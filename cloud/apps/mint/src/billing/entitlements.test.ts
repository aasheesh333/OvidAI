import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { billingUsers, type Db } from "@ovid/db";
import type { Redis } from "ioredis";
import { BillingError } from "./domain.js";
import type { MintDeps } from "../app.js";
import { loadMintEnv } from "../env.js";
import { createLiteLlmAdmin } from "../litellmAdmin.js";
import { createProjection } from "../projection.js";
import { getSettings } from "../settings.js";
import { reapplyUser } from "../windows.js";
import { FakeLiteLlm, MASTER_KEY } from "../test/litellmFake.js";
import { createTierSink, type TierSink } from "./tierSink.js";
import {
  createEntitlementService,
  type BillingEntitlement,
  type EntitlementService,
  type RevenueCatEvent,
} from "./entitlements.js";
import {
  closeDb,
  closeRedis,
  openFlushedRedis,
  resetTestDb,
  testUid,
  TEST_DATABASE_URL,
  TEST_MINT_REDIS_URL,
} from "../test/env.js";

const RUN = TEST_DATABASE_URL !== undefined && TEST_MINT_REDIS_URL !== undefined;
const NOW = 1_800_000_000;
const YEAR = 365 * 86_400;

const FREE: BillingEntitlement = {
  tier: "free",
  productId: null,
  period: null,
  expiresAt: null,
  autoRenewing: false,
  purchaseState: "unknown",
};

