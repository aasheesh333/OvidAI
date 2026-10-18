import { Redis } from "ioredis";
import {
  createDb,
  messages,
  runs,
  schedules,
  sessions,
  users,
  type Db,
} from "@ovid/db";
import { createRedisEventLog, createRedisSystemBus } from "@ovid/events";
import type { EventLog, SystemBus } from "@ovid/events";
import type { QueueServices } from "@ovid/queue";
import {
  runSchedulerTick,
  sweepStaleRuns,
} from "@ovid/worker";
import type {
  Assertion,
  ChaosContext,
  ChaosScenario,
  GateResult,
} from "../runner.js";
import {
  closeClients,
  openClients,
  readHealth,
  sleep,
  waitFor,
  type ChaosClient,
} from "../helpers.js";
import { evaluateStagingTarget } from "./workerKill.js";
import { createScenarioQueues } from "./redisQRestart.js";

/** Injected clocks only: the host clock must not move during the scenario. */
export const HOST_CLOCK_DRIFT_LIMIT_MS = 5_000;

/**
 * clock-skew — scheduler sanity and stale-run semantics WITHOUT touching the
 * host clock.
 *
 * Locked assertions (plan): three schedules (one `at`, two `every`) exist;
 * the tick is driven through the P4 injected-clock seam (`SchedulerDeps.clock`
 * → `runSchedulerTick`); the `at` schedule fires exactly once, the `every`
 * schedules fire at least once across a simulated 12+ minute window, and the
 * claim ledger has zero duplicate `(schedule_id, scheduled_for)` rows. The
 * scenario also re-runs the Step-1 sweep evidence in-process: a forward jump
 * terminalizes only genuinely stale runs, a backward jump terminalizes none,
 * and two concurrent sweeps emit exactly one `run_failed`.
 *
 * Safety: `Date.now()` is recorded before/after and must drift < 5 s. No
 * `date`, `clock_settime`, `TZ`, or wall-clock mutation is ever performed.
 *
 * The staging worker stays alive: it must drain the runs fired by the
 * injected tick. Its own real-clock tick cannot race the scenario because
 * every created schedule's `nextRunAt` is at least 2 minutes in the future
 * when the scenario starts.
 */

export interface ScheduleLedgerRow {  scheduleId: string;
  scheduledFor: string;
}

export interface ScheduleLedgerSummary {
  total: number;
  perSchedule: Record<string, number>;
  duplicateKeys: string[];
}

/** Pure ledger summary (unit-tested): duplicate occurrence detection. */
export function summarizeScheduleLedger(
  rows: ScheduleLedgerRow[],
): ScheduleLedgerSummary {
  const perSchedule: Record<string, number> = {};
  const seen = new Set<string>();
  const duplicateKeys = new Set<string>();
  for (const row of rows) {
    perSchedule[row.scheduleId] = (perSchedule[row.scheduleId] ?? 0) + 1;
    const key = `${row.scheduleId}@${row.scheduledFor}`;
    if (seen.has(key)) duplicateKeys.add(key);
    else seen.add(key);
  }
  return {
    total: rows.length,
    perSchedule,
    duplicateKeys: [...duplicateKeys].sort(),
  };
}

export interface ClockSkewGateState {
  scheduleIds: string[];
  expectedSchedules: number;
  pending: number;
  workerAlive: boolean;
  healthStatus: "ok" | "degraded" | "unreachable";
  targetProblems: string[];
}

/** Pure gate (unit-tested). */
export function evaluateClockSkewGate(state: ClockSkewGateState): GateResult {
  const problems: string[] = [];
  if (state.targetProblems.length > 0) problems.push(...state.targetProblems);
  if (state.scheduleIds.length !== state.expectedSchedules) {
    problems.push(
      `prepared ${state.scheduleIds.length} schedule(s), expected ${state.expectedSchedules}`,
    );
  }
  if (state.pending !== state.expectedSchedules) {
    problems.push(
      `${state.pending}/${state.expectedSchedules} schedules are pending — a schedule already fired or paused before the injected tick`,
    );
  }
  if (!state.workerAlive) {
    problems.push(
      "staging worker is not alive — the runs fired by the injected tick would never drain",
    );
  }
  if (state.healthStatus !== "ok") {
    problems.push(`gateway health is '${state.healthStatus}', expected 'ok'`);
  }
  if (problems.length > 0) return { ok: false, detail: problems.join("; ") };
  return {
    ok: true,
    detail: `${state.pending} pending schedule(s), staging worker alive, health ok; injection will use an injected clock only`,
  };
}

