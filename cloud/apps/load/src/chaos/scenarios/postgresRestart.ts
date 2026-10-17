import { readFile } from "node:fs/promises";
import { createDb, type Db } from "@ovid/db";
import { diffIntegrity } from "../../metrics.js";
import type {
  Assertion,
  ChaosContext,
  ChaosScenario,
  GateResult,
} from "../runner.js";
import {
  closeClients,
  createGroundTruth,
  deliveredSeqs,
  groundTruthSeqs,
  mirrorSeqs,
  openClients,
  readHealth,
  receivedEvents,
  runEventCounts,
  sendRuns,
  waitFor,
  waitForTerminalRuns,
  type ChaosClient,
} from "../helpers.js";

/**
 * postgres-restart — no torn writes and no illegal run state across a database
 * restart.
 *
 * Locked assertions (plan): runs in flight (gated); precondition health ok;
 * restart postgres; health reports `degraded {db:false}` then `ok`; the host
 * worker does not crash-loop (pidfile alive; BullMQ stalled-job recovery or a
 * transient retry is accepted, both recorded); post-recovery every
 * `message_completed` event in the mirror has a matching `messages` row; no
 * run row sits in an illegal state; each gated run either completes after
 * release or is terminalized with `run_failed`, and both counts are recorded.
 */

const CLIENTS = 10;
const LEGAL_RUN_STATES = new Set(["queued", "running", "completed", "failed"]);

export interface PostgresClientState {
  runStarted: boolean;
  deltaSeen: boolean;
  terminal: boolean;
}

export interface PostgresGateState {
  clients: PostgresClientState[];
  gateReleased: boolean;
  healthStatus: "ok" | "degraded" | "unreachable";
  workerAlive: boolean;
}

/** Pure gate logic (unit-tested). */
export function evaluatePostgresGate(state: PostgresGateState): GateResult {
  const problems: string[] = [];
  if (state.clients.length === 0) problems.push("no clients prepared");
  state.clients.forEach((client, index) => {
    if (!client.runStarted) problems.push(`client ${index} has no run_started`);
    if (!client.deltaSeen) problems.push(`client ${index} has <2 events (no streamed delta)`);
    if (client.terminal) {
      problems.push(`client ${index} run already terminal — it was not held in flight`);
    }
  });
  if (state.gateReleased) problems.push("the mock gate was already released");
  if (state.healthStatus !== "ok") {
    problems.push(`gateway health is '${state.healthStatus}', expected 'ok'`);
  }
  if (!state.workerAlive) problems.push("staging worker is not running");
  if (problems.length > 0) {
    return { ok: false, detail: problems.join("; ") };
  }
  return {
    ok: true,
    detail: `${state.clients.length} gated run(s) in flight, worker alive, health ok`,
  };
}

interface Prepared {
  clients: ChaosClient[];
  gate: { release(): void };
  gateReleased: boolean;
  db: Db;
  redis: ReturnType<typeof createGroundTruth>["redis"];
  log: ReturnType<typeof createGroundTruth>["log"];
  sawDegraded: boolean;
  workerAliveAfter: boolean;
  recoveryMs: number;
}

