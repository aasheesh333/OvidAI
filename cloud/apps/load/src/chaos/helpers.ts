import { Redis } from "ioredis";
import type { Db } from "@ovid/db";
import { createRedisEventLog } from "@ovid/events";
import type { SessionEvent } from "@ovid/shared";
import { createLoadClient, type LoadClient } from "../client.js";
import { compareSeq } from "../metrics.js";

/**
 * Shared primitives for the chaos scenarios. Nothing here injects a failure —
 * scenarios use these to prepare a vulnerable state and to read ground truth
 * afterwards.
 */

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function errorText(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/** Poll until `probe` returns a non-null/undefined/false value. */
export async function waitFor<T>(
  label: string,
  probe: () => Promise<T | null | undefined | false>,
  timeoutMs: number,
  intervalMs = 100,
): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  let lastError: unknown;
  for (;;) {
    try {
      const value = await probe();
      if (value !== null && value !== undefined && value !== false) {
        return value as T;
      }
    } catch (err) {
      lastError = err;
    }
    if (Date.now() >= deadline) {
      const suffix =
        lastError === undefined
          ? ""
          : ` (last error: ${lastError instanceof Error ? lastError.message : String(lastError)})`;
      throw new Error(`${label}: timed out after ${timeoutMs}ms${suffix}`);
    }
    await sleep(intervalMs);
  }
}

export function wsBaseFor(baseUrl: string): string {
  return `${baseUrl.replace(/^http/, "ws").replace(/\/+$/, "")}/cloud/ws`;
}

export interface ChaosClient {
  client: LoadClient;
  sessionId: string;
  uid: string;
  /** runIds this client enqueued, in send order. */
  runIds: string[];
}

export interface OpenClientsOptions {
  baseUrl: string;
  count: number;
  tag: string;
}

export async function openClients(opts: OpenClientsOptions): Promise<ChaosClient[]> {
  const clients: ChaosClient[] = [];
  try {
    for (let index = 0; index < opts.count; index += 1) {
      const uid = `chaos-${opts.tag}-u${index}`;
      const client = await createLoadClient({
        baseUrl: opts.baseUrl,
        wsBase: wsBaseFor(opts.baseUrl),
        uid,
        authMode: "test",
      });
      const sessionId = await client.createSession();
      await client.subscribe(sessionId, null);
      clients.push({ client, sessionId, uid, runIds: [] });
    }
  } catch (err) {
    // A partially-opened set must not leak sockets into the next scenario.
    await closeClients(clients);
    throw err;
  }
  return clients;
}

export async function closeClients(clients: ChaosClient[]): Promise<void> {
  await Promise.allSettled(clients.map((entry) => entry.client.close()));
}

/** Send one run per `count` and record the runIds. */
export async function sendRuns(
  entry: ChaosClient,
  count: number,
  content: (index: number) => string,
): Promise<void> {
  for (let index = 0; index < count; index += 1) {
    const response = await entry.client.sendMessage(entry.sessionId, content(index));
    entry.runIds.push(response.runId);
  }
}

export interface HealthSnapshot {
  statusCode: number;
  status: "ok" | "degraded" | "unreachable";
  checks: { db: boolean; redisQ: boolean };
  raw: string;
}

export async function readHealth(baseUrl: string): Promise<HealthSnapshot> {
  try {
    const response = await fetch(`${baseUrl.replace(/\/+$/, "")}/cloud/v1/health`, {
      // The gateway can be mid-restart; a hung probe would stall the poller.
      signal: AbortSignal.timeout(2_000),
    });
    const raw = await response.text();
    let body: {
      status?: unknown;
      checks?: { db?: unknown; redisQ?: unknown };
    } = {};
    try {
      body = JSON.parse(raw) as typeof body;
    } catch {
      // non-JSON body — keep unreachable semantics with the raw text
    }
    const status =
      body.status === "ok" || body.status === "degraded" ? body.status : "unreachable";
    return {
      statusCode: response.status,
      status,
      checks: { db: body.checks?.db === true, redisQ: body.checks?.redisQ === true },
      raw,
    };
  } catch (err) {
    return {
      statusCode: 0,
      status: "unreachable",
      checks: { db: false, redisQ: false },
      raw: err instanceof Error ? err.message : String(err),
    };
  }
}

export interface EventCounts {
  started: Set<string>;
  completed: Set<string>;
  failed: Set<string>;
  /**
   * Terminal events (`run_completed`/`run_failed`) that carried no
   * `payload.runId` and could not be attributed to exactly one still-open
   * expected run. They are counted here instead of being silently dropped.
   */
  unattributedTerminal: number;
  /** Every terminal event observed, attributed or not (duplicate detection). */
  terminalEvents: number;
}