export interface ClockSkewOutcomeState {
  atLedgerCount: number;
  everyLedgerCounts: number[];
  duplicateKeys: string[];
  doubleTickLedgerDelta: number;
  hostClockDriftMs: number;
  forwardSwept: number;
  backwardSwept: number;
  forwardFreshUntouched: boolean;
  backwardRowsUntouched: boolean;
  sweepDuplicateEvents: number;
  targetProblems: string[];
}

/** Pure outcome evaluator (unit-tested). */
export function evaluateClockSkewOutcome(
  state: ClockSkewOutcomeState,
): Assertion[] {
  return [
    {
      name: "at-fires-exactly-once",
      passed: state.atLedgerCount === 1,
      detail: `at-schedule ledger rows: ${state.atLedgerCount} (expected 1)`,
    },
    {
      name: "every-schedules-fire",
      passed:
        state.everyLedgerCounts.length > 0 &&
        state.everyLedgerCounts.every((count) => count >= 1),
      detail: `every-schedule ledger rows: [${state.everyLedgerCounts.join(", ")}] (each expected >= 1 across the simulated window)`,
    },
    {
      name: "ledger-no-duplicates",
      passed: state.duplicateKeys.length === 0,
      detail:
        state.duplicateKeys.length === 0
          ? "zero duplicate (schedule_id, scheduled_for) claims"
          : `duplicate claims: ${state.duplicateKeys.join(", ")}`,
    },
    {
      name: "double-tick-no-duplicate",
      passed: state.doubleTickLedgerDelta === 0,
      detail: `duplicate claims produced by the concurrent double tick: ${state.doubleTickLedgerDelta} (expected 0)`,
    },
    {
      name: "host-clock-untouched",
      passed: state.hostClockDriftMs <= HOST_CLOCK_DRIFT_LIMIT_MS,
      detail: `host clock drift during the scenario: ${state.hostClockDriftMs}ms (injected clocks only; expected < 5000ms)`,
    },
    {
      name: "forward-jump-scoped",
      passed: state.forwardSwept === 1 && state.forwardFreshUntouched,
      detail: `forward jump swept ${state.forwardSwept} stale run(s); the fresh run was untouched: ${state.forwardFreshUntouched}`,
    },
    {
      name: "backward-jump-safe",
      passed: state.backwardSwept === 0 && state.backwardRowsUntouched,
      detail: `backward jump swept ${state.backwardSwept} run(s); rows untouched: ${state.backwardRowsUntouched}`,
    },
    {
      name: "sweep-claim-once",
      passed: state.sweepDuplicateEvents === 1,
      detail: `run_failed events for the double-swept run: ${state.sweepDuplicateEvents} (claim-then-emit must produce exactly 1)`,
    },
  ];
}

// ---------------------------------------------------------------------------
// REST + ledger helpers
// ---------------------------------------------------------------------------

interface ScheduleHandle {
  id: string;
  uid: string;
  kind: "at" | "every";
  nextRunAtMs: number;
  sessionId: string;
}

