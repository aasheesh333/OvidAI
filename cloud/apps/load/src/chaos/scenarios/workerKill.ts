import { readFileSync } from "node:fs";
import { basename } from "node:path";
import { eventMirror, createDb, type Db } from "@ovid/db";
import type {
  Assertion,
  ChaosContext,
  ChaosScenario,
  GateResult,
} from "../runner.js";
import {
  closeClients,
  createGroundTruth,
  openClients,
  readHealth,
  receivedEvents,
  runEventCounts,
  sendRuns,
  sleep,
  waitFor,
  type ChaosClient,
} from "../helpers.js";

/**
 * worker-kill — a hard `kill -9` of the staging worker must be recovered by
 * the stale-run sweeper, not merely observed.
 *
 * Locked assertions (plan): a gated run is provably in flight (run_started +
 * streamed delta, no terminal) before the kill; `workerKill()` is `kill -9`
 * through the staging pidfile; the worker stays dead for 20 s; it restarts
 * with `OVID_RUN_STALE_MS=15000`; within 15 s + 60 s sweep + 20 s slack the
 * client receives `run_failed {code:"run_lost"}` (append+mirror) and the run
 * row is `failed`; exactly one `run_failed` event (claim-then-emit); a fresh
 * run after the restart completes normally.
 *
 * Safety: the scenario NEVER constructs a signal target. It calls
 * `ctx.staging.workerKill()` (staging.sh + its pidfile) and validates the
 * staging target before injection: the pidfile must be staging-named and the
 * gateway URL must not be the production host. The only pid it reads is that
 * validated pidfile, and it probes it with signal 0 (never a kill signal).
 */

export interface WorkerKillClientState {
  runStarted: boolean;
  deltaSeen: boolean;
  terminal: boolean;
}

export interface WorkerKillGateState {
  clients: WorkerKillClientState[];
  gateReleased: boolean;
  healthStatus: "ok" | "degraded" | "unreachable";
  workerAlive: boolean;
  targetProblems: string[];
  /** null = the staging pidfile was missing/unreadable. */
  workerPid: number | null;
}

export interface WorkerKillOutcomeState {
  stayedDeadMs: number;
  requiredDeadMs: number;
  runLostSeen: boolean;
  runLostCode: string | null;
  recoveryMs: number;
  recoveryBudgetMs: number;
  runRowStatus: string | null;
  runFailedEventsInStream: number;
  runFailedEventsInMirror: number;
  freshRunCompleted: boolean;
  workerAlive: boolean;
}

export const REQUIRED_DEAD_MS = 20_000;
/** 15 s stale window + 60 s sweeper interval + 20 s slack (plan-pinned). */
export const RECOVERY_BUDGET_MS = 95_000;
export const STALE_OVERRIDE_MS = 15_000;

const PRODUCTION_HOST = "api.ovidsi.com";

/**
 * Proven-staging target checks. A chaos run must never be able to signal a
 * live worker: the pidfile must be staging-named, and the gateway URL must
 * not point at the production host.
 */
export function evaluateStagingTarget(env: Record<string, string>): string[] {
  const problems: string[] = [];
  const gateway = env.STAGING_GATEWAY_URL ?? "";
  const pidfile = env.STAGING_WORKER_PIDFILE ?? "";

  if (gateway === "") {
    problems.push("STAGING_GATEWAY_URL is missing — refusing to guess a target");
  } else if (gateway.includes(PRODUCTION_HOST)) {
    problems.push(
      `STAGING_GATEWAY_URL points at the production host (${PRODUCTION_HOST}) — refusing to run chaos`,
    );
  }

  if (pidfile === "") {
    problems.push("STAGING_WORKER_PIDFILE is missing — cannot prove a staging worker target");
  } else if (!basename(pidfile).toLowerCase().includes("staging")) {
    problems.push(
      `STAGING_WORKER_PIDFILE (${pidfile}) is not staging-named — refusing to kill a non-staging process`,
    );
  }

  return problems;
}

