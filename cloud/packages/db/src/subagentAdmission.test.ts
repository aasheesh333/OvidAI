import { afterEach, describe, expect, it } from "vitest";
import type postgres from "postgres";
import { createDb, migrate, type Db } from "./client.js";
import { createMigrationScratch, type MigrationScratch } from "./migrationTestKit.js";
import { messages, newId, runs, sessions, users } from "./repos.js";
import { fingerprintRootFinalizationReports } from "./subagentReportSnapshots.js";
import {
  admitDispatches,
  beforeRootFinalResponse,
  capacityForSession,
  drainReports,
  markRootFinalized,
  reconsiderDeferred,
  settleAttemptAndMaybeWake,
  snapshotRootFinalization,
  updateDeferred,
  type AdmissionRequest,
  type AdmissionOutcome,
} from "./subagentAdmission.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const MODEL_CONTEXT = {
  requestedModel: "parent/model",
  byokKeyId: "key-id-only",
  byokModel: "provider/model",
  actorUserId: "unused-in-test-helper",
} as const;

interface Fixture {
  scratch: MigrationScratch;
  db: Db;
  userId: string;
  sessionId: string;
  close(): Promise<void>;
}

async function createFixture(prefix: string): Promise<Fixture> {
  const scratch = await createMigrationScratch(TEST_DATABASE_URL!, prefix);
  await migrate(scratch.url);
  const db = createDb(scratch.url, { max: 12 });
  const userId = `${prefix}-user`;
  await users.ensure(db, userId, null);
  const session = await sessions.create(db, userId, prefix);
  const fixture: Fixture = {
    scratch,
    db,
    userId,
    sessionId: session.id,
    async close() {
      await fixture.db.$client.end({ timeout: 5 });
      await scratch.close();
    },
  };
  return fixture;
}

async function createUserRoot(
  db: Db,
  sessionId: string,
  text: string,
): Promise<{ rootTaskRunId: string; messageId: string }> {
  const message = await messages.append(db, { sessionId, role: "user", content: text });
  const run = await runs.create(db, { sessionId, promptMessageId: message.id });
  expect(await runs.claimNext(db, run.id)).toBe(true);
  return { rootTaskRunId: run.id, messageId: message.id };
}

function requestsFor(input: {
  sessionId: string;
  userId: string;
  rootTaskRunId: string;
  batchId: string;
  count: number;
  provenance: "web" | "android" | "server";
  indexOffset?: number;
  promptPrefix?: string;
}): AdmissionRequest[] {
  const requestedAt = Date.now() - 10_000;
  return Array.from({ length: input.count }, (_, offset) => {
    const index = (input.indexOffset ?? 0) + offset;
    return {
      requestId: newId(),
      index,
      sessionId: input.sessionId,
      userId: input.userId,
      rootTaskRunId: input.rootTaskRunId,
      parentRunId: input.rootTaskRunId,
      batchId: input.batchId,
      prompt: `${input.promptPrefix ?? "task"}-${index}: preserve the complete prompt`,
      agentType: offset % 2 === 0 ? "general-purpose" : "research",
      tools: ["read", `tool-${index}`],
      disallowedTools: ["dispatch_agent"],
      provenance: input.provenance,
      requestedAt: new Date(requestedAt + index),
      userPriorityHint: index,
      modelContext: { ...MODEL_CONTEXT, actorUserId: input.userId },
    };
  });
}

function flattened(outcomes: readonly AdmissionOutcome[][]): AdmissionOutcome[] {
  return outcomes.flatMap((batch) => batch);
}

async function rawDeferred(client: postgres.Sql, requestId: string) {
  const rows = await client`
    SELECT d.id, d.state, d.prompt, d.provenance, d.tools, d.disallowed_tools,
      d.user_priority_hint, d.requested_model, d.byok_key_id, d.byok_model,
      d.requested_at, d.deferred_at, d.admitted_at, d.cancelled_at,
      d.first_message_id, d.admitted_root_task_run_id,
      (SELECT count(*)::int AS count FROM subagent_logical_workers w WHERE w.request_id = d.id) AS workers
    FROM subagent_dispatches d WHERE d.id = ${requestId}`;
  expect(rows).toHaveLength(1);
  return rows[0]!;
}

async function createDeferredSlot(
  fixture: Fixture,
  prefix: string,
): Promise<{ originalRootId: string; deferredRequestId: string }> {
  const { db, sessionId, userId } = fixture;
  const originalRoot = await createUserRoot(db, sessionId, `${prefix} original root`);
  const outcomes = await admitDispatches(db, requestsFor({
    sessionId, userId, rootTaskRunId: originalRoot.rootTaskRunId, batchId: newId(),
    count: 51, provenance: "web", promptPrefix: prefix,
  }));
  expect(outcomes.filter((outcome) => outcome.admission === "admitted")).toHaveLength(50);
  const deferredRequestId = outcomes[50]?.deferredRequestId!;
  expect(outcomes[50]?.admission).toBe("awaiting_next_user_task");
  await settleAttemptAndMaybeWake(db, {
    attemptId: outcomes[0]!.attemptId!, outcome: "completed",
  });
  expect(await capacityForSession(db, sessionId)).toEqual({
    active: 49, limit: 50, available: 1, awaiting: 1,
  });
  return { originalRootId: originalRoot.rootTaskRunId, deferredRequestId };
}

