import { randomBytes } from "node:crypto";
import { createQueues, type QueueServices } from "@ovid/queue";
import { createDb, type Db } from "@ovid/db";
import { diffIntegrity } from "../../metrics.js";
import type {
  Assertion,
  ChaosContext,
  ChaosScenario,
  GateResult,
} from "../runner.js";
import {
  aggregateEventCounts,
  closeClients,
  createGroundTruth,
  deliveredSeqs,
  errorText,
  groundTruthSeqs,
  mirrorSeqs,
  openClients,
  readHealth,
  sendRuns,
  sleep,
  waitFor,
  waitForTerminalRuns,
  type ChaosClient,
} from "../helpers.js";

/**
 * redis-q-restart — the queue survives a Redis restart without losing work.
 *
 * Locked assertions (plan): worker stopped; 10 clients enqueue 20 runs;
 * precondition `agentRuns.getWaitingCount() === 20` AND health ok AND the
 * enqueues settled >2 s before the restart (the AOF-everysec tail-loss
 * allowance); during the outage health reports `degraded {redisQ:false}` at
 * least once, then `ok`; waiting count is still 20; after the worker starts,
 * all 20 runs complete and the client-observed ledger matches ground truth
 * (0 lost / 0 duplicate / 0 mirror gaps).
 */

const EXPECTED_WAITING = 20;
const CLIENTS = 10;
const RUNS_PER_CLIENT = 2;
/** AOF everysec: enqueues must be at least this old before the restart. */
const AOF_SETTLE_MS = 2_000;

/**
 * The queue prefix the staging gateway and worker actually use.
 *
 * Their mains call `createQueues`/`createAgentRunsWorker` with NO `prefix`
 * option (`apps/gateway/src/index.ts`, `apps/worker/src/main.ts`), so BullMQ's
 * default `"bull"` applies. `.env.staging` records `BULL_PREFIX=bull` to
 * match (it once said `bull:staging`, which sent two chaos scenarios to
 * inspect `bull:staging:agent-runs`, where no job ever lands — staging is
 * isolated by its own redis-q instance, not by the prefix).
 * `queuePrefix.test.ts` pins this against the mains' real calls.
 */
export const STAGING_QUEUE_PREFIX = "bull";

/**
 * Construct the scenario's queues exactly like the gateway/worker mains: no
 * prefix option. This is the derivation — do not add `prefix` here unless the
 * mains do too.
 */
export function createScenarioQueues(redisQUrl: string): QueueServices {
  return createQueues({ url: redisQUrl });
}

export interface RedisQGateState {
  waitingCount: number;
  expectedWaiting: number;
  workerAlive: boolean;
  healthStatus: "ok" | "degraded" | "unreachable";
  enqueueSettleMs: number;
}

/** Pure gate logic (unit-tested): every clause is a proven-vulnerable-state check. */
export function evaluateRedisQGate(state: RedisQGateState): GateResult {
  const problems: string[] = [];
  if (state.waitingCount !== state.expectedWaiting) {
    problems.push(
      `waiting == ${state.waitingCount}, expected ${state.expectedWaiting} (the queue must hold the enqueued work before the restart)`,
    );
  }
  if (state.workerAlive) {
    problems.push("staging worker is still running — runs could drain before the restart");
  }
  if (state.healthStatus !== "ok") {
    problems.push(`gateway health is '${state.healthStatus}', expected 'ok'`);
  }
  if (state.enqueueSettleMs < AOF_SETTLE_MS) {
    problems.push(
      `enqueues settled ${state.enqueueSettleMs}ms before injection, need >= ${AOF_SETTLE_MS}ms (AOF everysec tail-loss allowance)`,
    );
  }
  if (problems.length > 0) {
    return { ok: false, detail: problems.join("; ") };
  }
  return {
    ok: true,
    detail: `waiting == ${state.waitingCount}, worker stopped, health ok, enqueues settled ${state.enqueueSettleMs}ms before the restart`,
  };
}

interface Prepared {
  clients: ChaosClient[];
  queues: QueueServices;
  db: Db;
  redis: ReturnType<typeof createGroundTruth>["redis"];
  log: ReturnType<typeof createGroundTruth>["log"];
  enqueuedAtMs: number;
  /** Pre-run worker liveness — cleanup restores exactly this state. */
  workerWasAlive: boolean;
  sawDegraded: boolean;
  recoveryMs: number;
}

/** Idempotently restore the worker to the liveness it had before prepare. */
async function restoreWorker(ctx: ChaosContext, wasAlive: boolean): Promise<void> {
  let alive = false;
  try {
    alive = await ctx.staging.workerAlive();
  } catch {
    alive = false;
  }
  if (wasAlive && !alive) {
    await ctx.staging.workerStart();
  } else if (!wasAlive && alive) {
    await ctx.staging.workerStopGraceful();
  }
}

