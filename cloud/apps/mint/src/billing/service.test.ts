import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { Db } from "@ovid/db";
import type { Redis } from "ioredis";
import type { MintIdentityVerifier } from "../app.js";
import { loadMintEnv, type MintEnv } from "../env.js";
import { BillingError } from "./domain.js";
import { accountHash } from "./products.js";
import type { PlayDeveloperApi } from "./play.js";
import {
  createBillingService,
  createPurchaseLedger,
  type BillingService,
  type PurchaseLedger,
} from "./service.js";
import { closeDb, resetTestDb, testUid, TEST_DATABASE_URL } from "../test/env.js";

/**
 * Port of test_billing.py's BillingApiTest verify/RTDN matrix against the
 * REAL Postgres ledger (billingPurchases) with a fake Play API and a capturing
 * tier sink. No network, no credentials.
 */

const RUN = TEST_DATABASE_URL !== undefined;
const NOW = 1_800_000_000; // 2027-01-15T08:00:00Z
const PRODUCTS = {
  ovid_plus_monthly: "3x",
  ovid_pro_monthly: "7x",
  ovid_max_monthly: "15x",
};

function iso(epoch: number): string {
  return new Date(epoch * 1000).toISOString().replace(/\.000Z$/, "Z");
}

function subscription(
  opts: {
    product?: string;
    state?: string;
    expiry?: number;
    uid?: string | null;
    auto?: boolean;
    linked?: string | null;
    ack?: boolean;
  } = {},
): Record<string, unknown> {
  const {
    product = "ovid_plus_monthly",
    state = "SUBSCRIPTION_STATE_ACTIVE",
    expiry = NOW + 30 * 86400,
    uid = "u1",
    auto = true,
    linked = null,
    ack = false,
  } = opts;
  const resource: Record<string, unknown> = {
    subscriptionState: state,
    acknowledgementState: ack
      ? "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED"
      : "ACKNOWLEDGEMENT_STATE_PENDING",
    lineItems: [
      {
        productId: product,
        expiryTime: iso(expiry),
        autoRenewingPlan: { autoRenewEnabled: auto },
      },
    ],
  };
  if (uid !== null) {
    resource.externalAccountIdentifiers = {
      obfuscatedExternalAccountId: accountHash(uid),
    };
  }
  if (linked) resource.linkedPurchaseToken = linked;
  return resource;
}

class FakePlay implements PlayDeveloperApi {
  readonly tokens = new Map<string, unknown>();
  readonly calls: string[] = [];
  readonly acks: Array<{ product: string; token: string }> = [];
  fail: Error | null = null;
  ackFail: Error | null = null;

  async acknowledgeSubscription(product: string, token: string): Promise<void> {
    if (this.ackFail) throw this.ackFail;
    this.acks.push({ product, token });
  }

  async getSubscription(token: string): Promise<unknown> {
    this.calls.push(token);
    if (this.fail) throw this.fail;
    if (!this.tokens.has(token)) throw new BillingError(400, "purchase_invalid");
    return this.tokens.get(token);
  }
}

interface SinkCall {
  uid: string;
  tier: string;
  expiresAt: number | null;
}

function push(payload: unknown): unknown {
  return {
    message: {
      data: Buffer.from(JSON.stringify(payload)).toString("base64"),
      messageId: "1",
    },
    subscription: "projects/p/subscriptions/s",
  };
}

function testEnv(): MintEnv {
  return loadMintEnv({
    NODE_ENV: "test",
    DATABASE_URL: TEST_DATABASE_URL!,
    LITELLM_MASTER_KEY: "sk-test",
    OVID_ADMIN_MASTER_KEY: "sk-admin-test",
    OVID_INTERNAL_API_SECRET: "sk-internal-test",
    FIREBASE_PROJECT_ID: "ovid-test",
    APPCHECK_ENABLED: "false",
    OVID_PLAY_PACKAGE: "com.dhanuk.ovidai",
  });
}

