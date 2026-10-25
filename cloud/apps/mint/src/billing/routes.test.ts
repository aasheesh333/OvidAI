import Fastify, { type FastifyInstance } from "fastify";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { type Db } from "@ovid/db";
import type { Redis } from "ioredis";
import { buildMintApps, HttpContractError, type MintDeps, type MintIdentityVerifier } from "../app.js";
import { signInternalRequest } from "@ovid/shared";
import { loadMintEnv, type MintEnv } from "../env.js";
import { createLiteLlmAdmin } from "../litellmAdmin.js";
import { registerUsageRoutes } from "../usage.js";
import { BillingError } from "./domain.js";
import { pubsubPushVerifier } from "./pushAuth.js";
import { registerBillingRoutes } from "./routes.js";
import { createBillingService, type BillingService } from "./service.js";
import { accountHash } from "./products.js";
import { createMintVerifier } from "../verifier.js";
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
    revenueCat: async () => ({
      status: "applied",
      entitlement: {
        tier: "free",
        productId: null,
        period: null,
        expiresAt: null,
        autoRenewing: false,
        purchaseState: "unknown",
      },
    }),
    entitlement: async () => ({
      tier: "free",
      productId: null,
      period: null,
      expiresAt: null,
      autoRenewing: false,
      purchaseState: "unknown",
    }),
    offerings: () => ({ available: false, products: [] }),
    usageFields: async () => ({}),
    products: {},
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

  it("revenuecat: wrong secret is rejected and a verified event is processed", async () => {
    const revenueCat = vi.fn(async () => ({
      status: "applied" as const,
      entitlement: {
        tier: "plus" as const,
        productId: "ovid_pro_yearly",
        period: "yearly" as const,
        expiresAt: 1_900_000_000,
        autoRenewing: true,
        purchaseState: "active" as const,
      },
    }));
    const server = app(stubBilling({ revenueCat }), routeDeps(), {
      deletionFence: async () => {},
      revenueCatSecret: "rc-route-secret",
    });
    const payload = {
      event: {
        id: "route-event",
        type: "INITIAL_PURCHASE",
        event_timestamp_ms: 1_800_000_000_000,
        app_user_id: "u1",
        original_transaction_id: "route-transaction",
        product_id: "ovid_pro_yearly",
        expiration_at_ms: 1_900_000_000_000,
        auto_renew_status: true,
      },
    };
    const denied = await server.inject({
      method: "POST",
      url: "/billing/revenuecat",
      headers: { authorization: "Bearer wrong" },
      payload,
    });
    expect(denied.statusCode).toBe(401);
    expect(revenueCat).not.toHaveBeenCalled();

    const accepted = await server.inject({
      method: "POST",
      url: "/billing/revenuecat",
      headers: { authorization: "Bearer rc-route-secret" },
      payload,
    });
    expect(accepted.statusCode).toBe(200);
    expect(accepted.json()).toMatchObject({ ok: true, status: "applied" });
    expect(revenueCat).toHaveBeenCalledOnce();
    expect(accepted.headers["cache-control"]).toBe("no-store");
  });

  it("offerings: unconfigured is unavailable and web checkout stays absent", async () => {
    const server = app(stubBilling());
    const offerings = await server.inject({ method: "GET", url: "/billing/offerings" });
    expect(offerings.statusCode).toBe(503);
    expect(offerings.json()).toEqual({ ok: false, error: { code: "billing_unavailable" } });
    expect(offerings.body).not.toContain("purchaseEnabled\":true");

    const checkout = await server.inject({ method: "POST", url: "/billing/checkout", payload: {} });
    expect(checkout.statusCode).toBe(404);
  });

  it("internal entitlement: signed admin-listener read only, public route absent", async () => {
    const entitlement = {
      tier: "plus" as const,
      productId: "ovid_pro_yearly",
      period: "yearly" as const,
      expiresAt: 1_900_000_000,
      autoRenewing: false,
      purchaseState: "cancelled" as const,
    };
    const deps = routeDeps();
    const now = 1_800_000_000;
    deps.clock = () => new Date(now * 1000);
    deps.billing = stubBilling({ entitlement: async () => entitlement });
    const apps = buildMintApps(deps);
    const path = "/internal/billing/entitlement";
    const headers = {
      "x-ovid-timestamp": Buffer.from(String(now)).toString("base64"),
      "x-ovid-signature": signInternalRequest("sk-internal-test", "GET", path, "u1", now),
    };
    const res = await apps.adminApp.inject({
      method: "GET",
      url: `${path}?uid=u1`,
      headers,
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ entitlement });
    expect(res.headers["cache-control"]).toBe("no-store");

    const publicRes = await apps.publicApp.inject({ method: "GET", url: `${path}?uid=u1`, headers });
    expect(publicRes.statusCode).toBe(404);
    await apps.publicApp.close();
    await apps.adminApp.close();
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
    expect(plans.map((p) => p.tier)).toEqual(["free", "go", "plus", "pro"]);
    expect(plans[0]!.features.length).toBeGreaterThan(0);
    expect(body).not.toHaveProperty("plan_expires_at");
  });
});

