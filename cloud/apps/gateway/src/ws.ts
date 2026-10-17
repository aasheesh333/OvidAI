import { randomUUID } from "node:crypto";
import type { RawData, WebSocket } from "ws";
import { sessions, type Db } from "@ovid/db";
import type { EventLog } from "@ovid/events";
import { wsClientMsg, type PtyOutMsg, type SessionEvent, type WsClientMsg, type WsServerMsg } from "@ovid/shared";
import { isUuid } from "./routes/http.js";
import type { TicketStore } from "./tickets.js";
import { PTY_OPEN_TIMEOUT_MS, PTY_REPLY_TIMEOUT_MS, PtyBridgeError, type PtyBridge } from "./wsPty.js";

/**
 * The thin client's live event channel: one multiplexed WS connection carries
 * subscriptions to many sessions. Auth is the single-use ticket in the query
 * string (Task 6) — there is deliberately NO authHook on this route.
 *
 * Review Focus #1 (reconnect replay/live race) is closed by the per-
 * subscription ordering below: events.subscribe() attaches the live listener
 * BEFORE readSince() runs, live events arriving during the replay read are
 * buffered, and the flush (subscribed → replay → buffer → pass-through) is
 * fully synchronous, deduping by stream-id seq. Nothing can be lost between
 * the two reads and nothing can be delivered twice.
 *
 * Task 13 adds the terminal ops (pty_*): pty_open/attach wire a PtyBridge
 * session into this connection's ptySubs; every frame a bridge produces is
 * forwarded as pty_output/pty_exit. Ownership discipline: pty_open goes
 * through sessions.get; pty_attach and control ops from connections that did
 * not open/attach the pty go through the bridge's registry lookup. PTYS
 * SURVIVE socket close — 'close' only DETACHES the output subscriptions (an
 * explicit pty_close or a worker shutdown kills them).
 */

export interface WsDeps {
  tickets: TicketStore;
  events: EventLog;
  db: Db;
  /** Terminal-over-WS bridge (Task 13); main wires createRedisPtyBridge(redisQ). */
  pty: PtyBridge;
}

export interface WsConnectionOptions {
  /** Server-side protocol ping interval (default 30 s). Injectable for tests. */
  pingIntervalMs?: number;
}

/** App-private close code (4000–4999 range) for a failed ticket handshake. */
export const WS_CLOSE_UNAUTHENTICATED = 4401;

/** Cap on events replayed to a client per subscribe (contract with the thin client). */
export const REPLAY_LIMIT = 500;

/**
 * I3: cap on concurrent subscriptions per WS connection. Every subscription
 * holds a dedicated redis pub/sub connection (Task 4 duplicates the client),
 * so an unbounded per-connection multiplex is a server-resource DoS vector.
 * A re-subscribe to an ALREADY-subscribed session replaces (no net growth)
 * and is never refused; the cap applies to the 65th DISTINCT session.
 */
export const MAX_SUBSCRIPTIONS_PER_CONNECTION = 64;

const DEFAULT_PING_INTERVAL_MS = 30_000;
/** Close the socket once this many consecutive protocol pings went unanswered. */
const MAX_UNANSWERED_PINGS = 2;
/** Frames buffered while the ticket verify is in flight (unauthenticated memory cap). */
const PRE_AUTH_QUEUE_MAX = 32;

/**
 * Redis stream ids are "ms-i". Compare NUMERICALLY on both parts — a
 * lexicographic compare breaks the moment the millisecond part changes width
 * ("100-0" < "99-0" as strings, wrong as ids). Missing parts count as 0.
 */
export function compareSeq(a: string, b: string): number {
  const [aMs = 0, aIdx = 0] = a.split("-").map(Number);
  const [bMs = 0, bIdx = 0] = b.split("-").map(Number);
  if (aMs !== bMs) return aMs < bMs ? -1 : 1;
  if (aIdx !== bIdx) return aIdx < bIdx ? -1 : 1;
  return 0;
}

/** ws delivers Buffer | ArrayBuffer | Buffer[]; every frame here is UTF-8 JSON text. */
function rawToString(data: RawData): string {
  if (Array.isArray(data)) return Buffer.concat(data).toString("utf8");
  if (data instanceof ArrayBuffer) return Buffer.from(data).toString("utf8");
  return data.toString("utf8");
}

