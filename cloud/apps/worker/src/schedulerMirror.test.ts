/**
 * P4 Task 10 — the boot mirror resync + the schedules-mirror fire processor.
 *
 * Cases (a)/(b) use REAL Redis queues under a suite-unique BullMQ prefix
 * (`OVID_TEST_QUEUE_PREFIX` + `-sched`) because mirror behavior needs real
 * delayed-job semantics; cleanup obliterates ONLY this suite's prefixed
 * `schedules` queue (P1 fix-wave discipline). Case (c) invokes the processor
 * directly against a capturing queue/system stub and injected clock, so no
 * wall-time waiting is involved.
 */

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  createDb,
  migrate,
  schedules,
  scheduleRuns,
  sessions,
  users,
  type Db,
  type ScheduleRow,
  type ScheduleTrigger,
} from "@ovid/db";
import type { SystemBus } from "@ovid/events";
import type { SystemEvent } from "@ovid/shared";
import { createQueues, type QueueServices } from "@ovid/queue";
import { loadWorkerEnv } from "./main.js";
import { createScheduleFireProcessor, resyncScheduleMirror } from "./schedulerMirror.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

// Parallel suites share the dev redis — only ever touch this suite's keys.
const QUEUE_PREFIX = process.env.OVID_TEST_QUEUE_PREFIX
  ? `${process.env.OVID_TEST_QUEUE_PREFIX}-sched`
  : "ovid-test-sched";

const T = new Date("2026-10-17T12:00:00.000Z");

interface CapturedAdd {
  queue: "agentRuns" | "schedules";
  name: string;
  data: unknown;
  opts: Record<string, unknown>;
}

