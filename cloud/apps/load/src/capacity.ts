import { monitorEventLoopDelay } from "node:perf_hooks";
import WebSocket from "ws";
import { LatencyHistogram, type SerializedHistogram } from "./hdr.js";

/**
 * Capacity driver (2026-10-19 capacity wave): "N users concurrently ACTIVE".
 *
 * Unlike scenario.ts (integrity-first: keeps every frame, zod-parses it,
 * diffs against ground truth), this driver is built to put thousands of
 * realistic users on ONE box and measure the latency the user feels:
 *
 *   send→202        POST /messages until the 202 lands
 *   first token     POST start → first message_delta of that run on the WS
 *   WS event lag    event.ts (worker append) → client receipt, every event
 *   burst           every user sends inside one `windowMs` (default 1 s)
 *
 * Memory is bounded (fixed histograms, a per-user in-flight map) so the
 * harness itself never becomes the unbounded thing in a 15-min soak, and a
 * profile is split across several shard processes (capacityCli) so the
 * generator's own event loop is never the bottleneck — its loop delay is
 * reported alongside the numbers.
 */

export interface CapacityProfile {
  /** Users in THIS shard (the CLI splits the total). */
  users: number;
  /** Connect phase length; users are spread evenly across it. */
  rampMs: number;
  /** Quiet period after the ramp before samples count. */
  settleMs: number;
  /** Steady-state measurement window. */
  measureMs: number;
  /** Per-user send interval, uniform in [min, max]. */
  sendEveryMinMs: number;
  sendEveryMaxMs: number;
  /** Fraction of sends that trigger a sandbox tool step (`[sandbox]` marker). */
  toolShare: number;
  /** Users (per shard) that also poll the Studio file API. */
  studioUsers: number;
  studioEveryMs: number;
  /** Users (per shard) that attach the live browser view. */
  browserUsers: number;
  /** Optional burst: every user sends once inside `windowMs`. */
  burst?: { atMs: number; windowMs: number } | undefined;
  /** A run with no terminal event this long after its send is a timeout. */
  runTimeoutMs: number;
}

export interface CapacityTarget {
  baseUrl: string;
  wsBase: string;
  /**
   * When set, Studio reads go straight to the worker's internal file service
   * (the gateway route is a thin proxy onto it). Staging needs this: the
   * host firewall drops container→host traffic, so the staging gateway
   * container cannot reach the host-run staging worker's file service.
   */
  workerFile?: { url: string; token: string } | undefined;
}

export interface ShardResult {
  shard: number;
  users: number;
  connected: number;
  histograms: {
    send202: SerializedHistogram;
    firstToken: SerializedHistogram;
    wsLag: SerializedHistogram;
    runTotal: SerializedHistogram;
    burstSend202: SerializedHistogram;
    burstFirstToken: SerializedHistogram;
    studio: SerializedHistogram;
    connect: SerializedHistogram;
  };
  counters: Record<string, number>;
  statuses: Record<string, number>;
  failureCodes: Record<string, number>;
  errors: string[];
  harness: { loopDelayP99Ms: number; loopDelayMaxMs: number; maxInFlightRuns: number };
}

interface InFlight {
  t0: number;
  burst: boolean;
  measured: boolean;
  firstTokenAt: number | null;
  /** Wakes the owning user's loop when the run terminates. */
  onDone: (() => void) | null;
}

const MAX_ERRORS = 50;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, Math.max(0, ms)));
}

function uniform(min: number, max: number): number {
  return min + Math.random() * Math.max(0, max - min);
}

/** Protocol evidence: a requested tool marker is not proof of execution. */
export function recordCapacityEvent(counters: Record<string, number>, type: string, payload: Record<string, unknown>): void {
  const field = ({ tool_started: "toolsStarted", tool_completed: "toolsCompleted", run_started: "runsStarted", run_merged: "runsMerged" } as Record<string, string>)[type];
  if (field !== undefined) counters[field] = (counters[field] ?? 0) + 1;
  if (type === "tool_completed" && (payload.ok === false || payload.isError === true)) counters.toolErrors = (counters.toolErrors ?? 0) + 1;
}

/** Start-to-start pacing; a slow reply may delay, but never overlaps a run. */
export function nextSendAt(startMs: number, minMs: number, maxMs: number, random = Math.random()): number {
  return startMs + minMs + random * Math.max(0, maxMs - minMs);
}

