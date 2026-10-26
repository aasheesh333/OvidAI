import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type { AgentRequest, AgentResponse, AgentTransport } from "@ovid/agent-core";
import {
  RunQuotaService,
  createDb,
  createSchedule,
  messages,
  migrate,
  newId,
  runs,
  scheduleRuns,
  schedules,
  sessions,
  users,
  type Db,
  type ScheduleRow,
} from "@ovid/db";
import type { EventLog, SystemBus } from "@ovid/events";
import type { ScheduleTrigger, SystemEvent } from "@ovid/shared";
import {
  AGENT_RUN_JOB_NAME,
  SCHEDULE_FIRE_JOB_NAME,
  scheduleMirrorJobId,
  type QueueServices,
} from "@ovid/queue";
import {
  createMigrationScratch,
  type MigrationScratch,
} from "../../../packages/db/src/migrationTestKit.js";
import type { Notifier } from "./notify.js";
import {
  fireScheduleOccurrence,
  recoverPendingModelCallSettlements,
  runSchedulerTick,
  startSchedulerLoop,
  type ModelCallSettlementQuota,
  type SchedulerDeps,
} from "./schedulerTick.js";
import { withUsageRecording } from "./usageRecorder.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

// Pinned PAST base — 2020-09-13, deliberately BELOW every other suite's 2023
// base (1.7e12) and the real clock: leftover pending schedules / retry rows
// other suites leave behind are NEVER due under this clock, so this suite's
// exact-count reports stay exact on the shared dev DB with no real waiting.
// This suite's own leftovers are cancelled in afterEach (cancelled rows are
// invisible to claimDue), so re-runs are exact too.
const BASE = 1_600_000_000_000;
const iso = (ms: number): string => new Date(ms).toISOString();

/** One captured queue add (which queue, job name, payload, add options). */
interface CapturedAdd {
  queue: "agentRuns" | "schedules";
  name: string;
  data: unknown;
  opts: Record<string, unknown>;
}

/** Capturing stub for BOTH queues the scheduler touches (gateway stubQueues idea). */
function stubQueues(behavior: { failAgentAddOnce?: boolean } = {}): {
  queues: QueueServices;
  adds: CapturedAdd[];
} {
  const adds: CapturedAdd[] = [];
  let failedOnce = false;
  const queues = {
    agentRuns: {
      add: async (name: string, data: unknown, opts?: Record<string, unknown>) => {
        if (behavior.failAgentAddOnce && !failedOnce) {
          failedOnce = true;
          throw new Error("queue redis unreachable");
        }
        adds.push({ queue: "agentRuns", name, data, opts: opts ?? {} });
        return { id: String(opts?.jobId ?? "") };
      },
    },
    schedules: {
      add: async (name: string, data: unknown, opts?: Record<string, unknown>) => {
        adds.push({ queue: "schedules", name, data, opts: opts ?? {} });
        return { id: String(opts?.jobId ?? "") };
      },
    },
  } as unknown as QueueServices;
  return { queues, adds };
}

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