/** Pure gate (unit-tested): every clause proves the vulnerable state. */
export function evaluateWorkerKillGate(state: WorkerKillGateState): GateResult {
  const problems: string[] = [];
  if (state.targetProblems.length > 0) problems.push(...state.targetProblems);
  if (state.workerPid === null) {
    problems.push("staging worker pidfile is missing/unreadable — no proven kill target");
  }
  if (state.clients.length === 0) problems.push("no clients prepared");
  state.clients.forEach((client, index) => {
    if (!client.runStarted) problems.push(`client ${index} has no run_started`);
    if (!client.deltaSeen) {
      problems.push(`client ${index} has <2 events (no streamed delta)`);
    }
    if (client.terminal) {
      problems.push(`client ${index} run already reached a terminal event — it was not held`);
    }
  });
  if (state.gateReleased) problems.push("the mock gate was already released");
  if (state.healthStatus !== "ok") {
    problems.push(`gateway health is '${state.healthStatus}', expected 'ok'`);
  }
  if (!state.workerAlive) {
    problems.push("staging worker is not alive before the kill (nothing to kill)");
  }
  if (problems.length > 0) return { ok: false, detail: problems.join("; ") };
  return {
    ok: true,
    detail:
      `${state.clients.length} run(s) provably in flight with the mock gate held; ` +
      `staging worker pid ${state.workerPid} alive; health ok; target is staging`,
  };
}

/** Pure outcome evaluator (unit-tested): recovery, not just death. */
export function evaluateWorkerKillOutcome(
  state: WorkerKillOutcomeState,
): Assertion[] {
  return [
    {
      name: "worker-stays-dead",
      passed: state.stayedDeadMs >= state.requiredDeadMs,
      detail: `worker observed dead for ${state.stayedDeadMs}ms (required ${state.requiredDeadMs}ms)`,
    },
    {
      name: "run-lost-emitted",
      passed: state.runLostSeen && state.runLostCode === "run_lost",
      detail: state.runLostSeen
        ? `run_failed code=${JSON.stringify(state.runLostCode)}`
        : "client never received run_failed for the killed run",
    },
    {
      name: "run-lost-within-budget",
      passed:
        state.runLostSeen && state.recoveryMs <= state.recoveryBudgetMs,
      detail: `recovered ${state.recoveryMs}ms after worker restart (budget ${state.recoveryBudgetMs}ms = 15s stale + 60s sweep + 20s slack)`,
    },
    {
      name: "run-row-failed",
      passed: state.runRowStatus === "failed",
      detail: `run row status is ${state.runRowStatus ?? "missing"}`,
    },
    {
      name: "exactly-one-run-failed",
      passed:
        state.runFailedEventsInStream === 1 && state.runFailedEventsInMirror === 1,
      detail: `run_failed events: stream ${state.runFailedEventsInStream}, mirror ${state.runFailedEventsInMirror} (claim-then-emit must produce exactly 1)`,
    },
    {
      name: "fresh-run-completes",
      passed: state.freshRunCompleted,
      detail: state.freshRunCompleted
        ? "a fresh run started after the restart reached run_completed"
        : "a fresh run did not complete after the restart",
    },
    {
      name: "worker-restarted",
      passed: state.workerAlive,
      detail: state.workerAlive
        ? "staging worker is alive and consuming again"
        : "staging worker is not alive after the restart",
    },
  ];
}

// ---------------------------------------------------------------------------
// Pidfile probing (signal 0 only — never a kill signal)
// ---------------------------------------------------------------------------

export function readStagingWorkerPid(env: Record<string, string>): number | null {
  const pidfile = env.STAGING_WORKER_PIDFILE;
  if (pidfile === undefined || pidfile === "") return null;
  try {
    const raw = readFileSync(pidfile, "utf8").trim();
    const pid = Number(raw);
    return Number.isInteger(pid) && pid > 0 ? pid : null;
  } catch {
    return null;
  }
}

/** `kill -0` semantics: EPERM means the pid exists (not ours), ESRCH = gone. */
export function isPidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException).code === "EPERM";
  }
}

// ---------------------------------------------------------------------------
// Scenario
// ---------------------------------------------------------------------------

interface Prepared {
  clients: ChaosClient[];
  runId: string;
  gate: { release(): void };
  gateReleased: boolean;
  workerPid: number | null;
  targetProblems: string[];
  db: Db;
  redis: ReturnType<typeof createGroundTruth>["redis"];
  log: ReturnType<typeof createGroundTruth>["log"];
  stayedDeadMs: number;
  workerRestartedAtMs: number;
  recoveryMs: number;
  freshRunId: string | null;
  freshRunCompleted: boolean;
}

