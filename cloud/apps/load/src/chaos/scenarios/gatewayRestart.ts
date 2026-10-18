import WebSocket from "ws";
import { createDb, type Db } from "@ovid/db";
import {
  WS_RESTART_CLOSE_CODE,
  WS_RESTART_CLOSE_REASON,
} from "@ovid/gateway";
import { AGENT_RUNS_DEFAULT_CONCURRENCY } from "@ovid/queue";
import { compareSeq, percentile, diffIntegrity } from "../../metrics.js";
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
  isMonotonic,
  mirrorSeqs,
  openClients,
  readHealth,
  receivedEvents,
  runEventCounts,
  sendRuns,
  waitFor,
  waitForTerminalRuns,
  wsBaseFor,
  type ChaosClient,
} from "../helpers.js";

/**
 * gateway-restart — the reconnect+replay contract survives a SIGTERM drain.
 *
 * Locked assertions (plan): 10 subscribed clients, every run held mid-stream
 * by the deferred-gated mock (precondition: every client has >=2 events and
 * its run is provably in-flight — gate NOT released); restart gateway
 * (SIGTERM → Task-2 drain, sockets close 1001); every client reconnects with a
 * fresh ticket + lastEventId within 15 s; release; per session the union of
 * pre- and post-restart deliveries equals readSince exactly (0 lost, 0
 * duplicate, monotonic seqs); replay p95 recorded.
 */

/**
 * The staging worker runs `createAgentRunsWorker` with no concurrency override,
 * so it holds exactly AGENT_RUNS_DEFAULT_CONCURRENCY runs. The mock gate holds
 * every started run after its first delta, so a larger client count would leave
 * the excess runs queued forever and the gate could never observe them.
 */
export const CLIENTS = AGENT_RUNS_DEFAULT_CONCURRENCY;
const RECONNECT_DEADLINE_MS = 15_000;

/** P10 Task 2 drain contract (re-exported by @ovid/gateway). */
export const EXPECTED_CLOSE_CODE = WS_RESTART_CLOSE_CODE;
export const EXPECTED_CLOSE_REASON = WS_RESTART_CLOSE_REASON;

export interface GatewayClientState {
  runStarted: boolean;
  deltaSeen: boolean;
  terminal: boolean;
}

export interface GatewayGateState {
  clients: GatewayClientState[];
  /** The exact client count the scenario prepared (worker concurrency bound). */
  expectedClients: number;
  gateReleased: boolean;
  healthStatus: "ok" | "degraded" | "unreachable";
}

/** Pure gate logic (unit-tested). */
export function evaluateGatewayGate(state: GatewayGateState): GateResult {
  const problems: string[] = [];
  if (state.clients.length !== state.expectedClients) {
    problems.push(
      `prepared ${state.clients.length} client(s), expected exactly ${state.expectedClients}`,
    );
  }
  state.clients.forEach((client, index) => {
    if (!client.runStarted) problems.push(`client ${index} has no run_started`);
    if (!client.deltaSeen) problems.push(`client ${index} has <2 events (no streamed delta)`);
    if (client.terminal) {
      problems.push(`client ${index} run already reached a terminal event — it was not held`);
    }
  });
  if (state.gateReleased) {
    problems.push("the mock gate was already released — runs were not held mid-stream");
  }
  if (state.healthStatus !== "ok") {
    problems.push(`gateway health is '${state.healthStatus}', expected 'ok'`);
  }
  // The positive in-flight count the gate actually observed. With the worker
  // concurrency bound above, this is the strongest statement available from
  // client-observed events: every worker slot is occupied by a held run.
  const inFlight = state.clients.filter(
    (client) => client.runStarted && client.deltaSeen && !client.terminal,
  ).length;
  if (inFlight !== state.expectedClients) {
    problems.push(
      `observed ${inFlight} in-flight run(s), expected exactly ${state.expectedClients}`,
    );
  }
  if (problems.length > 0) {
    return { ok: false, detail: problems.join("; ") };
  }
  return {
    ok: true,
    detail: `${inFlight} run(s) provably in-flight (run_started + delta seen, no terminal) with the mock gate held`,
  };
}

