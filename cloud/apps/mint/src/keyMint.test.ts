import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { Db } from "@ovid/db";
import type { Redis } from "ioredis";
import type { MintDeps } from "./app.js";
import { HttpContractError } from "./app.js";
import { loadMintEnv } from "./env.js";
import { litellmMintOrGet, userKeyIds, webTeamId } from "./keyMint.js";
import { createLiteLlmAdmin } from "./litellmAdmin.js";
import { getSettings } from "./settings.js";
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
 * keyMint.ts — the port of litellm_mint_or_get. One Google account == exactly
 * one key per platform, race-safe via mintlock:{ns}{uid}; the global new-key
 * breaker fires INSIDE that lock (after a lost lock race has already 409'd).
 *
 * Real Postgres (settings authority) + Redis db9 + a local FakeLiteLLM.
 */

const RUN = TEST_DATABASE_URL !== undefined && TEST_MINT_REDIS_URL !== undefined;

const FIXED_NOW = new Date("2026-10-17T12:34:56.000Z");

describe.skipIf(!RUN)("key minting (keyMint.ts)", () => {
  let db: Db;
  let redis: Redis;
  let fake: FakeLiteLlm;
  let baseDeps: MintDeps;

  beforeAll(async () => {
    db = await resetTestDb();
    redis = await openFlushedRedis();
    fake = new FakeLiteLlm();
    await fake.start();
    baseDeps = {
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
      clock: () => FIXED_NOW,
    };
    await getSettings({ db });
    standardModels(fake);
  }, 60_000);

  afterAll(async () => {
    await fake.stop();
    await closeRedis(redis);
    await closeDb(db);
  });

  beforeEach(async () => {
    await redis.flushdb();
    fake.reset();
    standardModels(fake);
  });

  /** Per-test deps with optional overrides (never mutate the shared base). */
  function deps(over: Partial<MintDeps> = {}): MintDeps {
    return { ...baseDeps, ...over };
  }

  function newkeysKey(now: Date = FIXED_NOW): string {
    return `newkeys:${Math.floor(now.getTime() / 1000 / 3600)}`;
  }

  it("creates exactly one key, stores both Redis ids, and re-mints the SAME key", async () => {
    const uid = testUid("km");
    const first = await litellmMintOrGet(deps(), uid, "free", "android");

    expect(fake.posts("/key/generate")).toHaveLength(1);
    expect(first).toBe("sk-live-1");
    expect(await redis.get(`user:${uid}:keyid`)).toBe("hashed-1");
    expect(await redis.get(`user:${uid}:key`)).toBe("sk-live-1");
    expect(await redis.get(`user:${uid}:web:keyid`)).toBeNull();

    const gen = fake.posts("/key/generate")[0]!;
    expect(gen.user_id).toBe(uid);
    expect(gen.max_budget).toBeCloseTo(0.15, 10);
    expect(gen.budget_duration).toBe("24h");
    expect(gen.metadata).toEqual({ tier: "free", ovid_uid: uid, platform: "android" });
    expect(gen.rpm_limit).toBe(240);
    expect(gen.tpm_limit).toBe(4_000_000);
    expect(gen.max_parallel_requests).toBe(16);
    // The public catalog + the image alias are the explicit model scope.
    expect(gen.models).toEqual(expect.arrayContaining(["auto", "ovid-image"]));

    const second = await litellmMintOrGet(deps(), uid, "free", "android");
    expect(second).toBe(first);
    expect(fake.posts("/key/generate")).toHaveLength(1);

    const updates = fake.posts("/key/update");
    expect(updates.length).toBeGreaterThan(0);
    const last = updates[updates.length - 1]!;
    expect(last.key).toBe("hashed-1");
    expect(last.max_budget).toBeCloseTo(0.15, 10);
    // LiteLLM restarts the budget clock whenever budget_duration is sent.
    expect(last).not.toHaveProperty("budget_duration");
  });

  it("serializes concurrent double-mints for a brand-new uid into ONE key", async () => {
    const uid = testUid("race");
    const [a, b] = await Promise.all([
      litellmMintOrGet(deps(), uid, "free", "android"),
      litellmMintOrGet(deps(), uid, "free", "android"),
    ]);
    expect(a).toBe(b);
    expect(fake.posts("/key/generate")).toHaveLength(1);
  });

  it("waits on a held mintlock and returns the key written by the holder", async () => {
    const uid = testUid("wait");
    await redis.set(`mintlock:${uid}`, "1", "EX", 30);
    const timer = setTimeout(() => {
      void redis.set(`user:${uid}:key`, "sk-from-holder");
    }, 10);
    try {
      const key = await litellmMintOrGet(deps(), uid, "free", "android", {
        pollMs: 5,
        polls: 100,
      });
      expect(key).toBe("sk-from-holder");
      expect(fake.posts("/key/generate")).toHaveLength(0);
    } finally {
      clearTimeout(timer);
    }
  });

  it("times out the lock wait with the exact 409 contract", async () => {
    const uid = testUid("lock");
    await redis.set(`mintlock:${uid}`, "1", "EX", 30);
    await expect(
      litellmMintOrGet(deps(), uid, "free", "android", { pollMs: 1, polls: 3 }),
    ).rejects.toMatchObject({
      status: 409,
      detail: "key creation in progress, retry",
    });
    expect(fake.posts("/key/generate")).toHaveLength(0);
  });

  it("re-issues an unusable (404/expired) stored key after /key/delete", async () => {
    const uid = testUid("dead");
    await redis.set(`user:${uid}:keyid`, "hashed-dead");
    await redis.set(`user:${uid}:key`, "sk-dead");

    const key = await litellmMintOrGet(deps(), uid, "free", "android");
    expect(key).toBe("sk-live-1");
    const deletes = fake.calls.filter((c) => c.method === "POST" && c.path === "/key/delete");
    expect(deletes).toHaveLength(1);
    expect(deletes[0]!.body).toEqual({ keys: ["hashed-dead"] });
    expect(await redis.get(`user:${uid}:keyid`)).toBe("hashed-1");
    expect(fake.posts("/key/generate")).toHaveLength(1);
  });

  it("stores web keys under user:{uid}:web:keyid and sends team_id", async () => {
    const uid = testUid("web");
    const key = await litellmMintOrGet(deps(), uid, "free", "web");

    expect(key).toBe("sk-live-1");
    expect(await redis.get(`user:${uid}:web:keyid`)).toBe("hashed-1");
    expect(await redis.get(`user:${uid}:web:key`)).toBe("sk-live-1");
    expect(await redis.get(`user:${uid}:keyid`)).toBeNull();

    const gen = fake.posts("/key/generate")[0]!;
    expect(gen.team_id).toBe("team-web");
    expect(gen.metadata).toEqual({ tier: "free", ovid_uid: uid, platform: "web" });
    expect(await redis.get("config:web_team_id")).toBe("team-web");
  });

  it("webTeamId creates the team once and re-syncs the daily budget on change", async () => {
    const uid = testUid("team");
    const first = await webTeamId(deps());
    expect(first).toBe("team-web");
    expect(fake.posts("/team/new")).toHaveLength(1);
    expect(await redis.get("config:web_team_budget")).toBe("25.0");

    // unchanged budget → no /team/update
    await webTeamId(deps());
    expect(fake.posts("/team/update")).toHaveLength(0);

    // admin changed WEB_TEAM_DAILY_USD → re-sync once, cache the new value
    const changed = deps({
      env: { ...baseDeps.env, webTeamDailyUsd: 40 },
    });
    await webTeamId(changed);
    const updates = fake.posts("/team/update");
    expect(updates).toHaveLength(1);
    expect(updates[0]).toMatchObject({ team_id: "team-web", max_budget: 40, budget_duration: "1d" });
    expect(await redis.get("config:web_team_budget")).toBe("40.0");
    void uid;
  });

  it("fires the global new-key breaker INSIDE the lock with the exact 503", async () => {
    const uid = testUid("breaker");
    await redis.set(newkeysKey(), "500");
    const alerts: string[] = [];
    const d = deps({ alerter: async (kind) => void alerts.push(kind) });

    await expect(litellmMintOrGet(d, uid, "free", "android")).rejects.toMatchObject({
      status: 503,
      detail: "sign-ups are temporarily paused — please try again shortly",
    });
    expect(fake.posts("/key/generate")).toHaveLength(0);
    expect(await redis.get("alert:newkey_spike")).toBe("501");
    expect(await redis.get(`mintlock:${uid}`)).toBeNull(); // finally released
    expect(alerts).toContain("newkey_spike");
  });

  it("userKeyIds delegates to the Task-5 helper and returns both namespaces", async () => {
    const uid = testUid("ids");
    await redis.set(`user:${uid}:keyid`, "a");
    await redis.set(`user:${uid}:web:keyid`, "w");
    expect(await userKeyIds(deps(), uid)).toEqual({ "": "a", "web:": "w" });
  });

  it("uses the exact 409 class, not a bare Error", async () => {
    const uid = testUid("class");
    await redis.set(`mintlock:${uid}`, "1", "EX", 30);
    const err = await litellmMintOrGet(deps(), uid, "free", "android", {
      pollMs: 1,
      polls: 1,
    }).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(HttpContractError);
  });
});
