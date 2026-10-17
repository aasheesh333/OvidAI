import { randomUUID } from "node:crypto";
import type { RawData, WebSocket } from "ws";
import type { Redis } from "ioredis";
import { sessions, type Db } from "@ovid/db";
import type { EventLog } from "@ovid/events";
import {
  APPROVAL_RESPONSES_CHANNEL,
  wsClientMsg,
  type PtyOutMsg,
  type SessionEvent,
  type WsClientMsg,
  type WsServerMsg,
} from "@ovid/shared";
import { isUuid } from "./routes/http.js";
import type { TicketStore } from "./tickets.js";
import {
  BROWSER_FRAME_HIGH_WATER,
  BROWSER_VIEWER_HEARTBEAT_MS,
  createBrowserAttach,
  type BrowserAttach,
  type BrowserChannelDeps,
} from "./browserChannel.js";
import { PTY_OPEN_TIMEOUT_MS, PTY_REPLY_TIMEOUT_MS, PtyBridgeError, type PtyBridge } from "./wsPty.js";
import type { SystemHub } from "./systemChannel.js";

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
 *
 * Task 9 adds the browser viewer ops (browser_*): one attach per socket
 * holds TWO dedicated redis connections (a ctl/input publisher + a frames/
 * state subscriber — a subscriber-mode connection cannot publish) and is
 * torn down on detach, replace, and socket close. Frames reach the client
 * as BINARY ws messages (image bytes only); state as browser_state ops.
 *
 * P3 Task 12 adds the approval op (approval_response): the client answers
 * an approval_requested session event on the SAME multiplexed connection.
 * Ownership is validated exactly like subscribe (sessions.get), then the
 * response is published to the approval-responses redis channel for the
 * worker's approval bridge and acked (approval_ack). The ack confirms
 * PUBLICATION only — whether a pending approval was still waiting is the
 * worker bridge's concern (a late answer after its timeout is a no-op
 * there, by contract).
 *
 * P5 Task 10 adds the system channel: after the ticket verify the
 * connection attaches its uid to deps.systemHub (ONE shared sys:{uid}:out
 * subscription per uid across that uid's sockets — events fan out to every
 * attached socket as system_event frames). A client's system_response frame
 * is forwarded to sys:{uid}:in for the worker's pending request; there is
 * deliberately no ack frame (the request resolving IS the confirmation).
 * The hub is OPTIONAL: a composition without it never attaches and answers
 * system_response with `bad_message` (the frame could only be meaningful
 * after an attach this composition never made).
 */

/**
 * The gateway's side of the approval responses channel: publish one
 * {approvalId, userId, decision} for the worker's bridge to resolve.
 */
export interface ApprovalPublisher {
  publishResponse(response: { approvalId: string; userId: string; decision: string }): Promise<void>;
}

/** Redis-backed ApprovalPublisher (main wires it with the queue redisQ client). */
export function createRedisApprovalPublisher(redis: Redis): ApprovalPublisher {
  return {
    async publishResponse(response) {
      await redis.publish(APPROVAL_RESPONSES_CHANNEL, JSON.stringify(response));
    },
  };
}

export interface WsDeps {
  tickets: TicketStore;
  events: EventLog;
  db: Db;
  /** Terminal-over-WS bridge (Task 13); main wires createRedisPtyBridge(redisQ). */
  pty: PtyBridge;
  /**
   * Browser viewer channel (Task 9); main wires
   * `{ redisFactory: () => new Redis(cfg.redisQUrl) }`. OPTIONAL so pre-P6
   * compositions stay source-compatible: when absent, every browser_* frame
   * answers a loud `unavailable` error frame instead of crashing.
   */
  browser?: BrowserChannelDeps;
  /**
   * Approval response publisher (P3 Task 12); main wires
   * createRedisApprovalPublisher(redisQ). OPTIONAL so pre-P3 compositions
   * stay source-compatible: when absent, approval_response answers a loud
   * `unavailable` error frame instead of crashing (the same fallback
   * discipline as browser above).
   */
  approvals?: ApprovalPublisher;
  /**
   * System channel hub (P5 Task 10); main wires createSystemHub(redisQ).
   * OPTIONAL so pre-P5 compositions (spine e2e + P1 suites) stay
   * source-compatible: when absent, the connection never attaches and an
   * incoming system_response answers a `bad_message` error frame instead
   * of crashing (R5: this is THE canonical field name — Task 15 consumes
   * the SAME field; no second alias).
   */
  systemHub?: SystemHub;
}