/**
 * Attribute run events to runIds.
 *
 * Most failure paths emit `run_failed` WITHOUT `payload.runId`
 * (`run_queue_wait_timeout`, `model_terminal`, `key_not_minted`, …). Dropping
 * those made `waitForTerminalRuns` time out and let the postgres scenario's
 * "run_failed accepted" branch go unimplemented. When `expectedRunIds` is
 * supplied, an unlabelled terminal event is attributed to the single expected
 * run that has not reached a terminal state yet; if that is ambiguous it is
 * still counted (`unattributedTerminal`) so the exactly-one-terminal checks
 * cannot pass vacuously.
 */
export function runEventCounts(
  events: SessionEvent[],
  expectedRunIds: string[] = [],
): EventCounts {
  const started = new Set<string>();
  const completed = new Set<string>();
  const failed = new Set<string>();
  let unattributedTerminal = 0;
  let terminalEvents = 0;
  for (const event of events) {
    const runId = event.payload.runId;
    if (event.type === "run_started") {
      if (typeof runId === "string") started.add(runId);
      continue;
    }
    if (event.type !== "run_completed" && event.type !== "run_failed") continue;
    terminalEvents += 1;
    if (typeof runId === "string") {
      if (event.type === "run_completed") completed.add(runId);
      else failed.add(runId);
      continue;
    }
    const open = expectedRunIds.filter(
      (expected) => !completed.has(expected) && !failed.has(expected),
    );
    if (open.length === 1) {
      if (event.type === "run_completed") completed.add(open[0]!);
      else failed.add(open[0]!);
    } else {
      unattributedTerminal += 1;
    }
  }
  return { started, completed, failed, unattributedTerminal, terminalEvents };
}

/** Merge per-client counts (session-scoped attribution) across the scenario. */
export function aggregateEventCounts(clients: ChaosClient[]): EventCounts {
  const aggregate: EventCounts = {
    started: new Set(),
    completed: new Set(),
    failed: new Set(),
    unattributedTerminal: 0,
    terminalEvents: 0,
  };
  for (const entry of clients) {
    const counts = runEventCounts(receivedEvents(entry), entry.runIds);
    for (const runId of counts.started) aggregate.started.add(runId);
    for (const runId of counts.completed) aggregate.completed.add(runId);
    for (const runId of counts.failed) aggregate.failed.add(runId);
    aggregate.unattributedTerminal += counts.unattributedTerminal;
    aggregate.terminalEvents += counts.terminalEvents;
  }
  return aggregate;
}

export function receivedEvents(entry: ChaosClient): SessionEvent[] {
  return entry.client.received.map((item) => item.event);
}

/** Every runId this client enqueued reached exactly one terminal event. */
export async function waitForTerminalRuns(
  clients: ChaosClient[],
  timeoutMs: number,
): Promise<{
  completed: Set<string>;
  failed: Set<string>;
  terminal: Set<string>;
  unattributedTerminal: number;
}> {
  return waitFor(
    "runs terminal",
    async () => {
      const completed = new Set<string>();
      const failed = new Set<string>();
      let unattributedTerminal = 0;
      for (const entry of clients) {
        const counts = runEventCounts(receivedEvents(entry), entry.runIds);
        unattributedTerminal += counts.unattributedTerminal;
        for (const runId of entry.runIds) {
          if (counts.completed.has(runId)) completed.add(runId);
          if (counts.failed.has(runId)) failed.add(runId);
        }
      }
      const terminal = new Set([...completed, ...failed]);
      const expected = clients.reduce((sum, entry) => sum + entry.runIds.length, 0);
      return terminal.size >= expected
        ? { completed, failed, terminal, unattributedTerminal }
        : null;
    },
    timeoutMs,
    250,
  );
}

export function deliveredSeqs(entry: ChaosClient): string[] {
  return entry.client.received
    .filter((item) => item.event.sessionId === entry.sessionId)
    .map((item) => item.event.seq);
}

export function createGroundTruth(redisQUrl: string): {
  log: ReturnType<typeof createRedisEventLog>;
  redis: Redis;
} {
  const redis = new Redis(redisQUrl, { maxRetriesPerRequest: 2 });
  // Chaos restarts redis-q on purpose: ioredis emits 'error' on every failed
  // reconnect, and an unhandled EventEmitter error would kill the runner.
  redis.on("error", () => {});
  return { log: createRedisEventLog(redis), redis };
}

export async function groundTruthSeqs(
  log: ReturnType<typeof createRedisEventLog>,
  sessionId: string,
): Promise<string[]> {
  const events = await log.readSince(sessionId, null, 100_000);
  return events.map((event) => event.seq);
}

export async function mirrorSeqs(db: Db, sessionId: string): Promise<string[]> {
  const { eventMirror } = await import("@ovid/db");
  const events = await eventMirror.readSince(db, sessionId, null, 100_000);
  return events.map((event) => event.seq);
}

/** Monotonic (strictly increasing) seq order as delivered. */
export function isMonotonic(seqs: string[]): boolean {
  for (let index = 1; index < seqs.length; index += 1) {
    if (compareSeq(seqs[index - 1]!, seqs[index]!) >= 0) return false;
  }
  return true;
}

export function dedupe<T>(values: T[]): T[] {
  return [...new Set(values)];
}