export const workerKillScenario: ChaosScenario<Prepared> = {
  name: "worker-kill",
  precondition:
    "a gated run is provably in flight (run_started + streamed delta, no terminal), the staging worker pid is alive, and the target is proven staging (staging-named pidfile, non-production gateway)",

  async prepare(ctx: ChaosContext): Promise<Prepared> {
    const baseUrl = ctx.env.STAGING_GATEWAY_URL ?? "";
    const redisQUrl = ctx.env.STAGING_REDIS_Q_URL ?? "";
    const databaseUrl = ctx.env.STAGING_DATABASE_URL ?? "";
    const tag = `workerkill-${Date.now().toString(36)}`;

    // Read the pid BEFORE the kill: `worker-stop kill` removes the pidfile,
    // so a post-kill read could not prove the process actually died.
    const workerPid = readStagingWorkerPid(ctx.env);
    const targetProblems = evaluateStagingTarget(ctx.env);

    // Arm BEFORE sending: the run's first LLM request snapshots this gate.
    const gate = ctx.mockArm({
      deltas: ["kill-held-a", "kill-held-b", "kill-held-c"],
      chunkDelayMs: 0,
      gateAfterDeltas: 1,
    });
    let clients: ChaosClient[] = [];
    let db: Db | undefined;
    let redis: ReturnType<typeof createGroundTruth>["redis"] | undefined;
    try {
      clients = await openClients({ baseUrl, count: 1, tag });
      await sendRuns(clients[0]!, 1, () => `${tag} held run`);

      db = createDb(databaseUrl);
      const groundTruth = createGroundTruth(redisQUrl);
      redis = groundTruth.redis;

      return {
        clients,
        runId: clients[0]!.runIds[0]!,
        gate,
        gateReleased: false,
        workerPid,
        targetProblems,
        db,
        redis,
        log: groundTruth.log,
        stayedDeadMs: 0,
        workerRestartedAtMs: 0,
        recoveryMs: Number.POSITIVE_INFINITY,
        freshRunId: null,
        freshRunCompleted: false,
      };
    } catch (err) {
      // The runner does not call cleanup when prepare throws.
      gate.release();
      await closeClients(clients).catch(() => {});
      await redis?.quit().catch(() => {});
      await db?.$client.end({ timeout: 5 }).catch(() => {});
      throw err;
    }
  },

  async gate(ctx: ChaosContext, prepared: Prepared): Promise<GateResult> {
    const deadline = Date.now() + 60_000;
    let last: GateResult = { ok: false, detail: "gate not evaluated" };
    for (;;) {
      const health = await readHealth(ctx.env.STAGING_GATEWAY_URL ?? "");
      const entry = prepared.clients[0]!;
      const events = receivedEvents(entry);
      const counts = runEventCounts(events);
      const runId = prepared.runId;
      const state: WorkerKillClientState = {
        runStarted: counts.started.has(runId),
        deltaSeen: events.some(
          (event) =>
            event.type === "message_delta" &&
            event.payload.runId === runId,
        ),
        terminal:
          counts.completed.has(runId) || counts.failed.has(runId),
      };
      last = evaluateWorkerKillGate({
        clients: [state],
        gateReleased: prepared.gateReleased,
        healthStatus: health.status,
        workerAlive: await ctx.staging.workerAlive(),
        targetProblems: prepared.targetProblems,
        workerPid: prepared.workerPid,
      });
      if (last.ok || Date.now() >= deadline) return last;
      await sleep(100);
    }
  },

  async inject(ctx: ChaosContext, prepared: Prepared): Promise<void> {
    const workerPid = prepared.workerPid!;
    const killedAt = Date.now();
    await ctx.staging.workerKill();

    // Prove the process is gone for the whole window. The staging handle
    // removed the pidfile, so probe the pid we read in prepare with signal 0.
    let deadSince = killedAt;
    while (Date.now() - killedAt < REQUIRED_DEAD_MS) {
      if (isPidAlive(workerPid)) {
        // A live pid during the window means the kill did not take.
        deadSince = Date.now();
        throw new Error(
          `worker-kill: staging pid ${workerPid} is still alive ${Date.now() - killedAt}ms after kill -9`,
        );
      }
      await sleep(250);
    }
    prepared.stayedDeadMs = Date.now() - deadSince;

    await ctx.staging.workerStart({
      OVID_RUN_STALE_MS: String(STALE_OVERRIDE_MS),
    });
    prepared.workerRestartedAtMs = Date.now();
    await waitFor(
      "staging worker restarted",
      async () => ((await ctx.staging.workerAlive()) ? true : null),
      30_000,
      250,
    );
  },

  async verify(ctx: ChaosContext, prepared: Prepared): Promise<Assertion[]> {
    const entry = prepared.clients[0]!;

    // The killed run's HTTP stream is already gone; releasing is harmless and
    // keeps the mock server free for the fresh run below.
    if (!prepared.gateReleased) {
      prepared.gate.release();
      prepared.gateReleased = true;
    }

    let runLostSeen = false;
    let runLostCode: string | null = null;
    try {
      await waitFor(
        "run_lost delivered to the client",
        async () => {
          const terminal = receivedEvents(entry).find(
            (event) =>
              event.type === "run_failed" &&
              event.payload.runId === prepared.runId,
          );
          if (terminal === undefined) return null;
          runLostSeen = true;
          runLostCode =
            typeof terminal.payload.code === "string"
              ? terminal.payload.code
              : null;
          return true;
        },
        RECOVERY_BUDGET_MS,
        250,
      );
    } catch {
      // recorded by the outcome evaluator below
    }
    prepared.recoveryMs =
      runLostSeen
        ? Date.now() - prepared.workerRestartedAtMs
        : Number.POSITIVE_INFINITY;

    // Run row state (staging Postgres).
    let runRowStatus: string | null = null;
    try {
      const rows = (await prepared.db.$client.unsafe(
        "SELECT status FROM runs WHERE id = $1",
        [prepared.runId],
      )) as Array<{ status: string }>;
      runRowStatus = rows[0]?.status ?? null;
    } catch {
      runRowStatus = null;
    }

    const streamFailures = (
      await prepared.log
        .readSince(entry.sessionId, null, 10_000)
        .catch(() => [])
    ).filter(
      (event) =>
        event.type === "run_failed" &&
        event.payload.runId === prepared.runId,
    ).length;
    const mirrorFailures = (
      await eventMirror
        .readSince(prepared.db, entry.sessionId, null, 10_000)
        .catch(() => [])
    ).filter(
      (event) =>
        event.type === "run_failed" &&
        event.payload.runId === prepared.runId,
    ).length;

    // A fresh run after the restart must complete normally: the recovery is
    // not just "the sweeper wrote a row".
    try {
      ctx.mockArm({
        deltas: ["fresh-ok"],
        chunkDelayMs: 0,
        gateAfterDeltas: null,
      });
      const response = await entry.client.sendMessage(
        entry.sessionId,
        `workerkill-${Date.now().toString(36)} fresh run`,
      );
      prepared.freshRunId = response.runId;
      await waitFor(
        "fresh run completed",
        async () =>
          receivedEvents(entry).some(
            (event) =>
              event.type === "run_completed" &&
              event.payload.runId === prepared.freshRunId,
          )
            ? true
            : null,
        120_000,
        250,
      );
      prepared.freshRunCompleted = true;
    } catch {
      prepared.freshRunCompleted = false;
    }

    const workerAlive = await ctx.staging.workerAlive();
    return evaluateWorkerKillOutcome({
      stayedDeadMs: prepared.stayedDeadMs,
      requiredDeadMs: REQUIRED_DEAD_MS,
      runLostSeen,
      runLostCode,
      recoveryMs: prepared.recoveryMs,
      recoveryBudgetMs: RECOVERY_BUDGET_MS,
      runRowStatus,
      runFailedEventsInStream: streamFailures,
      runFailedEventsInMirror: mirrorFailures,
      freshRunCompleted: prepared.freshRunCompleted,
      workerAlive,
    });
  },

  async cleanup(_ctx: ChaosContext, prepared: Prepared): Promise<void> {
    if (!prepared.gateReleased) prepared.gate.release();
    await closeClients(prepared.clients);
    await prepared.redis.quit().catch(() => {});
    await prepared.db.$client.end({ timeout: 5 }).catch(() => {});
  },
};
