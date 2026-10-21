import { randomUUID } from "node:crypto";
import type { Redis as IORedis } from "ioredis";
import {
  browserCtlChannel,
  browserFramesChannel,
  browserInputChannel,
  browserStateChannel,
  browserStateDtoSchema,
  type BrowserCtlMsg,
  type BrowserInputEvent,
  type BrowserStateDto,
} from "@ovid/shared";

/**
 * Gateway-side browser viewer channel (P6 Task 9) — the redis plumbing behind
 * ONE socket's `browser_attach`. The ws dispatch (ws.ts) owns the protocol
 * surface (ownership checks, error frames, the per-socket attach slot); this
 * module owns the connections and channel wiring.
 *
 * Design pins:
 *  - Pub/sub rides redis-q per the P6-Q6 ruling (ephemeral, AG3-safe).
 *  - BINDING CARRY (T8 review, empirically proven): a connection in subscriber
 *    mode cannot publish. Each attach therefore holds TWO dedicated
 *    connections — a frames/state SUBSCRIBER and a ctl/input PUBLISHER — and
 *    `detach()` quits BOTH (awaited), so a leaked attach is a leaked nothing.
 *  - Binary frames ride ioredis `messageBuffer` events (the string `message`
 *    event coerces non-UTF-8 payloads lossily); the 1-byte
 *    BROWSER_FRAME_FORMAT prefix is stripped before the bytes reach the
 *    socket (the format travels in the client's latest `browser_state`).
 *  - The initial `viewer_join` is published AFTER the state/frames subscribe
 *    resolves: the worker starts screencasting on the join, so every state/
 *    frame it publishes from then on is seen by this subscriber.
 *  - All publishes are fire-and-forget (errors logged, never thrown into the
 *    ws frame loop — same discipline as the worker bridge).
 *  - `detach()` is idempotent and awaits the viewer_leave publish BEFORE the
 *    connections quit, so a replacing attach's join can never overtake the
 *    old viewer's leave on the ctl channel.
 */

/** What ws.ts wires: a factory for the per-attach dedicated connections. */
export interface BrowserChannelDeps {
  /** Must return a FRESH connection each call; every connection it hands out is quit by the attach's detach(). */
  redisFactory: () => IORedis;
}

/** Re-publish viewer_join while attached (the worker's sweep drops viewers silent for ~3× this). */
export const BROWSER_VIEWER_HEARTBEAT_MS = 30_000;

/**
 * Wave 5: a live, NON-casting state means the worker has a page but has not
 * counted this viewer (its join predates the worker's watch — the agent
 * opened its first page after the Browser screen did). The attach then
 * re-announces itself at most this often.
 */
export const BROWSER_REJOIN_MIN_INTERVAL_MS = 2_000;

/** socket.bufferedAmount above this ⇒ DROP the frame (slow-client guard, Review Focus #3). */
export const BROWSER_FRAME_HIGH_WATER = 4 * 1024 * 1024;

export interface BrowserAttachHandlers {
  /** Every zod-valid BrowserStateDto published on the state channel. */
  onState(state: BrowserStateDto): void;
  /** Every frame published on the frames channel — image bytes, prefix ALREADY stripped. */
  onFrame(image: Buffer): void;
}

/**
 * Result of parsing one state-channel payload. `state` is the zod-parsed DTO,
 * which preserves the additive browser-runtime fields (`fps`, `headless`) and
 * drops any other unknown key — exactly what the gateway forwards to clients.
 */
export type BrowserStateParse =
  | { ok: true; state: BrowserStateDto }
  | { ok: false; reason: "malformed" | "schema" };

/** Parse a raw state-channel payload; malformed JSON and schema misses are distinguished for logging. */
export function parseBrowserStatePayload(raw: string): BrowserStateParse {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { ok: false, reason: "malformed" };
  }
  const check = browserStateDtoSchema.safeParse(parsed);
  return check.success ? { ok: true, state: check.data } : { ok: false, reason: "schema" };
}

/** One attached viewer; created by createBrowserAttach, owned by ws.ts. */
export interface BrowserAttach {
  /** The BROWSER key (Wave 5: `userBrowserKey(uid)`) — channel namespace. */
  readonly sessionId: string;
  readonly viewerId: string;
  /**
   * FE-026: may THIS viewer inject input? False only while the latest state
   * names ANOTHER viewer as the takeover holder.
   */
  mayInput(): boolean;
  /** Fire-and-forget publish on the session's ctl channel. */
  publishCtl(msg: BrowserCtlMsg): void;
  /** Fire-and-forget publish on the session's input channel. */
  publishInput(event: BrowserInputEvent): void;
  /** viewer_leave + unsubscribe + quit BOTH connections (awaited). Idempotent. */
  detach(): Promise<void>;
}

/**
 * Wires one viewer's redis topology: subscribes state+frames on a dedicated
 * subscriber connection, then publishes the initial `viewer_join` on a
 * dedicated publisher connection and arms the join heartbeat (unref'd).
 * Rejects (with both connections already quit) if the subscribe fails.
 */
