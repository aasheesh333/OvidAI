/**
 * Worker-side Redis browser bridge (P6 Task 8).
 *
 * Publishes screencast frames (raw bytes prefixed with the 1-byte
 * `BROWSER_FRAME_FORMAT` value) and `BrowserStateDto` JSON for the gateway
 * (Task 9 peer), subscribes the session's ctl + input channels on ONE
 * dedicated ioredis subscriber connection per watched session, and keeps the
 * per-session viewer refcount that decides whether screencast should keep
 * running.
 *
 * Design pins:
 *  - Pub/sub rides redis-q per the P6-Q6 ruling (ephemeral, AG3-safe).
 *  - An ioredis connection in subscriber mode cannot run regular commands,
 *    and one subscriber interleaving many sessions' channels would let one
 *    slow session's handler head-of-line block the rest — so `watch` opens
 *    a DEDICATED subscriber connection per session (the Task-4 events
 *    package lesson), and `unwatch` awaits its quit.
 *  - Viewer bookkeeping: per watched session a `Map<viewerId, lastSeenMs>`;
 *    `viewer_join` sets/refreshes (the gateway re-sends every 30 s as a
 *    heartbeat), `viewer_leave` deletes, and ANY size transition fires
 *    `onViewersChange`. The sweep drops viewers whose lastSeen is older
 *    than `viewerStaleMs`, so a crashed gateway (no leave ever published)
 *    still ends up at zero viewers and the screencast stops (Review Focus
 *    #3). The sweep timer is unref'd — it must never keep the worker
 *    process alive.
 *  - Malformed ctl/input JSON or schema-invalid payloads are logged and
 *    ignored; the connection survives (Review Focus #4).
 *  - `publishFrame`/`publishState` are fire-and-forget: errors are logged,
 *    never thrown into the screencast ack loop.
 *
 * `onInput` is invoked synchronously in redis arrival order on the
 * subscriber connection's event loop turn. The engine (Task 14) MUST await
 * its `applyInputEvent` calls in that same arrival order — concurrent
 * un-awaited calls would interleave at the Playwright channel (T7-review
 * M1 carry).
 */

import { Redis } from "ioredis";

import {
  BROWSER_FRAME_FORMAT,
  browserCtlChannel,
  browserFramesChannel,
  browserInputChannel,
  browserStateChannel,
  browserCtlMsgSchema,
  browserInputEventSchema,
  type BrowserCtlMsg,
  type BrowserInputEvent,
  type BrowserStateDto,
} from "@ovid/shared";

import type { ScreencastFrame } from "./screencast.js";

export interface BridgeHandlers {
  /** Fired on every 0↔n or n↔m viewer-size transition of a watched session. */
  onViewersChange(sessionId: string, viewers: number): void;
  /** Only zod-valid events, in redis arrival order. */
  onInput(sessionId: string, event: BrowserInputEvent): void;
  onTakeover(sessionId: string, enabled: boolean): void;
}

export interface BrowserBridge {
  /** ONE dedicated ioredis subscriber connection per session; subscribes ctl+input. Idempotent. */
  watch(sessionId: string): Promise<void>;
  /** Unsubscribe + quit the session's connection (awaited). Idempotent. */
  unwatch(sessionId: string): Promise<void>;
  /** PUBLISH Buffer.concat([prefix byte, data]) — fire-and-forget, errors logged not thrown. */
  publishFrame(sessionId: string, frame: ScreencastFrame): void;
  /** PUBLISH JSON — fire-and-forget, errors logged not thrown. */
  publishState(sessionId: string, state: BrowserStateDto): void;
  viewerCount(sessionId: string): number;
  /** Unwatch all + quit the shared publisher connection. Idempotent. */
  close(): Promise<void>;
}

interface WatchedSession {
  /** ctl+input subscriber connection — dedicated to this session. */
  sub: Redis;
  /** viewerId -> last-seen epoch ms (from `now`). */
  viewers: Map<string, number>;
}

