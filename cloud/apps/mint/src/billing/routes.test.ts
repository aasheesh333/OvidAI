import Fastify, { type FastifyInstance } from "fastify";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { type Db } from "@ovid/db";
import type { Redis } from "ioredis";
import { HttpContractError, type MintDeps, type MintIdentityVerifier } from "../app.js";
import { loadMintEnv, type MintEnv } from "../env.js";
import { createLiteLlmAdmin } from "../litellmAdmin.js";
import { registerUsageRoutes } from "../usage.js";
import { BillingError } from "./domain.js";
import { pubsubPushVerifier } from "./pushAuth.js";
import { registerBillingRoutes } from "./routes.js";
import type { BillingService } from "./service.js";
import {
  closeDb,
  closeRedis,
  openFlushedRedis,
  resetTestDb,
  testUid,
  TEST_DATABASE_URL,
  TEST_MINT_REDIS_URL,
} from "../test/env.js";
import { FakeLiteLlm, MASTER_KEY, standardModels } from "../test/litellmFake.js";

/** Port of test_billing.py's route/auth cases + the /usage merge point. */

function baseEnv(extra: NodeJS.ProcessEnv = {}): MintEnv {
  return loadMintEnv({
    NODE_ENV: "test",
    DATABASE_URL: TEST_DATABASE_URL ?? "postgres://unused",
    LITELLM_MASTER_KEY: "sk-test",
    OVID_ADMIN_MASTER_KEY: "sk-admin-test",
    OVID_INTERNAL_API_SECRET: "sk-internal-test",
    FIREBASE_PROJECT_ID: "ovid-test",
    APPCHECK_ENABLED: "false",
    ...extra,
  });
}

function stubBilling(overrides: Partial<BillingService> = {}): BillingService {
  return {
    configured: true,
    verify: async () => ({ status: 200, payload: { ok: true, status: "active" } }),
    notify: async () => {},
    usageFields: async () => ({}),
    ...overrides,
  };
}

const identity: MintIdentityVerifier = async () => ({
  uid: "u1",
  email: null,
  platform: "android",
});

function routeDeps(
  verifyIdentity: MintIdentityVerifier = identity,
  banned = false,
): MintDeps {
  return {
    db: {} as Db,
    redis: {
      get: async () => (banned ? "auto" : null),
    } as unknown as Redis,
    litellm: {} as never,
    env: baseEnv(),
    alerter: async () => {},
    verifyIdentity,
  };
}

function headers(): Record<string, string> {
  return { authorization: "Bearer token-u1", "x-firebase-appcheck": "attest" };
}

