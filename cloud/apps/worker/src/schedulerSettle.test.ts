import { Redis } from "ioredis";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import {
  createDb,
  createSchedule,
  eventMirror,
  messages,
  migrate,
  runs,
  scheduleRuns,
  schedules,
  sessions,
  users,
  type Db,
  type ScheduleRow,
  type ScheduleTrigger,
} from "@ovid/db";
import { createRedisEventLog, type EventLog, type SystemBus } from "@ovid/events";
import type { SessionEvent, SystemEvent } from "@ovid/shared";
import type { Notifier } from "./notify.js";
import { sweepStaleRuns } from "./staleRuns.js";
import {
  SCHEDULE_ENQUEUE_LOST_MS,
  RETRYABLE_RUN_CODES,
  classifyRunFailure,
  settleScheduleRuns,
  type SettleDeps,
} from "./schedulerSettle.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

// Same pinned PAST base as schedulerTick.test.ts — 2020-09-13, below every
// other suite's 2023 base and the real clock. Two effects: (1) stale-arm rows
// other suites leave behind (2026-epoch startedAt) are NEVER stale under this
// clock, and (2) this suite's own leftovers are deterministic across re-runs
// (the clock is a constant, so "startedAt = T-1s" means the same instant on
// every run). The terminal-arm hygiene (foreign rows whose run already went
// completed/failed/cancelled) is handled by the beforeAll drain below.
const BASE = 1_600_000_000_000;
const iso = (ms: number): string => new Date(ms).toISOString();

// ---------------------------------------------------------------------------
// Pure pins (no db): the classification formula + the pinned constants.
// ---------------------------------------------------------------------------

describe("classifyRunFailure + pinned constants (pure)", () => {
  it("retryable exactly for RETRYABLE_RUN_CODES; code passthrough; null/empty → unknown", () => {
    expect(RETRYABLE_RUN_CODES).toEqual(["model_transient_exhausted", "run_lost"]);
    expect(SCHEDULE_ENQUEUE_LOST_MS).toBe(120_000);

    expect(classifyRunFailure("model_transient_exhausted")).toEqual({
      retryable: true,
      code: "model_transient_exhausted",
    });
    expect(classifyRunFailure("run_lost")).toEqual({ retryable: true, code: "run_lost" });

    expect(classifyRunFailure("key_not_minted")).toEqual({
      retryable: false,
      code: "key_not_minted",
    });
    expect(classifyRunFailure("model_terminal")).toEqual({
      retryable: false,
      code: "model_terminal",
    });
    expect(classifyRunFailure("hydrate_failed")).toEqual({
      retryable: false,
      code: "hydrate_failed",
    });
    expect(classifyRunFailure(null)).toEqual({ retryable: false, code: "unknown" });
    expect(classifyRunFailure("")).toEqual({ retryable: false, code: "unknown" });
  });
});

// ---------------------------------------------------------------------------
// Integration (real Postgres + real Redis event log, injected clock)
// ---------------------------------------------------------------------------

/** Capturing SystemBus stub — records every published SystemEvent. */
function stubSystem(): { system: SystemBus; published: Array<{ uid: string; event: SystemEvent }> } {
  const published: Array<{ uid: string; event: SystemEvent }> = [];
  const system = {
    async publish(uid: string, event: SystemEvent) {
      published.push({ uid, event });
    },
    async subscribe() {
      return async () => {};
    },
  } as unknown as SystemBus;
  return { system, published };
}

/** Capturing Notifier stub — records pushes; optionally throws on succeeded. */
function stubNotifier(
  behavior: { throwOnSucceeded?: boolean } = {},
): {
  notifier: Notifier;
  succeeded: Array<{ userId: string; scheduleId: string; sessionId: string; title: string; summary: string | null }>;
  failed: Array<{ userId: string; scheduleId: string; sessionId: string; title: string; code: string; error: string | null }>;
} {
  const succeeded: Array<{
    userId: string;
    scheduleId: string;
    sessionId: string;
    title: string;
    summary: string | null;
  }> = [];
  const failed: Array<{
    userId: string;
    scheduleId: string;
    sessionId: string;
    title: string;
    code: string;
    error: string | null;
  }> = [];
  const notifier = {
    async notifyScheduleSucceeded(a: (typeof succeeded)[number]) {
      if (behavior.throwOnSucceeded) throw new Error("push exploded");
      succeeded.push(a);
    },
    async notifyScheduleFailed(a: (typeof failed)[number]) {
      failed.push(a);
    },
    async notifyApprovalRequest() {},
  } as unknown as Notifier;
  return { notifier, succeeded, failed };
}

/**
 * EventLog wrapper around the REAL redis event log that records every append
 * (production seam transparency: settle's emit is events.append THEN
 * eventMirror.put, so the mirror verification below goes through the exact
 * production path — real stream id, real mirror row).
 */
