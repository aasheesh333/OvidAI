import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { plansRepo, users as usersRepo, type Db } from "@ovid/db";
import type { Redis } from "ioredis";
import { DB2, serializeSettings } from "./planMath.js";
import { getSettings } from "./settings.js";
import { createProjection } from "./projection.js";
import {
  closeDb, closeRedis, openFlushedRedis, resetTestDb, TEST_DATABASE_URL, TEST_MINT_REDIS_URL,
} from "./test/env.js";

/**
 * THE db2 hook contract: what the UNMODIFIED Python hook
 * (server/mint/litellm_hook/ovid_pools.py + server/mint/ovid_plans.py) reads
 * after the TS mint publishes. Every assertion mirrors the Python read path
 * byte-for-byte: field names from the hook's parse_settings, Python
 * str(int) vs str(float) rendering, JSON field names inside `plans`, and the
 * user:{uid}:tier lifetime the hook's find_plan consumes.
 *
 * Requires BOTH TEST_DATABASE_URL and TEST_MINT_REDIS_URL (db9).
 */

const SEED_PLANS_JSON =
  '[{"aliases":[],"auto_oss":false,"enabled":true,"id":"free","mult":1.0,"name":"Free","price_usd":0.0,"slow_mode":false,"window_hours":24},' +
  '{"aliases":["3x"],"auto_oss":false,"enabled":true,"id":"starter","mult":3.0,"name":"Starter","price_usd":5.0,"slow_mode":false,"window_hours":24},' +
  '{"aliases":["7x"],"auto_oss":true,"enabled":true,"id":"pro","mult":23.0,"name":"Pro","price_usd":25.0,"slow_mode":false,"window_hours":24},' +
  '{"aliases":["15x"],"auto_oss":true,"enabled":true,"id":"max","mult":43.0,"name":"Max","price_usd":60.0,"slow_mode":false,"window_hours":24}]';

const SEED_MEMBERS_JSON =
  '[{"model":"glm-5.3-flash","weight":1.0},{"model":"deepseek-v4.1-flash","weight":1.0},{"model":"minimax-m3","weight":1.0}]';

