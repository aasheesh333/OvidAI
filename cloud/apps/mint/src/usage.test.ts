import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { plansRepo, users as usersRepo, type Db } from "@ovid/db";
import type { Redis } from "ioredis";
import type { FastifyInstance } from "fastify";
import type { MintDeps } from "./app.js";
import { buildMintApps } from "./app.js";
import { availableModels, catalogFor } from "./catalog.js";
import { loadMintEnv } from "./env.js";
import { createLiteLlmAdmin } from "./litellmAdmin.js";
import { findPlan, poolKeys, poolState, userPools } from "./planMath.js";
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
import { computeUsage, modelEstimates, registerUsageRoutes } from "./usage.js";
import { dropUsageCache, resetWindowUser } from "./windows.js";

/**
 * /usage contract port: test_usage.py's body field set, README example
 * numbers, auto attribution, image counting/pricing, per-model remaining,
 * the single allowance pool, the free monthly backstop and the 15 s cache.
 * Real Postgres + Redis db9 + a local FakeLiteLLM.
 */

const RUN = TEST_DATABASE_URL !== undefined && TEST_MINT_REDIS_URL !== undefined;

const BODY_KEYS = [
  "tier", "is_paid", "daily_spent_usd", "daily_budget_usd", "daily_remaining_usd",
  "month_free_spent_usd", "month_free_cap_usd", "requests_today", "budget_window",
  "remaining_pct", "plan", "plan_name", "window", "resets_at", "today",
  "remaining_fraction", "pools", "models",
];

