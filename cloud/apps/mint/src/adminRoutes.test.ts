import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { plansRepo, users as usersRepo, type Db } from "@ovid/db";
import { PLANS, type PlanTier } from "@ovid/shared";
import type { Redis } from "ioredis";
import type { FastifyInstance, LightMyRequestResponse } from "fastify";
import type { MintDeps } from "./app.js";
import { buildMintApps, HttpContractError } from "./app.js";
import { requireAdmin, resyncCanonicalPlans } from "./adminRoutes.js";
import { AUDIT_LIST } from "./adminAudit.js";
import { isBanned, recordStrike } from "./antiAbuse.js";
import { loadMintEnv, type MintEnv } from "./env.js";
import { findPlan, parseSettings } from "./planMath.js";
import { createLiteLlmAdmin } from "./litellmAdmin.js";
import { getSettings, publishSettingsToRedis, storeSettings } from "./settings.js";
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

/**
 * The /admin JSON API + console — port of server/mint/tests/test_admin.py.
 * Real Postgres + Redis db9 + a local FakeLiteLLM; the console is served on
 * the ADMIN listener (buildMintApps' adminApp) only.
 *
 * Differences pinned by the plan (not Python bugs to copy):
 *  - auth compares OVID_ADMIN_MASTER_KEY (env.adminMasterKey) with
 *    timingSafeEqual, 401 "missing authorization" / 403 "not admin";
 *  - overrides/tier/bans are durable in Postgres and re-published to db2 by
 *    the projection (Python wrote Redis directly).
 */

const RUN = TEST_DATABASE_URL !== undefined && TEST_MINT_REDIS_URL !== undefined;

const FIXED_NOW = new Date("2026-10-17T12:34:56.000Z");
const ADMIN_KEY = "sk-admin-test";
const ADMIN = { authorization: `Bearer ${ADMIN_KEY}` };

const AUTH_MATRIX: Array<[string, string, unknown]> = [
  ["GET", "/admin/settings", null],
  ["POST", "/admin/settings", { free_daily_usd: 9 }],
  ["GET", "/admin/plans", null],
  ["POST", "/admin/plans", { id: "x", kind: "split" }],
  ["POST", "/admin/plans/resync", null],
  ["POST", "/admin/plans/pro/disable", null],
  ["GET", "/admin/models", null],
  ["POST", "/admin/set-base-budget", { daily_usd: 9 }],
  ["POST", "/admin/set-tier", { uid: "u", tier: "max" }],
  ["POST", "/admin/user/update", { uid: "u", daily_usd: 5 }],
  ["POST", "/admin/reset-window", { uid: "u" }],
  ["POST", "/admin/reset-usage", {}],
  ["GET", "/admin/reset-status", null],
  ["POST", "/admin/ban", { uid: "u" }],
  ["POST", "/admin/unban", { uid: "u" }],
  ["GET", "/admin/user?q=u", null],
  ["GET", "/admin/audit", null],
  ["GET", "/admin/reapply-status", null],
  ["POST", "/admin/sweep", null],
  ["GET", "/admin/export", null],
];

