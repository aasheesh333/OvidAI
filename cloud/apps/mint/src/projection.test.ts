import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { plansRepo, users as usersRepo, type Db } from "@ovid/db";
import type { Redis } from "ioredis";
import { DB2, parseSettings, serializeSettings } from "./planMath.js";
import { getSettings, storeSettings } from "./settings.js";
import { createProjection } from "./projection.js";
import {
  closeDb, closeRedis, openFlushedRedis, resetTestDb, testUid, TEST_DATABASE_URL, TEST_MINT_REDIS_URL,
} from "./test/env.js";

/**
 * The db2 request-time projection: publish / resync (Ruling Q4 — Postgres
 * wins) / user keys / model groups / the one-shot Redis→Postgres import.
 * Requires TEST_DATABASE_URL + TEST_MINT_REDIS_URL (db9, flushed in beforeAll).
 *
 * Test order matters: the resync counting test runs BEFORE any users row
 * exists so the identical-count is deterministic (14 = 13 config:limits
 * fields + config:base_daily_usd); later tests seed users.
 */

const OVID_UIDS_SET = "ovid:uids";

describe.skipIf(!TEST_DATABASE_URL || !TEST_MINT_REDIS_URL)("db2 projection", () => {
  let db: Db;
  let redis: Redis;
  let projection: ReturnType<typeof createProjection>;

  beforeAll(async () => {
    db = await resetTestDb();
    redis = await openFlushedRedis();
    projection = createProjection({ db, redis });
  }, 60_000);

  afterAll(async () => {
    await closeDb(db);
    await closeRedis(redis);
  });

  it("publishSettings round-trips through the hook's wire format", async () => {
    await projection.publishSettings();
    const hash = await redis.hgetall(DB2.LIMITS_HASH);
    const base = await redis.get(DB2.BASE_BUDGET_KEY);
    // what the hook's parse_settings would build === what Postgres holds
    expect(parseSettings(hash, base)).toEqual(await getSettings({ db }));
  });

  it("storeSettings persists to Postgres AND publishes to db2", async () => {
    const s = await getSettings({ db });
    await storeSettings({ db, redis }, { ...s, free_daily_usd: 3, slow_rpm: 7 });
    // int-typed scalar published WITHOUT ".0", float base WITH it
    expect(await redis.hget(DB2.LIMITS_HASH, "slow_rpm")).toBe("7");
    expect(await redis.get(DB2.BASE_BUDGET_KEY)).toBe("3.0");
    expect((await getSettings({ db })).slow_rpm).toBe(7);
    // put them back for the later tests
    await storeSettings({ db, redis }, s);
  });

  it("resyncAtBoot: a hand-corrupted config:limits is overwritten from Postgres (Q4)", async () => {
    await projection.publishSettings();
    const correct = serializeSettings(await getSettings({ db }));

    // corrupt two values the way an operator/half-failed write might
    const corruptedPlans = correct.fields.plans.replace('"mult":23.0', '"mult":99.0');
    await redis.hset(DB2.LIMITS_HASH, "plans", corruptedPlans);
    await redis.set(DB2.BASE_BUDGET_KEY, "9.99");

    const report = await projection.resyncAtBoot();
    expect(report.conflictsResolvedFromPostgres).toBeGreaterThanOrEqual(2);
    expect(report.rewritten).toContain("config:limits.plans");
    expect(report.rewritten).toContain(DB2.BASE_BUDGET_KEY);
    // Postgres won: both values restored byte-exactly
    expect(await redis.hget(DB2.LIMITS_HASH, "plans")).toBe(correct.fields.plans);
    expect(await redis.get(DB2.BASE_BUDGET_KEY)).toBe(correct.baseDaily);

    // a clean second pass: nothing to fix, 14 settings values already identical
    const clean = await projection.resyncAtBoot();
    expect(clean.conflictsResolvedFromPostgres).toBe(0);
    expect(clean.rewritten).toEqual([]);
    expect(clean.identical).toBe(14);
  });

  it("resyncAtBoot counts user keys disagreeing with Postgres and fixes them", async () => {
    const uid = testUid("resync");
    await usersRepo.ensure(db, uid, "resync@example.com");
    await plansRepo.markProvisioned(db, uid); // I4: resync only touches mint users
    await projection.publishUserState(uid); // clean publish first

    // hand-corrupt the user's state (wrong tier + stale dailyUsd)
    await redis.set(`user:${uid}:tier`, "15x");
    await redis.set(`user:${uid}:dailyUsd`, "77");

    const report = await projection.resyncAtBoot();
    expect(report.conflictsResolvedFromPostgres).toBeGreaterThanOrEqual(2);
    expect(report.rewritten).toContain(`user:${uid}:tier`);
    expect(report.rewritten).toContain(`user:${uid}:dailyUsd`);
    // users.tier defaults to free → the tier key is REMOVED (Postgres wins)
    expect(await redis.exists(`user:${uid}:tier`)).toBe(0);
    expect(await redis.exists(`user:${uid}:dailyUsd`)).toBe(0);
    expect(await redis.get(`user:${uid}:email`)).toBe("resync@example.com");
  });

  it("resyncAtBoot re-publishes a paid tier + expiry from the users row", async () => {
    const uid = testUid("tier");
    const expires = Math.floor(Date.now() / 1000) + 3600;
    // raw postgres.js templates bind ISO strings for timestamptz (not Date)
    await db.$client`INSERT INTO users (uid, tier, tier_expires_at) VALUES (${uid}, ${"7x"}, ${new Date(expires * 1000).toISOString()})`;
    await plansRepo.markProvisioned(db, uid); // I4: resync only touches mint users
    const report = await projection.resyncAtBoot();
    expect(report.rewritten).toContain(`user:${uid}:tier`);
    expect(await redis.get(`user:${uid}:tier`)).toBe("7x");
    expect(await redis.get(`user:${uid}:tier_expires_at`)).toBe(String(expires));
    const pttl = await redis.pttl(`user:${uid}:tier`);
    expect(pttl).toBeGreaterThan(3_590_000);
    expect(pttl).toBeLessThanOrEqual(4_200_000);
  });

  it("publishModelGroups writes the sorted JSON array; a no-op when unchanged", async () => {
    await redis.del(DB2.MODEL_GROUPS_KEY);
    await projection.publishModelGroups(["gemini-3.8-flash", "glm-5.3-flash", "auto"]);
    expect(await redis.get(DB2.MODEL_GROUPS_KEY)).toBe('["auto","gemini-3.8-flash","glm-5.3-flash"]');

    // unchanged (any input order) → ZERO set calls (Python catalog_for guard)
    let setCalls = 0;
    const originalSet = redis.set.bind(redis);
    (redis as { set: unknown }).set = ((...args: unknown[]) => {
      setCalls++;
      return originalSet(...(args as Parameters<typeof originalSet>));
    }) as typeof redis.set;
    try {
      await projection.publishModelGroups(["glm-5.3-flash", "auto", "gemini-3.8-flash"]);
      expect(setCalls).toBe(0);
      await projection.publishModelGroups(["auto", "minimax-m3"]);
      expect(setCalls).toBe(1); // changed → exactly one write
    } finally {
      (redis as { set: unknown }).set = originalSet;
    }

    // empty catalog → never wipes the hook's known-set (Python: if cat["groups"])
    await projection.publishModelGroups([]);
    expect(await redis.get(DB2.MODEL_GROUPS_KEY)).toBe('["auto","minimax-m3"]');
  });

  it("importFromRedisOnce: one-shot seeding of Postgres from live db2 (never deletes)", async () => {
    // virgin Postgres + a db2 that looks like the live stack after edits.
    // (fresh db handle AND projection: the resync/test state above is gone)
    await closeDb(db);
    db = await resetTestDb();
    projection = createProjection({ db, redis });
    await redis.flushdb();
    const s = parseSettings({ slow_rpm: "7" }, "0.15");
    const { baseDaily, fields } = serializeSettings(s);
    await redis.hset(DB2.LIMITS_HASH, fields);
    await redis.set(DB2.BASE_BUDGET_KEY, baseDaily);
    await redis.sadd(OVID_UIDS_SET, "imp-1", "imp-2");
    await redis.set("user:imp-1:tier", "7x");
    await redis.set("user:imp-1:email", "imp1@example.com");
    await redis.set("user:imp-2:tier", "3x");
    await redis.set("user:imp-1:dailyUsd", "1.25");
    await redis.set("user:imp-1:pools", '{"mult":2,"window_hours":48,"slow_mode":true,"auto_oss":false}');

    const { imported } = await projection.importFromRedisOnce();
    expect(imported).toEqual({ users: 2, plans: true, settings: true });

    // settings + plans landed in Postgres
    const record = await plansRepo.getSettings(db);
    expect(record?.baseDailyUsd).toBe("0.15");
    expect(record?.scalars.slow_rpm).toBe(7);
    expect((await plansRepo.list(db)).map((r) => r.id)).toEqual(["free", "starter", "pro", "max"]);
    // users + overrides landed
    const u1 = await db.$client`SELECT tier, email FROM users WHERE uid = ${"imp-1"}`;
    expect(u1[0]).toEqual({ tier: "7x", email: "imp1@example.com" });
    const u2 = await db.$client`SELECT tier FROM users WHERE uid = ${"imp-2"}`;
    expect(u2[0]).toEqual({ tier: "3x" });
    const override = await plansRepo.getOverride(db, "imp-1");
    expect(override?.dailyUsd).toBe("1.25");
    expect(override?.pools).toEqual({ mult: 2, window_hours: 48, slow_mode: true, auto_oss: false });

    // Redis is untouched (never deletes; only reads)
    expect(await redis.get(DB2.BASE_BUDGET_KEY)).toBe("0.15");
    expect(await redis.smembers(OVID_UIDS_SET).then((m) => m.sort())).toEqual(["imp-1", "imp-2"]);
    expect(await redis.get("user:imp-1:tier")).toBe("7x");

    // one-shot: a second run imports nothing (rows already exist)
    const again = await projection.importFromRedisOnce();
    expect(again.imported).toEqual({ users: 0, plans: false, settings: false });
  });
});
