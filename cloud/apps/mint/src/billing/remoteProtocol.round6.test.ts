import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import {
  BillingRemoteOperationConflictError,
  BillingRemotePlaintextUnavailableError,
  BillingRemoteUnresolvedError,
  billingRemote,
  billingUsers,
  createBillingRemoteAuthority,
  createDb,
  createLiteLlmBillingTransport,
  schema,
  type BillingRemoteAuthority,
  type Db,
} from "@ovid/db";
import type { Redis } from "ioredis";
import {
  createCloudCleanup,
  createHttpKeyAdmin,
  createNoopR2Deleter,
  type KeyAdmin,
} from "../../../../packages/account/src/adapters.js";
import {
  createIpAnomalyGuard,
  createIpAnomalySuspension,
} from "../../../gateway/src/ipAnomalyGuard.js";
import { createIpObservationStore } from "../../../gateway/src/ipObservations.js";
import type { SuspensionMailInput } from "../../../gateway/src/suspensionMailer.js";
import type { MintDeps } from "../app.js";
import { buildMintApps } from "../app.js";
import { loadMintEnv } from "../env.js";
import { litellmMintOrGet } from "../keyMint.js";
import { createLiteLlmAdmin } from "../litellmAdmin.js";
import { createProtocolKeyLifecycle } from "./keyLifecycle.js";
import { createProjection } from "../projection.js";
import { getSettings, storeSettings } from "../settings.js";
import {
  executeBillingRemoteOperation,
  reapplyUser,
  resetWindowUser,
  updateKeyProjection,
  withBillingAccountWrite,
} from "../windows.js";
import { FakeLiteLlm, MASTER_KEY, standardModels } from "../test/litellmFake.js";
import {
  closeDb,
  closeRedis,
  openFlushedRedis,
  resetTestDb,
  testUid,
  TEST_DATABASE_URL,
  TEST_MINT_REDIS_URL,
} from "../test/env.js";
import { createTierSink } from "./tierSink.js";
import {
  createEntitlementService,
  type EntitlementService,
  type RevenueCatEvent,
} from "./entitlements.js";

/**
 * ROUND-6/7 ADVERSARIAL REGRESSIONS — UNEXECUTED under HEAVY-COMMANDS-PAUSED.
 * Real production services/adapters, scratch Postgres/Redis, and local HTTP only.
 */
const RUN = TEST_DATABASE_URL !== undefined && TEST_MINT_REDIS_URL !== undefined;
const NOW = 1_800_000_000;
const YEAR = 365 * 86_400;
const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