/**
 * Pure timeline math (unit-tested): where a moment sits relative to the
 * measurement window that starts after ramp + settle.
 */
export function windowOf(profile: Pick<CapacityProfile, "rampMs" | "settleMs" | "measureMs">): {
  startMs: number;
  endMs: number;
} {
  const startMs = profile.rampMs + profile.settleMs;
  return { startMs, endMs: startMs + profile.measureMs };
}

export async function runCapacityShard(opts: {
  shard: number;
  userOffset: number;
  runTag: string;
  /** Absolute epoch (ms) shared by every shard: the timeline origin. */
  epochMs: number;
  profile: CapacityProfile;
  target: CapacityTarget;
}): Promise<ShardResult> {
  const { profile, target, runTag, epochMs } = opts;
  const baseUrl = target.baseUrl.replace(/\/+$/, "");
  const wsBase = target.wsBase.replace(/\/+$/, "");
  const win = windowOf(profile);
  const measureStart = epochMs + win.startMs;
  const measureEnd = epochMs + win.endMs;
  const burstAt = profile.burst === undefined ? null : measureStart + profile.burst.atMs;

  const h = {
    send202: new LatencyHistogram(),
    firstToken: new LatencyHistogram(),
    wsLag: new LatencyHistogram(),
    runTotal: new LatencyHistogram(),
    burstSend202: new LatencyHistogram(),
    burstFirstToken: new LatencyHistogram(),
    studio: new LatencyHistogram(),
    connect: new LatencyHistogram(),
  };
  const counters: Record<string, number> = {
    sends: 0,
    sendsAccepted: 0,
    sends5xx: 0,
    sends4xx: 0,
    sendNetErrors: 0,
    runsCompleted: 0,
    runsFailed: 0,
    runsTimedOut: 0,
    eventsReceived: 0,
    eventsMeasured: 0,
    wsDisconnects: 0,
    wsReconnects: 0,
    subscribeFailures: 0,
    studioOk: 0,
    studioErrors: 0,
    browserAttachOk: 0,
    browserAttachErrors: 0,
    burstSends: 0,
    burstAccepted: 0,
    connected: 0,
    measuredSends: 0,
  };
  const statuses: Record<string, number> = {};
  const failureCodes: Record<string, number> = {};
  const errors: string[] = [];
  const bump = (map: Record<string, number>, key: string): void => {
    map[key] = (map[key] ?? 0) + 1;
  };
  const note = (msg: string): void => {
    if (errors.length < MAX_ERRORS) errors.push(msg);
  };

  const loop = monitorEventLoopDelay({ resolution: 10 });
  loop.enable();
  let maxInFlightRuns = 0;
  const inFlightAll = new Map<string, InFlight>();
  /** runId → receipt time of a delta that beat its own 202 to the client. */
  const earlyDelta = new Map<string, number>();
  let stopping = false;
  const stopSendsAt = measureEnd;

  async function api(
    uid: string,
    path: string,
    init: { method: string; body?: unknown },
  ): Promise<{ status: number; body: unknown }> {
    const res = await fetch(`${baseUrl}${path}`, {
      method: init.method,
      headers: {
        authorization: `Bearer test:${uid}`,
        ...(init.body === undefined ? {} : { "content-type": "application/json" }),
      },
      ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
    });
    const text = await res.text();
    let body: unknown = null;
    if (text !== "") {
      try {
        body = JSON.parse(text);
      } catch {
        body = text;
      }
    }
    return { status: res.status, body };
  }

  const browserLiveSessions = new Set<string>();
  function onEvent(raw: WebSocket.RawData, isBinary = false): void {
    if (isBinary) {
      counters.browserFrames = (counters.browserFrames ?? 0) + 1;
      return;
    }
    const now = Date.now();
    let msg: { op?: string; sessionId?: string; state?: { live?: boolean; screencast?: boolean }; event?: { type?: string; ts?: string; payload?: Record<string, unknown> } };
    try {
      msg = JSON.parse(raw.toString()) as typeof msg;
    } catch {
      note("unparseable frame");
      return;
    }
    if (msg.op === "browser_state") {
      counters.browserStateMessages = (counters.browserStateMessages ?? 0) + 1;
      if (msg.state?.live === true && typeof msg.sessionId === "string") {
        browserLiveSessions.add(msg.sessionId);
        counters.browserLiveUsersObserved = browserLiveSessions.size;
      }
      if (msg.state?.screencast === true) counters.browserScreencastStates = (counters.browserScreencastStates ?? 0) + 1;
      return;
    }
    if (msg.op !== "event" || msg.event === undefined) return;
    const ev = msg.event;
    recordCapacityEvent(counters, ev.type ?? "", ev.payload ?? {});
    counters.eventsReceived! += 1;
    if (now >= measureStart && now < measureEnd && typeof ev.ts === "string") {
      h.wsLag.record(now - Date.parse(ev.ts));
      counters.eventsMeasured! += 1;
    }
    const runId = ev.payload?.runId;
    if (typeof runId !== "string") return;
    const run = inFlightAll.get(runId);
    if (ev.type === "message_delta") {
      if (run === undefined) {
        if (!earlyDelta.has(runId)) earlyDelta.set(runId, now);
      } else if (run.firstTokenAt === null) {
        run.firstTokenAt = now;
        if (run.measured) h.firstToken.record(now - run.t0);
        if (run.burst) h.burstFirstToken.record(now - run.t0);
      }
    } else if (ev.type === "run_completed" || ev.type === "run_failed") {
      earlyDelta.delete(runId);
      if (run === undefined) return;
      inFlightAll.delete(runId);
      run.onDone?.();
      if (ev.type === "run_completed") {
        counters.runsCompleted! += 1;
        if (run.measured) h.runTotal.record(now - run.t0);
      } else {
        counters.runsFailed! += 1;
        const code = ev.payload?.code;
        bump(failureCodes, typeof code === "string" ? code : "unknown");
      }
    }
  }

  async function connectWs(uid: string, sessionId: string): Promise<WebSocket> {
    const ticketRes = await api(uid, "/cloud/v1/auth/ticket", { method: "POST", body: {} });
    const ticket = (ticketRes.body as { ticket?: unknown } | null)?.ticket;
    if (ticketRes.status !== 200 || typeof ticket !== "string") {
      throw new Error(`ticket HTTP ${ticketRes.status}`);
    }
    const ws = new WebSocket(`${wsBase}?ticket=${encodeURIComponent(ticket)}`, {
      perMessageDeflate: false,
    });
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("subscribe ack timeout")), 15_000);
      ws.once("open", () => {
        ws.send(JSON.stringify({ op: "subscribe", sessionId, lastEventId: null }));
      });
      const onAck = (data: WebSocket.RawData): void => {
        const text = data.toString();
        if (text.includes('"op":"subscribed"')) {
          clearTimeout(timer);
          ws.off("message", onAck);
          resolve();
        } else if (text.includes('"op":"error"')) {
          clearTimeout(timer);
          ws.off("message", onAck);
          reject(new Error(`subscribe error ${text.slice(0, 160)}`));
        }
      };
      ws.on("message", onAck);
      ws.once("error", (err) => {
        clearTimeout(timer);
        reject(err);
      });
    });
    ws.on("message", onEvent);
    return ws;
  }

  /** Returns the accepted run (null when the send failed). */
  async function sendOne(uid: string, sessionId: string, burst: boolean): Promise<InFlight | null> {
    const t0 = Date.now();
    const measured = !burst && t0 >= measureStart && t0 < measureEnd;
    const sandbox = Math.random() < profile.toolShare;
    counters.sends! += 1;
    if (burst) counters.burstSends! += 1;
    if (measured) counters.measuredSends! += 1;
    let res: { status: number; body: unknown };
    try {
      res = await api(uid, `/cloud/v1/sessions/${sessionId}/messages`, {
        method: "POST",
        body: { content: `${sandbox ? "[sandbox] " : ""}${runTag} hello ${t0}` },
      });
    } catch (err) {
      counters.sendNetErrors! += 1;
      note(`send net error: ${err instanceof Error ? err.message : String(err)}`);
      return null;
    }
    const dt = Date.now() - t0;
    bump(statuses, String(res.status));
    if (res.status !== 202) {
      if (res.status >= 500) counters.sends5xx! += 1;
      else counters.sends4xx! += 1;
      note(`send HTTP ${res.status} ${JSON.stringify(res.body).slice(0, 160)}`);
      return null;
    }
    counters.sendsAccepted! += 1;
    if (burst) counters.burstAccepted! += 1;
    if (measured) h.send202.record(dt);
    if (burst) h.burstSend202.record(dt);
    const runId = (res.body as { runId?: unknown } | null)?.runId;
    if (typeof runId !== "string") return null;
    const run: InFlight = { t0, burst, measured, firstTokenAt: null, onDone: null };
    const early = earlyDelta.get(runId);
    if (early !== undefined) {
      earlyDelta.delete(runId);
      run.firstTokenAt = early;
      if (measured) h.firstToken.record(early - t0);
      if (burst) h.burstFirstToken.record(early - t0);
    }
    inFlightAll.set(runId, run);
    runKeys.set(run, runId);
    maxInFlightRuns = Math.max(maxInFlightRuns, inFlightAll.size);
    return run;
  }

  /**
   * A real user reads the reply before typing the next message. A message
   * sent while the user's previous run still streams is folded into that run
   * as steering (no run of its own), which would make it unmeasurable — so
   * each user waits for its previous run (bounded by runTimeoutMs).
   */
  async function awaitRun(run: InFlight | null): Promise<void> {
    if (run === null || !inFlightAll.has(runKeyOf(run))) return;
    await new Promise<void>((resolve) => {
      const timer = setTimeout(resolve, profile.runTimeoutMs);
      run.onDone = () => {
        clearTimeout(timer);
        resolve();
      };
    });
  }
  const runKeys = new WeakMap<InFlight, string>();
  const runKeyOf = (run: InFlight): string => runKeys.get(run) ?? "";

  async function studioCall(
    uid: string,
    sessionId: string,
    method: "GET" | "PUT",
    suffix: string,
    body?: unknown,
  ): Promise<number> {
    const wf = target.workerFile;
    if (wf === undefined) {
      const res = await api(uid, `/cloud/v1/sessions/${sessionId}/workspace${suffix}`, {
        method,
        ...(body === undefined ? {} : { body }),
      });
      return res.status;
    }
    const res = await fetch(
      `${wf.url.replace(/\/+$/, "")}/internal/sessions/${sessionId}${suffix}`,
      {
        method,
        headers: {
          "x-ovid-internal-token": wf.token,
          "x-ovid-user-id": uid,
          ...(body === undefined ? {} : { "content-type": "application/json" }),
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      },
    );
    await res.arrayBuffer();
    return res.status;
  }

  async function studioLoop(uid: string, sessionId: string): Promise<void> {
    // One small file, written once, then read back (tree + file) on a cadence.
    const content = `# ${runTag}\n${"lorem ipsum ".repeat(200)}`;
    try {
      if (target.workerFile === undefined) {
        await studioCall(uid, sessionId, "PUT", "/file", { path: "notes.md", contentUtf8: content });
      } else {
        await studioCall(uid, sessionId, "PUT", "/file?path=notes.md", {
          contentBase64: Buffer.from(content).toString("base64"),
        });
      }
    } catch {
      // counted on read
    }
    await sleep(uniform(0, profile.studioEveryMs));
    while (!stopping && Date.now() < stopSendsAt) {
      const t0 = Date.now();
      try {
        const tree = await studioCall(uid, sessionId, "GET", "/tree");
        const file = await studioCall(uid, sessionId, "GET", "/file?path=notes.md");
        if (tree === 200 && file === 200) counters.studioOk! += 1;
        else {
          counters.studioErrors! += 1;
          bump(statuses, `studio_${tree}_${file}`);
        }
        if (t0 >= measureStart && t0 < measureEnd) h.studio.record(Date.now() - t0);
      } catch (err) {
        counters.studioErrors! += 1;
        note(`studio error: ${err instanceof Error ? err.message : String(err)}`);
      }
      await sleep(profile.studioEveryMs);
    }
  }

  const sockets: WebSocket[] = [];

  async function runUser(i: number): Promise<void> {
    const uid = `${runTag}-u${opts.userOffset + i}`;
    const c0 = Date.now();
    const created = await api(uid, "/cloud/v1/sessions", { method: "POST", body: {} });
    if (created.status !== 201) throw new Error(`createSession HTTP ${created.status}`);
    const sessionId = (created.body as { id: string }).id;
    let ws: WebSocket;
    try {
      ws = await connectWs(uid, sessionId);
    } catch (err) {
      counters.subscribeFailures! += 1;
      throw err;
    }
    h.connect.record(Date.now() - c0);
    counters.connected! += 1;
    sockets.push(ws);

    const watch = (socket: WebSocket): void => {
      socket.once("close", () => {
        if (stopping) return;
        counters.wsDisconnects! += 1;
        void (async () => {
          await sleep(1_000);
          if (stopping) return;
          try {
            const next = await connectWs(uid, sessionId);
            counters.wsReconnects! += 1;
            sockets.push(next);
            watch(next);
          } catch (err) {
            counters.subscribeFailures! += 1;
            note(`reconnect failed: ${err instanceof Error ? err.message : String(err)}`);
          }
        })();
      });
    };
    watch(ws);

    if (i < profile.browserUsers) {
      const errorsBefore = counters.browserAttachErrors!;
      const onErr = (data: WebSocket.RawData): void => {
        const text = data.toString();
        if (text.includes('"op":"error"')) counters.browserAttachErrors! += 1;
      };
      ws.on("message", onErr);
      ws.send(JSON.stringify({ op: "browser_attach", sessionId }));
      await sleep(500);
      ws.off("message", onErr);
      if (counters.browserAttachErrors === errorsBefore) counters.browserAttachOk! += 1;
    }

    // Warm-up send (provisions the user's key, first sandbox attach) — not
    // measured; the user waits for its reply like any other.
    let lastSendStart = Date.now();
    let last = await sendOne(uid, sessionId, false);
    await awaitRun(last);
    // Studio users start after the warm-up run: the workspace is warm now
    // (the file service refuses writes to a cold workspace with not_warm).
    if (i < profile.studioUsers) void studioLoop(uid, sessionId);
    const quietMs = 15_000;
    const burstMine =
      burstAt === null ? Number.POSITIVE_INFINITY : burstAt + uniform(0, profile.burst!.windowMs);
    let burstDone = burstAt === null;
    const nextRegular = (): number => {
      let at = nextSendAt(lastSendStart, profile.sendEveryMinMs, profile.sendEveryMaxMs);
      // Keep the burst clean: no regular send in the 15 s before it, so (almost)
      // every burst send gets its own run instead of steering a live one.
      if (!burstDone && at >= burstMine - quietMs) at = Number.POSITIVE_INFINITY;
      return at;
    };
    // Starts are paced from the previous start, NOT from completion; if a
    // reply outlasts the interval it defers just that user's next send.
    let next = nextRegular();
    while (Date.now() < stopSendsAt) {
      const wake = Math.min(next, burstDone ? Number.POSITIVE_INFINITY : burstMine, stopSendsAt);
      await sleep(wake - Date.now());
      const now = Date.now();
      if (now >= stopSendsAt) break;
      lastSendStart = now;
      if (!burstDone && now >= burstMine) {
        burstDone = true;
        last = await sendOne(uid, sessionId, true);
      } else if (now >= next) {
        last = await sendOne(uid, sessionId, false);
      } else {
        continue;
      }
      await awaitRun(last);
      next = nextRegular();
    }
  }

  const tasks: Promise<void>[] = [];
  for (let i = 0; i < profile.users; i += 1) {
    const at = epochMs + Math.floor((i * profile.rampMs) / Math.max(1, profile.users));
    tasks.push(
      sleep(at - Date.now()).then(() =>
        runUser(i).catch((err: unknown) => {
          note(`user ${i} failed: ${err instanceof Error ? err.message : String(err)}`);
        }),
      ),
    );
  }
  await Promise.all(tasks);

  // Drain: in-flight runs get runTimeoutMs to finish.
  const drainUntil = Date.now() + profile.runTimeoutMs;
  while (inFlightAll.size > 0 && Date.now() < drainUntil) await sleep(250);
  counters.runsTimedOut = inFlightAll.size;
  stopping = true;
  for (const socket of sockets) socket.terminate();
  loop.disable();

  return {
    shard: opts.shard,
    users: profile.users,
    connected: counters.connected!,
    histograms: {
      send202: h.send202.serialize(),
      firstToken: h.firstToken.serialize(),
      wsLag: h.wsLag.serialize(),
      runTotal: h.runTotal.serialize(),
      burstSend202: h.burstSend202.serialize(),
      burstFirstToken: h.burstFirstToken.serialize(),
      studio: h.studio.serialize(),
      connect: h.connect.serialize(),
    },
    counters,
    statuses,
    failureCodes,
    errors,
    harness: {
      loopDelayP99Ms: Math.round(loop.percentile(99) / 1e6),
      loopDelayMaxMs: Math.round(loop.max / 1e6),
      maxInFlightRuns,
    },
  };
}
