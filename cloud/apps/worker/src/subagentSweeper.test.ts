import {
  admitDispatches,
  capacityForSession,
  createDb,
  drainReports,
  messages,
  migrate,
  newId,
  runs,
  sessions,
  type AdmissionOutcome,
  type Db,
} from "@ovid/db";
import { afterEach, describe, expect, it } from "vitest";

import {
  createMigrationScratch,
  type MigrationScratch,
} from "../../../packages/db/src/migrationTestKit.js";
import {
  createSubagentResources,
  drainReports as drainResourceReports,
  type SubagentResources,
} from "./subagentResources.js";
import { sweepSubagentAttempts } from "./subagentSweeper.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const HOUR = 60 * 60 * 1000;

interface Fixture {
  scratch: MigrationScratch;
  db: Db;
  userId: string;
  sessionId: string;
  rootTaskRunId: string;
  admitted: AdmissionOutcome[];
  close(): Promise<void>;
}

function timing(startedAt: Date): { checkpointAt: Date; deadlineAt: Date } {
  const deadlineAt = new Date(startedAt.getTime() + 8 * HOUR);
  return {
    checkpointAt: new Date(deadlineAt.getTime() - 5 * 60 * 1000),
    deadlineAt,
  };
}

async function createFixture(count: number, prefix: string): Promise<Fixture> {
  const scratch = await createMigrationScratch(TEST_DATABASE_URL!, prefix);
  await migrate(scratch.url);
  const db = createDb(scratch.url, { max: 12 });
  const userId = `${prefix}-user`;
  // Keep this fixture on the approved 0034 surface even while unrelated lanes
  // add user columns before their own migrations land.
  await db.$client`
    INSERT INTO users (uid, email) VALUES (${userId}, NULL)
    ON CONFLICT (uid) DO NOTHING`;
  const session = await sessions.create(db, userId, prefix);
  const rootMessage = await messages.append(db, {
    sessionId: session.id,
    role: "user",
    content: "root task",
  });
  const rootRun = await runs.create(db, {
    sessionId: session.id,
    promptMessageId: rootMessage.id,
  });
  expect(await runs.claimNext(db, rootRun.id)).toBe(true);
  const batchId = newId();
  const requestedAt = new Date();
  const admitted = await admitDispatches(db, Array.from({ length: count }, (_, index) => ({
    requestId: newId(),
    index,
    sessionId: session.id,
    userId,
    rootTaskRunId: rootRun.id,
    parentRunId: rootRun.id,
    batchId,
    prompt: `task-${index}: observed work only`,
    agentType: "general-purpose",
    provenance: index % 2 === 0 ? "web" as const : "android" as const,
    requestedAt,
    modelContext: {
      requestedModel: null,
      byokKeyId: null,
      actorUserId: userId,
    },
  })));
  const fixture: Fixture = {
    scratch,
    db,
    userId,
    sessionId: session.id,
    rootTaskRunId: rootRun.id,
    admitted,
    async close() {
      await fixture.db.$client.end({ timeout: 5 });
      await scratch.close();
    },
  };
  return fixture;
}

async function admitIntoSession(
  fixture: Fixture,
  sessionId: string,
  count: number,
  prefix: string,
): Promise<AdmissionOutcome[]> {
  const rootMessage = await messages.append(fixture.db, {
    sessionId,
    role: "user",
    content: `${prefix} root`,
  });
  const rootRun = await runs.create(fixture.db, {
    sessionId,
    promptMessageId: rootMessage.id,
  });
  expect(await runs.claimNext(fixture.db, rootRun.id)).toBe(true);
  const batchId = newId();
  return admitDispatches(fixture.db, Array.from({ length: count }, (_, index) => ({
    requestId: newId(),
    index,
    sessionId,
    userId: fixture.userId,
    rootTaskRunId: rootRun.id,
    parentRunId: rootRun.id,
    batchId,
    prompt: `${prefix}-${index}`,
    agentType: "general-purpose",
    provenance: index % 2 === 0 ? "web" as const : "android" as const,
    requestedAt: new Date(),
    modelContext: {
      requestedModel: null,
      byokKeyId: null,
      actorUserId: fixture.userId,
    },
  })));
}

