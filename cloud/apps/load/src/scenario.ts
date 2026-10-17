import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { Redis } from "ioredis";
import type { Db } from "@ovid/db";
import { createRedisEventLog, type EventLog } from "@ovid/events";
import type { SessionEvent } from "@ovid/shared";
import { createLoadClient, type LoadClient } from "./client.js";
import {
  compareSeq,
  deliveryLatencies,
  diffIntegrity,
  eventDeliveryStats,
  percentile,
  type EventDeliveryStats,
} from "./metrics.js";

/**
 * Scenario DSL: ramped users, per-user run cadence, reconnect+replay, optional
 * spike and schedules, then a ground-truth diff at the end.
 *
 * Everything measured here is from the client's own view (received frames,
 * send responses) plus the read-only ground truth (`EventLog.readSince` and,
 * when configured, the Postgres mirror). The harness never mutates the
 * gateway, worker or queue.
 */

export interface LoadProfile {
  users: number;
  durationMs: number;
  rampMs: number;
  runsPerUserEveryMs: number;
  sandboxDutyCycle: number;
  browserUsers: number;
  schedules: number;
  reconnectEveryMs: number | null;
  spike?: { atMs: number; extraConcurrentRuns: number; durationMs: number };
}

export interface LoadTarget {
  baseUrl: string;
  wsBase: string;
  /** Staging redis-q URL; used for the `EventLog.readSince` ground truth. */
  redisQUrl: string;
  /** Staging Postgres URL; used for the session_event_mirror diff. */
  databaseUrl: string;
  mockLlmUrl: string;
  queuePrefix: string;
  /**
   * Additive test seams (documented in the task ledger): inject an EventLog
   * and/or mirror reader instead of dialing redis/Postgres. Used by the
   * self-contained smoke test; production runs leave them undefined.
   */
  eventLog?: EventLog;
  mirrorRead?: (sessionId: string) => Promise<string[]>;
}

export interface LoadReport {
  startedAt: string;
  durationMs: number;
  users: number;
  runsStarted: number;
  runsCompleted: number;
  runsFailed: number;
  /**
   * Additive positive-data gate (T6 review): `runIds` attributes a failure by
   * `payload.runId`; an unattributed `run_failed` would otherwise vanish from
   * `runsFailed` and let a broken run read as 0 failures. Must be 0.
   */
  runsFailedUnattributed: number;
  eventDelivery: EventDeliveryStats;
  replay: { p95Ms: number; maxMs: number; reconnects: number; samples: number };
  integrity: { lostEvents: number; duplicateEvents: number; gapsVsMirror: number };
  admission: {
    maxObservedActiveSandboxes: number;
    queuedAtCap: number;
    rejectedAtCap: number;
    /** Additive: spike-end → last queued spike run started (Task 5 ≤600 s). */
    spikeDrainMs?: number;
    /**
     * Additive positive-data gate (T6 review): spike sends that were accepted
     * by the gateway. `spikeDrainMs` reads 0 when no spike ever fired, so the
     * drain threshold alone is vacuous; this must be > 0.
     */
    spikeRuns: number;
  };
  memory: {
    gatewayMaxRssMb: number;
    hostMemAvailableMinMb: number;
    workerMaxRssMb: number;
  };
  harness: {
    maxPendingFrames: number;
    latencyFloorP95Ms: number;
    /**
     * Additive positive-data gate (T6 review): off-contract server frames the
     * client rejected. A harness that silently accepts drift is not measuring
     * the real wire contract; must be 0.
     */
    invalidFrames: number;
  };
  scheduleRuns: { fired: number; duplicated: number; missed: number };
  thresholdFailures: string[];
  /** Additive: loud "NOT EXERCISED" notes (browser tier, schedule tier, …). */
  notes?: string[];
}

const DRAIN_TIMEOUT_MS = 15_000;
const REPLAY_WAIT_MS = 2_000;
const MEMORY_SAMPLE_EVERY_MS = 5_000;
const PENDING_SAMPLE_EVERY_MS = 25;
const GROUND_TRUTH_LIMIT = 100_000;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function run(
  command: string,
  args: string[],
  timeoutMs: number,
): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(command, args, { timeout: timeoutMs, encoding: "utf8" }, (err, stdout) => {
      if (err) reject(err);
      else resolve(stdout);
    });
  });
}