describe.skipIf(!RUN)("UNEXECUTED shared billing protocol production seams", () => {
  let db: Db;
  let redis: Redis;
  let fake: FakeLiteLlm;
  let uid: string;
  let sequence: number;

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
    uid = testUid("round7-protocol");
    sequence = 0;
    fake = new FakeLiteLlm();
    await fake.start();
    await getSettings({ db });
  });

  afterEach(async () => {
    await fake.stop();
  });

  function event(overrides: Partial<RevenueCatEvent> = {}): RevenueCatEvent {
    sequence += 1;
    return {
      id: `round7-event-${sequence}`,
      type: "INITIAL_PURCHASE",
      occurredAt: NOW,
      appUserId: uid,
      transactionId: "round7-transaction",
      productId: "ovid_pro_yearly",
      expiresAt: NOW + YEAR,
      autoRenewing: true,
      cancelReason: null,
      environment: "PRODUCTION",
      ...overrides,
    };
  }

  function productionDeps(opts: {
    litellm?: MintDeps["litellm"];
    fetchImpl?: typeof fetch;
    allowTestUpgrade?: boolean;
  } = {}): MintDeps {
    return {
      db,
      redis,
      litellm: opts.litellm ?? createLiteLlmAdmin(fake.baseUrl, MASTER_KEY),
      ...(opts.fetchImpl === undefined ? {} : { fetchImpl: opts.fetchImpl }),
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
        ALLOW_TEST_UPGRADE: opts.allowTestUpgrade === true ? "true" : "false",
      }),
      alerter: async () => {},
      verifyIdentity: async () => ({ uid, email: null, platform: "android" }),
    };
  }

  function productionService(deps = productionDeps()): EntitlementService {
    return createEntitlementService({
      db,
      redis,
      clock: () => NOW,
      setTier: createTierSink({
        db,
        redis,
        projection: createProjection({ db, redis }),
        reapplyUser: (target) => reapplyUser(deps, target),
      }),
    });
  }

  async function withLazyProductionKeyAdmin<T>(
    operation: (keyAdmin: KeyAdmin) => Promise<T>,
    fetchImpl: typeof fetch = fetch,
  ): Promise<T> {
    const previous = process.env.DATABASE_URL;
    process.env.DATABASE_URL = TEST_DATABASE_URL!;
    // Deliberately no {db}/{databaseUrl}: production enters its lazy max:1
    // branch. close() releases that owned handle after the bounded test.
    const keyAdmin = createHttpKeyAdmin(fake.baseUrl, MASTER_KEY, fetchImpl);
    try {
      return await operation(keyAdmin);
    } finally {
      await keyAdmin.close?.();
      if (previous === undefined) delete process.env.DATABASE_URL;
      else process.env.DATABASE_URL = previous;
    }
  }

  async function drainOnlyPending(deps: MintDeps): Promise<void> {
    const pending = await billingRemote.listUnresolved(db, uid);
    expect(pending).toHaveLength(1);
    const apps = buildMintApps(deps);
    try {
      const response = await apps.adminApp.inject({
        method: "POST",
        url: "/admin/billing/remote-operations/drain",
        headers: { authorization: "Bearer sk-admin-test" },
        payload: {
          uid,
          operation_id: pending[0]!.id,
          confirmation: "remote-request-drained",
        },
      });
      expect(response.statusCode).toBe(202);
      expect(response.json()).toEqual({ drained: true, retry_required: true });
    } finally {
      await apps.adminApp.close();
      await apps.publicApp.close();
    }
  }

  it("does not acknowledge a refund while the original paid request can apply afterward", async () => {
    const service = productionService();
    await service.apply(event());
    const paidBudget = fake.users.get(uid)!.max_budget!;
    // Force the older paid refresh to send even though the purchase had just
    // installed that same budget. The accepted application is held remotely.
    fake.users.get(uid)!.max_budget = 0;
    let release!: () => void;
    let applied!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const appliedPromise = new Promise<void>((resolve) => { applied = resolve; });
    let delayOriginal = true;
    fake.beforeHandle = ({ path, body, response }) => {
      if (delayOriginal && path === "/user/update" && body.max_budget === paidBudget) {
        delayOriginal = false;
        response.socket?.destroy();
        void gate.then(() => {
          fake.users.get(uid)!.max_budget = paidBudget;
          applied();
        });
        return true;
      }
      return false;
    };

    await expect(service.refresh(uid)).rejects.toThrow(/unresolved/i);
    const refund = event({ type: "REFUND", occurredAt: NOW + 20 });
    await expect(service.apply(refund)).rejects.toThrow(/unresolved/i);
    expect(fake.posts("/user/update").filter((body) => body.max_budget === 10)).toHaveLength(0);

    // Release the original mutation only AFTER the newer refund attempt has
    // returned. Stale paid state exists, but no refund was acknowledged.
    release();
    await appliedPromise;
    expect(fake.users.get(uid)!.max_budget).toBe(paidBudget);
    await expect(service.apply(refund)).rejects.toThrow(/unresolved/i);
    expect(fake.posts("/user/update").filter((body) => body.max_budget === 10)).toHaveLength(0);
    expect(await billingRemote.listUnresolved(db, uid)).toHaveLength(1);

    fake.beforeHandle = undefined;
    await drainOnlyPending(productionDeps());
    const recovered = await productionService().apply(refund);
    expect(recovered.status).toBe("recovered");
    expect(fake.users.get(uid)!.max_budget).toBe(10);
    expect(fake.posts("/user/update").filter((body) => body.max_budget === 10)).toHaveLength(1);
  }, 20_000);

  it("retires a pending old-key update on authenticated 404 and verifies its replacement", async () => {
    standardModels(fake);
    const oldTarget = "tok-old-deleted";
    fake.addKey(oldTarget, { max_budget: 0, budget_duration: "24h" });
    await redis.set(`user:${uid}:keyid`, oldTarget);
    await redis.set(`user:${uid}:key`, "fixture-old-plaintext");
    fake.beforeResponse = ({ path, response }) => {
      if (path === "/key/update") {
        response.socket?.destroy();
        return true;
      }
      return false;
    };
    await expect(updateKeyProjection(productionDeps(), uid, oldTarget, {
      key: oldTarget,
      max_budget: 1,
    })).rejects.toThrow(/unresolved/i);
    expect(await billingRemote.listUnresolved(db, uid)).toHaveLength(1);

    fake.keys.delete(oldTarget);
    fake.beforeResponse = undefined;
    const plaintext = await litellmMintOrGet(productionDeps(), uid, "free", "android");
    const replacement = await redis.get(`user:${uid}:keyid`);
    expect(plaintext).not.toBe("fixture-old-plaintext");
    expect(replacement).not.toBe(oldTarget);
    expect(replacement).not.toBeNull();
    expect(fake.keys.has(replacement!)).toBe(true);
    expect(fake.posts("/key/generate")).toHaveLength(1);
    expect(await billingRemote.listUnresolved(db, uid)).toEqual([]);
    const recoveredEntitlement = await productionService().refresh(uid);
    expect(recoveredEntitlement.tier).toBe("free");
    expect(await billingRemote.listUnresolved(db, uid)).toEqual([]);

    // A 500 is unavailable, not deletion, and cannot trigger another create.
    fake.failKeyInfo = true;
    await expect(litellmMintOrGet(productionDeps(), uid, "free", "android"))
      .rejects.toMatchObject({ status: 503 });
    expect(fake.posts("/key/generate")).toHaveLength(1);
  }, 20_000);

  it("preserves completed forced targets across second-key drain, restart, and intervening generations", async () => {
    const operationId = "round7-reset-original";
    await redis.set(`user:${uid}:keyid`, "tok-reset-a");
    await redis.set(`user:${uid}:web:keyid`, "tok-reset-b");
    fake.addKey("tok-reset-a", { max_budget: 0, budget_duration: "1h" });
    fake.addKey("tok-reset-b", { max_budget: 0, budget_duration: "1h" });
    fake.users.set(uid, { spend: 0, budget_duration: "1h" });
    let loseSecond = true;
    fake.beforeHandle = ({ path, body, response }) => {
      if (loseSecond && path === "/key/update" && body.key === "tok-reset-b") {
        loseSecond = false;
        response.socket?.destroy();
        return true;
      }
      return false;
    };

    const first = await resetWindowUser(productionDeps(), uid, {
      resetMonthFree: true,
      operationId,
    });
    expect(first).toEqual({ keys: 1, errors: 1 });
    const resetA = fake.keys.get("tok-reset-a")!.budget_reset_at;
    expect(fake.posts("/key/update").filter((body) => body.key === "tok-reset-a")).toHaveLength(1);
    expect(fake.posts("/key/update").filter((body) => body.key === "tok-reset-b")).toHaveLength(1);
    expect(fake.posts("/user/update")).toHaveLength(0);

    fake.beforeHandle = undefined;
    const firstABody = fake.posts("/key/update").find((body) => body.key === "tok-reset-a")!;
    await drainOnlyPending(productionDeps());

    // Change both the tier-derived budget and rate snapshot after the drain.
    // A is completed and must not be resent. B may resume only with the latest
    // body, never by replaying its old payload under a new body hash.
    const settings = await getSettings({ db });
    await storeSettings({ db, redis }, {
      ...settings,
      normal_rpm: settings.normal_rpm + 1,
    });
    const changingApps = buildMintApps(productionDeps());
    try {
      const changed = await changingApps.adminApp.inject({
        method: "POST",
        url: "/admin/set-tier",
        headers: { authorization: "Bearer sk-admin-test" },
        payload: { uid, tier: "pro" },
      });
      expect(changed.statusCode).toBe(200);
    } finally {
      await changingApps.adminApp.close();
      await changingApps.publicApp.close();
    }
    const keyPosts = (target: string) =>
      fake.posts("/key/update").filter((body) => body.key === target);
    const afterChangeA = keyPosts("tok-reset-a").length;
    const afterChangeB = keyPosts("tok-reset-b").length;
    const afterChangeUser = fake.posts("/user/update").length;

    const recovered = await resetWindowUser(productionDeps(), uid, {
      resetMonthFree: true,
      operationId,
    });
    expect(recovered).toEqual({ keys: 2, errors: 0 });
    const resetB = fake.keys.get("tok-reset-b")!.budget_reset_at;
    const resetUser = fake.users.get(uid)!.budget_reset_at;
    expect(fake.keys.get("tok-reset-a")!.budget_reset_at).toBe(resetA);
    expect(keyPosts("tok-reset-a")).toHaveLength(afterChangeA);
    expect(keyPosts("tok-reset-b")).toHaveLength(afterChangeB + 1);
    expect(fake.posts("/user/update")).toHaveLength(afterChangeUser + 1);
    expect(keyPosts("tok-reset-b").at(-1)).toMatchObject({
      rpm_limit: settings.normal_rpm + 1,
    });
    expect(keyPosts("tok-reset-b").at(-1)!.max_budget).not.toBe(firstABody.max_budget);

    // A fresh retry of the same logical reset uses durable completion despite
    // the changed body, so no read or write POST and no clock reset occurs.
    const beforeRetry = fake.calls.length;
    const again = await resetWindowUser(productionDeps(), uid, {
      resetMonthFree: true,
      operationId,
    });
    expect(again).toEqual({ keys: 2, errors: 0 });
    expect(fake.calls.length).toBe(beforeRetry);
    expect(fake.keys.get("tok-reset-a")!.budget_reset_at).toBe(resetA);
    expect(fake.keys.get("tok-reset-b")!.budget_reset_at).toBe(resetB);
    expect(fake.users.get(uid)!.budget_reset_at).toBe(resetUser);

    const newBaselineA = keyPosts("tok-reset-a").length;
    const newBaselineB = keyPosts("tok-reset-b").length;
    const newBaselineUser = fake.posts("/user/update").length;
    await delay(5);
    const genuinelyNew = await resetWindowUser(productionDeps(), uid, {
      resetMonthFree: true,
      operationId: "round7-reset-new",
    });
    expect(genuinelyNew).toEqual({ keys: 2, errors: 0 });
    expect(keyPosts("tok-reset-a")).toHaveLength(newBaselineA + 1);
    expect(keyPosts("tok-reset-b")).toHaveLength(newBaselineB + 1);
    expect(fake.posts("/user/update")).toHaveLength(newBaselineUser + 1);
    expect(fake.keys.get("tok-reset-a")!.budget_reset_at).not.toBe(resetA);
    expect(fake.keys.get("tok-reset-b")!.budget_reset_at).not.toBe(resetB);
    expect(fake.users.get(uid)!.budget_reset_at).not.toBe(resetUser);
  }, 20_000);

  it("returns non-success for admin/upgrade unresolved work and requires reset operation_id", async () => {
    fake.addKey("tok-compat", { max_budget: 0, budget_duration: "24h" });
    fake.users.set(uid, { spend: 0, budget_duration: "24h" });
    await redis.set(`user:${uid}:keyid`, "tok-compat");
    const deps = productionDeps({ allowTestUpgrade: true });
    const apps = buildMintApps(deps);
    try {
      fake.beforeResponse = ({ path, response }) => {
        if (path === "/key/update") {
          response.socket?.destroy();
          return true;
        }
        return false;
      };
      const admin = await apps.adminApp.inject({
        method: "POST",
        url: "/admin/set-tier",
        headers: { authorization: "Bearer sk-admin-test" },
        payload: { uid, tier: "pro" },
      });
      expect(admin.statusCode).toBe(503);
      expect(admin.json().ok).not.toBe(true);
      expect(admin.body).not.toContain(MASTER_KEY);
      expect(admin.body).not.toContain("tok-compat");
      expect(await billingRemote.listUnresolved(db, uid)).toHaveLength(1);

      fake.beforeResponse = undefined;
      const upgrade = await apps.publicApp.inject({
        method: "POST",
        url: "/upgrade",
        headers: { authorization: "Bearer fixture-identity" },
        payload: { tier: "free" },
      });
      expect(upgrade.statusCode).toBe(503);
      expect(upgrade.json().ok).not.toBe(true);

      const unresolvedReset = await apps.adminApp.inject({
        method: "POST",
        url: "/admin/reset-window",
        headers: { authorization: "Bearer sk-admin-test" },
        payload: { uid, operation_id: "round8-reset-unresolved" },
      });
      expect(unresolvedReset.statusCode).toBe(503);
      expect(unresolvedReset.json().ok).not.toBe(true);
      expect(unresolvedReset.body).not.toContain(MASTER_KEY);
      expect(unresolvedReset.body).not.toContain("tok-compat");

      const missingId = await apps.adminApp.inject({
        method: "POST",
        url: "/admin/reset-window",
        headers: { authorization: "Bearer sk-admin-test" },
        payload: { uid },
      });
      expect(missingId.statusCode).toBe(400);
      expect(missingId.body).toContain("operation_id");
      expect(fake.posts("/user/update")).toHaveLength(0);
    } finally {
      fake.beforeResponse = undefined;
      await apps.adminApp.close();
      await apps.publicApp.close();
    }
  }, 20_000);

  it("completes the real lazy max:1 account/gateway anomaly sequence with an older Redis generation", async () => {
    await db.$client`
      INSERT INTO users (uid, email) VALUES (${uid}, 'owner@example.test')`;
    fake.addKey("tok-anomaly", { user_id: uid, blocked: false });
    const { generation: olderGeneration } = await billingUsers.beginRefresh(db, uid);
    const generationKey = `user:${uid}:billing_refresh_generation`;
    await redis.set(generationKey, String(olderGeneration));
    const mail: string[] = [];

    // No DB is injected: this is the actual lazy max:1 composition. The test
    // timeout bounds any reintroduced nested-pool deadlock.
    await withLazyProductionKeyAdmin(async (keyAdmin) => {
      const suspension = createIpAnomalySuspension({
        db,
        redis,
        keyAdmin,
        mailer: {
          async send(input) {
            mail.push(input.blockId);
            return "sent";
          },
        },
        now: () => new Date(NOW * 1000),
      });
      const result = await suspension.suspend({
        uid,
        blockId: `anomaly:${uid}:round8`,
        reason: "network_fanout",
      });
      expect(result.mailOutcome).toBe("sent");
    });

    expect(mail).toHaveLength(1);
    expect(Number(await redis.get(generationKey))).toBeGreaterThan(olderGeneration);
    expect(await redis.get(`user:${uid}:banned`)).toBe("auto");
    expect(fake.keys.get("tok-anomaly")!.blocked).toBe(true);
    expect(fake.posts("/key/block")).toHaveLength(1);
    const [standing] = await db.$client`
      SELECT banned_at IS NOT NULL AS banned FROM users WHERE uid = ${uid}`;
    expect(standing.banned).toBe(true);
  }, 5_000);

  it("fails closed without mail/applied when the gateway generation reservation is unavailable", async () => {
    await db.$client`
      INSERT INTO users (uid, email) VALUES (${uid}, 'owner@example.test')`;
    fake.addKey("tok-anomaly", { user_id: uid, blocked: false });
    const { generation: olderGeneration } = await billingUsers.beginRefresh(db, uid);
    const generationKey = `user:${uid}:billing_refresh_generation`;
    await redis.set(generationKey, String(olderGeneration));
    const unavailableRedis = Object.create(redis) as Redis;
    unavailableRedis.eval = (async () => {
      throw new Error("reservation unavailable");
    }) as Redis["eval"];
    const mail: string[] = [];
    await withLazyProductionKeyAdmin(async (keyAdmin) => {
      const suspension = createIpAnomalySuspension({
        db,
        redis: unavailableRedis,
        keyAdmin,
        mailer: {
          async send(input) {
            mail.push(input.blockId);
            return "sent";
          },
        },
      });
      const observationStore = createIpObservationStore(redis, { windowMs: 600_000 });
      for (let index = 0; index < 13; index += 1) {
        await observationStore.record(uid, {
          ip: `198.51.100.${index + 1}`,
          asn: null,
          at: NOW * 1000 - index * 1000,
        });
      }
      const guard = createIpAnomalyGuard({
        store: observationStore,
        suspension,
        now: () => NOW * 1000,
        trustedProxyCidrs: ["127.0.0.0/8"],
        onError: () => {},
      });

      const decision = await guard.admit(uid, {
        peerAddress: "127.0.0.1",
        forwardedFor: "203.0.113.200",
      });
      expect(decision).toMatchObject({ block: true, suspension: "degraded" });
      expect(decision.mailOutcome).toBeUndefined();
    });
    expect(mail).toEqual([]);
    expect(fake.posts("/key/block")).toHaveLength(0);
    expect(fake.calls.filter((call) => call.method === "GET" && call.path === "/key/list"))
      .toHaveLength(0);
    expect(fake.keys.get("tok-anomaly")!.blocked).toBe(false);
    expect(await redis.get(generationKey)).toBe(String(olderGeneration));
    expect(await redis.get(`user:${uid}:banned`)).toBeNull();
    const [standing] = await db.$client`
      SELECT banned_at IS NOT NULL AS banned FROM users WHERE uid = ${uid}`;
    expect(standing.banned).toBe(false);
    expect(await billingUsers.getPendingAnomalyStandingProjection(db, uid))
      .toMatchObject({ uid, status: "pending", generation: olderGeneration + 1 });

    // A healthy retry uses the durable pending projection. It must reconcile
    // both standing stores before enumeration/block, then send exactly one mail.
    await withLazyProductionKeyAdmin(async (keyAdmin) => {
      const recovered = await createIpAnomalySuspension({
        db,
        redis,
        keyAdmin,
        mailer: {
          async send(input) {
            mail.push(input.blockId);
            return "sent";
          },
        },
      }).suspend({
        uid,
        blockId: `anomaly:${uid}:reservation-recovery`,
        reason: "network_fanout",
      });
      expect(recovered.mailOutcome).toBe("sent");
    });
    expect(mail).toHaveLength(1);
    expect(await billingUsers.getPendingAnomalyStandingProjection(db, uid)).toBeNull();
    expect(await redis.get(`user:${uid}:banned`)).toBe("auto");
    expect(fake.keys.get("tok-anomaly")!.blocked).toBe(true);
    expect(fake.calls.filter((call) => call.method === "GET" && call.path === "/key/list"))
      .toHaveLength(1);
    expect(fake.posts("/key/block")).toHaveLength(1);
    expect(await billingRemote.listUnresolved(db, uid)).toEqual([]);
    const [recoveredStanding] = await db.$client`
      SELECT banned_at IS NOT NULL AS banned FROM users WHERE uid = ${uid}`;
    expect(recoveredStanding.banned).toBe(true);
    const [refresh] = await db.$client`
      SELECT account_hash AS generation FROM billing_purchases
      WHERE token = ${`revenuecat:refresh:${uid}`}`;
    expect(await redis.get(generationKey)).toBe(refresh.generation);
  }, 10_000);

  it("completes account-cleanup block/delete through the same lazy max:1 composition", async () => {
    fake.addKey("tok-cleanup", { user_id: uid, blocked: false });
    await withLazyProductionKeyAdmin(async (keyAdmin) => {
      const noop = { deleteAccount: async () => {} };
      const cleanup = createCloudCleanup({
        db,
        redisDb2: redis,
        litellm: keyAdmin,
        r2: createNoopR2Deleter(),
        images: noop,
        shares: noop,
        byok: noop,
      });
      await cleanup.revokeKeys(uid, {
        tokens: ["tok-cleanup"],
        session_ids: [],
      });
      expect(fake.keys.get("tok-cleanup")!.blocked).toBe(true);
      const gateway = cleanup.deletionSteps().find((step) => step.name === "gateway")!;
      await gateway.run(uid, { tokens: ["tok-cleanup"], session_ids: [] });
      expect(fake.keys.has("tok-cleanup")).toBe(false);
    });
    expect(fake.posts("/key/block")).toHaveLength(1);
    expect(fake.posts("/key/delete")).toHaveLength(1);
  }, 5_000);

  it("raises the typed conflict for a changed unresolved payload instead of issuing a new operation", async () => {
    const target = "tok-payload-conflict";
    fake.addKey(target, { max_budget: 0, budget_duration: "24h" });
    const deps = productionDeps();
    const idempotencyKey = `round9-conflict:${uid}`;
    const execute = (maxBudget: number) => withBillingAccountWrite(deps, uid, () =>
      executeBillingRemoteOperation(
        deps,
        uid,
        "key",
        target,
        { key: target, max_budget: maxBudget },
        { idempotencyKey },
      )
    );
    fake.beforeResponse = ({ path, response }) => {
      if (path === "/key/update") {
        response.socket?.destroy();
        return true;
      }
      return false;
    };
    await expect(execute(1)).rejects.toBeInstanceOf(BillingRemoteUnresolvedError);
    expect(await billingRemote.listUnresolved(db, uid)).toHaveLength(1);
    fake.beforeResponse = undefined;

    await expect(execute(2)).rejects.toBeInstanceOf(BillingRemoteOperationConflictError);
    expect(fake.posts("/key/update")).toHaveLength(1);
    expect(await billingRemote.listUnresolved(db, uid)).toHaveLength(1);
  }, 10_000);

  it("does not let a delayed stale unblock silently win after a newer ban", async () => {
    const target = "tok-stale-unblock";
    fake.addKey(target, { user_id: uid, blocked: true });
    await redis.set(`user:${uid}:keyid`, target);
    await db.$client`INSERT INTO users (uid) VALUES (${uid})`;
    const deps = productionDeps();
    let release!: () => void;
    let applied!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const appliedPromise = new Promise<void>((resolve) => { applied = resolve; });
    let delayOriginal = true;
    fake.beforeHandle = ({ path, response }) => {
      if (delayOriginal && path === "/key/unblock") {
        delayOriginal = false;
        response.socket?.destroy();
        void gate.then(() => {
          fake.keys.get(target)!.blocked = false;
          applied();
        });
        return true;
      }
      return false;
    };
    const apps = buildMintApps(deps);
    let unbanStatus = 0;
    let banStatus = 0;
    try {
      unbanStatus = (await apps.adminApp.inject({
        method: "POST",
        url: "/admin/unban",
        headers: { authorization: "Bearer sk-admin-test" },
        payload: { uid },
      })).statusCode;
      banStatus = (await apps.adminApp.inject({
        method: "POST",
        url: "/admin/ban",
        headers: { authorization: "Bearer sk-admin-test" },
        payload: { uid },
      })).statusCode;
    } finally {
      await apps.adminApp.close();
      await apps.publicApp.close();
    }
    expect(unbanStatus).toBe(503);
    expect(banStatus).toBe(503);
    expect(fake.posts("/key/block")).toHaveLength(0);

    // Apply the original unblock only after both responses returned. Neither
    // response was success and the uncertain marker still blocks newer work.
    release();
    await appliedPromise;
    expect(fake.keys.get(target)!.blocked).toBe(false);
    expect(await billingRemote.listUnresolved(db, uid)).toHaveLength(1);
    fake.beforeHandle = undefined;
    await drainOnlyPending(deps);

    const recoveredApps = buildMintApps(deps);
    try {
      const recovered = await recoveredApps.adminApp.inject({
        method: "POST",
        url: "/admin/ban",
        headers: { authorization: "Bearer sk-admin-test" },
        payload: { uid },
      });
      expect(recovered.statusCode).toBe(200);
    } finally {
      await recoveredApps.adminApp.close();
      await recoveredApps.publicApp.close();
    }
    expect(fake.keys.get(target)!.blocked).toBe(true);
    expect(fake.posts("/key/unblock")).toHaveLength(1);
    expect(fake.posts("/key/block")).toHaveLength(1);
  }, 15_000);

  it("keeps lost generate unresolved and never creates a second key to recover plaintext", async () => {
    const alias = `ovid:rotate:${uid}:android:1`;
    const body = {
      user_id: uid,
      key_alias: alias,
      max_budget: 0.15,
      metadata: { tier: "free", ovid_uid: uid, platform: "android" },
    };
    fake.beforeResponse = ({ path, response }) => {
      if (path === "/key/generate") {
        response.socket?.destroy();
        return true;
      }
      return false;
    };
    const first = createProtocolKeyLifecycle(productionDeps(), uid);
    await expect(first.keyGenerate(body)).rejects.toBeInstanceOf(BillingRemoteUnresolvedError);
    expect(fake.posts("/key/generate")).toHaveLength(1);
    expect(await billingRemote.listUnresolved(db, uid)).toHaveLength(1);

    const fresh = createProtocolKeyLifecycle(productionDeps(), uid);
    await expect(fresh.keyGenerate(body)).rejects.toBeInstanceOf(BillingRemoteUnresolvedError);
    expect(fake.posts("/key/generate")).toHaveLength(1);
    fake.beforeResponse = undefined;
    await drainOnlyPending(productionDeps());

    const recovered = createProtocolKeyLifecycle(productionDeps(), uid);
    await expect(recovered.keyGenerate(body))
      .rejects.toBeInstanceOf(BillingRemotePlaintextUnavailableError);
    expect(fake.posts("/key/generate")).toHaveLength(1);
    expect(fake.keys.size).toBe(1);
  }, 15_000);

  it("retains a lost lazy delete intent and completes terminal deletion without resending", async () => {
    const target = "tok-lost-delete";
    fake.addKey(target, { user_id: uid, blocked: false });
    const cleanupFor = (keyAdmin: KeyAdmin) => {
      const noop = { deleteAccount: async () => {} };
      return createCloudCleanup({
        db,
        redisDb2: redis,
        litellm: keyAdmin,
        r2: createNoopR2Deleter(),
        images: noop,
        shares: noop,
        byok: noop,
      }).deletionSteps().find((step) => step.name === "gateway")!;
    };
    fake.beforeResponse = ({ path, response }) => {
      if (path === "/key/delete") {
        response.socket?.destroy();
        return true;
      }
      return false;
    };
    await expect(withLazyProductionKeyAdmin((keyAdmin) =>
      cleanupFor(keyAdmin).run(uid, { tokens: [target], session_ids: [] })
    )).rejects.toBeInstanceOf(BillingRemoteUnresolvedError);
    expect(fake.keys.has(target)).toBe(false);
    expect(fake.posts("/key/delete")).toHaveLength(1);
    expect(await billingRemote.listUnresolved(db, uid)).toMatchObject([
      { target, effect: "delete", phase: "uncertain", status: "pending" },
    ]);
    fake.beforeResponse = undefined;

    await withLazyProductionKeyAdmin((keyAdmin) =>
      cleanupFor(keyAdmin).run(uid, { tokens: [target], session_ids: [] })
    );
    expect(fake.posts("/key/delete")).toHaveLength(1);
    expect(await billingRemote.listUnresolved(db, uid)).toEqual([]);
  }, 10_000);

  it("keeps committed standing consistent after post-reservation key-list failure and recovers without mail duplication", async () => {
    await db.$client`
      INSERT INTO users (uid, email) VALUES (${uid}, 'owner@example.test')`;
    fake.addKey("tok-list-failure", { user_id: uid, blocked: false });
    const mail: string[] = [];
    const mailer = {
      async send(input: SuspensionMailInput) {
        mail.push(input.blockId);
        return "sent" as const;
      },
    };
    const listFailureFetch: typeof fetch = async (input, init) => {
      const url = new URL(input instanceof Request ? input.url : String(input));
      const method = init?.method ?? (input instanceof Request ? input.method : "GET");
      if (method === "GET" && url.pathname === "/key/list") {
        return new Response("{}", { status: 500 });
      }
      return fetch(input, init);
    };
    await expect(withLazyProductionKeyAdmin(
      (keyAdmin) => createIpAnomalySuspension({ db, redis, keyAdmin, mailer }).suspend({
        uid,
        blockId: `anomaly:${uid}:list-failure`,
        reason: "network_fanout",
      }),
      listFailureFetch,
    )).rejects.toThrow(/key list failed/);

    expect(mail).toEqual([]);
    expect(fake.posts("/key/block")).toHaveLength(0);
    expect(await redis.get(`user:${uid}:banned`)).toBe("auto");
    const [standing] = await db.$client`
      SELECT banned_at IS NOT NULL AS banned FROM users WHERE uid = ${uid}`;
    expect(standing.banned).toBe(true);
    expect(await billingUsers.getPendingAnomalyStandingProjection(db, uid)).toBeNull();
    expect(await billingRemote.listUnresolved(db, uid)).toEqual([]);

    await withLazyProductionKeyAdmin(async (keyAdmin) => {
      const recovered = await createIpAnomalySuspension({
        db,
        redis,
        keyAdmin,
        mailer,
      }).suspend({
        uid,
        blockId: `anomaly:${uid}:list-failure`,
        reason: "network_fanout",
      });
      expect(recovered.mailOutcome).toBe("sent");
    });
    expect(mail).toHaveLength(1);
    expect(fake.keys.get("tok-list-failure")!.blocked).toBe(true);
    expect(fake.posts("/key/block")).toHaveLength(1);
  }, 10_000);

  it("retains pending anomaly projection after a Redis standing failure until both stores agree", async () => {
    await db.$client`
      INSERT INTO users (uid, email) VALUES (${uid}, 'owner@example.test')`;
    fake.addKey("tok-standing-recovery", { user_id: uid, blocked: false });
    const mail: string[] = [];
    const mailer = {
      async send(input: SuspensionMailInput) {
        mail.push(input.blockId);
        return "sent" as const;
      },
    };
    const failingRedis = Object.create(redis) as Redis;
    const baseEval = redis.eval.bind(redis);
    let evalCalls = 0;
    failingRedis.eval = (async (...args: unknown[]) => {
      evalCalls += 1;
      if (evalCalls === 2) throw new Error("standing projection unavailable");
      return Reflect.apply(baseEval, redis, args);
    }) as Redis["eval"];
    await expect(withLazyProductionKeyAdmin((keyAdmin) =>
      createIpAnomalySuspension({ db, redis: failingRedis, keyAdmin, mailer }).suspend({
        uid,
        blockId: `anomaly:${uid}:standing-recovery`,
        reason: "network_fanout",
      })
    )).rejects.toThrow(/standing projection unavailable/);

    expect(mail).toEqual([]);
    expect(fake.calls.filter((call) => call.method === "GET" && call.path === "/key/list"))
      .toHaveLength(0);
    expect(fake.posts("/key/block")).toHaveLength(0);
    expect(await redis.get(`user:${uid}:banned`)).toBeNull();
    const [standing] = await db.$client`
      SELECT banned_at IS NOT NULL AS banned FROM users WHERE uid = ${uid}`;
    expect(standing.banned).toBe(true);
    expect(await billingUsers.getPendingAnomalyStandingProjection(db, uid))
      .toMatchObject({ uid, status: "pending" });

    await withLazyProductionKeyAdmin(async (keyAdmin) => {
      const recovered = await createIpAnomalySuspension({
        db,
        redis,
        keyAdmin,
        mailer,
      }).suspend({
        uid,
        blockId: `anomaly:${uid}:standing-recovery`,
        reason: "network_fanout",
      });
      expect(recovered.mailOutcome).toBe("sent");
    });
    expect(await redis.get(`user:${uid}:banned`)).toBe("auto");
    expect(await billingUsers.getPendingAnomalyStandingProjection(db, uid)).toBeNull();
    expect(fake.keys.get("tok-standing-recovery")!.blocked).toBe(true);
    expect(fake.posts("/key/block")).toHaveLength(1);
    expect(mail).toHaveLength(1);
  }, 10_000);

  it("persists lazy uncertain block and committed standing across fresh wrappers until explicit drain", async () => {
    await db.$client`
      INSERT INTO users (uid, email) VALUES (${uid}, 'owner@example.test')`;
    const target = "tok-lazy-lost-block";
    fake.addKey(target, { user_id: uid, blocked: false });
    const mail: string[] = [];
    const mailer = {
      async send(input: SuspensionMailInput) {
        mail.push(input.blockId);
        return "sent" as const;
      },
    };
    let release!: () => void;
    let applied!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const appliedPromise = new Promise<void>((resolve) => { applied = resolve; });
    let delayOriginal = true;
    fake.beforeHandle = ({ path, response }) => {
      if (delayOriginal && path === "/key/block") {
        delayOriginal = false;
        response.socket?.destroy();
        void gate.then(() => {
          fake.keys.get(target)!.blocked = true;
          applied();
        });
        return true;
      }
      return false;
    };
    await expect(withLazyProductionKeyAdmin((keyAdmin) =>
      createIpAnomalySuspension({ db, redis, keyAdmin, mailer }).suspend({
        uid,
        blockId: `anomaly:${uid}:lost-block`,
        reason: "network_fanout",
      })
    )).rejects.toBeInstanceOf(BillingRemoteUnresolvedError);

    const [pending] = await billingRemote.listUnresolved(db, uid);
    expect(pending).toMatchObject({ target, effect: "block", phase: "uncertain" });
    const [refresh] = await db.$client`
      SELECT account_hash AS generation FROM billing_purchases
      WHERE token = ${`revenuecat:refresh:${uid}`}`;
    expect(refresh.generation).toBe(String(pending!.generation));
    expect(mail).toEqual([]);
    expect(await redis.get(`user:${uid}:banned`)).toBe("auto");
    const [standing] = await db.$client`
      SELECT banned_at IS NOT NULL AS banned FROM users WHERE uid = ${uid}`;
    expect(standing.banned).toBe(true);
    expect(await billingUsers.getPendingAnomalyStandingProjection(db, uid)).toBeNull();

    await expect(withLazyProductionKeyAdmin((keyAdmin) =>
      createIpAnomalySuspension({ db, redis, keyAdmin, mailer }).suspend({
        uid,
        blockId: `anomaly:${uid}:lost-block`,
        reason: "network_fanout",
      })
    )).rejects.toBeInstanceOf(BillingRemoteUnresolvedError);
    expect(fake.posts("/key/block")).toHaveLength(1);
    expect(mail).toEqual([]);

    // The original block applies only after the fresh wrapper rejected. Its
    // committed uncertainty still prevents a blind success or delete/new send.
    release();
    await appliedPromise;
    expect(fake.keys.get(target)!.blocked).toBe(true);
    expect(await billingRemote.listUnresolved(db, uid)).toHaveLength(1);
    expect(mail).toEqual([]);
    fake.beforeHandle = undefined;
    await drainOnlyPending(productionDeps());

    await withLazyProductionKeyAdmin(async (keyAdmin) => {
      const recovered = await createIpAnomalySuspension({
        db,
        redis,
        keyAdmin,
        mailer,
      }).suspend({
        uid,
        blockId: `anomaly:${uid}:lost-block`,
        reason: "network_fanout",
      });
      expect(recovered.mailOutcome).toBe("sent");
    });
    expect(mail).toHaveLength(1);
    // The original accepted block has already applied. Drain performs no
    // mutation; recovery completes from readback with NO second block POST.
    expect(fake.posts("/key/block")).toHaveLength(1);
    expect(await billingRemote.listUnresolved(db, uid)).toEqual([]);
  }, 15_000);

  it("executes real Drizzle nested savepoints and root rollback on the reserved adapter", async () => {
    const lazyDb = createDb(TEST_DATABASE_URL!, { max: 1 });
    type Tx = Parameters<Parameters<Db["transaction"]>[0]>[0];
    const prefix = testUid("reserved-drizzle-tx");
    const nestedRoot = `${prefix}:nested-root`;
    const nestedChild = `${prefix}:nested-child`;
    const failedOuter = `${prefix}:failed-outer`;
    const failedNested = `${prefix}:failed-nested`;
    const failedRoot = `${prefix}:failed-root`;
    const tokens = [nestedRoot, nestedChild, failedOuter, failedNested, failedRoot];
    const insert = (tx: Tx, token: string) => tx.insert(schema.billingPurchases).values({
      token,
      productId: "reserved_transaction_test",
      tier: "free",
      status: "replaced",
      updatedAt: NOW,
    });
    const exists = async (token: string): Promise<boolean> => {
      const [row] = await lazyDb.$client`
        SELECT token FROM billing_purchases WHERE token = ${token}`;
      return row !== undefined;
    };
    try {
      // Root BEGIN/COMMIT and nested SAVEPOINT/RELEASE all use the one real
      // reserved postgres.js connection through Drizzle's transaction API.
      await billingUsers.withBillingRemoteWriteLock(lazyDb, uid, (lockedDb) =>
        lockedDb.transaction(async (tx) => {
          await insert(tx, nestedRoot);
          await tx.transaction(async (nested) => {
            await insert(nested, nestedChild);
          });
        })
      );
      expect(await exists(nestedRoot)).toBe(true);
      expect(await exists(nestedChild)).toBe(true);

      // Duplicate token aborts only the nested savepoint. The adapter must
      // ROLLBACK TO + RELEASE it so the outer root transaction can still COMMIT.
      await billingUsers.withBillingRemoteWriteLock(lazyDb, uid, (lockedDb) =>
        lockedDb.transaction(async (tx) => {
          await insert(tx, failedOuter);
          let nestedFailed = false;
          try {
            await tx.transaction(async (nested) => {
              await insert(nested, failedNested);
              await insert(nested, failedNested);
            });
          } catch {
            nestedFailed = true;
          }
          expect(nestedFailed).toBe(true);
        })
      );
      expect(await exists(failedOuter)).toBe(true);
      expect(await exists(failedNested)).toBe(false);

      await expect(billingUsers.withBillingRemoteWriteLock(lazyDb, uid, (lockedDb) =>
        lockedDb.transaction(async (tx) => {
          await insert(tx, failedRoot);
          throw new Error("deliberate root transaction failure");
        })
      )).rejects.toThrow("deliberate root transaction failure");
      expect(await exists(failedRoot)).toBe(false);
    } finally {
      for (const token of tokens) {
        await lazyDb.$client`DELETE FROM billing_purchases WHERE token = ${token}`;
      }
      await lazyDb.$client.end({ timeout: 5 });
    }
  }, 10_000);

  it("uses real reserved-connection transactions for lazy success, lost response, nested drain, and readback recovery", async () => {
    const lazyDb = createDb(TEST_DATABASE_URL!, { max: 1 });
    const originalReserve = lazyDb.$client.reserve.bind(lazyDb.$client);
    let reserveCalls = 0;
    lazyDb.$client.reserve = async () => {
      reserveCalls += 1;
      return originalReserve();
    };
    const successTarget = "tok-reserved-success";
    const lostTarget = "tok-reserved-lost";
    const externalTarget = "tok-reserved-external-drain";
    fake.addKey(successTarget, { user_id: uid, blocked: false });
    fake.addKey(lostTarget, { user_id: uid, blocked: false });
    fake.addKey(externalTarget, { user_id: uid, blocked: false });
    const authorityFor = (): BillingRemoteAuthority => createBillingRemoteAuthority({
      db: lazyDb,
      transport: createLiteLlmBillingTransport({
        baseUrl: fake.baseUrl,
        masterKey: MASTER_KEY,
      }),
    });
    const block = (authority: BillingRemoteAuthority, target: string) =>
      authority.withAccount(uid, (generation) => authority.execute({
        uid,
        generation,
        kind: "key",
        target,
        effect: "block",
        blocked: true,
      }));
    try {
      await block(authorityFor(), successTarget);
      expect(fake.keys.get(successTarget)!.blocked).toBe(true);
      expect(fake.posts("/key/block").filter((body) => body.key === successTarget))
        .toHaveLength(1);

      fake.beforeResponse = ({ path, response }) => {
        if (path === "/key/block") {
          response.socket?.destroy();
          return true;
        }
        return false;
      };
      await expect(block(authorityFor(), lostTarget))
        .rejects.toBeInstanceOf(BillingRemoteUnresolvedError);
      const [pending] = await billingRemote.listUnresolved(lazyDb, uid);
      expect(pending).toMatchObject({
        target: lostTarget,
        effect: "block",
        phase: "uncertain",
        status: "pending",
      });
      expect(fake.keys.get(lostTarget)!.blocked).toBe(true);
      expect(fake.posts("/key/block").filter((body) => body.key === lostTarget))
        .toHaveLength(1);

      fake.beforeResponse = undefined;
      const drainAuthority = authorityFor();
      const beforeNestedDrain = reserveCalls;
      expect(await drainAuthority.withAccount(uid, (generation) =>
        drainAuthority.markDrained(uid, pending!.id, generation)
      )).toBe(true);
      // Nested drain must reuse the existing locked connection, not reserve or
      // acquire the session advisory lock recursively.
      expect(reserveCalls).toBe(beforeNestedDrain + 1);
      await block(authorityFor(), lostTarget);
      // Already-applied block uses exact readback: one original POST only.
      expect(fake.posts("/key/block").filter((body) => body.key === lostTarget))
        .toHaveLength(1);
      expect(await billingRemote.listUnresolved(lazyDb, uid)).toEqual([]);

      // The external form has no account context and must reserve exactly once.
      fake.beforeResponse = ({ path, response }) => {
        if (path === "/key/block") {
          response.socket?.destroy();
          return true;
        }
        return false;
      };
      await expect(block(authorityFor(), externalTarget))
        .rejects.toBeInstanceOf(BillingRemoteUnresolvedError);
      const [externalPending] = await billingRemote.listUnresolved(lazyDb, uid);
      expect(externalPending).toMatchObject({
        target: externalTarget,
        effect: "block",
        phase: "uncertain",
      });
      fake.beforeResponse = undefined;
      const beforeExternalDrain = reserveCalls;
      expect(await drainAuthority.markDrained(
        uid,
        externalPending!.id,
        externalPending!.generation,
      )).toBe(true);
      expect(reserveCalls).toBe(beforeExternalDrain + 1);
      await block(authorityFor(), externalTarget);
      expect(fake.posts("/key/block").filter((body) => body.key === externalTarget))
        .toHaveLength(1);
      expect(await billingRemote.listUnresolved(lazyDb, uid)).toEqual([]);
    } finally {
      fake.beforeResponse = undefined;
      await lazyDb.$client.end({ timeout: 5 });
    }
  }, 10_000);
});
