import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { Db } from "@ovid/db";
import type { Redis } from "ioredis";
import type { MintDeps } from "./app.js";
import { loadMintEnv } from "./env.js";
import { createLiteLlmAdmin } from "./litellmAdmin.js";
import { findPlan, poolKeys, userPools, type Pools } from "./planMath.js";
import { getSettings, storeSettings } from "./settings.js";
import {
  closeDb,
  closeRedis,
  openFlushedRedis,
  resetTestDb,
  testUid,
  TEST_DATABASE_URL,
  TEST_MINT_REDIS_URL,
} from "./test/env.js";
import { FakeLiteLlm, MASTER_KEY, standardModels } from "./test/litellmFake.js";
import {
  currentWindowStart,
  dropUsageCache,
  effectiveTier,
  freeCapRemaining,
  freeCapUsd,
  hookSpend,
  monthSpent,
  reapplyUser,
  resetWindowUser,
  tierBudget,
  userBudgetTarget,
  windowBounds,
} from "./windows.js";

/**
 * Windows + budget re-application: ports of mint.py's
 * window_bounds/current_window_start/hook_spend/reset_window_user,
 * effective_tier/free_cap_usd/month_spent/tier_budget/user_budget_target and
 * reapply_user (the LiteLLM budget-clock rule), plus the window cases from
 * test_limits.py. Real Postgres (settings authority) + Redis db9 + a local
 * FakeLiteLLM.
 */

const RUN = TEST_DATABASE_URL !== undefined && TEST_MINT_REDIS_URL !== undefined;