/** "123.4MiB / 1GiB" → 123.4 (MiB). Unknown shapes are ignored. */
function parseMiB(value: string): number | null {
  const match = /^([\d.]+)\s*(B|KiB|MiB|GiB)$/i.exec(value.trim());
  if (match === null) return null;
  const amount = Number(match[1]);
  if (!Number.isFinite(amount)) return null;
  switch (match[2]!.toLowerCase()) {
    case "b":
      return amount / (1024 * 1024);
    case "kib":
      return amount / 1024;
    case "mib":
      return amount;
    case "gib":
      return amount * 1024;
    default:
      return null;
  }
}

interface MemoryState {
  gatewayMaxRssMb: number;
  workerMaxRssMb: number;
  hostMemAvailableMinMb: number;
}

/**
 * Best-effort host sampler. Docker/ps are absent in the self-contained test
 * environment; every probe is individually guarded, so a missing tool simply
 * leaves its metric at 0 (and the smoke threshold table does not gate on
 * memory). Staging (Task 5) has both.
 */
async function sampleMemory(state: MemoryState): Promise<void> {
  try {
    const meminfo = await readFile("/proc/meminfo", "utf8");
    const match = /^MemAvailable:\s+(\d+)\s+kB/m.exec(meminfo);
    if (match !== null) {
      const mb = Number(match[1]) / 1024;
      state.hostMemAvailableMinMb =
        state.hostMemAvailableMinMb === 0
          ? mb
          : Math.min(state.hostMemAvailableMinMb, mb);
    }
  } catch {
    // /proc unavailable (non-Linux) — leave the metric at 0
  }

  try {
    const stdout = await run(
      "docker",
      ["stats", "--no-stream", "--format", "{{.Name}} {{.MemUsage}}"],
      5_000,
    );
    for (const line of stdout.split("\n")) {
      const trimmed = line.trim();
      if (trimmed === "") continue;
      const [name, usage] = trimmed.split(/\s+/, 2);
      if (name === undefined || usage === undefined) continue;
      const mb = parseMiB(usage);
      if (mb === null) continue;
      if (name.includes("gateway")) {
        state.gatewayMaxRssMb = Math.max(state.gatewayMaxRssMb, mb);
      } else if (name.includes("worker")) {
        state.workerMaxRssMb = Math.max(state.workerMaxRssMb, mb);
      }
    }
  } catch {
    // docker not installed / not running
  }

  try {
    const pidOut = await run("pgrep", ["-f", "apps/worker/dist/main.js"], 2_000);
    const pids = pidOut.trim().split(/\s+/).filter((p) => p !== "");
    if (pids.length > 0) {
      const rssOut = await run("ps", ["-o", "rss=", "-p", pids.join(",")], 2_000);
      const rssKb = rssOut
        .split(/\s+/)
        .filter((v) => v !== "")
        .reduce((sum, v) => sum + Number(v), 0);
      if (Number.isFinite(rssKb)) {
        state.workerMaxRssMb = Math.max(state.workerMaxRssMb, rssKb / 1024);
      }
    }
  } catch {
    // worker not a host process / ps unavailable
  }
}

function runIds(events: SessionEvent[]): {
  started: Set<string>;
  completed: Set<string>;
  failed: Set<string>;
  unattributedFailed: number;
} {
  const started = new Set<string>();
  const completed = new Set<string>();
  const failed = new Set<string>();
  let unattributedFailed = 0;
  for (const event of events) {
    if (event.type === "run_failed") {
      // Never drop a failure on the floor: a `run_failed` without a string
      // runId cannot be attributed, but it is still counted (and gated).
      const runId = event.payload.runId;
      if (typeof runId !== "string" || runId === "") unattributedFailed += 1;
      else failed.add(runId);
      continue;
    }
    const runId = event.payload.runId;
    if (typeof runId !== "string") continue;
    if (event.type === "run_started") started.add(runId);
    else if (event.type === "run_completed") completed.add(runId);
  }
  return { started, completed, failed, unattributedFailed };
}

