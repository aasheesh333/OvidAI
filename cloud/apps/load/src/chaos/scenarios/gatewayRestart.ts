import WebSocket from "ws";
import { createDb, type Db } from "@ovid/db";
import { percentile, diffIntegrity } from "../../metrics.js";
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

const CLIENTS = 10;
const RECONNECT_DEADLINE_MS = 15_000;

export interface GatewayClientState {
  runStarted: boolean;
  deltaSeen: boolean;
  terminal: boolean;
}

export interface GatewayGateState {
  clients: GatewayClientState[];
  gateReleased: boolean;
  healthStatus: "ok" | "degraded" | "unreachable";
}

/** Pure gate logic (unit-tested). */
export function evaluateGatewayGate(state: GatewayGateState): GateResult {
  const problems: string[] = [];
  if (state.clients.length === 0) {
    problems.push("no clients prepared");
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
  if (problems.length > 0) {
    return { ok: false, detail: problems.join("; ") };
  }
  return {
    ok: true,
    detail: `${state.clients.length} run(s) provably in-flight (run_started + delta seen, no terminal) with the mock gate held`,
  };
}

interface CloseObserver {
  code: Promise<number>;
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
  const code = new Promise<number>((resolve) => {
    socket.once("close", (closeCode) => resolve(closeCode));
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
  reconnectLatencies: number[];
  reconnectFailures: string[];
}

export const gatewayRestartScenario: ChaosScenario<Prepared> = {
  name: "gateway-restart",
  precondition:
    "10 runs provably held mid-stream (run_started + streamed delta, no terminal) by the deferred mock gate; gateway health ok",

  async prepare(ctx: ChaosContext): Promise<Prepared> {
    const baseUrl = ctx.env.STAGING_GATEWAY_URL ?? "";
    const redisQUrl = ctx.env.STAGING_REDIS_Q_URL ?? "";
    const databaseUrl = ctx.env.STAGING_DATABASE_URL ?? "";
    const tag = `gateway-${Date.now().toString(36)}`;

    // Arm BEFORE sending: every run's first LLM request snapshots this gate.
    const gate = ctx.mockArm({
      deltas: ["held-a", "held-b", "held-c"],
      chunkDelayMs: 0,
      gateAfterDeltas: 1,
    });

    const clients = await openClients({ baseUrl, count: CLIENTS, tag });
    const observers: CloseObserver[] = [];
    for (const entry of clients) {
      observers.push(await openCloseObserver(baseUrl, entry.uid, entry.sessionId));
    }
    for (const entry of clients) {
      await sendRuns(entry, 1, () => `${tag} held run`);
    }

    const db = createDb(databaseUrl);
    const { log, redis } = createGroundTruth(redisQUrl);
    return {
      clients,
      observers,
      gate,
      gateReleased: false,
      db,
      redis,
      log,
      closeCodes: [],
      reconnectLatencies: [],
      reconnectFailures: [],
    };
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
      last = evaluateGatewayGate({
        clients: clientStates,
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

    // Task-2 drain contract: every live socket closes with 1001.
    prepared.closeCodes = await Promise.all(
      prepared.observers.map((observer) =>
        Promise.race([
          observer.code,
          new Promise<number>((resolve) =>
            setTimeout(() => resolve(-1), RECONNECT_DEADLINE_MS).unref(),
          ),
        ]),
      ),
    );

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
      prepared.closeCodes.every((code) => code === 1001);
    assertions.push({
      name: "drain-close-1001",
      passed: all1001,
      detail: `close codes: ${prepared.closeCodes.join(", ")} (expected ${CLIENTS} × 1001)`,
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
      } catch {
        // the diff below records the gap
      }
      const diff = diffIntegrity(delivered, truth, mirror);
      integrity.lost += diff.lostEvents;
      integrity.duplicate += diff.duplicateEvents;
      integrity.mirrorGaps += diff.gapsVsMirror;
    }

    assertions.push({
      name: "replay-integrity",
      passed:
        integrity.lost === 0 && integrity.duplicate === 0 && integrity.mirrorGaps === 0,
      detail: `lost ${integrity.lost}, duplicate ${integrity.duplicate}, mirror gaps ${integrity.mirrorGaps}`,
    });
    assertions.push({
      name: "monotonic-seqs",
      passed: monotonic,
      detail: "delivered seqs are strictly increasing across the reconnect union",
    });

    const p95 =
      prepared.reconnectLatencies.length === 0
        ? -1
        : percentile(prepared.reconnectLatencies, 95);
    assertions.push({
      name: "replay-p95-recorded",
      passed: p95 >= 0,
      detail: `reconnect (restart→subscribed) p95 ${p95}ms across ${prepared.reconnectLatencies.length} reconnect(s); the gated window had no missed events to replay beyond lastEventId`,
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
      detail: `${terminalEvents.length} terminal event(s) for ${CLIENTS} run(s)`,
    });

    return assertions;
  },

  async cleanup(_ctx: ChaosContext, prepared: Prepared): Promise<void> {
    for (const observer of prepared.observers) observer.stop();
    await closeClients(prepared.clients);
    await prepared.redis.quit().catch(() => {});
    await prepared.db.$client.end({ timeout: 5 }).catch(() => {});
  },
};
