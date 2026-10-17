import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { Redis } from "ioredis";

import {
  ACTIVITY_KEY_PREFIX,
  ACTIVITY_TTL_SECONDS,
  createActivityTracker,
} from "./activity.js";

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

// ---------------------------------------------------------------------------
// Pure tests against the structural redis interface — a recording fake pins
// the MGET batching (batches of 500) without needing a server.
// ---------------------------------------------------------------------------

describe("createActivityTracker (fake redis)", () => {
  const PREFIX = "fake-act:";

  function fakeRedis(overrides?: {
    mget?: (...ks: string[]) => Promise<Array<string | null>>;
  }) {
    const mgetCalls: string[][] = [];
    const setCalls: Array<{ key: string; value: string; mode: string; ttl: number }> = [];
    return {
      mgetCalls,
      setCalls,
      redis: {
        async set(key: string, value: string, mode: string, ttl: number) {
          setCalls.push({ key, value, mode, ttl });
          return 1;
        },
        async get(_key: string) {
          return null;
        },
        mget:
          overrides?.mget ??
          (async (...ks: string[]) => {
            mgetCalls.push(ks);
            return ks.map(() => "1000");
          }),
      },
    };
  }

  it("bump issues SET <key> <epoch-ms> EX <ttl> with the composed key", async () => {
    const { redis, setCalls } = fakeRedis();
    const tracker = createActivityTracker(redis, {
      keyPrefix: PREFIX,
      ttlSeconds: 60,
      clock: () => new Date(1_234_567),
    });
    await tracker.bump("s1");
    expect(setCalls).toEqual([
      { key: `${PREFIX}s1`, value: "1234567", mode: "EX", ttl: 60 },
    ]);
  });

  it("readMany batches MGET in chunks of 500 and maps values back by session id", async () => {
    const { redis, mgetCalls } = fakeRedis();
    const tracker = createActivityTracker(redis, { keyPrefix: PREFIX });
    const ids = Array.from({ length: 501 }, (_, i) => `s${i}`);

    const result = await tracker.readMany(ids);

    expect(mgetCalls.length).toBe(2);
    expect(mgetCalls[0].length).toBe(500);
    expect(mgetCalls[1].length).toBe(1);
    expect(mgetCalls[0][0]).toBe(`${PREFIX}s0`);
    expect(mgetCalls[1][0]).toBe(`${PREFIX}s500`);
    expect(result.size).toBe(501);
    expect(result.get("s0")).toBe(1000);
    expect(result.get("s500")).toBe(1000);
  });

  it("readMany maps missing (null) values to absent Map entries", async () => {
    const { redis } = fakeRedis({
      mget: async () => [null, "42", null],
    });
    const tracker = createActivityTracker(redis, { keyPrefix: PREFIX });
    const result = await tracker.readMany(["a", "b", "c"]);
    expect(result.size).toBe(1);
    expect(result.get("b")).toBe(42);
  });

  it("readMany of an empty list never calls MGET and returns an empty Map", async () => {
    const { redis, mgetCalls } = fakeRedis();
    const tracker = createActivityTracker(redis, { keyPrefix: PREFIX });
    const result = await tracker.readMany([]);
    expect(result.size).toBe(0);
    expect(mgetCalls.length).toBe(0); // MGET with zero keys is a redis protocol error
  });
});

// ---------------------------------------------------------------------------
// Real redis. Parallel test suites share the dev redis, so every key this
// suite creates lives under a run-unique prefix and is deleted in afterAll
// (shared dev redis — FLUSHDB and other suites' keys are off-limits).
// ---------------------------------------------------------------------------

describe.skipIf(!TEST_REDIS_URL)("activity tracker against real redis", () => {
  const KEY_PREFIX = `ovid-test-activity-${Date.now().toString(36)}-${Math.random()
    .toString(36)
    .slice(2, 10)}:`;
  let redis: Redis;
  const createdKeys: string[] = [];

  function newSid(): string {
    const s = `t7-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
    createdKeys.push(`${KEY_PREFIX}${s}`);
    return s;
  }

  beforeAll(() => {
    redis = new Redis(TEST_REDIS_URL!);
  });

  afterAll(async () => {
    // Clean up only the keys this suite created.
    if (createdKeys.length > 0) {
      await redis.del(...createdKeys).catch(() => {});
    }
    await redis.quit();
  });

  it("bump then read round-trips the injected clock's exact epoch ms", async () => {
    const tracker = createActivityTracker(redis, {
      keyPrefix: KEY_PREFIX,
      clock: () => new Date(1_234_567_890_123),
    });
    const s = newSid();
    await tracker.bump(s);
    expect(await tracker.read(s)).toBe(1_234_567_890_123);
  });

  it("applies the default key prefix and default clock when no options are given", async () => {
    const tracker = createActivityTracker(redis);
    const s = newSid();
    createdKeys.push(`${ACTIVITY_KEY_PREFIX}${s}`);
    const before = Date.now();
    await tracker.bump(s);
    const ms = await tracker.read(s);
    expect(ms).not.toBeNull();
    expect(ms!).toBeGreaterThanOrEqual(before);
    expect(ms!).toBeLessThanOrEqual(Date.now());
    // The value really sits at the spec-pinned key (shared redis: unique sid).
    expect(await redis.get(`${ACTIVITY_KEY_PREFIX}${s}`)).toBe(String(ms));
    expect(ACTIVITY_KEY_PREFIX).toBe("ovid:activity:");
  });

  it("read of a session with no key (missing or evicted) is null", async () => {
    const tracker = createActivityTracker(redis, { keyPrefix: KEY_PREFIX });
    expect(await tracker.read("never-bumped-t7")).toBeNull();
  });

  it("bump sets a TTL — PTTL is positive and bounded by ACTIVITY_TTL_SECONDS", async () => {
    const tracker = createActivityTracker(redis, {
      keyPrefix: KEY_PREFIX,
      clock: () => new Date(),
    });
    const s = newSid();
    await tracker.bump(s);
    const pttl = await redis.pttl(`${KEY_PREFIX}${s}`);
    expect(pttl).toBeGreaterThan(0);
    expect(pttl).toBeLessThanOrEqual(ACTIVITY_TTL_SECONDS * 1000);
    expect(ACTIVITY_TTL_SECONDS).toBe(604_800); // 7 d, refreshed on bump
  });

  it("bump twice refreshes the timestamp under a ttlSeconds override", async () => {
    let now = 5_000_000;
    const tracker = createActivityTracker(redis, {
      keyPrefix: KEY_PREFIX,
      ttlSeconds: 120,
      clock: () => new Date(now),
    });
    const s = newSid();
    await tracker.bump(s);
    now = 6_000_000;
    await tracker.bump(s);
    expect(await tracker.read(s)).toBe(6_000_000);
    const pttl = await redis.pttl(`${KEY_PREFIX}${s}`);
    expect(pttl).toBeGreaterThan(0);
    expect(pttl).toBeLessThanOrEqual(120_000);
  });

  it("readMany over 3 ids (one missing) returns a Map without the missing key", async () => {
    const tracker = createActivityTracker(redis, {
      keyPrefix: KEY_PREFIX,
      clock: () => new Date(9_999_000),
    });
    const a = newSid();
    const missing = newSid();
    const b = newSid();
    await tracker.bump(a);
    await tracker.bump(b);

    const result = await tracker.readMany([a, missing, b]);
    expect(result.size).toBe(2);
    expect(result.get(a)).toBe(9_999_000);
    expect(result.get(b)).toBe(9_999_000);
    expect(result.has(missing)).toBe(false);
  });
});