describe.skipIf(!RUN)("BillingService (service.ts)", () => {
  let db: Db;
  let play: FakePlay;
  let store: PurchaseLedger;
  let sink: SinkCall[];
  let now: number;
  let service: BillingService;
  let uid: string;
  let other: string;

  const verifyIdentity: MintIdentityVerifier = async () => ({
    uid: "unused",
    email: null,
    platform: "android",
  });

  function build(overrides: { api?: PlayDeveloperApi | null } = {}): BillingService {
    return createBillingService({
      db,
      redis: {} as Redis,
      env: testEnv(),
      verifyIdentity,
      projection: { publishUserTier: async () => {} },
      setTier: async (u, tier, expiresAt) => {
        sink.push({ uid: u, tier, expiresAt });
      },
      store,
      api: overrides.api === undefined ? play : overrides.api,
      clock: () => now,
      products: PRODUCTS,
    });
  }

  beforeAll(async () => {
    db = await resetTestDb();
    store = createPurchaseLedger(db);
  });

  afterAll(async () => {
    await closeDb(db);
  });

  beforeEach(async () => {
    // The Python suite gets a fresh in-memory PurchaseStore per test; this
    // suite shares one Postgres schema for the whole file. Clear the ledger
    // so a token bound in one test cannot leak into the next (that leak is
    // exactly the cross-account 409 the contract requires for real replays).
    await db.$client`DELETE FROM billing_purchases`;
    play = new FakePlay();
    sink = [];
    now = NOW;
    service = build();
    uid = testUid("u1");
    other = testUid("u2");
  });

  function verify(
    token = "tok-1",
    product = "ovid_plus_monthly",
    user = uid,
    packageName = "com.dhanuk.ovidai",
  ): Promise<{ status: number; payload: Record<string, unknown> }> {
    return service.verify(user, {
      purchase_token: token,
      product_id: product,
      package_name: packageName,
    });
  }

  async function codeOf(promise: Promise<unknown>): Promise<{ status: number; code: string }> {
    try {
      await promise;
    } catch (err) {
      expect(err).toBeInstanceOf(BillingError);
      return { status: (err as BillingError).status, code: (err as BillingError).code };
    }
    throw new Error("expected BillingError");
  }

  it("happy path: 200 active, acknowledge only when active, tier sunk + ledger row", async () => {
    play.tokens.set("tok-1", subscription({ uid, ack: false }));
    const { status, payload } = await verify("tok-1", "ovid_plus_monthly", uid);
    expect(status).toBe(200);
    expect(payload).toMatchObject({
      ok: true,
      status: "active",
      tier: "3x",
      product_id: "ovid_plus_monthly",
      expires_at: iso(NOW + 30 * 86400),
      auto_renewing: true,
      acknowledge: true,
    });
    expect(sink).toEqual([{ uid, tier: "3x", expiresAt: NOW + 30 * 86400 }]);
    expect(await store.get("tok-1")).toMatchObject({
      uid,
      status: "active",
      tier: "3x",
      accountHash: accountHash(uid),
    });
  });

  it("verify is idempotent per token", async () => {
    play.tokens.set("tok-1", subscription({ uid }));
    const first = await verify();
    const second = await verify();
    expect(second).toEqual(first);
    expect(sink).toEqual([
      { uid, tier: "3x", expiresAt: NOW + 30 * 86400 },
      { uid, tier: "3x", expiresAt: NOW + 30 * 86400 },
    ]);
  });

  // SH-002 belt and braces: the server acknowledges a verified, active,
  // still-unacknowledged purchase itself, so a client that dies between
  // verify and completePurchase cannot let Play refund it after 3 days.
  it("acknowledges an active unacknowledged purchase server-side, exactly once", async () => {
    play.tokens.set("tok-1", subscription({ uid, ack: false }));
    const first = await verify();
    expect(first.payload.acknowledge).toBe(true);
    expect(play.acks).toEqual([{ product: "ovid_plus_monthly", token: "tok-1" }]);
    // Play now reports it acknowledged: a re-verify (resume/restore) is a
    // no-op for Google and identical for the client.
    play.tokens.set("tok-1", subscription({ uid, ack: true }));
    const second = await verify();
    expect(second).toEqual(first);
    expect(play.acks).toHaveLength(1);
  });

  it("never acknowledges pending, expired or foreign purchases", async () => {
    play.tokens.set("tok-p", subscription({ uid, state: "SUBSCRIPTION_STATE_PENDING" }));
    await verify("tok-p");
    play.tokens.set("tok-e", subscription({ uid, expiry: NOW - 10 }));
    await verify("tok-e");
    play.tokens.set("tok-f", subscription({ uid: other }));
    await codeOf(verify("tok-f"));
    expect(play.acks).toEqual([]);
  });

  it("a failed server-side acknowledgement never fails verify (the client still acknowledges)", async () => {
    play.tokens.set("tok-1", subscription({ uid, ack: false }));
    play.ackFail = new Error("play down");
    const { status, payload } = await verify();
    expect(status).toBe(200);
    expect(payload).toMatchObject({ ok: true, tier: "3x", acknowledge: true });
  });

  it("unverified or foreign purchases never set a paid tier", async () => {
    // Unknown to Google.
    expect(await codeOf(verify("forged"))).toEqual({
      status: 400,
      code: "purchase_invalid",
    });
    // Bought by another account.
    play.tokens.set("tok-2", subscription({ uid: other }));
    expect(await codeOf(verify("tok-2", "ovid_plus_monthly", uid))).toEqual({
      status: 403,
      code: "account_mismatch",
    });
    // No obfuscated account id at all (requireAccountId defaults true).
    play.tokens.set("tok-3", subscription({ uid: null }));
    expect(await codeOf(verify("tok-3"))).toEqual({ status: 403, code: "account_mismatch" });
    // Product the server does not sell.
    expect(await codeOf(verify("tok-4", "other"))).toEqual({
      status: 400,
      code: "unknown_product",
    });
    // Google unreachable: 503 and nothing sunk.
    play.tokens.set("tok-5", subscription({ uid }));
    play.fail = new BillingError(503, "play_unavailable");
    expect(await codeOf(verify("tok-5"))).toEqual({ status: 503, code: "play_unavailable" });
    expect(sink).toEqual([]);
  });

  it("a token cannot be replayed from another account (409) and does not sink", async () => {
    play.tokens.set("tok-1", subscription({ uid }));
    expect((await verify("tok-1", "ovid_plus_monthly", uid)).status).toBe(200);
    sink.length = 0;
    expect(await codeOf(verify("tok-1", "ovid_plus_monthly", other))).toEqual({
      status: 409,
      code: "purchase_owned_by_another_account",
    });
    expect(sink).toEqual([]);
  });

  it("pending purchase → 202, acknowledge false, no paid tier", async () => {
    play.tokens.set("tok-1", subscription({ uid, state: "SUBSCRIPTION_STATE_PENDING" }));
    const { status, payload } = await verify();
    expect(status).toBe(202);
    expect(payload).toMatchObject({ ok: false, status: "pending", acknowledge: false });
    expect(sink).toEqual([{ uid, tier: "free", expiresAt: null }]);
  });

  it("invalid requests and wrong package are 400 invalid_request/wrong_package", async () => {
    for (const body of [null, [], "x", {}, { purchase_token: "" }, { purchase_token: 1 }]) {
      expect(
        await codeOf(service.verify(uid, body as unknown)),
      ).toEqual({ status: 400, code: "invalid_request" });
    }
    play.tokens.set("tok-1", subscription({ uid }));
    expect(await codeOf(verify("tok-1", "ovid_plus_monthly", uid, "other.app"))).toEqual({
      status: 400,
      code: "wrong_package",
    });
    expect(play.calls).toEqual([]);
  });

  it("unconfigured service is closed and reports billing_enabled false", async () => {
    const closed = build({ api: null });
    expect(closed.configured).toBe(false);
    expect((await closed.usageFields(uid)).billing_enabled).toBe(false);
    expect(await codeOf(closed.verify(uid, { purchase_token: "t", product_id: "x" }))).toEqual({
      status: 503,
      code: "billing_unavailable",
    });
  });

  it("requireAccountId=false accepts a token without the obfuscated id", async () => {
    const permissive = createBillingService({
      db,
      redis: {} as Redis,
      env: testEnv(),
      verifyIdentity,
      projection: { publishUserTier: async () => {} },
      setTier: async (u, tier, expiresAt) => {
        sink.push({ uid: u, tier, expiresAt });
      },
      store,
      api: play,
      clock: () => now,
      products: PRODUCTS,
      requireAccountId: false,
    });
    play.tokens.set("tok-9", subscription({ uid: null }));
    const { status } = await permissive.verify(uid, {
      purchase_token: "tok-9",
      product_id: "ovid_plus_monthly",
    });
    expect(status).toBe(200);
  });

  // ---- RTDN ---------------------------------------------------------------

  it("renewal refreshes expiry; cancel keeps access with auto-renew off; expiry drops tier", async () => {
    play.tokens.set("tok-1", subscription({ uid }));
    await verify();
    play.tokens.set("tok-1", subscription({ uid, expiry: NOW + 60 * 86400 }));
    await service.notify(
      push({
        packageName: "com.dhanuk.ovidai",
        subscriptionNotification: { notificationType: 2, purchaseToken: "tok-1" },
      }),
    );
    expect(sink.at(-1)).toEqual({ uid, tier: "3x", expiresAt: NOW + 60 * 86400 });
    // User cancels: keeps access, auto-renew off.
    play.tokens.set(
      "tok-1",
      subscription({ uid, state: "SUBSCRIPTION_STATE_CANCELED", expiry: NOW + 60 * 86400 }),
    );
    await service.notify(
      push({
        subscriptionNotification: { notificationType: 3, purchaseToken: "tok-1" },
      }),
    );
    expect(sink.at(-1)).toEqual({ uid, tier: "3x", expiresAt: NOW + 60 * 86400 });
    expect((await service.usageFields(uid)).plan_auto_renews).toBe(false);
    // Expiry: tier removed.
    now = NOW + 61 * 86400;
    play.tokens.set(
      "tok-1",
      subscription({ uid, state: "SUBSCRIPTION_STATE_EXPIRED", expiry: NOW + 60 * 86400 }),
    );
    await service.notify(
      push({
        subscriptionNotification: { notificationType: 13, purchaseToken: "tok-1" },
      }),
    );
    expect(sink.at(-1)).toEqual({ uid, tier: "free", expiresAt: null });
  });

  it("revoked (notificationType 12) is sticky against a later ACTIVE re-read", async () => {
    play.tokens.set("tok-1", subscription({ uid }));
    await verify();
    await service.notify(
      push({
        subscriptionNotification: { notificationType: 12, purchaseToken: "tok-1" },
      }),
    );
    expect((await store.get("tok-1"))!.status).toBe("revoked");
    expect(sink.at(-1)).toEqual({ uid, tier: "free", expiresAt: null });
    // A later ACTIVE Play read must not resurrect it.
    play.tokens.set("tok-1", subscription({ uid }));
    await service.notify(
      push({
        subscriptionNotification: { notificationType: 2, purchaseToken: "tok-1" },
      }),
    );
    expect(await store.get("tok-1")).toMatchObject({ status: "revoked", tier: "free" });
    expect(sink.at(-1)).toEqual({ uid, tier: "free", expiresAt: null });
    // And a re-verify cannot re-grant.
    const { payload } = await verify();
    expect(payload.ok).toBe(false);
  });

  it("voidedPurchaseNotification revokes and re-applies the owner", async () => {
    play.tokens.set("tok-1", subscription({ uid }));
    await verify();
    await service.notify(
      push({ voidedPurchaseNotification: { purchaseToken: "tok-1", productType: 1 } }),
    );
    expect((await store.get("tok-1"))!.status).toBe("revoked");
    expect(sink.at(-1)).toEqual({ uid, tier: "free", expiresAt: null });
  });

  it("linkedPurchaseToken replaces the old token and re-applies BOTH owners", async () => {
    play.tokens.set("tok-old", subscription({ uid }));
    await verify("tok-old", "ovid_plus_monthly", uid);
    play.tokens.set(
      "tok-new",
      subscription({ uid: other, product: "ovid_max_monthly", linked: "tok-old" }),
    );
    const upgraded = await verify("tok-new", "ovid_max_monthly", other);
    expect(upgraded.payload.tier).toBe("15x");
    expect((await store.get("tok-old"))!.status).toBe("replaced");

    sink.length = 0;
    await service.notify(
      push({
        subscriptionNotification: { notificationType: 2, purchaseToken: "tok-new" },
      }),
    );
    expect((await store.get("tok-old"))!.status).toBe("replaced");
    expect(sink).toEqual(
      expect.arrayContaining([
        { uid: other, tier: "15x", expiresAt: NOW + 30 * 86400 },
        { uid, tier: "free", expiresAt: null },
      ]),
    );
  });

  it("unbound RTDN tokens are stored uid=null and bound by the later verify", async () => {
    play.tokens.set("tok-9", subscription({ uid }));
    await service.notify(
      push({
        subscriptionNotification: { notificationType: 4, purchaseToken: "tok-9" },
      }),
    );
    expect((await store.get("tok-9"))!.uid).toBeNull();
    expect(sink).toEqual([]);
    expect((await verify("tok-9")).payload.tier).toBe("3x");
    expect((await store.get("tok-9"))!.uid).toBe(uid);
  });

  it("transient Play errors propagate as 503 so Pub/Sub retries", async () => {
    play.fail = new BillingError(503, "play_unavailable");
    await expect(
      service.notify(
        push({
          subscriptionNotification: { notificationType: 2, purchaseToken: "tok-1" },
        }),
      ),
    ).rejects.toMatchObject({ status: 503, code: "play_unavailable" });
  });

  it("a token Play does not know is acknowledged, not retried forever", async () => {
    // A forged/foreign/replayed token cannot be fixed by redelivery.
    await expect(
      service.notify(
        push({
          subscriptionNotification: { notificationType: 2, purchaseToken: "forged" },
        }),
      ),
    ).resolves.toBeUndefined();
    expect(play.calls).toEqual(["forged"]);
    expect(sink).toEqual([]);
  });

  it("malformed, test and foreign-package notifications are acknowledged without Play calls", async () => {
    await service.notify({});
    await service.notify({ message: { data: "!!" } });
    await service.notify(push({ testNotification: { version: "1.0" } }));
    await service.notify(
      push({ packageName: "other.app", subscriptionNotification: { purchaseToken: "x" } }),
    );
    expect(play.calls).toEqual([]);
  });

  it("redelivery is idempotent: identical end state, no duplicate effect", async () => {
    play.tokens.set("tok-1", subscription({ uid }));
    await verify();
    sink.length = 0;
    const note = push({
      subscriptionNotification: { notificationType: 2, purchaseToken: "tok-1" },
    });
    await service.notify(note);
    const first = [...sink];
    const row1 = await store.get("tok-1");
    await service.notify(note);
    expect([...sink]).toEqual([...first, ...first]);
    expect(await store.get("tok-1")).toEqual(row1);
  });

  // ---- /usage fields ------------------------------------------------------

  it("usageFields exposes renewal + feature lists (README shape)", async () => {
    play.tokens.set("tok-1", subscription({ uid }));
    await verify();
    const fields = await service.usageFields(uid);
    expect(fields.billing_enabled).toBe(true);
    expect(fields.plan_expires_at).toBe(iso(NOW + 30 * 86400));
    expect(fields.plan_auto_renews).toBe(true);
    expect(fields.plan_product_id).toBe("ovid_plus_monthly");
    // SH-006: plan cards come from the live plan table (usage.ts/planCards),
    // never from the old hard-coded TIERS copy here.
    expect(fields).not.toHaveProperty("plans");
    expect(service.products).toEqual(PRODUCTS);
  });

  it("usageFields(null) omits the plan_* fields", async () => {
    const fields = await service.usageFields(null);
    expect(fields).toEqual({ billing_enabled: true });
  });
});
