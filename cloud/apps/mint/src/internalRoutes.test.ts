import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance, LightMyRequestResponse } from "fastify";
import { users as usersRepo, type Db } from "@ovid/db";
import type { Redis } from "ioredis";
import { INTERNAL_MINT_PATH, signInternalRequest } from "@ovid/shared";
import type { MintDeps } from "./app.js";
import { buildMintApps } from "./app.js";
import { loadMintEnv } from "./env.js";
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
 * P9 Task 9 — the ADMIN-only internal mint route.
 *
 * The caller is a trusted process (gateway/worker) authenticated by a
 * per-request HMAC over "METHOD\nPATH\nUID\nTIMESTAMP". There is no Firebase
 * verifier on this path: the signature IS the identity, and the uid it signs
 * is the only uid the route will act on. Replays inside the ±300 s window are
 * deliberately idempotent (the mint lock + per-(uid, platform) key make the
 * result identical) — there is no nonce store.
 */

const RUN = TEST_DATABASE_URL !== undefined && TEST_MINT_REDIS_URL !== undefined;

const SECRET = "sk-internal-t9-secret-0123456789abcdef0123456789abcdef";
const FIXED_NOW = new Date("2026-10-17T12:34:56.000Z");
const NOW_S = Math.floor(FIXED_NOW.getTime() / 1000);