// ---------------------------------------------------------------------------
// The REAL deletion fence (P9 final re-review NEW-4)
//
// Every route test above injects `deletionFence`, which proves the route calls
// SOMETHING but not that the production default is wired. This block omits the
// option so `opts.deletionFence ?? requireNoDeletionFence(deps, uid)` is the
// code under test, against a real tombstone row.
// ---------------------------------------------------------------------------

describe.skipIf(!RUN)("billing route + the real account-deletion fence (NEW-4)", () => {
  let db: Db;
  let redis: Redis;
  let app: FastifyInstance;
  let verify: ReturnType<typeof vi.fn>;

  beforeAll(async () => {
    db = await resetTestDb();
    redis = await openFlushedRedis();
    const deps: MintDeps = {
      db,
      redis,
      litellm: {} as never,
      env: baseEnv({ DATABASE_URL: TEST_DATABASE_URL! }),
      alerter: async () => {},
      verifyIdentity: async ({ authorization }) => ({
        uid: authorization.replace(/^bearer\s+/i, ""),
        email: null,
        platform: "android",
      }),
    };
    verify = vi.fn(async () => ({ status: 200, payload: { ok: true } }));
    app = Fastify({ logger: false });
    // No fourth argument: the production default fence is what runs.
    registerBillingRoutes(app, deps, stubBilling({ verify }));
  }, 60_000);

  afterAll(async () => {
    await app.close();
    await closeRedis(redis);
    await closeDb(db);
  });

  async function tombstone(uid: string, state: string): Promise<void> {
    await db.$client`
      INSERT INTO account_deletions (uid, state, delete_after, record)
      VALUES (${uid}, ${state}, ${1_700_000_000.5}, ${"{}"}::jsonb)
      ON CONFLICT (uid) DO UPDATE SET state = ${state}
    `;
  }

  it("a pending tombstone fences /billing/verify before any billing work", async () => {
    const uid = testUid("fence-real");
    await tombstone(uid, "pending");
    const res = await app.inject({
      method: "POST",
      url: "/billing/verify",
      headers: { authorization: `Bearer ${uid}`, "x-firebase-appcheck": "x" },
      payload: { purchase_token: "t", product_id: "ovid_plus_monthly" },
    });
    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({
      ok: false,
      error: { code: "account_deletion_pending" },
    });
    expect(verify).not.toHaveBeenCalled();
  });

  it("a cancelled tombstone does not fence (recovery path)", async () => {
    const uid = testUid("fence-cancelled");
    await tombstone(uid, "cancelled");
    const res = await app.inject({
      method: "POST",
      url: "/billing/verify",
      headers: { authorization: `Bearer ${uid}`, "x-firebase-appcheck": "x" },
      payload: { purchase_token: "t", product_id: "ovid_plus_monthly" },
    });
    expect(res.statusCode).toBe(200);
    expect(verify).toHaveBeenCalledTimes(1);
  });
});

// ---------------------------------------------------------------------------
// CT-005 / SH-002: the INSTALLED CLIENT's exact request against the real
// verifier + real BillingService + real ledger (only Google is faked).
// lib/core/ovid_cloud_service.dart _verifyPlayPurchase sends:
//   POST /billing/verify
//   Authorization: Bearer <Firebase ID token>
//   X-Firebase-AppCheck: <token>   (omitted when App Check yields nothing)
//   Content-Type: application/json
//   {"product_id", "purchase_token", "package_name"}
// and parses: status 202 | body.status == "pending" → pending; 404 or
// 503 {error:{code:"billing_unavailable"}} → notAvailable; >=500 → unknown;
// other non-200 → rejected; 200 → tier, ok, acknowledge, expires_at,
// auto_renewing.
// ---------------------------------------------------------------------------