interface CloseObserver {
  code: Promise<number>;
  reason: Promise<string>;
  stop(): void;
}

function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  return Promise.race([
    promise,
    new Promise<T>((_resolve, reject) => {
      setTimeout(() => reject(new Error(`${label}: timeout after ${ms}ms`)), ms).unref();
    }),
  ]);
}

/**
 * A second socket per client, used only to observe the drain close code
 * (LoadClient does not expose it). It subscribes to the same session and
 * discards events.
 */
async function openCloseObserver(
  baseUrl: string,
  uid: string,
  sessionId: string,
): Promise<CloseObserver> {
  const ticketResponse = await fetch(`${baseUrl.replace(/\/+$/, "")}/cloud/v1/auth/ticket`, {
    method: "POST",
    headers: {
      authorization: `Bearer test:${uid}`,
      "content-type": "application/json",
    },
    body: "{}",
    signal: AbortSignal.timeout(10_000),
  });
  if (ticketResponse.status !== 200) {
    throw new Error(`close observer ticket: HTTP ${ticketResponse.status}`);
  }
  const ticket = ((await ticketResponse.json()) as { ticket?: unknown }).ticket;
  if (typeof ticket !== "string" || ticket === "") {
    throw new Error("close observer ticket: no ticket minted");
  }

  const socket = new WebSocket(`${wsBaseFor(baseUrl)}?ticket=${encodeURIComponent(ticket)}`);
  let resolveCode!: (code: number) => void;
  let resolveReason!: (reason: string) => void;
  const code = new Promise<number>((resolve) => {
    resolveCode = resolve;
  });
  const reason = new Promise<string>((resolve) => {
    resolveReason = resolve;
  });
  socket.once("close", (closeCode, closeReason) => {
    resolveCode(closeCode);
    resolveReason(closeReason.toString());
  });
  await withTimeout(
    new Promise<void>((resolve, reject) => {
      socket.once("open", () => resolve());
      socket.once("error", reject);
    }),
    10_000,
    "close observer open",
  );
  const subscribed = new Promise<void>((resolve) => {
    socket.on("message", (data) => {
      try {
        const msg = JSON.parse(data.toString()) as { op?: unknown };
        if (msg.op === "subscribed") resolve();
      } catch {
        // ignore non-JSON frames on the observer socket
      }
    });
  });
  socket.send(JSON.stringify({ op: "subscribe", sessionId, lastEventId: null }));
  await withTimeout(subscribed, 10_000, "close observer subscribe ack");
  return {
    code,
    reason,
    stop: () => socket.terminate(),
  };
}

interface Prepared {
  clients: ChaosClient[];
  observers: CloseObserver[];
  gate: { release(): void };
  gateReleased: boolean;
  db: Db;
  redis: ReturnType<typeof createGroundTruth>["redis"];
  log: ReturnType<typeof createGroundTruth>["log"];
  closeCodes: number[];
  closeReasons: string[];
  reconnectLatencies: number[];
  /** subscribe → last replayed event (only when the outage produced events). */
  replayLatencies: number[];
  reconnectFailures: string[];
}

/**
 * M5: measure subscribe → last replayed event, not just the `subscribed` ack.
 *
 * The gateway sends `subscribed` BEFORE replaying (`ws.ts`), so the ack time is
 * a reconnect metric. After the ack, replay frames are already past
 * `lastEventId`; wait for the burst to go quiet (or a bounded timeout) and take
 * the last such frame's receipt time. With the mock gate held, no events are
 * emitted during the outage, so this legitimately yields no sample — the
 * assertion records that explicitly instead of calling reconnect latency
 * "replay".
 */