/** Capturing stub for the two queues `fireScheduleOccurrence` touches. */
function stubQueues(): { queues: QueueServices; adds: CapturedAdd[] } {
  const adds: CapturedAdd[] = [];
  const queues = {
    agentRuns: {
      add: async (name: string, data: unknown, opts?: Record<string, unknown>) => {
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

function stubSystem(): { system: SystemBus; published: Array<{ uid: string; event: SystemEvent }> } {
  const published: Array<{ uid: string; event: SystemEvent }> = [];
  const system: SystemBus = {
    async publish(uid, event) {
      published.push({ uid, event });
    },
    async subscribe() {
      return async () => {};
    },
  };
  return { system, published };
}

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)(
  "resyncScheduleMirror + createScheduleFireProcessor (real db + real redis)",
  () => {
    let db: Db;
    let queues: ReturnType<typeof createQueues>;
    let uid: string;
    let sessionId: string;
    const seeded: string[] = [];

    beforeAll(async () => {
      await migrate(TEST_DATABASE_URL!);
      db = createDb(TEST_DATABASE_URL!);
      uid = `sm-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
      await users.ensure(db, uid, null);
      const session = await sessions.create(db, uid, "Mirror suite");
      sessionId = session.id;
      queues = createQueues({ url: TEST_REDIS_URL! }, { prefix: QUEUE_PREFIX });
      // Previous run of THIS suite may have left delayed jobs behind.
      await queues.schedules.obliterate({ force: true });
    }, 60_000);

    afterAll(async () => {
      for (const id of seeded) {
        await schedules.update(db, id, { status: "cancelled" }).catch(() => {});
      }
      if (queues !== undefined) {
        // ONLY this suite's prefixed queue — never another suite's keys.
        await queues.schedules.obliterate({ force: true });
        await queues.agentRuns.close();
        await queues.hibernate.close();
        await queues.hydrate.close();
        await queues.schedules.close();
      }
      await db?.$client.end({ timeout: 5 });
    });

    async function seedSchedule(o: {
      title: string;
      nextRunAt: Date | null;
      trigger?: ScheduleTrigger;
    }): Promise<ScheduleRow> {
      const row = await schedules.create(db, {
        userId: uid,
        sessionId,
        title: o.title,
        description: `description for ${o.title}`,
        trigger: o.trigger ?? { kind: "every", seconds: 300 },
        autonomy: "safe",
        maxRetries: 0,
        nextRunAt: o.nextRunAt,
      });
      seeded.push(row.id);
      return row;
    }

    let caseAIds: string[] = [];

    it("(a) resyncs every pending schedule with nextRunAt and returns the count", async () => {
      const now = new Date("2026-10-17T12:00:00.000Z");
      const soon = await seedSchedule({
        title: "soon",
        nextRunAt: new Date(now.getTime() + 60_000),
      });
      const later = await seedSchedule({
        title: "later",
        nextRunAt: new Date(now.getTime() + 120_000),
      });
      // Past occurrence → delay clamps to 1 ms and the job becomes waitable.
      const past = await seedSchedule({
        title: "past",
        nextRunAt: new Date(now.getTime() - 5_000),
      });
      const paused = await seedSchedule({
        title: "paused",
        nextRunAt: new Date(now.getTime() + 60_000),
      });
      await schedules.update(db, paused.id, { status: "paused" });
      await seedSchedule({ title: "no next run", nextRunAt: null });

      // The shared dev DB may carry pending rows from other suites: assert on
      // OUR rows' jobs rather than the global return/count.
      caseAIds = [soon.id, later.id, past.id];
      const expected = new Set(caseAIds);
      const added = await resyncScheduleMirror({ db, queues, clock: () => now });
      expect(added).toBeGreaterThanOrEqual(3);

      const jobs = await queues.schedules.getJobs(["delayed", "waiting"]);
      expect(jobs.filter((j) => expected.has(j.data.scheduleId))).toHaveLength(3);
    });

    it("(b) a second resync is idempotent — deterministic jobIds keep 3 jobs", async () => {
      const now = new Date("2026-10-17T12:00:00.000Z");
      const expected = new Set(caseAIds);
      const before = (await queues.schedules.getJobs(["delayed", "waiting"])).filter((j) =>
        expected.has(j.data.scheduleId),
      );
      const added = await resyncScheduleMirror({ db, queues, clock: () => now });
      expect(added).toBeGreaterThanOrEqual(3);

      const after = (await queues.schedules.getJobs(["delayed", "waiting"])).filter((j) =>
        expected.has(j.data.scheduleId),
      );
      expect(after).toHaveLength(3);
      expect(after).toHaveLength(before.length);
    });

    it("(c) processor fires a due occurrence, no-ops stale mirrors, completes malformed data", async () => {
      const { queues: stub, adds } = stubQueues();
      const { system } = stubSystem();
      const processor = createScheduleFireProcessor({
        db,
        queues: stub,
        system,
        clock: () => T,
      });

      // Due occurrence → exactly one schedule_run ledger row + one agent-run add.
      const due = await seedSchedule({ title: "due", nextRunAt: T });
      await processor({ data: { scheduleId: due.id, scheduledFor: T.toISOString() } });
      const dueRows = await scheduleRuns.listForSchedule(db, due.id, { limit: 10 });
      expect(dueRows.rows).toHaveLength(1);
      expect(dueRows.rows[0]!.status).toBe("running");
      expect(adds.filter((a) => a.queue === "agentRuns")).toHaveLength(1);

      // The schedule advanced since the mirror was armed → normal no-op.
      const advanced = await seedSchedule({
        title: "advanced",
        nextRunAt: new Date(T.getTime() + 300_000),
      });
      await processor({
        data: { scheduleId: advanced.id, scheduledFor: T.toISOString() },
      });
      const advancedRows = await scheduleRuns.listForSchedule(db, advanced.id, { limit: 10 });
      expect(advancedRows.rows).toHaveLength(0);

      // Malformed mirror payload → COMPLETE without throwing (never retried).
      await expect(
        processor({ data: { scheduleId: "", scheduledFor: T.toISOString() } }),
      ).resolves.toBeUndefined();
    });
  },
);

describe("loadWorkerEnv OVID_SCHEDULER_TICK_MS", () => {
  const baseEnv = (overrides: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv => ({
    DATABASE_URL: "postgres://postgres:ovid@127.0.0.1:5433/postgres",
    REDIS_Q_URL: "redis://127.0.0.1:6390",
    REDIS_MINT_URL: "redis://127.0.0.1:6390",
    OVID_LITELLM_BASE: "http://litellm.invalid",
    OVID_DEFAULT_MODEL: "ovid-default-model",
    OVID_INTERNAL_TOKEN: "shared-secret",
    ...overrides,
  });

  it("rejects a non-integer value, naming the variable", () => {
    expect(() => loadWorkerEnv(baseEnv({ OVID_SCHEDULER_TICK_MS: "abc" }))).toThrow(
      /OVID_SCHEDULER_TICK_MS/,
    );
    expect(() => loadWorkerEnv(baseEnv({ OVID_SCHEDULER_TICK_MS: "0" }))).toThrow(
      /OVID_SCHEDULER_TICK_MS/,
    );
  });

  it("defaults to 15 000 and accepts a positive integer", () => {
    expect(loadWorkerEnv(baseEnv()).schedulerTickMs).toBe(15_000);
    expect(loadWorkerEnv(baseEnv({ OVID_SCHEDULER_TICK_MS: "5000" })).schedulerTickMs).toBe(5_000);
  });
});