function capturingEvents(base: EventLog): {
  events: EventLog;
  appended: Array<{ sessionId: string; type: string; payload: Record<string, unknown> }>;
} {
  const appended: Array<{ sessionId: string; type: string; payload: Record<string, unknown> }> =
    [];
  const events: EventLog = {
    async append(sessionId, type, payload) {
      appended.push({ sessionId, type, payload });
      return base.append(sessionId, type, payload);
    },
    readSince(sessionId, lastSeq, limit) {
      return base.readSince(sessionId, lastSeq, limit);
    },
    subscribe(sessionId, onEvent) {
      return base.subscribe(sessionId, onEvent);
    },
  };
  return { events, appended };
}

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)(
  "settleScheduleRuns (real Postgres, injected clock)",
  () => {
    let db: Db;
    let redisQ: Redis;
    let events: EventLog;
    let appended: Array<{ sessionId: string; type: string; payload: Record<string, unknown> }>;
    /** Everything this suite seeds; cleaned up in afterEach. */
    const createdScheduleIds: string[] = [];
    const createdSessionIds: string[] = [];
    let counter = 0;

    beforeAll(async () => {
      await migrate(TEST_DATABASE_URL!);
      db = createDb(TEST_DATABASE_URL!);
      redisQ = new Redis(TEST_REDIS_URL!);
      const real = createRedisEventLog(redisQ);
      const captured = capturingEvents(real);
      events = captured.events;
      appended = captured.appended;

      // Shared-dev-DB hygiene (the terminal arm is clock-INDEPENDENT, so a
      // past clock alone cannot hide other suites' leftovers): drain every
      // pre-existing settleable row with fully-stubbed side effects so this
      // suite's exact-count pins are exact. The rows drained here are garbage
      // by definition — the production settle pass would consume them the
      // same way on the first tick after this code ships.
      let drainSeq = 0;
      const drainEvents: EventLog = {
        async append(sessionId, type, payload) {
          drainSeq += 1;
          const e: SessionEvent = {
            sessionId,
            seq: `0-${drainSeq}`,
            type,
            payload,
            ts: new Date().toISOString(),
          };
          return e;
        },
        async readSince() {
          return [];
        },
        async subscribe() {
          return async () => {};
        },
      };
      const drainNotifier = {
        async notifyScheduleSucceeded() {},
        async notifyScheduleFailed() {},
        async notifyApprovalRequest() {},
      } as unknown as Notifier;
      const drainSystem = {
        async publish() {},
        async subscribe() {
          return async () => {};
        },
      } as unknown as SystemBus;
      await settleScheduleRuns({
        db,
        events: drainEvents,
        system: drainSystem,
        notifier: drainNotifier,
      });
    });

    afterEach(async () => {
      // Cancelled rows are invisible to claimDue; a terminalized occurrence
      // is never settleable again — leftovers can never fire on a re-run.
      for (const scheduleId of createdScheduleIds) {
        await schedules.update(db, scheduleId, { status: "cancelled" }).catch(() => {});
      }
      if (createdScheduleIds.length > 0) {
        await db
          .$client.unsafe(
            "UPDATE schedule_runs SET status = 'skipped' WHERE schedule_id = ANY($1::text[]) AND status = 'running'",
            [createdScheduleIds],
          )
          .catch(() => {});
      }
      if (createdSessionIds.length > 0) {
        await db
          .$client.unsafe(
            "UPDATE runs SET status = 'completed' WHERE session_id = ANY($1::text[]) AND status IN ('queued','running')",
            [createdSessionIds],
          )
          .catch(() => {});
      }
    });

    afterAll(async () => {
      // Only keys/rows THIS suite created (shared dev redis + db — no
      // FLUSHDB, other suites' data untouched).
      if (createdSessionIds.length > 0) {
        await redisQ
          .del(...createdSessionIds.map((id) => `sess:${id}:events`))
          .catch(() => {});
        await db
          .$client.unsafe("DELETE FROM session_event_mirror WHERE session_id = ANY($1::text[])", [
            createdSessionIds,
          ])
          .catch(() => {});
      }
      redisQ?.disconnect();
      await db?.$client.end({ timeout: 5 });
    });

    const uid = (prefix: string): string => {
      counter += 1;
      return `${prefix}-${Date.now().toString(36)}-${counter}-${Math.random()
        .toString(36)
        .slice(2, 10)}`;
    };

    /** Fresh user + dedicated session + schedule via the domain service. */
    async function seedSchedule(
      trigger: ScheduleTrigger,
      opts: { at: number; title?: string; description?: string; maxRetries?: number },
    ): Promise<ScheduleRow> {
      const userId = uid("w9u");
      await users.ensure(db, userId, `${userId}@stub.test`);
      const row = await createSchedule(db, {
        userId,
        title: opts.title ?? "Report",
        description: opts.description ?? "check inbox",
        trigger,
        maxRetries: opts.maxRetries,
        clock: () => new Date(opts.at),
      });
      createdScheduleIds.push(row.id);
      createdSessionIds.push(row.sessionId);
      return row;
    }

    /**
     * The exact state the firing engine leaves behind: a claimed `running`
     * occurrence bound to a run row, with the run's terminal status (or left
     * non-terminal), an optional assistant reply, and optional row overrides
     * for the stale/orphan/exhaustion arms.
     */
    async function seedOccurrence(
      schedule: ScheduleRow,
      opts: {
        scheduledFor: number;
        ranLate?: boolean;
        finishRun?: "completed" | "failed" | "cancelled";
        runError?: string | null;
        assistant?: string;
        /** Overrides sr.started_at (orphan / queued-stale seeding). */
        startedAt?: number;
        /** Orphan recovery arm: sr.run_id = NULL. */
        nullRunId?: boolean;
        /** Exhaustion arm: sr.attempt = N (the ladder after N-1 retries). */
        attempt?: number;
        /** Leave the run non-terminal in this status instead. */
        runStatus?: "queued" | "running";
      },
    ): Promise<{ scheduleRunId: string; runId: string }> {
      const prompt = await messages.append(db, {
        sessionId: schedule.sessionId,
        role: "user",
        content: "go",
      });
      const run = await runs.create(db, {
        sessionId: schedule.sessionId,
        promptMessageId: prompt.id,
      });
      const claimed = await scheduleRuns.claim(db, {
        scheduleId: schedule.id,
        scheduledFor: new Date(opts.scheduledFor),
        runId: run.id,
        ranLate: opts.ranLate ?? false,
        sessionId: schedule.sessionId,
        triggerKind: schedule.trigger.kind,
      });
      expect(claimed).not.toBeNull();
      if (opts.finishRun !== undefined) {
        await runs.finish(db, run.id, opts.finishRun, opts.runError ?? null);
      } else if (opts.runStatus === "running") {
        await db.$client.unsafe("UPDATE runs SET status = 'running' WHERE id = $1", [run.id]);
      }
      if (opts.assistant !== undefined) {
        await messages.append(db, {
          sessionId: schedule.sessionId,
          role: "assistant",
          content: opts.assistant,
        });
      }
      if (opts.startedAt !== undefined) {
        await db.$client.unsafe("UPDATE schedule_runs SET started_at = $2 WHERE id = $1", [
          claimed!.id,
          new Date(opts.startedAt).toISOString(),
        ]);
      }
      if (opts.nullRunId === true) {
        await db.$client.unsafe("UPDATE schedule_runs SET run_id = NULL WHERE id = $1", [
          claimed!.id,
        ]);
      }
      if (opts.attempt !== undefined) {
        await db.$client.unsafe("UPDATE schedule_runs SET attempt = $2 WHERE id = $1", [
          claimed!.id,
          opts.attempt,
        ]);
      }
      return { scheduleRunId: claimed!.id, runId: run.id };
    }

    function makeDeps(
      clockMs: number,
      stubs: { system: SystemBus; notifier: Notifier },
      opts?: { staleAfterMs?: number },
    ): SettleDeps {
      return {
        db,
        events,
        system: stubs.system,
        notifier: stubs.notifier,
        clock: () => new Date(clockMs),
        ...(opts?.staleAfterMs !== undefined ? { staleAfterMs: opts.staleAfterMs } : {}),
      };
    }

    /** Occurrence rows for a schedule, OLDEST first (listForSchedule is newest-first). */
    async function scheduleRunsFor(scheduleId: string) {
      const { rows } = await scheduleRuns.listForSchedule(db, scheduleId, { limit: 50 });
      return [...rows].reverse();
    }

    const scheduleRow = (scheduleId: string): Promise<ScheduleRow | null> =>
      schedules.getById(db, scheduleId);

    async function messagesFor(sessionId: string) {
      const { rows } = await messages.page(db, sessionId, { limit: 50 });
      return rows; // newest first (UUIDv7 id order)
    }

    it("(a) success: summary from the newest assistant message; one-off completes; transcript note appended+mirrored; push + system publish", async () => {
      const T0 = BASE;
      const T1 = T0 + 600_000;
      // One-off, already fired (the tick nulled nextRunAt when it claimed).
      const oneOff = await seedSchedule({ kind: "at", at: iso(T0 + 300_000) }, { at: T0 });
      await schedules.update(db, oneOff.id, { nextRunAt: null });
      await seedOccurrence(oneOff, {
        scheduledFor: T0 + 300_000,
        finishRun: "completed",
        assistant: "Report ready",
      });

      const { system, published } = stubSystem();
      const { notifier, succeeded } = stubNotifier();
      expect(await settleScheduleRuns(makeDeps(T1, { system, notifier }))).toBe(1);

      const srs = await scheduleRunsFor(oneOff.id);
      expect(srs).toHaveLength(1);
      expect(srs[0]!.status).toBe("succeeded");

      const after = await scheduleRow(oneOff.id);
      expect(after!.status).toBe("completed");
      expect(after!.nextRunAt).toBeNull();
      expect(after!.lastResult).toEqual({
        status: "succeeded",
        code: null,
        message: null,
        finishedAt: iso(T1),
        ranLate: false,
      });

      expect(published).toHaveLength(1);
      expect(published[0]!.uid).toBe(oneOff.userId);
      expect(published[0]!.event.type).toBe("schedule_run_succeeded");
      expect(published[0]!.event.payload).toEqual({
        scheduleRunId: srs[0]!.id,
        scheduledFor: iso(T0 + 300_000),
        summary: "Report ready",
        scheduleCompleted: true,
        autoDeniedApprovals: 0,
      });

      expect(succeeded).toEqual([
        {
          userId: oneOff.userId,
          scheduleId: oneOff.id,
          sessionId: oneOff.sessionId,
          title: "Report",
          summary: "Report ready",
        },
      ]);

      // Transcript: system_note appended on the REAL event log AND mirrored.
      const notes = appended.filter(
        (e) =>
          e.sessionId === oneOff.sessionId &&
          e.type === "system_note" &&
          e.payload.scheduleRunId === srs[0]!.id,
      );
      expect(notes).toHaveLength(1);
      expect(notes[0]!.payload).toEqual({
        scheduleId: oneOff.id,
        scheduleRunId: srs[0]!.id,
        status: "succeeded",
      });
      const mirrored = await eventMirror.readSince(db, oneOff.sessionId, null, 50);
      expect(
        mirrored.some(
          (e) =>
            e.type === "system_note" &&
            e.payload.scheduleRunId === srs[0]!.id &&
            e.payload.status === "succeeded",
        ),
      ).toBe(true);

      // Recurring variant: stays pending, ranLate carries into lastResult.
      const recurring = await seedSchedule({ kind: "every", seconds: 300 }, { at: T0 });
      await seedOccurrence(recurring, {
        scheduledFor: T0 + 300_000,
        ranLate: true,
        finishRun: "completed",
        assistant: "Report ready",
      });
      const { system: sys2, published: pub2 } = stubSystem();
      const { notifier: n2, succeeded: ok2 } = stubNotifier();
      expect(await settleScheduleRuns(makeDeps(T1 + 1, { system: sys2, notifier: n2 }))).toBe(1);

      const after2 = await scheduleRow(recurring.id);
      expect(after2!.status).toBe("pending");
      expect(after2!.lastResult).toEqual({
        status: "succeeded",
        code: null,
        message: null,
        finishedAt: iso(T1 + 1),
        ranLate: true,
      });
      expect(pub2[0]!.event.payload.scheduleCompleted).toBe(false);
      expect(ok2[0]!.summary).toBe("Report ready");
    });

    it("(b) key_not_minted (Q5): final failure even with maxRetries:3; push carries the code; transcript row + note; one-off schedule failed", async () => {
      const T0 = BASE;
      const T1 = T0 + 600_000;
      const sched = await seedSchedule(
        { kind: "at", at: iso(T0 + 300_000) },
        { at: T0, maxRetries: 3 },
      );
      await schedules.update(db, sched.id, { nextRunAt: null });
      const seeded = await seedOccurrence(sched, {
        scheduledFor: T0 + 300_000,
        finishRun: "failed",
        runError: "key_not_minted",
      });

      const { system, published } = stubSystem();
      const { notifier, failed } = stubNotifier();
      expect(await settleScheduleRuns(makeDeps(T1, { system, notifier }))).toBe(1);

      const srs = await scheduleRunsFor(sched.id);
      expect(srs[0]!.status).toBe("failed");
      expect(srs[0]!.error).toBe("key_not_minted");

      const after = await scheduleRow(sched.id);
      expect(after!.status).toBe("failed");
      expect(after!.lastResult).toEqual({
        status: "failed",
        code: "key_not_minted",
        message: "key_not_minted",
        finishedAt: iso(T1),
        ranLate: false,
      });

      expect(failed).toEqual([
        {
          userId: sched.userId,
          scheduleId: sched.id,
          sessionId: sched.sessionId,
          title: "Report",
          code: "key_not_minted",
          error: "key_not_minted",
        },
      ]);

      // One system publish, willRetry false; a one-off never publishes paused.
      expect(published.map((p) => p.event.type)).toEqual(["schedule_run_failed"]);
      expect(published[0]!.event.payload).toEqual({
        scheduleRunId: seeded.scheduleRunId,
        scheduledFor: iso(T0 + 300_000),
        code: "key_not_minted",
        message: "key_not_minted",
        willRetry: false,
        retryAt: null,
        autoDeniedApprovals: 0,
      });

      // Transcript: the system message row + the system_note event.
      const msgs = await messagesFor(sched.sessionId);
      expect(msgs.some((m) => m.role === "system" && m.content === "Scheduled task failed: key_not_minted")).toBe(true);
      const notes = appended.filter(
        (e) => e.sessionId === sched.sessionId && e.type === "system_note",
      );
      expect(notes).toHaveLength(1);
      expect(notes[0]!.payload).toEqual({
        scheduleId: sched.id,
        scheduleRunId: seeded.scheduleRunId,
        status: "failed",
        code: "key_not_minted",
      });
    });

    it("(c) retry ladder: attempt 1 of maxRetries 2 → retry_scheduled at T+30s, NO push, NO transcript; immediate re-settle → 0 (idempotence pin)", async () => {
      const T0 = BASE;
      const T = T0 + 600_000;
      const sched = await seedSchedule(
        { kind: "at", at: iso(T0 + 300_000) },
        { at: T0, maxRetries: 2 },
      );
      await schedules.update(db, sched.id, { nextRunAt: null });
      const seeded = await seedOccurrence(sched, {
        scheduledFor: T0 + 300_000,
        finishRun: "failed",
        runError: "model_transient_exhausted",
      });

      const { system, published } = stubSystem();
      const { notifier, succeeded, failed } = stubNotifier();
      expect(await settleScheduleRuns(makeDeps(T, { system, notifier }))).toBe(1);

      const srs = await scheduleRunsFor(sched.id);
      expect(srs[0]).toMatchObject({
        status: "retry_scheduled",
        attempt: 2,
      });
      expect(srs[0]!.retryAt!.toISOString()).toBe(iso(T + 30_000));

      // Dart parity: intermediate retries notify nobody and write nothing.
      expect(succeeded).toHaveLength(0);
      expect(failed).toHaveLength(0);
      expect(await messagesFor(sched.sessionId)).toHaveLength(1); // just the prompt
      expect(appended.filter((e) => e.sessionId === sched.sessionId)).toHaveLength(0);

      expect(published.map((p) => p.event.type)).toEqual(["schedule_run_failed"]);
      expect(published[0]!.event.payload).toEqual({
        scheduleRunId: seeded.scheduleRunId,
        scheduledFor: iso(T0 + 300_000),
        code: "model_transient_exhausted",
        message: "model_transient_exhausted",
        willRetry: true,
        retryAt: iso(T + 30_000),
        autoDeniedApprovals: 0,
      });

      // The row is no longer settleable (status left 'running' behind), and
      // the schedule/lastResult were untouched by the retry pass.
      const after = await scheduleRow(sched.id);
      expect(after!.status).toBe("pending");
      expect(after!.lastResult).toBeNull();
      expect(await settleScheduleRuns(makeDeps(T, { system, notifier }))).toBe(0);
    });

    it("(d) exhaustion → pause: attempt 3 with maxRetries 2 → final; recurring paused retries_exhausted + schedule_run_paused + push", async () => {
      const T0 = BASE;
      const T = T0 + 600_000;
      const sched = await seedSchedule({ kind: "every", seconds: 300 }, { at: T0, maxRetries: 2 });
      const seeded = await seedOccurrence(sched, {
        scheduledFor: T0 + 300_000,
        finishRun: "failed",
        runError: "model_transient_exhausted",
        attempt: 3, // the ladder after two consumed retries: 3 <= 2 is false
      });

      const { system, published } = stubSystem();
      const { notifier, failed } = stubNotifier();
      expect(await settleScheduleRuns(makeDeps(T, { system, notifier }))).toBe(1);

      const srs = await scheduleRunsFor(sched.id);
      expect(srs[0]!.status).toBe("failed");
      expect(srs[0]!.error).toBe("model_transient_exhausted");

      const after = await scheduleRow(sched.id);
      expect(after!.status).toBe("paused");
      expect(after!.pausedReason).toBe("retries_exhausted");
      expect(after!.lastResult).toEqual({
        status: "failed",
        code: "model_transient_exhausted",
        message: "model_transient_exhausted",
        finishedAt: iso(T),
        ranLate: false,
      });

      const types = published.map((p) => p.event.type).sort();
      expect(types).toEqual(["schedule_run_failed", "schedule_run_paused"]);
      const failedEv = published.find((p) => p.event.type === "schedule_run_failed")!;
      expect(failedEv.event.payload).toEqual({
        scheduleRunId: seeded.scheduleRunId,
        scheduledFor: iso(T0 + 300_000),
        code: "model_transient_exhausted",
        message: "model_transient_exhausted",
        willRetry: false,
        retryAt: null,
        autoDeniedApprovals: 0,
      });
      const pausedEv = published.find((p) => p.event.type === "schedule_run_paused")!;
      expect(pausedEv.event.payload).toEqual({
        reason: "retries_exhausted",
        code: "model_transient_exhausted",
      });

      expect(failed).toHaveLength(1);
      expect(failed[0]!.code).toBe("model_transient_exhausted");
      const msgs = await messagesFor(sched.sessionId);
      expect(msgs.some((m) => m.role === "system" && m.content === "Scheduled task failed: model_transient_exhausted")).toBe(true);
    });

    it("(e) orphan recovery: run_id NULL past the stale window retries as run_lost (or finals at maxRetries 0); a fresh orphan is NOT settled", async () => {
      const T0 = BASE;
      const T = T0 + 600_000;
      // Retries remain → run_lost retry.
      const a = await seedSchedule({ kind: "at", at: iso(T0 + 300_000) }, { at: T0, maxRetries: 2 });
      await schedules.update(db, a.id, { nextRunAt: null });
      const aSeeded = await seedOccurrence(a, {
        scheduledFor: T0 + 300_000,
        startedAt: T - 121_000,
        nullRunId: true,
      });
      // No retries left → final run_lost failure.
      const b = await seedSchedule({ kind: "at", at: iso(T0 + 300_000) }, { at: T0, maxRetries: 0 });
      await schedules.update(db, b.id, { nextRunAt: null });
      const bSeeded = await seedOccurrence(b, {
        scheduledFor: T0 + 300_000,
        startedAt: T - 121_000,
        nullRunId: true,
      });
      // Fresh orphan: inside the stale window → not settleable.
      const c = await seedSchedule({ kind: "at", at: iso(T0 + 300_000) }, { at: T0, maxRetries: 2 });
      await schedules.update(db, c.id, { nextRunAt: null });
      await seedOccurrence(c, {
        scheduledFor: T0 + 300_000,
        startedAt: T - 1_000,
        nullRunId: true,
      });

      const { system, published } = stubSystem();
      const { notifier, failed } = stubNotifier();
      expect(await settleScheduleRuns(makeDeps(T, { system, notifier }))).toBe(2);

      const aSrs = await scheduleRunsFor(a.id);
      expect(aSrs[0]).toMatchObject({ status: "retry_scheduled", attempt: 2 });
      expect(aSrs[0]!.retryAt!.toISOString()).toBe(iso(T + 30_000));
      // Retry arm: no push, no transcript.
      expect(failed.some((f) => f.scheduleId === a.id)).toBe(false);
      expect(await messagesFor(a.sessionId)).toHaveLength(1);

      const bSrs = await scheduleRunsFor(b.id);
      expect(bSrs[0]!.status).toBe("failed");
      expect(bSrs[0]!.error).toBe("run_lost");
      expect((await scheduleRow(b.id))!.status).toBe("failed");
      expect(failed.some((f) => f.scheduleId === b.id && f.code === "run_lost")).toBe(true);
      const bMsgs = await messagesFor(b.sessionId);
      expect(bMsgs.some((m) => m.role === "system" && m.content === "Scheduled task failed: run_lost")).toBe(true);

      const runLostEvents = published.filter(
        (p) => p.event.type === "schedule_run_failed" && p.event.payload.code === "run_lost",
      );
      expect(runLostEvents.map((p) => p.event.payload.scheduleRunId).sort()).toEqual(
        [aSeeded.scheduleRunId, bSeeded.scheduleRunId].sort(),
      );
      expect(runLostEvents.find((p) => p.event.payload.scheduleRunId === aSeeded.scheduleRunId)!.event.payload.willRetry).toBe(true);
      expect(runLostEvents.find((p) => p.event.payload.scheduleRunId === bSeeded.scheduleRunId)!.event.payload.willRetry).toBe(false);

      // The fresh orphan is untouched, and a second pass settles nothing.
      const cSrs = await scheduleRunsFor(c.id);
      expect(cSrs[0]!.status).toBe("running");
      expect(await settleScheduleRuns(makeDeps(T, { system, notifier }))).toBe(0);
    });

    it("(f) queued-stale run → run_lost retry; a run still running is untouched", async () => {
      const T0 = BASE;
      const T = T0 + 600_000;
      const a = await seedSchedule({ kind: "every", seconds: 300 }, { at: T0, maxRetries: 1 });
      await seedOccurrence(a, {
        scheduledFor: T0 + 300_000,
        startedAt: T - 121_000,
        runStatus: "queued", // the run row exists but never left the queue
      });
      const b = await seedSchedule({ kind: "every", seconds: 300 }, { at: T0, maxRetries: 1 });
      await seedOccurrence(b, {
        scheduledFor: T0 + 300_000,
        startedAt: T - 121_000,
        runStatus: "running", // genuinely alive — never settleable
      });

      const { system, published } = stubSystem();
      const { notifier } = stubNotifier();
      expect(await settleScheduleRuns(makeDeps(T, { system, notifier }))).toBe(1);

      const aSrs = await scheduleRunsFor(a.id);
      expect(aSrs[0]).toMatchObject({ status: "retry_scheduled", attempt: 2 });
      expect(published[0]!.event.payload.code).toBe("run_lost");
      expect(published[0]!.event.payload.willRetry).toBe(true);

      const bSrs = await scheduleRunsFor(b.id);
      expect(bSrs[0]!.status).toBe("running");
      const bRun = (await db.$client.unsafe("SELECT status FROM runs WHERE id = $1", [
        bSrs[0]!.runId,
      ])) as Array<{ status: string }>;
      expect(bRun[0]!.status).toBe("running");
    });

    it("(g) cancelled run → final failure code cancelled, never retried even with maxRetries:3", async () => {
      const T0 = BASE;
      const T = T0 + 600_000;
      const sched = await seedSchedule(
        { kind: "at", at: iso(T0 + 300_000) },
        { at: T0, maxRetries: 3 },
      );
      await schedules.update(db, sched.id, { nextRunAt: null });
      const seeded = await seedOccurrence(sched, {
        scheduledFor: T0 + 300_000,
        finishRun: "cancelled",
      });

      const { system, published } = stubSystem();
      const { notifier, failed } = stubNotifier();
      expect(await settleScheduleRuns(makeDeps(T, { system, notifier }))).toBe(1);

      const srs = await scheduleRunsFor(sched.id);
      expect(srs[0]!.status).toBe("failed");
      expect(srs[0]!.error).toBe("cancelled");

      const after = await scheduleRow(sched.id);
      expect(after!.status).toBe("failed");
      expect(after!.lastResult).toEqual({
        status: "failed",
        code: "cancelled",
        message: null,
        finishedAt: iso(T),
        ranLate: false,
      });

      expect(published.map((p) => p.event.type)).toEqual(["schedule_run_failed"]);
      expect(published[0]!.event.payload).toMatchObject({
        scheduleRunId: seeded.scheduleRunId,
        code: "cancelled",
        message: null,
        willRetry: false,
        retryAt: null,
      });
      expect(failed).toEqual([
        {
          userId: sched.userId,
          scheduleId: sched.id,
          sessionId: sched.sessionId,
          title: "Report",
          code: "cancelled",
          error: null,
        },
      ]);
      const msgs = await messagesFor(sched.sessionId);
      expect(msgs.some((m) => m.role === "system" && m.content === "Scheduled task failed: cancelled")).toBe(true);
    });

    it("(h) autoDenied entries flow into the succeeded payload; no assistant message → summary null", async () => {
      const T0 = BASE;
      const T = T0 + 600_000;
      const sched = await seedSchedule({ kind: "every", seconds: 300 }, { at: T0 });
      const seeded = await seedOccurrence(sched, {
        scheduledFor: T0 + 300_000,
        finishRun: "completed", // newest message stays the user prompt
      });
      await scheduleRuns.appendAutoDenied(db, seeded.scheduleRunId, {
        toolName: "run_shell",
        summary: "rm -rf /",
        ts: iso(T0 + 300_001),
      });
      await scheduleRuns.appendAutoDenied(db, seeded.scheduleRunId, {
        toolName: "fetch_url",
        summary: "http://example.com",
        ts: iso(T0 + 300_002),
      });

      const { system, published } = stubSystem();
      const { notifier, succeeded } = stubNotifier();
      expect(await settleScheduleRuns(makeDeps(T, { system, notifier }))).toBe(1);

      expect(published[0]!.event.type).toBe("schedule_run_succeeded");
      expect(published[0]!.event.payload).toMatchObject({
        scheduleRunId: seeded.scheduleRunId,
        autoDeniedApprovals: 2,
        summary: null,
        scheduleCompleted: false,
      });
      expect(succeeded[0]!.summary).toBeNull();
    });

    it("(i) a throwing notifier never blocks the pass: bookkeeping first-class, push best-effort", async () => {
      const T0 = BASE;
      const T = T0 + 600_000;
      const sched = await seedSchedule({ kind: "at", at: iso(T0 + 300_000) }, { at: T0 });
      await schedules.update(db, sched.id, { nextRunAt: null });
      await seedOccurrence(sched, {
        scheduledFor: T0 + 300_000,
        finishRun: "completed",
        assistant: "Report ready",
      });

      const { system, published } = stubSystem();
      const { notifier } = stubNotifier({ throwOnSucceeded: true });
      const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
      // mockRestore() wipes mock.calls — the assertion must read them BEFORE
      // the restore (schedulerTick.test.ts case (i) convention).
      let sawSettleLog = false;
      try {
        expect(await settleScheduleRuns(makeDeps(T, { system, notifier }))).toBe(1);
        sawSettleLog = errSpy.mock.calls.some((c) => String(c[0]).includes("[settle]"));
      } finally {
        errSpy.mockRestore();
      }
      expect(sawSettleLog).toBe(true);

      // The row is FULLY settled despite the push blowing up.
      const srs = await scheduleRunsFor(sched.id);
      expect(srs[0]!.status).toBe("succeeded");
      const after = await scheduleRow(sched.id);
      expect(after!.status).toBe("completed");
      expect(after!.lastResult!.status).toBe("succeeded");
      // The rest of the reporting stack still ran.
      expect(published.filter((p) => p.event.type === "schedule_run_succeeded")).toHaveLength(1);
      expect(appended.filter((e) => e.sessionId === sched.sessionId)).toHaveLength(1);
    });

    it("(j) two overlapping settle passes race on one row: exactly one settles, exactly one notification set", async () => {
      const T0 = BASE;
      const T = T0 + 600_000;
      const sched = await seedSchedule({ kind: "at", at: iso(T0 + 300_000) }, { at: T0 });
      await schedules.update(db, sched.id, { nextRunAt: null });
      await seedOccurrence(sched, {
        scheduledFor: T0 + 300_000,
        finishRun: "completed",
        assistant: "Report ready",
      });

      const { system, published } = stubSystem();
      const { notifier, succeeded } = stubNotifier();
      const deps = makeDeps(T, { system, notifier });
      const [r1, r2] = await Promise.all([
        settleScheduleRuns(deps),
        settleScheduleRuns(deps),
      ]);
      expect(r1 + r2).toBe(1); // the FOR UPDATE + status re-check guards the loser
      expect(succeeded).toHaveLength(1);
      expect(published.filter((p) => p.event.type === "schedule_run_succeeded")).toHaveLength(1);
      const srs = await scheduleRunsFor(sched.id);
      expect(srs[0]!.status).toBe("succeeded");
    });

    it("(k) M3: a crashed-mid-run occurrence swept by the real stale sweeper retries (canonical run_lost)", async () => {
      const T0 = BASE;
      const T = T0 + 600_000;
      const sched = await seedSchedule(
        { kind: "at", at: iso(T0 + 300_000) },
        { at: T0, maxRetries: 2 },
      );
      await schedules.update(db, sched.id, { nextRunAt: null });
      const seeded = await seedOccurrence(sched, {
        scheduledFor: T0 + 300_000,
        runStatus: "running",
      });
      // The production crash shape: the run started, the worker died.
      await db.$client.unsafe(
        "UPDATE runs SET status = 'running', started_at = $2 WHERE id = $1",
        [seeded.runId, iso(T - 600_000)],
      );

      // The REAL sweeper (not a hand-written last_error) supplies the exact
      // DB value settle classifies.
      expect(
        await sweepStaleRuns({ db, events, clock: () => new Date(T) }, { staleAfterMs: 300_000 }),
      ).toBe(1);
      const runRows = (await db.$client.unsafe("SELECT last_error FROM runs WHERE id = $1", [
        seeded.runId,
      ])) as Array<{ last_error: string | null }>;
      expect(runRows[0]!.last_error).toBe("run_lost");

      const { system, published } = stubSystem();
      const { notifier } = stubNotifier();
      expect(await settleScheduleRuns(makeDeps(T + 1_000, { system, notifier }))).toBe(1);

      // Red-before-green: with the old decorated `"run_lost: stale sweep"`
      // the classifier saw a terminal code and the ladder never armed.
      const srs = await scheduleRunsFor(sched.id);
      expect(srs[0]).toMatchObject({ status: "retry_scheduled", attempt: 2 });
      expect(srs[0]!.retryAt!.toISOString()).toBe(iso(T + 1_000 + 30_000));
      const failedEv = published.find((p) => p.event.type === "schedule_run_failed")!;
      expect(failedEv.event.payload).toMatchObject({ code: "run_lost", willRetry: true });
    });

    it("(l) M1: a session/trigger rebind mid-run does not misroute settle's reporting", async () => {
      const T0 = BASE;
      const T = T0 + 600_000;
      const sched = await seedSchedule({ kind: "at", at: iso(T0 + 300_000) }, { at: T0 });
      await schedules.update(db, sched.id, { nextRunAt: null });
      const seeded = await seedOccurrence(sched, {
        scheduledFor: T0 + 300_000,
        finishRun: "completed",
        assistant: "Report ready",
      });

      // The user rebinds the schedule to another session AND makes it
      // recurring while the run is in flight. Settle must still report into
      // the session the run executed in and treat the occurrence as a
      // one-off (the trigger kind pinned at claim time).
      const rebound = await sessions.create(db, sched.userId, "rebound");
      createdSessionIds.push(rebound.id);
      await schedules.update(db, sched.id, {
        sessionId: rebound.id,
        trigger: { kind: "every", seconds: 300 },
      });

      const { system, published } = stubSystem();
      const { notifier, succeeded } = stubNotifier();
      expect(await settleScheduleRuns(makeDeps(T, { system, notifier }))).toBe(1);

      // Summary read from the PINNED session (A), not the rebound one (B).
      expect(published[0]!.event.type).toBe("schedule_run_succeeded");
      expect(published[0]!.event.payload).toMatchObject({
        scheduleRunId: seeded.scheduleRunId,
        summary: "Report ready",
        scheduleCompleted: true,
      });
      expect(succeeded).toEqual([
        {
          userId: sched.userId,
          scheduleId: sched.id,
          sessionId: sched.sessionId, // A — where the run actually happened
          title: "Report",
          summary: "Report ready",
        },
      ]);
      // The note lands on A; B stays untouched.
      expect(
        appended.some(
          (e) =>
            e.sessionId === sched.sessionId &&
            e.type === "system_note" &&
            e.payload.scheduleRunId === seeded.scheduleRunId,
        ),
      ).toBe(true);
      expect(appended.some((e) => e.sessionId === rebound.id)).toBe(false);
      expect(await messagesFor(rebound.id)).toHaveLength(0);

      // Pinned trigger kind: the occurrence was a one-off, so it completes
      // even though the live schedule now says `every`.
      const after = await scheduleRow(sched.id);
      expect(after!.status).toBe("completed");
      expect(after!.nextRunAt).toBeNull();
    });

    it("(m) M2: cancel/pause mid-run is not overwritten by settle (one-off success)", async () => {
      const T0 = BASE;
      const T = T0 + 600_000;

      // (1) cancelled one-off: stays cancelled, result still recorded.
      const cancelled = await seedSchedule({ kind: "at", at: iso(T0 + 300_000) }, { at: T0 });
      await schedules.update(db, cancelled.id, { nextRunAt: null });
      await seedOccurrence(cancelled, {
        scheduledFor: T0 + 300_000,
        finishRun: "completed",
        assistant: "Report ready",
      });
      await schedules.update(db, cancelled.id, { status: "cancelled" });

      // (2) paused one-off: stays paused (user reason kept).
      const paused = await seedSchedule({ kind: "at", at: iso(T0 + 600_000) }, { at: T0 });
      await schedules.update(db, paused.id, { nextRunAt: null });
      await seedOccurrence(paused, {
        scheduledFor: T0 + 600_000,
        finishRun: "completed",
        assistant: "Report ready",
      });
      await schedules.update(db, paused.id, { status: "paused", pausedReason: "user" });

      const { system, published } = stubSystem();
      const { notifier, succeeded } = stubNotifier();
      expect(await settleScheduleRuns(makeDeps(T, { system, notifier }))).toBe(2);

      const afterCancelled = await scheduleRow(cancelled.id);
      expect(afterCancelled!.status).toBe("cancelled");
      expect(afterCancelled!.lastResult!.status).toBe("succeeded");

      const afterPaused = await scheduleRow(paused.id);
      expect(afterPaused!.status).toBe("paused");
      expect(afterPaused!.pausedReason).toBe("user");
      expect(afterPaused!.lastResult!.status).toBe("succeeded");

      // The occurrences themselves settled and notified.
      expect(await scheduleRunsFor(cancelled.id)).toMatchObject([{ status: "succeeded" }]);
      expect(await scheduleRunsFor(paused.id)).toMatchObject([{ status: "succeeded" }]);
      expect(succeeded).toHaveLength(2);
      // `scheduleCompleted` reflects the ACTUAL transition: neither schedule
      // completed, so both events say false.
      expect(
        published
          .filter((p) => p.event.type === "schedule_run_succeeded")
          .map((p) => p.event.payload.scheduleCompleted),
      ).toEqual([false, false]);
    });

    it("(n) M2: a cancelled recurring schedule is not re-paused by a final failure", async () => {
      const T0 = BASE;
      const T = T0 + 600_000;
      const sched = await seedSchedule({ kind: "every", seconds: 300 }, { at: T0 });
      await seedOccurrence(sched, {
        scheduledFor: T0 + 300_000,
        finishRun: "failed",
        runError: "key_not_minted",
      });
      await schedules.update(db, sched.id, { status: "cancelled" });

      const { system, published } = stubSystem();
      const { notifier, failed } = stubNotifier();
      expect(await settleScheduleRuns(makeDeps(T, { system, notifier }))).toBe(1);

      const after = await scheduleRow(sched.id);
      expect(after!.status).toBe("cancelled");
      expect(after!.pausedReason).toBeNull();
      expect(after!.lastResult!.status).toBe("failed");
      // The failure is still reported (lastResult + push), but no bogus
      // `paused` event claims a transition that did not happen.
      expect(failed).toHaveLength(1);
      expect(published.map((p) => p.event.type)).toEqual(["schedule_run_failed"]);
    });
  },
);