describe.skipIf(!RUN)("/admin JSON API + console (adminRoutes.ts)", () => {
  let db: Db;
  let redis: Redis;
  let fake: FakeLiteLlm;
  let deps: MintDeps;
  let adminApp: FastifyInstance;
  let publicApp: FastifyInstance;
  let stateDir: string;

  beforeAll(async () => {
    db = await resetTestDb();
    redis = await openFlushedRedis();
    stateDir = mkdtempSync(join(tmpdir(), "mint-admin-"));
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
        OVID_ADMIN_MASTER_KEY: ADMIN_KEY,
        OVID_INTERNAL_API_SECRET: "sk-internal-test",
        FIREBASE_PROJECT_ID: "ovid-test",
        APPCHECK_ENABLED: "true",
        USAGE_CACHE_S: "15",
        MINT_STATE_DIR: stateDir,
      }),
      alerter: async () => {},
      verifyIdentity: async ({ authorization }) => {
        const token = authorization.replace(/^bearer\s+/i, "");
        return { uid: token, email: null, platform: "android" };
      },
      clock: () => FIXED_NOW,
    };
    const apps = buildMintApps(deps);
    publicApp = apps.publicApp;
    adminApp = apps.adminApp;
    await getSettings({ db });
    standardModels(fake);
  }, 60_000);

  afterAll(async () => {
    await publicApp.close();
    await adminApp.close();
    await fake.stop();
    await closeRedis(redis);
    await closeDb(db);
  });

  beforeEach(async () => {
    await redis.flushdb();
    fake.reset();
    standardModels(fake);
    deps.env.reapplySyncMax = 200;
    // re-publish the db2 projection the flush wiped (parity with a live boot)
    await publishSettingsToRedis(redis, await getSettings({ db }));
  });

  function admin(
    method: string,
    url: string,
    payload?: unknown,
    headers: Record<string, string> = {},
  ): Promise<LightMyRequestResponse> {
    return adminApp.inject({
      method: method as "GET" | "POST",
      url,
      headers: { ...ADMIN, ...headers },
      ...(payload === undefined || payload === null ? {} : { payload: payload as object }),
    });
  }

  /** conftest user_with_keys: android+web keys, tier in Redis AND Postgres. */
  async function userWithKeys(
    uid: string,
    tier: string | null = null,
  ): Promise<{ android: string; web: string }> {
    await usersRepo.ensure(db, uid, null);
    // A key-issuing mint user is mint-provisioned (I4) — the gateway's
    // chat-only rows deliberately are not.
    await plansRepo.markProvisioned(db, uid);
    if (tier !== null && tier !== "free") {
      const s = await getSettings({ db });
      await redis.set(`user:${uid}:tier`, tier);
      await db.$client`UPDATE users SET tier = ${findPlan(s, tier).id} WHERE uid = ${uid}`;
    }
    const android = fake.addKey(`tok-${uid}-a`);
    const web = fake.addKey(`tok-${uid}-w`);
    await redis.set(`user:${uid}:keyid`, android);
    await redis.set(`user:${uid}:web:keyid`, web);
    // conftest default: the LiteLLM user budget already runs on a 30d clock
    fake.users.set(uid, { spend: 0, budget_duration: "30d" });
    return { android, web };
  }

  /** conftest _prime: a mid-window user with spend, auto hits, slow mode. */
  async function prime(uid: string, tier = "pro") {
    const toks = await userWithKeys(uid, tier);
    for (const t of Object.values(toks)) fake.keys.get(t)!.spend = 0.7;
    const old = FIXED_NOW.getTime() / 1000 - 5 * 3600;
    await redis.set(`pool:${uid}:start`, String(old));
    await redis.set(`pool:${uid}:spend`, "6");
    await redis.hset(`pool:${uid}:auto`, "glm-5.3-flash", "4");
    await redis.hset("pools:slow", uid, "9999999999");
    fake.users.get(uid)!.spend = 4.0;
    return { toks, old };
  }

  async function getUsage(uid: string): Promise<Record<string, unknown>> {
    const res = await publicApp.inject({
      method: "POST",
      url: "/usage",
      headers: { authorization: `Bearer ${uid}`, "x-firebase-appcheck": "x" },
    });
    expect(res.statusCode).toBe(200);
    return res.json() as Record<string, unknown>;
  }

  async function auditEntries(limit = 200): Promise<Array<Record<string, unknown>>> {
    const res = await admin("GET", `/admin/audit?limit=${limit}`);
    expect(res.statusCode).toBe(200);
    return (res.json() as { entries: Array<Record<string, unknown>> }).entries;
  }

  // ------------------------------------------------------------------ reset ALL
  // FIRST test in the file: the users table holds exactly these 3 users, so
  // the "all users" reset pins Python's users=3 / keys=6 numbers.

  it("reset-window {} over all users runs SYNC and reports done status", async () => {
    const uids = [testUid("ra"), testUid("rb"), testUid("rc")];
    for (const u of uids) await prime(u);

    const res = await admin("POST", "/admin/reset-window", { all: true, operation_id: "admin-test-reset-all" });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({
      ok: true,
      accepted: false,
      reset: 6,
      detail: { mode: "sync", users: 3, keys: 6, errors: 0 },
    });

    const status = (await admin("GET", "/admin/reset-status")).json();
    expect(status).toMatchObject({ state: "done", total: 3, done: 3, users: 3, keys: 6 });

    for (const u of uids) {
      expect(await redis.get(`pool:${u}:spend`)).toBeNull();
      expect(await redis.hgetall(`pool:${u}:auto`)).toEqual({});
    }
    expect(await redis.hgetall("pools:slow")).toEqual({});

    const entries = await auditEntries();
    expect(entries[0]).toMatchObject({ action: "reset-window", target: "ALL" });
  });

  it("reset-window {} above REAPPLY_SYNC_MAX runs in the BACKGROUND with progress", async () => {
    const uidA = testUid("bga");
    const uidB = testUid("bgb");
    const a = await prime(uidA);
    const b = await prime(uidB, "free");
    const total = (await plansRepo.mintUids(db)).length;

    deps.env.reapplySyncMax = 1;
    try {
      const res = await admin("POST", "/admin/reset-window", { all: true, operation_id: "admin-test-reset-all" });
      expect(res.statusCode).toBe(202);
      expect(res.json()).toEqual({
        ok: false,
        accepted: true,
        reset: 0,
        detail: { mode: "background", users: total },
      });

      const deadline = Date.now() + 15_000;
      let status: Record<string, unknown> = {};
      for (;;) {
        status = (await admin("GET", "/admin/reset-status")).json();
        if (status.state === "done") break;
        if (Date.now() > deadline) throw new Error("background reset never finished");
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      expect(status).toMatchObject({ state: "done", total, done: total, users: total });

      for (const t of [...Object.values(a.toks), ...Object.values(b.toks)]) {
        expect(fake.keys.get(t)!.spend).toBe(0);
      }
      expect(await redis.get(`pool:${uidA}:spend`)).toBeNull();
      expect(await redis.get(`pool:${uidB}:spend`)).toBeNull();
      expect(await redis.hgetall("pools:slow")).toEqual({});
    } finally {
      deps.env.reapplySyncMax = 200;
    }
  });

  // ---------------------------------------------------------------------- auth

  it("every admin endpoint requires the master key: 401 missing, 403 wrong, no side effects", async () => {
    const uid = testUid("auth");
    await userWithKeys(uid);
    const settingsBefore = await getSettings({ db });

    for (const [method, path, payload] of AUTH_MATRIX) {
      const noAuth = await adminApp.inject({
        method: method as "GET" | "POST",
        url: path,
        ...(payload === null ? {} : { payload: payload as object }),
      });
      expect(noAuth.statusCode, `${method} ${path} without auth`).toBe(401);
      expect(noAuth.json()).toEqual({ detail: "missing authorization" });

      const wrong = await adminApp.inject({
        method: method as "GET" | "POST",
        url: path,
        headers: { authorization: "Bearer nope" },
        ...(payload === null ? {} : { payload: payload as object }),
      });
      expect(wrong.statusCode, `${method} ${path} with a wrong key`).toBe(403);
      expect(wrong.json()).toEqual({ detail: "not admin" });
    }

    // nothing happened: settings unchanged, no ban, no audit rows
    expect(await getSettings({ db })).toEqual(settingsBefore);
    expect(await redis.get(`user:${uid}:banned`)).toBeNull();
    expect(await redis.llen(AUDIT_LIST)).toBe(0);
  });

  it("requireAdmin: timing-safe compare, equal-length wrong key is a 403 not a throw", () => {
    const env = loadMintEnv({
      NODE_ENV: "test",
      DATABASE_URL: "postgres://u:p@localhost:5432/t",
      REDIS_DB2_URL: "redis://localhost:6379/9",
      LITELLM_MASTER_KEY: MASTER_KEY,
      OVID_ADMIN_MASTER_KEY: ADMIN_KEY,
      OVID_INTERNAL_API_SECRET: "sk-internal-test",
      FIREBASE_PROJECT_ID: "ovid-test",
    }) as MintEnv;

    expect(() => requireAdmin(env, "")).toThrowError(HttpContractError);
    expect(() => requireAdmin(env, "")).toThrowError(
      expect.objectContaining({ status: 401, detail: "missing authorization" }),
    );
    expect(() => requireAdmin(env, "Token abc")).toThrowError(
      expect.objectContaining({ status: 401 }),
    );
    // equal length, wrong bytes: exercises timingSafeEqual, not the length guard
    expect(() => requireAdmin(env, `Bearer ${"x".repeat(ADMIN_KEY.length)}`)).toThrowError(
      expect.objectContaining({ status: 403, detail: "not admin" }),
    );
    expect(() => requireAdmin(env, `Bearer ${ADMIN_KEY}`)).not.toThrow();
    expect(() => requireAdmin(env, `bearer ${ADMIN_KEY}`)).not.toThrow();
  });

  // ------------------------------------------------------------------ settings

  it("GET /admin/settings returns settings, user count, scalar bounds and statuses", async () => {
    const uid = testUid("setg");
    await userWithKeys(uid);
    const res = await admin("GET", "/admin/settings");
    expect(res.statusCode).toBe(200);
    const body = res.json() as Record<string, unknown>;
    expect(body.users).toBe((await plansRepo.mintUids(db)).length);
    const settings = body.settings as Record<string, unknown>;
    expect(settings.free_daily_usd).toBe(0.15);
    expect((settings.plans as Array<{ id: string }>)[0]!.id).toBe("free");
    const scalars = body.scalars as Record<string, { min: number; max: number }>;
    expect(scalars.free_monthly_cap_usd).toEqual({ min: 0, max: 100000 });
    expect(scalars.est_input_tokens).toEqual({ min: 1, max: 10_000_000 });
    expect(body.reapply_status).toBeNull();
    expect(body.reset_status).toBeNull(); // beforeEach flushed db2's status keys
  });

  it("POST /admin/settings partial update keeps other fields, re-publishes db2, reapplies to every key", async () => {
    const uid = testUid("setp");
    const toks = await userWithKeys(uid);

    const hashBefore = await redis.hgetall("config:limits");
    expect(await redis.get("config:base_daily_usd")).toBe("0.15");

    const res = await admin("POST", "/admin/settings", { free_daily_usd: 9 });
    expect(res.statusCode).toBe(200);
    const body = res.json() as {
      ok: boolean;
      settings: Record<string, unknown>;
      reapplied: Record<string, unknown>;
    };
    expect(body.ok).toBe(true);
    expect(body.settings.free_daily_usd).toBe(9);
    // untouched fields survive the partial update
    expect(body.settings.free_monthly_cap_usd).toBe(10);
    expect(
      (body.settings.auto_oss_members as Array<{ model: string; weight: number }>).map((m) => m.model),
    ).toEqual(["glm-5.3-flash", "deepseek-v4.1-flash", "minimax-m3"]);
    const hashAfter = await redis.hgetall("config:limits");
    expect(hashAfter.free_monthly_cap_usd).toBe(hashBefore.free_monthly_cap_usd);
    expect(hashAfter.plans).toBe(hashBefore.plans);
    expect(await redis.get("config:base_daily_usd")).toBe("9.0");

    // re-applied to EVERY key (android + web namespaces)
    expect(body.reapplied).toMatchObject({ mode: "sync" });
    for (const t of Object.values(toks)) {
      const upd = fake.posts("/key/update").filter((p) => p.key === t).pop()!;
      expect(upd.max_budget).toBe(9); // free plan: 9 × 1 per 24h
    }

    // audited with before/after
    const entries = await auditEntries();
    const s = entries.find((e) => e.action === "settings")!;
    expect((s.before as Record<string, unknown>).free_daily_usd).toBe(0.15);
    expect((s.after as Record<string, unknown>).free_daily_usd).toBe(9);

    // restore
    await admin("POST", "/admin/settings", { free_daily_usd: 0.15 });
  });

  it("POST /admin/settings with reapply=false skips the key sweep (?reapply=false opt-out)", async () => {
    const uid = testUid("setr");
    await userWithKeys(uid);
    fake.calls.length = 0;

    const res = await admin("POST", "/admin/settings", {
      auto_oss_members: [{ model: "glm-5.3-flash", weight: 2 }],
      reapply: false,
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ ok: true, reapplied: { mode: "skipped" } });
    expect(fake.posts("/key/update")).toHaveLength(0);
    expect(
      ((res.json() as { settings: { auto_oss_members: unknown[] } }).settings.auto_oss_members),
    ).toEqual([{ model: "glm-5.3-flash", weight: 2 }]);

    // the query-string spelling works too
    const q = await adminApp.inject({
      method: "POST",
      url: "/admin/settings?reapply=false",
      headers: ADMIN,
      payload: { free_monthly_cap_usd: 12 },
    });
    expect(q.statusCode).toBe(200);
    expect(q.json()).toMatchObject({ reapplied: { mode: "skipped" } });
    expect(fake.posts("/key/update")).toHaveLength(0);

    // restore
    await admin("POST", "/admin/settings", {
      auto_oss_members: [
        { model: "glm-5.3-flash", weight: 1 },
        { model: "deepseek-v4.1-flash", weight: 1 },
        { model: "minimax-m3", weight: 1 },
      ],
      free_monthly_cap_usd: 10,
      reapply: false,
    });
  });

  it("POST /admin/settings rejects invalid values with Python's messages", async () => {
    const invalid: Array<[Record<string, unknown>, string]> = [
      [{ bogus: 1 }, "unknown setting 'bogus'"],
      [{ auto_oss_members: [{ model: "nope" }] }, "not LiteLLM models: nope"],
      [{ auto_oss_members: ["auto"] }, "auto_oss_members cannot contain 'auto'"],
      [
        { plans: [{ id: "FREE" }] },
        "plan id must be 1-32 chars of a-z 0-9 _ -",
      ],
    ];
    for (const [payload, message] of invalid) {
      const res = await admin("POST", "/admin/settings", payload);
      expect(res.statusCode, JSON.stringify(payload)).toBe(400);
      expect(res.json()).toEqual({ detail: message });
    }
  });

  it("GET /admin/reapply-status: never → done after a settings change", async () => {
    const uid = testUid("reps");
    await userWithKeys(uid);
    await redis.del("config:reapply_status");
    const never = (await admin("GET", "/admin/reapply-status")).json();
    expect(never).toEqual({ state: "never" });
    await admin("POST", "/admin/settings", { est_input_tokens: 2000 });
    const done = (await admin("GET", "/admin/reapply-status")).json();
    expect(done).toMatchObject({ state: "done", total: expect.any(Number) });
  });

  // --------------------------------------------------------------------- plans

  it("plans-as-data: add, edit, disable (stop selling) keeps existing users, re-enable", async () => {
    const uid = testUid("plan");
    await userWithKeys(uid, "pro");
    const budgetBefore = (await getUsage(uid)).daily_budget_usd;

    // add
    const add = await admin("POST", "/admin/plans", {
      id: "team",
      name: "Team",
      price_usd: 15,
      mult: 10,
      window_hours: 24,
    });
    expect(add.statusCode).toBe(200);
    expect((add.json() as { settings: { plans: Array<{ id: string }> } }).settings.plans.map((p) => p.id)).toContain("team");
    expect((await auditEntries()).find((e) => e.action === "plan-add")!.target).toBe("team");

    // edit by id: missing fields keep their stored values
    const edit = await admin("POST", "/admin/plans", { id: "team", mult: 12 });
    expect(edit.statusCode).toBe(200);
    const team = ((await admin("GET", "/admin/plans")).json() as {
      plans: Array<{ id: string; name: string; mult: number }>;
    }).plans.find((p) => p.id === "team")!;
    expect(team.name).toBe("Team");
    expect(team.mult).toBe(12);
    expect((await auditEntries()).find((e) => e.action === "plan-edit")!.target).toBe("team");

    // disable: vanishes from the PUBLIC /plans, existing users keep it
    const disable = await admin("POST", "/admin/plans/pro/disable");
    expect(disable.statusCode).toBe(200);
    const publicPlans = (
      (await publicApp.inject({ method: "GET", url: "/plans" }).then((r) => r.json())) as {
        plans: Array<{ id: string }>;
      }
    ).plans.map((p) => p.id);
    expect(publicPlans).not.toContain("pro");
    expect(publicPlans).toContain("team");
    await redis.del(`usagecache:${uid}`); // prove findPlan ignores `enabled`
    expect((await getUsage(uid)).daily_budget_usd).toBe(budgetBefore);
    expect((await auditEntries()).find((e) => e.action === "plan-disable")!.target).toBe("pro");

    // re-enable
    const enable = await admin("POST", "/admin/plans/pro/enable");
    expect(enable.statusCode).toBe(200);
    expect(
      ((await publicApp.inject({ method: "GET", url: "/plans" }).then((r) => r.json())) as {
        plans: Array<{ id: string }>;
      }).plans.map((p) => p.id),
    ).toContain("pro");

    // guards
    const noPlan = await admin("POST", "/admin/plans/nope/disable");
    expect(noPlan.statusCode).toBe(404);
    expect(noPlan.json()).toEqual({ detail: "unknown plan" });
    const noAction = await admin("POST", "/admin/plans/pro/bogus");
    expect(noAction.statusCode).toBe(404);
    expect(noAction.json()).toEqual({ detail: "unknown action" });
    const freeOff = await admin("POST", "/admin/plans/free/disable");
    expect(freeOff.statusCode).toBe(400);
    expect(freeOff.json()).toEqual({ detail: "the 'free' plan must stay enabled" });
  });

  it("canonical resync is idempotent and makes Postgres, Redis and LiteLLM match PLANS", async () => {
    const original = await getSettings({ db });
    const uid = testUid("canonical-resync");
    const keys = await userWithKeys(uid, "plus");
    fake.users.get(uid)!.budget_duration = "24h";
    const stale = {
      ...original,
      plans: original.plans.map((plan) =>
        plan.id in PLANS
          ? {
              ...plan,
              name: "stale",
              price_usd: 1234,
              mult: 999,
              enabled: plan.id === "go" ? false : plan.enabled,
              window_hours: 720,
            }
          : plan,
      ),
    };
    try {
      await storeSettings({ db, redis }, stale);
      const res = await admin("POST", "/admin/plans/resync");
      expect(res.statusCode).toBe(200);
      expect(res.json()).toMatchObject({
        ok: true,
        status: "ok",
        changed: true,
        projection: { redis: "ok", litellm: "ok", errors: 0 },
      });

      const durable = await getSettings({ db });
      for (const plan of durable.plans.filter((row) => row.id in PLANS)) {
        const canonical = PLANS[plan.id as PlanTier];
        const before = stale.plans.find((row) => row.id === plan.id)!;
        expect(plan).toMatchObject({
          name: canonical.name,
          price_usd: canonical.priceUsd,
          mult: canonical.autoMultiplier,
          enabled: before.enabled,
          window_hours: before.window_hours,
        });
      }
      const projected = parseSettings(
        await redis.hgetall("config:limits"),
        await redis.get("config:base_daily_usd"),
      );
      expect(projected.plans).toEqual(durable.plans);

      const expected = Math.round(original.free_daily_usd * PLANS.plus.autoMultiplier * 30 * 1e6) / 1e6;
      for (const key of Object.values(keys)) {
        expect(fake.posts("/key/update").filter((body) => body.key === key).at(-1)).toMatchObject({
          max_budget: expected,
          budget_duration: "30d",
        });
      }
      expect(fake.posts("/user/update").filter((body) => body.user_id === uid).at(-1)).toMatchObject({
        max_budget: expected,
        budget_duration: "30d",
      });

      const again = await admin("POST", "/admin/plans/resync");
      expect(again.statusCode).toBe(200);
      expect(again.json()).toMatchObject({ ok: true, status: "ok", changed: false });
      expect(await getSettings({ db })).toEqual(durable);
    } finally {
      await storeSettings({ db, redis }, original);
    }
  });

  it("canonical resync reports a committed Redis projection failure as degraded", async () => {
    const original = await getSettings({ db });
    const stale = {
      ...original,
      plans: original.plans.map((plan) => ({ ...plan, name: "stale-before-resync" })),
    };
    await storeSettings({ db, redis }, stale);
    const brokenRedis = new Proxy(redis, {
      get(target, property, receiver) {
        if (property === "hset") {
          return async () => {
            throw new Error("isolated redis projection failure");
          };
        }
        const value = Reflect.get(target, property, receiver) as unknown;
        return typeof value === "function" ? value.bind(target) : value;
      },
    }) as Redis;
    try {
      const result = await resyncCanonicalPlans({ ...deps, redis: brokenRedis });
      expect(result).toMatchObject({
        ok: false,
        status: "degraded",
        projection: { redis: "failed" },
      });
      // Postgres committed; the failure is not misreported as a rejected write.
      for (const plan of (await getSettings({ db })).plans.filter((row) => row.id in PLANS)) {
        expect(plan.name).toBe(PLANS[plan.id as PlanTier].name);
      }
    } finally {
      await storeSettings({ db, redis }, original);
    }
  });

  it("canonical resync degrades when LiteLLM /user/update returns HTTP >=300", async () => {
    const uid = testUid("canonical-user-update-500");
    await userWithKeys(uid, "plus");
    const result = await resyncCanonicalPlans({
      ...deps,
      litellm: {
        ...deps.litellm,
        userUpdate: async () => 503,
      },
    });
    expect(result).toMatchObject({
      ok: false,
      status: "degraded",
      projection: { redis: "ok", litellm: "degraded" },
    });
    expect(result.projection.errors).toBeGreaterThan(0);
  });

  it("canonical resync appends before/after/IP audit without changing prices", async () => {
    const original = await getSettings({ db });
    const named = {
      ...original,
      plans: original.plans.map((plan) => ({ ...plan, name: `stale-${plan.id}` })),
    };
    await storeSettings({ db, redis }, named);
    const baselineRows = await db.$client`SELECT action FROM mint_audit WHERE action = 'plan-resync'`;
    const baselineEntries = (await auditEntries()).filter((item) => item.action === "plan-resync").length;
    try {
      const res = await admin("POST", "/admin/plans/resync", undefined, {
        "x-forwarded-for": "203.0.113.44",
      });
      expect(res.statusCode).toBe(200);
      const entries = await auditEntries();
      const entry = entries.find((item) => item.action === "plan-resync");
      expect(entry).toMatchObject({
        action: "plan-resync",
        target: "canonical-plans",
        ip: "203.0.113.44",
      });
      const beforePlans = (entry!.before as { plans: Array<{ id: string; name: string; price_usd: number }> }).plans;
      const afterPlans = (entry!.after as { plans: Array<{ id: string; name: string; price_usd: number }> }).plans;
      expect(beforePlans.map((plan) => plan.name)).toEqual(named.plans.map((plan) => plan.name));
      expect(afterPlans.map((plan) => plan.name)).toEqual(
        named.plans.map((plan) => plan.id in PLANS ? PLANS[plan.id as PlanTier].name : plan.name),
      );
      expect(afterPlans.map((plan) => plan.price_usd)).toEqual(original.plans.map((plan) => plan.price_usd));

      await admin("POST", "/admin/plans/resync");
      const rows = await db.$client`
        SELECT action, ip FROM mint_audit WHERE action = 'plan-resync' ORDER BY at`;
      expect(rows).toHaveLength(baselineRows.length + 2);
      expect(rows.filter((row) => row.ip === "203.0.113.44")).toEqual([
        { action: "plan-resync", ip: "203.0.113.44" },
      ]);
      expect((await auditEntries()).filter((item) => item.action === "plan-resync")).toHaveLength(baselineEntries + 2);
    } finally {
      await storeSettings({ db, redis }, original);
    }
  });

  // -------------------------------------------------------------- user/update

  it("user/update tier + custom free limit: Postgres + db2 + reapply, then clear", async () => {
    const uid = testUid("su1");
    const toks = await userWithKeys(uid);

    const res = await admin("POST", "/admin/user/update", {
      uid,
      tier: "starter",
      daily_usd: 2,
    });
    expect(res.statusCode).toBe(200);
    const body = res.json() as {
      ok: boolean;
      user: Record<string, unknown>;
      reapplied: { keys: number; errors: number };
    };
    expect(body.ok).toBe(true);
    expect(body.user.tier).toBe("go");
    expect(body.user.plan).toBe("go");
    expect(body.user.daily_usd_override).toBe("2.0");
    expect(body.reapplied).toEqual({ keys: 2, errors: 0 });

    // Postgres authority
    const rows = (await db.$client`SELECT tier FROM users WHERE uid = ${uid}`) as {
      tier: string;
    }[];
    expect(rows[0]!.tier).toBe("go");
    expect((await plansRepo.getOverride(db, uid))?.dailyUsd).toBe("2.0");
    // db2 projection
    expect(await redis.get(`user:${uid}:tier`)).toBe("go");
    expect(await redis.get(`user:${uid}:dailyUsd`)).toBe("2.0");
    // re-applied: 2 × canonical Go mult 1.5 per 24h window
    for (const t of Object.values(toks)) {
      expect(fake.keys.get(t)!.max_budget).toBeCloseTo(3, 10);
    }

    // the /admin/set-tier alias + clear_daily_usd
    const alias = await admin("POST", "/admin/set-tier", { uid, clear_daily_usd: true });
    expect(alias.statusCode).toBe(200);
    expect((alias.json() as { user: { daily_usd_override: string | null } }).user.daily_usd_override).toBeNull();
    expect(await redis.get(`user:${uid}:dailyUsd`)).toBeNull();
    expect(fake.keys.get(toks.web)!.max_budget).toBeCloseTo(0.225, 10);
    expect(await plansRepo.getOverride(db, uid)).toBeNull();

    // audited with before/after — two set-user calls happened (set, then clear)
    const setUser = (await auditEntries()).filter((e) => e.action === "set-user");
    expect(setUser).toHaveLength(2);
    expect((setUser[1]!.before as Record<string, unknown>).plan).toBe("free");
    expect((setUser[1]!.after as Record<string, unknown>).plan).toBe("go");
    expect((setUser[1]!.after as Record<string, unknown>).tier).toBe("go");
    expect((setUser[1]!.after as Record<string, unknown>).daily_usd_override).toBe("2.0");
    expect((setUser[0]!.after as Record<string, unknown>).daily_usd_override).toBeNull();
  });

  it("user/update pools override (mult/slow/auto-oss) with clear", async () => {
    const uid = testUid("su2");
    const toks = await userWithKeys(uid, "pro");

    const res = await admin("POST", "/admin/user/update", {
      uid,
      pools: { mult: 40, slow_mode: true, auto_oss: false },
    });
    expect(res.statusCode).toBe(200);
    // allowance 0.15 × 40 = 6; slow-mode plans get the key ceiling ×3
    expect(fake.keys.get(toks.android)!.max_budget).toBeCloseTo(0.15 * 40 * 3, 10);

    const u = (await admin("GET", `/admin/user?q=${uid}`)).json() as Record<string, unknown>;
    expect(u.override_pools).toEqual({ mult: 40, slow_mode: true, auto_oss: false });
    expect((u.pools_usd as { all: number }).all).toBeCloseTo(6.0, 10);

    const clear = await admin("POST", "/admin/user/update", { uid, clear_pools: true });
    expect(clear.statusCode).toBe(200);
    expect(fake.keys.get(toks.android)!.max_budget).toBeCloseTo(0.15 * 20, 10);
    expect((await plansRepo.getOverride(db, uid))?.pools ?? null).toBeNull();
  });

  it("user/update validation: unknown plan, negative money, bad pools fields, missing uid", async () => {
    const cases: Array<[Record<string, unknown>, string]> = [
      [{ uid: "vu1", tier: "99x" }, "unknown plan"],
      [{ uid: "vu2", daily_usd: -1 }, "daily_usd must be >= 0"],
      [{ uid: "vu3", monthly_cap_usd: -0.5 }, "monthly_cap_usd must be >= 0"],
      [{ uid: "vu4", pools: { oss_usd: -1 } }, "unknown override field 'oss_usd'"],
      [{ uid: "vu5", pools: { bogus: 1 } }, "unknown override field 'bogus'"],
      [{ uid: "vu6", pools: { mult: -1 } }, "mult must be between 0 and 100000"],
      [{ uid: "vu7", pools: { slow_mode: "yes" } }, "slow_mode must be true or false"],
      [{ tier: "pro" }, "uid required"],
    ];
    for (const [payload, message] of cases) {
      const res = await admin("POST", "/admin/user/update", payload);
      expect(res.statusCode, JSON.stringify(payload)).toBe(400);
      expect(res.json()).toEqual({ detail: message });
    }
  });

  it("custom monthly backstop drives the LiteLLM user budget (free plan, 30d)", async () => {
    const uid = testUid("cap");
    await userWithKeys(uid);
    const res = await admin("POST", "/admin/set-tier", { uid, monthly_cap_usd: 25 });
    expect(res.statusCode).toBe(200);
    expect((await plansRepo.getOverride(db, uid))?.monthlyCapUsd).toBe("25.0");
    expect(await redis.get(`user:${uid}:monthlyCapUsd`)).toBe("25.0");
    expect(fake.users.get(uid)!.max_budget).toBe(25);
  });

  // ------------------------------------------------------------- reset-window

  it("reset-window (one user): counters cleared, clocks restarted, /usage resets_at moved", async () => {
    const uid = testUid("rw");
    const { toks, old } = await prime(uid);

    const before = (await getUsage(uid)) as {
      resets_at: string;
      remaining_fraction: number;
    };
    expect(await redis.get(`usagecache:${uid}`)).not.toBeNull();

    const res = await admin("POST", "/admin/reset-window", { uid, operation_id: "admin-test-reset-user" });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({
      ok: true,
      accepted: false,
      reset: 2,
      detail: { mode: "sync", users: 1, keys: 2, errors: 0 },
    });

    for (const t of Object.values(toks)) {
      expect(fake.keys.get(t)!.spend).toBe(0);
      const upd = fake.posts("/key/update").filter((p) => p.key === t).pop()!;
      expect(upd.spend).toBe(0);
      expect(upd.budget_duration).toBe("24h"); // clock restarted
      expect(upd.rpm_limit).toBe(240); // slow mode lifted
    }
    expect(fake.users.get(uid)!.spend).toBe(0); // paid: user budget = window budget
    expect(await redis.get(`pool:${uid}:spend`)).toBeNull();
    expect(await redis.hgetall(`pool:${uid}:auto`)).toEqual({});
    expect(Number(await redis.get(`pool:${uid}:start`))).toBeGreaterThan(old + 4 * 3600);
    expect(await redis.hget("pools:slow", uid)).toBeNull();
    expect(await redis.get(`usagecache:${uid}`)).toBeNull(); // cache dropped

    const after = (await getUsage(uid)) as {
      resets_at: string;
      remaining_fraction: number;
      pools: Array<{ slow_mode: boolean }>;
    };
    expect(after.resets_at > before.resets_at).toBe(true);
    expect(after.remaining_fraction).toBe(1);
    expect(after.pools.every((p) => !p.slow_mode)).toBe(true);

    const entry = (await auditEntries()).find((e) => e.action === "reset-window")!;
    expect(entry.target).toBe(uid);
  });

  it("reset-window on a free user keeps the monthly backstop unless reset_month_free", async () => {
    const uid = testUid("rwf");
    await prime(uid, "free");

    await admin("POST", "/admin/reset-window", { uid, operation_id: "admin-test-reset-user" });
    expect(fake.users.get(uid)!.spend).toBe(4);
    // the free user's budget clock (30d) was NOT restarted
    expect(fake.posts("/user/update").every((u) => !("budget_duration" in u))).toBe(true);

    await admin("POST", "/admin/reset-window", { uid, reset_month_free: true, operation_id: "admin-test-reset" });
    expect(fake.users.get(uid)!.spend).toBe(0);
    const withDuration = fake.posts("/user/update").filter((u) => "budget_duration" in u);
    expect(withDuration).toHaveLength(1);
  });

  it("reset-usage (legacy) also zeroes the monthly backstop", async () => {
    const uid = testUid("rul");
    await prime(uid, "free");
    const res = await admin("POST", "/admin/reset-usage", { uid, operation_id: "admin-test-reset-usage" });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ ok: true, reset: 2 });
    expect(fake.users.get(uid)!.spend).toBe(0);
  });

  // ---------------------------------------------------------------- ban/unban

  it("ban blocks both keys + Redis flag + Postgres bannedAt + audit before/after; unban reverses", async () => {
    const uid = testUid("ban");
    const toks = await userWithKeys(uid);

    const ban = await admin("POST", "/admin/ban", { uid });
    expect(ban.statusCode).toBe(200);
    expect(ban.json()).toEqual({ ok: true });
    expect(await redis.get(`user:${uid}:banned`)).toBe("admin");
    for (const t of Object.values(toks)) {
      expect(fake.keys.get(t)!.blocked).toBe(true);
      expect(fake.calls.some((c) => c.method === "POST" && c.path === "/key/block" && c.body.key === t)).toBe(true);
    }
    const rows = (await db.$client`
      SELECT banned_at IS NOT NULL AS banned, banned_reason FROM users WHERE uid = ${uid}`) as {
      banned: boolean;
      banned_reason: string | null;
    }[];
    expect(rows[0]).toEqual({ banned: true, banned_reason: "admin" });

    const entry = (await auditEntries()).find((e) => e.action === "ban")!;
    expect(entry.target).toEqual({ uid, ip: null });
    expect((entry.before as Record<string, unknown>).banned).toBeNull();
    expect((entry.after as Record<string, unknown>).banned).toBe("admin");

    const unban = await admin("POST", "/admin/unban", { uid });
    expect(unban.statusCode).toBe(200);
    expect(await redis.get(`user:${uid}:banned`)).toBeNull();
    for (const t of Object.values(toks)) expect(fake.keys.get(t)!.blocked).toBe(false);
    expect(fake.calls.some((c) => c.method === "POST" && c.path === "/key/unblock")).toBe(true);
    const after = (await db.$client`
      SELECT banned_at IS NOT NULL AS banned FROM users WHERE uid = ${uid}`) as { banned: boolean }[];
    expect(after[0]!.banned).toBe(false);
  });

  it("IP ban: 30-day SETEX, unban deletes", async () => {
    const ban = await admin("POST", "/admin/ban", { ip: "203.0.113.9" });
    expect(ban.statusCode).toBe(200);
    expect(await redis.get("ban:ip:203.0.113.9")).toBe("admin");
    const ttl = await redis.ttl("ban:ip:203.0.113.9");
    expect(ttl).toBeGreaterThan(29 * 24 * 3600 - 60);
    expect(ttl).toBeLessThanOrEqual(30 * 24 * 3600);

    await admin("POST", "/admin/unban", { ip: "203.0.113.9" });
    expect(await redis.get("ban:ip:203.0.113.9")).toBeNull();
  });

  // -------------------------------------------------------------- user lookup

  it("lookup by uid or email shows allowance, app view and per-model usage", async () => {
    const uid = testUid("look");
    await usersRepo.ensure(db, uid, "u@example.com");
    await redis.set(`email:u@example.com`, uid);
    const toks = await userWithKeys(uid, "7x");
    standardModels(fake);

    const appBody = (await getUsage(uid)) as Record<string, unknown>;
    fake.addLog(toks.web, "prov/deepseek-v4.1-flash", { group: "auto", spend: 0.3, agoMin: 0 });

    const res = await admin("GET", `/admin/user?q=${encodeURIComponent("U@Example.com")}`);
    expect(res.statusCode).toBe(200);
    const u = res.json() as Record<string, unknown>;
    expect(u.uid).toBe(uid);
    expect((u.plan as { id: string }).id).toBe("plus");
    expect(u.tier).toBe("plus");
    expect(u.email).toBe("u@example.com");
    const all = (u.pool_state_usd as { all: { spent: number; remaining: number } }).all;
    expect(all.spent).toBeCloseTo(0.3, 10);
    expect(all.remaining).toBeCloseTo(0.15 * 5 - 0.3, 10);
    expect(
      ((u.today as { by_model: Record<string, { via_auto: number }> }).by_model[
        "deepseek-v4.1-flash"
      ] ?? {}).via_auto,
    ).toBe(1);
    expect(((u.app_view as { pools: Array<{ class: string }> }).pools).map((p) => p.class)).toEqual(["all"]);
    expect(Object.keys(u.app_view as Record<string, unknown>).sort()).toEqual(
      Object.keys(appBody).sort(),
    );
    expect(Array.isArray(u.keys)).toBe(true);

    const ghost = await admin("GET", "/admin/user?q=ghost");
    expect(ghost.statusCode).toBe(404);
    expect(ghost.json()).toEqual({ detail: "user not found" });
  });

  // -------------------------------------------------------------------- models

  it("GET /admin/models: prices + per-message/image estimates", async () => {
    const res = await admin("GET", "/admin/models");
    expect(res.statusCode).toBe(200);
    const models = (res.json() as { models: Array<Record<string, unknown>> }).models;
    const m = new Map(models.map((x) => [x.id, x]));
    expect(m.get("glm-5.3-flash")!.est_unit_cost_usd).toBeCloseTo(2e-7 * 2000 + 8e-7 * 600, 20);
    expect(m.get("ovid-image")!.est_unit_cost_usd).toBe(0.04);
    expect(m.get("mystery")!.est_unit_cost_usd).toBeNull();
    expect((m.get("auto")!.members as string[]).length).toBeGreaterThan(0);
    expect("class" in m.get("glm-5.3-flash")!).toBe(false);
    expect(models.map((x) => x.id)).toEqual([...models.map((x) => x.id)].sort());
  });

  // --------------------------------------------------------------------- audit

  it("audit list is newest-first and the JSONL file mirrors it oldest-first", async () => {
    const uid = testUid("aud");
    await userWithKeys(uid);
    const fileBefore = readFileSync(join(stateDir, "admin-audit.jsonl"), "utf8")
      .split("\n")
      .filter((l) => l !== "").length;

    await admin("POST", "/admin/settings", { free_daily_usd: 3 });
    await admin("POST", "/admin/set-tier", { uid, tier: "7x" });
    await admin("POST", "/admin/ban", { uid });
    await admin("POST", "/admin/reset-window", { uid, operation_id: "admin-test-reset-user" });

    const entries = await auditEntries();
    expect(entries.slice(0, 4).map((e) => e.action)).toEqual([
      "reset-window",
      "ban",
      "set-user",
      "settings",
    ]);
    const s = entries.find((e) => e.action === "settings")!;
    expect((s.before as Record<string, unknown>).free_daily_usd).toBe(0.15);
    expect((s.after as Record<string, unknown>).free_daily_usd).toBe(3);
    const t = entries.find((e) => e.action === "set-user")!;
    expect((t.before as Record<string, unknown>).plan).toBe("free");
    expect((t.after as Record<string, unknown>).plan).toBe("plus");
    expect((t.after as Record<string, unknown>).tier).toBe("plus");

    const lines = readFileSync(join(stateDir, "admin-audit.jsonl"), "utf8")
      .split("\n")
      .filter((l) => l !== "");
    expect(lines.length - fileBefore).toBe(4);
    const lineActions = lines
      .slice(fileBefore)
      .map((l) => (JSON.parse(l) as { action: string }).action);
    expect(lineActions).toEqual(["settings", "set-user", "ban", "reset-window"]);

    // limit is honored and clamped
    expect((await auditEntries(1)).length).toBe(1);
    expect((await auditEntries(-5)).length).toBe(1);

    // restore the settings change made here
    await admin("POST", "/admin/settings", { free_daily_usd: 0.15 });
  });

  // -------------------------------------------------------------------- sweep

  it("POST /admin/sweep runs the slow-mode sweep now", async () => {
    const uid = testUid("swp");
    await userWithKeys(uid);
    // an already-expired slow entry: the sweep lifts it and pushes rate limits
    await redis.hset("pools:slow", uid, String(FIXED_NOW.getTime() / 1000 - 60));
    const res = await admin("POST", "/admin/sweep");
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ checked: 0, lifted: 1 });
    expect(await redis.hget("pools:slow", uid)).toBeNull();
  });

  // ------------------------------------------------------------------- export

  it("GET /admin/export: settings + every user's state", async () => {
    const uid = testUid("exp");
    await usersRepo.ensure(db, uid, "export@example.com");
    await plansRepo.markProvisioned(db, uid);
    await redis.set(`user:${uid}:tier`, "3x");
    await db.$client`UPDATE users SET tier = 'starter' WHERE uid = ${uid}`;
    await plansRepo.saveOverride(db, uid, { pools: { mult: 4 } });

    const res = await admin("GET", "/admin/export");
    expect(res.statusCode).toBe(200);
    const exp = res.json() as {
      exported_at: string;
      settings: { plans: Array<{ id: string }> };
      users: Record<string, Record<string, unknown>>;
    };
    expect(exp.exported_at).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    expect(exp.settings.plans[0]!.id).toBe("free");
    expect(exp.users[uid]).toMatchObject({
      tier: "go",
      plan: "go",
      email: "export@example.com",
      pools_override: { mult: 4 },
    });
  });

  // ------------------------------------------------------------------- console

  it("GET /admin and /admin/ui serve the console: text/html, no-store, frame-ancestors 'none', nosniff", async () => {
    for (const path of ["/admin", "/admin/ui"]) {
      const res = await adminApp.inject({ method: "GET", url: path });
      expect(res.statusCode).toBe(200);
      expect(res.headers["content-type"]).toContain("text/html");
      expect(res.headers["cache-control"]).toBe("no-store");
      expect(res.headers["content-security-policy"]).toContain("frame-ancestors 'none'");
      expect(res.headers["x-content-type-options"]).toBe("nosniff");
      const html = res.body;
      for (const needle of [
        "Plans",
        "Model prices",
        "Auto-oss members",
        "auto uses auto-oss",
        "Slow-mode rpm",
        "Reset window now",
        "Reset window for ALL users now",
        "Clear custom plan",
        "Clear custom free limit",
        "Models as the app sees them",
        "Audit log",
        "monthly backstop",
      ]) {
        expect(html, needle).toContain(needle);
      }
      for (const gone of ["5 / 10 / 20", "Model classes", "frontier", "oss pool", "auto_oss_group"]) {
        expect(html, gone).not.toContain(gone);
      }
    }
    // the console page itself needs no key (it is a client of this API)
    const anon = await adminApp.inject({ method: "GET", url: "/admin" });
    expect(anon.statusCode).toBe(200);
  });

  it("the console HTML is byte-stable across serves", async () => {
    const a = await adminApp.inject({ method: "GET", url: "/admin" });
    const b = await adminApp.inject({ method: "GET", url: "/admin/ui" });
    expect(a.body).toBe(b.body);
  });

  // ── Fix round 1 regressions (I1–I5 + cheap minors) ──────────────────────

  it("I1: reset-window rejects a missing/malformed body or blank uid with NO reset side effects", async () => {
    const uid = testUid("i1");
    await prime(uid);
    const spendBefore = await redis.get(`pool:${uid}:spend`);
    const startBefore = await redis.get(`pool:${uid}:start`);

    const cases: Array<[string, unknown, boolean]> = [
      // [label, payload, rawJsonString]
      ["no body", undefined, false],
      ["JSON null", "null", true],
      ["JSON scalar", JSON.stringify("str"), true],
      ["JSON array", [], false],
      ["empty object", {}, false],
      ["blank uid", { uid: "   " }, false],
      ["non-string uid", { uid: 123 }, false],
      ["non-boolean reset_month_free", { uid, reset_month_free: "yes" }, false],
    ];
    for (const [label, payload, rawJson] of cases) {
      const res = await adminApp.inject({
        method: "POST",
        url: "/admin/reset-window",
        headers: rawJson ? { ...ADMIN, "content-type": "application/json" } : ADMIN,
        ...(payload === undefined ? {} : { payload: payload as object }),
      });
      expect(res.statusCode, label).toBe(400);
    }

    // NOTHING was reset: counters/window intact, no audit entry.
    expect(await redis.get(`pool:${uid}:spend`)).toBe(spendBefore);
    expect(await redis.get(`pool:${uid}:start`)).toBe(startBefore);
    expect((await auditEntries()).some((e) => e.action === "reset-window")).toBe(false);
  });

  it("I1: {all:true} is the explicit ALL-users shape; reset_month_free:'false' stays false", async () => {
    const uid = testUid("i1all");
    const toks = await userWithKeys(uid, "free");
    for (const t of Object.values(toks)) fake.keys.get(t)!.spend = 0.5;
    fake.users.get(uid)!.spend = 4;

    // string "false" must NOT be coerced to true (pydantic semantics)
    const one = await admin("POST", "/admin/reset-window", {
      uid,
      reset_month_free: "false",
      operation_id: "admin-test-reset-false",
    });
    expect(one.statusCode).toBe(200);
    expect(fake.users.get(uid)!.spend).toBe(4); // monthly backstop untouched

    const all = await admin("POST", "/admin/reset-window", { all: true, operation_id: "admin-test-reset-all" });
    expect(all.statusCode).toBe(200);
    expect((all.json() as { detail: { mode: string } }).detail.mode).toBe("sync");
  });

  it("I2: an auto-ban is durable in Postgres and survives an unrelated admin update; unban clears it", async () => {
    const uid = testUid("autoban");
    await userWithKeys(uid);
    const oldLimit = deps.env.abuse.abuseStrikeLimit;
    deps.env.abuse.abuseStrikeLimit = 1;
    try {
      await recordStrike(deps, uid, "203.0.113.77");
    } finally {
      deps.env.abuse.abuseStrikeLimit = oldLimit;
    }
    expect(await redis.get(`user:${uid}:banned`)).toBe("auto");
    const rows = (await db.$client`
      SELECT banned_at IS NOT NULL AS banned, banned_reason
      FROM users WHERE uid = ${uid}`) as { banned: boolean; banned_reason: string | null }[];
    expect(rows[0]).toEqual({ banned: true, banned_reason: "auto" });

    // An unrelated admin update must not DEL the ban (the I2 bug).
    const update = await admin("POST", "/admin/user/update", { uid, daily_usd: 5 });
    expect(update.statusCode).toBe(200);
    expect(await redis.get(`user:${uid}:banned`)).toBe("auto");
    expect(await isBanned(deps, uid, "unknown")).toBe(true);

    // Export and audit read the ban too.
    const exp = (await admin("GET", "/admin/export")).json() as {
      users: Record<string, { banned: string | null }>;
    };
    expect(exp.users[uid]!.banned).toBe("auto");

    // An explicit admin unban DOES clear it (clearBan overrides preservation).
    const unban = await admin("POST", "/admin/unban", { uid });
    expect(unban.statusCode).toBe(200);
    expect(await redis.get(`user:${uid}:banned`)).toBeNull();
    expect(await isBanned(deps, uid, "unknown")).toBe(false);
  });

  it("I2: a Redis-only auto-ban is preserved by the projection (Postgres write failed)", async () => {
    const uid = testUid("redisonly");
    await userWithKeys(uid);
    // Simulate recordStrike's Redis write succeeding while its Postgres
    // write failed (the case the projection must not "fix" by deleting).
    await redis.set(`user:${uid}:banned`, "auto");

    const res = await admin("POST", "/admin/set-tier", { uid, tier: "pro" });
    expect(res.statusCode).toBe(200);
    expect(await redis.get(`user:${uid}:banned`)).toBe("auto");
  });

  it("I3: a Redis projection failure after the Postgres commit is a sanitized 500, logged and audited", async () => {
    const uid = testUid("projfail");
    await userWithKeys(uid);
    const original = await getSettings({ db });

    // A Redis whose writes fail the way a dead connection does; reads and
    // the audit list still work (so the durable trail is observable).
    const failingRedis = new Proxy(redis, {
      get(target, prop) {
        if (prop === "set" || prop === "hset") {
          return async () => {
            throw new Error("Connection is closed.");
          };
        }
        const value = Reflect.get(target, prop, target) as unknown;
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
    const failApps = buildMintApps({ ...deps, redis: failingRedis as Redis });
    const inject = (method: string, url: string, payload: unknown) =>
      failApps.adminApp.inject({
        method: method as "POST",
        url,
        headers: ADMIN,
        payload: payload as object,
      });

    try {
      const res = await inject("POST", "/admin/settings", { free_daily_usd: 9 });
      expect(res.statusCode).toBe(500);
      // The raw driver message must never reach the wire; the sanitized
      // degraded-write message is the contract.
      expect((res.json() as { detail: string }).detail).not.toContain("Connection is closed");
      expect((res.json() as { detail: string }).detail).toContain("redis projection failed");
      // Postgres committed (durable authority).
      expect((await getSettings({ db })).free_daily_usd).toBe(9);
      // And the change was audited with a degraded marker.
      const auditRows = (await db.$client`
        SELECT after FROM mint_audit
        WHERE action = 'settings'
          AND after->>'projection_error' IS NOT NULL
        ORDER BY id DESC LIMIT 1`) as Array<{
        after: Record<string, unknown>;
      }>;
      expect(auditRows[0]!.after.projection_error).toBe("redis projection failed");

      // Same for a per-user update: Postgres committed, sanitized 500.
      const userRes = await inject("POST", "/admin/user/update", { uid, daily_usd: 2 });
      expect(userRes.statusCode).toBe(500);
      expect((userRes.json() as { detail: string }).detail).not.toContain("Connection is closed");
      const tierRows = (await db.$client`
        SELECT daily_usd FROM user_plan_overrides WHERE uid = ${uid}`) as Array<{
        daily_usd: string;
      }>;
      expect(tierRows[0]!.daily_usd).toBe("2.0");
    } finally {
      await failApps.publicApp.close();
      await failApps.adminApp.close();
      await storeSettings({ db, redis }, original);
    }
  });

  it("I4: all-users operations only touch mint-provisioned users (chat-only rows excluded)", async () => {
    const mintUid = testUid("i4mint");
    const chatUid = testUid("i4chat");
    await userWithKeys(mintUid);
    // The gateway's users.ensure creates this row for a chat-only user.
    await usersRepo.ensure(db, chatUid, "chat-only@example.com");

    expect(await plansRepo.mintUids(db)).toContain(mintUid);
    expect(await plansRepo.mintUids(db)).not.toContain(chatUid);

    // Count + export exclude the chat-only user.
    const settings = (await admin("GET", "/admin/settings")).json() as { users: number };
    expect(settings.users).toBe((await plansRepo.mintUids(db)).length);
    const exp = (await admin("GET", "/admin/export")).json() as {
      users: Record<string, unknown>;
    };
    expect(exp.users[mintUid]).toBeDefined();
    expect(exp.users[chatUid]).toBeUndefined();

    // ALL-users reset does not touch a chat-only user's counters.
    await redis.set(`pool:${mintUid}:spend`, "9");
    await redis.set(`pool:${chatUid}:spend`, "9");
    const res = await admin("POST", "/admin/reset-window", { all: true, operation_id: "admin-test-reset-all" });
    expect(res.statusCode).toBe(200);
    expect(await redis.get(`pool:${mintUid}:spend`)).toBeNull();
    expect(await redis.get(`pool:${chatUid}:spend`)).toBe("9");
  });

  it("cheap minors: strict coercion, unknown override uid 404, unban never creates a user, prototype settings, no-store", async () => {
    // M1: a present-but-unparseable number is a 400, not a silent no-op.
    const uid = testUid("minor");
    await userWithKeys(uid);
    const badNum = await admin("POST", "/admin/user/update", { uid, daily_usd: "abc" });
    expect(badNum.statusCode).toBe(400);
    expect((badNum.json() as { detail: string }).detail).toBe("daily_usd must be a number");

    // M2: override-only update for an unknown uid is a 404, not an FK 500.
    const ghost = testUid("ghost");
    const noUser = await admin("POST", "/admin/user/update", { uid: ghost, daily_usd: 5 });
    expect(noUser.statusCode).toBe(404);
    expect((noUser.json() as { detail: string }).detail).toBe("user not found");

    // M3: unban of an unknown uid must not create a users row.
    const unban = await admin("POST", "/admin/unban", { uid: ghost });
    expect(unban.statusCode).toBe(200);
    const ghostRows = (await db.$client`
      SELECT uid FROM users WHERE uid = ${ghost}`) as Array<{ uid: string }>;
    expect(ghostRows).toHaveLength(0);

    // M11: prototype keys are not settings.
    const proto = await admin("POST", "/admin/settings", { toString: 1 });
    expect(proto.statusCode).toBe(400);
    expect((proto.json() as { detail: string }).detail).toBe("unknown setting 'toString'");

    // M7: JSON admin responses are never cacheable.
    const json = await admin("GET", "/admin/settings");
    expect(json.headers["cache-control"]).toBe("no-store");
    expect(json.headers["x-content-type-options"]).toBe("nosniff");
  });
});