describe.skipIf(!RUN)("POST /usage (usage.ts)", () => {
  let db: Db;
  let redis: Redis;
  let fake: FakeLiteLlm;
  let deps: MintDeps;
  let app: FastifyInstance;

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
        APPCHECK_ENABLED: "true",
        USAGE_CACHE_S: "15",
      }),
      alerter: async () => {},
      verifyIdentity: async ({ authorization }) => {
        const token = authorization.replace(/^bearer\s+/i, "");
        return { uid: token, email: null, platform: "android" };
      },
    };
    app = buildMintApps(deps).publicApp;
    await getSettings({ db });
    standardModels(fake);
  }, 60_000);

  afterAll(async () => {
    await app.close();
    await fake.stop();
    await closeRedis(redis);
    await closeDb(db);
  });

  /** Register a user with android+web keys in Redis + the fake. */
  async function user(uid: string, tier: string | null = null): Promise<{ android: string; web: string }> {
    const android = `tok-${uid}-a`;
    const web = `tok-${uid}-w`;
    await usersRepo.ensure(db, uid, null); // overrides carry an FK to users
    fake.addKey(android);
    fake.addKey(web);
    await redis.set(`user:${uid}:keyid`, android);
    await redis.set(`user:${uid}:web:keyid`, web);
    if (tier !== null && tier !== "free") await redis.set(`user:${uid}:tier`, tier);
    fake.users.set(uid, { spend: 0, budget_duration: "24h" });
    return { android, web };
  }

  async function getUsage(uid: string): Promise<Record<string, unknown>> {
    const res = await app.inject({
      method: "POST",
      url: "/usage",
      headers: { authorization: `Bearer ${uid}`, "x-firebase-appcheck": "x" },
    });
    expect(res.statusCode).toBe(200);
    return res.json() as Record<string, unknown>;
  }

  it("401 shapes: missing bearer id token / missing app check token", async () => {
    const noAuth = await app.inject({ method: "POST", url: "/usage" });
    expect(noAuth.statusCode).toBe(401);
    expect(noAuth.json()).toEqual({ detail: "missing bearer id token" });

    const basic = await app.inject({
      method: "POST",
      url: "/usage",
      headers: { authorization: "Basic abc" },
    });
    expect(basic.statusCode).toBe(401);
    expect(basic.json()).toEqual({ detail: "missing bearer id token" });

    const noAppCheck = await app.inject({
      method: "POST",
      url: "/usage",
      headers: { authorization: "Bearer someone" },
    });
    expect(noAppCheck.statusCode).toBe(401);
    expect(noAppCheck.json()).toEqual({ detail: "missing app check token" });
  });

  it("pro fixture reproduces the README example numbers and EXACT field set", async () => {
    const uid = testUid("usage-pro");
    const keys = await user(uid, "7x");
    fake.addLog(keys.android, "prov/glm-5.3-flash", {
      group: "glm-5.3-flash", pin: 21000, pout: 5200, spend: 0.5,
    });
    fake.addLog(keys.android, "prov/img-1", {
      group: "ovid-image", pin: 40, pout: 0, spend: 0.5, callType: "aimage_generation",
    });
    fake.addLog(keys.web, "prov/minimax-m3", {
      group: "auto", pin: 9000, pout: 1800, spend: 0.5,
    });
    fake.addLog(keys.web, "prov/gemini-3.8-flash", {
      group: "gemini-3.8-flash", pin: 4000, pout: 900, spend: 0.34,
    });
    // The hook rewrote one auto request to minimax-m3; LiteLLM logged it
    // under the member name.
    await redis.hset(poolKeys(uid).auto, "minimax-m3", "1");

    const body = await getUsage(uid);

    expect(Object.keys(body).sort()).toEqual([...BODY_KEYS].sort());
    expect(body.tier).toBe("7x");
    expect(body.is_paid).toBe(true);
    expect(body.plan).toBe("pro");
    expect(body.plan_name).toBe("Pro");
    expect(body.window).toBe("24h");
    expect(body.budget_window).toBe("24h");
    expect(body.daily_spent_usd).toBe(1.84);
    expect(body.daily_budget_usd).toBe(3.45);
    expect(body.daily_remaining_usd).toBe(1.61);
    expect(body.month_free_spent_usd).toBe(0);
    expect(body.month_free_cap_usd).toBe(10);
    expect(body.requests_today).toBe(4);
    expect(body.remaining_pct).toBe(0.4667);
    expect(body.remaining_fraction).toBe(0.4667);
    expect(typeof body.resets_at).toBe("string");
    expect(body.resets_at).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    expect(body.resets_at).not.toContain("+00:00");
    expect(body.pools).toEqual([
      {
        class: "all",
        remaining_fraction: 0.4667,
        resets_at: body.resets_at,
        slow_mode: false,
      },
    ]);
    expect(body.today).toEqual({
      requests: 4,
      input_tokens: 34040,
      output_tokens: 7900,
      images: 1,
      auto_requests: 1,
      by_model: {
        "glm-5.3-flash": {
          requests: 1, input_tokens: 21000, output_tokens: 5200, images: 0, via_auto: 0,
        },
        "ovid-image": {
          requests: 1, input_tokens: 40, output_tokens: 0, images: 1, via_auto: 0,
        },
        "minimax-m3": {
          requests: 1, input_tokens: 9000, output_tokens: 1800, images: 0, via_auto: 1,
        },
        "gemini-3.8-flash": {
          requests: 1, input_tokens: 4000, output_tokens: 900, images: 0, via_auto: 0,
        },
      },
    });
    expect(JSON.stringify(body)).not.toContain("auto-oss");
  });

  it("models[]: README per-model remaining, auto conservative members, image and unpriced rows", async () => {
    const uid = testUid("usage-models");
    const keys = await user(uid, "7x");
    // Spend 1.84 of the 3.45 allowance so the README remaining numbers apply.
    fake.addLog(keys.android, "prov/glm-5.3-flash", { group: "glm-5.3-flash", spend: 1.84 });
    const body = await getUsage(uid);
    const models = body.models as Record<string, unknown>[];
    const byId = Object.fromEntries(models.map((m) => [m.id as string, m]));

    expect(byId["auto"]).toMatchObject({
      id: "auto",
      name: "auto",
      kind: "chat",
      auto: true,
      estimate: "conservative",
      members: ["deepseek-v4.1-flash", "glm-5.3-flash", "minimax-m3"],
      priced: true,
      slow_mode: false,
      remaining_messages: 1610,
      model: "auto",
      input_cost_per_token: 2.5e-7,
      output_cost_per_token: 2e-6,
      remaining_pct: 0.4667,
    });
    expect(byId["big-pro"].remaining_messages).toBe(73);
    expect(byId["glm-5.3-flash"].remaining_messages).toBe(1829);
    expect(byId["ovid-image"]).toMatchObject({
      kind: "image",
      estimate: "typical",
      remaining_images: 40,
      input_cost_per_token: null,
      output_cost_per_token: null,
    });
    expect("remaining_messages" in byId["ovid-image"]).toBe(false);
    expect(byId["mystery"]).toMatchObject({ priced: false, remaining_messages: null });
    for (const m of models) expect(m.remaining_pct).toBe(0.4667);

    // sort: auto first, chat before image, then name
    expect(models[0].id).toBe("auto");
    expect(models[models.length - 1].id).toBe("ovid-image");
    const chatNames = models
      .slice(1)
      .filter((m) => m.kind === "chat")
      .map((m) => m.name as string);
    expect(chatNames).toEqual([...chatNames].sort((a, b) => (a.toLowerCase() < b.toLowerCase() ? -1 : 1)));
  });

  it("auto attribution: hook auto hits are capped at requests − via_auto", async () => {
    const uid = testUid("usage-auto");
    const keys = await user(uid, "pro");
    for (let i = 0; i < 3; i += 1) {
      fake.addLog(keys.web, "prov/glm-5.3-flash", { group: "glm-5.3-flash" });
    }
    await redis.hset(poolKeys(uid).auto, "glm-5.3-flash", "2");
    await redis.hset(poolKeys(uid).auto, "deepseek-v4.1-flash", "9"); // no rows → ignored
    const body = await getUsage(uid);
    const today = body.today as {
      auto_requests: number;
      by_model: Record<string, { via_auto: number }>;
    };
    expect(today.auto_requests).toBe(2);
    expect(today.by_model["glm-5.3-flash"].via_auto).toBe(2);
  });

  it("counts only successful rows; images from call_type and group kind", async () => {
    const uid = testUid("usage-images");
    const keys = await user(uid);
    fake.addLog(keys.android, "prov/glm-5.3-flash", { group: "glm-5.3-flash", pin: 10, pout: 5 });
    fake.addLog(keys.android, "prov/glm-5.3-flash", { group: "glm-5.3-flash", status: "failure" });
    fake.addLog(keys.android, "prov/img-1", {
      group: "ovid-image", pin: 20, pout: 0, callType: "aimage_generation",
    });
    // group kind alone makes it an image even with a chat-ish call_type
    fake.addLog(keys.android, "prov/img-1", { group: "ovid-image", pin: 5, pout: 0 });
    const body = await getUsage(uid);
    const today = body.today as { requests: number; images: number };
    expect(today.requests).toBe(3);
    expect(today.images).toBe(2);
  });

  it("daily_spent_usd is pyRound6(max(logged spend, hook counter))", async () => {
    const uid = testUid("usage-spend");
    const keys = await user(uid);
    fake.addLog(keys.android, "prov/glm-5.3-flash", { group: "glm-5.3-flash", spend: 0.1 });
    await redis.set(poolKeys(uid).spend, "0.15");
    const body = await getUsage(uid);
    expect(body.daily_spent_usd).toBe(0.15);
    expect(body.daily_remaining_usd).toBe(0);
    expect(body.remaining_fraction).toBe(0);
  });

  it("free plan applies the monthly backstop to the single allowance pool", async () => {
    const uid = testUid("usage-freecap");
    await user(uid);
    await plansRepo.saveOverride(db, uid, { dailyUsd: "3" });
    fake.users.set(uid, { spend: 9, budget_duration: "30d" });

    const body = await getUsage(uid);
    expect(body.daily_budget_usd).toBe(3);
    expect(body.daily_remaining_usd).toBe(1);
    expect(body.month_free_spent_usd).toBe(9);
    expect(body.month_free_cap_usd).toBe(10);
    expect(body.remaining_fraction).toBe(0.3333);
    expect(body.pools).toEqual([
      { class: "all", remaining_fraction: 0.3333, resets_at: body.resets_at, slow_mode: false },
    ]);
  });

  it("15 s cache: a second POST serves the cached body with zero LiteLLM calls", async () => {
    const uid = testUid("usage-cache");
    const keys = await user(uid);
    const first = await getUsage(uid);
    const callsAfterFirst = fake.calls.length;
    fake.addLog(keys.android, "prov/glm-5.3-flash", {
      group: "glm-5.3-flash", spend: 0.1, agoMin: 0,
    });
    const second = await getUsage(uid);
    expect(second).toEqual(first);
    expect(fake.calls.length).toBe(callsAfterFirst);

    // dropUsageCache → recompute
    await dropUsageCache(deps, [uid]);
    const third = await getUsage(uid);
    expect(third.daily_spent_usd).toBe(0.1);
  });

  it("resetWindowUser invalidates the usage cache", async () => {
    const uid = testUid("usage-reset-cache");
    await user(uid);
    await redis.set(`usagecache:${uid}`, JSON.stringify({ cached: true }));
    expect((await getUsage(uid)).cached).toBe(true);

    await resetWindowUser(deps, uid);
    expect((await getUsage(uid)).cached).toBeUndefined();
  });

  it("free auto estimate is conservative over all routed members", async () => {
    const uid = testUid("usage-free-auto");
    await user(uid);
    const body = await getUsage(uid);
    const auto = (body.models as Record<string, unknown>[]).find((m) => m.id === "auto")!;
    expect(auto.estimate).toBe("conservative");
    expect(auto.members).toEqual([
      "deepseek-v4.1-flash", "gemini-3.7-flash", "gemini-3.8-flash",
      "glm-5.3-flash", "gpt-5.6-luna", "minimax-m3",
    ]);
    // dearest member: gemini-3.8-flash (0.0021 per message); 0.15 / 0.0021 = 71.4
    expect(auto.remaining_messages).toBe(71);
  });

  it("image alias is priced at the dearest private image backend", async () => {
    fake.addModel("img-backend-a", "prov/a", undefined, undefined, 0.02, "image_generation");
    fake.addModel("img-backend-b", "prov/b", undefined, undefined, 0.05, "image_generation");
    const cat = await catalogFor(deps);
    const s = await getSettings({ db });
    const uid = testUid("usage-alias");
    const plan = findPlan(s, "free");
    const pools = userPools(s, plan, 1, null);
    const st = poolState(pools, 0);

    const entries = modelEstimates(
      cat,
      st,
      s,
      {},
      1,
      null,
      ["glm-5.3-flash", "studio-alias"],
    );
    const byId = Object.fromEntries(entries.map((e) => [e.id, e]));
    expect(Object.keys(byId).sort()).toEqual(["glm-5.3-flash", "studio-alias"]);
    expect(byId["studio-alias"]).toMatchObject({
      kind: "image",
      auto: false,
      estimate: "conservative",
      remaining_images: 20, // floor(1 / 0.05)
    });
    expect(byId["studio-alias"].priced).toBe(true);
  });

  it("an image model priced by measured output tokens", async () => {
    fake.addModel("tok-image", "prov/tok-image", undefined, 1e-5, undefined, "image_generation");
    const uid = testUid("usage-measured");
    const keys = await user(uid);
    await plansRepo.saveOverride(db, uid, { dailyUsd: "1" });

    const first = await getUsage(uid);
    const before = (first.models as Record<string, unknown>[]).find((m) => m.id === "tok-image")!;
    expect(before.remaining_images).toBe(Math.floor(1 / (1e-5 * 1500) + 1e-9));

    fake.addLog(keys.android, "prov/tok-image", {
      group: "tok-image", pin: 0, pout: 4000, spend: 0, callType: "aimage_generation", agoMin: 0,
    });
    await dropUsageCache(deps, [uid]);
    const second = await getUsage(uid);
    const after = (second.models as Record<string, unknown>[]).find((m) => m.id === "tok-image")!;
    expect(after.remaining_images).toBe(Math.floor(1 / (1e-5 * 4000) + 1e-9));
  });

  it("computeUsage detail carries the admin-only key/spend/pool numbers", async () => {
    const uid = testUid("usage-detail");
    const keys = await user(uid, "7x");
    fake.addLog(keys.android, "prov/glm-5.3-flash", { group: "glm-5.3-flash", spend: 0.25 });

    const { body, detail } = await computeUsage(deps, uid);
    expect(body.daily_spent_usd).toBe(0.25);
    expect(detail.spend_usd).toBe(0.25);
    expect(detail.logged_spend_usd).toBe(0.25);
    expect(detail.hook_counter_usd).toBe(0);
    expect(detail.remaining_usd).toBe(3.2);
    expect(detail.slow_mode).toBe(false);
    expect(detail.window_start).toMatch(/Z$/);
    expect(detail.keys).toHaveLength(2);
    expect(detail.keys.map((k) => k.platform).sort()).toEqual(["android", "web"]);
    expect(detail.pools_usd).toMatchObject({ plan_id: "pro", window_hours: 24 });
    expect(detail.pool_state_usd).toEqual({
      all: { cap: 3.45, spent: 0.25, remaining: 3.2 },
    });
  });

  it("syncs slow mode when the allowance is exhausted (plan slow_mode)", async () => {
    const original = await getSettings({ db });
    try {
      await storeSettings({ db, redis }, {
        ...original,
        plans: original.plans.map((p) => (p.id === "pro" ? { ...p, slow_mode: true } : p)),
      });
      const uid = testUid("usage-slow");
      const keys = await user(uid, "7x");
      fake.addLog(keys.android, "prov/glm-5.3-flash", { group: "glm-5.3-flash", spend: 3.5 });

      const body = await getUsage(uid);
      expect(body.remaining_fraction).toBe(0);
      expect((body.pools as Record<string, unknown>[])[0].slow_mode).toBe(true);
      expect(await redis.hget("pools:slow", uid)).not.toBeNull();

      const updates = fake.posts("/key/update").filter((u) => u.key === keys.android);
      expect(updates.at(-1)).toMatchObject({ rpm_limit: 20, tpm_limit: 200_000, max_parallel_requests: 2 });
    } finally {
      await storeSettings({ db, redis }, original);
    }
  });

  it("availableModels lists the published catalog (Task 13 wraps it)", async () => {
    await catalogFor(deps);
    const names = availableModels(deps).map((m) => m.model);
    expect(names).toContain("glm-5.3-flash");
    expect(names).toContain("ovid-image");
    expect(names).toContain("auto");
  });

  it("buildMintApps registers POST /usage (the composition root)", async () => {
    // A second registration on the same app must collide — the guard proving
    // the route is already installed by buildMintApps.
    expect(() => registerUsageRoutes(app, deps)).toThrow();
  });
});