describe.skipIf(!RUN)("/billing/verify — installed-client contract (real verifier + service)", () => {
  let db: Db;
  let redis: Redis;
  const sink: Array<{ uid: string; tier: string }> = [];
  const playTokens = new Map<string, unknown>();
  const acks: string[] = [];
  const now = Math.floor(Date.now() / 1000);

  async function build(appcheck: "true" | "false"): Promise<FastifyInstance> {
    const env = baseEnv({ DATABASE_URL: TEST_DATABASE_URL!, APPCHECK_ENABLED: appcheck });
    const deps: MintDeps = {
      db,
      redis,
      litellm: {} as never,
      env,
      alerter: async () => {},
      verifyIdentity: createMintVerifier(env, {
        verifyIdToken: async (token) => ({ uid: token.replace(/^id-/, "") }),
        verifyAppCheck: async () => ({ appId: "1:android:abc" }),
      }),
    };
    const billing = createBillingService({
      db,
      redis,
      env,
      projection: { publishUserTier: async () => {} },
      setTier: async (uid, tier) => {
        sink.push({ uid, tier });
      },
      api: {
        getSubscription: async (token) => {
          if (!playTokens.has(token)) throw new BillingError(400, "purchase_invalid");
          return playTokens.get(token);
        },
        acknowledgeSubscription: async (_product, token) => {
          acks.push(token);
        },
      },
    });
    const app = Fastify({ logger: false });
    registerBillingRoutes(app, deps, billing);
    await app.ready();
    return app;
  }

  function resource(uid: string): Record<string, unknown> {
    return {
      subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
      acknowledgementState: "ACKNOWLEDGEMENT_STATE_PENDING",
      lineItems: [
        {
          productId: "ovid_pro_monthly",
          expiryTime: new Date((now + 30 * 86400) * 1000).toISOString(),
          autoRenewingPlan: { autoRenewEnabled: true },
        },
      ],
      externalAccountIdentifiers: { obfuscatedExternalAccountId: accountHash(uid) },
    };
  }

  beforeAll(async () => {
    db = await resetTestDb();
    redis = await openFlushedRedis();
  }, 60_000);

  afterAll(async () => {
    await closeRedis(redis);
    await closeDb(db);
  });

  function clientPost(app: FastifyInstance, uid: string, token: string, withAppCheck = false) {
    return app.inject({
      method: "POST",
      url: "/billing/verify",
      headers: {
        authorization: `Bearer id-${uid}`,
        "content-type": "application/json",
        ...(withAppCheck ? { "x-firebase-appcheck": "ac" } : {}),
      },
      payload: JSON.stringify({
        product_id: "ovid_pro_monthly",
        purchase_token: token,
        package_name: "com.dhanuk.ovidai",
      }),
    });
  }

  it("APPCHECK_ENABLED=false: no App Check header → 200 with every field the client parses; re-verify is identical", async () => {
    const app = await build("false");
    try {
      const uid = testUid("client");
      playTokens.set("tok-client", resource(uid));
      const first = await clientPost(app, uid, "tok-client");
      expect(first.statusCode).toBe(200);
      expect(first.headers["cache-control"]).toBe("no-store");
      const body = first.json() as Record<string, unknown>;
      expect(body).toMatchObject({
        ok: true,
        status: "active",
        tier: "plus",
        product_id: "ovid_pro_monthly",
        auto_renewing: true,
        acknowledge: true,
      });
      expect(typeof body.expires_at).toBe("string");
      expect(Number.isNaN(Date.parse(body.expires_at as string))).toBe(false);
      expect(sink.at(-1)).toEqual({ uid, tier: "plus" });
      expect(acks).toEqual(["tok-client"]);
      // Resume/restore re-delivers the same token: same verdict, no error.
      const again = await clientPost(app, uid, "tok-client");
      expect(again.statusCode).toBe(200);
      expect(again.json()).toEqual(body);
    } finally {
      await app.close();
    }
  });

  it("another account replaying the token → 409 (client: rejected); wrong obfuscated id → 403", async () => {
    const app = await build("false");
    try {
      const owner = testUid("owner");
      const thief = testUid("thief");
      playTokens.set("tok-owned", resource(owner));
      expect((await clientPost(app, owner, "tok-owned")).statusCode).toBe(200);
      const replay = await clientPost(app, thief, "tok-owned");
      expect(replay.statusCode).toBe(409);
      expect(replay.json()).toEqual({
        ok: false,
        error: { code: "purchase_owned_by_another_account" },
      });
      playTokens.set("tok-foreign", resource(owner));
      const mismatch = await clientPost(app, thief, "tok-foreign");
      expect(mismatch.statusCode).toBe(403);
      expect(mismatch.json()).toEqual({ ok: false, error: { code: "account_mismatch" } });
    } finally {
      await app.close();
    }
  });

  it("APPCHECK_ENABLED=true: a missing App Check header is 401 sign_in_required; present → 200", async () => {
    const app = await build("true");
    try {
      const uid = testUid("attested");
      playTokens.set("tok-attested", resource(uid));
      const missing = await clientPost(app, uid, "tok-attested");
      expect(missing.statusCode).toBe(401);
      expect(missing.json()).toEqual({ ok: false, error: { code: "sign_in_required" } });
      expect((await clientPost(app, uid, "tok-attested", true)).statusCode).toBe(200);
    } finally {
      await app.close();
    }
  });
});