export async function runScenario(
  profile: LoadProfile,
  target: LoadTarget,
): Promise<LoadReport> {
  if (!Number.isInteger(profile.users) || profile.users <= 0) {
    throw new Error("runScenario: users must be a positive integer");
  }
  if (profile.durationMs <= 0) {
    throw new Error("runScenario: durationMs must be positive");
  }
  if (profile.runsPerUserEveryMs <= 0) {
    throw new Error("runScenario: runsPerUserEveryMs must be positive");
  }
  if (profile.rampMs < 0) {
    throw new Error("runScenario: rampMs must be >= 0");
  }

  const startedAt = new Date().toISOString();
  const startedMs = Date.now();
  const stopAt = startedMs + profile.durationMs;
  const runTag = `load-${startedMs.toString(36)}-${Math.random().toString(36).slice(2, 6)}`;

  const clients: Array<LoadClient | undefined> = [];
  const sessions: Array<string | undefined> = [];
  const notes: string[] = [];
  const replaySamples: number[] = [];
  let sends = 0;
  let sendFailures = 0;
  let reconnects = 0;
  let maxPendingFrames = 0;
  let browserAttached = 0;
  const spikeRunIds: string[] = [];
  let spikeEndedAt: number | undefined;

  // ---- Ground truth (read-only) -------------------------------------------
  let groundTruth: EventLog | undefined = target.eventLog;
  let redis: Redis | undefined;
  if (groundTruth === undefined && target.redisQUrl !== "") {
    redis = new Redis(target.redisQUrl, { maxRetriesPerRequest: 2 });
    groundTruth = createRedisEventLog(redis);
  }

  let mirrorRead = target.mirrorRead;
  let db: Db | undefined;
  if (mirrorRead === undefined && target.databaseUrl !== "") {
    const dbModule = await import("@ovid/db");
    db = dbModule.createDb(target.databaseUrl);
    mirrorRead = async (sessionId) =>
      (await dbModule.eventMirror.readSince(db!, sessionId, null, GROUND_TRUTH_LIMIT)).map(
        (event) => event.seq,
      );
  }

  // ---- Samplers ------------------------------------------------------------
  const memory: MemoryState = {
    gatewayMaxRssMb: 0,
    workerMaxRssMb: 0,
    hostMemAvailableMinMb: 0,
  };
  let sampling = true;
  const sampler = (async () => {
    let lastMemory = 0;
    while (sampling) {
      const pending = clients.reduce(
        (max, client) => (client === undefined ? max : Math.max(max, client.pendingFrames())),
        0,
      );
      maxPendingFrames = Math.max(maxPendingFrames, pending);
      if (Date.now() - lastMemory >= MEMORY_SAMPLE_EVERY_MS) {
        lastMemory = Date.now();
        await sampleMemory(memory);
      }
      await sleep(PENDING_SAMPLE_EVERY_MS);
    }
  })();

  // ---- Per-user loops ------------------------------------------------------

  async function reconnect(client: LoadClient, sessionId: string): Promise<void> {
    const prior = client.lastEventId();
    let missed: SessionEvent[] = [];
    if (groundTruth !== undefined) {
      try {
        missed = await groundTruth.readSince(sessionId, prior, GROUND_TRUTH_LIMIT);
      } catch (err) {
        notes.push(`ground truth read failed: ${err instanceof Error ? err.message : String(err)}`);
      }
    }
    client.terminate();
    const reconnectStart = Date.now();
    await client.subscribe(sessionId, prior);
    reconnects += 1;

    if (missed.length > 0) {
      const lastSeq = missed[missed.length - 1]!.seq;
      const deadline = Date.now() + REPLAY_WAIT_MS;
      while (
        Date.now() < deadline &&
        !client.received.some((item) => item.event.seq === lastSeq)
      ) {
        await sleep(5);
      }
      if (client.received.some((item) => item.event.seq === lastSeq)) {
        replaySamples.push(Date.now() - reconnectStart);
      } else {
        notes.push(`replay did not deliver missed seq ${lastSeq} within ${REPLAY_WAIT_MS}ms`);
      }
    }
  }

  async function runUser(index: number): Promise<void> {
    const client = await createLoadClient({
      baseUrl: target.baseUrl,
      wsBase: target.wsBase,
      uid: `${runTag}-u${index}`,
      authMode: "test",
    });
    clients[index] = client;
    const sessionId = await client.createSession();
    sessions[index] = sessionId;
    await client.subscribe(sessionId, null);

    if (index < profile.browserUsers) {
      client.sendOp({ op: "browser_attach", sessionId });
      await sleep(25);
      const refusal = client.errors.find(
        (error) => error.code === "unavailable" || error.code === "invalid_frame",
      );
      if (refusal === undefined) browserAttached += 1;
      else notes.push(`browser tier: NOT EXERCISED (${refusal.code}: ${refusal.message})`);
    }

    let nextSend = Date.now();
    let nextReconnect =
      profile.reconnectEveryMs === null
        ? Number.POSITIVE_INFINITY
        : Date.now() + profile.reconnectEveryMs;

    while (Date.now() < stopAt) {
      const now = Date.now();
      if (now >= nextReconnect) {
        try {
          await reconnect(client, sessionId);
        } catch (err) {
          notes.push(`reconnect failed: ${err instanceof Error ? err.message : String(err)}`);
        }
        nextReconnect += profile.reconnectEveryMs!;
        while (nextReconnect <= Date.now()) nextReconnect += profile.reconnectEveryMs!;
      }

      if (Date.now() >= nextSend) {
        const slot = sends % 100;
        const sandbox = slot < Math.round(profile.sandboxDutyCycle * 100);
        const content = `${sandbox ? "[sandbox] " : ""}${runTag} run ${sends}`;
        try {
          await client.sendMessage(sessionId, content);
          sends += 1;
        } catch (err) {
          sendFailures += 1;
          notes.push(`send failed: ${err instanceof Error ? err.message : String(err)}`);
        }
        nextSend += profile.runsPerUserEveryMs;
        while (nextSend <= Date.now()) nextSend += profile.runsPerUserEveryMs;
      }

      const until = Math.min(nextSend, nextReconnect, stopAt);
      await sleep(Math.max(5, Math.min(25, until - Date.now())));
    }
  }

  // ---- Optional spike ------------------------------------------------------
  let spikeTimer: ReturnType<typeof setTimeout> | undefined;
  let spikeTask: Promise<void> = Promise.resolve();
  async function fireSpike(): Promise<void> {
    const spike = profile.spike;
    if (spike === undefined) return;
    const deadline = Date.now() + 5_000;
    for (let i = 0; i < spike.extraConcurrentRuns && Date.now() < deadline; i += 1) {
      const live = clients
        .map((client, index) => ({ client, sessionId: sessions[index] }))
        .filter(
          (entry): entry is { client: LoadClient; sessionId: string } =>
            entry.client !== undefined && entry.sessionId !== undefined,
        );
      if (live.length === 0) {
        await sleep(25);
        continue;
      }
      const chosen = live[i % live.length]!;
      try {
        const sent = await chosen.client.sendMessage(chosen.sessionId, `${runTag} spike ${i}`);
        spikeRunIds.push(sent.runId);
        sends += 1;
      } catch (err) {
        sendFailures += 1;
        notes.push(`spike send failed: ${err instanceof Error ? err.message : String(err)}`);
      }
      await sleep(Math.max(1, Math.floor(5_000 / Math.max(1, spike.extraConcurrentRuns))));
    }
    spikeEndedAt = Date.now();
  }
  if (profile.spike !== undefined) {
    spikeTimer = setTimeout(() => {
      spikeTask = fireSpike().catch((err: unknown) => {
        notes.push(`spike failed: ${err instanceof Error ? err.message : String(err)}`);
      });
    }, profile.spike.atMs);
  }

  // ---- Optional schedules --------------------------------------------------
  const scheduleIds: string[] = [];
  async function createSchedules(): Promise<void> {
    if (profile.schedules <= 0) return;
    const deadline = Date.now() + 5_000;
    let sessionId: string | undefined;
    while (Date.now() < deadline && sessionId === undefined) {
      sessionId = sessions.find((sid) => sid !== undefined);
      if (sessionId === undefined) await sleep(25);
    }
    if (sessionId === undefined) {
      notes.push("schedule tier: NOT EXERCISED (no session available at ramp start)");
      return;
    }
    for (let i = 0; i < profile.schedules; i += 1) {
      const response = await fetch(`${target.baseUrl}/cloud/v1/schedules`, {
        method: "POST",
        headers: {
          authorization: `Bearer test:${runTag}-sched`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          title: `load schedule ${i}`,
          description: "load harness schedule",
          trigger: { kind: "every", seconds: 300 },
          sessionId,
        }),
      });
      if (!response.ok) {
        notes.push(
          `schedule tier: NOT EXERCISED (POST /cloud/v1/schedules → ${response.status})`,
        );
        return;
      }
      const body = (await response.json()) as { id?: unknown };
      if (typeof body.id === "string") scheduleIds.push(body.id);
    }
  }
  const schedulesTask = createSchedules();

  // ---- Ramp + run ----------------------------------------------------------
  const userTasks = Array.from({ length: profile.users }, (_, index) => {
    const delay =
      profile.rampMs === 0 ? 0 : Math.floor((index * profile.rampMs) / profile.users);
    return sleep(delay).then(async () => {
      if (Date.now() >= stopAt) return;
      try {
        await runUser(index);
      } catch (err) {
        notes.push(
          `user ${index} failed: ${err instanceof Error ? err.message : String(err)}`,
        );
      }
    });
  });

  await Promise.allSettled(userTasks);
  await schedulesTask.catch(() => {});
  await spikeTask;
  if (spikeTimer !== undefined) clearTimeout(spikeTimer);

  // ---- Drain: wait for every accepted run to reach a terminal event -------
  const drainDeadline = Date.now() + DRAIN_TIMEOUT_MS;
  for (;;) {
    const events = clients.flatMap((client) =>
      client === undefined ? [] : client.received.map((item) => item.event),
    );
    const { started, completed, failed } = runIds(events);
    if (started.size >= sends && completed.size + failed.size >= started.size) break;
    if (Date.now() >= drainDeadline) {
      notes.push(
        `drain timed out: sends=${sends} started=${started.size} completed=${completed.size} failed=${failed.size}`,
      );
      break;
    }
    await sleep(25);
  }

  sampling = false;
  await sampler;

  // ---- Aggregate -----------------------------------------------------------
  const allReceived = clients.flatMap((client) => client?.received ?? []);
  const allEvents = allReceived.map((item) => item.event);
  const counts = runIds(allEvents);

  let lostEvents = 0;
  let duplicateEvents = 0;
  let gapsVsMirror = 0;
  for (let index = 0; index < sessions.length; index += 1) {
    const sessionId = sessions[index];
    const client = clients[index];
    if (sessionId === undefined || client === undefined) continue;
    const delivered = client.received
      .filter((item) => item.event.sessionId === sessionId)
      .map((item) => item.event.seq);

    let truthSeqs: string[];
    if (groundTruth !== undefined) {
      try {
        truthSeqs = (await groundTruth.readSince(sessionId, null, GROUND_TRUTH_LIMIT)).map(
          (event) => event.seq,
        );
      } catch (err) {
        notes.push(
          `ground truth read failed for ${sessionId}: ${
            err instanceof Error ? err.message : String(err)
          }`,
        );
        truthSeqs = [...new Set(delivered)];
      }
    } else {
      truthSeqs = [...new Set(delivered)];
    }

    let mirrorSeqs: string[] | undefined;
    if (mirrorRead !== undefined) {
      try {
        mirrorSeqs = await mirrorRead(sessionId);
      } catch (err) {
        notes.push(
          `mirror read failed for ${sessionId}: ${
            err instanceof Error ? err.message : String(err)
          }`,
        );
      }
    }

    const diff = diffIntegrity(delivered, truthSeqs, mirrorSeqs ?? truthSeqs);
    lostEvents += diff.lostEvents;
    duplicateEvents += diff.duplicateEvents;
    gapsVsMirror += diff.gapsVsMirror;
  }

  // Admission: track tool_started/tool_completed pairs per session.
  let maxObservedActiveSandboxes = 0;
  for (let index = 0; index < sessions.length; index += 1) {
    const client = clients[index];
    if (client === undefined) continue;
    let active = 0;
    for (const item of client.received) {
      if (item.event.type === "tool_started") {
        active += 1;
        maxObservedActiveSandboxes = Math.max(maxObservedActiveSandboxes, active);
      } else if (item.event.type === "tool_completed") {
        active = Math.max(0, active - 1);
      }
    }
  }
  const errorFrames = clients.flatMap((client) => client?.errors ?? []);
  const queuedAtCap = errorFrames.filter((error) => error.code === "sandbox_busy").length;
  const rejectedAtCap = errorFrames.filter(
    (error) => error.code === "sandbox_unavailable",
  ).length;

  // Spike drain: from the end of the spike burst to the last spike run's
  // run_started. 0 when no spike ran; a value only appears once every spike
  // run has started (Task 5 gates this at ≤600 s).
  let spikeDrainMs = 0;
  if (spikeRunIds.length > 0 && spikeEndedAt !== undefined) {
    let lastStartedAt = 0;
    for (const client of clients) {
      if (client === undefined) continue;
      for (const item of client.received) {
        if (item.event.type !== "run_started") continue;
        const runId = item.event.payload.runId;
        if (typeof runId === "string" && spikeRunIds.includes(runId)) {
          lastStartedAt = Math.max(lastStartedAt, item.receivedAtMs);
        }
      }
    }
    if (lastStartedAt > 0) spikeDrainMs = Math.max(0, lastStartedAt - spikeEndedAt);
  }

  // Schedules: best-effort claim-ledger read (needs staging Postgres).
  let fired = 0;
  let duplicated = 0;
  let missed = 0;
  if (db !== undefined && scheduleIds.length > 0) {
    try {
      const rows = (await db.$client.unsafe(
        `SELECT status, count(*)::int AS n
           FROM schedule_runs
          WHERE schedule_id = ANY($1)
          GROUP BY status`,
        [scheduleIds],
      )) as Array<{ status: string; n: number }>;
      for (const row of rows) {
        if (row.status === "running" || row.status === "retry_scheduled" || row.status === "succeeded") {
          fired += Number(row.n);
        }
        if (row.status === "skipped") missed += Number(row.n);
      }
      const dupRows = (await db.$client.unsafe(
        `SELECT count(*)::int AS n
           FROM (
             SELECT schedule_id, scheduled_for
               FROM schedule_runs
              WHERE schedule_id = ANY($1)
              GROUP BY schedule_id, scheduled_for
             HAVING count(*) > 1
           ) dup`,
        [scheduleIds],
      )) as Array<{ n: number }>;
      duplicated = Number(dupRows[0]?.n ?? 0);
    } catch (err) {
      notes.push(
        `schedule ledger read failed: ${err instanceof Error ? err.message : String(err)}`,
      );
    }
  } else if (profile.schedules > 0 && scheduleIds.length > 0) {
    notes.push("schedule tier: claim ledger NOT READ (no staging Postgres configured)");
  }

  const dispatchSamples = clients.flatMap((client) => client?.dispatchLatenciesMs() ?? []);
  const replayP95 =
    replaySamples.length === 0 ? 0 : percentile(replaySamples, 95);
  const replayMax = replaySamples.length === 0 ? 0 : Math.max(...replaySamples);

  const report: LoadReport = {
    startedAt,
    durationMs: Date.now() - startedMs,
    users: profile.users,
    runsStarted: counts.started.size,
    runsCompleted: counts.completed.size,
    runsFailed: counts.failed.size,
    runsFailedUnattributed: counts.unattributedFailed,
    eventDelivery: eventDeliveryStats(allReceived),
    replay: {
      p95Ms: replayP95,
      maxMs: replayMax,
      reconnects,
      samples: replaySamples.length,
    },
    integrity: { lostEvents, duplicateEvents, gapsVsMirror },
    admission: {
      maxObservedActiveSandboxes,
      queuedAtCap,
      rejectedAtCap,
      spikeDrainMs,
      spikeRuns: spikeRunIds.length,
    },
    memory: {
      gatewayMaxRssMb: Math.round(memory.gatewayMaxRssMb),
      hostMemAvailableMinMb: Math.round(memory.hostMemAvailableMinMb),
      workerMaxRssMb: Math.round(memory.workerMaxRssMb),
    },
    harness: {
      maxPendingFrames,
      latencyFloorP95Ms:
        dispatchSamples.length === 0 ? 0 : percentile(dispatchSamples, 95),
      invalidFrames: clients.reduce(
        (sum, client) => sum + (client?.invalidFrames() ?? 0),
        0,
      ),
    },
    scheduleRuns: { fired, duplicated, missed },
    thresholdFailures: [],
    notes,
  };

  if (sendFailures > 0) {
    report.notes = [...(report.notes ?? []), `send failures: ${sendFailures}`];
  }
  if (browserAttached > 0) {
    report.notes = [...(report.notes ?? []), `browser tier: ${browserAttached} attached`];
  }

  // ---- Teardown ------------------------------------------------------------
  await Promise.allSettled(clients.map((client) => client?.close() ?? Promise.resolve()));
  if (redis !== undefined) await redis.quit().catch(() => {});
  if (db !== undefined) await db.$client.end({ timeout: 5 }).catch(() => {});

  return report;
}

export { deliveryLatencies, compareSeq };