async function measureReplayLatency(
  entry: ChaosClient,
  beforeCount: number,
  lastSeq: string | null,
  subscribeAt: number,
  quietMs = 250,
  timeoutMs = 1_500,
): Promise<number | null> {
  const deadline = Date.now() + timeoutMs;
  let lastAt: number | null = null;
  let seen = entry.client.received.length;
  let quietSince = Date.now();
  for (;;) {
    const replayed = entry.client.received
      .slice(beforeCount)
      .filter((item) => lastSeq === null || compareSeq(item.event.seq, lastSeq) > 0);
    if (replayed.length > 0) {
      lastAt = replayed[replayed.length - 1]!.receivedAtMs;
    }
    const now = Date.now();
    const current = entry.client.received.length;
    if (current !== seen) {
      seen = current;
      quietSince = now;
    }
    if (now >= deadline) break;
    if (lastAt !== null && now - quietSince >= quietMs) break;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  return lastAt === null ? null : Math.max(0, lastAt - subscribeAt);
}

export const gatewayRestartScenario: ChaosScenario<Prepared> = {
  name: "gateway-restart",
  precondition:
    `${CLIENTS} runs (the worker's concurrency) provably held mid-stream ` +
    "(run_started + streamed delta, no terminal) by the deferred mock gate; gateway health ok",

  async prepare(ctx: ChaosContext): Promise<Prepared> {
    const baseUrl = ctx.env.STAGING_GATEWAY_URL ?? "";
    const redisQUrl = ctx.env.STAGING_REDIS_Q_URL ?? "";
    const databaseUrl = ctx.env.STAGING_DATABASE_URL ?? "";
    const tag = `gateway-${Date.now().toString(36)}`;

    // Arm BEFORE sending: every run's first LLM request snapshots this gate.
    const gate = await ctx.mockArm({
      deltas: ["held-a", "held-b", "held-c"],
      chunkDelayMs: 0,
      gateAfterDeltas: 1,
    });

    const clients: ChaosClient[] = [];
    const observers: CloseObserver[] = [];
    let db: Db | undefined;
    let ground: ReturnType<typeof createGroundTruth> | undefined;
    try {
      clients.push(...(await openClients({ baseUrl, count: CLIENTS, tag })));
      for (const entry of clients) {
        observers.push(await openCloseObserver(baseUrl, entry.uid, entry.sessionId));
      }
      for (const entry of clients) {
        await sendRuns(entry, 1, () => `${tag} held run`);
      }

      db = createDb(databaseUrl);
      ground = createGroundTruth(redisQUrl);
      return {
        clients,
        observers,
        gate,
        gateReleased: false,
        db,
        redis: ground.redis,
        log: ground.log,
        closeCodes: [],
        closeReasons: [],
        reconnectLatencies: [],
        replayLatencies: [],
        reconnectFailures: [],
      };
    } catch (err) {
      // Unwind a partial prepare: release the held streams (they would
      // otherwise occupy every worker slot) and close every opened socket.
      gate.release();
      for (const observer of observers) observer.stop();
      await closeClients(clients);
      await ground?.redis.quit().catch(() => {});
      await db?.$client.end({ timeout: 5 }).catch(() => {});
      throw err;
    }
  },

  async gate(ctx: ChaosContext, prepared: Prepared): Promise<GateResult> {
    // Poll until every run is provably mid-stream: run_started is emitted
    // before the LLM call and the first delta arrives from the gated mock, so
    // a run that already finished can never slip through as "in flight".
    const deadline = Date.now() + 60_000;
    let last: GateResult = { ok: false, detail: "gate not evaluated" };
    for (;;) {
      const health = await readHealth(ctx.env.STAGING_GATEWAY_URL ?? "");
      const clientStates: GatewayClientState[] = prepared.clients.map((entry) => {
        const events = receivedEvents(entry);
        const counts = runEventCounts(events, entry.runIds);
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
      last = evaluateGatewayGate({
        clients: clientStates,
        expectedClients: CLIENTS,
        gateReleased: prepared.gateReleased,
        healthStatus: health.status,
      });
      if (last.ok || Date.now() >= deadline) return last;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  },

  async inject(ctx: ChaosContext, prepared: Prepared): Promise<void> {
    const restartAt = Date.now();
    await ctx.staging.restart("gateway");

    // P10 Task 2 drain contract: every live socket closes 1001
    // "server restarting" (installShutdownHandlers in the gateway).
    const closed = await Promise.all(
      prepared.observers.map(async (observer) => ({
        code: await Promise.race([
          observer.code,
          new Promise<number>((resolve) =>
            setTimeout(() => resolve(-1), RECONNECT_DEADLINE_MS).unref(),
          ),
        ]),
        reason: await Promise.race([
          observer.reason,
          new Promise<string>((resolve) =>
            setTimeout(() => resolve(""), RECONNECT_DEADLINE_MS).unref(),
          ),
        ]),
      })),
    );
    prepared.closeCodes = closed.map((entry) => entry.code);
    prepared.closeReasons = closed.map((entry) => entry.reason);

    const baseUrl = ctx.env.STAGING_GATEWAY_URL ?? "";
    await waitFor(
      "gateway health ok after restart",
      async () => ((await readHealth(baseUrl)).status === "ok" ? true : null),
      30_000,
      250,
    );

    // Give the old socket's last frames a beat to land before capturing
    // lastEventId, so replay cannot duplicate an in-flight event.
    await new Promise((resolve) => setTimeout(resolve, 50));

    await Promise.all(
      prepared.clients.map(async (entry) => {
        try {
          const remaining = Math.max(1_000, RECONNECT_DEADLINE_MS - (Date.now() - restartAt));
          const beforeCount = entry.client.received.length;
          const lastSeq = entry.client.lastEventId();
          const subscribeAt = Date.now();
          await waitFor(
            `reconnect ${entry.uid}`,
            async () => {
              try {
                await entry.client.subscribe(entry.sessionId, entry.client.lastEventId());
                return true;
              } catch {
                return null;
              }
            },
            remaining,
            250,
          );
          prepared.reconnectLatencies.push(Date.now() - restartAt);
          const replayLatency = await measureReplayLatency(
            entry,
            beforeCount,
            lastSeq,
            subscribeAt,
          );
          if (replayLatency !== null) prepared.replayLatencies.push(replayLatency);
        } catch (err) {
          prepared.reconnectFailures.push(
            `${entry.uid}: ${err instanceof Error ? err.message : String(err)}`,
          );
        }
      }),
    );

    prepared.gate.release();
    prepared.gateReleased = true;
  },

  async verify(_ctx: ChaosContext, prepared: Prepared): Promise<Assertion[]> {
    const assertions: Assertion[] = [];

    const all1001 =
      prepared.closeCodes.length === CLIENTS &&
      prepared.closeCodes.every((code) => code === EXPECTED_CLOSE_CODE);
    const allRestartReason =
      prepared.closeReasons.length === CLIENTS &&
      prepared.closeReasons.every((reason) => reason === EXPECTED_CLOSE_REASON);
    assertions.push({
      name: "drain-close-1001",
      passed: all1001 && allRestartReason,
      detail:
        `close codes: ${prepared.closeCodes.join(", ") || "none"} (expected ${CLIENTS} × ` +
        `${EXPECTED_CLOSE_CODE}); reasons: ${prepared.closeReasons.join(", ") || "none"} ` +
        `(expected ${CLIENTS} × '${EXPECTED_CLOSE_REASON}')`,
    });

    assertions.push({
      name: "reconnect-within-15s",
      passed:
        prepared.reconnectFailures.length === 0 &&
        prepared.reconnectLatencies.length === CLIENTS &&
        prepared.reconnectLatencies.every((ms) => ms <= RECONNECT_DEADLINE_MS),
      detail:
        prepared.reconnectFailures.length > 0
          ? `failures: ${prepared.reconnectFailures.join("; ")}`
          : `reconnected ${prepared.reconnectLatencies.length}/${CLIENTS} within ${RECONNECT_DEADLINE_MS}ms of the restart`,
    });

    const terminal = await waitForTerminalRuns(prepared.clients, 180_000);
    assertions.push({
      name: "all-runs-completed",
      passed: terminal.completed.size === CLIENTS && terminal.failed.size === 0,
      detail: `completed ${terminal.completed.size}/${CLIENTS}, failed ${terminal.failed.size}`,
    });

    const integrity = { lost: 0, duplicate: 0, mirrorGaps: 0 };
    const integrityErrors: string[] = [];
    let monotonic = true;
    for (const entry of prepared.clients) {
      const delivered = deliveredSeqs(entry);
      monotonic = monotonic && isMonotonic(delivered);

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
        // M1: a swallowed ground-truth read would make diffIntegrity(delivered,
        // [], []) report 0/0/0 and turn the core replay assertion vacuously
        // green. Record the failure and fail the assertion instead.
        integrityErrors.push(`${entry.sessionId}: ${errorText(err)}`);
        continue;
      }
      const diff = diffIntegrity(delivered, truth, mirror);
      integrity.lost += diff.lostEvents;
      integrity.duplicate += diff.duplicateEvents;
      integrity.mirrorGaps += diff.gapsVsMirror;
    }

    const integrityPassed =
      integrityErrors.length === 0 &&
      integrity.lost === 0 &&
      integrity.duplicate === 0 &&
      integrity.mirrorGaps === 0;
    assertions.push({
      name: "replay-integrity",
      passed: integrityPassed,
      detail:
        integrityErrors.length > 0
          ? `ground-truth read failed: ${integrityErrors.join("; ")}`
          : `lost ${integrity.lost}, duplicate ${integrity.duplicate}, mirror gaps ${integrity.mirrorGaps}`,
    });
    assertions.push({
      name: "monotonic-seqs",
      passed: monotonic,
      detail: "delivered seqs are strictly increasing across the reconnect union",
    });

    // M5: the ack latency is a RECONNECT metric (the gateway acks before it
    // replays), so it is labelled as such.
    const reconnectP95 =
      prepared.reconnectLatencies.length === 0
        ? -1
        : percentile(prepared.reconnectLatencies, 95);
    assertions.push({
      name: "reconnect-p95-recorded",
      passed: reconnectP95 >= 0,
      detail: `reconnect (restart→subscribed ack) p95 ${reconnectP95}ms across ${prepared.reconnectLatencies.length} reconnect(s)`,
    });

    // A separate replay measurement: subscribe → last replayed event. The
    // gated window emits no events, so a zero sample is expected; in that case
    // replay correctness is carried by `replay-integrity`, never by this row.
    const replayP95 =
      prepared.replayLatencies.length === 0
        ? -1
        : percentile(prepared.replayLatencies, 95);
    assertions.push({
      name: "replay-latency-recorded",
      passed:
        prepared.replayLatencies.length > 0
          ? replayP95 <= RECONNECT_DEADLINE_MS
          : integrityPassed,
      detail:
        prepared.replayLatencies.length === 0
          ? "0 events replayed (the gated window emitted nothing between lastEventId and reconnect); replay correctness is asserted by replay-integrity"
          : `subscribe→last replayed event p95 ${replayP95}ms across ${prepared.replayLatencies.length} session(s)`,
    });

    const counts = aggregateEventCounts(prepared.clients);
    assertions.push({
      name: "exactly-one-terminal-per-run",
      passed:
        counts.completed.size + counts.failed.size === CLIENTS &&
        counts.terminalEvents === CLIENTS &&
        counts.unattributedTerminal === 0,
      detail:
        `${counts.terminalEvents} terminal event(s) for ${CLIENTS} run(s) ` +
        `(completed ${counts.completed.size}, failed ${counts.failed.size}, ` +
        `unattributed ${counts.unattributedTerminal})`,
    });

    return assertions;
  },

  async cleanup(_ctx: ChaosContext, prepared: Prepared | undefined): Promise<void> {
    if (prepared === undefined) return;
    // M9: idempotent release — a failed inject must not leave every worker
    // slot occupied by a held stream for the next scenario.
    prepared.gate.release();
    for (const observer of prepared.observers) observer.stop();
    await closeClients(prepared.clients);
    await prepared.redis.quit().catch(() => {});
    await prepared.db.$client.end({ timeout: 5 }).catch(() => {});
  },
};
