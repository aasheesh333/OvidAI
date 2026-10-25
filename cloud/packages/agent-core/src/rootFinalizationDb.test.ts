// UNEXECUTED in fix round 1: heavy tests/Postgres verification is paused by user instruction.
import { afterEach, describe, expect, it } from "vitest";
import {
  admitDispatches,
  capacityForSession,
  createDb,
  drainReports,
  messages,
  migrate,
  newId,
  reconsiderDeferred,
  runs,
  sessions,
  users,
  type AdmissionOutcome,
  type AdmissionRequest,
  type Db,
  type SubagentReportRecord,
} from "@ovid/db";
import {
  createMigrationScratch,
  type MigrationScratch,
} from "../../db/src/migrationTestKit.js";
import {
  createRootFinalizationGate,
  type RootFinalizationStore,
} from "./rootFinalization.js";
import { createRootFinalizationDbStore } from "./rootFinalizationDb.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const MODEL_CONTEXT = {
  requestedModel: "parent/model",
  byokKeyId: "byok-key-id-only",
  byokModel: "provider/model",
} as const;

type CasPausePoint = "beforeRootFinalResponse" | "markRootFinalized";

interface Fixture {
  scratch: MigrationScratch;
  db: Db;
  userId: string;
  sessionId: string;
  rootTaskRunId: string;
  close(): Promise<void>;
}

interface Pause {
  entered: Promise<void>;
  released: Promise<void>;
  markEntered(): void;
  release(): void;
}

function pause(): Pause {
  let markEntered!: () => void;
  let release!: () => void;
  const entered = new Promise<void>((resolve) => { markEntered = resolve; });
  const released = new Promise<void>((resolve) => { release = resolve; });
  return { entered, released, markEntered, release };
}

async function createUserRoot(db: Db, sessionId: string, text: string): Promise<string> {
  const prompt = await messages.append(db, { sessionId, role: "user", content: text });
  const run = await runs.create(db, { sessionId, promptMessageId: prompt.id });
  expect(await runs.claimNext(db, run.id)).toBe(true);
  return run.id;
}

async function createFixture(prefix: string): Promise<Fixture> {
  const scratch = await createMigrationScratch(TEST_DATABASE_URL!, prefix);
  await migrate(scratch.url);
  const db = createDb(scratch.url, { max: 8 });
  const userId = `${prefix}-user`;
  await users.ensure(db, userId, null);
  const session = await sessions.create(db, userId, prefix);
  const rootTaskRunId = await createUserRoot(db, session.id, `${prefix} root`);
  const fixture: Fixture = {
    scratch,
    db,
    userId,
    sessionId: session.id,
    rootTaskRunId,
    async close() {
      await fixture.db.$client.end({ timeout: 5 });
      await scratch.close();
    },
  };
  return fixture;
}

function requestFor(
  fixture: Fixture,
  rootTaskRunId: string,
  prompt: string,
  index = 0,
  batchId = newId(),
): AdmissionRequest {
  return {
    requestId: newId(),
    index,
    sessionId: fixture.sessionId,
    userId: fixture.userId,
    rootTaskRunId,
    parentRunId: rootTaskRunId,
    batchId,
    prompt,
    provenance: "web",
    requestedAt: new Date(),
    modelContext: { ...MODEL_CONTEXT, actorUserId: fixture.userId },
  };
}

async function admitOne(
  fixture: Fixture,
  rootTaskRunId: string,
  prompt: string,
): Promise<AdmissionOutcome> {
  const [outcome] = await admitDispatches(fixture.db, [
    requestFor(fixture, rootTaskRunId, prompt),
  ]);
  expect(outcome?.admission).toBe("admitted");
  if (outcome === undefined) throw new Error("missing admission outcome");
  return outcome;
}

async function drainAll(db: Db, sessionId: string): Promise<SubagentReportRecord[]> {
  const items: SubagentReportRecord[] = [];
  let afterId: string | undefined;
  do {
    const page = await drainReports(db, {
      sessionId,
      limit: 2,
      ...(afterId !== undefined ? { afterId } : {}),
    });
    items.push(...page.items);
    afterId = page.nextCursor ?? undefined;
  } while (afterId !== undefined);
  return items;
}

/** Pause after the real before CAS, or immediately before the real final CAS. */
function pausedStore(
  base: RootFinalizationStore,
  point: CasPausePoint,
  control: Pause,
): RootFinalizationStore {
  return {
    ...base,
    async beforeRootFinalResponse(input) {
      const result = await base.beforeRootFinalResponse(input);
      if (point === "beforeRootFinalResponse") {
        control.markEntered();
        await control.released;
      }
      return result;
    },
    async markRootFinalized(input) {
      if (point === "markRootFinalized") {
        control.markEntered();
        await control.released;
      }
      return base.markRootFinalized(input);
    },
  };
}