describe.skipIf(!TEST_DATABASE_URL).sequential("durable subagent admission", () => {
  const cleanups: Array<() => Promise<void>> = [];
  afterEach(async () => {
    await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()));
  }, 30_000);

  it("races 51 Web/Android requests across two connections and roots without exceeding 50", async () => {
    const fixture = await createFixture("admission_race");
    cleanups.push(fixture.close);
    const { db, scratch, sessionId, userId } = fixture;
    const other = createDb(scratch.url, { max: 2 });
    cleanups.push(() => other.$client.end({ timeout: 5 }));
    const rootA = await createUserRoot(db, sessionId, "Web root");
    const rootB = await createUserRoot(db, sessionId, "Android root");
    const batchA = newId();
    const batchB = newId();
    const requestsA = requestsFor({
      sessionId, userId, rootTaskRunId: rootA.rootTaskRunId, batchId: batchA,
      count: 26, provenance: "web", promptPrefix: "web",
    });
    const requestsB = requestsFor({
      sessionId, userId, rootTaskRunId: rootB.rootTaskRunId, batchId: batchB,
      count: 25, provenance: "android", promptPrefix: "android",
    });

    const [outcomesA, outcomesB] = await Promise.all([
      admitDispatches(db, requestsA),
      admitDispatches(other, requestsB),
    ]);
    expect(outcomesA.map((outcome) => outcome.index)).toEqual(requestsA.map((request) => request.index));
    expect(outcomesB.map((outcome) => outcome.index)).toEqual(requestsB.map((request) => request.index));
    const all = flattened([outcomesA, outcomesB]);
    expect(all.filter((outcome) => outcome.admission === "admitted")).toHaveLength(50);
    expect(all.filter((outcome) => outcome.admission === "awaiting_next_user_task")).toHaveLength(1);
    expect(all.filter((outcome) => outcome.admission === "refused")).toHaveLength(0);
    const partial = [outcomesA, outcomesB].find((outcomes) =>
      outcomes.some((outcome) => outcome.admission === "awaiting_next_user_task"))!;
    expect(partial[partial.length - 1]?.admission).toBe("awaiting_next_user_task");
    expect(partial.slice(0, -1).every((outcome) => outcome.admission === "admitted")).toBe(true);

    for (const outcome of all) {
      if (outcome.admission === "admitted") {
        expect(outcome.logicalWorkerId).toEqual(expect.any(String));
        expect(outcome.attemptId).toEqual(expect.any(String));
        expect(outcome.childSessionId).toEqual(expect.any(String));
        expect(outcome.childRunId).toEqual(expect.any(String));
        expect(outcome.deferredRequestId).toBeUndefined();
      } else {
        expect(outcome.deferredRequestId).toEqual(expect.any(String));
        expect(outcome.logicalWorkerId).toBeUndefined();
        expect(outcome.attemptId).toBeUndefined();
        expect(outcome.childSessionId).toBeUndefined();
        expect(outcome.childRunId).toBeUndefined();
      }
    }
    expect(await capacityForSession(db, sessionId)).toEqual({
      active: 50, limit: 50, available: 0, awaiting: 1,
    });
    const counts = await scratch.client`
      SELECT
        (SELECT count(*)::int FROM subagent_attempts WHERE session_id = ${sessionId} AND status = 'running') AS active,
        (SELECT count(*)::int FROM subagent_attempts WHERE session_id = ${sessionId}) AS attempts,
        (SELECT count(*)::int FROM runs r JOIN subagent_attempts a ON a.child_run_id = r.id
          WHERE a.session_id = ${sessionId}) AS child_runs,
        (SELECT count(*)::int FROM run_usage WHERE session_id = ${sessionId}) AS usage_rows,
        (SELECT count(*)::int FROM subagent_roots WHERE session_id = ${sessionId}) AS roots`;
    expect(counts[0]).toMatchObject({ active: 50, attempts: 50, child_runs: 50, usage_rows: 0, roots: 2 });

    const deferred = all.find((outcome) => outcome.admission === "awaiting_next_user_task")!;
    const stored = await rawDeferred(scratch.client, deferred.deferredRequestId!);
    expect(stored).toMatchObject({ state: "awaiting_next_user_task", workers: 0, admitted_at: null });
    expect(stored.first_message_id).toBeNull();
    expect(stored.prompt).toContain("preserve the complete prompt");
  }, 180_000);

  it("preserves backlog across reconnect, never auto-starts on completion, and admits only main-selected work after a new user root", async () => {
    const fixture = await createFixture("admission_restart");
    let db = fixture.db;
    let closed = false;
    const close = async () => {
      if (closed) return;
      closed = true;
      await fixture.close();
    };
    cleanups.push(close);
    const { scratch, sessionId, userId } = fixture;
    const originalRoot = await createUserRoot(db, sessionId, "Original root");
    const requests = requestsFor({
      sessionId, userId, rootTaskRunId: originalRoot.rootTaskRunId, batchId: newId(),
      count: 53, provenance: "android", promptPrefix: "durable",
    });
    const initial = await admitDispatches(db, requests);
    const deferred = initial.slice(50).map((outcome) => outcome.deferredRequestId!);
    expect(deferred).toHaveLength(3);
    const [older, urgentNew, cancelled] = deferred as [string, string, string];

    expect(await updateDeferred(db, {
      sessionId, deferredRequestId: older!, actorRunId: originalRoot.rootTaskRunId, userPriorityHint: 7,
    })).toBe("updated");
    expect(await updateDeferred(db, {
      sessionId, deferredRequestId: urgentNew!, actorRunId: originalRoot.rootTaskRunId, userPriorityHint: 99,
    })).toBe("updated");
    expect(await updateDeferred(db, {
      sessionId, deferredRequestId: cancelled!, actorRunId: originalRoot.rootTaskRunId, cancel: true,
    })).toBe("updated");
    expect(await updateDeferred(db, {
      sessionId, deferredRequestId: cancelled!, actorRunId: originalRoot.rootTaskRunId, cancel: true,
    })).toBe("not_deferred");

    // A fresh pool is the reconnect/restart boundary: no process-local state is consulted.
    await db.$client.end({ timeout: 5 });
    db = createDb(scratch.url, { max: 12 });
    fixture.db = db;
    const cancelledRow = await rawDeferred(scratch.client, cancelled!);
    expect(cancelledRow).toMatchObject({ state: "cancelled", provenance: "android", workers: 0 });
    expect(cancelledRow.cancelled_at).toBeInstanceOf(Date);
    expect(cancelledRow.prompt).toBe(`durable-52: preserve the complete prompt`);
    const urgentRow = await rawDeferred(scratch.client, urgentNew!);
    expect(urgentRow).toMatchObject({
      state: "awaiting_next_user_task", provenance: "android", user_priority_hint: 99,
      requested_model: "parent/model", byok_key_id: "key-id-only", byok_model: "provider/model",
      tools: ["read", "tool-51"], disallowed_tools: ["dispatch_agent"], admitted_at: null,
    });

    const audit = await scratch.client`
      SELECT deferred_request_id, actor_run_id, action, decision, outcome
      FROM subagent_control_audit
      WHERE deferred_request_id IN (${older}, ${urgentNew}, ${cancelled})
      ORDER BY action, deferred_request_id`;
    expect(audit).toHaveLength(3);
    expect(audit.filter((row) => row.action === "deferred_cancel")).toHaveLength(1);
    expect(audit.filter((row) => row.action === "deferred_reprioritize")).toHaveLength(2);
    expect(audit.every((row) =>
      row.actor_run_id === originalRoot.rootTaskRunId &&
      row.decision === "performed" && row.outcome === "updated")).toBe(true);

    const active = initial.filter((outcome) => outcome.admission === "admitted");
    const settled = await Promise.all(active.slice(0, 2).map((outcome, index) =>
      settleAttemptAndMaybeWake(db, {
        attemptId: outcome.attemptId!, outcome: index === 0 ? "completed" : "failed",
      })));
    expect(settled.every((result) => result.rootTaskRunId === originalRoot.rootTaskRunId)).toBe(true);
    expect(settled.every((result) => result.shouldWake === false)).toBe(true);
    expect(await capacityForSession(db, sessionId)).toEqual({
      active: 48, limit: 50, available: 2, awaiting: 2,
    });
    expect((await rawDeferred(scratch.client, older!)).state).toBe("awaiting_next_user_task");
    expect((await rawDeferred(scratch.client, urgentNew!)).state).toBe("awaiting_next_user_task");
    expect((await scratch.client`SELECT count(*)::int AS count FROM subagent_attempts WHERE session_id = ${sessionId}`)[0])
      .toEqual({ count: 50 });

    // Completion and an old-root/wake actor are not a next-user admission permit.
    const forbidden = await reconsiderDeferred(db, {
      sessionId, rootTaskRunId: originalRoot.rootTaskRunId, requestIds: [older!, urgentNew!],
      actorRunId: originalRoot.rootTaskRunId, schedulingReason: "completion wake only",
    });
    expect(forbidden.map((outcome) => [outcome.admission, outcome.code])).toEqual([
      ["refused", "next_user_task_required"], ["refused", "next_user_task_required"],
    ]);
    expect((await capacityForSession(db, sessionId)).active).toBe(48);

    const nextRoot = await createUserRoot(db, sessionId, "Genuine next user root");
    const cancelledOutcome = await reconsiderDeferred(db, {
      sessionId, rootTaskRunId: nextRoot.rootTaskRunId, requestIds: [cancelled!],
      actorRunId: nextRoot.rootTaskRunId, schedulingReason: "main reviewed cancelled work",
    });
    expect(cancelledOutcome).toEqual([{
      index: 0, admission: "refused", code: "not_deferred", message: "Request is not deferred.",
    }]);

    // The server honors this exact main-selected order; it does not impose FIFO/new-first.
    const admitted = await reconsiderDeferred(db, {
      sessionId, rootTaskRunId: nextRoot.rootTaskRunId, requestIds: [urgentNew!, older!],
      actorRunId: nextRoot.rootTaskRunId, schedulingReason: "urgent new work before older backlog",
    });
    expect(admitted.map((outcome) => outcome.admission)).toEqual(["admitted", "admitted"]);
    expect(admitted.map((outcome) => outcome.index)).toEqual([0, 1]);
    expect(admitted.map((outcome) => outcome.deferredRequestId)).toEqual([urgentNew, older]);
    const lineage = await scratch.client`
      SELECT d.id, d.prompt, d.first_message_id, d.root_task_run_id, d.admitted_root_task_run_id,
        d.requested_at, d.admitted_at, d.scheduling_reason, d.decision_actor_run_id,
        a.started_at, a.root_task_run_id AS attempt_root,
        m.content AS canonical_prompt, r.started_at AS run_started_at
      FROM subagent_dispatches d
      JOIN subagent_logical_workers w ON w.request_id = d.id
      JOIN subagent_attempts a ON a.logical_worker_id = w.id
      JOIN messages m ON m.id = d.first_message_id
      JOIN runs r ON r.id = a.child_run_id
      WHERE d.id IN (${older}, ${urgentNew})`;
    expect(lineage).toHaveLength(2);
    for (const row of lineage) {
      expect(row.prompt).toBeNull();
      expect(row.first_message_id).toEqual(expect.any(String));
      expect(row.root_task_run_id).toBe(originalRoot.rootTaskRunId);
      expect(row.admitted_root_task_run_id).toBe(nextRoot.rootTaskRunId);
      expect(row.attempt_root).toBe(nextRoot.rootTaskRunId);
      expect(row.admitted_at).toBeInstanceOf(Date);
      expect(row.started_at).toBeInstanceOf(Date);
      expect(row.admitted_at.getTime()).toBeGreaterThan(row.requested_at.getTime());
      expect(row.scheduling_reason).toBe("urgent new work before older backlog");
      expect(row.decision_actor_run_id).toBe(nextRoot.rootTaskRunId);
      expect(row.started_at.getTime()).toBeGreaterThanOrEqual(row.admitted_at.getTime());
      expect(row.started_at.getTime()).not.toBe(row.admitted_at.getTime());
      expect(row.run_started_at).toEqual(row.started_at);
    }
    const byId = new Map(lineage.map((row) => [row.id, row]));
    expect(byId.get(older)?.canonical_prompt).toBe("durable-50: preserve the complete prompt");
    expect(byId.get(urgentNew)?.canonical_prompt).toBe("durable-51: preserve the complete prompt");
    expect((await rawDeferred(scratch.client, cancelled!)).workers).toBe(0);
    expect((await scratch.client`SELECT count(*)::int AS count FROM run_usage WHERE session_id = ${sessionId}`)[0])
      .toEqual({ count: 0 });

    await close();
  }, 180_000);

  it("rejects reuse of a completed next-user root without admitting deferred work", async () => {
    const fixture = await createFixture("admission_completed_root");
    cleanups.push(fixture.close);
    const { db, scratch, sessionId } = fixture;
    const { deferredRequestId } = await createDeferredSlot(fixture, "completed-root");
    const completedRoot = await createUserRoot(db, sessionId, "Root that already ended");
    await scratch.client`
      UPDATE runs SET status = 'completed', finished_at = now()
      WHERE id = ${completedRoot.rootTaskRunId}`;

    const outcomes = await reconsiderDeferred(db, {
      sessionId,
      rootTaskRunId: completedRoot.rootTaskRunId,
      requestIds: [deferredRequestId],
      actorRunId: completedRoot.rootTaskRunId,
      schedulingReason: "late completion wake must not admit",
    });
    expect(outcomes).toHaveLength(1);
    expect(outcomes[0]).toMatchObject({
      index: 0,
      admission: "refused",
      code: "next_user_task_required",
    });
    expect(outcomes[0]).not.toHaveProperty("attemptId");
    expect(outcomes[0]).not.toHaveProperty("childRunId");
    expect(await rawDeferred(scratch.client, deferredRequestId)).toMatchObject({
      state: "awaiting_next_user_task",
      workers: 0,
      admitted_at: null,
      first_message_id: null,
    });
    expect(await capacityForSession(db, sessionId)).toEqual({
      active: 49, limit: 50, available: 1, awaiting: 1,
    });
    expect((await scratch.client`
      SELECT count(*)::int AS count FROM subagent_attempts WHERE session_id = ${sessionId}`)[0])
      .toEqual({ count: 50 });
  }, 180_000);

  it("rejects stale and mismatched actors, then admits only for the exact active next root", async () => {
    const fixture = await createFixture("admission_actor_lineage");
    cleanups.push(fixture.close);
    const { db, scratch, sessionId } = fixture;
    const { originalRootId, deferredRequestId } = await createDeferredSlot(fixture, "actor-lineage");
    await scratch.client`
      UPDATE runs SET status = 'failed', finished_at = now(), last_error = 'original ended'
      WHERE id = ${originalRootId}`;
    const activeNextRoot = await createUserRoot(db, sessionId, "Legitimate active next root");
    const otherActiveRoot = await createUserRoot(db, sessionId, "Unrelated active root");
    const base = {
      sessionId,
      rootTaskRunId: activeNextRoot.rootTaskRunId,
      requestIds: [deferredRequestId],
      schedulingReason: "main explicitly selected this deferred task",
    };

    const staleActor = await reconsiderDeferred(db, {
      ...base, actorRunId: originalRootId,
    });
    const mismatchedActor = await reconsiderDeferred(db, {
      ...base, actorRunId: otherActiveRoot.rootTaskRunId,
    });
    for (const outcomes of [staleActor, mismatchedActor]) {
      expect(outcomes).toHaveLength(1);
      expect(outcomes[0]).toMatchObject({
        index: 0,
        admission: "refused",
        code: "invalid_actor_lineage",
      });
      expect(outcomes[0]).not.toHaveProperty("attemptId");
      expect(outcomes[0]).not.toHaveProperty("childRunId");
    }
    expect(await rawDeferred(scratch.client, deferredRequestId)).toMatchObject({
      state: "awaiting_next_user_task",
      workers: 0,
      admitted_at: null,
    });

    const legitimate = await reconsiderDeferred(db, {
      ...base, actorRunId: activeNextRoot.rootTaskRunId,
    });
    expect(legitimate).toHaveLength(1);
    expect(legitimate[0]).toMatchObject({
      index: 0,
      admission: "admitted",
      deferredRequestId,
    });
    expect(legitimate[0]?.attemptId).toEqual(expect.any(String));
    expect(legitimate[0]?.childRunId).toEqual(expect.any(String));
    expect(await rawDeferred(scratch.client, deferredRequestId)).toMatchObject({
      state: "admitted",
      workers: 1,
      prompt: null,
      admitted_root_task_run_id: activeNextRoot.rootTaskRunId,
    });
    expect(await capacityForSession(db, sessionId)).toEqual({
      active: 50, limit: 50, available: 0, awaiting: 0,
    });
  }, 180_000);

  it.each([
    {
      label: "success already canonical",
      canonicalStatus: "completed",
      callerOutcome: "failed",
      expectedOutcome: "completed",
      canonicalError: null,
      expectedSummary: "Canonical completed response",
    },
    {
      label: "failure already canonical",
      canonicalStatus: "failed",
      callerOutcome: "completed",
      expectedOutcome: "failed",
      canonicalError: "canonical provider failure",
      expectedSummary: "Failed: canonical provider failure",
    },
    {
      label: "cancellation already canonical",
      canonicalStatus: "cancelled",
      callerOutcome: "completed",
      expectedOutcome: "cancelled",
      canonicalError: null,
      expectedSummary: "Cancelled before finishing.",
    },
  ] as const)("reconciles a pre-terminal child run without contradiction: $label", async ({
    canonicalStatus,
    callerOutcome,
    expectedOutcome,
    canonicalError,
    expectedSummary,
  }) => {
    const fixture = await createFixture(`settlement_${canonicalStatus}`);
    cleanups.push(fixture.close);
    const { db, scratch, sessionId, userId } = fixture;
    const root = await createUserRoot(db, sessionId, `${canonicalStatus} root`);
    const [admitted] = await admitDispatches(db, requestsFor({
      sessionId, userId, rootTaskRunId: root.rootTaskRunId, batchId: newId(),
      count: 1, provenance: "server", promptPrefix: "pre-terminal",
    }));
    expect(admitted?.admission).toBe("admitted");
    if (canonicalStatus === "completed") {
      await messages.append(db, {
        sessionId: admitted!.childSessionId!,
        role: "assistant",
        content: "Canonical completed response",
      });
    }
    await scratch.client`
      UPDATE runs SET status = ${canonicalStatus}, finished_at = now(), last_error = ${canonicalError}
      WHERE id = ${admitted!.childRunId!}`;
    const [canonicalBefore] = await scratch.client`
      SELECT status, last_error, finished_at FROM runs WHERE id = ${admitted!.childRunId!}`;

    const settled = await settleAttemptAndMaybeWake(db, {
      attemptId: admitted!.attemptId!, outcome: callerOutcome,
    });
    expect(settled).toEqual({ rootTaskRunId: root.rootTaskRunId, shouldWake: false });

    const [canonicalAfter] = await scratch.client`
      SELECT status, last_error, finished_at FROM runs WHERE id = ${admitted!.childRunId!}`;
    expect(canonicalAfter).toEqual(canonicalBefore);
    expect(canonicalAfter).toMatchObject({ status: canonicalStatus, last_error: canonicalError });
    const lifecycle = await scratch.client`
      SELECT a.status AS attempt_status, w.status AS worker_status,
        r.status AS report_status, r.summary
      FROM subagent_attempts a
      JOIN subagent_logical_workers w ON w.id = a.logical_worker_id
      JOIN subagent_reports r ON r.attempt_id = a.id
      WHERE a.id = ${admitted!.attemptId!}`;
    expect(lifecycle).toHaveLength(1);
    expect(lifecycle[0]).toMatchObject({
      attempt_status: expectedOutcome,
      worker_status: expectedOutcome,
      report_status: expectedOutcome,
      summary: expectedSummary,
    });
    const reports = await drainReports(db, { sessionId, limit: 10 });
    expect(reports.items).toHaveLength(1);
    expect(reports.items[0]).toMatchObject({
      attemptId: admitted!.attemptId,
      childRunId: admitted!.childRunId,
      status: expectedOutcome,
      summary: expectedSummary,
    });
    expect((await scratch.client`
      SELECT count(*)::int AS count FROM subagent_reports
      WHERE attempt_id = ${admitted!.attemptId!}`)[0]).toEqual({ count: 1 });
  }, 180_000);

  it("persists all 50 reports in bounded cursor pages and fences duplicate wake/finalization", async () => {
    const fixture = await createFixture("admission_reports");
    cleanups.push(fixture.close);
    const { db, scratch, sessionId, userId } = fixture;
    const root = await createUserRoot(db, sessionId, "Report root");
    const admitted = await admitDispatches(db, requestsFor({
      sessionId, userId, rootTaskRunId: root.rootTaskRunId, batchId: newId(),
      count: 50, provenance: "web", promptPrefix: "report",
    }));
    expect(admitted.every((outcome) => outcome.admission === "admitted")).toBe(true);
    expect(await beforeRootFinalResponse(db, {
      rootTaskRunId: root.rootTaskRunId, executionEpoch: 1,
    })).toBe("wait");
    await scratch.client`UPDATE runs SET status = 'completed', finished_at = now() WHERE id = ${root.rootTaskRunId}`;

    const outcomes = ["completed", "failed", "cancelled", "timeout"] as const;
    const settlements = await Promise.all(admitted.map((outcome, index) =>
      settleAttemptAndMaybeWake(db, { attemptId: outcome.attemptId!, outcome: outcomes[index % 4]! })));
    expect(settlements.filter((result) => result.shouldWake)).toHaveLength(1);
    expect(await capacityForSession(db, sessionId)).toEqual({
      active: 0, limit: 50, available: 50, awaiting: 0,
    });
    expect(await beforeRootFinalResponse(db, {
      rootTaskRunId: root.rootTaskRunId, executionEpoch: 1,
    })).toBe("allow");
    const finalSnapshot = await snapshotRootFinalization(db, {
      rootTaskRunId: root.rootTaskRunId,
    });
    expect(await markRootFinalized(db, {
      rootTaskRunId: root.rootTaskRunId,
      executionEpoch: 1,
      activeAttemptIds: [],
      expectedReportAttemptIds: finalSnapshot!.reports.map((report) => report.attemptId),
      expectedReportFingerprint: fingerprintRootFinalizationReports(finalSnapshot!.reports),
    })).toBe("committed");
    expect(await markRootFinalized(db, {
      rootTaskRunId: root.rootTaskRunId, executionEpoch: 1, activeAttemptIds: [],
    })).toBe("fenced");
    expect(await beforeRootFinalResponse(db, {
      rootTaskRunId: root.rootTaskRunId, executionEpoch: 1,
    })).toBe("wait");
    const repeated = await settleAttemptAndMaybeWake(db, {
      attemptId: admitted[0]!.attemptId!, outcome: "completed",
    });
    expect(repeated.shouldWake).toBe(false);

    const seen: string[] = [];
    let afterId: string | undefined;
    let pages = 0;
    do {
      const page = await drainReports(db, { sessionId, afterId, limit: 17 });
      pages += 1;
      expect(page.items.length).toBeLessThanOrEqual(17);
      for (const report of page.items) {
        expect(seen).not.toContain(report.attemptId);
        seen.push(report.attemptId);
        expect(report.logicalWorkerId).toEqual(expect.any(String));
        expect(report.childSessionId).toEqual(expect.any(String));
        expect(report.childRunId).toEqual(expect.any(String));
        expect(report.task).toContain("preserve the complete prompt");
        expect(report.summary.length).toBeGreaterThan(0);
        expect(report.summary.length).toBeLessThanOrEqual(4000);
        expect(report.at).toEqual(expect.any(Number));
        expect(outcomes).toContain(report.status);
      }
      afterId = page.nextCursor ?? undefined;
      if (page.nextCursor === null) break;
    } while (pages < 5);
    expect(pages).toBe(3);
    expect(seen).toHaveLength(50);
    await expect(drainReports(db, { sessionId, limit: 0 })).rejects.toThrow(RangeError);
    await expect(drainReports(db, { sessionId, limit: 51 })).rejects.toThrow(RangeError);
    expect((await scratch.client`SELECT count(*)::int AS count FROM subagent_reports WHERE session_id = ${sessionId}`)[0])
      .toEqual({ count: 50 });
  }, 180_000);

  it("preserves input positions when separate batches repeat an index", async () => {
    const fixture = await createFixture("admission_order");
    cleanups.push(fixture.close);
    const { db, scratch, sessionId, userId } = fixture;
    const root = await createUserRoot(db, sessionId, "Two batches");
    const first = requestsFor({
      sessionId, userId, rootTaskRunId: root.rootTaskRunId, batchId: newId(),
      count: 1, provenance: "web", promptPrefix: "first",
    })[0]!;
    const second = requestsFor({
      sessionId, userId, rootTaskRunId: root.rootTaskRunId, batchId: newId(),
      count: 1, provenance: "android", promptPrefix: "second",
    })[0]!;
    expect(first.index).toBe(second.index);
    const outcomes = await admitDispatches(db, [first, second]);
    expect(outcomes.map((outcome) => outcome.index)).toEqual([0, 0]);
    expect(outcomes.map((outcome) => outcome.admission)).toEqual(["admitted", "admitted"]);
    expect(outcomes[0]?.attemptId).not.toBe(outcomes[1]?.attemptId);
    expect(outcomes[0]?.childRunId).not.toBe(outcomes[1]?.childRunId);
    const stored = await scratch.client`
      SELECT d.id, a.id AS attempt_id FROM subagent_dispatches d
      JOIN subagent_logical_workers w ON w.request_id = d.id
      JOIN subagent_attempts a ON a.logical_worker_id = w.id
      WHERE d.id IN (${first.requestId}, ${second.requestId}) ORDER BY d.created_at, d.id`;
    expect(stored).toHaveLength(2);
    expect(outcomes.map((outcome) => outcome.attemptId).sort()).toEqual(
      stored.map((row) => row.attempt_id).sort(),
    );
  }, 180_000);

  it("allows a zero-admitted root to finalize without a worker wake and enforces one active attempt per worker in SQL", async () => {
    const fixture = await createFixture("admission_zero");
    cleanups.push(fixture.close);
    const { db, scratch, sessionId, userId } = fixture;
    const firstRoot = await createUserRoot(db, sessionId, "Fill capacity");
    const admitted = await admitDispatches(db, requestsFor({
      sessionId, userId, rootTaskRunId: firstRoot.rootTaskRunId, batchId: newId(),
      count: 50, provenance: "web",
    }));
    const zeroRoot = await createUserRoot(db, sessionId, "No slots root");
    const zeroBatchId = newId();
    const zero = await admitDispatches(db, requestsFor({
      sessionId, userId, rootTaskRunId: zeroRoot.rootTaskRunId, batchId: zeroBatchId,
      count: 2, provenance: "android", promptPrefix: "zero",
    }));
    expect(zero.map((outcome) => outcome.admission)).toEqual([
      "awaiting_next_user_task", "awaiting_next_user_task",
    ]);
    expect(zero.every((outcome) => outcome.childRunId === undefined)).toBe(true);
    expect((await scratch.client`SELECT request_count, admitted_count, deferred_count FROM subagent_batches WHERE id = ${zeroBatchId}`)[0])
      .toEqual({ request_count: 2, admitted_count: 0, deferred_count: 2 });
    expect(await beforeRootFinalResponse(db, {
      rootTaskRunId: zeroRoot.rootTaskRunId, executionEpoch: 1,
    })).toBe("allow");
    expect(await markRootFinalized(db, {
      rootTaskRunId: zeroRoot.rootTaskRunId,
      executionEpoch: 1,
      activeAttemptIds: [],
      expectedReportAttemptIds: [],
      expectedReportFingerprint: fingerprintRootFinalizationReports([]),
    })).toBe("committed");
    expect((await scratch.client`SELECT wake_requested_at, finalized_at FROM subagent_root_finalizations WHERE root_task_run_id = ${zeroRoot.rootTaskRunId}`)[0]?.wake_requested_at)
      .toBeNull();

    const source = admitted[0]!;
    const child = await sessions.create(db, userId, "duplicate-attempt-child");
    const prompt = await messages.append(db, { sessionId: child.id, role: "user", content: "duplicate" });
    const duplicateRun = await runs.create(db, { sessionId: child.id, promptMessageId: prompt.id });
    const attempt = (await scratch.client`
      SELECT logical_worker_id, root_task_run_id, admitted_at FROM subagent_attempts WHERE id = ${source.attemptId!}`)[0]!;
    await expect(scratch.client`
      INSERT INTO subagent_attempts
        (id, logical_worker_id, session_id, root_task_run_id, execution_epoch, attempt_number,
         child_session_id, child_run_id, prompt_message_id, status, admitted_at, started_at)
      VALUES (${newId()}, ${attempt.logical_worker_id}, ${sessionId}, ${attempt.root_task_run_id}, 1, 2,
        ${child.id}, ${duplicateRun.id}, ${prompt.id}, 'running', ${attempt.admitted_at}, now())`)
      .rejects.toMatchObject({ code: "23505" });
    expect((await scratch.client`SELECT count(*)::int AS count FROM subagent_attempts WHERE logical_worker_id = ${attempt.logical_worker_id}`)[0])
      .toEqual({ count: 1 });
  }, 180_000);

  it.each([
    { field: "summary" as const },
    { field: "structuredReport" as const },
  ])("fences $field enrichment at both root CAS boundaries and retries fresh content", async ({ field }) => {
    const fixture = await createFixture(`root_report_${field}_fence`);
    cleanups.push(fixture.close);
    const { db, scratch, sessionId, userId } = fixture;
    const root = await createUserRoot(db, sessionId, "root report fingerprint root");
    const [admitted] = await admitDispatches(db, requestsFor({
      sessionId, userId, rootTaskRunId: root.rootTaskRunId,
      batchId: newId(), count: 1, provenance: "server",
    }));
    expect(admitted).toMatchObject({ admission: "admitted" });
    await runs.finish(db, admitted!.childRunId!, "completed");
    await settleAttemptAndMaybeWake(db, {
      attemptId: admitted!.attemptId!, outcome: "completed",
    });
    const stale = await snapshotRootFinalization(db, { rootTaskRunId: root.rootTaskRunId });
    const expectedIds = stale!.reports.map((report) => report.attemptId);
    const staleFingerprint = fingerprintRootFinalizationReports(stale!.reports);
    if (field === "summary") {
      await scratch.client`
        UPDATE subagent_reports SET summary = 'enriched summary'
         WHERE attempt_id = ${admitted!.attemptId!}`;
    } else {
      await scratch.client`
        UPDATE subagent_reports SET structured_report = ${JSON.stringify({
          subagent_id: admitted!.childSessionId,
          status: "completed",
          files_modified: ["src/enriched.ts"],
          artifacts_created: [],
          key_findings: "enriched structured finding",
          error_if_any: null,
        })}::jsonb
         WHERE attempt_id = ${admitted!.attemptId!}`;
    }
    // Attempt ID/terminal identity did not change; both pre-response and final
    // CAS must nevertheless reject the stale report content snapshot.
    expect(await beforeRootFinalResponse(db, {
      rootTaskRunId: root.rootTaskRunId,
      executionEpoch: 1,
      expectedReportAttemptIds: expectedIds,
      expectedReportFingerprint: staleFingerprint,
    })).toBe("wait");
    expect(await markRootFinalized(db, {
      rootTaskRunId: root.rootTaskRunId,
      executionEpoch: 1,
      activeAttemptIds: [],
      expectedReportAttemptIds: expectedIds,
      expectedReportFingerprint: staleFingerprint,
    })).toBe("fenced");

    const fresh = await snapshotRootFinalization(db, { rootTaskRunId: root.rootTaskRunId });
    expect(fresh!.reports).toHaveLength(1);
    expect(field === "summary"
      ? fresh!.reports[0]!.summary
      : fresh!.reports[0]!.structuredReport?.key_findings)
      .toBe(field === "summary" ? "enriched summary" : "enriched structured finding");
    const freshFingerprint = fingerprintRootFinalizationReports(fresh!.reports);
    expect(freshFingerprint).not.toBe(staleFingerprint);
    expect(await beforeRootFinalResponse(db, {
      rootTaskRunId: root.rootTaskRunId,
      executionEpoch: 1,
      expectedReportAttemptIds: expectedIds,
      expectedReportFingerprint: freshFingerprint,
    })).toBe("allow");
    expect(await markRootFinalized(db, {
      rootTaskRunId: root.rootTaskRunId,
      executionEpoch: 1,
      activeAttemptIds: [],
      expectedReportAttemptIds: expectedIds,
      expectedReportFingerprint: freshFingerprint,
    })).toBe("committed");
  }, 180_000);

});
