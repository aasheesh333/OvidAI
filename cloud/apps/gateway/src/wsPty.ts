import { randomUUID } from "node:crypto";
import type { Redis } from "ioredis";
import {
  parsePtyOutMsg,
  parsePtyReplyMsg,
  ptyCtlChannel,
  ptyOutChannel,
  ptyRegistryKey,
  type PtyOutMsg,
  type PtyReplyMsg,
  type RingChunkWire,
} from "@ovid/shared";

/**
 * Gateway-side terminal bridge (P2 Task 13): the ws dispatch's only view of
 * the Redis pty protocol. Each open/attach generates a fresh
 * `pty:reply:{uuid}` channel, SUBSCRIBEs it BEFORE publishing the ctl frame
 * (a reply published before the subscribe ack would be lost), and tears the
 * subscription down as soon as the reply lands.
 *
 * Review Focus #3 — attach ordering/dedupe: `attach` SUBSCRIBEs `pty:out`
 * FIRST, then publishes the attach request. Every output chunk published after
 * that subscribe is therefore seen by the bridge; live chunks with
 * `offset < snapshot endOffset` are dropped INSIDE the bridge (the snapshot
 * wins — a chunk racing the snapshot read is delivered exactly once, via the
 * snapshot, never twice).
 */

/** How long the ws dispatch waits for the worker's `opened` ack. */
export const PTY_OPEN_TIMEOUT_MS = 30_000;
/** How long the ws dispatch waits for an `attach_reply`. */
export const PTY_REPLY_TIMEOUT_MS = 10_000;

/** A failed open/attach/lookup: `code` goes verbatim into the ws error frame. */
export class PtyBridgeError extends Error {
  constructor(readonly code: string, message: string) {
    super(message);
    this.name = "PtyBridgeError";
  }
}

export interface PtyBridge {
  /**
   * Publishes the open ctl and resolves on `opened`; rejects
   * PtyBridgeError(code) on `opened_failed` or when no ack arrives in time.
   */
  open(
    ptyId: string,
    meta: { userId: string; sessionId: string; cols: number; rows: number },
    timeoutMs: number,
  ): Promise<void>;
  /**
   * SUBSCRIBES `pty:out:{ptyId}` FIRST, then publishes the attach request.
   * Resolves with the snapshot (truncated/chunks/endOffset) once the
   * `attach_reply` lands; buffered live output with offset < endOffset is
   * dropped (offset dedupe), everything beyond is passed to `onOut`. `detach`
   * quits the output subscription — the PTY ITSELF SURVIVES.
   */
  attach(
    ptyId: string,
    lastOffset: number | null,
    onOut: (m: PtyOutMsg) => void,
    timeoutMs: number,
  ): Promise<{
    truncated: boolean;
    chunks: RingChunkWire[];
    endOffset: number;
    detach(): Promise<void>;
  }>;
  /** Publishes an input/resize/close ctl frame. */
  send(
    ptyId: string,
    msg: { type: "input"; data: string } | { type: "resize"; cols: number; rows: number } | { type: "close" },
  ): Promise<void>;
  /** Registry HGETALL → {userId, sessionId} | null (missing/expired → null). */
  lookup(ptyId: string): Promise<{ userId: string; sessionId: string } | null>;
}

/**
 * Subscribes `channel` on a DEDICATED connection (ioredis pub/sub mode blocks
 * regular commands, so the shared client cannot be used — Task 4 convention).
 * The listener is attached before the SUBSCRIBE is issued, so a message
 * arriving in the same tick as the ack is never missed.
 */
async function subscribeChannel(
  redis: Redis,
  channel: string,
  onMessage: (raw: string) => void,
): Promise<() => Promise<void>> {
  const sub = redis.duplicate();
  sub.on("error", () => {}); // ioredis reconnects on its own; transient errors are contained
  const listener = (_ch: string, message: string): void => {
    try {
      onMessage(message);
    } catch {
      // consumer bug: contained — never fatal to the pub/sub connection
    }
  };
  sub.on("message", listener);
  try {
    await sub.subscribe(channel); // resolves once redis acknowledges
  } catch (err) {
    await sub.quit().catch(() => {}); // don't leak the connection on failure
    throw err;
  }
  let closed = false;
  return async () => {
    if (closed) return;
    closed = true;
    sub.off("message", listener);
    await sub.quit().catch(() => {});
  };
}

