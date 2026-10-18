import { readFileSync, readlinkSync } from "node:fs";
import { basename, dirname } from "node:path";
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
  /** F3: /proc/<pid> cmdline + cwd must prove the pid is the worker. */
  workerIdentityProblems: string[];
  /** F3: the held run must still be `running` when the gate passes. */
  runStatus: string | null;
  /** null = the staging pidfile was missing/unreadable. */
  workerPid: number | null;
}

export interface WorkerKillOutcomeState {
  stayedDeadMs: number;
  requiredDeadMs: number;
  runLostSeen: boolean;
  runLostCode: string | null;
  /** F9: the run_lost event's own `ts` was at/after the restart. */
  runLostAfterRestart: boolean;
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

function isLoopbackHost(hostname: string): boolean {
  return (
    hostname === "127.0.0.1" ||
    hostname === "localhost" ||
    hostname === "::1" ||
    hostname === "[::1]"
  );
}

/**
 * Proven-staging target checks. A chaos run must never be able to signal a
 * live worker: the pidfile must be staging-named, and the gateway URL must be
 * loopback (a production host reached by IP or alias fails too). The /proc
 * identity check in `evaluateWorkerProcessIdentity` is the ground truth for
 * the pid itself; the name check alone cannot distinguish a stale pidfile.
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
  } else {
    let hostname = "";
    try {
      hostname = new URL(gateway).hostname;
    } catch {
      problems.push(`STAGING_GATEWAY_URL (${gateway}) is not a valid URL`);
    }
    if (hostname !== "" && !isLoopbackHost(hostname)) {
      problems.push(
        `STAGING_GATEWAY_URL host '${hostname}' is not loopback — refusing to run against a non-staging target`,
      );
    }
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
  if (state.workerIdentityProblems.length > 0) {
    problems.push(...state.workerIdentityProblems);
  }
  if (state.runStatus !== "running") {
    problems.push(
      `held run is '${state.runStatus ?? "missing"}', expected 'running' at kill time`,
    );
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
        state.runLostSeen &&
        state.runLostAfterRestart &&
        state.recoveryMs >= 0 &&
        state.recoveryMs <= state.recoveryBudgetMs,
      detail: state.runLostSeen
        ? `run_lost emitted ${state.recoveryMs}ms after the worker restart (budget ${state.recoveryBudgetMs}ms = 15s stale + 60s sweep + 20s slack); emitted-after-restart: ${state.runLostAfterRestart}`
        : "no run_lost event to time",
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

export interface ProcessIdentity {
  cmdline: string;
  cwd: string | null;
}

/** Read `/proc/<pid>` ground truth. null = the process (or /proc) is gone. */
export function readProcessIdentity(pid: number): ProcessIdentity | null {
  let cmdline: string;
  try {
    cmdline = readFileSync(`/proc/${pid}/cmdline`, "utf8")
      .split("\0")
      .filter((part) => part !== "")
      .join(" ");
  } catch {
    return null;
  }
  let cwd: string | null = null;
  try {
    cwd = readlinkSync(`/proc/${pid}/cwd`);
  } catch {
    cwd = null;
  }
  return { cmdline, cwd };
}

/**
 * F3: the same identity staging.sh's `worker-stop` verifies before signalling
 * — the entrypoint must be `dist/main.js` and the cwd must be an
 * `apps/worker` checkout. A stale/reused pidfile pid fails here even when it
 * is alive, so the scenario cannot kill an unrelated process and call the
 * wrong death a recovery.
 */
export function evaluateWorkerProcessIdentity(
  identity: ProcessIdentity | null,
): string[] {
  if (identity === null) {
    return [
      "/proc/<pid> is unreadable — cannot prove the pidfile pid is the staging worker",
    ];
  }
  const problems: string[] = [];
  if (!identity.cmdline.includes("dist/main.js")) {
    problems.push(
      `pid cmdline '${identity.cmdline}' is not the staging worker entrypoint (dist/main.js) — refusing to signal`,
    );
  }
  if (
    identity.cwd === null ||
    basename(identity.cwd) !== "worker" ||
    basename(dirname(identity.cwd)) !== "apps"
  ) {
    problems.push(
      `pid cwd '${identity.cwd ?? "<unreadable>"}' is not an apps/worker checkout — refusing to signal`,
    );
  }
  return problems;
}

async function readRunStatus(db: Db, runId: string): Promise<string | null> {
  try {
    const rows = (await db.$client.unsafe(
      "SELECT status FROM runs WHERE id = $1",
      [runId],
    )) as Array<{ status: string }>;
    return rows[0]?.status ?? null;
  } catch {
    return null;
  }
}

/**
 * F7: cleanup must restore the worker even when inject threw after the kill.
 * Exported so the restore path is unit-testable with a fake handle.
 */
export async function restoreWorkerIfKilled(
  staging: {
    workerAlive(): Promise<boolean>;
    workerStart(env?: Record<string, string>): Promise<void>;
  },
  killed: boolean,
): Promise<void> {
  if (!killed) return;
  let alive = false;
  try {
    alive = await staging.workerAlive();
  } catch {
    alive = false;
  }
  if (!alive) {
    await staging.workerStart({ OVID_RUN_STALE_MS: String(STALE_OVERRIDE_MS) });
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
  workerIdentityProblems: string[];
  workerKilled: boolean;
  db: Db;
  redis: ReturnType<typeof createGroundTruth>["redis"];
  log: ReturnType<typeof createGroundTruth>["log"];
  stayedDeadMs: number;
  workerRestartedAtMs: number;
  runLostEmittedAtMs: number | null;
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
    // F3: name/URL checks are not enough — prove the pid is the worker.
    const workerIdentityProblems =
      workerPid === null
        ? []
        : evaluateWorkerProcessIdentity(readProcessIdentity(workerPid));

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
        workerIdentityProblems,
        workerKilled: false,
        db,
        redis,
        log: groundTruth.log,
        stayedDeadMs: 0,
        workerRestartedAtMs: 0,
        runLostEmittedAtMs: null,
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
      // F3: re-read the pidfile and /proc each pass. A reused pid or a
      // replaced worker between prepare and injection must fail the gate.
      const currentPid = readStagingWorkerPid(ctx.env) ?? prepared.workerPid;
      const identityProblems =
        currentPid === null
          ? []
          : evaluateWorkerProcessIdentity(readProcessIdentity(currentPid));
      if (
        currentPid !== null &&
        prepared.workerPid !== null &&
        currentPid !== prepared.workerPid
      ) {
        identityProblems.push(
          `pidfile pid changed from ${prepared.workerPid} to ${currentPid} — the kill target is no longer the prepared worker`,
        );
      }
      last = evaluateWorkerKillGate({
        clients: [state],
        gateReleased: prepared.gateReleased,
        healthStatus: health.status,
        workerAlive: await ctx.staging.workerAlive(),
        targetProblems: prepared.targetProblems,
        workerIdentityProblems: [
          ...prepared.workerIdentityProblems,
          ...identityProblems,
        ],
        runStatus: await readRunStatus(prepared.db, runId),
        workerPid: prepared.workerPid,
      });
      if (last.ok || Date.now() >= deadline) return last;
      await sleep(100);
    }
  },

