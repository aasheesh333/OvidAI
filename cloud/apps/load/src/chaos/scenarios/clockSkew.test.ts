import { readFileSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { Redis } from "ioredis";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import {
  createDb,
  eventMirror,
  messages,
  migrate,
  runs,
  sessions,
  users,
  type Db,
} from "@ovid/db";
import { createRedisEventLog, type EventLog } from "@ovid/events";
import type { SessionEvent } from "@ovid/shared";
import { sweepStaleRuns } from "@ovid/worker";
import {
  evaluateClockSkewGate,
  evaluateClockSkewOutcome,
  summarizeScheduleLedger,
} from "./clockSkew.js";
import {
  STAGING_QUEUE_PREFIX,
  createScenarioQueues,
} from "./redisQRestart.js";

/**
 * Clock-skew evidence (Task 7 Step 1 + the scenario's re-run leg).
 *
 * ALL skew is injected through `deps.clock`; the host clock is never changed.
 * The real Postgres/Redis cases are skipped when the dev services are absent,
 * exactly like the e2e spine suite. The pure ledger/gate/outcome tests always
 * run so `pnpm --filter @ovid/load test` cannot go green on an empty file.
 *
 * Pinned PAST base (2023-11-14T22:13:20Z): every seeded timestamp and every
 * injected clock lives in 2023, so real-clock rows other suites leave behind
 * can never contaminate the assertions.
 */

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

const BASE = 1_700_000_000_000;
const STALE_AFTER_MS = 600_000; // 10 min
const FORWARD_NOW = BASE + 30 * 60_000; // 30 min after BASE

describe("summarizeScheduleLedger", () => {
  it("counts occurrences per schedule and finds duplicate (schedule_id, scheduled_for)", () => {
    const summary = summarizeScheduleLedger([
      { scheduleId: "a", scheduledFor: "2023-11-14T22:20:00.000Z" },
      { scheduleId: "a", scheduledFor: "2023-11-14T22:25:00.000Z" },
      { scheduleId: "b", scheduledFor: "2023-11-14T22:20:00.000Z" },
      { scheduleId: "a", scheduledFor: "2023-11-14T22:20:00.000Z" },
    ]);
    expect(summary.total).toBe(4);
    expect(summary.perSchedule.a).toBe(3);
    expect(summary.perSchedule.b).toBe(1);
    expect(summary.duplicateKeys).toEqual(["a@2023-11-14T22:20:00.000Z"]);
  });
});

describe("evaluateClockSkewGate", () => {
  const healthy = {
    scheduleIds: ["s1", "s2", "s3"],
    expectedSchedules: 3,
    pending: 3,
    workerAlive: true,
    healthStatus: "ok" as const,
    targetProblems: [] as string[],
  };

  it("passes with three pending schedules and a live staging worker", () => {
    expect(evaluateClockSkewGate(healthy).ok).toBe(true);
  });

  it("rejects a missing schedule", () => {
    expect(
      evaluateClockSkewGate({ ...healthy, scheduleIds: ["s1", "s2"] }).ok,
    ).toBe(false);
  });

  it("rejects a stopped worker (the fired runs would never drain)", () => {
    const result = evaluateClockSkewGate({ ...healthy, workerAlive: false });
    expect(result.ok).toBe(false);
    expect(result.detail).toContain("worker");
  });

  it("rejects a degraded gateway", () => {
    expect(
      evaluateClockSkewGate({ ...healthy, healthStatus: "degraded" }).ok,
    ).toBe(false);
  });

  it("rejects a non-staging target", () => {
    expect(
      evaluateClockSkewGate({
        ...healthy,
        targetProblems: ["production gateway host"],
      }).ok,
    ).toBe(false);
  });
});

describe("evaluateClockSkewOutcome", () => {
  const healthy = {
    atLedgerCount: 1,
    everyLedgerCounts: [4, 4],
    duplicateKeys: [] as string[],
    doubleTickLedgerDelta: 0,
    hostClockDriftMs: 12,
    forwardSwept: 1,
    backwardSwept: 0,
    forwardFreshUntouched: true,
    backwardRowsUntouched: true,
    sweepDuplicateEvents: 1,
    targetProblems: [] as string[],
  };

  function assertion(name: string, overrides: Partial<typeof healthy> = {}) {
    return evaluateClockSkewOutcome({ ...healthy, ...overrides }).find(
      (entry) => entry.name === name,
    );
  }

  it("passes every injected-clock assertion", () => {
    expect(
      evaluateClockSkewOutcome(healthy).every((entry) => entry.passed),
    ).toBe(true);
  });

  it("fails when the at schedule fires twice", () => {
    expect(assertion("at-fires-exactly-once", { atLedgerCount: 2 })?.passed).toBe(
      false,
    );
  });

  it("fails when an every schedule never fires", () => {
    expect(
      assertion("every-schedules-fire", { everyLedgerCounts: [0, 4] })?.passed,
    ).toBe(false);
  });

  it("fails when the claim ledger has a duplicate occurrence", () => {
    expect(
      assertion("ledger-no-duplicates", { duplicateKeys: ["a@t"] })?.passed,
    ).toBe(false);
  });

  it("fails when a concurrent double tick claims a second occurrence", () => {
    expect(
      assertion("double-tick-no-duplicate", { doubleTickLedgerDelta: 1 })?.passed,
    ).toBe(false);
  });

  it("fails when the host clock moved (the forbidden approach)", () => {
    expect(
      assertion("host-clock-untouched", { hostClockDriftMs: 120_000 })?.passed,
    ).toBe(false);
  });

  it("fails when a forward jump sweeps a fresh run", () => {
    expect(
      assertion("forward-jump-scoped", { forwardFreshUntouched: false })?.passed,
    ).toBe(false);
  });

  it("fails when a backward jump terminalizes a run", () => {
    expect(
      assertion("backward-jump-safe", { backwardRowsUntouched: false })?.passed,
    ).toBe(false);
  });

  it("fails when concurrent sweeps emit two run_failed events", () => {
    expect(
      assertion("sweep-claim-once", { sweepDuplicateEvents: 2 })?.passed,
    ).toBe(false);
  });
});

describe("clock-skew queue prefix matches the running stack (F2)", () => {
  it("derives the same no-prefix keys the gateway and worker use", async () => {
    expect(STAGING_QUEUE_PREFIX).toBe("bull");
    const queues = createScenarioQueues("redis://127.0.0.1:1");
    try {
      expect(queues.agentRuns.opts.prefix).toBe("bull");
      expect(queues.agentRuns.toKey("wait")).toBe("bull:agent-runs:wait");
      expect(queues.schedules.opts.prefix).toBe("bull");
      expect(queues.schedules.toKey("wait")).toBe("bull:schedules:wait");
      expect(queues.agentRuns.toKey("wait")).not.toContain("bull:staging");
    } finally {
      await Promise.allSettled(
        Object.values(queues)
          .filter(
            (queue): queue is NonNullable<typeof queue> => queue !== undefined,
          )
          .map((queue) => queue.close()),
      );
    }
  });

  it("clockSkew.ts builds queues through createScenarioQueues, never BULL_PREFIX", () => {
    const here = dirname(fileURLToPath(import.meta.url));
    const source = readFileSync(`${here}/clockSkew.ts`, "utf8");
    expect(source).toContain("createScenarioQueues(redisQUrl)");
    expect(source).not.toContain("ctx.env.BULL_PREFIX");
    expect(source).not.toMatch(/createQueues\(\{ url: redisQUrl \}, \{ prefix \}\)/);
  });
});

// ---------------------------------------------------------------------------
// F12: deterministic double-claim barrier
// ---------------------------------------------------------------------------

interface Latch {
  arrive(): Promise<void>;
  arrivals(): number;
}

/**
 * Both sweeps must finish `listStaleRunning` before either may `finish`.
 * Wrapping the drizzle select thenable gives exactly that interleaving; a
 * serialized run (list+finish, then list+finish) would let emit-first pass.
 */
function createLatch(parties: number): Latch {
  let arrived = 0;
  let release!: () => void;
  const released = new Promise<void>((resolvePromise) => {
    release = resolvePromise;
  });
  return {
    arrivals: () => arrived,
    async arrive() {
      arrived += 1;
      if (arrived >= parties) release();
      await released;
    },
  };
}

function gateThenable<T extends object>(query: T, latch: Latch): T {
  return new Proxy(query, {
    get(target, prop) {
      const value = Reflect.get(target, prop);
      if (prop === "then") {
        return (
          onFulfilled?: (rows: unknown) => unknown,
          onRejected?: (err: unknown) => unknown,
        ) =>
          new Promise((resolvePromise, rejectPromise) => {
            (
              value as (
                res: (rows: unknown) => void,
                rej: (err: unknown) => void,
              ) => void
            ).call(target, resolvePromise, rejectPromise);
          })
            .then(async (rows) => {
              await latch.arrive();
              return rows;
            })
            .then(onFulfilled, onRejected);
      }
      if (typeof value === "function") {
        return (...args: unknown[]) =>
          gateThenable(
            (value as (...inner: unknown[]) => object).apply(target, args),
            latch,
          );
      }
      return value;
    },
  }) as T;
}

/** Intercept the drizzle select chain (listStaleRunning) after it resolves. */
function barrierAfterSelect<T extends object>(db: T, latch: Latch): T {
  const select = (
    db as unknown as { select: (...args: unknown[]) => object }
  ).select.bind(db);
  // The sweeper runs TWO selects per pass (running half + queued half — the
  // zombie sweep), so a per-select barrier counts 4 arrivals. The F12
  // property under test is about the RUNNING half's claim race; gate only
  // the FIRST select per proxy. Callers pass one gated db per sweep, so
  // the shared 2-party latch sees exactly one arrival from each sweep.
  let gated = false;
  return new Proxy(db, {
    get(target, prop) {
      if (prop === "select") {
        return (...args: unknown[]) => {
          const inner = select(...args);
          if (gated) return inner;
          gated = true;
          return gateThenable(inner, latch);
        };
      }
      const value = Reflect.get(target, prop);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)(
  "sweepStaleRuns under injected clock skew (real Postgres + Redis)",
  () => {
    let db: Db;
    let redisQ: Redis;
    let events: EventLog;
    const createdSessions: string[] = [];
    const seededRuns: string[] = [];

    beforeAll(async () => {
      await migrate(TEST_DATABASE_URL!);
      db = createDb(TEST_DATABASE_URL!);
      redisQ = new Redis(TEST_REDIS_URL!);
      events = createRedisEventLog(redisQ);
    });

    afterEach(async () => {
      // Isolate the sweep counts per case: terminalize any row this case left
      // running and drop its stream, so the next case's sweep sees ONLY its
      // own seeded rows.
      for (const runId of seededRuns) {
        const rows = await db.$client
          .unsafe("SELECT status FROM runs WHERE id = $1", [runId])
          .catch(() => []);
        if ((rows[0] as { status?: string } | undefined)?.status === "running") {
          await runs
            .finish(db, runId, "failed", "clockSkew.test case cleanup")
            .catch(() => {});
        }
      }
      if (createdSessions.length > 0) {
        await redisQ
          .del(...createdSessions.map((id) => `sess:${id}:events`))
          .catch(() => {});
      }
      seededRuns.length = 0;
      createdSessions.length = 0;
    });

    afterAll(async () => {
      for (const runId of seededRuns) {
        const rows = await db.$client
          .unsafe("SELECT status FROM runs WHERE id = $1", [runId])
          .catch(() => []);
        if ((rows[0] as { status?: string } | undefined)?.status === "running") {
          await runs
            .finish(db, runId, "failed", "clockSkew.test cleanup")
            .catch(() => {});
        }
      }
      if (createdSessions.length > 0) {
        await redisQ
          .del(...createdSessions.map((id) => `sess:${id}:events`))
          .catch(() => {});
      }
      redisQ?.disconnect();
      await db?.$client.end({ timeout: 5 });
    });

    let counter = 0;
    function uid(prefix: string): string {
      counter += 1;
      return `${prefix}-${Date.now().toString(36)}-${counter}-${Math.random()
        .toString(36)
        .slice(2, 10)}`;
    }

    async function seedRunningRun(startedAt: number): Promise<{
      runId: string;
      sessionId: string;
    }> {
      const userUid = uid("skew");
      await users.ensure(db, userUid, `${userUid}@stub.test`);
      const session = await sessions.create(db, userUid);
      createdSessions.push(session.id);
      const prompt = await messages.append(db, {
        sessionId: session.id,
        role: "user",
        content: "go",
      });
      const run = await runs.create(db, {
        sessionId: session.id,
        promptMessageId: prompt.id,
      });
      seededRuns.push(run.id);
      expect(await runs.claimNext(db, run.id)).toBe(true);
      await db.$client.unsafe(
        "UPDATE runs SET started_at = $1 WHERE id = $2",
        [new Date(startedAt).toISOString(), run.id],
      );
      return { runId: run.id, sessionId: session.id };
    }

    async function runStatus(runId: string): Promise<string> {
      const rows = (await db.$client.unsafe(
        "SELECT status FROM runs WHERE id = $1",
        [runId],
      )) as Array<{ status: string }>;
      return rows[0]!.status;
    }

    const readEvents = (sessionId: string): Promise<SessionEvent[]> =>
      events.readSince(sessionId, null, 100);
    const readMirror = (sessionId: string): Promise<SessionEvent[]> =>
      eventMirror.readSince(db, sessionId, null, 100);

    const sweep = (clockMs: number, targetDb: Db = db): Promise<number> =>
      sweepStaleRuns(
        { db: targetDb, events, clock: () => new Date(clockMs) },
        { staleAfterMs: STALE_AFTER_MS },
      );

    it("forward jump terminalizes only genuinely stale runs", async () => {
      const stale = await seedRunningRun(BASE);
      const fresh = await seedRunningRun(FORWARD_NOW - 60_000);

      await sweep(FORWARD_NOW);

      const staleEvents = await readEvents(stale.sessionId);
      expect(staleEvents.map((event) => event.type)).toEqual(["run_failed"]);
      expect(staleEvents[0]!.payload).toEqual({
        runId: stale.runId,
        code: "run_lost",
      });
      expect(await readMirror(stale.sessionId)).toEqual(staleEvents);
      expect(await runStatus(stale.runId)).toBe("failed");

      expect(await runStatus(fresh.runId)).toBe("running");
      expect(await readEvents(fresh.sessionId)).toEqual([]);
    });

    it("backward jump never sweeps fresh runs (no spurious terminalization)", async () => {
      const older = await seedRunningRun(BASE);
      const fresher = await seedRunningRun(FORWARD_NOW - 60_000);
      const backwardNow = FORWARD_NOW - 2 * 60 * 60_000; // -2 h

      await sweep(backwardNow);

      for (const seeded of [older, fresher]) {
        expect(await runStatus(seeded.runId)).toBe("running");
        expect(await readEvents(seeded.sessionId)).toEqual([]);
        expect(await readMirror(seeded.sessionId)).toEqual([]);
      }
    });

    it("double-claim under skew: two concurrent sweeps emit exactly one run_failed", async () => {
      const seeded = await seedRunningRun(BASE);

      // F12 barrier: both sweeps complete listStaleRunning before either may
      // claim. Without it, a serialized interleaving would pass even if the
      // implementation emitted before claiming. One gated db PER SWEEP —
      // each gates its first select (the running-half list), so the shared
      // latch counts exactly two arrivals.
      const latch = createLatch(2);
      const gatedDbA = barrierAfterSelect(db, latch);
      const gatedDbB = barrierAfterSelect(db, latch);

      // Both clocks call the run stale (cutoffs BASE+20min and BASE+15min).
      const counts = await Promise.all([
        sweep(FORWARD_NOW, gatedDbA),
        sweep(FORWARD_NOW - 5 * 60_000, gatedDbB),
      ]);
      expect(latch.arrivals()).toBe(2);
      // Claim-then-emit: only one sweep may claim the row, even if both
      // listed it. (emit-then-finish returns 1 from both.)
      expect(counts[0]! + counts[1]!).toBe(1);

      const stream = await readEvents(seeded.sessionId);
      const failed = stream.filter(
        (event) =>
          event.type === "run_failed" &&
          (event.payload as { runId?: string }).runId === seeded.runId,
      );
      expect(failed).toHaveLength(1);
      expect(failed[0]!.payload).toEqual({ runId: seeded.runId, code: "run_lost" });

      const mirror = await readMirror(seeded.sessionId);
      expect(
        mirror.filter(
          (event) =>
            event.type === "run_failed" &&
            (event.payload as { runId?: string }).runId === seeded.runId,
        ),
      ).toHaveLength(1);
      expect(await runStatus(seeded.runId)).toBe("failed");
    });
  },
);