/** Reply watcher for one request: settles on the matching reply, or times out. */
interface ReplyWatcher {
  reply: Promise<PtyReplyMsg>;
  /** Resolves only after the reply-channel SUBSCRIBE is acknowledged. */
  subscribed: Promise<void>;
  stop(): Promise<void>;
}

export function createRedisPtyBridge(redis: Redis, opts: { replyTimeoutMs?: number } = {}): PtyBridge {
  // Test seam: when set, it OVERRIDES every per-call timeout (the ws dispatch
  // always passes the pinned PTY_OPEN/REPLY_TIMEOUT_MS; prod never sets this).
  const replyTimeoutOverride = opts.replyTimeoutMs;
  const effectiveTimeout = (requestedMs: number): number => replyTimeoutOverride ?? requestedMs;
  return makeBridge(redis, effectiveTimeout);
}

function makeBridge(redis: Redis, effectiveTimeout: (ms: number) => number): PtyBridge {
  return {
    async open(ptyId, meta, timeoutMs) {
      const replyChannel = `pty:reply:${randomUUID()}`;
      const watcher = watchReplyChannel(redis, replyChannel, ptyId, timeoutMs, effectiveTimeout);
      await watcher.subscribed;
      await redis.publish(
        ptyCtlChannel(ptyId),
        JSON.stringify({
          type: "open",
          ptyId,
          userId: meta.userId,
          sessionId: meta.sessionId,
          cols: meta.cols,
          rows: meta.rows,
          replyChannel,
        }),
      );
      try {
        const reply = await watcher.reply;
        if (reply.type === "opened") return;
        if (reply.type === "opened_failed") {
          throw new PtyBridgeError(reply.code, reply.message);
        }
        throw new PtyBridgeError("internal", `unexpected reply ${reply.type} for open`);
      } finally {
        await watcher.stop();
      }
    },

    async attach(ptyId, lastOffset, onOut, timeoutMs) {
      let snapshotEnd: number | null = null;
      let detached = false;
      const buffered: PtyOutMsg[] = [];

      const deliver = (m: PtyOutMsg): void => {
        if (detached) return;
        try {
          onOut(m);
        } catch {
          // consumer bug: contained
        }
      };

      // (1) SUBSCRIBE pty:out FIRST — the pinned ordering rule.
      const stopOut = await subscribeChannel(redis, ptyOutChannel(ptyId), (raw) => {
        let m: PtyOutMsg;
        try {
          m = parsePtyOutMsg(JSON.parse(raw));
        } catch {
          return; // garbage on the channel: skip
        }
        if (m.ptyId !== ptyId) return; // channel is per-pty; guard anyway
        if (snapshotEnd === null) {
          buffered.push(m); // pre-snapshot window: snapshot decides what's stale
          return;
        }
        if (m.type === "output" && m.offset < snapshotEnd) return; // snapshot wins
        deliver(m);
      });

      try {
        // (2) reply channel, then (3) the attach request.
        const replyChannel = `pty:reply:${randomUUID()}`;
        const watcher = watchReplyChannel(redis, replyChannel, ptyId, timeoutMs, effectiveTimeout);
        await watcher.subscribed;
        await redis.publish(
          ptyCtlChannel(ptyId),
          JSON.stringify({ type: "attach", ptyId, lastOffset, replyChannel }),
        );
        let reply: PtyReplyMsg;
        try {
          reply = await watcher.reply;
        } finally {
          await watcher.stop();
        }
        if (reply.type === "attach_failed") {
          throw new PtyBridgeError(reply.code, reply.message);
        }
        if (reply.type !== "attach_reply") {
          throw new PtyBridgeError("internal", `unexpected reply ${reply.type} for attach`);
        }

        snapshotEnd = reply.endOffset;
        const end = reply.endOffset;
        const flush = (): void => {
          for (const m of buffered.splice(0)) {
            if (m.type === "output" && m.offset < end) continue; // snapshot wins
            deliver(m);
          }
        };
        // The buffered live tail is flushed from a MACROTASK, not a microtask.
        // queueMicrotask(flush) would enqueue the flush BEFORE the promise
        // resolution queues the awaiting caller's continuation, so the
        // buffered beyond-endOffset chunks would reach onOut — the socket —
        // AHEAD of the ack (pty_opened/pty_attached) and the snapshot frames
        // (microtasks run FIFO; verified empirically under Node 22). A
        // setTimeout(0) fires only after every pending microtask — including
        // the caller's resume, which sends ack + snapshot synchronously — has
        // drained, pinning the frame order ACK → SNAPSHOT → live on both the
        // open and the attach path. A lazy flush (armed on the next live
        // message) would also work but leaves the window open when no further
        // output arrives.
        const flushTimer = setTimeout(flush, 0);
        flushTimer.unref?.();

        return {
          truncated: reply.truncated,
          chunks: reply.chunks,
          endOffset: reply.endOffset,
          detach: async () => {
            if (detached) return;
            detached = true; // also gates deliver(): nothing after a detach
            await stopOut();
          },
        };
      } catch (err) {
        await stopOut(); // no live subscription may outlive a failed attach
        throw err;
      }
    },

    async send(ptyId, msg) {
      // ptyId is merged in — every worker-side ctl variant requires it.
      await redis.publish(ptyCtlChannel(ptyId), JSON.stringify({ ...msg, ptyId }));
    },

    async lookup(ptyId) {
      let fields: Record<string, string> | null = null;
      try {
        fields = (await redis.hgetall(ptyRegistryKey(ptyId))) as Record<string, string> | null;
      } catch {
        return null; // redis outage: indistinguishable from a missing registry
      }
      if (fields === null || fields.userId === undefined || fields.sessionId === undefined) {
        return null; // missing or expired (HGETALL on a TTL-lapsed key is empty)
      }
      return { userId: fields.userId, sessionId: fields.sessionId };
    },
  };
}

