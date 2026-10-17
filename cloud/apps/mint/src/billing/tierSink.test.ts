import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { billingUsers, type Db } from "@ovid/db";
import type { Redis } from "ioredis";
import { createProjection } from "../projection.js";
import type { PublishTier } from "./tierSink.js";
import { TIER_SKEW_SECONDS, createTierSink } from "./tierSink.js";
import {
  closeDb,
  closeRedis,
  openFlushedRedis,
  resetTestDb,
  testUid,
  TEST_DATABASE_URL,
  TEST_MINT_REDIS_URL,
} from "../test/env.js";

/**
 * Tier sink: Postgres users.tier FIRST (durable authority), then mint's Redis
 * tier keys with EXAT expiry + 600 s (the self-expiry that keeps a missed RTDN
 * from leaving a paid tier forever), then the LiteLLM budget reapply.
 */

const RUN = TEST_DATABASE_URL !== undefined && TEST_MINT_REDIS_URL !== undefined;

interface Observed {
  uid: string;
  tier: string | null;
  expiresAt: number | null;
  /** users.tier as seen AT publish time — pins the Postgres-first ordering. */
  dbTier: string;
}

describe.skipIf(!RUN)("tierSink (tierSink.ts)", () => {
  let db: Db;
  let redis: Redis;
  let observed: Observed[];
  let reapplied: string[];
  let sink: (uid: string, tier: string, expiresAt: number | null) => Promise<void>;
  let realProjection: ReturnType<typeof createProjection>;

  beforeAll(async () => {
    db = await resetTestDb();
    redis = await openFlushedRedis();
    realProjection = createProjection({ db, redis });
  });

  afterAll(async () => {
    await closeRedis(redis);
    await closeDb(db);
  });

  beforeEach(() => {
    observed = [];
    reapplied = [];
    const projection: PublishTier = {
      publishUserTier: async (uid, tier, expiresAt) => {
        // Observe the Postgres-first ordering, then perform the REAL Redis
        // projection (the brief assigns the EXAT/DEL writes to this method).
        const row = await billingUsers.getTier(db, uid);
        observed.push({ uid, tier, expiresAt, dbTier: row.tier });
        await realProjection.publishUserTier(uid, tier, expiresAt);
      },
    };
    sink = createTierSink({
      db,
      redis,
      projection,
      reapplyUser: async (uid) => {
        reapplied.push(uid);
      },
    });
  });

  it("paid: users.tier first, then Redis EXAT expiry+600, then reapplyUser", async () => {
    const uid = testUid("tier-paid");
    const expiry = Math.floor(Date.now() / 1000) + 3600;
    // Bound the TTL window against the clock BEFORE the write: PTTL is read a
    // few milliseconds later, so comparing with a bound captured afterwards
    // can flake by 1 ms (the key is written EXAT, not relative).
    const before = Date.now();
    await sink(uid, "3x", expiry);

    // Postgres durable copy.
    const row = await billingUsers.getTier(db, uid);
    expect(row.tier).toBe("3x");
    expect(row.tierExpiresAt?.getTime()).toBe(expiry * 1000);

    // Projection ran AFTER the Postgres write (it observed the new tier).
    expect(observed).toEqual([
      { uid, tier: "3x", expiresAt: expiry, dbTier: "3x" },
    ]);

    // Redis tier key + the self-expiry window (Review Focus #3).
    expect(await redis.get(`user:${uid}:tier`)).toBe("3x");
    expect(await redis.get(`user:${uid}:tier_expires_at`)).toBe(String(expiry));
    const ttlMs = await redis.pttl(`user:${uid}:tier`);
    const upperMs = (expiry + TIER_SKEW_SECONDS) * 1000 - before;
    expect(ttlMs).toBeGreaterThan(upperMs - 10_000);
    expect(ttlMs).toBeLessThanOrEqual(upperMs);
    // Both keys carry the same EXAT; the two PTTL calls are milliseconds
    // apart, so allow a tiny read-time delta instead of exact equality.
    const expiryTtlMs = await redis.pttl(`user:${uid}:tier_expires_at`);
    expect(Math.abs(expiryTtlMs - ttlMs)).toBeLessThanOrEqual(5);

    expect(reapplied).toEqual([uid]);
    expect(TIER_SKEW_SECONDS).toBe(600);
  });

  it("free: both Redis keys deleted, tierExpiresAt null, budgets reapplied", async () => {
    const uid = testUid("tier-free");
    await sink(uid, "7x", Math.floor(Date.now() / 1000) + 3600);
    await sink(uid, "free", null);

    expect(await redis.get(`user:${uid}:tier`)).toBeNull();
    expect(await redis.get(`user:${uid}:tier_expires_at`)).toBeNull();
    expect(await redis.pttl(`user:${uid}:tier`)).toBe(-2);
    const row = await billingUsers.getTier(db, uid);
    expect(row.tier).toBe("free");
    expect(row.tierExpiresAt).toBeNull();
    expect(reapplied).toEqual([uid, uid]);
  });

  it("an unknown tier never leaves a paid key (normalized to free)", async () => {
    const uid = testUid("tier-unknown");
    await sink(uid, "99x", Math.floor(Date.now() / 1000) + 3600);
    expect(await redis.get(`user:${uid}:tier`)).toBeNull();
    expect((await billingUsers.getTier(db, uid)).tier).toBe("free");
  });

  it("a paid tier with no expiry gets a plain SET (no TTL), expiry key cleared", async () => {
    const uid = testUid("tier-noexp");
    await sink(uid, "15x", null);
    expect(await redis.get(`user:${uid}:tier`)).toBe("15x");
    expect(await redis.pttl(`user:${uid}:tier`)).toBe(-1);
    expect(await redis.get(`user:${uid}:tier_expires_at`)).toBeNull();
    expect((await billingUsers.getTier(db, uid)).tierExpiresAt).toBeNull();
  });
});