export function createRedisBrowserBridge(opts: {
  /** Must return a FRESH connection each call; every connection it hands out is quit by `close()`. */
  redisFactory: () => Redis;
  handlers: BridgeHandlers;
  /** Default 90_000 — comfortably above the gateway's 30 s join heartbeat. */
  viewerStaleMs?: number;
  /** Default 30_000; the timer is unref'd and cleared on close(). */
  sweepIntervalMs?: number;
  /** Test seam for the stale sweep. Default Date.now. */
  now?: () => number;
  log?: (msg: string, err?: unknown) => void;
}): BrowserBridge {
  const { redisFactory, handlers } = opts;
  const viewerStaleMs = opts.viewerStaleMs ?? 90_000;
  const sweepIntervalMs = opts.sweepIntervalMs ?? 30_000;
  const now = opts.now ?? Date.now;
  const log = opts.log ?? ((msg: string, err?: unknown) => console.error(`[browser-bridge] ${msg}`, err ?? ""));

  const sessions = new Map<string, WatchedSession>();
  /** Shared publisher, created lazily on first publish (ioredis queues commands while connecting). */
  let publisher: Redis | null = null;
  let closed = false;

  // Test seam: the raw sweep timer handle (see bridge.test.ts), readable off
  // the returned bridge as `_sweepTimer` so the unref can be asserted
  // without timing a whole process exit. Not part of the public interface.
  let _sweepTimer: NodeJS.Timeout | null = null;

  function sweep(): void {
    const t = now();
    for (const [sessionId, session] of sessions) {
      const before = session.viewers.size;
      for (const [viewerId, lastSeen] of session.viewers) {
        if (t - lastSeen > viewerStaleMs) session.viewers.delete(viewerId);
      }
      const after = session.viewers.size;
      if (after !== before) {
        log(`viewer sweep dropped ${before - after} stale viewer(s) on session ${sessionId}`);
        handlers.onViewersChange(sessionId, after);
      }
    }
  }

  function getPublisher(): Redis {
    if (!publisher) {
      if (closed) throw new Error("BrowserBridge is closed.");
      publisher = redisFactory();
    }
    return publisher;
  }

  function onCtlMessage(sessionId: string, channel: string, raw: Buffer | string): void {
    const text = typeof raw === "string" ? raw : raw.toString("utf8");
    if (channel !== browserCtlChannel(sessionId)) return;
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      log(`ignoring malformed ctl JSON on ${channel}: ${text.slice(0, 64)}`);
      return;
    }
    const msg: BrowserCtlMsg | null = browserCtlMsgSchema.safeParse(parsed).success
      ? (parsed as BrowserCtlMsg)
      : null;
    if (!msg) {
      log(`ignoring schema-invalid ctl payload on ${channel}`);
      return;
    }
    const session = sessions.get(sessionId);
    if (!session) return; // raced an unwatch: nothing to bookkeep
    if (msg.type === "viewer_join" || msg.type === "viewer_leave") {
      const before = session.viewers.size;
      if (msg.type === "viewer_join") session.viewers.set(msg.viewerId, now());
      else session.viewers.delete(msg.viewerId);
      const after = session.viewers.size;
      if (after !== before) handlers.onViewersChange(sessionId, after);
    } else {
      handlers.onTakeover(sessionId, msg.enabled);
    }
  }

  function onInputMessage(sessionId: string, channel: string, raw: Buffer | string): void {
    const text = typeof raw === "string" ? raw : raw.toString("utf8");
    if (channel !== browserInputChannel(sessionId)) return;
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      log(`ignoring malformed input JSON on ${channel}: ${text.slice(0, 64)}`);
      return;
    }
    const check = browserInputEventSchema.safeParse(parsed);
    if (!check.success) {
      log(`ignoring schema-invalid input event on ${channel}`);
      return;
    }
    if (!sessions.has(sessionId)) return; // raced an unwatch
    handlers.onInput(sessionId, check.data);
  }

  const bridge: BrowserBridge = {
    async watch(sessionId: string): Promise<void> {
      if (closed) throw new Error("BrowserBridge is closed.");
      const existing = sessions.get(sessionId);
      if (existing) return; // idempotent: one connection per session

      const sub = redisFactory();
      sub.on("messageBuffer", (channel: Buffer, message: Buffer) => {
        const ch = channel.toString("utf8");
        if (ch === browserCtlChannel(sessionId)) onCtlMessage(sessionId, ch, message);
        else if (ch === browserInputChannel(sessionId)) onInputMessage(sessionId, ch, message);
      });
      const watched: WatchedSession = { sub, viewers: new Map() };
      // Register BEFORE subscribing so an immediately-following publish
      // (e.g. the gateway's viewer_join before this watch resolved) is not
      // dropped by the `sessions.get` guards above.
      sessions.set(sessionId, watched);
      try {
        await sub.subscribe(browserCtlChannel(sessionId), browserInputChannel(sessionId));
      } catch (err) {
        // Never leave a half-watched session registered.
        if (sessions.get(sessionId) === watched) sessions.delete(sessionId);
        await sub.quit().catch(() => {});
        throw err;
      }
    },

    async unwatch(sessionId: string): Promise<void> {
      const watched = sessions.get(sessionId);
      if (!watched) return; // idempotent
      sessions.delete(sessionId);
      watched.viewers.clear();
      try {
        await watched.sub.unsubscribe();
      } catch (err) {
        log(`unsubscribe failed for session ${sessionId}`, err);
      }
      await watched.sub.quit().catch(() => {});
    },

    publishFrame(sessionId: string, frame: ScreencastFrame): void {
      try {
        const prefix = BROWSER_FRAME_FORMAT[frame.format];
        const payload = Buffer.concat([Buffer.from([prefix]), frame.data]);
        getPublisher()
          .publish(browserFramesChannel(sessionId), payload)
          .catch((err: unknown) => log(`publishFrame failed for session ${sessionId}`, err));
      } catch (err) {
        log(`publishFrame failed for session ${sessionId}`, err);
      }
    },

    publishState(sessionId: string, state: BrowserStateDto): void {
      try {
        getPublisher()
          .publish(browserStateChannel(sessionId), JSON.stringify(state))
          .catch((err: unknown) => log(`publishState failed for session ${sessionId}`, err));
      } catch (err) {
        log(`publishState failed for session ${sessionId}`, err);
      }
    },

    viewerCount(sessionId: string): number {
      return sessions.get(sessionId)?.viewers.size ?? 0;
    },

    async close(): Promise<void> {
      if (closed) return;
      closed = true;
      if (_sweepTimer) {
        clearInterval(_sweepTimer);
        _sweepTimer = null;
      }
      const watched = [...sessions.keys()];
      for (const sid of watched) await bridge.unwatch(sid);
      const pub = publisher;
      publisher = null;
      if (pub) {
        try {
          await pub.quit();
        } catch {
          // already gone / never fully connected
        }
      }
    },
  };

  // Expose the `_sweepTimer` test seam without widening the public type.
  Object.defineProperty(bridge, "_sweepTimer", {
    get: () => _sweepTimer,
    enumerable: false,
  });

  // The sweep runs from construction (unref'd) so it never keeps the worker
  // process alive, and `close()` clears it.
  _sweepTimer = setInterval(sweep, sweepIntervalMs);
  _sweepTimer.unref?.();

  return bridge;
}