export function createBrowserAttach(opts: {
  redisFactory: () => IORedis;
  sessionId: string;
  handlers: BrowserAttachHandlers;
  /** Default BROWSER_VIEWER_HEARTBEAT_MS; test seam (WsConnectionOptions.browserHeartbeatMs). */
  heartbeatMs?: number;
  log?: (msg: string, err?: unknown) => void;
}): Promise<BrowserAttach> {
  const { redisFactory, sessionId, handlers } = opts;
  const heartbeatMs = opts.heartbeatMs ?? BROWSER_VIEWER_HEARTBEAT_MS;
  const log =
    opts.log ?? ((msg: string, err?: unknown) => console.error(`[browser-channel] ${msg}`, err ?? ""));

  const viewerId = randomUUID();
  // BINDING CARRY: SEPARATE connections — the publisher must never sit in
  // subscriber mode, and the subscriber must never be asked to publish.
  const pub = redisFactory();
  const sub = redisFactory();
  let detached = false;
  let heartbeatTimer: NodeJS.Timeout | null = null;

  const ctlChannel = browserCtlChannel(sessionId);
  const stateChannel = browserStateChannel(sessionId);
  const framesChannel = browserFramesChannel(sessionId);
  const join = JSON.stringify({ type: "viewer_join", viewerId } satisfies BrowserCtlMsg);
  let latestState: BrowserStateDto | null = null;
  let lastRejoinAt = 0;
  let subscribed = false;

  function publish(channel: string, payload: string): void {
    if (detached) return;
    pub.publish(channel, payload).catch((err: unknown) => {
      log(`publish to ${channel} failed for session ${sessionId}`, err);
    });
  }

  // messageBuffer: the frames channel carries raw image bytes — the string
  // `message` event is lossy for non-UTF-8 payloads (T8 carry).
  sub.on("messageBuffer", (channel: Buffer, message: Buffer) => {
    if (detached) return; // raced a detach: nothing more forwards
    const ch = channel.toString("utf8");
    if (ch === stateChannel) {
      const raw = message.toString("utf8");
      const parsed = parseBrowserStatePayload(raw);
      if (!parsed.ok) {
        if (parsed.reason === "malformed") {
          log(`ignoring malformed state JSON on ${ch}: ${raw.slice(0, 64)}`);
        } else {
          log(`ignoring schema-invalid state payload on ${ch}`);
        }
        return;
      }
      latestState = parsed.state;
      if (
        subscribed &&
        parsed.state.live &&
        !parsed.state.screencast &&
        Date.now() - lastRejoinAt >= BROWSER_REJOIN_MIN_INTERVAL_MS
      ) {
        lastRejoinAt = Date.now();
        publish(ctlChannel, join);
      }
      handlers.onState(parsed.state);
      return;
    }
    if (ch === framesChannel) {
      // Strip the 1-byte format prefix; the client learns the format from
      // its latest browser_state. An empty payload has no prefix to strip.
      if (message.length === 0) return;
      handlers.onFrame(message.subarray(1));
    }
  });

  return (async () => {
    try {
      await sub.subscribe(stateChannel, framesChannel);
    } catch (err) {
      // Never leave half-created connections behind a failed attach.
      log(`subscribe failed for session ${sessionId}`, err);
      await sub.quit().catch(() => {});
      await pub.quit().catch(() => {});
      throw err;
    }

    // Initial join AFTER the subscribe: the worker starts screencasting on
    // it, and the subscriber is already listening by then.
    subscribed = true;
    publish(ctlChannel, join);

    // Heartbeat: re-publish the SAME viewerId so the worker's staleness sweep
    // keeps this viewer alive. Unref'd — it must never hold the process open.
    heartbeatTimer = setInterval(() => publish(ctlChannel, join), heartbeatMs);
    heartbeatTimer.unref?.();

    const attach: BrowserAttach = {
      sessionId,
      viewerId,
      mayInput: () => {
        const holder = latestState?.takeoverViewerId ?? null;
        return holder === null || holder === viewerId;
      },
      publishCtl: (msg) => publish(ctlChannel, JSON.stringify(msg)),
      publishInput: (event) => publish(browserInputChannel(sessionId), JSON.stringify(event)),
      async detach(): Promise<void> {
        if (detached) return;
        detached = true;
        if (heartbeatTimer !== null) {
          clearInterval(heartbeatTimer);
          heartbeatTimer = null;
        }
        // Leave BEFORE quitting the publisher, and AWAIT it: a replacing
        // attach's join must never overtake this viewer's leave.
        try {
          await pub.publish(ctlChannel, JSON.stringify({ type: "viewer_leave", viewerId } satisfies BrowserCtlMsg));
        } catch (err) {
          log(`viewer_leave publish failed for session ${sessionId}`, err);
        }
        try {
          await sub.unsubscribe(stateChannel, framesChannel);
        } catch (err) {
          log(`unsubscribe failed for session ${sessionId}`, err);
        }
        await sub.quit().catch(() => {});
        await pub.quit().catch(() => {});
      },
    };
    return attach;
  })();
}
