import { afterAll, beforeAll, describe, expect, it } from "vitest";
import Redis from "ioredis";
import type { SessionEvent } from "@ovid/shared";
import { createRedisEventLog } from "./eventLog.js";

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

// Unique session ids per test run so leftover data from previous runs can
// never collide (shared dev redis — FLUSHDB is forbidden).
let counter = 0;
function sid(): string {
  counter += 1;
  return `t4-${Date.now().toString(36)}-${counter}-${Math.random()
    .toString(36)
    .slice(2, 10)}`;
}

const streamKey = (sessionId: string): string => `sess:${sessionId}:events`;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(cond: () => boolean, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!cond()) {
    if (Date.now() >= deadline) {
      throw new Error("waitFor: condition not met before timeout");
    }
    await sleep(25);
  }
}

// Stream ids are "ms-seq": numeric compare on both parts (same scheme the
// gateway uses for replay/live dedupe).
function cmpSeq(a: string, b: string): number {
  const [aMs, aSeq] = a.split("-").map(Number);
  const [bMs, bSeq] = b.split("-").map(Number);
  if (aMs !== bMs) return aMs < bMs ? -1 : 1;
  if (aSeq !== bSeq) return aSeq < bSeq ? -1 : 1;
  return 0;
}

describe.skipIf(!TEST_REDIS_URL)("eventLog against real redis", () => {
  let redis: Redis;
  const createdSids: string[] = [];

  function newSid(): string {
    const s = sid();
    createdSids.push(s);
    return s;
  }

  beforeAll(() => {
    redis = new Redis(TEST_REDIS_URL!);
  });

  afterAll(async () => {
    // Clean up only the keys this suite created.
    if (createdSids.length > 0) {
      await redis.del(createdSids.map(streamKey));
    }
    await redis.quit();
  });

  it("append returns a full SessionEvent with increasing stream-id seqs", async () => {
    const log = createRedisEventLog(redis);
    const s = newSid();

    const e1 = await log.append(s, "run_started", { runId: "run-1" });
    const e2 = await log.append(s, "message_delta", { text: "hello" });

    expect(e1.seq).toMatch(/^\d+-\d+$/); // seq = Redis Stream id
    expect(cmpSeq(e2.seq, e1.seq)).toBe(1); // strictly increasing
    expect(e1).toEqual({
      sessionId: s,
      seq: e1.seq,
      type: "run_started",
      payload: { runId: "run-1" },
      ts: e1.ts,
    });
    expect(e2).toEqual({
      sessionId: s,
      seq: e2.seq,
      type: "message_delta",
      payload: { text: "hello" },
      ts: e2.ts,
    });
    // ts is an ISO-8601 UTC string
    expect(e1.ts).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
    expect(new Date(e1.ts).toISOString()).toBe(e1.ts);
  });

  it("append refreshes a TTL on the stream (time-based retention); ttlSec 0 disables it", async () => {
    const s = newSid();
    await createRedisEventLog(redis, { ttlSec: 3600 }).append(s, "run_started", { runId: "r" });
    const ttl = await redis.ttl(streamKey(s));
    expect(ttl).toBeGreaterThan(3500);
    expect(ttl).toBeLessThanOrEqual(3600);

    const s2 = newSid();
    await createRedisEventLog(redis, { ttlSec: 0 }).append(s2, "run_started", { runId: "r" });
    expect(await redis.ttl(streamKey(s2))).toBe(-1);
  });

  it("the published envelope equals the returned event (seq spliced in by the script)", async () => {
    const log = createRedisEventLog(redis);
    const s = newSid();
    const got: SessionEvent[] = [];
    const unsubscribe = await log.subscribe(s, (e) => got.push(e));
    try {
      const sent = await log.append(s, "message_delta", {
        runId: "r",
        text: 'quote " brace } unicode é \u{1F600}',
      });
      await waitFor(() => got.length === 1);
      expect(got[0]).toEqual(sent);
      // A second log on the same connection reuses the defined command.
      const again = await createRedisEventLog(redis).append(s, "run_completed", { runId: "r" });
      await waitFor(() => got.length === 2);
      expect(got[1]).toEqual(again);
    } finally {
      await unsubscribe();
    }
  });

  it("readSince(null) replays all events in order; readSince(seq) excludes that seq; limit caps", async () => {
    const log = createRedisEventLog(redis);
    const s = newSid();

    const a = await log.append(s, "run_started", { runId: "r" });
    const b = await log.append(s, "message_delta", { text: "one" });
    const c = await log.append(s, "run_completed", { runId: "r" });

    const all = await log.readSince(s, null, 100);
    expect(all).toEqual([a, b, c]); // full envelopes round-trip through the stream

    const afterA = await log.readSince(s, a.seq, 100);
    expect(afterA).toEqual([b, c]); // a.seq itself is excluded

    const afterB = await log.readSince(s, b.seq, 100);
    expect(afterB).toEqual([c]);

    const afterLast = await log.readSince(s, c.seq, 100);
    expect(afterLast).toEqual([]);

    const capped = await log.readSince(s, null, 2);
    expect(capped).toEqual([a, b]);

    // non-positive limit → empty window, no redis COUNT syntax error
    expect(await log.readSince(s, null, 0)).toEqual([]);

    // unknown session → empty replay, no throw
    expect(await log.readSince(newSid(), null, 100)).toEqual([]);
  });

  it("subscribe delivers appended events live, per session only", async () => {
    const log = createRedisEventLog(redis);
    const sA = newSid();
    const sB = newSid();
    const gotA: SessionEvent[] = [];
    const gotB: SessionEvent[] = [];

    const unsubA = await log.subscribe(sA, (e) => gotA.push(e));
    const unsubB = await log.subscribe(sB, (e) => gotB.push(e));
    try {
      const e1 = await log.append(sA, "message_delta", { text: "live-1" });
      const e2 = await log.append(sA, "message_completed", {
        messageId: "m1",
        role: "assistant",
      });

      await waitFor(() => gotA.length === 2);
      expect(gotA).toEqual([e1, e2]); // live delivery in order, seq/ts included

      // channel isolation: session B's subscriber must see none of A's events
      await sleep(100);
      expect(gotB).toEqual([]);
    } finally {
      await unsubA();
      await unsubB();
    }
  });

  it("unsubscribe stops delivery", async () => {
    const log = createRedisEventLog(redis);
    const s = newSid();
    const got: SessionEvent[] = [];

    const unsub = await log.subscribe(s, (e) => got.push(e));
    const first = await log.append(s, "message_delta", { text: "before" });
    await waitFor(() => got.length === 1);
    expect(got[0]).toEqual(first);

    await unsub();
    const second = await log.append(s, "message_delta", { text: "after" });
    await sleep(200); // give any stray delivery time to arrive
    expect(got).toEqual([first]); // nothing delivered after unsubscribe
    expect(cmpSeq(second.seq, first.seq)).toBe(1);

    await unsub(); // idempotent: second call must not throw
  });

  it("trims the stream toward maxLen, keeping the newest events", async () => {
    const log = createRedisEventLog(redis, { maxLen: 5 });
    const s = newSid();

    for (let i = 0; i < 12; i++) {
      await log.append(s, "message_delta", { i });
    }

    const all = await log.readSince(s, null, 100);
    expect(all.length).toBeLessThanOrEqual(6); // approximate-trim tolerance
    expect(all.length).toBeGreaterThanOrEqual(5); // a no-trim implementation fails here
    expect(all[all.length - 1].payload).toEqual({ i: 11 }); // newest survives
  });

  // Task 4 review carry-over, promoted into Task 8: the pub/sub listener must
  // never let a malformed published payload or a throwing consumer callback
  // escape — an exception thrown inside an EventEmitter listener surfaces as
  // an uncaughtException and kills the host process (gateway/worker).

  it("malformed payload on the live channel is skipped; later events still delivered", async () => {
    const log = createRedisEventLog(redis);
    const s = newSid();
    const got: SessionEvent[] = [];

    const unsub = await log.subscribe(s, (e) => got.push(e));
    try {
      // Raw garbage straight onto the channel (bypasses append's JSON).
      await redis.publish(`sess:${s}:live`, "{{{ not json at all");
      await redis.publish(`sess:${s}:live`, "");
      await redis.publish(`sess:${s}:live`, '["truncated"');

      // The listener must still be alive and delivering afterwards.
      const e1 = await log.append(s, "message_delta", { text: "after-garbage" });
      await waitFor(() => got.length === 1);
      expect(got[0]).toEqual(e1);
    } finally {
      await unsub();
    }
  });

  it("an onEvent that throws on one event still receives the next", async () => {
    const log = createRedisEventLog(redis);
    const s = newSid();
    const got: SessionEvent[] = [];

    const unsub = await log.subscribe(s, (e) => {
      got.push(e);
      if (got.length === 1) throw new Error("consumer boom");
    });
    try {
      const e1 = await log.append(s, "message_delta", { text: "first" });
      await waitFor(() => got.length === 1);

      // The throwing consumer must not have knocked out the listener:
      const e2 = await log.append(s, "message_delta", { text: "second" });
      await waitFor(() => got.length === 2);
      expect(got).toEqual([e1, e2]);
    } finally {
      await unsub();
    }
  });
});