function watchReplyChannel(
  redis: Redis,
  replyChannel: string,
  ptyId: string,
  timeoutMs: number,
  effectiveTimeout: (ms: number) => number,
): ReplyWatcher {
  let settled = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let resolveReply!: (m: PtyReplyMsg) => void;
  const reply = new Promise<PtyReplyMsg>((resolve) => {
    resolveReply = resolve;
  });
  const rejection = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(
      () => {
        if (settled) return;
        settled = true;
        reject(new PtyBridgeError("timeout", `no worker reply on ${replyChannel} within ${timeoutMs} ms`));
      },
      effectiveTimeout(timeoutMs),
    );
    timer.unref?.();
  });

  let stopSub: (() => Promise<void>) | undefined;
  const subscribed = new Promise<void>((resolve, reject) => {
    void subscribeChannel(redis, replyChannel, (raw) => {
      let m: PtyReplyMsg;
      try {
        m = parsePtyReplyMsg(JSON.parse(raw));
      } catch {
        return; // garbage on the channel: skip
      }
      if (m.ptyId !== ptyId) return; // fresh per-request channel; guard anyway
      if (settled) return;
      settled = true;
      if (timer !== undefined) clearTimeout(timer);
      resolveReply(m);
    })
      .then((stop) => {
        stopSub = stop;
        resolve();
      })
      .catch((err: unknown) => {
        if (!settled) {
          settled = true;
          if (timer !== undefined) clearTimeout(timer);
          reject(
            new PtyBridgeError(
              "internal",
              `reply channel subscribe failed: ${err instanceof Error ? err.message : String(err)}`,
            ),
          );
        }
      });
  });

  return {
    reply: Promise.race([reply, rejection]),
    subscribed,
    stop: async () => {
      if (timer !== undefined) clearTimeout(timer);
      const stop = await subscribed.then(
        () => stopSub,
        () => undefined,
      );
      await stop?.().catch(() => {});
    },
  };
}