async function ageAttempt(fixture: Fixture, attemptId: string, startedAt: Date): Promise<void> {
  await fixture.scratch.client`
    UPDATE subagent_attempts
    SET admitted_at = ${new Date(startedAt.getTime() - 1_000)}, started_at = ${startedAt}
    WHERE id = ${attemptId}`;
  await fixture.scratch.client`
    UPDATE runs SET started_at = ${startedAt}
    WHERE id = (SELECT child_run_id FROM subagent_attempts WHERE id = ${attemptId})`;
}

function sweep(resources: SubagentResources, now: Date) {
  return sweepSubagentAttempts({ resources, timing, now: () => now });
}

async function within<T>(promise: Promise<T>, milliseconds: number): Promise<T | "timed-out"> {
  let timer: NodeJS.Timeout | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<"timed-out">((resolve) => {
        timer = setTimeout(() => resolve("timed-out"), milliseconds);
      }),
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

describe.skipIf(!TEST_DATABASE_URL).sequential("subagent resources and recovery sweeper (real Postgres)", () => {
  const cleanups: Array<() => Promise<void>> = [];
  afterEach(async () => {
    await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()));
  }, 30_000);

  it("races pending recovery checkpoint/event hooks against each deadline without starving a sibling", async () => {
    const fixture = await createFixture(2, "task7_pending_recovery");
    cleanups.push(fixture.close);
    const first = fixture.admitted[0]!.attemptId!;
    const second = fixture.admitted[1]!.attemptId!;
    const firstStart = new Date(Date.now() - 8 * HOUR + 100);
    const secondStart = new Date(Date.now() - 8 * HOUR + 180);
    await ageAttempt(fixture, first, firstStart);
    await ageAttempt(fixture, second, secondStart);
    const released: string[] = [];
    const resources = createSubagentResources({
      db: fixture.db,
      captureCheckpoint: async ({ attemptId }) => {
        if (attemptId === first) return new Promise<never>(() => {});
        return { hash: "sha256:second-verified" };
      },
      killJobs: async ({ attemptId }) => {
        released.push(attemptId);
      },
    });
    const result = await within(sweepSubagentAttempts({
      resources,
      timing,
      now: () => new Date(),
      onCheckpoint: () => {
        return new Promise<void>(() => {});
      },
    }), 5_000);
    expect(result).not.toBe("timed-out");
    if (result === "timed-out") return;
    expect(result.timedOut).toBe(2);
    expect(new Set(released)).toEqual(new Set([first, second]));
    const reports = await drainReports(fixture.db, { sessionId: fixture.sessionId, limit: 50 });
    expect(reports.items).toHaveLength(2);
    const firstReport = reports.items.find((report) => report.attemptId === first)!;
    const secondReport = reports.items.find((report) => report.attemptId === second)!;
    expect(firstReport.summary).toContain("No verified checkpoint was produced.");
    expect(secondReport.summary).not.toContain("No verified checkpoint was produced.");
  }, 180_000);

  it("re-reads a delayed clock after checkpoint recovery and times out stale-now immediately", async () => {
    const fixture = await createFixture(1, "task7_stale_now");
    cleanups.push(fixture.close);
    const attemptId = fixture.admitted[0]!.attemptId!;
    const startedAt = new Date(Date.now() - 60_000);
    await ageAttempt(fixture, attemptId, startedAt);
    let current = startedAt.getTime() + 8 * HOUR - 5 * 60 * 1000;
    let emitted = 0;
    const resources = createSubagentResources({
      db: fixture.db,
      captureCheckpoint: async () => {
        current = startedAt.getTime() + 8 * HOUR + 1_000;
        return { hash: "sha256:late-recovery-checkpoint" };
      },
    });
    const result = await within(sweepSubagentAttempts({
      resources,
      timing,
      now: () => new Date(current),
      onCheckpoint: () => {
        emitted += 1;
      },
    }), 5_000);
    expect(result).not.toBe("timed-out");
    if (result === "timed-out") return;
    expect(result.timedOut).toBe(1);
    expect(emitted).toBe(0);
    expect((await capacityForSession(fixture.db, fixture.sessionId)).active).toBe(0);
  }, 180_000);

  it("returns a checkpoint only after its approved 0034 row can be read back", async () => {
    const fixture = await createFixture(1, "task7_checkpoint");
    cleanups.push(fixture.close);
    const attemptId = fixture.admitted[0]!.attemptId!;
    const now = new Date("2026-10-24T07:55:00.000Z");
    const resources = createSubagentResources({
      db: fixture.db,
      captureCheckpoint: async ({ attemptId: captured, now: capturedAt }) => ({
        hash: `sha256:${captured}-real`,
        objectRef: "checkpoint/object-ref",
        provenance: { capturedAt: capturedAt.toISOString() },
      }),
    });

    const verified = await resources.checkpoint({ attemptId, now });
    expect(verified).toMatchObject({
      hash: `sha256:${attemptId}-real`,
      createdAt: now.toISOString(),
    });
    expect(verified?.checkpointId).toEqual(expect.any(String));
    const rows = await fixture.scratch.client`
      SELECT id, attempt_id, hash, object_ref, verified_at, created_at
      FROM subagent_checkpoints WHERE attempt_id = ${attemptId}`;
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      id: verified!.checkpointId,
      attempt_id: attemptId,
      hash: verified!.hash,
      object_ref: "checkpoint/object-ref",
    });

    const withoutCapture = createSubagentResources({ db: fixture.db });
    await expect(withoutCapture.checkpoint({ attemptId, now })).resolves.toBeNull();
    expect((await fixture.scratch.client`
      SELECT count(*)::int AS count FROM subagent_checkpoints WHERE attempt_id = ${attemptId}`)[0])
      .toEqual({ count: 1 });
  }, 180_000);

  it("aborts and releases resources before persisting outcome and freeing capacity", async () => {
    const fixture = await createFixture(1, "task7_cleanup_order");
    cleanups.push(fixture.close);
    const attemptId = fixture.admitted[0]!.attemptId!;
    const events: string[] = [];
    const resources = createSubagentResources({
      db: fixture.db,
      abortTransport: async () => { events.push("abortTransport"); },
      killJobs: async () => { events.push("killJobsAndExec"); },
      releaseMcpLeases: async () => { events.push("releaseMcp"); },
      releaseBrowserLeases: async () => { events.push("releaseBrowser"); },
      closeLog: async () => { events.push("closeLog"); },
      freeCapacity: async () => {
        const persisted = await drainReports(fixture.db, { sessionId: fixture.sessionId, limit: 1 });
        events.push(`persisted:${persisted.items.length}:freeCapacity`);
      },
    });
    resources.recordOutcome({ attemptId, outcome: "completed", error: null });
    await resources.releaseAttempt(attemptId);
    const persisted = await drainReports(fixture.db, { sessionId: fixture.sessionId, limit: 1 });
    expect(persisted.items[0]?.status).toBe("completed");
    expect(events).toEqual([
      "abortTransport",
      "killJobsAndExec",
      "releaseMcp",
      "releaseBrowser",
      "closeLog",
      "persisted:1:freeCapacity",
    ]);
    expect((await capacityForSession(fixture.db, fixture.sessionId)).active).toBe(0);
  }, 180_000);

  it("sweeps a failed cleanup after capacity release without admitting deferred work", async () => {
    const fixture = await createFixture(51, "task7_cleanup_retry");
    cleanups.push(fixture.close);
    const attemptId = fixture.admitted[0]!.attemptId!;
    const deferredRequestId = fixture.admitted[50]!.deferredRequestId!;
    let killCalls = 0;
    const resources = createSubagentResources({
      db: fixture.db,
      killJobs: async () => {
        killCalls += 1;
        if (killCalls === 1) throw new Error("test-only kill failure");
      },
    });
    resources.recordOutcome({ attemptId, outcome: "timeout", error: null });
    const released = await resources.releaseAttempt(attemptId);
    expect(released).toEqual({ released: true, cleanupError: "cleanup failed: killJobs" });
    expect(await capacityForSession(fixture.db, fixture.sessionId)).toEqual({
      active: 49,
      limit: 50,
      available: 1,
      awaiting: 1,
    });
    expect((await fixture.scratch.client`
      SELECT count(*)::int AS count FROM subagent_control_audit
      WHERE source_attempt_id = ${attemptId} AND action = 'subagent_cleanup' AND outcome = 'pending'`)[0])
      .toEqual({ count: 1 });

    const recovered = await sweep(resources, new Date());
    expect(recovered).toMatchObject({ cleanupRetried: 1, cleanupFailed: 0 });
    expect(killCalls).toBe(2);
    expect((await fixture.scratch.client`
      SELECT count(*)::int AS count FROM subagent_control_audit
      WHERE source_attempt_id = ${attemptId} AND action = 'subagent_cleanup' AND outcome = 'pending'`)[0])
      .toEqual({ count: 0 });
    expect((await fixture.scratch.client`
      SELECT state FROM subagent_dispatches WHERE id = ${deferredRequestId}`)[0])
      .toEqual({ state: "awaiting_next_user_task" });
    expect((await fixture.scratch.client`
      SELECT count(*)::int AS count FROM subagent_attempts WHERE session_id = ${fixture.sessionId}`)[0])
      .toEqual({ count: 50 });
  }, 180_000);

  it("keeps a canonical pre-terminal outcome authoritative in reports and cleanup audit", async () => {
    const fixture = await createFixture(1, "task7_canonical");
    cleanups.push(fixture.close);
    const admission = fixture.admitted[0]!;
    await messages.append(fixture.db, {
      sessionId: admission.childSessionId!,
      role: "assistant",
      content: "Canonical completed answer",
    });
    await fixture.scratch.client`
      UPDATE runs SET status = 'completed', finished_at = now()
      WHERE id = ${admission.childRunId!}`;
    const resources = createSubagentResources({ db: fixture.db });
    resources.recordOutcome({
      attemptId: admission.attemptId!,
      outcome: "timeout",
      error: null,
      report: {
        summary: "caller timeout must not replace canonical completion",
        structuredReport: {
          subagent_id: admission.childSessionId!,
          status: "timeout",
          files_modified: [],
          artifacts_created: [],
          key_findings: "",
          error_if_any: "Timed out before finishing.",
        },
      },
    });
    await resources.releaseAttempt(admission.attemptId!);
    const reports = await drainReports(fixture.db, { sessionId: fixture.sessionId, limit: 1 });
    expect(reports.items[0]).toMatchObject({
      status: "completed",
      summary: "Canonical completed answer",
    });
    expect(reports.items[0]?.structuredReport).toBeUndefined();
    expect((await fixture.scratch.client`
      SELECT requested_transition, performed_transition FROM subagent_control_audit
      WHERE source_attempt_id = ${admission.attemptId!} AND action = 'subagent_cleanup'`)[0])
      .toEqual({ requested_transition: "timeout", performed_transition: "completed" });
  }, 180_000);

  it("recomputes timeout from persisted start after restart and never resumes work autonomously", async () => {
    const fixture = await createFixture(1, "task7_restart");
    cleanups.push(fixture.close);
    const attemptId = fixture.admitted[0]!.attemptId!;
    const startedAt = new Date(Date.now() - 8 * HOUR + 1_000);
    await ageAttempt(fixture, attemptId, startedAt);
    let abortCalls = 0;
    const restartedResources = createSubagentResources({
      db: fixture.db,
      abortTransport: async () => { abortCalls += 1; },
    });

    const before = await sweep(restartedResources, new Date(startedAt.getTime() + 8 * HOUR - 1_000));
    expect(before.timedOut).toBe(0);
    expect((await capacityForSession(fixture.db, fixture.sessionId)).active).toBe(1);

    const atDeadline = new Date(startedAt.getTime() + 8 * HOUR);
    const recovered = await sweep(restartedResources, atDeadline);
    expect(recovered.timedOut).toBe(1);
    expect(abortCalls).toBeGreaterThanOrEqual(1);
    expect((await capacityForSession(fixture.db, fixture.sessionId)).active).toBe(0);
    const reports = await drainReports(fixture.db, { sessionId: fixture.sessionId, limit: 50 });
    expect(reports.items).toHaveLength(1);
    expect(reports.items[0]?.status).toBe("timeout");
    expect(reports.items[0]?.summary).toContain("No verified checkpoint was produced.");
    expect(reports.items[0]?.summary.length).toBeLessThanOrEqual(4_000);
    expect(reports.items[0]?.structuredReport).toEqual({
      subagent_id: fixture.admitted[0]!.childSessionId,
      status: "timeout",
      files_modified: [],
      artifacts_created: [],
      key_findings: "",
      error_if_any: "Timed out before finishing.",
    });
    expect((await fixture.scratch.client`
      SELECT count(*)::int AS count FROM subagent_attempts WHERE session_id = ${fixture.sessionId}`)[0])
      .toEqual({ count: 1 });
  }, 180_000);

  it("bounds observed lists again at resource persistence with deterministic omitted counts", async () => {
    const fixture = await createFixture(1, "task7_report_bounds");
    cleanups.push(fixture.close);
    const admission = fixture.admitted[0]!;
    const files = Array.from({ length: 130 }, (_, index) =>
      index === 0 ? `src/${"f".repeat(900)}` : `src/${index}-${"x".repeat(100)}`);
    const artifacts = Array.from({ length: 125 }, (_, index) => `artifact-${index}-${"y".repeat(90)}`);
    const resources = createSubagentResources({ db: fixture.db });
    resources.recordOutcome({
      attemptId: admission.attemptId!,
      outcome: "completed",
      error: null,
      report: {
        summary: "bounded",
        structuredReport: {
          subagent_id: admission.childSessionId!,
          status: "completed",
          files_modified: files,
          artifacts_created: artifacts,
          key_findings: "bounded",
          error_if_any: null,
        },
      },
    });
    await resources.releaseAttempt(admission.attemptId!);
    // Prove the stored row is bounded independently of the drain projection.
    const storedPage = await drainReports(fixture.db, { sessionId: fixture.sessionId, limit: 1 });
    const stored = storedPage.items[0]!.structuredReport!;
    expect(stored.files_modified.length).toBeLessThanOrEqual(100);
    expect(stored.artifacts_created.length).toBeLessThanOrEqual(100);
    expect(Buffer.byteLength(JSON.stringify(stored.files_modified), "utf8"))
      .toBeLessThanOrEqual(8_192);
    expect(Buffer.byteLength(JSON.stringify(stored.artifacts_created), "utf8"))
      .toBeLessThanOrEqual(8_192);
    const page = await drainResourceReports(fixture.db, { sessionId: fixture.sessionId, limit: 1 });
    const report = page.items[0]!.structuredReport!;
    expect(report.files_modified.length).toBeLessThanOrEqual(100);
    expect(report.artifacts_created.length).toBeLessThanOrEqual(100);
    expect([...report.files_modified, ...report.artifacts_created].every((item) =>
      Array.from(item).length <= 512)).toBe(true);
    expect(Buffer.byteLength(JSON.stringify(report.files_modified), "utf8"))
      .toBeLessThanOrEqual(8_192);
    expect(Buffer.byteLength(JSON.stringify(report.artifacts_created), "utf8"))
      .toBeLessThanOrEqual(8_192);
    expect(report.key_findings).toContain(
      `${130 - report.files_modified.length} files and ` +
      `${125 - report.artifacts_created.length} artifacts omitted`,
    );
    expect(Object.keys(report).sort()).toEqual([
      "artifacts_created", "error_if_any", "files_modified",
      "key_findings", "status", "subagent_id",
    ]);
  }, 180_000);

  it("revalidates an oversized legacy structured report at the drain boundary", async () => {
    const fixture = await createFixture(1, "task7_drain_bounds");
    cleanups.push(fixture.close);
    const admission = fixture.admitted[0]!;
    const resources = createSubagentResources({ db: fixture.db });
    resources.recordOutcome({ attemptId: admission.attemptId!, outcome: "completed", error: null });
    await resources.releaseAttempt(admission.attemptId!);
    const oversized = {
      subagent_id: admission.childSessionId!,
      status: "completed",
      files_modified: Array.from({ length: 140 }, (_, index) => `f-${index}-${"z".repeat(100)}`),
      artifacts_created: Array.from({ length: 120 }, (_, index) => `a-${index}-${"q".repeat(100)}`),
      key_findings: "legacy",
      error_if_any: null,
    };
    await fixture.scratch.client`
      UPDATE subagent_reports SET structured_report = ${JSON.stringify(oversized)}::jsonb
      WHERE attempt_id = ${admission.attemptId!}`;
    const page = await drainResourceReports(fixture.db, { sessionId: fixture.sessionId, limit: 1 });
    const report = page.items[0]!.structuredReport!;
    expect(report.files_modified.length).toBeLessThanOrEqual(100);
    expect(report.artifacts_created.length).toBeLessThanOrEqual(100);
    expect(Buffer.byteLength(JSON.stringify({
      files_modified: report.files_modified,
      artifacts_created: report.artifacts_created,
    }), "utf8")).toBeLessThanOrEqual(16_384);
    expect(report.key_findings).toContain(
      `${140 - report.files_modified.length} files and ` +
      `${120 - report.artifacts_created.length} artifacts omitted`,
    );
  }, 180_000);

  it("does not run duplicate concurrent cleanup for one attempt across resource instances", async () => {
    const fixture = await createFixture(1, "task7_cleanup_lease");
    cleanups.push(fixture.close);
    const attemptId = fixture.admitted[0]!.attemptId!;
    let unblock!: () => void;
    const gate = new Promise<void>((resolve) => { unblock = resolve; });
    let active = 0;
    let maximumActive = 0;
    let calls = 0;
    const makeResources = () => createSubagentResources({
      db: fixture.db,
      killJobs: async () => {
        calls += 1;
        active += 1;
        maximumActive = Math.max(maximumActive, active);
        try {
          if (calls === 1) await gate;
          throw new Error("test-only cleanup failure");
        } finally {
          active -= 1;
        }
      },
    });
    const firstResources = makeResources();
    const secondResources = makeResources();
    firstResources.recordOutcome({ attemptId, outcome: "failed", error: null });
    secondResources.recordOutcome({ attemptId, outcome: "failed", error: null });
    const first = firstResources.releaseAttempt(attemptId);
    for (let turn = 0; turn < 5_000 && calls === 0; turn += 1) {
      await new Promise((resolve) => setTimeout(resolve, 1));
    }
    try {
      expect(calls).toBe(1);
      const second = await secondResources.retryCleanup(attemptId);
      expect(maximumActive).toBe(1);
      expect(second).toMatchObject({ released: false, cleanupError: "cleanup lease active" });
    } finally {
      unblock();
      await first;
    }
    await secondResources.retryCleanup(attemptId);
    expect(calls).toBe(2);
    expect(maximumActive).toBe(1);
  }, 180_000);

  it("releases the advisory lease when cursor persistence fails before cleanup", async () => {
    const fixture = await createFixture(1, "task7_lease_error");
    cleanups.push(fixture.close);
    const attemptId = fixture.admitted[0]!.attemptId!;
    const initial = createSubagentResources({
      db: fixture.db,
      killJobs: async () => { throw new Error("initial cleanup failure"); },
    });
    initial.recordOutcome({ attemptId, outcome: "failed", error: null });
    await initial.releaseAttempt(attemptId);
    await fixture.scratch.client`
      CREATE FUNCTION fail_task7_cleanup_cursor() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'test-only cursor write failure'; END;
      $$`;
    await fixture.scratch.client`
      CREATE TRIGGER fail_task7_cleanup_cursor
      BEFORE UPDATE ON subagent_control_audit
      FOR EACH ROW EXECUTE FUNCTION fail_task7_cleanup_cursor()`;
    try {
      await expect(initial.retryCleanup(attemptId)).rejects.toThrow();
    } finally {
      await fixture.scratch.client`DROP TRIGGER fail_task7_cleanup_cursor ON subagent_control_audit`;
      await fixture.scratch.client`DROP FUNCTION fail_task7_cleanup_cursor()`;
    }

    const recovered = createSubagentResources({ db: fixture.db });
    const result = await recovered.retryCleanup(attemptId);
    expect(result).toEqual({ released: true });
    expect((await fixture.scratch.client`
      SELECT count(*)::int AS count FROM subagent_control_audit
      WHERE source_attempt_id = ${attemptId} AND action = 'subagent_cleanup'
        AND outcome = 'pending'`)[0]).toEqual({ count: 0 });
  }, 180_000);

  it("rotates more than 100 failing cleanup intents fairly without deferred auto-start", async () => {
    const fixture = await createFixture(0, "task7_fair_cleanup");
    cleanups.push(fixture.close);
    const secondSession = await sessions.create(fixture.db, fixture.userId, "fair-second");
    const thirdSession = await sessions.create(fixture.db, fixture.userId, "fair-third");
    const first = await admitIntoSession(fixture, fixture.sessionId, 51, "fair-first");
    const second = await admitIntoSession(fixture, secondSession.id, 40, "fair-second");
    const third = await admitIntoSession(fixture, thirdSession.id, 30, "fair-third");
    const all = [...first.slice(0, 50), ...second, ...third];
    expect(all).toHaveLength(120);
    const deferredRequestId = first[50]!.deferredRequestId!;
    const resources = createSubagentResources({
      db: fixture.db,
      killJobs: async () => {
        throw new Error("persistent test-only cleanup failure");
      },
    });
    for (const admission of all) {
      resources.recordOutcome({
        attemptId: admission.attemptId!,
        outcome: "failed",
        error: null,
      });
      await resources.releaseAttempt(admission.attemptId!);
    }
    expect((await fixture.scratch.client`
      SELECT count(*)::int AS count FROM subagent_control_audit
      WHERE action = 'subagent_cleanup' AND outcome = 'pending'`)[0]).toEqual({ count: 120 });

    const firstRetried = new Set<string>();
    const trackFirst = createSubagentResources({
      db: fixture.db,
      killJobs: async ({ attemptId }) => {
        firstRetried.add(attemptId);
        throw new Error("persistent test-only cleanup failure");
      },
    });
    const firstSweep = await sweep(trackFirst, new Date());
    expect(firstSweep.cleanupRetried).toBe(100);
    expect(firstRetried.size).toBe(100);

    const secondRetried = new Set<string>();
    const trackSecond = createSubagentResources({
      db: fixture.db,
      killJobs: async ({ attemptId }) => {
        secondRetried.add(attemptId);
        throw new Error("persistent test-only cleanup failure");
      },
    });
    const secondSweep = await sweep(trackSecond, new Date());
    expect(secondSweep.cleanupRetried).toBe(100);
    for (const attemptId of firstRetried) {
      if (!secondRetried.has(attemptId)) secondRetried.add(attemptId);
    }
    expect(secondRetried.size).toBe(120);
    expect((await fixture.scratch.client`
      SELECT state FROM subagent_dispatches WHERE id = ${deferredRequestId}`)[0])
      .toEqual({ state: "awaiting_next_user_task" });
    expect((await fixture.scratch.client`
      SELECT count(*)::int AS count FROM subagent_attempts`)[0]).toEqual({ count: 120 });
  }, 180_000);

  it("retains all 50 Task 5 durable reports and matching six-key structure without a lossy queue", async () => {
    const fixture = await createFixture(50, "task7_reports");
    cleanups.push(fixture.close);
    const resources = createSubagentResources({ db: fixture.db });
    const statuses = ["completed", "failed", "cancelled", "timeout"] as const;
    for (const [index, admission] of fixture.admitted.entries()) {
      const outcome = statuses[index % statuses.length]!;
      const structuredReport = {
        subagent_id: admission.childSessionId!,
        status: outcome,
        files_modified: index === 0 ? ["src/observed.ts"] : [],
        artifacts_created: index === 0 ? ["artifact-observed"] : [],
        key_findings: index === 0 ? "Observed finding." : "",
        error_if_any: outcome === "failed" ? "actual failure" : outcome === "timeout" ? "Timed out before finishing." : null,
      } as const;
      resources.recordOutcome({
        attemptId: admission.attemptId!,
        outcome,
        error: structuredReport.error_if_any,
        report: { summary: `report-${index}`, structuredReport },
      });
      await resources.releaseAttempt(admission.attemptId!);
    }

    expect((await capacityForSession(fixture.db, fixture.sessionId)).active).toBe(0);
    const seen = new Set<string>();
    let afterId: string | undefined;
    let pages = 0;
    let firstStructured: unknown;
    do {
      const page = await drainReports(fixture.db, {
        sessionId: fixture.sessionId,
        afterId,
        limit: 17,
      });
      pages += 1;
      expect(page.items.length).toBeLessThanOrEqual(17);
      for (const report of page.items) {
        expect(seen.has(report.attemptId)).toBe(false);
        seen.add(report.attemptId);
        if (report.attemptId === fixture.admitted[0]!.attemptId) {
          firstStructured = report.structuredReport;
        }
      }
      afterId = page.nextCursor ?? undefined;
      if (page.nextCursor === null) break;
    } while (pages < 5);

    expect(pages).toBe(3);
    expect(seen.size).toBe(50);
    expect(firstStructured).toEqual({
      subagent_id: fixture.admitted[0]!.childSessionId,
      status: "completed",
      files_modified: ["src/observed.ts"],
      artifacts_created: ["artifact-observed"],
      key_findings: "Observed finding.",
      error_if_any: null,
    });
    expect((await fixture.scratch.client`
      SELECT count(*)::int AS count FROM subagent_reports WHERE session_id = ${fixture.sessionId}`)[0])
      .toEqual({ count: 50 });
  }, 180_000);
});