export const redisQRestartScenario: ChaosScenario<Prepared> = {
  name: "redis-q-restart",
  precondition:
    "20 runs provably waiting in agent-runs, staging worker stopped, health ok, enqueues settled >2s (AOF tail-loss allowance)",

  async prepare(ctx: ChaosContext): Promise<Prepared> {
    const baseUrl = ctx.env.STAGING_GATEWAY_URL ?? "";
    const redisQUrl = ctx.env.STAGING_REDIS_Q_URL ?? "";
    const databaseUrl = ctx.env.STAGING_DATABASE_URL ?? "";
    const tag = `redisq-${Date.now().toString(36)}-${randomBytes(3).toString("hex")}`;

    // Record the pre-run state so cleanup restores it (never leave the
    // staging worker stopped for the next scenario in `--scenario all`).
    const workerWasAlive = await ctx.staging.workerAlive();
    // The worker must be down so the 20 runs cannot drain. This is setup, not
    // injection; the gate re-proves it immediately before the restart.
    await ctx.staging.workerStopGraceful();

    const clients: ChaosClient[] = [];
    let queues: QueueServices | undefined;
    let db: Db | undefined;
    let ground: ReturnType<typeof createGroundTruth> | undefined;
    try {
      clients.push(...(await openClients({ baseUrl, count: CLIENTS, tag })));
      for (const entry of clients) {
        await sendRuns(entry, RUNS_PER_CLIENT, (index) => `${tag} queued run ${index}`);
      }

      queues = createScenarioQueues(redisQUrl);
      // The redis restart below intentionally breaks these connections; without
      // an error listener BullMQ's EventEmitter 'error' would crash the runner.
      for (const queue of Object.values(queues)) {
        queue?.on("error", () => {});
      }
      db = createDb(databaseUrl);
      ground = createGroundTruth(redisQUrl);

      // AOF everysec: the gate requires the enqueues to be >2 s old before the
      // restart. Wait here so the gate observes a settled queue rather than
      // failing on a freshly-enqueued one.
      const enqueuedAtMs = Date.now();
      await sleep(AOF_SETTLE_MS + 250);

      return {
        clients,
        queues,
        db,
        redis: ground.redis,
        log: ground.log,
        enqueuedAtMs,
        workerWasAlive,
        sawDegraded: false,
        recoveryMs: 0,
      };
    } catch (err) {
      // Partial prepare: close everything opened and let the runner's cleanup
      // (prepared === undefined) restore the worker. Close first, then throw.
      await closeClients(clients);
      if (queues !== undefined) {
        await Promise.allSettled(
          Object.values(queues)
            .filter((queue): queue is NonNullable<typeof queue> => queue !== undefined)
            .map((queue) => queue.close()),
        );
      }
      await ground?.redis.quit().catch(() => {});
      await db?.$client.end({ timeout: 5 }).catch(() => {});
      throw err;
    }
  },

  async gate(ctx: ChaosContext, prepared: Prepared): Promise<GateResult> {
    // Poll briefly: the queue count is immediate in practice, but a slow
    // reconnect from a previous scenario must not turn into a vacuous pass.
    const deadline = Date.now() + 5_000;
    let last: GateResult = { ok: false, detail: "gate not evaluated" };
    for (;;) {
      let waitingCount = -1;
      try {
        waitingCount = await prepared.queues.agentRuns.getWaitingCount();
      } catch {
        waitingCount = -1;
      }
      const health = await readHealth(ctx.env.STAGING_GATEWAY_URL ?? "");
      last = evaluateRedisQGate({
        waitingCount,
        expectedWaiting: EXPECTED_WAITING,
        workerAlive: await ctx.staging.workerAlive(),
        healthStatus: health.status,
        enqueueSettleMs: Date.now() - prepared.enqueuedAtMs,
      });
      if (last.ok || Date.now() >= deadline) return last;
      await sleep(100);
    }
  },

  async inject(ctx: ChaosContext, prepared: Prepared): Promise<void> {
    const baseUrl = ctx.env.STAGING_GATEWAY_URL ?? "";
    const restartAt = Date.now();

    // Poll WHILE the restart is in flight: `docker compose restart` returns
    // only after the container is back, so a post-hoc poll can miss a fast
    // bounce entirely (the scenario would then pass without observing the
    // degraded state).
    let polling = true;
    const observe = (async () => {
      while (polling) {
        const health = await readHealth(baseUrl);
        if (health.status === "degraded" && !health.checks.redisQ) {
          prepared.sawDegraded = true;
        }
        await sleep(100);
      }
    })();

    try {
      await ctx.staging.restart("redis-q");
      await sleep(300);
    } finally {
      polling = false;
      await observe;
    }

    await waitFor(
      "health ok after redis recovery",
      async () => (await readHealth(baseUrl)).status === "ok",
      60_000,
      250,
    );
    prepared.recoveryMs = Date.now() - restartAt;
  },

  async verify(ctx: ChaosContext, prepared: Prepared): Promise<Assertion[]> {
    const assertions: Assertion[] = [];
    assertions.push({
      name: "degraded-redisQ-observed",
      passed: prepared.sawDegraded,
      detail: prepared.sawDegraded
        ? `health reported degraded {redisQ:false} during the outage; recovered in ${prepared.recoveryMs}ms`
        : "health never reported degraded {redisQ:false} — the outage was not observed",
    });

    // AOF everysec + the >2s settle gate: the queue must be intact.
    let waitingAfter = -1;
    try {
      waitingAfter = await waitFor(
        "waiting count preserved",
        async () => {
          try {
            const count = await prepared.queues.agentRuns.getWaitingCount();
            return count === EXPECTED_WAITING ? count : null;
          } catch {
            return null;
          }
        },
        30_000,
        250,
      );
    } catch {
      waitingAfter = -1;
    }
    assertions.push({
      name: "queue-preserved",
      passed: waitingAfter === EXPECTED_WAITING,
      detail: `waiting == ${waitingAfter === -1 ? "unreadable" : waitingAfter}, expected ${EXPECTED_WAITING}`,
    });

    await ctx.staging.workerStart();
    const alive = await waitFor(
      "staging worker started",
      async () => ((await ctx.staging.workerAlive()) ? true : null),
      30_000,
      250,
    ).then(() => true);
    assertions.push({
      name: "worker-restarted",
      passed: alive,
      detail: "staging worker is consuming again after the redis restart",
    });

    const terminal = await waitForTerminalRuns(prepared.clients, 180_000);
    assertions.push({
      name: "all-runs-completed",
      passed:
        terminal.completed.size === EXPECTED_WAITING && terminal.failed.size === 0,
      detail: `completed ${terminal.completed.size}/${EXPECTED_WAITING}, failed ${terminal.failed.size}`,
    });

    // Mirror writes race the client delivery by a few ms; poll briefly.
    const integrity = { lost: 0, duplicate: 0, mirrorGaps: 0 };
    const integrityErrors: string[] = [];
    for (const entry of prepared.clients) {
      let truth: string[] = [];
      let mirror: string[] = [];
      try {
        truth = await groundTruthSeqs(prepared.log, entry.sessionId);
        await waitFor(
          `mirror caught up for ${entry.sessionId}`,
          async () => {
            mirror = await mirrorSeqs(prepared.db, entry.sessionId);
            return mirror.length >= truth.length ? true : null;
          },
          10_000,
          100,
        );
      } catch (err) {
        // M1: a failed read must fail the integrity assertion, not yield a
        // vacuous 0/0/0 pass.
        integrityErrors.push(`${entry.sessionId}: ${errorText(err)}`);
        continue;
      }
      const diff = diffIntegrity(deliveredSeqs(entry), truth, mirror);
      integrity.lost += diff.lostEvents;
      integrity.duplicate += diff.duplicateEvents;
      integrity.mirrorGaps += diff.gapsVsMirror;
    }
    assertions.push({
      name: "ledger-integrity",
      passed:
        integrityErrors.length === 0 &&
        integrity.lost === 0 &&
        integrity.duplicate === 0 &&
        integrity.mirrorGaps === 0,
      detail:
        integrityErrors.length > 0
          ? `ground-truth read failed: ${integrityErrors.join("; ")}`
          : `lost ${integrity.lost}, duplicate ${integrity.duplicate}, mirror gaps ${integrity.mirrorGaps}`,
    });

    const counts = aggregateEventCounts(prepared.clients);
    assertions.push({
      name: "exactly-one-terminal-per-run",
      passed:
        counts.completed.size + counts.failed.size === EXPECTED_WAITING &&
        counts.terminalEvents === EXPECTED_WAITING &&
        counts.unattributedTerminal === 0,
      detail:
        `${counts.terminalEvents} terminal event(s) for ${EXPECTED_WAITING} run(s); ` +
        `completed ${counts.completed.size}, failed ${counts.failed.size}, ` +
        `unattributed ${counts.unattributedTerminal}`,
    });

    return assertions;
  },

  async cleanup(ctx: ChaosContext, prepared: Prepared | undefined): Promise<void> {
    if (prepared !== undefined) {
      await closeClients(prepared.clients);
      await Promise.allSettled(
        Object.values(prepared.queues)
          .filter((queue): queue is NonNullable<typeof queue> => queue !== undefined)
          .map((queue) => queue.close()),
      );
      await prepared.redis.quit().catch(() => {});
      await prepared.db.$client.end({ timeout: 5 }).catch(() => {});
    }
    // H4: ALWAYS restore the worker — even when the gate/inject/verify failed
    // and even when prepare threw before returning (prepared === undefined;
    // the pre-run state is then unknown, so starting is the safe default).
    await restoreWorker(ctx, prepared?.workerWasAlive ?? true);
    await sleep(0);
  },
};