async function createSchedule(
  baseUrl: string,
  uid: string,
  sessionId: string,
  trigger: Record<string, unknown>,
  title: string,
): Promise<{ id: string; nextRunAt: string }> {
  const response = await fetch(
    `${baseUrl.replace(/\/+$/, "")}/cloud/v1/schedules`,
    {
      method: "POST",
      headers: {
        authorization: `Bearer test:${uid}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        title,
        description: `clock-skew scenario: ${title}`,
        trigger,
        autonomy: "safe",
        sessionId,
      }),
      signal: AbortSignal.timeout(10_000),
    },
  );
  const text = await response.text();
  if (response.status !== 201) {
    throw new Error(`schedule create ${title}: HTTP ${response.status} ${text}`);
  }
  const dto = JSON.parse(text) as { id?: unknown; nextRunAt?: unknown };
  if (typeof dto.id !== "string" || typeof dto.nextRunAt !== "string") {
    throw new Error(`schedule create ${title}: malformed DTO ${text}`);
  }
  return { id: dto.id, nextRunAt: dto.nextRunAt };
}

async function deleteSchedule(
  baseUrl: string,
  uid: string,
  id: string,
): Promise<void> {
  await fetch(
    `${baseUrl.replace(/\/+$/, "")}/cloud/v1/schedules/${encodeURIComponent(id)}`,
    {
      method: "DELETE",
      headers: { authorization: `Bearer test:${uid}` },
      signal: AbortSignal.timeout(5_000),
    },
  ).catch(() => {});
}

async function readLedger(
  db: Db,
  scheduleIds: string[],
): Promise<ScheduleLedgerRow[]> {
  const rows = (await db.$client.unsafe(
    "SELECT schedule_id, scheduled_for FROM schedule_runs WHERE schedule_id = ANY($1::text[]) ORDER BY scheduled_for",
    [scheduleIds],
  )) as Array<{ schedule_id: string; scheduled_for: Date | string }>;
  return rows.map((row) => ({
    scheduleId: row.schedule_id,
    scheduledFor:
      row.scheduled_for instanceof Date
        ? row.scheduled_for.toISOString()
        : String(row.scheduled_for),
  }));
}

function duplicateCount(rows: ScheduleLedgerRow[]): number {
  return summarizeScheduleLedger(rows).duplicateKeys.length;
}

// ---------------------------------------------------------------------------
// Scenario
// ---------------------------------------------------------------------------

interface Prepared {
  clients: ChaosClient[];
  scheduleHandles: ScheduleHandle[];
  atHandle: ScheduleHandle;
  everyHandles: ScheduleHandle[];
  db: Db;
  redis: Redis;
  log: EventLog;
  system: SystemBus;
  queues: QueueServices;
  targetProblems: string[];
  hostNowBeforeMs: number;
  hostMonoBeforeNs: bigint;
  atLedgerCount: number;
  everyLedgerCounts: number[];
  duplicateKeys: string[];
  doubleTickLedgerDelta: number;
  forwardSwept: number;
  backwardSwept: number;
  forwardFreshUntouched: boolean;
  backwardRowsUntouched: boolean;
  sweepDuplicateEvents: number;
  seededRuns: string[];
  seededSessions: string[];
}

const STALE_AFTER_MS = 600_000;

export const clockSkewScenario: ChaosScenario<Prepared> = {
  name: "clock-skew",
  precondition:
    "three pending schedules (one at +2min, two every 300s) exist against staging, the staging worker is alive to drain fired runs, and the target is proven staging; injection uses SchedulerDeps.clock only",

  async prepare(ctx: ChaosContext): Promise<Prepared> {
    const baseUrl = ctx.env.STAGING_GATEWAY_URL ?? "";
    const redisQUrl = ctx.env.STAGING_REDIS_Q_URL ?? "";
    const databaseUrl = ctx.env.STAGING_DATABASE_URL ?? "";
    const tag = `clockskew-${Date.now().toString(36)}`;
    const targetProblems = evaluateStagingTarget(ctx.env);
    const hostNowBeforeMs = Date.now();
    const hostMonoBeforeNs = process.hrtime.bigint();

    // One session per schedule: a fired run makes the session busy, and two
    // schedules sharing a session would defer each other.
    const clients = await openClients({ baseUrl, count: 3, tag });
    const createdIds: string[] = [];
    try {
      const atAt = new Date(Date.now() + 120_000).toISOString();
      // Sequential creates so `createdIds` is accurate even when a later
      // create fails: the catch below can then delete every schedule that
      // was actually created (F6/F8 — no recurring schedule left behind).
      const specs = [
        {
          uid: clients[0]!.uid,
          sessionId: clients[0]!.sessionId,
          trigger: { kind: "at", at: atAt },
          title: `${tag} at`,
        },
        {
          uid: clients[1]!.uid,
          sessionId: clients[1]!.sessionId,
          trigger: { kind: "every", seconds: 300 },
          title: `${tag} every-1`,
        },
        {
          uid: clients[2]!.uid,
          sessionId: clients[2]!.sessionId,
          trigger: { kind: "every", seconds: 300 },
          title: `${tag} every-2`,
        },
      ];
      const created: Array<{ id: string; nextRunAt: string }> = [];
      for (const spec of specs) {
        const row = await createSchedule(
          baseUrl,
          spec.uid,
          spec.sessionId,
          spec.trigger,
          spec.title,
        );
        created.push(row);
        createdIds.push(row.id);
      }
      const scheduleHandles: ScheduleHandle[] = created.map((row, index) => ({
        id: row.id,
        uid: clients[index]!.uid,
        kind: index === 0 ? "at" : "every",
        nextRunAtMs: Date.parse(row.nextRunAt),
        sessionId: clients[index]!.sessionId,
      }));

      const db = createDb(databaseUrl);
      const redis = new Redis(redisQUrl, { maxRetriesPerRequest: 2 });
      redis.on("error", () => {});
      const log = createRedisEventLog(redis);
      const system = createRedisSystemBus(redis);
      // F2: derive the queue keys EXACTLY like the gateway/worker mains —
      // they pass NO prefix, so BullMQ's default `bull` applies. Reading
      // `BULL_PREFIX` here inspected `bull:staging:agent-runs`, which no
      // worker consumes (the fired runs never left `queued` and drain timed
      // out). Same derivation and unit pin as Task 6's redis-q-restart.
      const queues = createScenarioQueues(redisQUrl);
      for (const queue of Object.values(queues)) {
        queue?.on("error", () => {});
      }

      return {
        clients,
        scheduleHandles,
        atHandle: scheduleHandles[0]!,
        everyHandles: scheduleHandles.slice(1),
        db,
        redis,
        log,
        system,
        queues,
        targetProblems,
        hostNowBeforeMs,
        hostMonoBeforeNs,
        atLedgerCount: 0,
        everyLedgerCounts: [],
        duplicateKeys: [],
        doubleTickLedgerDelta: 0,
        forwardSwept: 0,
        backwardSwept: 0,
        forwardFreshUntouched: false,
        backwardRowsUntouched: false,
        sweepDuplicateEvents: 0,
        seededRuns: [],
        seededSessions: [],
      };
    } catch (err) {
      // The runner does not call cleanup when prepare throws: cancel any
      // schedules we created and close the clients.
      await Promise.all(
        createdIds.map((id, index) =>
          deleteSchedule(baseUrl, clients[index]!.uid, id),
        ),
      );
      await closeClients(clients).catch(() => {});
      throw err;
    }
  },

  async gate(ctx: ChaosContext, prepared: Prepared): Promise<GateResult> {
    let pending = 0;
    for (const handle of prepared.scheduleHandles) {
      const row = await schedules.getById(prepared.db, handle.id);
      if (row !== null && row.status === "pending" && row.nextRunAt !== null) {
        pending += 1;
      }
    }
    const health = await readHealth(ctx.env.STAGING_GATEWAY_URL ?? "");
    return evaluateClockSkewGate({
      scheduleIds: prepared.scheduleHandles.map((handle) => handle.id),
      expectedSchedules: 3,
      pending,
      workerAlive: await ctx.staging.workerAlive(),
      healthStatus: health.status,
      targetProblems: prepared.targetProblems,
    });
  },

  async inject(_ctx: ChaosContext, prepared: Prepared): Promise<void> {
    const tick = (nowMs: number) =>
      runSchedulerTick({
        db: prepared.db,
        queues: prepared.queues,
        system: prepared.system,
        clock: () => new Date(nowMs),
      });

    const drain = async (handle: ScheduleHandle): Promise<void> => {
      await waitFor(
        `runs drained for ${handle.sessionId}`,
        async () => ((await runs.activeForSession(prepared.db, handle.sessionId)) === null ? true : null),
        90_000,
        250,
      );
    };

    // 1. Fire the one-off at its own slot, one second later.
    await tick(prepared.atHandle.nextRunAtMs + 1_000);
    await drain(prepared.atHandle);

    // 2. Fire both `every` schedules at their first slot.
    const firstEvery = Math.min(
      ...prepared.everyHandles.map((handle) => handle.nextRunAtMs),
    );
    await tick(firstEvery + 1_000);
    for (const handle of prepared.everyHandles) await drain(handle);

    // 3. A concurrent double tick at the next slot must claim each occurrence
    //    exactly once. Measure duplicate pairs produced by the pair of ticks.
    const beforeDouble = await readLedger(
      prepared.db,
      prepared.scheduleHandles.map((handle) => handle.id),
    );
    await Promise.all([tick(firstEvery + 301_000), tick(firstEvery + 301_000)]);
    for (const handle of prepared.everyHandles) await drain(handle);
    const afterDouble = await readLedger(
      prepared.db,
      prepared.scheduleHandles.map((handle) => handle.id),
    );
    prepared.doubleTickLedgerDelta =
      duplicateCount(afterDouble) - duplicateCount(beforeDouble);

    // 4. Two more every slots: a 12+ minute simulated window (900 s).
    await tick(firstEvery + 601_000);
    for (const handle of prepared.everyHandles) await drain(handle);
    await tick(firstEvery + 901_000);
    for (const handle of prepared.everyHandles) await drain(handle);

    // 5. Ledger summary.
    const ledger = await readLedger(
      prepared.db,
      prepared.scheduleHandles.map((handle) => handle.id),
    );
    const summary = summarizeScheduleLedger(ledger);
    prepared.atLedgerCount = summary.perSchedule[prepared.atHandle.id] ?? 0;
    prepared.everyLedgerCounts = prepared.everyHandles.map(
      (handle) => summary.perSchedule[handle.id] ?? 0,
    );
    prepared.duplicateKeys = summary.duplicateKeys;

    // 6. Re-run the Step-1 sweep evidence against staging Postgres. All
    //    seeded timestamps are in the FUTURE relative to the real clock, so
    //    the live worker's own 60 s real-clock sweep cannot touch them; the
    //    injected clocks make them stale/fresh as each leg requires.
    const realNow = Date.now();
    const forwardNow = realNow + 30 * 60_000;
    const backwardNow = forwardNow - 2 * 60 * 60_000;

    const seed = async (startedAtMs: number) => {
      const userUid = `skew-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
      await users.ensure(prepared.db, userUid, `${userUid}@stub.test`);
      const session = await sessions.create(prepared.db, userUid);
      prepared.seededSessions.push(session.id);
      const prompt = await messages.append(prepared.db, {
        sessionId: session.id,
        role: "user",
        content: "clock-skew evidence",
      });
      const run = await runs.create(prepared.db, {
        sessionId: session.id,
        promptMessageId: prompt.id,
      });
      prepared.seededRuns.push(run.id);
      await runs.claimNext(prepared.db, run.id);
      await prepared.db.$client.unsafe(
        "UPDATE runs SET started_at = $1 WHERE id = $2",
        [new Date(startedAtMs).toISOString(), run.id],
      );
      return { runId: run.id, sessionId: session.id };
    };

    const runStatus = async (runId: string): Promise<string> => {
      const rows = (await prepared.db.$client.unsafe(
        "SELECT status FROM runs WHERE id = $1",
        [runId],
      )) as Array<{ status: string }>;
      return rows[0]?.status ?? "missing";
    };

    const eventsFor = (sessionId: string) =>
      prepared.log.readSince(sessionId, null, 100);

    const sweep = (clockMs: number) =>
      sweepStaleRuns(
        { db: prepared.db, events: prepared.log, clock: () => new Date(clockMs) },
        { staleAfterMs: STALE_AFTER_MS },
      );

    // Forward: only the 20-min-old row is stale at the injected now.
    const stale = await seed(realNow + 10 * 60_000);
    const fresh = await seed(realNow + 29 * 60_000);
    await sweep(forwardNow);
    prepared.forwardSwept = (await runStatus(stale.runId)) === "failed" ? 1 : 0;
    prepared.forwardFreshUntouched = (await runStatus(fresh.runId)) === "running";

    // Backward: nothing is stale under a -2 h injected clock.
    const backwardA = await seed(realNow + 10 * 60_000);
    const backwardB = await seed(realNow + 29 * 60_000);
    await sweep(backwardNow);
    prepared.backwardSwept =
      (await runStatus(backwardA.runId)) === "failed" ||
      (await runStatus(backwardB.runId)) === "failed"
        ? 1
        : 0;
    prepared.backwardRowsUntouched =
      (await runStatus(backwardA.runId)) === "running" &&
      (await runStatus(backwardB.runId)) === "running";

    // Double claim: both injected clocks call the row stale.
    const doubleClaim = await seed(realNow + 10 * 60_000);
    await Promise.all([sweep(forwardNow), sweep(forwardNow - 5 * 60_000)]);
    prepared.sweepDuplicateEvents = (await eventsFor(doubleClaim.sessionId)).filter(
      (event) =>
        event.type === "run_failed" &&
        event.payload.runId === doubleClaim.runId,
    ).length;

    // Never touch the host clock: give it a moment to be sure.
    await sleep(0);
  },

  async verify(_ctx: ChaosContext, prepared: Prepared): Promise<Assertion[]> {
    // A wall-clock jump is detectable by comparing elapsed wall time with the
    // monotonic clock: both should advance together. This lets the scenario
    // take as long as the real-time drains need without conflating duration
    // with a clock change.
    const wallDeltaMs = Date.now() - prepared.hostNowBeforeMs;
    const monoDeltaMs =
      Number(process.hrtime.bigint() - prepared.hostMonoBeforeNs) / 1_000_000;
    const hostClockDriftMs = Math.abs(wallDeltaMs - monoDeltaMs);
    return evaluateClockSkewOutcome({
      atLedgerCount: prepared.atLedgerCount,
      everyLedgerCounts: prepared.everyLedgerCounts,
      duplicateKeys: prepared.duplicateKeys,
      doubleTickLedgerDelta: prepared.doubleTickLedgerDelta,
      hostClockDriftMs,
      forwardSwept: prepared.forwardSwept,
      backwardSwept: prepared.backwardSwept,
      forwardFreshUntouched: prepared.forwardFreshUntouched,
      backwardRowsUntouched: prepared.backwardRowsUntouched,
      sweepDuplicateEvents: prepared.sweepDuplicateEvents,
      targetProblems: prepared.targetProblems,
    });
  },

  async cleanup(ctx: ChaosContext, prepared: Prepared | undefined): Promise<void> {
    // F8: prepare's catch unwinds its own partial state when prepared is
    // undefined (the runner calls cleanup(ctx, undefined) in that path).
    if (prepared === undefined) return;

    // F6: delete the REST schedules. The `at` one is done, but the two
    // `every 300` schedules would keep firing runs into staging forever.
    const baseUrl = ctx.env.STAGING_GATEWAY_URL ?? "";
    await Promise.allSettled(
      prepared.scheduleHandles.map((handle) =>
        deleteSchedule(baseUrl, handle.uid, handle.id),
      ),
    );

    // The evidence rows are deliberately seeded as 'running'; terminalize
    // ours so a later real-clock sweep never mistakes them for stranded work.
    for (const runId of prepared.seededRuns) {
      const rows = (await prepared.db.$client
        .unsafe("SELECT status FROM runs WHERE id = $1", [runId])
        .catch(() => [])) as Array<{ status?: string }>;
      if (rows[0]?.status === "running") {
        await runs
          .finish(prepared.db, runId, "failed", "clock-skew scenario cleanup")
          .catch(() => {});
      }
    }
    if (prepared.seededSessions.length > 0) {
      await prepared.redis
        .del(...prepared.seededSessions.map((id) => `sess:${id}:events`))
        .catch(() => {});
    }
    await closeClients(prepared.clients);
    await Promise.allSettled(
      Object.values(prepared.queues)
        .filter((queue): queue is NonNullable<typeof queue> => queue !== undefined)
        .map((queue) => queue.close()),
    );
    await prepared.redis.quit().catch(() => {});
    await prepared.db.$client.end({ timeout: 5 }).catch(() => {});
  },
};
