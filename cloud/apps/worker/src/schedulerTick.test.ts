import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import {
  createDb,
  createSchedule,
  messages,
  migrate,
  runs,
  scheduleRuns,
  schedules,
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
import type { Notifier } from "./notify.js";
import {
  fireScheduleOccurrence,
  runSchedulerTick,
  startSchedulerLoop,
  type SchedulerDeps,
} from "./schedulerTick.js";

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