describe.skipIf(!RUN)("canonical entitlement authority (real test Postgres + Redis)", () => {
  let db: Db;
  let redis: Redis;
  let service: EntitlementService;
  let now: number;
  let uid: string;
  let sequence: number;
  let projections: Array<{ uid: string; tier: string; expiresAt: number | null }>;

  beforeAll(async () => {
    db = await resetTestDb();
    redis = await openFlushedRedis();
  }, 60_000);

  afterAll(async () => {
    await closeRedis(redis);
    await closeDb(db);
  });

  beforeEach(async () => {
    await db.$client`DELETE FROM billing_purchases`;
    await redis.flushdb();
    now = NOW;
    uid = testUid("entitlement");
    sequence = 0;
    projections = [];
    service = createEntitlementService({
      db,
      redis,
      clock: () => now,
      setTier: async (target, tier, expiresAt) => {
        projections.push({ uid: target, tier, expiresAt });
        await billingUsers.setTier(db, target, tier, expiresAt);
      },
    });
  });

  function event(overrides: Partial<RevenueCatEvent> = {}): RevenueCatEvent {
    sequence += 1;
    return {
      id: `event-${sequence}`,
      type: "INITIAL_PURCHASE",
      occurredAt: NOW,
      appUserId: uid,
      transactionId: "transaction-1",
      productId: "ovid_pro_yearly",
      expiresAt: NOW + YEAR,
      autoRenewing: true,
      cancelReason: null,
      environment: "PRODUCTION",
      ...overrides,
    };
  }

  async function cached(target = uid): Promise<BillingEntitlement> {
    const raw = await redis.get(`user:${target}:billing_entitlement`);
    expect(raw).not.toBeNull();
    return JSON.parse(raw!) as BillingEntitlement;
  }

  it("mints one canonical yearly entitlement into billingUsers and the mint projection", async () => {
    const result = await service.apply(event());
    const expected: BillingEntitlement = {
      tier: "plus",
      productId: "ovid_pro_yearly",
      period: "yearly",
      expiresAt: NOW + YEAR,
      autoRenewing: true,
      purchaseState: "active",
    };
    expect(result).toEqual({ status: "applied", entitlement: expected });
    expect(await service.entitlement(uid)).toEqual(expected);
    expect(await cached()).toEqual(expected);
    expect(await billingUsers.getTier(db, uid)).toEqual({
      tier: "plus",
      tierExpiresAt: new Date((NOW + YEAR) * 1000),
    });
    expect(projections).toEqual([{ uid, tier: "plus", expiresAt: NOW + YEAR }]);
  });

  it("keeps cancellation access until expiry, then derives expiration from time", async () => {
    await service.apply(event());
    const cancelled = await service.apply(event({
      type: "CANCELLATION",
      occurredAt: NOW + 10,
      autoRenewing: false,
    }));
    expect(cancelled.entitlement).toMatchObject({
      tier: "plus",
      period: "yearly",
      purchaseState: "cancelled",
      autoRenewing: false,
      expiresAt: NOW + YEAR,
    });

    now = NOW + YEAR + 1;
    expect(await service.entitlement(uid)).toMatchObject({
      tier: "free",
      purchaseState: "expired",
      autoRenewing: false,
      expiresAt: NOW + YEAR,
    });
    await service.refresh(uid);
    expect((await billingUsers.getTier(db, uid)).tier).toBe("free");
    expect((await cached()).purchaseState).toBe("expired");
  });

  it("revokes immediately for refund and expiration events", async () => {
    await service.apply(event());
    const refunded = await service.apply(event({
      type: "REFUND",
      occurredAt: NOW + 10,
      autoRenewing: false,
    }));
    expect(refunded.entitlement).toMatchObject({ tier: "free", purchaseState: "refunded" });
    expect((await billingUsers.getTier(db, uid)).tier).toBe("free");

    await service.apply(event({
      id: "new-purchase",
      type: "INITIAL_PURCHASE",
      transactionId: "transaction-2",
      occurredAt: NOW + 20,
    }));
    const expired = await service.apply(event({
      type: "EXPIRATION",
      transactionId: "transaction-2",
      occurredAt: NOW + 30,
      autoRenewing: false,
    }));
    expect(expired.entitlement).toMatchObject({ tier: "free", purchaseState: "expired" });
    expect((await billingUsers.getTier(db, uid)).tier).toBe("free");
  });

  it("dedupes event IDs without a second purchase write and repairs a stale projection", async () => {
    const original = event();
    expect((await service.apply(original)).status).toBe("applied");
    const first = await service.entitlement(uid);
    await redis.set(`user:${uid}:billing_entitlement`, JSON.stringify(FREE));
    await billingUsers.setTier(db, uid, "free", null);

    expect((await service.apply(original)).status).toBe("replayed");
    expect(await service.entitlement(uid)).toEqual(first);
    expect(await cached()).toEqual(first);
    expect((await billingUsers.getTier(db, uid)).tier).toBe("plus");
    const purchases = await db.$client`
      SELECT token FROM billing_purchases WHERE token LIKE 'revenuecat:purchase:%'`;
    expect(purchases).toHaveLength(1);
  });

  it("ignores stale out-of-order events", async () => {
    await service.apply(event({ occurredAt: NOW + 100 }));
    const stale = await service.apply(event({
      type: "CANCELLATION",
      occurredAt: NOW + 50,
      autoRenewing: false,
    }));
    expect(stale.status).toBe("stale");
    expect(stale.entitlement).toMatchObject({ tier: "plus", purchaseState: "active" });
    expect(projections).toHaveLength(1);
  });

  it("rejects stale out-of-order events even within one ledger second", async () => {
    await service.apply(event({ occurredAt: NOW + 100.9 }));
    const stale = await service.apply(event({
      type: "CANCELLATION",
      occurredAt: NOW + 100.8,
      autoRenewing: false,
    }));
    expect(stale.status).toBe("stale");
    expect(stale.entitlement).toMatchObject({ tier: "plus", purchaseState: "active" });
    expect(projections).toHaveLength(1);
  });

  it("moves a server-confirmed account switch and revokes the old account", async () => {
    const oldUid = uid;
    const newUid = testUid("entitlement-switch");
    await service.apply(event({ appUserId: oldUid }));
    const switched = await service.apply(event({
      type: "TRANSFER",
      appUserId: newUid,
      occurredAt: NOW + 10,
    }));
    expect(switched.status).toBe("applied");
    expect(switched.entitlement).toMatchObject({ tier: "plus", period: "yearly" });
    expect(await service.entitlement(oldUid)).toEqual(FREE);
    expect(await service.entitlement(newUid)).toEqual(switched.entitlement);
    expect((await billingUsers.getTier(db, oldUid)).tier).toBe("free");
    expect((await billingUsers.getTier(db, newUid)).tier).toBe("plus");
  });

  it("restores only from a newer server event with a verified future expiry", async () => {
    await service.apply(event());
    await service.apply(event({
      type: "CANCELLATION",
      occurredAt: NOW + 10,
      autoRenewing: false,
    }));
    const restored = await service.apply(event({
      type: "RESTORE",
      occurredAt: NOW + 20,
      expiresAt: NOW + YEAR * 2,
      autoRenewing: true,
    }));
    expect(restored.entitlement).toMatchObject({
      tier: "plus",
      purchaseState: "active",
      autoRenewing: true,
      expiresAt: NOW + YEAR * 2,
    });
  });

  it("never grants an unknown product or a pending purchase", async () => {
    await expect(service.apply(event({ productId: "forged" }))).rejects.toMatchObject({
      status: 400,
      code: "unknown_product",
    } satisfies Partial<BillingError>);
    expect(projections).toEqual([]);

    const pending = await service.apply(event({ type: "PENDING", productId: "ovid_pro_monthly" }));
    expect(pending.entitlement).toEqual({
      tier: "free",
      productId: "ovid_pro_monthly",
      period: "monthly",
      expiresAt: NOW + YEAR,
      autoRenewing: false,
      purchaseState: "pending",
    });
    expect((await billingUsers.getTier(db, uid)).tier).toBe("free");
  });

  it("repairs a failed refund projection on retry instead of blindly replaying success", async () => {
    await service.apply(event());
    let fail = true;
    service = createEntitlementService({
      db,
      redis,
      clock: () => now,
      setTier: async (target, tier, expiresAt) => {
        if (fail && target === uid && tier === "free") throw new Error("isolated projection outage");
        projections.push({ uid: target, tier, expiresAt });
        await billingUsers.setTier(db, target, tier, expiresAt);
      },
    });
    const refund = event({ type: "REFUND", occurredAt: NOW + 10, autoRenewing: false });
    await expect(service.apply(refund)).rejects.toThrow("isolated projection outage");
    expect((await billingUsers.getTier(db, uid)).tier).toBe("plus");

    fail = false;
    const recovered = await service.apply(refund);
    expect(recovered.status).toBe("recovered");
    expect(recovered.entitlement).toMatchObject({ tier: "free", purchaseState: "refunded" });
    expect((await billingUsers.getTier(db, uid)).tier).toBe("free");
    expect((await cached()).purchaseState).toBe("refunded");
  });

  it("retains the previous owner across a failed account-switch projection retry", async () => {
    const oldUid = uid;
    const newUid = testUid("switch-retry");
    await service.apply(event({ appUserId: oldUid }));
    let fail = true;
    service = createEntitlementService({
      db,
      redis,
      clock: () => now,
      setTier: async (target, tier, expiresAt) => {
        if (fail && target === newUid) throw new Error("new owner projection failed");
        projections.push({ uid: target, tier, expiresAt });
        await billingUsers.setTier(db, target, tier, expiresAt);
      },
    });
    const transfer = event({
      type: "TRANSFER",
      appUserId: newUid,
      occurredAt: NOW + 10,
    });
    await expect(service.apply(transfer)).rejects.toThrow("new owner projection failed");
    fail = false;

    const recovered = await service.apply(transfer);
    expect(recovered.status).toBe("recovered");
    expect(recovered.entitlement).toMatchObject({ tier: "plus", period: "yearly" });
    expect((await billingUsers.getTier(db, oldUid)).tier).toBe("free");
    expect((await billingUsers.getTier(db, newUid)).tier).toBe("plus");
    expect(projections).toEqual(expect.arrayContaining([
      { uid: oldUid, tier: "free", expiresAt: null },
      { uid: newUid, tier: "plus", expiresAt: NOW + YEAR },
    ]));
  });

  it("handles the official TRANSFER payload without transaction, product, or expiry fields", async () => {
    const oldUid = "00005A1C-6091-4F81-BE77-F0A83A271AB6";
    const newUid = "4BEDB450-8EF2-11E9-B475-0800200C9A66";
    await service.apply(event({ appUserId: oldUid }));
    const { parseRevenueCatEvent } = await import("./revenuecatWebhook.js");
    const parsed = parseRevenueCatEvent({
      event: {
        app_id: "1234567890",
        event_timestamp_ms: 78789789798798,
        id: "CD489E0E-5D52-4E03-966B-A7F17788E432",
        store: "APP_STORE",
        transferred_from: [oldUid],
        transferred_to: [newUid],
        type: "TRANSFER",
        environment: "PRODUCTION",
      },
      api_version: "1.0",
    });
    expect(parsed).not.toBeNull();

    const result = await service.apply(parsed!);
    expect(result.status).toBe("applied");
    expect(result.entitlement).toMatchObject({ tier: "plus", productId: "ovid_pro_yearly" });
    expect((await billingUsers.getTier(db, oldUid)).tier).toBe("free");
    expect((await billingUsers.getTier(db, newUid)).tier).toBe("plus");
  });

  it("ignores SANDBOX and missing-environment events without granting production entitlement", async () => {
    for (const environment of ["SANDBOX", null]) {
      const result = await service.apply(event({ environment }));
      expect(result.status).toBe("ignored");
      expect(result.entitlement).toEqual(FREE);
      expect(await service.entitlement(uid)).toEqual(FREE);
    }
    expect(await billingUsers.listPurchases(db, uid)).toEqual([]);
    expect(projections).toEqual([]);
    const rows = await db.$client`SELECT token FROM billing_purchases`;
    expect(rows).toEqual([]);
  });

  it("uses official SUBSCRIPTION_EXTENDED semantics", async () => {
    await service.apply(event());
    const extended = await service.apply(event({
      type: "SUBSCRIPTION_EXTENDED",
      occurredAt: NOW + 10,
      expiresAt: NOW + YEAR + 86400,
    }));
    expect(extended.status).toBe("applied");
    expect(extended.entitlement).toMatchObject({
      tier: "plus",
      purchaseState: "active",
      expiresAt: NOW + YEAR + 86400,
    });
  });

  it("keeps BILLING_ISSUE access through grace_period_expiration_at_ms", async () => {
    await service.apply(event());
    const result = await service.apply(event({
      type: "BILLING_ISSUE",
      occurredAt: NOW + 10,
      expiresAt: NOW + 100,
      gracePeriodExpiresAt: NOW + 1000,
    }));
    expect(result.entitlement).toMatchObject({
      tier: "plus",
      purchaseState: "active",
      expiresAt: NOW + 1000,
    });
    now = NOW + 500;
    expect((await service.entitlement(uid)).tier).toBe("plus");
    now = NOW + 1001;
    expect((await service.entitlement(uid)).tier).toBe("free");
  });

  it("defers PRODUCT_CHANGE new_product_id until a later renewal", async () => {
    await service.apply(event({ productId: "ovid_pro_monthly" }));
    const deferred = await service.apply(event({
      type: "PRODUCT_CHANGE",
      occurredAt: NOW + 10,
      productId: "ovid_pro_monthly",
      newProductId: "ovid_max_yearly",
      expiresAt: NOW + YEAR,
    }));
    expect(deferred.status).toBe("deferred");
    expect(deferred.entitlement).toMatchObject({
      tier: "plus",
      productId: "ovid_pro_monthly",
      period: "monthly",
    });

    const renewed = await service.apply(event({
      type: "RENEWAL",
      occurredAt: NOW + 20,
      productId: "ovid_max_yearly",
      expiresAt: NOW + YEAR * 2,
    }));
    expect(renewed.entitlement).toMatchObject({
      tier: "pro",
      productId: "ovid_max_yearly",
      period: "yearly",
      purchaseState: "active",
    });
  });

  it("restores a future-dated entitlement on official REFUND_REVERSED", async () => {
    await service.apply(event());
    await service.apply(event({ type: "REFUND", occurredAt: NOW + 10 }));
    const reversed = await service.apply(event({
      type: "REFUND_REVERSED",
      occurredAt: NOW + 20,
      expiresAt: NOW + YEAR * 2,
      autoRenewing: true,
    }));
    expect(reversed.status).toBe("applied");
    expect(reversed.entitlement).toMatchObject({
      tier: "plus",
      purchaseState: "active",
      autoRenewing: true,
      expiresAt: NOW + YEAR * 2,
    });
  });

  function productionDeps(fake: FakeLiteLlm, litellm = createLiteLlmAdmin(fake.baseUrl, MASTER_KEY)): MintDeps {
    return {
      db,
      redis,
      litellm,
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
      }),
      alerter: async () => {},
      verifyIdentity: async () => ({ uid: "unused", email: null, platform: "android" }),
      clock: () => new Date(now * 1000),
    };
  }

  function productionService(deps: MintDeps, setTier?: TierSink): EntitlementService {
    return createEntitlementService({
      db,
      redis,
      clock: () => now,
      setTier: setTier ?? createTierSink({
        db,
        redis,
        projection: createProjection({ db, redis }),
        reapplyUser: (target) => reapplyUser(deps, target),
      }),
    });
  }

  it("real createTierSink/reapplyUser keeps LiteLLM failure pending until retry succeeds", async () => {
    const fake = new FakeLiteLlm();
    await fake.start();
    try {
      await getSettings({ db });
      const base = createLiteLlmAdmin(fake.baseUrl, MASTER_KEY);
      let failUserUpdate = false;
      const deps = productionDeps(fake, {
        ...base,
        userUpdate: async (body) => failUserUpdate ? 503 : base.userUpdate(body),
      });
      const real = productionService(deps);
      await real.apply(event());
      const refund = event({ type: "REFUND", occurredAt: NOW + 10 });
      failUserUpdate = true;

      await expect(real.apply(refund)).rejects.toThrow(/projection|user\/update/i);
      const [marker] = await db.$client`
        SELECT status FROM billing_purchases WHERE token = ${`revenuecat:event:${refund.id}`}`;
      expect(marker).toMatchObject({ status: "pending" });
      expect((await billingUsers.getTier(db, uid)).tier).toBe("free");
      expect(await redis.get(`user:${uid}:tier`)).toBeNull();
      expect(await redis.get(`user:${uid}:billing_entitlement`)).toBeNull();

      failUserUpdate = false;
      const recovered = await real.apply(refund);
      expect(recovered.status).toBe("recovered");
      expect(recovered.entitlement).toMatchObject({ tier: "free", purchaseState: "refunded" });
      const [projected] = await db.$client`
        SELECT status FROM billing_purchases WHERE token = ${`revenuecat:event:${refund.id}`}`;
      expect(projected).toMatchObject({ status: "replaced" });
      expect((await cached()).purchaseState).toBe("refunded");
    } finally {
      await fake.stop();
    }
  });

  it("version-fences the real sink so no stale paid state is visible post-refund/pre-repair", async () => {
    const fake = new FakeLiteLlm();
    await fake.start();
    let entered!: () => void;
    let release!: () => void;
    let sinkReturned!: () => void;
    let finishRepair!: () => void;
    const enteredPromise = new Promise<void>((resolve) => { entered = resolve; });
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const returnedPromise = new Promise<void>((resolve) => { sinkReturned = resolve; });
    const repairGate = new Promise<void>((resolve) => { finishRepair = resolve; });
    try {
      await getSettings({ db });
      const deps = productionDeps(fake);
      const real = productionService(deps);
      await real.apply(event());
      const realSetTier = createTierSink({
        db,
        redis,
        projection: createProjection({ db, redis }),
        reapplyUser: (target) => reapplyUser(deps, target),
      });
      let blocked = false;
      const older = productionService(deps, async (target, tier, expiresAt, generation) => {
        if (!blocked && target === uid && tier === "plus") {
          blocked = true;
          entered();
          await gate;
          try {
            await realSetTier(target, tier, expiresAt, generation);
          } finally {
            sinkReturned();
            await repairGate;
          }
          return;
        }
        await realSetTier(target, tier, expiresAt, generation);
      });
      const oldRefresh = older.refresh(uid);
      await enteredPromise;

      await real.apply(event({ type: "REFUND", occurredAt: NOW + 20 }));
      expect((await billingUsers.getTier(db, uid)).tier).toBe("free");
      expect(await redis.get(`user:${uid}:tier`)).toBeNull();

      release();
      await returnedPromise;
      const beforeRepair = {
        durable: (await billingUsers.getTier(db, uid)).tier,
        redis: await redis.get(`user:${uid}:tier`),
      };
      finishRepair();
      await oldRefresh;
      expect(beforeRepair).toEqual({ durable: "free", redis: null });
      expect((await billingUsers.getTier(db, uid)).tier).toBe("free");
      expect(await redis.get(`user:${uid}:tier`)).toBeNull();
      expect((await cached()).purchaseState).toBe("refunded");
    } finally {
      release();
      finishRepair();
      await fake.stop();
    }
  });

  it("serializes in-flight paid /user/update before refund even with an interrupted older repair", async () => {
    const fake = new FakeLiteLlm();
    await fake.start();
    let oldRemoteStarted!: () => void;
    let releaseOldRemote!: () => void;
    let oldSinkSettled!: () => void;
    let finishOldRepair!: () => void;
    const oldRemoteStartedPromise = new Promise<void>((resolve) => { oldRemoteStarted = resolve; });
    const oldRemoteGate = new Promise<void>((resolve) => { releaseOldRemote = resolve; });
    const oldSinkSettledPromise = new Promise<void>((resolve) => { oldSinkSettled = resolve; });
    const oldRepairGate = new Promise<void>((resolve) => { finishOldRepair = resolve; });
    try {
      await getSettings({ db });
      const base = createLiteLlmAdmin(fake.baseUrl, MASTER_KEY);
      let delayOldPaid = false;
      const deps = productionDeps(fake, {
        ...base,
        userUpdate: async (body) => {
          if (delayOldPaid && body.user_id === uid && body.max_budget === paidBudget) {
            oldRemoteStarted();
            await oldRemoteGate;
          }
          return base.userUpdate(body);
        },
      });
      const real = productionService(deps);
      await real.apply(event());
      const paidBudget = fake.users.get(uid)?.max_budget;
      expect(paidBudget).toBeGreaterThan(0);
      const realSetTier = createTierSink({
        db,
        redis,
        projection: createProjection({ db, redis }),
        reapplyUser: (target) => reapplyUser(deps, target),
      });
      let blocked = false;
      const older = productionService(deps, async (target, tier, expiresAt, generation) => {
        if (!blocked && target === uid && tier === "plus") {
          blocked = true;
          try {
            await realSetTier(target, tier, expiresAt, generation);
          } finally {
            oldSinkSettled();
            // Simulate interruption before the older refresh can self-repair.
            await oldRepairGate;
          }
          return;
        }
        await realSetTier(target, tier, expiresAt, generation);
      });

      delayOldPaid = true;
      const oldRefresh = older.refresh(uid);
      await oldRemoteStartedPromise;
      let refundSettled = false;
      const refundPromise = real.apply(event({ type: "REFUND", occurredAt: NOW + 20 }))
        .then((result) => {
          refundSettled = true;
          return result;
        });
      await new Promise((resolve) => setTimeout(resolve, 50));
      const refundSettledBeforeOldRemote = refundSettled;

      releaseOldRemote();
      await oldSinkSettledPromise;
      const deadline = Date.now() + 2_000;
      while (!refundSettled && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 5));
      }
      const budgetBeforeOldRepair = fake.users.get(uid)?.max_budget;
      finishOldRepair();
      const [refundResult] = await Promise.all([refundPromise, oldRefresh]);
      const finalBudget = fake.users.get(uid)?.max_budget;

      expect({
        refundSettledBeforeOldRemote,
        budgetBeforeOldRepair,
        finalBudget,
        refundStatus: refundResult.status,
      }).toEqual({
        refundSettledBeforeOldRemote: false,
        budgetBeforeOldRepair: 10,
        finalBudget: 10,
        refundStatus: "applied",
      });
    } finally {
      releaseOldRemote();
      finishOldRepair();
      await fake.stop();
    }
  });

  it("reconciles an accepted paid timeout with remote readback before allowing refund success", async () => {
    const fake = new FakeLiteLlm();
    await fake.start();
    let oldRequestStarted!: () => void;
    let releaseOldApply!: () => void;
    let oldApplied!: () => void;
    const oldRequestStartedPromise = new Promise<void>((resolve) => { oldRequestStarted = resolve; });
    const oldApplyGate = new Promise<void>((resolve) => { releaseOldApply = resolve; });
    const oldAppliedPromise = new Promise<void>((resolve) => { oldApplied = resolve; });
    try {
      await getSettings({ db });
      const base = createLiteLlmAdmin(fake.baseUrl, MASTER_KEY);
      let paidBudget = 0;
      let delayOld = false;
      let failFree = true;
      const deps = productionDeps(fake, {
        ...base,
        userUpdate: async (body) => {
          if (delayOld && body.user_id === uid && body.max_budget === paidBudget) {
            oldRequestStarted();
            // The server accepted the paid mutation; the client times out now.
            // It applies independently after the newer refund has started.
            void oldApplyGate.then(() => {
              fake.users.get(uid)!.max_budget = paidBudget;
              oldApplied();
            });
            return 0;
          }
          if (body.user_id === uid && body.max_budget === 10 && failFree) {
            // A later repair is also accepted but its response is lost.
            const remote = fake.users.get(uid)!;
            remote.max_budget = 10;
            if (body.budget_duration !== undefined) {
              remote.budget_duration = body.budget_duration as string;
            }
            return 0;
          }
          return base.userUpdate(body);
        },
      });
      const real = productionService(deps);
      await real.apply(event());
      paidBudget = fake.users.get(uid)!.max_budget!;
      // Make the old expected paid value differ from the current remote readback.
      fake.users.get(uid)!.max_budget = 0;
      delayOld = true;
      const oldRefresh = real.refresh(uid);
      await oldRequestStartedPromise;
      await expect(oldRefresh).rejects.toThrow(/user\/update|projection/i);

      const refund = event({ type: "REFUND", occurredAt: NOW + 20 });
      const firstOutcome = await real.apply(refund).then(
        () => "resolved" as const,
        () => "rejected" as const,
      );
      expect(firstOutcome).toBe("rejected");
      const [pending] = await db.$client`
        SELECT status FROM billing_purchases WHERE token = ${`revenuecat:remote:${uid}`}`;
      expect(pending).toMatchObject({ status: "pending" });

      releaseOldApply();
      await oldAppliedPromise;
      // A failed repair is accepted remotely but remains unresolved until readback.
      const failedRepair = await real.apply(refund).then(
        () => "resolved" as const,
        () => "rejected" as const,
      );
      expect(failedRepair).toBe("rejected");
      expect(fake.users.get(uid)?.max_budget).toBe(10);

      failFree = false;
      const recovered = await real.apply(refund);
      expect(recovered.status).toBe("recovered");
      expect(fake.users.get(uid)?.max_budget).toBe(10);
      const [resolved] = await db.$client`
        SELECT status FROM billing_purchases WHERE token = ${`revenuecat:remote:${uid}`}`;
      expect(resolved).toMatchObject({ status: "replaced" });
      const [eventMarker] = await db.$client`
        SELECT status FROM billing_purchases WHERE token = ${`revenuecat:event:${refund.id}`}`;
      expect(eventMarker).toMatchObject({ status: "replaced" });
    } finally {
      releaseOldApply();
      await fake.stop();
    }
  });

  it("preserves verified autoRenewing through official payloads that omit auto_renew_status", async () => {
    const { parseRevenueCatEvent } = await import("./revenuecatWebhook.js");
    await service.apply(event());
    const lifecycle = [
      "RENEWAL",
      "SUBSCRIPTION_EXTENDED",
      "BILLING_ISSUE",
      "REFUND",
      "REFUND_REVERSED",
    ] as const;
    for (const [index, type] of lifecycle.entries()) {
      const parsed = parseRevenueCatEvent({
        event: {
          event_timestamp_ms: (NOW + 100 + index) * 1000,
          product_id: "ovid_pro_yearly",
          period_type: "NORMAL",
          purchased_at_ms: NOW * 1000,
          expiration_at_ms: (NOW + YEAR * (index + 2)) * 1000,
          ...(type === "BILLING_ISSUE"
            ? { grace_period_expiration_at_ms: (NOW + YEAR * 6) * 1000 }
            : {}),
          environment: "PRODUCTION",
          transaction_id: "transaction-1",
          original_transaction_id: "transaction-1",
          app_user_id: uid,
          original_app_user_id: uid,
          store: "APP_STORE",
          type,
          id: `official-auto-${type}`,
          app_id: "1234567890",
        },
        api_version: "1.0",
      });
      expect(parsed).not.toBeNull();
      expect(parsed!.autoRenewing).toBeNull();
      const result = await service.apply(parsed!);
      expect(result.entitlement.autoRenewing).toBe(type === "REFUND" ? false : true);
    }
  });

  it("fences an older blocked refresh behind a newer refund", async () => {
    await service.apply(event());
    let release!: () => void;
    let entered!: () => void;
    const enteredPromise = new Promise<void>((resolve) => { entered = resolve; });
    const gate = new Promise<void>((resolve) => { release = resolve; });
    let blocked = false;
    const older = createEntitlementService({
      db,
      redis,
      clock: () => now,
      setTier: async (target, tier, expiresAt) => {
        if (!blocked && target === uid && tier === "plus") {
          blocked = true;
          entered();
          await gate;
        }
        await billingUsers.setTier(db, target, tier, expiresAt);
      },
    });
    const oldRefresh = older.refresh(uid);
    await enteredPromise;

    await service.apply(event({ type: "REFUND", occurredAt: NOW + 20, autoRenewing: false }));
    expect((await billingUsers.getTier(db, uid)).tier).toBe("free");
    release();
    await oldRefresh;

    expect((await billingUsers.getTier(db, uid)).tier).toBe("free");
    expect((await cached()).purchaseState).toBe("refunded");
    expect(await service.entitlement(uid)).toMatchObject({ tier: "free", purchaseState: "refunded" });
  });
});