export interface WsConnectionOptions {
  /** Server-side protocol ping interval (default 30 s). Injectable for tests. */
  pingIntervalMs?: number;
  /** Test seam: overrides BROWSER_VIEWER_HEARTBEAT_MS for the join heartbeat. */
  browserHeartbeatMs?: number;
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
  // ONE browser attach per socket (Task 9): holds the dedicated redis
  // publisher + subscriber; torn down on detach, replace, and socket close.
  let browserAttach: BrowserAttach | null = null;
  // System channel detach (P5 Task 10): declared HERE (same teardown
  // bookkeeping block as session subs) but only SET after the ticket verify
  // proves the uid — a close that fires during the verify finds it null and
  // there is nothing to tear down (the attach itself happens after the
  // closed re-check below, synchronously, before any frame is drained).
  let detachSystem: (() => void) | null = null;
  let closed = false;
  let heartbeat: ReturnType<typeof setInterval> | null = null;

  const teardownAll = async (): Promise<void> => {
    if (heartbeat !== null) clearInterval(heartbeat);
    // Sync and first: the system attach holds a slot in the uid's SHARED
    // per-uid subscription (its release may quit a redis connection, which
    // is awaited inside the hub — no await needed here).
    detachSystem?.();
    const all = [...subs.values()];
    subs.clear();
    const ptyAll = [...ptySubs.values()];
    ptySubs.clear();
    const browser = browserAttach;
    browserAttach = null;
    // EVERY subscription must be torn down: each holds a dedicated redis
    // pub/sub connection (Task 4 duplicates the client), so a leak here is a
    // leaked connection per session per reconnect.
    await Promise.all(all.map((sub) => sub.unsubscribe().catch(() => {})));
    // Terminal subs DETACH ONLY (ptys survive — never an implicit pty_close;
    // the reconnect's pty_attach picks the same pty back up).
    await Promise.all(ptyAll.map((p) => p.detach().catch(() => {})));
    // The browser attach publishes viewer_leave and quits BOTH of its
    // dedicated connections (awaited — same reclaim discipline as above).
    if (browser !== null) await browser.detach().catch(() => {});
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

  // System channel attach (P5 Task 10): synchronous, BEFORE the heartbeat
  // setup and the pre-auth drain at the end of this function — no frame can
  // arrive between here and the drain, and the hub's shared per-uid
  // subscription is live (or opening) before the first system_response.
  detachSystem = deps.systemHub?.attach(uid, (event) => {
    send(socket, { op: "system_event", event });
  }) ?? null;

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

  // ---- Browser viewer ops (Task 9) ------------------------------------------

  /**
   * Attach precondition for input/takeover: THIS connection must hold an
   * active attach for THAT session (the attach itself proved ownership, so
   * ops never re-query the db). Missing/mismatched → `not_attached`; the
   * connection survives.
   */
  function requireBrowserAttach(sessionId: string): BrowserAttach | null {
    const attach = browserAttach;
    if (attach === null || attach.sessionId !== sessionId) {
      send(socket, {
        op: "error",
        code: "not_attached",
        message: "No active browser attach for this session.",
        sessionId,
      });
      return null;
    }
    return attach;
  }

  async function handleBrowserAttach(sessionId: string): Promise<void> {
    // Loud fallback for pre-P6 compositions (no browser deps wired).
    if (deps.browser === undefined) {
      send(socket, {
        op: "error",
        code: "unavailable",
        message: "Browser channel not configured.",
      });
      return;
    }
    // Ownership FIRST, before any redis work — sessions.get is ownership-
    // scoped (null on unknown id AND wrong owner; the uuid shape guard keeps
    // client garbage away from the id column).
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

    // ONE attach per socket: a second browser_attach REPLACES the first.
    // The old viewer's leave is AWAITED before the new attach is created, so
    // the ctl channel sees leave(v1) strictly before join(v2).
    const previous = browserAttach;
    browserAttach = null;
    if (previous !== null) await previous.detach().catch(() => {});

    let attach: BrowserAttach | null = null;
    try {
      attach = await createBrowserAttach({
        redisFactory: deps.browser.redisFactory,
        sessionId,
        heartbeatMs: opts.browserHeartbeatMs ?? BROWSER_VIEWER_HEARTBEAT_MS,
        handlers: {
          onState: (state) => {
            if (browserAttach !== attach) return; // replaced or torn down: ignore
            send(socket, { op: "browser_state", sessionId, state });
          },
          onFrame: (image) => {
            if (browserAttach !== attach) return; // replaced or torn down: ignore
            if (closed || socket.readyState !== socket.OPEN) return;
            // Review Focus #3 (slow client): never queue unbounded image
            // bytes behind a stuck socket — anything still buffered above
            // the high-water mark is DROPPED, and later frames flow once the
            // client drains.
            if (socket.bufferedAmount > BROWSER_FRAME_HIGH_WATER) return;
            socket.send(image); // raw BINARY message: image bytes only
          },
        },
      });
    } catch {
      send(socket, {
        op: "error",
        code: "internal",
        message: "Browser attach failed.",
        sessionId,
      });
      return;
    }
    if (closed || browserAttach !== null) {
      // Socket died (or another attach won) mid-setup: don't leak the freshly
      // created subscriber/publisher connections.
      await attach.detach().catch(() => {});
      return;
    }
    browserAttach = attach;
    // Deliberately NO ack frame: the client learns the attach worked from
    // the worker's first browser_state / binary frame (shared ws contract).
  }

  async function handleBrowserDetach(sessionId: string): Promise<void> {
    const attach = browserAttach;
    if (attach === null || attach.sessionId !== sessionId) return; // idempotent no-op
    browserAttach = null;
    await attach.detach().catch(() => {});
  }

  // ---- Approval op (P3 Task 12) ---------------------------------------------

  /**
   * approval_response: ownership FIRST (the subscribe discipline — the uuid
   * shape guard keeps client garbage away from the id column), then the
   * decision enum (the shared schema keeps it an open string precisely so
   * THIS arm can answer the specific bad_request instead of a generic
   * bad_message), then publish + ack. The connection survives every refusal.
   */
  async function handleApprovalResponse(
    msg: Extract<WsClientMsg, { op: "approval_response" }>,
  ): Promise<void> {
    if (deps.approvals === undefined) {
      // Loud fallback for pre-P3 compositions (no publisher wired).
      send(socket, {
        op: "error",
        code: "unavailable",
        message: "Approval channel not configured.",
        sessionId: msg.sessionId,
      });
      return;
    }
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
    if (msg.decision !== "allow" && msg.decision !== "deny" && msg.decision !== "always") {
      send(socket, {
        op: "error",
        code: "bad_request",
        message: "decision must be one of allow, deny, always.",
        sessionId: msg.sessionId,
      });
      return;
    }
    try {
      await deps.approvals.publishResponse({
        approvalId: msg.approvalId,
        userId: uid,
        decision: msg.decision,
      });
    } catch {
      send(socket, {
        op: "error",
        code: "internal",
        message: "Approval response could not be published.",
        sessionId: msg.sessionId,
      });
      return;
    }
    send(socket, { op: "approval_ack", approvalId: msg.approvalId, decision: msg.decision });
  }

  // ---- System channel op (P5 Task 10) ----------------------------------------

  /**
   * system_response: the payload was zod-validated by the shared
   * wsClientMsg parse above; the uid IS this connection's authenticated
   * principal, so no ownership check applies (the channel itself is
   * uid-scoped). Forwarded to sys:{uid}:in; NO ack frame by contract — the
   * worker's pending request resolving is the confirmation, a late answer
   * is a no-op there. The connection survives every refusal.
   */
  async function handleSystemResponse(
    msg: Extract<WsClientMsg, { op: "system_response" }>,
  ): Promise<void> {
    if (deps.systemHub === undefined) {
      // Pre-P5 composition: no attach was ever made on this gateway, so the
      // client can only hold a system_event it never received here — the
      // frame is off-contract for THIS composition (bad_message, not
      // unavailable; R5 revision).
      send(socket, {
        op: "error",
        code: "bad_message",
        message: "System channel not configured.",
      });
      return;
    }
    try {
      await deps.systemHub.respond(uid, msg.id, msg.payload);
    } catch {
      send(socket, {
        op: "error",
        code: "internal",
        message: "System response could not be published.",
      });
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
      case "browser_attach":
        await handleBrowserAttach(msg.sessionId);
        return;
      case "browser_detach":
        await handleBrowserDetach(msg.sessionId);
        return;
      case "browser_input": {
        // `input` was zod-validated by the shared wsClientMsg parse above —
        // an off-schema event never gets this far (it answered bad_message).
        const attach = requireBrowserAttach(msg.sessionId);
        if (attach !== null) attach.publishInput(msg.input);
        return;
      }
      case "browser_takeover": {
        const attach = requireBrowserAttach(msg.sessionId);
        if (attach !== null) attach.publishCtl({ type: "takeover", enabled: msg.enabled });
        return;
      }
      case "approval_response":
        await handleApprovalResponse(msg);
        return;
      case "system_response":
        await handleSystemResponse(msg);
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