describe.skipIf(!TEST_DATABASE_URL || !TEST_MINT_REDIS_URL)("db2 hook contract", () => {
  let db: Db;
  let redis: Redis;
  let projection: ReturnType<typeof createProjection>;

  beforeAll(async () => {
    db = await resetTestDb();
    redis = await openFlushedRedis();
    projection = createProjection({ db, redis });
    await projection.publishSettings();
  }, 60_000);

  afterAll(async () => {
    await closeDb(db);
    await closeRedis(redis);
  });

  it("config:limits has EXACTLY the 13 field names the hook reads", async () => {
    const hash = await redis.hgetall(DB2.LIMITS_HASH);
    expect(Object.keys(hash).sort()).toEqual([
      "auto_oss_members", "est_image_tokens", "est_input_tokens", "est_output_tokens",
      "free_monthly_cap_usd", "hard_ceiling_mult", "normal_parallel", "normal_rpm",
      "normal_tpm", "plans", "slow_parallel", "slow_rpm", "slow_tpm",
    ]);
  });

  it("the plans field JSON-parses to objects with exactly the pinned ovid_plans fields", async () => {
    const plans = JSON.parse((await redis.hget(DB2.LIMITS_HASH, "plans"))!);
    expect(plans).toHaveLength(4);
    for (const p of plans) {
      expect(Object.keys(p).sort()).toEqual([
        "aliases", "auto_oss", "enabled", "id", "mult", "name", "price_usd", "slow_mode", "window_hours",
      ]);
    }
  });

  it("float-typed scalars parse via parseFloat and are finite", async () => {
    const cap = await redis.hget(DB2.LIMITS_HASH, "free_monthly_cap_usd");
    expect(Number.isFinite(parseFloat(cap!))).toBe(true);
    expect(parseFloat(cap!)).toBe(10);
  });

  it("config:base_daily_usd === '0.15' (Python str(0.15))", async () => {
    expect(await redis.get(DB2.BASE_BUDGET_KEY)).toBe("0.15");
  });

  it("scalar byte-parity: int-typed WITHOUT '.0', float-typed WITH it (Python str())", async () => {
    expect(await redis.hget(DB2.LIMITS_HASH, "normal_rpm")).toBe("240");
    expect(await redis.hget(DB2.LIMITS_HASH, "est_output_tokens")).toBe("600");
    expect(await redis.hget(DB2.LIMITS_HASH, "normal_tpm")).toBe("4000000");
    expect(await redis.hget(DB2.LIMITS_HASH, "slow_parallel")).toBe("2");
    expect(await redis.hget(DB2.LIMITS_HASH, "hard_ceiling_mult")).toBe("3.0");
    expect(await redis.hget(DB2.LIMITS_HASH, "free_monthly_cap_usd")).toBe("10.0");
  });

  it("plans + auto_oss_members are the exact json.dumps byte-image (compact separators)", async () => {
    expect(await redis.hget(DB2.LIMITS_HASH, "plans")).toBe(SEED_PLANS_JSON);
    expect(await redis.hget(DB2.LIMITS_HASH, "auto_oss_members")).toBe(SEED_MEMBERS_JSON);
  });

  it("the published hash is byte-identical to serializeSettings(getSettings())", async () => {
    const { baseDaily, fields } = serializeSettings(await getSettings({ db }));
    expect(await redis.get(DB2.BASE_BUDGET_KEY)).toBe(baseDaily);
    const hash = await redis.hgetall(DB2.LIMITS_HASH);
    expect(hash).toEqual(fields);
  });

  it("publishUserTier('u','7x',now+3600): tier value + EXAT expiry+600 skew", async () => {
    const now = Math.floor(Date.now() / 1000);
    await projection.publishUserTier("u", "7x", now + 3600);
    expect(await redis.get("user:u:tier")).toBe("7x");
    const pttl = await redis.pttl("user:u:tier");
    expect(pttl).toBeGreaterThan(3_590_000);
    expect(pttl).toBeLessThanOrEqual(4_200_000);
    // the durable expiry copy rides the same TTL
    expect(await redis.get("user:u:tier_expires_at")).toBe(String(now + 3600));
    expect(await redis.pttl("user:u:tier_expires_at")).toBeGreaterThan(3_590_000);
  });

  it("publishUserTier free/null → BOTH tier keys deleted", async () => {
    await projection.publishUserTier("u", "7x", Math.floor(Date.now() / 1000) + 3600);
    expect(await redis.get("user:u:tier")).toBe("7x");
    await projection.publishUserTier("u", "free", null);
    expect(await redis.get("user:u:tier")).toBeNull();
    expect(await redis.get("user:u:tier_expires_at")).toBeNull();

    await projection.publishUserTier("u", "7x", Math.floor(Date.now() / 1000) + 3600);
    await projection.publishUserTier("u", null, null);
    expect(await redis.get("user:u:tier")).toBeNull();
    expect(await redis.get("user:u:tier_expires_at")).toBeNull();
  });

  it("publishUserTier paid with no expiry: plain SET (no TTL), expiry key cleared", async () => {
    await projection.publishUserTier("u", "7x", Math.floor(Date.now() / 1000) + 3600);
    await projection.publishUserTier("u", "7x", null);
    expect(await redis.get("user:u:tier")).toBe("7x");
    expect(await redis.pttl("user:u:tier")).toBe(-1);
    expect(await redis.exists("user:u:tier_expires_at")).toBe(0);
  });

  it("publishUserState mirrors the Postgres override + users row into the hook's keys", async () => {
    const uid = "state-u";
    await usersRepo.ensure(db, uid, "state@example.com");
    await plansRepo.saveOverride(db, uid, {
      dailyUsd: "1.25",
      monthlyCapUsd: "2",
      pools: { mult: 2, window_hours: 48, slow_mode: true, auto_oss: false },
    });
    await projection.publishUserState(uid);
    expect(await redis.get(`user:${uid}:dailyUsd`)).toBe("1.25");
    expect(await redis.get(`user:${uid}:monthlyCapUsd`)).toBe("2");
    expect(JSON.parse((await redis.get(`user:${uid}:pools`))!)).toEqual({
      mult: 2, window_hours: 48, slow_mode: true, auto_oss: false,
    });
    expect(await redis.get(`user:${uid}:email`)).toBe("state@example.com");
    expect(await redis.get("email:state@example.com")).toBe(uid);
    expect(await redis.exists(`user:${uid}:banned`)).toBe(0);

    // ban the account → the banned flag publishes with who banned
    await db.$client`UPDATE users SET banned_at = now(), banned_reason = ${"auto"} WHERE uid = ${uid}`;
    await projection.publishUserState(uid);
    expect(await redis.get(`user:${uid}:banned`)).toBe("auto");

    // clearing the override removes its keys (Postgres wins)
    await plansRepo.saveOverride(db, uid, null);
    await projection.publishUserState(uid);
    expect(await redis.exists(`user:${uid}:dailyUsd`)).toBe(0);
    expect(await redis.exists(`user:${uid}:monthlyCapUsd`)).toBe(0);
    expect(await redis.exists(`user:${uid}:pools`)).toBe(0);
  });
});