describe("billing routes (routes.ts)", () => {
  function app(
    billing: BillingService,
    deps: MintDeps = routeDeps(),
    // The route-level tests never own a real db: inject a no-op fence unless a
    // test is explicitly exercising the deletion fence.
    opts: Parameters<typeof registerBillingRoutes>[3] = {
      deletionFence: async () => {},
    },
  ): FastifyInstance {
    const instance = Fastify({ logger: false });
    registerBillingRoutes(instance, deps, billing, opts);
    return instance;
  }

  it("verify: missing/invalid identity → 401 sign_in_required envelope", async () => {
    const failing: MintIdentityVerifier = async () => {
      throw new HttpContractError(401, "missing bearer id token");
    };
    const server = app(stubBilling(), routeDeps(failing));
    const res = await server.inject({
      method: "POST",
      url: "/billing/verify",
      payload: { purchase_token: "t", product_id: "ovid_plus_monthly" },
    });
    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ ok: false, error: { code: "sign_in_required" } });
    expect(res.headers["cache-control"]).toBe("no-store");
  });

  it("verify: banned user → 403 account_blocked", async () => {
    const server = app(stubBilling(), routeDeps(identity, true));
    const res = await server.inject({
      method: "POST",
      url: "/billing/verify",
      headers: headers(),
      payload: { purchase_token: "t", product_id: "ovid_plus_monthly" },
    });
    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({ ok: false, error: { code: "account_blocked" } });
  });

  it("verify: deletion-pending account → 403 before any billing work (H1)", async () => {
    const verify = vi.fn(async () => ({ status: 200, payload: { ok: true } }));
    let fencedUid = "";
    const server = app(stubBilling({ verify }), routeDeps(), {
      deletionFence: async (uid) => {
        fencedUid = uid;
        throw new HttpContractError(403, "account_deletion_pending");
      },
    });
    const res = await server.inject({
      method: "POST",
      url: "/billing/verify",
      headers: headers(),
      payload: { purchase_token: "t", product_id: "ovid_plus_monthly" },
    });
    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({
      ok: false,
      error: { code: "account_deletion_pending" },
    });
    expect(res.headers["cache-control"]).toBe("no-store");
    expect(fencedUid).toBe("u1");
    // LOAD-BEARING: the fence runs before the purchase is bound.
    expect(verify).not.toHaveBeenCalled();
  });

  it("verify: status + payload pass through with no-store (200 and 202)", async () => {
    const server = app(
      stubBilling({
        verify: async () => ({
          status: 202,
          payload: { ok: false, status: "pending", acknowledge: false },
        }),
      }),
    );
    const res = await server.inject({
      method: "POST",
      url: "/billing/verify",
      headers: headers(),
      payload: { purchase_token: "t", product_id: "ovid_plus_monthly" },
    });
    expect(res.statusCode).toBe(202);
    expect(res.json()).toMatchObject({ status: "pending", acknowledge: false });
    expect(res.headers["cache-control"]).toBe("no-store");
  });

  it("verify: BillingError maps to its status/code; unexpected → 503 billing_unavailable", async () => {
    const conflict = app(
      stubBilling({
        verify: async () => {
          throw new BillingError(409, "purchase_owned_by_another_account");
        },
      }),
    );
    const res = await conflict.inject({
      method: "POST",
      url: "/billing/verify",
      headers: headers(),
      payload: {},
    });
    expect(res.statusCode).toBe(409);
    expect(res.json()).toEqual({
      ok: false,
      error: { code: "purchase_owned_by_another_account" },
    });

    const broken = app(
      stubBilling({
        verify: async () => {
          throw new Error("driver exploded");
        },
      }),
    );
    const res2 = await broken.inject({
      method: "POST",
      url: "/billing/verify",
      headers: headers(),
      payload: {},
    });
    expect(res2.statusCode).toBe(503);
    expect(res2.json()).toEqual({ ok: false, error: { code: "billing_unavailable" } });
    expect(res2.body).not.toContain("driver exploded");
  });

  it("rtdn: push auth failure → 403 empty; success → 204; transient → 503", async () => {
    const denied = app(
      stubBilling({
        notify: async () => {
          throw new Error("must not run");
        },
      }),
    );
    // No OVID_RTDN_* configured → fail closed.
    const res = await denied.inject({ method: "POST", url: "/billing/rtdn", payload: {} });
    expect(res.statusCode).toBe(403);
    expect(res.body).toBe("");

    const notify = vi.fn(async () => {});
    const deps = routeDeps();
    deps.env = baseEnv({ OVID_RTDN_SHARED_SECRET: "push-secret" });
    const ok = app(stubBilling({ notify }), deps);
    const res2 = await ok.inject({
      method: "POST",
      url: "/billing/rtdn?secret=push-secret",
      payload: { message: { data: "e30=" } },
    });
    expect(res2.statusCode).toBe(204);
    expect(notify).toHaveBeenCalledOnce();

    const retry = app(
      stubBilling({
        notify: async () => {
          throw new BillingError(503, "play_unavailable");
        },
      }),
      deps,
    );
    const res3 = await retry.inject({
      method: "POST",
      url: "/billing/rtdn?secret=push-secret",
      payload: {},
    });
    expect(res3.statusCode).toBe(503);
    expect(res3.json()).toEqual({ ok: false, error: { code: "play_unavailable" } });

    const generic = app(
      stubBilling({
        notify: async () => {
          throw new Error("boom");
        },
      }),
      deps,
    );
    const res4 = await generic.inject({
      method: "POST",
      url: "/billing/rtdn?secret=push-secret",
      payload: {},
    });
    expect(res4.statusCode).toBe(503);
    expect(res4.body).toBe("");
  });
});

