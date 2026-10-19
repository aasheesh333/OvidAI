import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance, LightMyRequestResponse } from "fastify";
import { users as usersRepo, type Db } from "@ovid/db";
import type { Redis } from "ioredis";
import type { MintDeps } from "./app.js";
import { buildMintApps } from "./app.js";
import { loadMintEnv } from "./env.js";
import { createLiteLlmAdmin, type LiteLlmAdmin } from "./litellmAdmin.js";
import { getSettings, storeSettings } from "./settings.js";
import { createMintVerifier, rememberEmail } from "./verifier.js";
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
 * Public mint endpoints — /mint, /upgrade, /plans, /v1/models — plus the
 * firebase verifier's contract. Ports of test_limits.py (mint/upgrade/plans
 * paths), the set-tier→mint interplay from test_admin.py, and the
 * _catalog_error matrix from server/images/tests/test_verifier.py.
 *
 * The ERROR LADDER ORDER is pinned here exactly as mint.py fires it:
 * verifier 401s → banned 403 → per-IP 429 → signup-velocity 429 → free-cap
 * 402 (before key creation) → lock 409 (before the breaker) → breaker 503.
 */

const RUN = TEST_DATABASE_URL !== undefined && TEST_MINT_REDIS_URL !== undefined;

const FIXED_NOW = new Date("2026-10-17T12:34:56.000Z");
const APPCHECK = "x";