describe.skipIf(!TEST_DATABASE_URL)(
  "scheduler tick + occurrence firing (real Postgres, injected clock)",
  () => {
    let db: Db;
    /** Everything this suite seeds; cancelled/terminalized in afterEach. */
    const createdScheduleIds: string[] = [];
    const createdSessionIds: string[] = [];
    let counter = 0;

    beforeAll(async () => {
      await migrate(TEST_DATABASE_URL!);
      db = createDb(TEST_DATABASE_URL!);
    });

    afterEach(async () => {
      // Cancelled rows are invisible to claimDue (status='pending' filter), so
      // leftovers can never fire on a re-run; stranded queued/running runs are
      // terminalized like staleRuns.test does (never strand rows yourself).
      for (const scheduleId of createdScheduleIds) {
        await schedules.update(db, scheduleId, { status: "cancelled" }).catch(() => {});
      }
      for (const sessionId of createdSessionIds) {
        await db
          .$client.unsafe(
            "UPDATE runs SET status = 'completed' WHERE session_id = $1 AND status IN ('queued','running')",
            [sessionId],
          )
          .catch(() => {});
      }
    });

    afterAll(async () => {
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
      opts: {
        at: number;
        title?: string;
        description?: string;
        maxRetries?: number;
        autonomy?: "safe" | "auto";
      },
    ): Promise<ScheduleRow> {
      const userId = uid("w8u");
      // createSchedule only users.ensure's on the cron tier gate — the FK on
      // sessions requires the user row to exist for every other trigger kind.
      await users.ensure(db, userId, `${userId}@stub.test`);
      const row = await createSchedule(db, {
        userId,
        title: opts.title ?? "Morning",
        description: opts.description ?? "check inbox",
        trigger,
        maxRetries: opts.maxRetries,
        autonomy: opts.autonomy,
        clock: () => new Date(opts.at),
      });
      createdScheduleIds.push(row.id);
      createdSessionIds.push(row.sessionId);
      return row;
    }

    function makeDeps(
      clockMs: number,
      stubs: { queues: QueueServices; system: SystemBus },
    ): SchedulerDeps {
      return { db, queues: stubs.queues, system: stubs.system, clock: () => new Date(clockMs) };
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

    async function runStatus(runId: string): Promise<string> {
      const rows = (await db.$client.unsafe("SELECT status FROM runs WHERE id = $1", [
        runId,
      ])) as Array<{ status: string }>;
      return rows[0]!.status;
    }

    it("(a) on-time fire: claim ledger, prompt row, enqueue, publish, mirror, anchored advance", async () => {
      const T0 = BASE;
      const sched = await seedSchedule({ kind: "every", seconds: 300 }, { at: T0 });
      const { queues, adds } = stubQueues();
      const { system, published } = stubSystem();

      const report = await runSchedulerTick(makeDeps(T0 + 300_000, { queues, system }));
      expect(report).toEqual({ fired: 1, retried: 0, skipped: 0, paused: 0, deferred: 0, duplicates: 0 });

      const srs = await scheduleRunsFor(sched.id);
      expect(srs).toHaveLength(1);
      expect(srs[0]).toMatchObject({
        scheduleId: sched.id,
        status: "running",
        ranLate: false,
        attempt: 1,
      });
      expect(srs[0]!.scheduledFor.toISOString()).toBe(iso(T0 + 300_000));

      const msgs = await messagesFor(sched.sessionId);
      expect(msgs).toHaveLength(1);
      expect(msgs[0]!.role).toBe("user");
      expect(msgs[0]!.content).toBe("[schedule: Morning] check inbox");

      const agentAdds = adds.filter((a) => a.queue === "agentRuns");
      expect(agentAdds).toHaveLength(1);
      expect(agentAdds[0]!.name).toBe(AGENT_RUN_JOB_NAME);
      expect(agentAdds[0]!.data).toEqual({
        runId: srs[0]!.runId,
        sessionId: sched.sessionId,
        userId: sched.userId,
        prompt: "[schedule: Morning] check inbox",
        // H1: the schedule's autonomy reaches the run as a mode — `safe` is
        // the only read-only gate on the run path.
        autonomy: "safe",
        mode: "safe",
        schedule: { scheduleId: sched.id, scheduleRunId: srs[0]!.id, autonomy: "safe" },
      });
      expect(agentAdds[0]!.opts.jobId).toBe(srs[0]!.runId);
      expect(agentAdds[0]!.opts.priority).toBe(2); // free user
      expect(await runStatus(srs[0]!.runId!)).toBe("queued");

      expect(published).toHaveLength(1);
      expect(published[0]!.uid).toBe(sched.userId);
      expect(published[0]!.event.type).toBe("schedule_run_started");
      expect(published[0]!.event.payload).toEqual({
        scheduleRunId: srs[0]!.id,
        runId: srs[0]!.runId,
        scheduledFor: iso(T0 + 300_000),
        ranLate: false,
        attempt: 1,
      });

      const mirrorAdds = adds.filter((a) => a.queue === "schedules");
      expect(mirrorAdds).toHaveLength(1);
      expect(mirrorAdds[0]!.name).toBe(SCHEDULE_FIRE_JOB_NAME);
      expect(mirrorAdds[0]!.opts.jobId).toBe(scheduleMirrorJobId(sched.id, T0 + 600_000));
      expect(mirrorAdds[0]!.opts.delay).toBe(300_000);
      expect(mirrorAdds[0]!.data).toEqual({
        scheduleId: sched.id,
        scheduledFor: iso(T0 + 600_000),
      });

      // Interval anchored at the occurrence (nextIntervalSlot), NOT now+300.
      const after = await scheduleRow(sched.id);
      expect(after!.nextRunAt!.toISOString()).toBe(iso(T0 + 600_000));

      // Sub-case: the SAME shape of schedule ticked 600 s late (grace 150 s
      // for every 300) SKIPS to the next anchored slot — it never fires late.
      await schedules.update(db, sched.id, { status: "cancelled" }); // keep the report exact
      const late = await seedSchedule({ kind: "every", seconds: 300 }, { at: T0 });
      const report2 = await runSchedulerTick(makeDeps(T0 + 900_000, { queues, system }));
      expect(report2).toEqual({ fired: 0, retried: 0, skipped: 1, paused: 0, deferred: 0, duplicates: 0 });

      const lateSrs = await scheduleRunsFor(late.id);
      expect(lateSrs).toHaveLength(1);
      expect(lateSrs[0]!.status).toBe("skipped");
      expect(agentAdds).toHaveLength(1); // still exactly one agent-runs add overall
      const lateAfter = await scheduleRow(late.id);
      // Dart nextSlot: steps = 600/300 + 1 = 3 ⇒ due + 900 = T0+1200 — the
      // pinned anchored value (NOT now+300).
      expect(lateAfter!.nextRunAt!.toISOString()).toBe(iso(T0 + 1200_000));
    });

    it("(b) within the 2-min tolerance fires onTime; within grace fires runNow (ranLate)", async () => {
      const T0 = BASE;
      const tol = await seedSchedule({ kind: "every", seconds: 300 }, { at: T0 });
      const grace = await seedSchedule({ kind: "every", seconds: 1800 }, { at: T0 });
      const { queues } = stubQueues();
      const { system } = stubSystem();

      // 60 s late on every-300 (tolerance 120 s): onTime, ranLate false.
      const r1 = await runSchedulerTick(makeDeps(T0 + 360_000, { queues, system }));
      expect(r1).toEqual({ fired: 1, retried: 0, skipped: 0, paused: 0, deferred: 0, duplicates: 0 });
      const tolSrs = await scheduleRunsFor(tol.id);
      expect(tolSrs[0]).toMatchObject({ status: "running", ranLate: false });
      expect((await scheduleRow(tol.id))!.nextRunAt!.toISOString()).toBe(iso(T0 + 600_000));

      // Keep the second tick's report scoped to the grace schedule.
      await schedules.update(db, tol.id, { status: "cancelled" });

      // 5 min late on every-1800 (grace 900 s): runNow, ranLate true.
      const r2 = await runSchedulerTick(makeDeps(T0 + 2100_000, { queues, system }));
      expect(r2).toEqual({ fired: 1, retried: 0, skipped: 0, paused: 0, deferred: 0, duplicates: 0 });
      const graceSrs = await scheduleRunsFor(grace.id);
      expect(graceSrs[0]).toMatchObject({ status: "running", ranLate: true });
      expect((await scheduleRow(grace.id))!.nextRunAt!.toISOString()).toBe(iso(T0 + 3600_000));
    });

    it("(c) 7 h late on every-300 (grace 150 s) → skipped_next, zero agent-runs adds", async () => {
      const T0 = BASE;
      const sched = await seedSchedule({ kind: "every", seconds: 300 }, { at: T0 });
      const { queues, adds } = stubQueues();
      const { system, published } = stubSystem();
      const nowMs = T0 + 300_000 + 7 * 3_600_000;

      const report = await runSchedulerTick(makeDeps(nowMs, { queues, system }));
      expect(report).toEqual({ fired: 0, retried: 0, skipped: 1, paused: 0, deferred: 0, duplicates: 0 });

      const srs = await scheduleRunsFor(sched.id);
      expect(srs).toHaveLength(1);
      expect(srs[0]!.status).toBe("skipped");
      expect(srs[0]!.scheduledFor.toISOString()).toBe(iso(T0 + 300_000));

      expect(adds.filter((a) => a.queue === "agentRuns")).toHaveLength(0);

      expect(published.map((p) => p.event.type)).toEqual(["schedule_updated"]);
      expect(published[0]!.event.payload).toEqual({
        reason: "skipped_missed",
        skippedFor: iso(T0 + 300_000),
        nextRunAt: iso(nowMs + 300_000),
      });

      const after = await scheduleRow(sched.id);
      expect(after!.status).toBe("pending");
      expect(after!.nextRunAt!.toISOString()).toBe(iso(nowMs + 300_000)); // first slot after now
    });

    it("(d) one-off 25 h late → paused (missed_beyond_grace), nextRunAt KEPT, no run/message rows", async () => {
      const T0 = BASE;
      const sched = await seedSchedule({ kind: "at", at: iso(T0 + 600_000) }, { at: T0 });
      const { queues, adds } = stubQueues();
      const { system, published } = stubSystem();

      const report = await runSchedulerTick(
        makeDeps(T0 + 600_000 + 25 * 3_600_000, { queues, system }),
      );
      expect(report).toEqual({ fired: 0, retried: 0, skipped: 0, paused: 1, deferred: 0, duplicates: 0 });

      const after = await scheduleRow(sched.id);
      expect(after!.status).toBe("paused");
      expect(after!.pausedReason).toBe("missed_beyond_grace");
      expect(after!.nextRunAt!.toISOString()).toBe(iso(T0 + 600_000)); // KEPT

      expect(await scheduleRunsFor(sched.id)).toHaveLength(0);
      expect(await messagesFor(sched.sessionId)).toHaveLength(0);
      expect(adds).toHaveLength(0); // no enqueue, no mirror
      expect(published.map((p) => p.event.type)).toEqual(["schedule_run_paused"]);
      expect(published[0]!.event.payload).toEqual({
        reason: "missed_beyond_grace",
        scheduledFor: iso(T0 + 600_000),
      });
    });

    it("(e) duplicate fire race: one fired + one duplicate_claim/not_due; exactly one occurrence/run/add", async () => {
      const T0 = BASE;
      const sched = await seedSchedule({ kind: "every", seconds: 300 }, { at: T0 });
      const { queues, adds } = stubQueues();
      const { system, published } = stubSystem();
      const deps = makeDeps(T0 + 300_000, { queues, system });

      const [r1, r2] = await Promise.all([
        fireScheduleOccurrence(deps, sched.id),
        fireScheduleOccurrence(deps, sched.id),
      ]);
      const outcomes = [r1, r2].sort();
      expect(outcomes[0]).toBe("fired");
      expect(["duplicate_claim", "not_due"]).toContain(outcomes[1]);

      expect(await scheduleRunsFor(sched.id)).toHaveLength(1);
      const runRows = (await db.$client.unsafe("SELECT id FROM runs WHERE session_id = $1", [
        sched.sessionId,
      ])) as Array<{ id: string }>;
      expect(runRows).toHaveLength(1);
      expect(adds.filter((a) => a.queue === "agentRuns")).toHaveLength(1);
      expect(published.filter((p) => p.event.type === "schedule_run_started")).toHaveLength(1);
    });

    it("(f) busy session defers (row untouched, nothing claimed); next tick fires once free", async () => {
      const T0 = BASE;
      const sched = await seedSchedule({ kind: "every", seconds: 300 }, { at: T0 });
      const prompt = await messages.append(db, {
        sessionId: sched.sessionId,
        role: "user",
        content: "manual",
      });
      const activeRow = await runs.create(db, {
        sessionId: sched.sessionId,
        promptMessageId: prompt.id,
      });
      const active = activeRow.id;
      const { queues, adds } = stubQueues();
      const { system, published } = stubSystem();

      const r1 = await runSchedulerTick(makeDeps(T0 + 300_000, { queues, system }));
      expect(r1).toEqual({ fired: 0, retried: 0, skipped: 0, paused: 0, deferred: 1, duplicates: 0 });

      const after = await scheduleRow(sched.id);
      expect(after!.nextRunAt!.toISOString()).toBe(iso(T0 + 300_000)); // untouched
      expect(await scheduleRunsFor(sched.id)).toHaveLength(0); // nothing claimed
      expect(adds).toHaveLength(0);
      expect(published).toHaveLength(0);
      expect(await runStatus(active)).toBe("queued"); // busy row untouched

      expect(await runs.finish(db, active, "completed")).toBe(true);
      const r2 = await runSchedulerTick(makeDeps(T0 + 300_000, { queues, system }));
      expect(r2).toEqual({ fired: 1, retried: 0, skipped: 0, paused: 0, deferred: 0, duplicates: 0 });
      const srs = await scheduleRunsFor(sched.id);
      expect(srs).toHaveLength(1);
      expect(srs[0]!.status).toBe("running");
    });

    it("(g) retry_scheduled occurrence due → retry_fired: new run + message, attempt kept, retry_at cleared", async () => {
      const T0 = BASE;
      const sched = await seedSchedule({ kind: "at", at: iso(T0 + 600_000) }, { at: T0, maxRetries: 2 });
      const prompt = await messages.append(db, {
        sessionId: sched.sessionId,
        role: "user",
        content: "first",
      });
      const firstRunRow = await runs.create(db, {
        sessionId: sched.sessionId,
        promptMessageId: prompt.id,
      });
      const firstRun = firstRunRow.id;
      const claimed = await scheduleRuns.claim(db, {
        scheduleId: sched.id,
        scheduledFor: new Date(T0 + 600_000),
        runId: firstRun,
        ranLate: false,
        sessionId: sched.sessionId,
        triggerKind: "at",
      });
      expect(claimed).not.toBeNull();
      await runs.finish(db, firstRun, "failed", "model_transient_exhausted");
      await scheduleRuns.scheduleRetry(db, claimed!.id, new Date(T0 + 700_000));
      await schedules.update(db, sched.id, { nextRunAt: null }); // one-off after its fire

      const { queues, adds } = stubQueues();
      const { system } = stubSystem();
      const report = await runSchedulerTick(makeDeps(T0 + 700_000, { queues, system }));
      expect(report).toEqual({ fired: 0, retried: 1, skipped: 0, paused: 0, deferred: 0, duplicates: 0 });

      const srs = await scheduleRunsFor(sched.id);
      expect(srs).toHaveLength(1);
      const row = srs[0]!;
      expect(row.status).toBe("running");
      expect(row.attempt).toBe(2); // scheduleRetry bumped it; claimRetry keeps it
      expect(row.retryAt).toBeNull();
      expect(row.runId).not.toBe(firstRun); // NEW run
      expect(await runStatus(row.runId!)).toBe("queued");

      // NEW prompt message (newest first: the retry prompt, then "first").
      const msgs = await messagesFor(sched.sessionId);
      expect(msgs.map((m) => m.content)).toEqual(["[schedule: Morning] check inbox", "first"]);

      const agentAdds = adds.filter((a) => a.queue === "agentRuns");
      expect(agentAdds).toHaveLength(1);
      expect(agentAdds[0]!.opts.jobId).toBe(row.runId);
      expect((agentAdds[0]!.data as { schedule: { scheduleRunId: string } }).schedule.scheduleRunId).toBe(row.id);
    });

    it("(h) stale mirror (expectedScheduledFor ≠ row nextRunAt) → not_due, zero side effects", async () => {
      const T0 = BASE;
      const sched = await seedSchedule({ kind: "every", seconds: 300 }, { at: T0 });
      const { queues, adds } = stubQueues();
      const { system, published } = stubSystem();

      const outcome = await fireScheduleOccurrence(makeDeps(T0 + 300_000, { queues, system }), sched.id, {
        expectedScheduledFor: new Date(T0 - 999_000),
      });
      expect(outcome).toBe("not_due");

      expect(await scheduleRunsFor(sched.id)).toHaveLength(0);
      expect(adds).toHaveLength(0);
      expect(published).toHaveLength(0);
      expect((await scheduleRow(sched.id))!.nextRunAt!.toISOString()).toBe(iso(T0 + 300_000));
    });

    it("(i) enqueue failure is logged, never rethrown: outcome fired, run stays queued for settle's stale path", async () => {
      const T0 = BASE;
      const sched = await seedSchedule({ kind: "every", seconds: 300 }, { at: T0 });
      const { queues, adds } = stubQueues({ failAgentAddOnce: true });
      const { system, published } = stubSystem();
      // mockRestore() wipes mock.calls — every assertion that reads them must
      // run BEFORE the restore (hence try/finally around the assertions too).
      const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
      try {
        const report = await runSchedulerTick(makeDeps(T0 + 300_000, { queues, system }));
        expect(report).toEqual({ fired: 1, retried: 0, skipped: 0, paused: 0, deferred: 0, duplicates: 0 });

        expect(errSpy.mock.calls.some((c) => String(c[0]).includes("[scheduler] enqueue failed"))).toBe(
          true,
        );
        const srs = await scheduleRunsFor(sched.id);
        expect(srs).toHaveLength(1);
        expect(await runStatus(srs[0]!.runId!)).toBe("queued"); // settle (Task 9) recovers this
        expect(adds.filter((a) => a.queue === "agentRuns")).toHaveLength(0); // the add itself failed
        // Post-commit side effects continue past the enqueue failure.
        expect(published.filter((p) => p.event.type === "schedule_run_started")).toHaveLength(1);
        expect(adds.filter((a) => a.queue === "schedules")).toHaveLength(1); // mirror still re-armed
      } finally {
        errSpy.mockRestore();
      }
    });

    it("(j) three due schedules → summed report; loop runs ≥2 passes and stop() ends it", async () => {
      const T0 = BASE;
      const ids: string[] = [];
      for (let i = 0; i < 3; i += 1) {
        ids.push((await seedSchedule({ kind: "every", seconds: 300 }, { at: T0 })).id);
      }
      const { queues } = stubQueues();
      const { system } = stubSystem();

      const report = await runSchedulerTick(makeDeps(T0 + 300_000, { queues, system }));
      expect(report).toEqual({ fired: 3, retried: 0, skipped: 0, paused: 0, deferred: 0, duplicates: 0 });
      for (const id of ids) {
        expect(await scheduleRunsFor(id)).toHaveLength(1);
      }

      // The loop: settle (stubbed — Task 9 lands it next) + tick per pass,
      // overlap-guarded, stop() ends it. Bounded: the whole case stays < 2 s.
      let settlePasses = 0;
      const loop = startSchedulerLoop(
        {
          db,
          queues,
          system,
          events: {} as unknown as EventLog,
          notifier: {} as unknown as Notifier,
          clock: () => new Date(BASE),
          settleScheduleRuns: async () => {
            settlePasses += 1;
            return 0;
          },
        },
        { intervalMs: 5 },
      );
      await new Promise((resolve) => setTimeout(resolve, 60));
      loop.stop();
      const settled = settlePasses;
      await new Promise((resolve) => setTimeout(resolve, 40));
      expect(settlePasses).toBe(settled); // stop() ended it
      expect(settled).toBeGreaterThanOrEqual(2);
      expect(settled).toBeLessThan(100); // 5 ms interval, ~100 ms window: sanity bound
    });

    it("(k) H1: schedule autonomy is projected onto the run mode (safe → read-only; auto → explicit opt-in)", async () => {
      const T0 = BASE;
      const safe = await seedSchedule({ kind: "every", seconds: 300 }, { at: T0 });
      const auto = await seedSchedule(
        { kind: "every", seconds: 300 },
        { at: T0, autonomy: "auto" },
      );
      const { queues, adds } = stubQueues();
      const { system } = stubSystem();

      const report = await runSchedulerTick(makeDeps(T0 + 300_000, { queues, system }));
      expect(report.fired).toBe(2);

      const agentAdds = adds.filter((a) => a.queue === "agentRuns");
      const dataFor = (scheduleId: string): Record<string, unknown> => {
        const add = agentAdds.find(
          (a) => (a.data as { schedule: { scheduleId: string } }).schedule.scheduleId === scheduleId,
        );
        expect(add).toBeDefined();
        return add!.data as Record<string, unknown>;
      };

      // Load-bearing H1 pin: delete the mode projection in schedulerTick's
      // enqueue and this assertion fails (the job then inherits the session's
      // `auto` mode and a `safe` schedule can mutate).
      expect(dataFor(safe.id)).toMatchObject({ autonomy: "safe", mode: "safe" });
      expect(dataFor(auto.id)).toMatchObject({ autonomy: "auto", mode: "auto" });
    });
  },
);

// R1b recovery regressions are UNEXECUTED under HEAVY-COMMANDS-PAUSED.md.
// Source-order authorship is not RED/GREEN evidence. The isolated scratch and
// real RunQuotaService keep the production discovery/settlement path intact.
describe.skipIf(!TEST_DATABASE_URL).sequential(
  "pending model-call settlement recovery (isolated real Postgres; UNEXECUTED)",
  () => {
    const RECOVERY_NOW = new Date("2026-10-25T00:00:00.000Z");
    const RECOVERY_REQUEST = {
      model: "auto",
      baseUrl: "http://litellm",
      apiKey: "sk",
      system: [],
      messages: [],
      tools: [],
      cacheMode: "none",
    } as unknown as AgentRequest;
    let scratch: MigrationScratch;
    let db: Db;
    const actorIds: string[] = [];
    const recoveryScheduleIds: string[] = [];

    beforeAll(async () => {
      scratch = await createMigrationScratch(TEST_DATABASE_URL!, "scheduler_settlement_r1b");
      await migrate(scratch.url);
      db = createDb(scratch.url, { max: 8 });
    }, 180_000);

    afterEach(async () => {
      for (const scheduleId of recoveryScheduleIds.splice(0)) {
        await schedules.update(db, scheduleId, { status: "cancelled" }).catch(() => {});
      }
      // Recovery deliberately scans all actors. Remove only this test's quota
      // rows so each case starts with an empty global pending-settlement set.
      for (const actorUserId of actorIds.splice(0)) {
        await db.$client`DELETE FROM run_usage WHERE user_id = ${actorUserId}`;
        await db.$client`DELETE FROM usage_quota_reservations WHERE actor_user_id = ${actorUserId}`;
        await db.$client`DELETE FROM usage_quota_counters WHERE actor_user_id = ${actorUserId}`;
        await db.$client`DELETE FROM usage_run_admissions WHERE actor_user_id = ${actorUserId}`;
      }
    });

    afterAll(async () => {
      await db?.$client.end({ timeout: 5 });
      await scratch?.close();
    }, 30_000);

    async function seedRun() {
      const actorUserId = newId();
      actorIds.push(actorUserId);
      await users.ensure(db, actorUserId, null);
      const session = await sessions.create(db, actorUserId, "scheduler settlement recovery");
      const prompt = await messages.append(db, {
        sessionId: session.id,
        role: "user",
        content: "scheduler settlement recovery",
      });
      const run = await runs.create(db, { sessionId: session.id, promptMessageId: prompt.id });
      return { actorUserId, session, run };
    }

    function newQuota(now: () => Date = () => RECOVERY_NOW): RunQuotaService {
      return new RunQuotaService(db, {
        now,
        tokenCaps: { perDay: 100_000, perMonth: 1_000_000 },
        usdCaps: { perDay: null, perMonth: null },
      });
    }

    function recoveryDeps(quota?: ModelCallSettlementQuota) {
      const { queues, adds } = stubQueues();
      const { system, published } = stubSystem();
      const deps: SchedulerDeps = {
        db,
        queues,
        system,
        clock: () => new Date(BASE),
        ...(quota === undefined ? {} : { quota }),
      };
      return { deps, adds, published };
    }

    async function quotaCounters(actorUserId: string) {
      return db.$client`
        SELECT window_kind, used_tokens::int, reserved_tokens::int,
               used_usd::text, reserved_usd::text
          FROM usage_quota_counters
         WHERE actor_user_id = ${actorUserId}
         ORDER BY window_kind`;
    }

    async function seedPendingReservation(
      reservationKey: string,
      actual: { inputTokens: number; outputTokens: number },
    ) {
      const root = await seedRun();
      const quota = newQuota();
      const reservation = await quota.reserveModelCall({
        actorUserId: root.actorUserId,
        runId: root.run.id,
        reservationKey,
        inputTokens: actual.inputTokens,
        maxOutputTokens: 20,
        requestedModel: "auto",
        billingClass: "ovid_allowance",
      });
      if (!reservation.ok) throw new Error("reservation unexpectedly exhausted");
      await db.$client`
        UPDATE usage_quota_reservations
           SET actual_input_tokens = ${actual.inputTokens},
               actual_output_tokens = ${actual.outputTokens},
               actual_cache_read_tokens = 1,
               actual_cache_write_tokens = 2,
               provider_model = 'provider/recovered',
               cost_usd = 0.0000000007,
               cost_source = 'provider'
         WHERE id = ${reservation.reservationId}`;
      const staged = (await quota.pendingSettlements()).find(
        (item) => item.reservationId === reservation.reservationId,
      );
      if (staged === undefined) throw new Error("staged reservation was not discoverable");
      return { ...root, quota, reservationId: reservation.reservationId, usage: staged.usage };
    }

    it("recovers canonical staged facts through the default service without another provider invocation", async () => {
      const { actorUserId, session, run } = await seedRun();
      const quota = newQuota();
      let providerCalls = 0;
      const provider: AgentTransport = {
        apiFormat: "openai",
        async stream(): Promise<AgentResponse> {
          providerCalls += 1;
          return {
            content: "provider response already consumed",
            thinking: "",
            toolCalls: [],
            finishReason: "stop",
            usage: {
              inputTokens: 3,
              outputTokens: 4,
              cacheReadTokens: 1,
              cacheWriteTokens: 2,
              providerModel: "provider/recovered",
              costUsd: "0.0000000007",
              costSource: "provider",
            },
          };
        },
      };
      const record = vi.fn(async () => {});
      const wrapped = withUsageRecording(provider, {
        userId: actorUserId,
        sessionId: session.id,
        runId: run.id,
        record,
        log: vi.fn(),
        quota,
        inputTokens: () => 1,
        reservationKey: () => "scheduler-default-recovery",
      });

      await db.$client`
        CREATE FUNCTION fail_scheduler_r1b_run_usage_insert() RETURNS trigger AS $$
        BEGIN
          RAISE EXCEPTION 'ambiguous scheduler settlement commit blocked';
        END;
        $$ LANGUAGE plpgsql`;
      await db.$client`
        CREATE TRIGGER fail_scheduler_r1b_run_usage_insert
        BEFORE INSERT ON run_usage FOR EACH ROW
        EXECUTE FUNCTION fail_scheduler_r1b_run_usage_insert()`;
      let outcomeError: unknown = null;
      try {
        outcomeError = await wrapped.stream(
          { ...RECOVERY_REQUEST, maxTokens: 10 },
          { onTextDelta() {} },
          new AbortController().signal,
        ).then(() => null, (error: unknown) => error);
      } finally {
        await db.$client`DROP TRIGGER fail_scheduler_r1b_run_usage_insert ON run_usage`;
        await db.$client`DROP FUNCTION fail_scheduler_r1b_run_usage_insert()`;
      }
      expect(outcomeError).toBeInstanceOf(Error);
      expect((outcomeError as Error).message).toContain("ambiguous scheduler settlement commit blocked");
      expect(providerCalls).toBe(1);
      expect(record).not.toHaveBeenCalled();

      const pending = await quota.pendingSettlements();
      expect(pending).toHaveLength(1);
      const reservationId = pending[0]!.reservationId;
      expect(pending[0]!.usage).toEqual({
        inputTokens: 3,
        outputTokens: 4,
        cacheReadTokens: 1,
        cacheWriteTokens: 2,
        requestedModel: "auto",
        providerModel: "provider/recovered",
        costUsd: "0.0000000007",
        costSource: "provider",
        billingClass: "ovid_allowance",
      });
      expect(await db.$client`
        SELECT count(*)::int AS count FROM run_usage
         WHERE quota_reservation_id = ${reservationId}`)
        .toEqual([{ count: 0 }]);

      // No quota override: recovery must construct the canonical DB service.
      const { deps, adds, published } = recoveryDeps();
      await recoverPendingModelCallSettlements(deps);

      expect(providerCalls).toBe(1);
      expect(adds).toEqual([]);
      expect(published).toEqual([]);
      expect(await quota.pendingSettlements()).toEqual([]);
      expect(await db.$client`
        SELECT state FROM usage_quota_reservations WHERE id = ${reservationId}`)
        .toEqual([{ state: "settled" }]);
      expect(await db.$client`
        SELECT user_id, session_id::text, run_id::text, model,
               input_tokens::int, output_tokens::int,
               cache_read_tokens::int, cache_write_tokens::int,
               requested_model, provider_model, cost_usd::text,
               cost_source, billing_class
          FROM run_usage WHERE quota_reservation_id = ${reservationId}`)
        .toEqual([{
          user_id: actorUserId,
          session_id: session.id,
          run_id: run.id,
          model: "auto",
          input_tokens: 3,
          output_tokens: 4,
          cache_read_tokens: 1,
          cache_write_tokens: 2,
          requested_model: "auto",
          provider_model: "provider/recovered",
          cost_usd: "0.0000000007",
          cost_source: "provider",
          billing_class: "ovid_allowance",
        }]);
    });

    it("settles one exact reservation once across concurrent and repeated recovery", async () => {
      const staged = await seedPendingReservation(
        "scheduler-concurrent-replay",
        { inputTokens: 5, outputTokens: 6 },
      );
      let discoveries = 0;
      let releaseDiscoveries: (() => void) | undefined;
      const bothDiscovered = new Promise<void>((resolve) => {
        releaseDiscoveries = resolve;
      });
      const concurrentQuota = (): ModelCallSettlementQuota => ({
        async pendingSettlements(limit = 50) {
          const pending = await staged.quota.pendingSettlements(limit);
          discoveries += 1;
          if (discoveries === 2) releaseDiscoveries?.();
          await bothDiscovered;
          return pending;
        },
        settleModelCall(input) {
          return staged.quota.settleModelCall(input);
        },
      });

      await Promise.all([
        recoverPendingModelCallSettlements({
          ...recoveryDeps().deps,
          quota: concurrentQuota(),
        }),
        recoverPendingModelCallSettlements({
          ...recoveryDeps().deps,
          quota: concurrentQuota(),
        }),
      ]);
      expect(discoveries).toBe(2);
      const recoveredCounters = await quotaCounters(staged.actorUserId);
      expect(recoveredCounters).toEqual([
        {
          window_kind: "day",
          used_tokens: 11,
          reserved_tokens: 0,
          used_usd: "0.0000000007",
          reserved_usd: "0.0000000000",
        },
        {
          window_kind: "month",
          used_tokens: 11,
          reserved_tokens: 0,
          used_usd: "0.0000000007",
          reserved_usd: "0.0000000000",
        },
      ]);

      await recoverPendingModelCallSettlements(recoveryDeps(staged.quota).deps);

      expect(await quotaCounters(staged.actorUserId)).toEqual(recoveredCounters);
      expect(await db.$client`
        SELECT count(*)::int AS calls,
               sum(input_tokens)::int AS input_tokens,
               sum(output_tokens)::int AS output_tokens
          FROM run_usage WHERE quota_reservation_id = ${staged.reservationId}`)
        .toEqual([{ calls: 1, input_tokens: 5, output_tokens: 6 }]);
      expect(await db.$client`
        SELECT state FROM usage_quota_reservations WHERE id = ${staged.reservationId}`)
        .toEqual([{ state: "settled" }]);
    });

    it("fails closed on conflicting staged facts without releasing or ledgering the call", async () => {
      const staged = await seedPendingReservation(
        "scheduler-conflicting-facts",
        { inputTokens: 7, outputTokens: 8 },
      );
      const before = await quotaCounters(staged.actorUserId);
      const conflictingQuota: ModelCallSettlementQuota = {
        async pendingSettlements(limit = 50) {
          const pending = await staged.quota.pendingSettlements(limit);
          return pending.map((item) => item.reservationId === staged.reservationId
            ? {
                ...item,
                usage: { ...item.usage, outputTokens: item.usage.outputTokens + 1 },
              }
            : item);
        },
        settleModelCall(input) {
          return staged.quota.settleModelCall(input);
        },
      };
      const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
      try {
        await expect(recoverPendingModelCallSettlements(
          recoveryDeps(conflictingQuota).deps,
        )).resolves.toBeUndefined();
        expect(errSpy).toHaveBeenCalledWith(
          "[scheduler] model usage settlement recovery failed",
          expect.objectContaining({
            reservationId: staged.reservationId,
            err: expect.objectContaining({ code: "idempotency_conflict" }),
          }),
        );
      } finally {
        errSpy.mockRestore();
      }

      expect(await db.$client`
        SELECT state, actual_input_tokens::int, actual_output_tokens::int
          FROM usage_quota_reservations WHERE id = ${staged.reservationId}`)
        .toEqual([{ state: "reserved", actual_input_tokens: 7, actual_output_tokens: 8 }]);
      expect(await db.$client`
        SELECT count(*)::int AS count FROM run_usage
         WHERE quota_reservation_id = ${staged.reservationId}`)
        .toEqual([{ count: 0 }]);
      expect(await quotaCounters(staged.actorUserId)).toEqual(before);
      const stillPending = await staged.quota.pendingSettlements();
      expect(stillPending).toHaveLength(1);
      expect(stillPending[0]!.usage).toEqual(staged.usage);
    });

    it("continues past a conflicting first item and settles the later valid item exactly once", async () => {
      const first = await seedPendingReservation(
        "scheduler-continue-conflict-first",
        { inputTokens: 7, outputTokens: 8 },
      );
      const second = await seedPendingReservation(
        "scheduler-continue-valid-second",
        { inputTokens: 3, outputTokens: 4 },
      );
      const orderBase = Date.parse("2026-10-24T01:00:00.000Z");
      await db.$client`
        UPDATE usage_quota_reservations SET created_at = ${new Date(orderBase)}
        WHERE id = ${first.reservationId}`;
      await db.$client`
        UPDATE usage_quota_reservations SET created_at = ${new Date(orderBase + 1_000)}
        WHERE id = ${second.reservationId}`;
      expect((await first.quota.pendingSettlements()).map((item) => item.reservationId))
        .toEqual([first.reservationId, second.reservationId]);
      const firstCountersBefore = await quotaCounters(first.actorUserId);
      const invocations: string[] = [];
      const continueQuota: ModelCallSettlementQuota = {
        async pendingSettlements(limit = 50) {
          const pending = await first.quota.pendingSettlements(limit);
          return pending.map((item) => item.reservationId === first.reservationId
            ? {
                ...item,
                usage: { ...item.usage, outputTokens: item.usage.outputTokens + 1 },
              }
            : item);
        },
        async settleModelCall(input) {
          invocations.push(input.reservationId);
          await first.quota.settleModelCall(input);
        },
      };
      const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
      try {
        await expect(recoverPendingModelCallSettlements(
          recoveryDeps(continueQuota).deps,
        )).resolves.toBeUndefined();
        expect(errSpy).toHaveBeenCalledWith(
          "[scheduler] model usage settlement recovery failed",
          expect.objectContaining({
            reservationId: first.reservationId,
            err: expect.objectContaining({ code: "idempotency_conflict" }),
          }),
        );
      } finally {
        errSpy.mockRestore();
      }

      // A whole-batch catch stops after the first conflict and fails here.
      expect(invocations).toEqual([first.reservationId, second.reservationId]);
      expect(await db.$client`
        SELECT state, actual_input_tokens::int, actual_output_tokens::int,
               provider_model, cost_usd::text, cost_source
          FROM usage_quota_reservations WHERE id = ${first.reservationId}`)
        .toEqual([{
          state: "reserved",
          actual_input_tokens: 7,
          actual_output_tokens: 8,
          provider_model: "provider/recovered",
          cost_usd: "0.0000000007",
          cost_source: "provider",
        }]);
      expect(await first.quota.pendingSettlements()).toEqual([{
        reservationId: first.reservationId,
        usage: first.usage,
      }]);
      expect(await db.$client`
        SELECT count(*)::int AS count FROM run_usage
         WHERE quota_reservation_id = ${first.reservationId}`)
        .toEqual([{ count: 0 }]);
      expect(await quotaCounters(first.actorUserId)).toEqual(firstCountersBefore);

      expect(await db.$client`
        SELECT state FROM usage_quota_reservations WHERE id = ${second.reservationId}`)
        .toEqual([{ state: "settled" }]);
      expect(await db.$client`
        SELECT count(*)::int AS count,
               sum(input_tokens + output_tokens)::int AS tokens
          FROM run_usage WHERE quota_reservation_id = ${second.reservationId}`)
        .toEqual([{ count: 1, tokens: 7 }]);
      expect(await quotaCounters(second.actorUserId)).toEqual([
        {
          window_kind: "day",
          used_tokens: 7,
          reserved_tokens: 0,
          used_usd: "0.0000000007",
          reserved_usd: "0.0000000000",
        },
        {
          window_kind: "month",
          used_tokens: 7,
          reserved_tokens: 0,
          used_usd: "0.0000000007",
          reserved_usd: "0.0000000000",
        },
      ]);
    });

    it("rejects discovery failure unchanged and prevents tick schedule or queue side effects", async () => {
      const staged = await seedPendingReservation(
        "scheduler-discovery-rejection",
        { inputTokens: 2, outputTokens: 3 },
      );
      const due = await createSchedule(db, {
        userId: staged.actorUserId,
        title: "discovery failure must stop the tick",
        description: "must remain unclaimed",
        trigger: { kind: "every", seconds: 300 },
        clock: () => new Date(BASE - 300_000),
      });
      recoveryScheduleIds.push(due.id);
      expect(due.nextRunAt?.toISOString()).toBe(iso(BASE));
      const discoveryError = new Error("R1B_DISCOVERY_SENTINEL: quota read unavailable");
      let settlementCalls = 0;
      const rejectingQuota: ModelCallSettlementQuota = {
        async pendingSettlements() {
          throw discoveryError;
        },
        settleModelCall(input) {
          settlementCalls += 1;
          return staged.quota.settleModelCall(input);
        },
      };
      const { deps, adds, published } = recoveryDeps(rejectingQuota);

      await expect(recoverPendingModelCallSettlements(deps)).rejects.toBe(discoveryError);
      expect(settlementCalls).toBe(0);
      await expect(runSchedulerTick(deps)).rejects.toBe(discoveryError);
      expect(settlementCalls).toBe(0);

      const after = await schedules.getById(db, due.id);
      expect(after).toMatchObject({ status: "pending" });
      expect(after?.nextRunAt?.toISOString()).toBe(iso(BASE));
      expect(await db.$client`
        SELECT count(*)::int AS count FROM schedule_runs WHERE schedule_id = ${due.id}`)
        .toEqual([{ count: 0 }]);
      expect(await db.$client`
        SELECT count(*)::int AS count FROM runs WHERE session_id = ${due.sessionId}`)
        .toEqual([{ count: 0 }]);
      expect(await db.$client`
        SELECT count(*)::int AS count FROM messages WHERE session_id = ${due.sessionId}`)
        .toEqual([{ count: 0 }]);
      expect(adds).toEqual([]);
      expect(published).toEqual([]);
      expect(await staged.quota.pendingSettlements()).toEqual([{
        reservationId: staged.reservationId,
        usage: staged.usage,
      }]);
      expect(await db.$client`
        SELECT count(*)::int AS count FROM run_usage
         WHERE quota_reservation_id = ${staged.reservationId}`)
        .toEqual([{ count: 0 }]);
    });

    it("honors the batch limit and canonical pending-settlement order sequentially", async () => {
      const first = await seedPendingReservation(
        "scheduler-batch-first-created",
        { inputTokens: 1, outputTokens: 2 },
      );
      const second = await seedPendingReservation(
        "scheduler-batch-second-created",
        { inputTokens: 3, outputTokens: 4 },
      );
      const third = await seedPendingReservation(
        "scheduler-batch-third-created",
        { inputTokens: 5, outputTokens: 6 },
      );
      const expectedOrder = [third, first, second];
      const orderBase = Date.parse("2026-10-24T00:00:00.000Z");
      for (const [index, item] of expectedOrder.entries()) {
        await db.$client`
          UPDATE usage_quota_reservations
             SET created_at = ${new Date(orderBase + index * 1_000)}
           WHERE id = ${item.reservationId}`;
      }
      const discoveryLimits: number[] = [];
      const invocationOrder: string[] = [];
      const completionOrder: string[] = [];
      let releaseFirstSettlement!: () => void;
      const firstSettlementGate = new Promise<void>((resolve) => {
        releaseFirstSettlement = resolve;
      });
      let markFirstSettlementStarted!: () => void;
      const firstSettlementStarted = new Promise<void>((resolve) => {
        markFirstSettlementStarted = resolve;
      });
      const orderedQuota: ModelCallSettlementQuota = {
        async pendingSettlements(limit = 50) {
          discoveryLimits.push(limit);
          return first.quota.pendingSettlements(limit);
        },
        async settleModelCall(input) {
          invocationOrder.push(input.reservationId);
          if (input.reservationId === expectedOrder[0]!.reservationId) {
            markFirstSettlementStarted();
            await firstSettlementGate;
          }
          await first.quota.settleModelCall(input);
          completionOrder.push(input.reservationId);
        },
      };
      const { deps } = recoveryDeps(orderedQuota);

      const firstTwoRecovery = recoverPendingModelCallSettlements(deps, { limit: 2 });
      try {
        await firstSettlementStarted;
        // Promise.all starts the second wrapper and can complete it while the
        // first is gated; both observations discriminate concurrent replay.
        expect(invocationOrder).toEqual([expectedOrder[0]!.reservationId]);
        expect(invocationOrder).not.toContain(expectedOrder[1]!.reservationId);
        expect(completionOrder).toEqual([]);
      } finally {
        releaseFirstSettlement();
        await firstTwoRecovery;
      }

      const firstTwoIds = expectedOrder.slice(0, 2).map((item) => item.reservationId);
      expect(discoveryLimits).toEqual([2]);
      expect(invocationOrder).toEqual(firstTwoIds);
      expect(completionOrder).toEqual(firstTwoIds);
      expect((await first.quota.pendingSettlements()).map((item) => item.reservationId))
        .toEqual([second.reservationId]);

      await recoverPendingModelCallSettlements(deps);

      const allIds = expectedOrder.map((item) => item.reservationId);
      expect(discoveryLimits).toEqual([2, 50]);
      expect(invocationOrder).toEqual(allIds);
      expect(completionOrder).toEqual(allIds);
      expect(await first.quota.pendingSettlements()).toEqual([]);
      for (const item of [first, second, third]) {
        const expectedTokens = item === first ? 3 : item === second ? 7 : 11;
        expect(await db.$client`
          SELECT state FROM usage_quota_reservations WHERE id = ${item.reservationId}`)
          .toEqual([{ state: "settled" }]);
        expect(await db.$client`
          SELECT count(*)::int AS count,
                 sum(input_tokens + output_tokens)::int AS tokens
            FROM run_usage WHERE quota_reservation_id = ${item.reservationId}`)
          .toEqual([{ count: 1, tokens: expectedTokens }]);
        expect(await quotaCounters(item.actorUserId)).toEqual([
          {
            window_kind: "day",
            used_tokens: expectedTokens,
            reserved_tokens: 0,
            used_usd: "0.0000000007",
            reserved_usd: "0.0000000000",
          },
          {
            window_kind: "month",
            used_tokens: expectedTokens,
            reserved_tokens: 0,
            used_usd: "0.0000000007",
            reserved_usd: "0.0000000000",
          },
        ]);
      }
    });

    it("rejects invalid recovery limits through canonical validation before settlement", async () => {
      const staged = await seedPendingReservation(
        "scheduler-invalid-recovery-limit",
        { inputTokens: 2, outputTokens: 3 },
      );
      const countersBefore = await quotaCounters(staged.actorUserId);
      const invalidLimits = [0, 1.5, 101];
      const observedLimits: number[] = [];
      let settlementCalls = 0;
      const validatingQuota: ModelCallSettlementQuota = {
        pendingSettlements(limit = 50) {
          observedLimits.push(limit);
          return staged.quota.pendingSettlements(limit);
        },
        settleModelCall(input) {
          settlementCalls += 1;
          return staged.quota.settleModelCall(input);
        },
      };
      const { deps } = recoveryDeps(validatingQuota);

      for (const limit of invalidLimits) {
        await expect(recoverPendingModelCallSettlements(deps, { limit }))
          .rejects.toMatchObject({
            name: "RangeError",
            message: "settlement recovery limit must be an integer from 1 to 100",
          });
        expect(settlementCalls).toBe(0);
        expect(await staged.quota.pendingSettlements()).toEqual([{
          reservationId: staged.reservationId,
          usage: staged.usage,
        }]);
        expect(await db.$client`
          SELECT count(*)::int AS count FROM run_usage
           WHERE quota_reservation_id = ${staged.reservationId}`)
          .toEqual([{ count: 0 }]);
        expect(await quotaCounters(staged.actorUserId)).toEqual(countersBefore);
      }
      expect(observedLimits).toEqual(invalidLimits);
    });

    it("composes real recovery into a tick without firing a schedule or starting deferred work", async () => {
      const staged = await seedPendingReservation(
        "scheduler-tick-recovery",
        { inputTokens: 9, outputTokens: 10 },
      );
      const future = await createSchedule(db, {
        userId: staged.actorUserId,
        title: "not due",
        description: "must not fire during recovery",
        trigger: { kind: "every", seconds: 300 },
        clock: () => new Date(BASE),
      });
      recoveryScheduleIds.push(future.id);
      const batchId = newId();
      const deferredRequestId = newId();
      const requestedAt = new Date(BASE);
      // Direct durable fixture only: this is a scheduler no-auto-start guard,
      // not an admission, supervisor, parent-wake, or descendant proof.
      await db.$client`
        INSERT INTO subagent_batches
          (id, session_id, user_id, root_task_run_id, parent_run_id,
           requested_at, request_count, deferred_count)
        VALUES
          (${batchId}, ${staged.session.id}, ${staged.actorUserId},
           ${staged.run.id}, ${staged.run.id}, ${requestedAt}, 1, 1)`;
      await db.$client`
        INSERT INTO subagent_dispatches
          (id, batch_id, request_index, session_id, user_id,
           root_task_run_id, parent_run_id, prompt, provenance,
           requested_at, actor_user_id, state, defer_reason,
           requested_sequence, deferred_at)
        VALUES
          (${deferredRequestId}, ${batchId}, 0, ${staged.session.id},
           ${staged.actorUserId}, ${staged.run.id}, ${staged.run.id},
           'remain deferred through scheduler recovery', 'server',
           ${requestedAt}, ${staged.actorUserId}, 'awaiting_next_user_task',
           'capacity_exhausted', ${BASE}, ${requestedAt})`;
      const calls: string[] = [];
      const observingQuota: ModelCallSettlementQuota = {
        async pendingSettlements(limit = 50) {
          calls.push(`discover:${limit}`);
          return staged.quota.pendingSettlements(limit);
        },
        async settleModelCall(input) {
          calls.push(`settle:${input.reservationId}`);
          await staged.quota.settleModelCall(input);
        },
      };
      const { deps, adds, published } = recoveryDeps(observingQuota);

      const report = await runSchedulerTick(deps);

      expect(calls).toEqual(["discover:50", `settle:${staged.reservationId}`]);
      expect(report).toEqual({
        fired: 0,
        retried: 0,
        skipped: 0,
        paused: 0,
        deferred: 0,
        duplicates: 0,
      });
      expect(await db.$client`
        SELECT state FROM usage_quota_reservations WHERE id = ${staged.reservationId}`)
        .toEqual([{ state: "settled" }]);
      expect(await db.$client`
        SELECT count(*)::int AS count FROM run_usage
         WHERE quota_reservation_id = ${staged.reservationId}`)
        .toEqual([{ count: 1 }]);
      expect(await db.$client`
        SELECT count(*)::int AS count FROM schedule_runs WHERE schedule_id = ${future.id}`)
        .toEqual([{ count: 0 }]);
      expect(await db.$client`
        SELECT state, admitted_at, first_message_id,
               (SELECT count(*)::int FROM subagent_logical_workers
                 WHERE request_id = ${deferredRequestId}) AS workers,
               (SELECT count(*)::int FROM subagent_attempts
                 WHERE session_id = ${staged.session.id}) AS attempts
          FROM subagent_dispatches WHERE id = ${deferredRequestId}`)
        .toEqual([{
          state: "awaiting_next_user_task",
          admitted_at: null,
          first_message_id: null,
          workers: 0,
          attempts: 0,
        }]);
      expect(await db.$client`
        SELECT count(*)::int AS count FROM runs WHERE session_id = ${staged.session.id}`)
        .toEqual([{ count: 1 }]);
      expect(adds).toEqual([]);
      expect(published).toEqual([]);
    });
  },
);