function baseEnv(extra: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv {
  return {
    NODE_ENV: "test",
    DATABASE_URL: TEST_DATABASE_URL ?? "postgres://u:p@localhost:5432/test",
    REDIS_DB2_URL: TEST_MINT_REDIS_URL ?? "redis://localhost:6379/9",
    LITELLM_MASTER_KEY: MASTER_KEY,
    OVID_ADMIN_MASTER_KEY: "sk-admin-test",
    OVID_INTERNAL_API_SECRET: SECRET,
    FIREBASE_PROJECT_ID: "ovid-test",
    APPCHECK_ENABLED: "false",
    ...extra,
  };
}

function signedHeaders(
  uid: string,
  opts: { secret?: string; timestamp?: number } = {},
): Record<string, string> {
  const timestamp = opts.timestamp ?? NOW_S;
  return {
    "content-type": "application/json",
    "x-ovid-timestamp": Buffer.from(String(timestamp), "utf8").toString("base64"),
    "x-ovid-signature": signInternalRequest(
      opts.secret ?? SECRET,
      "POST",
      INTERNAL_MINT_PATH,
      uid,
      timestamp,
    ),
  };
}

describe.skipIf(!RUN)("internal mint route (admin listener only)", () => {
  let db: Db;
  let redis: Redis;
  let fake: FakeLiteLlm;
  let deps: MintDeps;
  let publicApp: FastifyInstance;
  let adminApp: FastifyInstance;

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
      verifyIdentity: async () => ({ uid: "unused", email: null, platform: "android" }),
      clock: () => FIXED_NOW,
      mintLock: { pollMs: 1, polls: 2 },
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
  });

  function mintInternal(
    body: unknown,
    opts: { secret?: string; timestamp?: number; uidForSignature?: string } = {},
  ): Promise<LightMyRequestResponse> {
    const uid =
      opts.uidForSignature ??
      (typeof body === "object" && body !== null && "uid" in body
        ? String((body as { uid: unknown }).uid)
        : "");
    return adminApp.inject({
      method: "POST",
      url: INTERNAL_MINT_PATH,
      headers: signedHeaders(uid, opts),
      payload: body as object,
    });
  }

  it("valid signature → 200 with the minted key, stored tier and base URL", async () => {
    const uid = testUid("internal");
    const res = await mintInternal({ uid });
    expect(res.statusCode, res.body).toBe(200);
    expect(res.json()).toEqual({
      key: "sk-live-1",
      tier: "free",
      baseUrl: deps.env.publicBaseUrl,
    });
    expect(await redis.get(`user:${uid}:key`)).toBe("sk-live-1");

    // Same key on a replay — idempotent by design (no nonce store).
    const replay = await mintInternal({ uid });
    expect(replay.statusCode).toBe(200);
    expect(replay.json()).toEqual(res.json());
    expect(fake.posts("/key/generate")).toHaveLength(1);
  });

  it("a timestamp 301 s outside the window → 401", async () => {
    const uid = testUid("internal-old");
    const stale = await mintInternal({ uid }, { timestamp: NOW_S - 301 });
    expect(stale.statusCode).toBe(401);
    const future = await mintInternal({ uid }, { timestamp: NOW_S + 301 });
    expect(future.statusCode).toBe(401);
    // 300 s exactly is still inside the window.
    const edge = await mintInternal({ uid }, { timestamp: NOW_S - 300 });
    expect(edge.statusCode).toBe(200);
  });

  it("wrong secret → 401 with the same body as a missing signature", async () => {
    const uid = testUid("internal-wrong");
    const wrong = await mintInternal({ uid }, { secret: `${SECRET}-other` });
    expect(wrong.statusCode).toBe(401);

    const missing = await adminApp.inject({
      method: "POST",
      url: INTERNAL_MINT_PATH,
      headers: { "content-type": "application/json" },
      payload: { uid },
    });
    expect(missing.statusCode).toBe(401);
    expect(wrong.json()).toEqual(missing.json());
  });

  it("a uid swapped in the body after signing → 401 (the signature binds the uid)", async () => {
    const signedUid = testUid("internal-a");
    const bodyUid = testUid("internal-b");
    const res = await mintInternal({ uid: bodyUid }, { uidForSignature: signedUid });
    expect(res.statusCode).toBe(401);
    expect(await redis.get(`user:${bodyUid}:key`)).toBeNull();
  });

  it("banned uid → 403 account suspended", async () => {
    const uid = testUid("internal-banned");
    await redis.set(`user:${uid}:banned`, "admin");
    const res = await mintInternal({ uid });
    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({ detail: "account suspended" });
  });

  it("free cap exhausted → 402 monthly free limit reached (before any key work)", async () => {
    const uid = testUid("internal-cap");
    await usersRepo.ensure(db, uid, null);
    fake.users.set(uid, { spend: 10.0, budget_duration: "30d", max_budget: 10 });
    const res = await mintInternal({ uid });
    expect(res.statusCode).toBe(402);
    expect(res.json()).toEqual({ detail: "monthly free limit reached" });
    expect(fake.posts("/key/generate")).toHaveLength(0);
  });

  it("free cap exhausted with a LiteLLM budget clock → 402 carries x-ovid-resets-at", async () => {
    const uid = testUid("internal-cap-reset");
    await usersRepo.ensure(db, uid, null);
    // The backstop is the user budget over 30d, so the clock LiteLLM reports
    // for it (user_info.budget_reset_at) is the countdown the client shows.
    fake.users.set(uid, {
      spend: 10.0,
      budget_duration: "30d",
      max_budget: 10,
      budget_reset_at: "2026-11-01T08:09:10.500000Z",
    });
    const res = await mintInternal({ uid });
    expect(res.statusCode).toBe(402);
    // The hook's _iso shape (ovid_pools.py): whole-second UTC "Z". The
    // gateway's forwarder normalizes to epoch ms for the client.
    expect(res.headers["x-ovid-resets-at"]).toBe("2026-11-01T08:09:10Z");
  });

  it("free cap exhausted with no reported clock → 402 without x-ovid-resets-at", async () => {
    const uid = testUid("internal-cap-noreset");
    await usersRepo.ensure(db, uid, null);
    fake.users.set(uid, { spend: 10.0, budget_duration: "30d", max_budget: 10 });
    const res = await mintInternal({ uid });
    expect(res.statusCode).toBe(402);
    expect(res.json()).toEqual({ detail: "monthly free limit reached" });
    // LiteLLM reports no reset for the user → the header is omitted entirely
    // (graceful: the client just shows no countdown).
    expect(res.headers["x-ovid-resets-at"]).toBeUndefined();
  });

  it("the route does not exist on the public listener (404)", async () => {
    const res = await publicApp.inject({
      method: "POST",
      url: INTERNAL_MINT_PATH,
      headers: { "content-type": "application/json" },
      payload: { uid: "anyone" },
    });
    expect(res.statusCode).toBe(404);
  });
});