function baseEnv(extra: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv {
  return {
    NODE_ENV: "test",
    DATABASE_URL: TEST_DATABASE_URL ?? "postgres://u:p@localhost:5432/test",
    REDIS_DB2_URL: TEST_MINT_REDIS_URL ?? "redis://localhost:6379/9",
    LITELLM_MASTER_KEY: MASTER_KEY,
    OVID_ADMIN_MASTER_KEY: "sk-admin-test",
    OVID_INTERNAL_API_SECRET: "sk-internal-test",
    FIREBASE_PROJECT_ID: "ovid-test",
    APPCHECK_ENABLED: "true",
    ALLOW_TEST_UPGRADE: "true",
    ...extra,
  };
}

describe.skipIf(!RUN)("public mint endpoints (mintRoutes.ts)", () => {
  let db: Db;
  let redis: Redis;
  let fake: FakeLiteLlm;
  let deps: MintDeps;
  let app: FastifyInstance;
  let originalRawModels: LiteLlmAdmin["rawModels"];

  beforeAll(async () => {
    db = await resetTestDb();
    redis = await openFlushedRedis();
    fake = new FakeLiteLlm();
    await fake.start();
    deps = {
      db,
      redis,
      litellm: createLiteLlmAdmin(fake.baseUrl, MASTER_KEY),
      env: loadMintEnv(baseEnv({ LITELLM_BASE: fake.baseUrl })),
      alerter: async () => {},
      verifyIdentity: async ({ authorization }) => {
        const token = authorization.replace(/^bearer\s+/i, "");
        if (token.startsWith("web|")) {
          return { uid: token.slice(4), email: `${token.slice(4)}@example.com`, platform: "web" };
        }
        return { uid: token, email: `${token}@example.com`, platform: "android" };
      },
      clock: () => FIXED_NOW,
      mintLock: { pollMs: 1, polls: 2 },
    };
    app = buildMintApps(deps).publicApp;
    await getSettings({ db });
    standardModels(fake);
    originalRawModels = deps.litellm.rawModels;
  }, 60_000);

  afterAll(async () => {
    await app.close();
    await fake.stop();
    await closeRedis(redis);
    await closeDb(db);
  });

  beforeEach(async () => {
    await redis.flushdb();
    fake.reset();
    standardModels(fake);
    deps.litellm.rawModels = originalRawModels;
    deps.env.allowTestUpgrade = true;
    deps.mintLock = { pollMs: 1, polls: 2 };
  });

  function mint(uid: string, extra: Record<string, string> = {}): Promise<LightMyRequestResponse> {
    return app.inject({
      method: "POST",
      url: "/mint",
      headers: { authorization: `Bearer ${uid}`, "x-firebase-appcheck": APPCHECK, ...extra },
    });
  }

  function hourKey(): string {
    return `mintrate:1.2.3.4:${Math.floor(FIXED_NOW.getTime() / 1000 / 3600)}`;
  }

  function velocityKey(): string {
    return `ipnew:1.2.3.4:${Math.floor(FIXED_NOW.getTime() / 1000 / 600)}`;
  }

  function newkeysKey(): string {
    return `newkeys:${Math.floor(FIXED_NOW.getTime() / 1000 / 3600)}`;
  }

  async function userWithKeys(uid: string, tier: string | null = null): Promise<{ android: string; web: string }> {
    await usersRepo.ensure(db, uid, null);
    const android = fake.addKey(`tok-${uid}-a`);
    const web = fake.addKey(`tok-${uid}-w`);
    await redis.set(`user:${uid}:keyid`, android);
    await redis.set(`user:${uid}:web:keyid`, web);
    fake.users.set(uid, { spend: 0, budget_duration: "24h" });
    if (tier !== null && tier !== "free") await redis.set(`user:${uid}:tier`, tier);
    return { android, web };
  }

  // ------------------------------------------------------------------ /mint

  it("creates exactly one key and returns the SAME key on a second mint", async () => {
    const uid = testUid("mint");
    const first = await mint(uid);
    expect(first.statusCode).toBe(200);
    const body = first.json() as { key: string; tier: string; base_url: string };
    expect(body.key).toBe("sk-live-1");
    expect(body.tier).toBe("free");
    expect(body.base_url).toBe(deps.env.publicBaseUrl);
    expect(fake.posts("/key/generate")).toHaveLength(1);

    // verifier's email side effect (Postgres authoritative + Redis mirror)
    expect(await redis.get(`user:${uid}:email`)).toBe(`${uid}@example.com`);
    expect(await redis.get(`email:${uid}@example.com`)).toBe(uid);
    const rows = (await db.$client`SELECT email FROM users WHERE uid = ${uid}`) as {
      email: string | null;
    }[];
    expect(rows[0]?.email).toBe(`${uid}@example.com`);

    const second = await mint(uid);
    expect(second.statusCode).toBe(200);
    expect((second.json() as { key: string }).key).toBe(body.key);
    expect(fake.posts("/key/generate")).toHaveLength(1);
  });

  it("fences /mint and /upgrade while a deletion tombstone is pending", async () => {
    const uid = testUid("fenced");
    await usersRepo.ensure(db, uid, null);
    await db.$client`
      INSERT INTO account_deletions (uid, state, delete_after, record)
      VALUES (${uid}, 'pending', 0, '{}'::jsonb)`;
    const mintRes = await mint(uid);
    expect(mintRes.statusCode).toBe(403);
    expect(mintRes.json()).toEqual({ detail: "account_deletion_pending" });
    expect(fake.posts("/key/generate")).toHaveLength(0);

    const upgradeRes = await app.inject({
      method: "POST",
      url: "/upgrade",
      headers: { authorization: `Bearer ${uid}`, "x-firebase-appcheck": APPCHECK },
      payload: { tier: "pro" },
    });
    expect(upgradeRes.statusCode).toBe(403);
    expect(upgradeRes.json()).toEqual({ detail: "account_deletion_pending" });

    // A cancelled tombstone (recovery) no longer fences.
    await db.$client`UPDATE account_deletions SET state = 'cancelled' WHERE uid = ${uid}`;
    expect((await mint(uid)).statusCode).toBe(200);
  });

  it("web platform stores the key under user:{uid}:web:keyid and sends team_id", async () => {
    const uid = testUid("mintweb");
    const res = await mint(`web|${uid}`);
    expect(res.statusCode).toBe(200);
    expect(await redis.get(`user:${uid}:web:keyid`)).toBe("hashed-1");
    expect(await redis.get(`user:${uid}:keyid`)).toBeNull();
    const gen = fake.posts("/key/generate")[0]!;
    expect(gen.team_id).toBe("team-web");
    expect(gen.metadata).toMatchObject({ platform: "web" });
  });

  it("banned uid → 403 'account suspended' (before any key work)", async () => {
    const uid = testUid("banned");
    await redis.set(`user:${uid}:banned`, "auto");
    const res = await mint(uid);
    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({ detail: "account suspended" });
    expect(fake.posts("/key/generate")).toHaveLength(0);
  });

  it("IP ban → 403 'account suspended'", async () => {
    const uid = testUid("ipban");
    await redis.set("ban:ip:9.9.9.9", "1");
    const res = await mint(uid, { "x-forwarded-for": "9.9.9.9, 10.0.0.1" });
    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({ detail: "account suspended" });
  });

  it("41st mint call from one IP in the window → 429 exact message", async () => {
    const uid = testUid("rate");
    await redis.set(hourKey(), "40");
    const res = await mint(uid, { "x-forwarded-for": "1.2.3.4" });
    expect(res.statusCode).toBe(429);
    expect(res.json()).toEqual({ detail: "too many requests from this network — retry later" });
    expect(fake.posts("/key/generate")).toHaveLength(0);
  });

  it("13th new signup from one IP in the velocity window → 429 exact message", async () => {
    const uid = testUid("vel");
    await redis.set(velocityKey(), "12");
    const res = await mint(uid, { "x-forwarded-for": "1.2.3.4" });
    expect(res.statusCode).toBe(429);
    expect(res.json()).toEqual({
      detail: "sign-ups from this network are busy right now — please retry in a few minutes",
    });
    expect(await redis.get("ban:ip:1.2.3.4")).toBeNull();
    expect(fake.posts("/key/generate")).toHaveLength(0);
  });

  it("free user with the monthly cap exhausted → 402 (BEFORE key creation)", async () => {
    const uid = testUid("cap");
    fake.users.set(uid, { spend: 10 });
    const res = await mint(uid);
    expect(res.statusCode).toBe(402);
    expect(res.json()).toEqual({ detail: "monthly free limit reached" });
    expect(fake.posts("/key/generate")).toHaveLength(0);
  });

  it("ORDER: free-cap 402 precedes the new-key breaker 503", async () => {
    const uid = testUid("order402");
    fake.users.set(uid, { spend: 10 });
    await redis.set(newkeysKey(), "500");
    const res = await mint(uid);
    expect(res.statusCode).toBe(402);
    expect(res.json()).toEqual({ detail: "monthly free limit reached" });
  });

  it("ORDER: a held lock 409 precedes the new-key breaker 503", async () => {
    const uid = testUid("order409");
    await redis.set(`mintlock:${uid}`, "1", "EX", 30);
    await redis.set(newkeysKey(), "500");
    const res = await mint(uid);
    expect(res.statusCode).toBe(409);
    expect(res.json()).toEqual({ detail: "key creation in progress, retry" });
    expect(fake.posts("/key/generate")).toHaveLength(0);
  });

  it("breaker fires inside the acquired lock → 503 exact message", async () => {
    const uid = testUid("breaker");
    await redis.set(newkeysKey(), "500");
    const res = await mint(uid);
    expect(res.statusCode).toBe(503);
    expect(res.json()).toEqual({
      detail: "sign-ups are temporarily paused — please try again shortly",
    });
    expect(await redis.get("alert:newkey_spike")).toBe("501");
    expect(fake.posts("/key/generate")).toHaveLength(0);
  });

  it("401s come from the verifier: missing bearer then missing app check", async () => {
    const noBearer = await app.inject({ method: "POST", url: "/mint" });
    expect(noBearer.statusCode).toBe(401);
    expect(noBearer.json()).toEqual({ detail: "missing bearer id token" });

    const noAppcheck = await app.inject({
      method: "POST",
      url: "/mint",
      headers: { authorization: "Bearer someone" },
    });
    expect(noAppcheck.statusCode).toBe(401);
    expect(noAppcheck.json()).toEqual({ detail: "missing app check token" });
  });

  // --------------------------------------------------------------- /upgrade

  it("POST /upgrade with ALLOW_TEST_UPGRADE=false → 403 exact message", async () => {
    deps.env.allowTestUpgrade = false;
    const res = await app.inject({
      method: "POST",
      url: "/upgrade",
      headers: { authorization: "Bearer u", "x-firebase-appcheck": APPCHECK },
      payload: { tier: "pro" },
    });
    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({ detail: "test upgrade is disabled" });
  });

  it("POST /upgrade '7x' sets Postgres users.tier=pro, Redis tier '7x', and reapplies", async () => {
    const uid = testUid("up");
    const toks = await userWithKeys(uid);
    const res = await app.inject({
      method: "POST",
      url: "/upgrade",
      headers: { authorization: `Bearer ${uid}`, "x-firebase-appcheck": APPCHECK },
      payload: { tier: "7x" },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ ok: true, tier: "7x" });

    expect(await redis.get(`user:${uid}:tier`)).toBe("7x");
    const rows = (await db.$client`SELECT tier FROM users WHERE uid = ${uid}`) as { tier: string }[];
    expect(rows[0]?.tier).toBe("pro");

    // reapplyUser pushed the new plan budget (0.15 × 23) to BOTH keys
    for (const tok of Object.values(toks)) {
      expect(fake.keys.get(tok)!.max_budget).toBeCloseTo(3.45, 10);
    }
  });

  it("POST /upgrade with an unknown/disabled tier falls back to free", async () => {
    const uid = testUid("upfree");
    await userWithKeys(uid);
    const res = await app.inject({
      method: "POST",
      url: "/upgrade",
      headers: { authorization: `Bearer ${uid}`, "x-firebase-appcheck": APPCHECK },
      payload: { tier: "bogus" },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ ok: true, tier: "free" });
    expect(await redis.get(`user:${uid}:tier`)).toBeNull();
    const rows = (await db.$client`SELECT tier FROM users WHERE uid = ${uid}`) as { tier: string }[];
    expect(rows[0]?.tier).toBe("free");
  });

  // ----------------------------------------------------------------- /plans

  it("GET /plans lists enabled plans only, with the window string", async () => {
    const original = await getSettings({ db });
    try {
      await storeSettings(
        { db, redis },
        {
          ...original,
          plans: original.plans.map((p) => (p.id === "pro" ? { ...p, enabled: false } : p)),
        },
      );
      const res = await app.inject({ method: "GET", url: "/plans" });
      expect(res.statusCode).toBe(200);
      const plans = (res.json() as {
        plans: { id: string; name: string; price_usd: number; aliases: string[]; window: string }[];
      }).plans;
      const ids = plans.map((p) => p.id);
      expect(ids).toEqual(["free", "starter", "max"]);
      const starter = plans.find((p) => p.id === "starter")!;
      expect(starter).toMatchObject({
        name: "Starter",
        price_usd: 5,
        aliases: ["3x"],
        window: "24h",
        // SH-006: the same live cards /usage returns.
        tier: "3x",
        mult: 3,
        product_id: "ovid_plus_monthly",
      });
      expect((starter as unknown as { features: string[] }).features).toContain(
        "About 3x the Free allowance",
      );
    } finally {
      await storeSettings({ db, redis }, original);
    }
  });

  // ------------------------------------------------------------- /v1/models

  function stubModels(status: number, text: string, body: unknown = null): void {
    deps.litellm.rawModels = async () => ({ status, body, text });
  }

  it("GET /v1/models forwards the user's bearer and reshapes to the OpenAI list", async () => {
    let seen = "";
    deps.litellm.rawModels = async (authorization) => {
      seen = authorization;
      return {
        status: 200,
        body: { data: [{ id: "auto" }, { id: "big-pro" }, { id: "ovid-image" }] },
        text: "",
      };
    };
    const res = await app.inject({
      method: "GET",
      url: "/v1/models",
      headers: { authorization: "Bearer sk-user-key" },
    });
    expect(res.statusCode).toBe(200);
    expect(seen).toBe("Bearer sk-user-key");
    expect(res.json()).toEqual({
      object: "list",
      data: [
        { id: "auto", object: "model", owned_by: "ovid" },
        { id: "big-pro", object: "model", owned_by: "ovid" },
        { id: "ovid-image", object: "model", owned_by: "ovid" },
      ],
    });
    expect(res.headers["cache-control"]).toBe("no-store");
    expect(res.headers["x-ovid-gateway"]).toBe("2");
  });

  it("missing bearer → 401 sign_in_required without calling upstream", async () => {
    let called = false;
    deps.litellm.rawModels = async () => {
      called = true;
      return { status: 200, body: { data: [] }, text: "" };
    };
    const res = await app.inject({ method: "GET", url: "/v1/models" });
    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ error: { code: "sign_in_required" } });
    expect(called).toBe(false);
    expect(res.headers["x-ovid-gateway"]).toBe("2");
  });

  it("upstream error matrix matches _catalog_error", async () => {
    const cases: [number, string, number, string][] = [
      [401, '{"error":"invalid key"}', 401, "key_invalid"],
      [403, '{"error":"blocked"}', 401, "key_invalid"],
      [400, '{"error":{"message":"ExceededBudget: Crossed budget"}}', 402, "budget_exceeded"],
      [401, '{"error":{"message":"Budget has been exceeded"}}', 402, "budget_exceeded"],
      [429, '{"error":{"message":"BUDGET exceeded"}}', 402, "budget_exceeded"],
      [429, '{"error":"slow down"}', 429, "rate_limited"],
      [502, "{}", 503, "catalog_unavailable"],
      [500, "{}", 503, "catalog_unavailable"],
    ];
    for (const [upstream, text, status, code] of cases) {
      stubModels(upstream, text);
      const res = await app.inject({
        method: "GET",
        url: "/v1/models",
        headers: { authorization: "Bearer sk-user-key" },
      });
      expect([res.statusCode, (res.json() as { error: { code: string } }).error.code]).toEqual([
        status,
        code,
      ]);
      expect(res.headers["x-ovid-gateway"]).toBe("2");
      expect(res.headers["cache-control"]).toBe("no-store");
      expect(res.body).not.toContain("sk-user-key");
    }
  });

  it("network failure → 503 catalog_unavailable", async () => {
    deps.litellm.rawModels = async () => {
      throw new Error("connect timeout");
    };
    const res = await app.inject({
      method: "GET",
      url: "/v1/models",
      headers: { authorization: "Bearer sk-user-key" },
    });
    expect(res.statusCode).toBe(503);
    expect(res.json()).toEqual({ error: { code: "catalog_unavailable" } });
  });

  // -------------------------------------------------------------- verifier

  it("rememberEmail normalizes, mirrors Redis, and writes Postgres authoritatively", async () => {
    const uid = testUid("email");
    await usersRepo.ensure(db, uid, "old@example.com");
    await rememberEmail({ db, redis }, uid, "  MiXeD@Example.COM ");
    expect(await redis.get(`user:${uid}:email`)).toBe("mixed@example.com");
    expect(await redis.get(`email:mixed@example.com`)).toBe(uid);
    const rows = (await db.$client`SELECT email FROM users WHERE uid = ${uid}`) as {
      email: string | null;
    }[];
    expect(rows[0]?.email).toBe("mixed@example.com");
  });

  it("createMintVerifier maps app ids to platforms and enforces the 401/403 contract", async () => {
    const env = loadMintEnv(
      baseEnv({
        OVID_APPCHECK_APPS: "android:1:234:android:abc,web:1:234:web:xyz",
      }),
    );
    const verify = createMintVerifier(env, {
      verifyIdToken: async (token) => ({ uid: `uid-${token}`, email: "e@example.com" }),
      verifyAppCheck: async (token) => ({ appId: token }),
    });

    await expect(
      verify({ authorization: "", appcheck: "", xff: "", xRealIp: "" }),
    ).rejects.toMatchObject({ status: 401, detail: "missing bearer id token" });

    await expect(
      verify({ authorization: "Bearer t", appcheck: "", xff: "", xRealIp: "" }),
    ).rejects.toMatchObject({ status: 401, detail: "missing app check token" });

    const android = await verify({
      authorization: "Bearer t1",
      appcheck: "1:234:android:abc",
      xff: "",
      xRealIp: "",
    });
    expect(android).toEqual({ uid: "uid-t1", email: "e@example.com", platform: "android" });

    const web = await verify({
      authorization: "Bearer t2",
      appcheck: "1:234:web:xyz",
      xff: "",
      xRealIp: "",
    });
    expect(web.platform).toBe("web");

    await expect(
      verify({ authorization: "Bearer t3", appcheck: "unknown-app", xff: "", xRealIp: "" }),
    ).rejects.toMatchObject({ status: 403, detail: "unknown app" });
  });

  it("createMintVerifier falls back to the ':web:' heuristic and wraps bad tokens", async () => {
    const env = loadMintEnv(baseEnv());
    const verify = createMintVerifier(env, {
      verifyIdToken: async () => ({ uid: "u1", email: null }),
      verifyAppCheck: async (token) => {
        if (token === "bad") throw new Error("boom");
        return { appId: "1:234:web:xyz" };
      },
    });

    const identity = await verify({
      authorization: "Bearer t",
      appcheck: "1:234:web:xyz",
      xff: "",
      xRealIp: "",
    });
    expect(identity.platform).toBe("web");

    await expect(
      verify({ authorization: "Bearer t", appcheck: "bad", xff: "", xRealIp: "" }),
    ).rejects.toMatchObject({ status: 401, detail: "invalid app check token: boom" });
  });

  it("createMintVerifier: APPCHECK_ENABLED=false needs no token and yields android", async () => {
    const env = loadMintEnv(baseEnv({ APPCHECK_ENABLED: "false" }));
    let appcheckCalled = false;
    const verify = createMintVerifier(env, {
      verifyIdToken: async () => ({ uid: "u1", email: null }),
      verifyAppCheck: async () => {
        appcheckCalled = true;
        return { appId: "1:234:web:xyz" };
      },
    });
    const identity = await verify({
      authorization: "Bearer t",
      appcheck: "",
      xff: "",
      xRealIp: "",
    });
    expect(identity.platform).toBe("android");
    expect(appcheckCalled).toBe(false);
  });

  it("createMintVerifier wraps an invalid ID token as 401", async () => {
    const env = loadMintEnv(baseEnv({ APPCHECK_ENABLED: "false" }));
    const verify = createMintVerifier(env, {
      verifyIdToken: async () => {
        throw new Error("expired");
      },
    });
    await expect(
      verify({ authorization: "Bearer t", appcheck: "", xff: "", xRealIp: "" }),
    ).rejects.toMatchObject({ status: 401, detail: "invalid id token: expired" });
  });

  // -------------------------------------------------------------- secrets

  it("production sources contain no secret literals (README rule)", () => {
    const srcDir = new URL(".", import.meta.url).pathname;
    const files: string[] = [];
    const walk = (dir: string): void => {
      for (const name of readdirSync(dir)) {
        const path = join(dir, name);
        const stat = statSync(path);
        if (stat.isDirectory()) {
          if (name !== "test") walk(path);
          continue;
        }
        if (!name.endsWith(".ts") || name.endsWith(".test.ts")) continue;
        files.push(path);
      }
    };
    walk(srcDir);
    expect(files.length).toBeGreaterThan(0);
    const patterns = [
      /sk-[A-Za-z0-9_-]{12,}/,
      /AIza[0-9A-Za-z_-]{20,}/,
      /\d{8,}:[A-Za-z0-9_-]{30,}/, // telegram bot token
    ];
    for (const file of files) {
      const text = readFileSync(file, "utf8");
      for (const pattern of patterns) {
        expect(text, `${file} must not contain ${pattern}`).not.toMatch(pattern);
      }
    }
  });
});