export const postgresRestartScenario: ChaosScenario<Prepared> = {
  name: "postgres-restart",
  precondition:
    "10 gated runs provably in flight, staging worker alive, gateway health ok",

  async prepare(ctx: ChaosContext): Promise<Prepared> {
    const baseUrl = ctx.env.STAGING_GATEWAY_URL ?? "";
    const redisQUrl = ctx.env.STAGING_REDIS_Q_URL ?? "";
    const databaseUrl = ctx.env.STAGING_DATABASE_URL ?? "";
    const tag = `postgres-${Date.now().toString(36)}`;

    const gate = ctx.mockArm({
      deltas: ["db-held-a", "db-held-b"],
      chunkDelayMs: 0,
      gateAfterDeltas: 1,
    });
    const clients = await openClients({ baseUrl, count: CLIENTS, tag });
    for (const entry of clients) {
      await sendRuns(entry, 1, () => `${tag} held run`);
    }

    const db = createDb(databaseUrl);
    const { log, redis } = createGroundTruth(redisQUrl);
    return {
      clients,
      gate,
      gateReleased: false,
      db,
      redis,
      log,
      sawDegraded: false,
      workerAliveAfter: false,
      recoveryMs: 0,
    };
  },

  async gate(ctx: ChaosContext, prepared: Prepared): Promise<GateResult> {
    const deadline = Date.now() + 60_000;
    let last: GateResult = { ok: false, detail: "gate not evaluated" };
    for (;;) {
      const health = await readHealth(ctx.env.STAGING_GATEWAY_URL ?? "");
      const clientStates: PostgresClientState[] = prepared.clients.map((entry) => {
        const events = receivedEvents(entry);
        const counts = runEventCounts(events);
        const runIds = new Set(entry.runIds);
        return {
          runStarted: [...runIds].some((runId) => counts.started.has(runId)),
          deltaSeen: events.some(
            (event) =>
              event.type === "message_delta" &&
              typeof event.payload.runId === "string" &&
              runIds.has(event.payload.runId),
          ),
          terminal: [...runIds].some(
            (runId) => counts.completed.has(runId) || counts.failed.has(runId),
          ),
        };
      });
      last = evaluatePostgresGate({
        clients: clientStates,
        gateReleased: prepared.gateReleased,
        healthStatus: health.status,
        workerAlive: await ctx.staging.workerAlive(),
      });
      if (last.ok || Date.now() >= deadline) return last;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  },

  async inject(ctx: ChaosContext, prepared: Prepared): Promise<void> {
    const baseUrl = ctx.env.STAGING_GATEWAY_URL ?? "";
    const restartAt = Date.now();

    // Observe concurrently with the restart: the postgres container can come
    // back before a post-hoc poll would ever see the degraded state.
    let polling = true;
    const observe = (async () => {
      while (polling) {
        const health = await readHealth(baseUrl);
        if (health.status === "degraded" && !health.checks.db) {
          prepared.sawDegraded = true;
        }
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
    })();

    try {
      await ctx.staging.restart("postgres");
      await new Promise((resolve) => setTimeout(resolve, 300));
    } finally {
      polling = false;
      await observe;
    }

    await waitFor(
      "health ok after postgres recovery",
      async () => ((await readHealth(baseUrl)).status === "ok" ? true : null),
      90_000,
      250,
    );
    prepared.recoveryMs = Date.now() - restartAt;
    prepared.workerAliveAfter = await ctx.staging.workerAlive();

    // Release only after the database is back: the remaining stream then
    // exercises the normal post-recovery write path.
    prepared.gate.release();
    prepared.gateReleased = true;
  },

  async verify(_ctx: ChaosContext, prepared: Prepared): Promise<Assertion[]> {
    const assertions: Assertion[] = [];
    assertions.push({
      name: "degraded-db-observed",
      passed: prepared.sawDegraded,
      detail: prepared.sawDegraded
        ? `health reported degraded {db:false} during the outage; recovered in ${prepared.recoveryMs}ms`
        : "health never reported degraded {db:false} — the outage was not observed",
    });
    assertions.push({
      name: "worker-no-crash-loop",
      passed: prepared.workerAliveAfter,
      detail: prepared.workerAliveAfter
        ? "staging worker pidfile is alive after the database restart"
        : "staging worker died during the database restart (crash-loop)",
    });

    // The plan accepts either BullMQ stalled-job recovery or a transient
    // retry; record which path the worker log shows (read-only).
    let workerLog = "";
    try {
      workerLog = await readFile(
        process.env.STAGING_WORKER_LOG ?? "/tmp/opencode/ovid-staging-worker.log",
        "utf8",
      );
    } catch {
      // log not readable — the pidfile assertion above is authoritative
    }
    const tail = workerLog.split("\n").slice(-80).join("\n").toLowerCase();
    const recoveryMarkers = ["stalled", "retry", "reconnect", "econnrefused", "connection terminated"].filter(
      (marker) => tail.includes(marker),
    );
    assertions.push({
      name: "worker-recovery-path-recorded",
      passed: true,
      detail:
        recoveryMarkers.length > 0
          ? `worker log shows: ${recoveryMarkers.join(", ")}`
          : "no recovery marker in the last 80 worker log lines (worker stayed alive; pidfile is authoritative)",
    });

    const terminal = await waitForTerminalRuns(prepared.clients, 180_000);
    assertions.push({
      name: "every-run-terminal",
      passed: terminal.terminal.size === CLIENTS,
      detail: `terminal ${terminal.terminal.size}/${CLIENTS} — completed ${terminal.completed.size}, failed ${terminal.failed.size}`,
    });

    // ---- DB consistency (staging Postgres) --------------------------------
    const sessionIds = prepared.clients.map((entry) => entry.sessionId);
    const runIds = prepared.clients.flatMap((entry) => entry.runIds);

    // postgres.js may still be replacing stale pooled connections right
    // after the restart; retry the read-only consistency queries.
    const dbState = await waitFor(
      "postgres consistency queries",
      async () => {
        const runRows = (await prepared.db.$client.unsafe(
          `SELECT id, status FROM runs WHERE session_id = ANY($1::text[])`,
          [sessionIds],
        )) as Array<{ id: string; status: string }>;
        const statuses = new Map(runRows.map((row) => [row.id, row.status]));
        const illegal = runRows.filter((row) => !LEGAL_RUN_STATES.has(row.status));
        const missingRuns = runIds.filter((runId) => !statuses.has(runId));

        const completedEvents = (await prepared.db.$client.unsafe(
          `SELECT payload->>'messageId' AS message_id
             FROM session_event_mirror
            WHERE session_id = ANY($1::text[]) AND type = 'message_completed'`,
          [sessionIds],
        )) as Array<{ message_id: string | null }>;
        const messageIds = completedEvents
          .map((row) => row.message_id)
          .filter((id): id is string => typeof id === "string" && id !== "");
        let missingMessages: string[] = [];
        if (messageIds.length > 0) {
          const messageRows = (await prepared.db.$client.unsafe(
            `SELECT id::text AS id FROM messages WHERE id::text = ANY($1::text[])`,
            [messageIds],
          )) as Array<{ id: string }>;
          const present = new Set(messageRows.map((row) => row.id));
          missingMessages = messageIds.filter((id) => !present.has(id));
        }
        return { runRows, illegal, missingRuns, messageIds, missingMessages };
      },
      30_000,
      250,
    );

    assertions.push({
      name: "no-illegal-run-state",
      passed: dbState.illegal.length === 0 && dbState.missingRuns.length === 0,
      detail:
        dbState.illegal.length === 0 && dbState.missingRuns.length === 0
          ? `all ${dbState.runRows.length} run row(s) in {queued,running,completed,failed}; all ${runIds.length} enqueued run(s) present`
          : `illegal: ${dbState.illegal.map((row) => `${row.id}=${row.status}`).join(", ") || "none"}; missing: ${dbState.missingRuns.join(", ") || "none"}`,
    });

    assertions.push({
      name: "no-torn-writes",
      passed: dbState.missingMessages.length === 0,
      detail:
        dbState.missingMessages.length === 0
          ? `${dbState.messageIds.length} mirrored message_completed event(s), every one has a messages row`
          : `missing messages rows for: ${dbState.missingMessages.join(", ")}`,
    });

    // Ledger integrity is secondary here (the database was restarted); record
    // it so a silent event-log loss cannot hide behind the DB assertions.
    const integrity = { lost: 0, duplicate: 0, mirrorGaps: 0 };
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
      } catch {
        // recorded by the diff below
      }
      const diff = diffIntegrity(deliveredSeqs(entry), truth, mirror);
      integrity.lost += diff.lostEvents;
      integrity.duplicate += diff.duplicateEvents;
      integrity.mirrorGaps += diff.gapsVsMirror;
    }
    assertions.push({
      name: "ledger-integrity",
      passed:
        integrity.lost === 0 && integrity.duplicate === 0 && integrity.mirrorGaps === 0,
      detail: `lost ${integrity.lost}, duplicate ${integrity.duplicate}, mirror gaps ${integrity.mirrorGaps}`,
    });

    const terminalEvents = prepared.clients
      .flatMap((entry) => receivedEvents(entry))
      .filter((event) => event.type === "run_completed" || event.type === "run_failed");
    const counts = runEventCounts(terminalEvents);
    assertions.push({
      name: "exactly-one-terminal-per-run",
      passed:
        counts.completed.size + counts.failed.size === CLIENTS &&
        terminalEvents.length === CLIENTS,
      detail: `${terminalEvents.length} terminal event(s) for ${CLIENTS} run(s); completed ${counts.completed.size}, failed ${counts.failed.size}`,
    });

    return assertions;
  },

  async cleanup(_ctx: ChaosContext, prepared: Prepared): Promise<void> {
    await closeClients(prepared.clients);
    await prepared.redis.quit().catch(() => {});
    await prepared.db.$client.end({ timeout: 5 }).catch(() => {});
  },
};
