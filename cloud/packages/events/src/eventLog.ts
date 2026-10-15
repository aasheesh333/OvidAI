import type { Redis } from "ioredis";
import type { SessionEvent, SessionEventType } from "@ovid/shared";

export interface EventLog {
  append(sessionId: string, type: SessionEventType, payload: Record<string, unknown>): Promise<SessionEvent>; // XADD + PUBLISH
  readSince(sessionId: string, lastSeq: string | null, limit: number): Promise<SessionEvent[]>; // XRANGE
  subscribe(sessionId: string, onEvent: (e: SessionEvent) => void): Promise<() => Promise<void>>; // PSUBSCRIBE; returns unsubscribe
}

const DEFAULT_MAX_LEN = 10_000;

const streamKey = (sessionId: string): string => `sess:${sessionId}:events`;
const liveChannel = (sessionId: string): string => `sess:${sessionId}:live`;

// Envelope stored in the stream under the single JSON field `e`: everything
// but `seq`, which is the stream entry id assigned by XADD and merged in on
// every read/delivery.
type StoredEnvelope = Omit<SessionEvent, "seq">;

function decodeEntry(id: string, fields: string[]): SessionEvent {
  // fields is the flat [name, value, …] list; we only ever write `e`.
  const stored = JSON.parse(fields[1]) as StoredEnvelope;
  return { ...stored, seq: id };
}

export function createRedisEventLog(redis: Redis, opts?: { maxLen?: number }): EventLog {
  const maxLen = opts?.maxLen ?? DEFAULT_MAX_LEN;

  return {
    async append(sessionId, type, payload) {
      const stored: StoredEnvelope = {
        sessionId,
        type,
        payload,
        ts: new Date().toISOString(),
      };
      // Exact MAXLEN, deliberately NOT "MAXLEN ~": approximate trimming only
      // evicts whole macro-nodes (~100 entries each), so streams below one
      // node are never trimmed at all (verified on redis 7.4: 12 appends with
      // "~ 5" leave XLEN 12). Exact trimming keeps the plan's trim contract
      // at any scale; its extra cost is a bounded listpack split per XADD.
      const id = await redis.xadd(
        streamKey(sessionId),
        "MAXLEN",
        String(maxLen),
        "*",
        "e",
        JSON.stringify(stored),
      );
      if (id === null) {
        throw new Error(`XADD returned null for stream ${streamKey(sessionId)}`);
      }
      const event: SessionEvent = { ...stored, seq: id };
      // Fan out the same envelope (seq filled) to live subscribers.
      await redis.publish(liveChannel(sessionId), JSON.stringify(event));
      return event;
    },

    async readSince(sessionId, lastSeq, limit) {
      if (limit <= 0) return [];
      // "(" prefix = exclusive start (redis >= 6.2): never re-delivers lastSeq.
      const start = lastSeq === null ? "-" : `(${lastSeq}`;
      const entries = await redis.xrange(
        streamKey(sessionId),
        start,
        "+",
        "COUNT",
        limit,
      );
      return (entries ?? []).map(([id, fields]) => decodeEntry(id, fields));
    },

    async subscribe(sessionId, onEvent) {
      // Dedicated connection: ioredis pub/sub mode blocks regular commands,
      // so the shared client cannot be used here.
      const sub = redis.duplicate();
      // An unhandled "error" event would crash the process; ioredis keeps
      // reconnecting on its own, so transient errors are swallowed here.
      sub.on("error", () => {});
      const channel = liveChannel(sessionId);
      const listener = (_ch: string, message: string): void => {
        onEvent(JSON.parse(message) as SessionEvent);
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
        // Detach first so no message can be delivered mid-teardown.
        sub.off("message", listener);
        await sub.quit().catch(() => {});
      };
    },
  };
}