describe("pubsubPushVerifier (pushAuth.ts)", () => {
  it("no env → false even for a valid-looking bearer", async () => {
    const verify = pubsubPushVerifier(baseEnv());
    expect(await verify({ authorization: "Bearer abc" }, {})).toBe(false);
    expect(await verify({}, { secret: "anything" })).toBe(false);
  });

  it("shared-secret fallback compares the ?secret= value timing-safely", async () => {
    const verify = pubsubPushVerifier(
      baseEnv({ OVID_RTDN_SHARED_SECRET: "push-secret" }),
    );
    expect(await verify({}, { secret: "push-secret" })).toBe(true);
    expect(await verify({}, { secret: "wrong" })).toBe(false);
    expect(await verify({}, {})).toBe(false);
    expect(await verify({}, { secret: "push-secret-longer" })).toBe(false);
  });

  it("OIDC: audience, email and email_verified are all enforced", async () => {
    const seen: { token: string; audience: string }[] = [];
    const env = baseEnv({
      OVID_RTDN_AUDIENCE: "https://api.example/billing/rtdn",
      OVID_RTDN_SERVICE_ACCOUNT: "push@example.iam.gserviceaccount.com",
    });
    const verify = pubsubPushVerifier(env, {
      verifyIdToken: async (token, audience) => {
        seen.push({ token, audience });
        return { email: "push@example.iam.gserviceaccount.com", email_verified: true };
      },
    });
    expect(await verify({ authorization: "Bearer id-token" }, {})).toBe(true);
    expect(seen).toEqual([
      { token: "id-token", audience: "https://api.example/billing/rtdn" },
    ]);
    // Missing bearer.
    expect(await verify({}, {})).toBe(false);
    // Wrong email.
    const wrongEmail = pubsubPushVerifier(env, {
      verifyIdToken: async () => ({ email: "other@example.com", email_verified: true }),
    });
    expect(await wrongEmail({ authorization: "Bearer t" }, {})).toBe(false);
    // email_verified must be literally true.
    const unverified = pubsubPushVerifier(env, {
      verifyIdToken: async () => ({
        email: "push@example.iam.gserviceaccount.com",
        email_verified: "true",
      }),
    });
    expect(await unverified({ authorization: "Bearer t" }, {})).toBe(false);
    // Verification failure is fail-closed.
    const throwing = pubsubPushVerifier(env, {
      verifyIdToken: async () => {
        throw new Error("bad token");
      },
    });
    expect(await throwing({ authorization: "Bearer t" }, {})).toBe(false);
  });

  it("OIDC takes precedence over the shared-secret fallback (Python order)", async () => {
    const verify = pubsubPushVerifier(
      baseEnv({
        OVID_RTDN_AUDIENCE: "aud",
        OVID_RTDN_SERVICE_ACCOUNT: "push@example.com",
        OVID_RTDN_SHARED_SECRET: "push-secret",
      }),
      { verifyIdToken: async () => ({ email: "push@example.com", email_verified: true }) },
    );
    expect(await verify({}, { secret: "push-secret" })).toBe(false); // no bearer
    expect(await verify({ authorization: "Bearer t" }, {})).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// /usage merge point (declared Task-5 ownership overlap)
// ---------------------------------------------------------------------------

const RUN = TEST_DATABASE_URL !== undefined && TEST_MINT_REDIS_URL !== undefined;

describe.skipIf(!RUN)("POST /usage billing merge (usage.ts)", () => {
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
      env: baseEnv({
        DATABASE_URL: TEST_DATABASE_URL!,
        REDIS_DB2_URL: TEST_MINT_REDIS_URL!,
        LITELLM_BASE: fake.baseUrl,
      }),
      alerter: async () => {},
      verifyIdentity: async ({ authorization }) => ({
        uid: authorization.replace(/^bearer\s+/i, ""),
        email: null,
        platform: "android",
      }),
    };
    standardModels(fake);
    app = Fastify({ logger: false });
    // Unconfigured billing service (no Play service account) is the exact
    // "paid plans coming soon" gate the README describes.
    const billing = (
      await import("./service.js")
    ).createBillingService({
      db,
      redis,
      env: deps.env,
      verifyIdentity: deps.verifyIdentity,
      projection: { publishUserTier: async () => {} },
      api: null,
    });
    registerUsageRoutes(app, deps, billing);
  }, 60_000);

  afterAll(async () => {
    await app.close();
    await fake.stop();
    await closeRedis(redis);
    await closeDb(db);
  });

  it("merges billing_enabled/plans into the legacy usage body", async () => {
    const uid = testUid("usage-billing");
    const res = await app.inject({
      method: "POST",
      url: "/usage",
      headers: { authorization: `Bearer ${uid}`, "x-firebase-appcheck": "x" },
    });
    expect(res.statusCode).toBe(200);
    const body = res.json() as Record<string, unknown>;
    // Existing fields survive the merge.
    expect(body).toHaveProperty("tier");
    expect(body).toHaveProperty("remaining_fraction");
    expect(body.billing_enabled).toBe(false);
    const plans = body.plans as { tier: string; features: string[] }[];
    expect(plans.map((p) => p.tier)).toEqual(["free", "3x", "7x", "15x"]);
    expect(plans[0]!.features.length).toBeGreaterThan(0);
    expect(body).not.toHaveProperty("plan_expires_at");
  });
});