  async inject(ctx: ChaosContext, prepared: Prepared): Promise<void> {
    const workerPid = prepared.workerPid!;

    // F3: ground truth immediately before the signal. staging.sh re-verifies
    // too, but the scenario must prove it killed the worker it thinks it did.
    const pidAtKill = readStagingWorkerPid(ctx.env);
    if (pidAtKill !== workerPid) {
      throw new Error(
        `worker-kill: pidfile changed between prepare (${workerPid}) and inject (${pidAtKill ?? "missing"}) — refusing to kill`,
      );
    }
    if (!isPidAlive(workerPid)) {
      throw new Error(`worker-kill: pid ${workerPid} is not alive before the kill`);
    }
    const identityProblems = evaluateWorkerProcessIdentity(
      readProcessIdentity(workerPid),
    );
    if (identityProblems.length > 0) {
      throw new Error(`worker-kill: ${identityProblems.join("; ")}`);
    }
    const statusAtKill = await readRunStatus(prepared.db, prepared.runId);
    if (statusAtKill !== "running") {
      throw new Error(
        `worker-kill: held run is '${statusAtKill ?? "missing"}', expected 'running' at kill time`,
      );
    }

    // Set before the command: `worker-stop kill` can exit non-zero after the
    // signal (e.g. the post-check fails). Cleanup then still restores the
    // worker; `restoreWorkerIfKilled` only starts it when it is not alive.
    prepared.workerKilled = true;
    await ctx.staging.workerKill();

    // F9: measure the verified dead window from AFTER the kill command
    // returned, not from before it (which overstated the 20 s claim).
    const deadSince = Date.now();
    while (Date.now() - deadSince < REQUIRED_DEAD_MS) {
      if (isPidAlive(workerPid)) {
        // A live pid during the window means the kill did not take.
        throw new Error(
          `worker-kill: staging pid ${workerPid} is still alive ${Date.now() - deadSince}ms after kill -9`,
        );
      }
      await sleep(250);
    }
    prepared.stayedDeadMs = Date.now() - deadSince;

    // The restart boundary is when we ASK for the restart, not when the
    // process is observed alive: a sweep during startup is still a
    // post-restart recovery, while an old-worker emit cannot be after this.
    prepared.workerRestartedAtMs = Date.now();
    await ctx.staging.workerStart({
      OVID_RUN_STALE_MS: String(STALE_OVERRIDE_MS),
    });
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
          // F9: the event's own emit timestamp, not when we noticed it.
          const emittedAt = Date.parse(terminal.ts);
          prepared.runLostEmittedAtMs = Number.isFinite(emittedAt)
            ? emittedAt
            : null;
          return true;
        },
        RECOVERY_BUDGET_MS,
        250,
      );
    } catch {
      // recorded by the outcome evaluator below
    }
    const runLostAfterRestart =
      prepared.runLostEmittedAtMs !== null &&
      prepared.runLostEmittedAtMs >= prepared.workerRestartedAtMs;
    prepared.recoveryMs =
      prepared.runLostEmittedAtMs !== null
        ? prepared.runLostEmittedAtMs - prepared.workerRestartedAtMs
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
      runLostAfterRestart,
      recoveryMs: prepared.recoveryMs,
      recoveryBudgetMs: RECOVERY_BUDGET_MS,
      runRowStatus,
      runFailedEventsInStream: streamFailures,
      runFailedEventsInMirror: mirrorFailures,
      freshRunCompleted: prepared.freshRunCompleted,
      workerAlive,
    });
  },

  async cleanup(ctx: ChaosContext, prepared: Prepared | undefined): Promise<void> {
    // F8: the runner calls cleanup(ctx, undefined) when prepare throws; the
    // prepare catch already released the gate and closed its resources.
    if (prepared === undefined) return;
    if (!prepared.gateReleased) prepared.gate.release();
    await closeClients(prepared.clients);
    await prepared.redis.quit().catch(() => {});
    await prepared.db.$client.end({ timeout: 5 }).catch(() => {});
    // F7: inject can throw after `workerKill()` (dead-window or restart
    // failure). Never leave the staging worker dead for the next scenario.
    // A restart failure propagates so the runner records a cleanup failure.
    await restoreWorkerIfKilled(ctx.staging, prepared.workerKilled);
  },
};