describe.skipIf(!RUN)("window machinery (windows.ts)", () => {
  let db: Db;
  let redis: Redis;
  let fake: FakeLiteLlm;
  let deps: MintDeps;

  beforeAll(async () => {
    db = await resetTestDb();
    redis = await openFlushedRedis();
    fake = new FakeLiteLlm();
    await fake.start();
    deps = {
      db,
      redis,
      litellm: createLiteLlmAdmin(fake.baseUrl, MASTER_KEY),
      env: loadMintEnv({
        NODE_ENV: "test",
        DATABASE_URL: TEST_DATABASE_URL!,
        REDIS_DB2_URL: TEST_MINT_REDIS_URL!,
        LITELLM_BASE: fake.baseUrl,
        LITELLM_MASTER_KEY: MASTER_KEY,
        OVID_ADMIN_MASTER_KEY: "sk-admin-test",
        OVID_INTERNAL_API_SECRET: "sk-internal-test",
        FIREBASE_PROJECT_ID: "ovid-test",
        APPCHECK_ENABLED: "false",
        USAGE_CACHE_S: "15",
      }),
      alerter: async () => {},
      verifyIdentity: async () => ({ uid: "unused", email: null, platform: "android" }),
    };
    // seed the settings authority once
    await getSettings({ db });
  }, 60_000);

  afterAll(async () => {
    await fake.stop();
    await closeRedis(redis);
    await closeDb(db);
  });

  beforeEach(() => {
    fake.calls.length = 0;
  });

  afterEach(() => {
    fake.calls.length = 0;
  });

  async function poolsFor(uid: string): Promise<Pools> {
    const s = await getSettings({ db });
    const tier = await redis.get(`user:${uid}:tier`);
    return userPools(s, findPlan(s, tier), s.free_daily_usd, null);
  }

  it("windowBounds creates the start key with NX + TTL≈window and anchors at firstUse", async () => {
    const uid = testUid("win-anchor");
    const pools = await poolsFor(uid);
    expect(pools.window_hours).toBe(24);

    const firstUse = new Date(Date.now() - 3600_000);
    const { start, end } = await windowBounds(deps, uid, pools, { firstUse });

    const k = poolKeys(uid);
    expect(await redis.get(k.start)).toBe(String(Math.floor(firstUse.getTime() / 1000)));
    expect(start.getTime()).toBe(Math.floor(firstUse.getTime() / 1000) * 1000);
    expect(end.getTime() - start.getTime()).toBe(24 * 3600_000);
    const ttl = await redis.pttl(k.start);
    expect(ttl).toBeGreaterThan(23 * 3600_000 - 5000);
    expect(ttl).toBeLessThanOrEqual(24 * 3600_000);
  });

  it("windowBounds is NX: an existing live start is never overwritten", async () => {
    const uid = testUid("win-nx");
    const pools = await poolsFor(uid);
    const k = poolKeys(uid);
    const existing = Math.floor((Date.now() - 600_000) / 1000);
    await redis.set(k.start, String(existing));

    const { start } = await windowBounds(deps, uid, pools, {
      firstUse: new Date(Date.now() - 7200_000),
    });
    expect(await redis.get(k.start)).toBe(String(existing));
    expect(start.getTime()).toBe(existing * 1000);
  });

  it("an expired window is cleared (start/spend/auto) and recreated", async () => {
    const uid = testUid("win-expired");
    const pools = await poolsFor(uid);
    const k = poolKeys(uid);
    await redis.set(k.start, String(Math.floor((Date.now() - 90_000_000) / 1000)));
    await redis.set(k.spend, "9");
    await redis.hset(k.auto, "glm-5.3-flash", "3");

    expect(await currentWindowStart(deps, uid, pools)).toBeNull();
    expect(await redis.get(k.start)).toBeNull();
    expect(await redis.get(k.spend)).toBeNull();
    expect(await redis.hgetall(k.auto)).toEqual({});

    const { start } = await windowBounds(deps, uid, pools);
    expect(start.getTime()).toBeGreaterThan(Date.now() - 5000);
    expect(await redis.get(k.start)).not.toBeNull();
  });

  it("windowBounds create:false reports the would-be window without writing", async () => {
    const uid = testUid("win-nocreate");
    const pools = await poolsFor(uid);
    const k = poolKeys(uid);
    const { start, end } = await windowBounds(deps, uid, pools, { create: false });
    expect(await redis.get(k.start)).toBeNull();
    expect(start.getTime()).toBeLessThanOrEqual(Date.now());
    expect(end.getTime() - start.getTime()).toBe(24 * 3600_000);
  });

  it("hookSpend reads the counter float-or-0 (garbage → 0)", async () => {
    const uid = testUid("win-hookspend");
    const k = poolKeys(uid);
    expect(await hookSpend(deps, uid)).toBe(0);
    await redis.set(k.spend, "0.25");
    expect(await hookSpend(deps, uid)).toBe(0.25);
    await redis.set(k.spend, "not-a-number");
    expect(await hookSpend(deps, uid)).toBe(0);
  });

  it("effectiveTier resolves stored aliases and falls back to free", async () => {
    const uid = testUid("win-tier");
    await redis.set(`user:${uid}:tier`, "7x");
    expect(await effectiveTier(deps, uid)).toBe("pro");
    await redis.set(`user:${uid}:tier`, "3x");
    expect(await effectiveTier(deps, uid)).toBe("starter");
    await redis.set(`user:${uid}:tier`, "bogus");
    expect(await effectiveTier(deps, uid)).toBe("free");
    await redis.del(`user:${uid}:tier`);
    expect(await effectiveTier(deps, uid)).toBe("free");
  });

  it("freeCapUsd honours the per-user override, else the global cap", async () => {
    const uid = testUid("win-freecap");
    expect(await freeCapUsd(deps, uid)).toBe(10);
    await redis.set(`user:${uid}:monthlyCapUsd`, "4.5");
    expect(await freeCapUsd(deps, uid)).toBe(4.5);
  });

  it("monthSpent reads /user/info and fails soft to 0", async () => {
    const uid = testUid("win-monthspent");
    fake.users.set(uid, { spend: 2.5, budget_duration: "30d" });
    expect(await monthSpent(deps, uid)).toBe(2.5);
    expect(await freeCapRemaining(deps, uid)).toBe(7.5);

    fake.failUserInfo = true;
    try {
      expect(await monthSpent(deps, uid)).toBe(0);
    } finally {
      fake.failUserInfo = false;
    }
    expect(await monthSpent(deps, testUid("win-nouser"))).toBe(0);
  });

  it("tierBudget / userBudgetTarget: free uses the monthly cap and 30d", async () => {
    const uid = testUid("win-budget");
    await redis.set(`user:${uid}:tier`, "7x");
    expect(await tierBudget(deps, uid, "7x")).toEqual({ budget: 3.45, duration: "24h" });
    expect(await userBudgetTarget(deps, uid, "7x")).toEqual({ budget: 3.45, duration: "24h" });
    expect(await userBudgetTarget(deps, uid, "free")).toEqual({ budget: 10, duration: "30d" });

    await redis.set(`user:${uid}:monthlyCapUsd`, "4.5");
    expect(await userBudgetTarget(deps, uid, "free")).toEqual({ budget: 4.5, duration: "30d" });
  });

  it("tierBudget applies the slow-mode hard ceiling", async () => {
    const original = await getSettings({ db });
    try {
      await storeSettings({ db, redis }, {
        ...original,
        plans: original.plans.map((p) => (p.id === "pro" ? { ...p, slow_mode: true } : p)),
      });
      expect((await tierBudget(deps, testUid("win-slow"), "pro")).budget).toBe(10.35);
    } finally {
      await storeSettings({ db, redis }, original);
    }
  });

  it("reapplyUser sends budget_duration ONLY when it changes (budget-clock rule)", async () => {
    const uid = testUid("win-reapply");
    await redis.set(`user:${uid}:tier`, "7x");
    await redis.set(`user:${uid}:keyid`, "tok-android");
    await redis.set(`user:${uid}:web:keyid`, "tok-web");
    fake.addKey("tok-android");
    fake.addKey("tok-web");
    fake.users.set(uid, { spend: 0, budget_duration: "24h" });

    expect(await reapplyUser(deps, uid)).toEqual({ keys: 2, errors: 0 });
    let updates = fake.posts("/key/update");
    expect(updates).toHaveLength(2);
    for (const u of updates) {
      expect(u.max_budget).toBe(3.45);
      expect(u.rpm_limit).toBe(240);
      expect(u.tpm_limit).toBe(4_000_000);
      expect(u.max_parallel_requests).toBe(16);
      expect("budget_duration" in u).toBe(false);
    }
    expect(fake.posts("/user/update")).toEqual([{ user_id: uid, max_budget: 3.45 }]);

    // second call: still no budget_duration (the clock is untouched)
    await reapplyUser(deps, uid);
    updates = fake.posts("/key/update").slice(2);
    for (const u of updates) expect("budget_duration" in u).toBe(false);
    expect(fake.posts("/user/update").slice(1)).toEqual([{ user_id: uid, max_budget: 3.45 }]);

    // duration changed → it is sent
    for (const key of fake.keys.values()) key.budget_duration = "1h";
    fake.users.get(uid)!.budget_duration = "1h";
    await reapplyUser(deps, uid);
    for (const u of fake.posts("/key/update").slice(4)) expect(u.budget_duration).toBe("24h");
    expect(fake.posts("/user/update").slice(2)[0].budget_duration).toBe("24h");

    // forceDuration (a window reset) always restarts the clock
    await reapplyUser(deps, uid, { forceDuration: true });
    for (const u of fake.posts("/key/update").slice(6)) expect(u.budget_duration).toBe("24h");

    await reapplyUser(deps, uid, { userForceDuration: true, userExtra: { spend: 0 } });
    expect(fake.posts("/user/update").at(-1)).toMatchObject({
      user_id: uid,
      max_budget: 3.45,
      budget_duration: "24h",
      spend: 0,
    });
  });

  it("reapplyUser leaves the budget clock alone when /user/info is down (unknown)", async () => {
    const uid = testUid("win-reapply-down");
    await redis.set(`user:${uid}:keyid`, "tok-down");
    fake.addKey("tok-down");
    fake.failUserInfo = true;
    try {
      await reapplyUser(deps, uid);
    } finally {
      fake.failUserInfo = false;
    }
    expect("budget_duration" in fake.posts("/user/update").at(-1)!).toBe(false);
  });

  it("resetWindowUser restarts the window, zeroes key spend, keeps the free monthly clock", async () => {
    const uid = testUid("win-reset");
    const k = poolKeys(uid);
    const month = new Date().toISOString().slice(0, 7);
    await redis.set(`user:${uid}:keyid`, "tok-reset");
    await redis.set(k.spend, "0.5");
    await redis.hset(k.auto, "glm-5.3-flash", "3");
    await redis.set(`usagecache:${uid}`, JSON.stringify({ cached: true }));
    await redis.hset("pools:slow", uid, "9999999999");
    await redis.sadd("pools:slow_pending", uid);
    await redis.set(`freecap:${uid}:${month}`, "1");
    fake.addKey("tok-reset", { spend: 0.5 });
    fake.users.set(uid, { spend: 5, budget_duration: "30d" });

    expect(await resetWindowUser(deps, uid)).toEqual({ keys: 1, errors: 0 });

    const start = Number(await redis.get(k.start));
    expect(Math.abs(start - Date.now() / 1000)).toBeLessThan(5);
    expect(await redis.get(k.spend)).toBeNull();
    expect(await redis.hgetall(k.auto)).toEqual({});
    expect(await redis.get(`usagecache:${uid}`)).toBeNull();
    expect(await redis.hget("pools:slow", uid)).toBeNull();
    expect(await redis.sismember("pools:slow_pending", uid)).toBe(0);
    expect(await redis.get(`freecap:${uid}:${month}`)).toBeNull();

    const keyUpdate = fake.posts("/key/update").at(-1)!;
    expect(keyUpdate).toMatchObject({ key: "tok-reset", max_budget: 0.15, spend: 0, budget_duration: "24h" });
    // free plan: the 30d user budget clock is NOT restarted and spend is untouched
    expect(fake.posts("/user/update").at(-1)).toEqual({ user_id: uid, max_budget: 10 });
  });

  it("resetWindowUser resetMonthFree restarts the free user budget clock too", async () => {
    const uid = testUid("win-reset-month");
    await redis.set(`user:${uid}:keyid`, "tok-reset-month");
    fake.addKey("tok-reset-month");
    fake.users.set(uid, { spend: 5, budget_duration: "30d" });

    await resetWindowUser(deps, uid, { resetMonthFree: true });

    expect(fake.posts("/user/update").at(-1)).toMatchObject({
      user_id: uid,
      max_budget: 10,
      budget_duration: "30d",
      spend: 0,
    });
  });

  it("resetWindowUser uses forceDuration for a paid user's window budget", async () => {
    const uid = testUid("win-reset-paid");
    await redis.set(`user:${uid}:tier`, "7x");
    await redis.set(`user:${uid}:keyid`, "tok-reset-paid");
    fake.addKey("tok-reset-paid");
    fake.users.set(uid, { spend: 0, budget_duration: "24h" });

    await resetWindowUser(deps, uid);

    expect(fake.posts("/key/update").at(-1)).toMatchObject({
      key: "tok-reset-paid",
      max_budget: 3.45,
      spend: 0,
      budget_duration: "24h",
    });
    expect(fake.posts("/user/update").at(-1)).toMatchObject({
      user_id: uid,
      max_budget: 3.45,
      budget_duration: "24h",
      spend: 0,
    });
  });

  it("dropUsageCache deletes only the named users' caches", async () => {
    const a = testUid("win-cache-a");
    const b = testUid("win-cache-b");
    await redis.set(`usagecache:${a}`, "{}");
    await redis.set(`usagecache:${b}`, "{}");
    await dropUsageCache(deps, [a]);
    expect(await redis.get(`usagecache:${a}`)).toBeNull();
    expect(await redis.get(`usagecache:${b}`)).toBe("{}");
  });
});
