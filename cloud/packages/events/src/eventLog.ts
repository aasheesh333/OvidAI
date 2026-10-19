import type { Redis } from "ioredis";
import type { SessionEvent, SessionEventType } from "@ovid/shared";

export interface EventLog {
  append(sessionId: string, type: SessionEventType, payload: Record<string, unknown>): Promise<SessionEvent>; // XADD + PUBLISH
  readSince(sessionId: string, lastSeq: string | null, limit: number): Promise<SessionEvent[]>; // XRANGE
  subscribe(sessionId: string, onEvent: (e: SessionEvent) => void): Promise<() => Promise<void>>; // SUBSCRIBE (one channel per session); returns unsubscribe
}

const DEFAULT_MAX_LEN = 10_000;

/**
 * Time-based retention (capacity wave 2026-10-19). MAXLEN bounds ONE stream,
 * but nothing bounded the NUMBER of streams: every session that ever ran kept
 * up to 10k events in redis-q forever, and redis-q is `noeviction` — so the
 * event log grew without bound until writes started failing. Each append now
 * refreshes a TTL on the stream key: an idle session's live tail expires and
 * history is served from the Postgres mirror (the REST events route), which
 * is already the source of truth beyond the stream's trim window.
 */
export const DEFAULT_STREAM_TTL_SEC = 48 * 3600;

/** OVID_EVENT_STREAM_TTL_S (60..30 days, default 48 h; 0 disables). */
export function streamTtlSecFromEnv(env: NodeJS.ProcessEnv): number {
  const raw = env.OVID_EVENT_STREAM_TTL_S;
  if (raw === undefined || raw.trim() === "") return DEFAULT_STREAM_TTL_SEC;
  const n = Number(raw);
  if (!Number.isInteger(n) || (n !== 0 && (n < 60 || n > 30 * 86_400))) {
    throw new Error(`OVID_EVENT_STREAM_TTL_S must be 0 or an integer 60..2592000, got: ${raw}`);
  }
  return n;
}

/**
 * XADD + EXPIRE + PUBLISH in ONE round trip, atomically. The published
 * envelope is the stored JSON with `"seq":"<id>"` spliced in before the
 * closing brace (ARGV[2] is always a JSON object from JSON.stringify).
 *   KEYS[1] stream, KEYS[2] channel
 *   ARGV[1] maxLen, ARGV[2] stored JSON, ARGV[3] ttl seconds (0 = none)
 */
const APPEND_LUA = `
local id = redis.call('XADD', KEYS[1], 'MAXLEN', ARGV[1], '*', 'e', ARGV[2])
local ttl = tonumber(ARGV[3])
if ttl > 0 then redis.call('EXPIRE', KEYS[1], ttl) end
local body = ARGV[2]
redis.call('PUBLISH', KEYS[2], string.sub(body, 1, -2) .. ',"seq":"' .. id .. '"}')
return id
`;

type AppendCapable = Redis & {
  ovidEventAppend(
    stream: string,
    channel: string,
    maxLen: string,
    stored: string,
    ttl: string,
  ): Promise<string>;
};

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

export function createRedisEventLog(
  redis: Redis,
  opts?: { maxLen?: number; ttlSec?: number },
): EventLog {
  const maxLen = String(opts?.maxLen ?? DEFAULT_MAX_LEN);
  const ttl = String(opts?.ttlSec ?? streamTtlSecFromEnv(process.env));
  const r = redis as AppendCapable;
  if (typeof r.ovidEventAppend !== "function") {
    r.defineCommand("ovidEventAppend", { numberOfKeys: 2, lua: APPEND_LUA });
  }

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
      // XADD → EXPIRE → PUBLISH run as one script (one round trip, atomic),
      // and the envelope is serialized once.
      const id = await r.ovidEventAppend(
        streamKey(sessionId),
        liveChannel(sessionId),
        maxLen,
        JSON.stringify(stored),
        ttl,
      );
      if (typeof id !== "string" || id === "") {
        throw new Error(`XADD returned no id for stream ${streamKey(sessionId)}`);
      }
      return { ...stored, seq: id };
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
        // Hardening (Task 4 review carry-over): this runs inside an
        // EventEmitter listener — an exception thrown here escapes as an
        // uncaughtException and kills the host process (gateway/worker).
        // A malformed published payload is skipped; a throwing consumer loses
        // that one event but the listener survives for the next.
        let event: SessionEvent;
        try {
          event = JSON.parse(message) as SessionEvent;
        } catch {
          return; // garbage on the channel: skip, keep listening
        }
        try {
          onEvent(event);
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
        // Detach first so no message can be delivered mid-teardown.
        sub.off("message", listener);
        await sub.quit().catch(() => {});
      };
    },
  };
}