function send(socket: WebSocket, msg: WsServerMsg): void {
  // readyState guard: frames produced after close/terminate (e.g. a replay
  // that was still in flight) are dropped instead of erroring the socket.
  if (socket.readyState !== socket.OPEN) return;
  socket.send(JSON.stringify(msg));
}

interface Subscription {
  /** Task 4's EventLog unsubscribe — quits the dedicated redis pub/sub connection. */
  unsubscribe: () => Promise<void>;
  /** True while the replay read is in flight: live events queue instead of sending. */
  buffering: boolean;
  buffered: SessionEvent[];
  /** Highest seq already sent for this subscription — the dedupe baseline. */
  lastSentSeq: string | null;
}

/**
 * One terminal attached on this connection. `detach` only quits the bridge's
 * pty:out subscription — the PTY ITSELF SURVIVES (reconnect re-attaches; only
 * explicit pty_close or a worker shutdown kills it).
 */
interface PtyEntry {
  detach(): Promise<void>;
}

export async function handleWsConnection(
  socket: WebSocket,
  url: URL,
  deps: WsDeps,
  opts: WsConnectionOptions = {},
): Promise<void> {
  // ws emits 'error' before 'close' on abnormal teardown; an EventEmitter
  // 'error' with no listener throws. Teardown happens in the 'close' handler.
  socket.on("error", () => {});

  // ---- Teardown bookkeeping — registered BEFORE any await ----
  // 'close' is never replayed to a late listener: if the peer drops during
  // the (async) ticket verify below, a listener attached afterwards would
  // never fire, `closed` would stay false, and the pre-auth drain would build
  // subscriptions (each holding a dedicated redis pub/sub connection) that
  // nothing can ever reclaim. Registering first closes that window; the
  // readyState re-check after verify backs it up (everything from there to
  // the drain is synchronous, so no new window opens).
  const subs = new Map<string, Subscription>();
  const ptySubs = new Map<string, PtyEntry>();
  let closed = false;
  let heartbeat: ReturnType<typeof setInterval> | null = null;

  const teardownAll = async (): Promise<void> => {
    if (heartbeat !== null) clearInterval(heartbeat);
    const all = [...subs.values()];
    subs.clear();
    const ptyAll = [...ptySubs.values()];
    ptySubs.clear();
    // EVERY subscription must be torn down: each holds a dedicated redis
    // pub/sub connection (Task 4 duplicates the client), so a leak here is a
    // leaked connection per session per reconnect.
    await Promise.all(all.map((sub) => sub.unsubscribe().catch(() => {})));
    // Terminal subs DETACH ONLY (ptys survive — never an implicit pty_close;
    // the reconnect's pty_attach picks the same pty back up).
    await Promise.all(ptyAll.map((p) => p.detach().catch(() => {})));
  };
  socket.on("close", () => {
    closed = true;
    void teardownAll();
  });

  // ---- Ticket handshake (single-use; the ticket IS the auth) ----
  // Frames can arrive while the async verify is in flight: queue them and
  // drain after auth succeeds; on rejection they die with the socket. The
  // queue is capped — an UNauthenticated socket must not be able to grow
  // server memory by streaming frames at it (beyond the cap they're dropped;
  // a well-behaved client pipelines at most a handful of subscribes).
  const preAuth: string[] = [];
  let ingest: ((raw: string) => void) | null = null;
  socket.on("message", (data: RawData) => {
    const raw = rawToString(data);
    if (ingest === null) {
      if (preAuth.length < PRE_AUTH_QUEUE_MAX) preAuth.push(raw);
      return;
    }
    ingest(raw);
  });

  const verified = await verifyTicket(deps.tickets, url.searchParams.get("ticket"));
  if (verified === null) {
    send(socket, {
      op: "error",
      code: "unauthenticated",
      message: "Missing or invalid ticket.",
    });
    socket.close(WS_CLOSE_UNAUTHENTICATED, "unauthenticated");
    return;
  }
  const uid: string = verified.uid;

  // The peer may have dropped while verify was in flight — 'close' already
  // ran teardown above. Setting anything up now (or draining queued frames)
  // would do db/redis work for a dead socket and leak whatever it created.
  if (closed || socket.readyState !== socket.OPEN) return;

  // ---- Heartbeat: protocol-level ping every 30 s, close after 2 misses ----
  let unansweredPings = 0;
  socket.on("pong", () => {
    unansweredPings = 0;
  });
  heartbeat = setInterval(() => {
    if (unansweredPings >= MAX_UNANSWERED_PINGS) {
      // Two pings went unanswered: the peer is dead, don't wait for a close
      // frame that will never come.
      if (heartbeat !== null) clearInterval(heartbeat);
      socket.terminate();
      return;
    }
    unansweredPings += 1;
    socket.ping();
  }, opts.pingIntervalMs ?? DEFAULT_PING_INTERVAL_MS);
  heartbeat.unref?.(); // never hold the process (or a test runner) open by itself

  /** Dedupe + emit one event for a subscription (replay, buffered, and live paths). */
  function sendEvent(sub: Subscription, event: SessionEvent): void {
    // Drop anything at or below the highest seq already sent — this is what
    // makes the replay/live overlap exactly-once (Review Focus #1).
    if (sub.lastSentSeq !== null && compareSeq(event.seq, sub.lastSentSeq) <= 0) return;
    sub.lastSentSeq = event.seq;
    send(socket, { op: "event", event });
  }

  async function handleSubscribe(sessionId: string, lastEventId: string | null): Promise<void> {
    // Ownership FIRST, before any redis work. sessions.get is ownership-
    // scoped: null on unknown id AND wrong owner (no existence leaks). The
    // connection stays open and other subscriptions are untouched. The uuid
    // shape guard keeps client garbage away from the id column entirely.
    const owned = isUuid(sessionId) ? await sessions.get(deps.db, sessionId, uid) : null;
    if (owned === null) {
      send(socket, {
        op: "error",
        code: "forbidden",
        message: "Session not found.",
        sessionId,
      });
      return;
    }

    // Per-connection subscription cap (I3) BEFORE any redis work: a client
    // must not be able to open an unbounded fan of pub/sub connections. A
    // re-subscribe (previous exists) replaces in place and bypasses the cap.
    const previous = subs.get(sessionId);
    if (previous === undefined && subs.size >= MAX_SUBSCRIPTIONS_PER_CONNECTION) {
      send(socket, {
        op: "error",
        code: "too_many_subscriptions",
        message: "Subscription limit reached for this connection.",
        sessionId,
      });
      return;
    }

    // A re-subscribe replaces the existing subscription; the old one is torn
    // down first so its redis listener can never leak.
    if (previous !== undefined) {
      subs.delete(sessionId);
      await previous.unsubscribe().catch(() => {});
    }

    const sub: Subscription = {
      unsubscribe: async () => {}, // placeholder until events.subscribe resolves
      buffering: true,
      buffered: [],
      lastSentSeq: lastEventId,
    };
    subs.set(sessionId, sub);

    // subscribe BEFORE replay: the listener is attached before XRANGE runs,
    // so an event appended in between is buffered here instead of lost.
    let unsubscribe: () => Promise<void>;
    try {
      unsubscribe = await deps.events.subscribe(sessionId, (event) => {
        if (subs.get(sessionId) !== sub) return; // replaced or torn down: ignore
        if (sub.buffering) sub.buffered.push(event);
        else sendEvent(sub, event);
      });
    } catch {
      if (subs.get(sessionId) === sub) subs.delete(sessionId);
      send(socket, {
        op: "error",
        code: "internal",
        message: "Live subscription failed.",
        sessionId,
      });
      return;
    }
    if (closed || subs.get(sessionId) !== sub) {
      // Socket died (or subscription was replaced) mid-setup: don't leak the
      // freshly created redis listener.
      await unsubscribe().catch(() => {});
      return;
    }
    sub.unsubscribe = unsubscribe;

    let replay: SessionEvent[];
    try {
      replay = await deps.events.readSince(sessionId, lastEventId, REPLAY_LIMIT);
    } catch {
      if (subs.get(sessionId) === sub) subs.delete(sessionId);
      await unsubscribe().catch(() => {});
      send(socket, {
        op: "error",
        code: "internal",
        message: "Replay failed.",
        sessionId,
      });
      return;
    }
    if (closed || subs.get(sessionId) !== sub) {
      await unsubscribe().catch(() => {});
      return;
    }

    // Synchronous flush — no awaits from here to `buffering = false`, so a
    // live callback can never interleave mid-flush (JS is single-threaded and
    // ws.send preserves call order). Contract: the `subscribed` ack arrives
    // BEFORE the replayed events.
    send(socket, { op: "subscribed", sessionId });
    for (const event of replay) sendEvent(sub, event);
    sub.buffering = false;
    for (const event of sub.buffered.splice(0)) sendEvent(sub, event);
    // From here on, the subscribe callback above is the pass-through path.
  }

  async function handleUnsubscribe(sessionId: string): Promise<void> {
    const sub = subs.get(sessionId);
    if (sub === undefined) return; // idempotent: unknown session is a no-op
    subs.delete(sessionId);
    await sub.unsubscribe().catch(() => {});
  }

  // ---- Terminal ops (Task 13) ----------------------------------------------

  /** PtyBridgeError → error frame with the code; the connection SURVIVES. */
  function ptyError(err: unknown, ptyId: string): void {
    if (err instanceof PtyBridgeError) {
      send(socket, { op: "error", code: err.code, message: err.message, ptyId });
      return;
    }
    send(socket, { op: "error", code: "internal", message: "Internal error.", ptyId });
  }

  /**
   * Drops a terminal sub (pty_exit seen, or replaced): stops forwarding and
   * detaches the bridge's pty:out subscription. The pty itself is untouched.
   */
  function dropPty(ptyId: string, entry: PtyEntry): void {
    if (ptySubs.get(ptyId) !== entry) return; // already dropped or replaced
    ptySubs.delete(ptyId);
    void entry.detach().catch(() => {});
  }

  /** The bridge's live stream for one attached pty, forwarded as ws frames. */
  function forwardPty(ptyId: string, entry: PtyEntry): (m: PtyOutMsg) => void {
    return (m) => {
      if (ptySubs.get(ptyId) !== entry) return; // dropped or replaced: ignore
      if (m.type === "output") {
        send(socket, { op: "pty_output", ptyId, data: m.data, offset: m.offset });
        return;
      }
      send(socket, { op: "pty_exit", ptyId, exitCode: m.exitCode });
      dropPty(ptyId, entry); // the sub dies with the pty; the registry is gone
    };
  }

  /**
   * Registers `entry`, awaits the bridge attach, and on success arms the real
   * detach + sends the ack + snapshot frames. On any failure the entry is
   * removed and an error frame goes out — the connection survives.
   */
  async function armPty(
    entry: PtyEntry,
    ptyId: string,
    attach: () => Promise<{ truncated: boolean; endOffset: number; detach(): Promise<void>; chunks: { offset: number; data: string }[] }>,
    ack: (res: { truncated: boolean }) => void,
  ): Promise<void> {
    ptySubs.set(ptyId, entry); // pre-registered: the bridge's first live frames find it
    let res;
    try {
      res = await attach();
    } catch (err) {
      if (ptySubs.get(ptyId) === entry) ptySubs.delete(ptyId);
      ptyError(err, ptyId);
      return;
    }
    if (closed || ptySubs.get(ptyId) !== entry) {
      // Socket died (or the sub was replaced) mid-setup: don't leak the
      // bridge's freshly created pty:out subscription.
      await res.detach().catch(() => {});
      return;
    }
    entry.detach = res.detach;
    ack(res);
    // Snapshot chunks go out as pty_output frames in snapshot order; the
    // bridge delivers its buffered live tail only after this continuation.
    for (const c of res.chunks) {
      send(socket, { op: "pty_output", ptyId, data: c.data, offset: c.offset });
    }
  }

  async function handlePtyOpen(msg: Extract<WsClientMsg, { op: "pty_open" }>): Promise<void> {
    // Ownership FIRST, before any bridge work — sessions.get is ownership-
    // scoped (null on unknown id AND wrong owner; the uuid shape guard keeps
    // client garbage away from the id column).
    const owned = isUuid(msg.sessionId) ? await sessions.get(deps.db, msg.sessionId, uid) : null;
    if (owned === null) {
      send(socket, {
        op: "error",
        code: "forbidden",
        message: "Session not found.",
        sessionId: msg.sessionId,
      });
      return;
    }
    const ptyId = randomUUID();
    const entry: PtyEntry = { detach: async () => {} };
    try {
      await deps.pty.open(
        ptyId,
        { userId: uid, sessionId: msg.sessionId, cols: msg.cols, rows: msg.rows },
        PTY_OPEN_TIMEOUT_MS,
      );
    } catch (err) {
      ptyError(err, ptyId);
      return;
    }
    await armPty(
      entry,
      ptyId,
      () => deps.pty.attach(ptyId, null, forwardPty(ptyId, entry), PTY_REPLY_TIMEOUT_MS),
      () => send(socket, { op: "pty_opened", ptyId, sessionId: msg.sessionId }),
    );
  }

  async function handlePtyAttach(msg: Extract<WsClientMsg, { op: "pty_attach" }>): Promise<void> {
    // Registry ownership: userId must match this connection's principal.
    const meta = await deps.pty.lookup(msg.ptyId);
    if (meta === null || meta.userId !== uid) {
      send(socket, {
        op: "error",
        code: "forbidden",
        message: "Terminal not found.",
        ptyId: msg.ptyId,
      });
      return;
    }
    const entry: PtyEntry = { detach: async () => {} };
    await armPty(
      entry,
      msg.ptyId,
      () =>
        deps.pty.attach(
          msg.ptyId,
          msg.lastOffset ?? null,
          forwardPty(msg.ptyId, entry),
          PTY_REPLY_TIMEOUT_MS,
        ),
      (res) => send(socket, { op: "pty_attached", ptyId: msg.ptyId, truncated: res.truncated }),
    );
  }

  async function handlePtyCtl(
    ptyId: string,
    msg:
      | { type: "input"; data: string }
      | { type: "resize"; cols: number; rows: number }
      | { type: "close" },
  ): Promise<void> {
    // Allowed without a lookup when THIS connection opened/attached the pty…
    if (!ptySubs.has(ptyId)) {
      // …else the registry ownership check decides.
      const meta = await deps.pty.lookup(ptyId);
      if (meta === null || meta.userId !== uid) {
        send(socket, {
          op: "error",
          code: "forbidden",
          message: "Terminal not found.",
          ptyId,
        });
        return;
      }
    }
    try {
      await deps.pty.send(ptyId, msg);
    } catch (err) {
      ptyError(err, ptyId);
    }
  }

  async function processFrame(raw: string): Promise<void> {
    // Defense in depth for the chained-queue path: a frame that was still
    // waiting its turn when the socket died must not start db/redis work.
    if (closed) return;
    let msg;
    try {
      // Unparseable JSON and off-contract shapes are the same client error.
      msg = wsClientMsg(JSON.parse(raw));
    } catch {
      send(socket, {
        op: "error",
        code: "bad_message",
        message: "Frame is not a valid client message.",
      });
      return; // connection survives
    }
    switch (msg.op) {
      case "ping":
        send(socket, { op: "pong" });
        return;
      case "subscribe":
        await handleSubscribe(msg.sessionId, msg.lastEventId ?? null);
        return;
      case "unsubscribe":
        await handleUnsubscribe(msg.sessionId);
        return;
      case "pty_open":
        await handlePtyOpen(msg);
        return;
      case "pty_attach":
        await handlePtyAttach(msg);
        return;
      case "pty_input":
        await handlePtyCtl(msg.ptyId, { type: "input", data: msg.data });
        return;
      case "pty_resize":
        await handlePtyCtl(msg.ptyId, { type: "resize", cols: msg.cols, rows: msg.rows });
        return;
      case "pty_close":
        await handlePtyCtl(msg.ptyId, { type: "close" });
        return;
    }
  }

  // Frames are processed strictly in arrival order: each chained after the
  // previous, so two subscribes can never interleave their flushes.
  let chain: Promise<void> = Promise.resolve();
  ingest = (raw: string) => {
    chain = chain.then(async () => {
      try {
        await processFrame(raw);
      } catch {
        // Unexpected failure (e.g. db outage during the ownership check):
        // report generically, keep the connection.
        send(socket, { op: "error", code: "internal", message: "Internal error." });
      }
    });
  };
  for (const raw of preAuth.splice(0)) ingest(raw);
}

async function verifyTicket(
  tickets: TicketStore,
  ticket: string | null,
): Promise<{ uid: string } | null> {
  if (ticket === null) return null;
  try {
    return await tickets.verify(ticket);
  } catch {
    // Ticket-store outage: identity cannot be proven → reject like an invalid
    // ticket (the client re-mints and retries).
    return null;
  }
}