/** Fail after a real before CAS or before the real final CAS can commit. */
function failedStore(base: RootFinalizationStore, point: CasPausePoint): RootFinalizationStore {
  return {
    ...base,
    async beforeRootFinalResponse(input) {
      const result = await base.beforeRootFinalResponse(input);
      if (point === "beforeRootFinalResponse") {
        throw new Error("injected failure after real beforeRootFinalResponse");
      }
      return result;
    },
    async markRootFinalized(input) {
      if (point === "markRootFinalized") {
        throw new Error("injected failure before real markRootFinalized");
      }
      return base.markRootFinalized(input);
    },
  };
}

describe.skipIf(!TEST_DATABASE_URL).sequential("real Task 5 root finalization adapter", () => {
  const cleanups: Array<() => Promise<void>> = [];
  afterEach(async () => {
    await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()));
  }, 30_000);

  it.each(["beforeRootFinalResponse", "markRootFinalized"] as const)(
    "fences same-epoch admit -> settle ABA at %s and then includes the new report",
    async (point) => {
      const fixture = await createFixture(`aba_${point}`);
      cleanups.push(fixture.close);
      const { db, rootTaskRunId } = fixture;
      const base = createRootFinalizationDbStore(db);
      const gate = createRootFinalizationGate(base);
      const first = await admitOne(fixture, rootTaskRunId, "old settled work");
      expect(await runs.finish(db, rootTaskRunId, "completed")).toBe(true);
      const initial = await gate.settle({
        attemptId: first.attemptId!,
        outcome: "completed",
      });
      expect(initial.wake).toEqual({ trigger: "parent_wake", rootTaskRunId });

      const control = pause();
      const stalePromise = createRootFinalizationGate(pausedStore(base, point, control))
        .finalize(rootTaskRunId);
      await control.entered;
      const second = await admitOne(fixture, rootTaskRunId, "new admitted and settled work");
      // Task 5 deliberately retains epoch 1; the report fence, not an epoch
      // increment, must reject the stale pre-admission response snapshot.
      const secondSettlement = await gate.settle({
        attemptId: second.attemptId!,
        outcome: "failed",
      });
      expect(secondSettlement.rootTaskRunId).toBe(rootTaskRunId);
      control.release();

      const stale = await stalePromise;
      expect(stale.status).toBe("fenced");
      if (stale.status === "committed") throw new Error("stale response was authorized");
      expect(stale.snapshot.reports.map((report) => report.attemptId)).toEqual([first.attemptId]);

      const legitimate = await gate.finalize(rootTaskRunId);
      expect(legitimate.status).toBe("committed");
      if (legitimate.status !== "committed") throw new Error("fresh response was fenced");
      expect(legitimate.snapshot.executionEpoch).toBe(1);
      expect(legitimate.snapshot.activeAttemptIds).toEqual([]);
      expect(legitimate.snapshot.reports.map((report) => report.attemptId).sort()).toEqual([
        first.attemptId,
        second.attemptId,
      ].sort());
      expect(legitimate.snapshot.reports.find((report) => report.attemptId === second.attemptId))
        .toMatchObject({ status: "failed" });
      const drained = await drainAll(db, fixture.sessionId);
      expect(drained.map((report) => report.attemptId).sort()).toEqual([
        first.attemptId,
        second.attemptId,
      ].sort());
      expect((await gate.finalize(rootTaskRunId)).status).toBe("fenced");
      const finalRows = await fixture.scratch.client`
        SELECT execution_epoch, finalized_at FROM subagent_root_finalizations
        WHERE root_task_run_id = ${rootTaskRunId} AND finalized_at IS NOT NULL`;
      expect(finalRows).toHaveLength(1);
      expect(finalRows[0]?.execution_epoch).toBe(1);
    },
    180_000,
  );

  it("uses the real before CAS wait when activity arrives before its invocation", async () => {
    const fixture = await createFixture("before_wait");
    cleanups.push(fixture.close);
    const { db, rootTaskRunId } = fixture;
    const base = createRootFinalizationDbStore(db);
    const gate = createRootFinalizationGate(base);
    const first = await admitOne(fixture, rootTaskRunId, "old work");
    await gate.settle({ attemptId: first.attemptId!, outcome: "completed" });
    const control = pause();
    const pausedBefore: RootFinalizationStore = {
      ...base,
      async beforeRootFinalResponse(input) {
        control.markEntered();
        await control.released;
        return base.beforeRootFinalResponse(input);
      },
    };
    const pending = createRootFinalizationGate(pausedBefore).finalize(rootTaskRunId);
    await control.entered;
    const second = await admitOne(fixture, rootTaskRunId, "activity before before CAS");
    control.release();
    expect((await pending).status).toBe("wait");
    const finalRows = await fixture.scratch.client`
      SELECT count(*)::int AS count FROM subagent_root_finalizations
      WHERE root_task_run_id = ${rootTaskRunId} AND finalized_at IS NOT NULL`;
    expect(finalRows[0]?.count).toBe(0);

    await gate.settle({ attemptId: second.attemptId!, outcome: "failed" });
    const committed = await gate.finalize(rootTaskRunId);
    expect(committed.status).toBe("committed");
    if (committed.status !== "committed") throw new Error("fresh response was fenced");
    expect(committed.snapshot.reports.map((report) => report.attemptId).sort()).toEqual([
      first.attemptId,
      second.attemptId,
    ].sort());
  }, 180_000);

  it.each(["beforeRootFinalResponse", "markRootFinalized"] as const)(
    "does not commit after a real CAS failure at %s and retries once",
    async (point) => {
      const fixture = await createFixture(`failure_${point}`);
      cleanups.push(fixture.close);
      const { db, rootTaskRunId } = fixture;
      const base = createRootFinalizationDbStore(db);
      const gate = createRootFinalizationGate(base);
      const admitted = await admitOne(fixture, rootTaskRunId, "failure retry work");
      await gate.settle({ attemptId: admitted.attemptId!, outcome: "completed" });

      await expect(createRootFinalizationGate(failedStore(base, point)).finalize(rootTaskRunId))
        .rejects.toThrow(point === "beforeRootFinalResponse"
          ? "injected failure after real beforeRootFinalResponse"
          : "injected failure before real markRootFinalized");
      const beforeRetry = await fixture.scratch.client`
        SELECT count(*)::int AS count FROM subagent_root_finalizations
        WHERE root_task_run_id = ${rootTaskRunId} AND finalized_at IS NOT NULL`;
      expect(beforeRetry[0]?.count).toBe(0);

      expect((await gate.finalize(rootTaskRunId)).status).toBe("committed");
      expect((await gate.finalize(rootTaskRunId)).status).toBe("fenced");
      expect((await drainAll(db, fixture.sessionId)).map((report) => report.attemptId))
        .toEqual([admitted.attemptId]);
    },
    180_000,
  );

  it("keeps real settlement/report and finalization retries idempotent after a crash", async () => {
    const fixture = await createFixture("crash_retry");
    cleanups.push(fixture.close);
    const { db, rootTaskRunId } = fixture;
    const base = createRootFinalizationDbStore(db);
    const gate = createRootFinalizationGate(base);
    const admitted = await admitOne(fixture, rootTaskRunId, "crash retry work");
    expect(await runs.finish(db, rootTaskRunId, "completed")).toBe(true);
    const crashing = createRootFinalizationGate({
      ...base,
      async settleAttemptAndMaybeWake() {
        throw new Error("injected crash before real settlement");
      },
    });
    await expect(crashing.settle({ attemptId: admitted.attemptId!, outcome: "failed" }))
      .rejects.toThrow("injected crash before real settlement");
    expect(await drainAll(db, fixture.sessionId)).toEqual([]);

    const settled = await gate.settle({ attemptId: admitted.attemptId!, outcome: "failed" });
    expect(settled.wake).toEqual({ trigger: "parent_wake", rootTaskRunId });
    expect((await gate.settle({ attemptId: admitted.attemptId!, outcome: "completed" })).wake)
      .toBeNull();
    const reports = await drainAll(db, fixture.sessionId);
    expect(reports).toHaveLength(1);
    expect(reports[0]).toMatchObject({ attemptId: admitted.attemptId, status: "failed" });

    expect((await gate.finalize(rootTaskRunId)).status).toBe("committed");
    expect((await gate.finalize(rootTaskRunId)).status).toBe("fenced");
    expect(await drainAll(db, fixture.sessionId)).toHaveLength(1);
  }, 180_000);

  it("finalizes a real zero-admitted deferred root without wake or auto-start", async () => {
    const fixture = await createFixture("deferred_zero");
    cleanups.push(fixture.close);
    const { db, rootTaskRunId, sessionId } = fixture;
    const fillBatch = newId();
    const fill = await admitDispatches(db, Array.from({ length: 50 }, (_, index) =>
      requestFor(fixture, rootTaskRunId, `fill ${index}`, index, fillBatch)));
    expect(fill.every((outcome) => outcome.admission === "admitted")).toBe(true);
    const deferredRoot = await createUserRoot(db, sessionId, "zero admitted deferred root");
    const [deferred] = await admitDispatches(db, [
      requestFor(fixture, deferredRoot, "wait for a later user task"),
    ]);
    expect(deferred).toMatchObject({ admission: "awaiting_next_user_task" });
    expect(deferred?.attemptId).toBeUndefined();

    const gate = createRootFinalizationGate(createRootFinalizationDbStore(db));
    const result = await gate.finalize(deferredRoot);
    expect(result).toMatchObject({
      status: "committed",
      snapshot: { executionEpoch: 1, activeAttemptIds: [], reports: [] },
    });
    const finalRow = await fixture.scratch.client`
      SELECT wake_requested_at, finalized_at FROM subagent_root_finalizations
      WHERE root_task_run_id = ${deferredRoot}`;
    expect(finalRow[0]?.wake_requested_at).toBeNull();
    expect(finalRow[0]?.finalized_at).not.toBeNull();
    expect((await gate.finalize(rootTaskRunId)).status).toBe("wait");
    expect(await capacityForSession(db, sessionId)).toMatchObject({ active: 50, awaiting: 1 });
    expect(await drainAll(db, sessionId)).toEqual([]);
    const reconsidered = await reconsiderDeferred(db, {
      sessionId,
      rootTaskRunId: deferredRoot,
      requestIds: [deferred!.deferredRequestId!],
      actorRunId: deferredRoot,
      schedulingReason: "completion alone is not a later user task",
    });
    expect(reconsidered[0]).toMatchObject({
      admission: "refused",
      code: "next_user_task_required",
    });

    const [late] = await admitDispatches(db, [
      requestFor(fixture, deferredRoot, "must not reopen finalized root"),
    ]);
    expect(late).toMatchObject({ admission: "refused", code: "root_finalized" });
    const attempts = await fixture.scratch.client`
      SELECT count(*)::int AS count FROM subagent_attempts WHERE root_task_run_id = ${deferredRoot}`;
    expect(attempts[0]?.count).toBe(0);
  }, 180_000);

  it("isolates real roots and retains failed, stopped, and timeout reports", async () => {
    const fixture = await createFixture("independent_roots");
    cleanups.push(fixture.close);
    const { db, rootTaskRunId: rootA, sessionId } = fixture;
    const rootB = await createUserRoot(db, sessionId, "independent root B");
    const failed = await admitOne(fixture, rootA, "failed work");
    const stopped = await admitOne(fixture, rootA, "stopped work");
    const timeout = await admitOne(fixture, rootB, "timeout work");
    expect(await runs.finish(db, rootA, "completed")).toBe(true);
    expect(await runs.finish(db, rootB, "completed")).toBe(true);
    const gate = createRootFinalizationGate(createRootFinalizationDbStore(db));

    const settledA = await Promise.all([
      gate.settle({ attemptId: failed.attemptId!, outcome: "failed" }),
      gate.settle({ attemptId: stopped.attemptId!, outcome: "cancelled" }),
    ]);
    const settledB = await gate.settle({ attemptId: timeout.attemptId!, outcome: "timeout" });
    expect(settledA.filter((result) => result.wake !== null)).toHaveLength(1);
    expect(settledB.wake).toEqual({ trigger: "parent_wake", rootTaskRunId: rootB });

    const [finalA, finalB] = await Promise.all([gate.finalize(rootA), gate.finalize(rootB)]);
    expect(finalA.status).toBe("committed");
    expect(finalB.status).toBe("committed");
    if (finalA.status !== "committed" || finalB.status !== "committed") {
      throw new Error("independent roots did not commit");
    }
    expect(finalA.snapshot.reports.map((report) => report.attemptId).sort()).toEqual([
      failed.attemptId,
      stopped.attemptId,
    ].sort());
    expect(finalB.snapshot.reports.map((report) => report.attemptId)).toEqual([timeout.attemptId]);
    const reports = await drainAll(db, sessionId);
    expect(reports.map((report) => [report.attemptId, report.status]).sort()).toEqual([
      [failed.attemptId, "failed"],
      [stopped.attemptId, "cancelled"],
      [timeout.attemptId, "timeout"],
    ].sort());
    expect(reports.find((report) => report.attemptId === failed.attemptId)?.summary)
      .toBe("Failed: Subagent failed.");
    expect(reports.find((report) => report.attemptId === stopped.attemptId)?.summary)
      .toBe("Cancelled before finishing.");
    expect(reports.find((report) => report.attemptId === timeout.attemptId)?.summary)
      .toBe("Timed out before finishing.");
  }, 180_000);
});
