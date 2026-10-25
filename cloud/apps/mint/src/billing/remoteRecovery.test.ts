import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { billingUsers, type Db } from "@ovid/db";
import type { Redis } from "ioredis";
import type { MintDeps } from "../app.js";
import { buildMintApps } from "../app.js";
import { loadMintEnv } from "../env.js";
import { createLiteLlmAdmin } from "../litellmAdmin.js";
import { litellmMintOrGet } from "../keyMint.js";
import { createProjection } from "../projection.js";
import { getSettings } from "../settings.js";
import {
  ensureUserBudget,
  poolPushRateLimits,
  reapplyUser,
  resetWindowUser,
} from "../windows.js";
import { reapplyAll } from "../adminRoutes.js";
import { FakeLiteLlm, MASTER_KEY } from "../test/litellmFake.js";
import { createTierSink } from "./tierSink.js";
import {
  createEntitlementService,
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
const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

describe.skipIf(!RUN)("durable remote writer recovery (real HTTP, Postgres, Redis)", () => {
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
    uid = testUid("remote-recovery");
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
      id: `remote-event-${sequence}`,
      type: "INITIAL_PURCHASE",
      occurredAt: NOW,
      appUserId: uid,
      transactionId: "remote-transaction-1",
      productId: "ovid_pro_yearly",
      expiresAt: NOW + YEAR,
      autoRenewing: true,
      cancelReason: null,
      environment: "PRODUCTION",
      ...overrides,
    };
  }

  function productionDeps(
    litellm = createLiteLlmAdmin(fake.baseUrl, MASTER_KEY),
    fetchImpl?: typeof fetch,
  ): MintDeps {
    return {
      db,
      redis,
      litellm,
      ...(fetchImpl === undefined ? {} : { fetchImpl }),
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
    };
  }

  function productionService(deps: MintDeps): EntitlementService {
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

  async function markerStatus(token: string): Promise<string | undefined> {
    const [row] = await db.$client`
      SELECT status FROM billing_purchases WHERE token = ${token}`;
    return row?.status as string | undefined;
  }

  it("serializes the actual unversioned reapplyAll caller behind a newer refund", async () => {
    const base = createLiteLlmAdmin(fake.baseUrl, MASTER_KEY);
    const normal = productionService(productionDeps(base));
    await normal.apply(event());
    const paidBudget = fake.users.get(uid)!.max_budget!;
    expect(paidBudget).toBeGreaterThan(0);

    let entered!: () => void;
    let release!: () => void;
    const enteredPromise = new Promise<void>((resolve) => { entered = resolve; });
    const gate = new Promise<void>((resolve) => { release = resolve; });
    let delayOld = true;
    const oldDeps = productionDeps({
      ...base,
      userUpdate: async (body) => {
        if (delayOld && body.user_id === uid && body.max_budget === paidBudget) {
          delayOld = false;
          entered();
          await gate;
        }
        return base.userUpdate(body);
      },
    });

    const oldReapply = reapplyAll(oldDeps, [uid]);
    await enteredPromise;
    let refundSettled = false;
    const refundPromise = normal.apply(event({ type: "REFUND", occurredAt: NOW + 20 }))
      .then((result) => {
        refundSettled = true;
        return result;
      });
    await delay(75);
    const refundSettledBeforeOldRemote = refundSettled;

    release();
    const oldResult = await oldReapply;
    const refund = await refundPromise;
    const finalBudget = fake.users.get(uid)?.max_budget;
    expect(oldResult.mode).toBe("sync");
    expect({
      refundSettledBeforeOldRemote,
      paidBudget,
      budgetAtRefundSuccess: finalBudget,
      finalBudget,
      refundStatus: refund.status,
    }).toEqual({
      refundSettledBeforeOldRemote: false,
      paidBudget,
      budgetAtRefundSuccess: 10,
      finalBudget: 10,
      refundStatus: "applied",
    });
  }, 15_000);

  it("fences the complete admin set-tier write behind a newer refund", async () => {
    const deps = productionDeps();
    const real = productionService(deps);
    await real.apply(event());
    const fn = `task4_round5_admin_${Date.now()}_${process.pid}`;
    const apps = buildMintApps(deps);
    await db.$client.unsafe(`
      CREATE FUNCTION ${fn}() RETURNS trigger AS $$
      BEGIN
        IF NEW.tier = 'pro' THEN PERFORM pg_sleep(0.5); END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER ${fn}_trigger BEFORE INSERT OR UPDATE ON users
      FOR EACH ROW WHEN (NEW.uid = '${uid}')
      EXECUTE FUNCTION ${fn}();
    `);
    try {
      let adminSettled = false;
      let refundSettledBeforeAdmin = false;
      const adminPromise = apps.adminApp.inject({
        method: "POST",
        url: "/admin/set-tier",
        headers: { authorization: "Bearer sk-admin-test" },
        payload: { uid, tier: "pro" },
      }).then((response) => {
        adminSettled = true;
        return response;
      });
      await delay(75);
      const refundPromise = real.apply(event({ type: "REFUND", occurredAt: NOW + 20 }))
        .then((result) => {
          refundSettledBeforeAdmin = !adminSettled;
          return result;
        });
      const [adminResponse, refund] = await Promise.all([adminPromise, refundPromise]);
      expect(adminResponse.statusCode).toBe(200);
      expect(refund.status).toBe("applied");
      expect(refundSettledBeforeAdmin).toBe(false);
      expect((await billingUsers.getTier(db, uid)).tier).toBe("free");
      expect(await redis.get(`user:${uid}:tier`)).toBeNull();
      expect(fake.users.get(uid)?.max_budget).toBe(10);
    } finally {
      await apps.adminApp.close();
      await apps.publicApp.close();
      await db.$client.unsafe(`
        DROP TRIGGER IF EXISTS ${fn}_trigger ON users;
        DROP FUNCTION IF EXISTS ${fn}();
      `);
    }
  }, 15_000);

  it("rejects an admin writer superseded before account-lock acquisition without writing paid state", async () => {
    const real = productionService(productionDeps());
    await real.apply(event());
    let reserved!: () => void;
    let release!: () => void;
    const reservedPromise = new Promise<void>((resolve) => { reserved = resolve; });
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const adminRedis = Object.create(redis) as Redis;
    const baseEval = redis.eval.bind(redis);
    let pauseReservation = true;
    adminRedis.eval = (async (...args: unknown[]) => {
      const result = await Reflect.apply(baseEval, redis, args) as unknown;
      if (pauseReservation) {
        pauseReservation = false;
        reserved();
        await gate;
      }
      return result;
    }) as Redis["eval"];
    const apps = buildMintApps({ ...productionDeps(), redis: adminRedis });
    try {
      const adminPromise = apps.adminApp.inject({
        method: "POST",
        url: "/admin/set-tier",
        headers: { authorization: "Bearer sk-admin-test" },
        payload: { uid, tier: "pro" },
      });
      await reservedPromise;
      const refund = await real.apply(event({ type: "REFUND", occurredAt: NOW + 20 }));
      expect(refund.status).toBe("applied");
      release();
      const adminResponse = await adminPromise;
      expect(adminResponse.statusCode).toBe(500);
      expect((await billingUsers.getTier(db, uid)).tier).toBe("free");
      expect(await redis.get(`user:${uid}:tier`)).toBeNull();
      expect(fake.users.get(uid)?.max_budget).toBe(10);
    } finally {
      release();
      await apps.adminApp.close();
      await apps.publicApp.close();
    }
  }, 15_000);

  for (const phase of [
    "before-send",
    "before-accept",
    "after-accept-before-response",
    "after-readback-before-completion",
  ] as const) {
    it(`recovers a fresh service after crash ${phase} without an unnecessary resend`, async () => {
      const base = createLiteLlmAdmin(fake.baseUrl, MASTER_KEY);
      await productionService(productionDeps(base)).apply(event());
      const paidBudget = fake.users.get(uid)!.max_budget!;
      const initialPosts = fake.posts("/user/update").length;
      let crashUserUpdate = false;
      let failReadback = false;
      const fetchImpl: typeof fetch = async (input, init) => {
        const response = await fetch(input, init);
        const url = new URL(input instanceof Request ? input.url : String(input));
        const method = init?.method ?? (input instanceof Request ? input.method : "GET");
        if (failReadback && method === "GET" && url.pathname === "/user/info" &&
            url.searchParams.get("user_id") === uid) {
          failReadback = false;
          await response.clone().json();
          throw new Error("process stopped after readback before completion");
        }
        return response;
      };

      if (phase === "before-accept") {
        fake.beforeHandle = ({ path, body, response }) => {
          if (path === "/user/update" && body.user_id === uid && body.max_budget === 10) {
            response.socket?.destroy();
            return true;
          }
          return false;
        };
      } else if (phase === "after-accept-before-response") {
        fake.beforeResponse = ({ path, body, response }) => {
          if (path === "/user/update" && body.user_id === uid && body.max_budget === 10) {
            response.socket?.destroy();
            return true;
          }
          return false;
        };
      } else if (phase === "after-readback-before-completion") {
        failReadback = true;
      } else {
        crashUserUpdate = true;
      }

      const crashingDeps = productionDeps({
        ...base,
        userUpdate: async (body) => {
          if (crashUserUpdate && body.user_id === uid && body.max_budget === 10) {
            crashUserUpdate = false;
            throw new Error("process stopped before send");
          }
          return base.userUpdate(body);
        },
      }, fetchImpl);
      const refund = event({ type: "REFUND", occurredAt: NOW + 20 });
      await expect(productionService(crashingDeps).apply(refund)).rejects.toThrow(/projection|unresolved/i);
      expect(await markerStatus(`revenuecat:event:${refund.id}`)).toBe("pending");
      expect(await billingUsers.getPendingRemoteOperation(db, uid)).toMatchObject({
        generation: expect.any(Number),
        kind: "user",
        maxBudget: 10,
      });
      expect(await redis.get(`user:${uid}:billing_entitlement`)).toBeNull();
      if (phase === "before-send" || phase === "before-accept") {
        expect(fake.users.get(uid)?.max_budget).toBe(paidBudget);
      } else {
        expect(fake.users.get(uid)?.max_budget).toBe(10);
      }

      const resetAfterCrash = fake.users.get(uid)?.budget_reset_at;
      fake.beforeHandle = undefined;
      fake.beforeResponse = undefined;
      const fresh = productionService(productionDeps());
      const recovered = await fresh.apply(refund);
      expect(recovered.status).toBe("recovered");
      expect(recovered.entitlement).toMatchObject({ tier: "free", purchaseState: "refunded" });
      expect(fake.users.get(uid)?.max_budget).toBe(10);
      // The initial purchase and any crashed HTTP request remain in the log;
      // recovery adds one POST only when the pending mutation was never accepted.
      const expectedPosts = initialPosts + 1 + (phase === "before-accept" ? 1 : 0);
      expect(fake.posts("/user/update")).toHaveLength(expectedPosts);
      if (phase === "after-accept-before-response" || phase === "after-readback-before-completion") {
        expect(fake.users.get(uid)?.budget_reset_at).toBe(resetAfterCrash);
      }
      expect(await markerStatus(`revenuecat:remote:${uid}`)).toBe("replaced");
      expect(await markerStatus(`revenuecat:event:${refund.id}`)).toBe("replaced");
    }, 15_000);
  }

  it("reconciles multiple keys after a real disconnect and failed readback without duplicate clock resets", async () => {
    await redis.set(`user:${uid}:keyid`, "tok-android");
    await redis.set(`user:${uid}:web:keyid`, "tok-web");
    fake.addKey("tok-android", {
      max_budget: 0,
      budget_duration: "1h",
      budget_reset_at: "2027-01-01T00:00:00.000Z",
    });
    fake.addKey("tok-web", { max_budget: 0, budget_duration: "1h" });
    fake.users.set(uid, { spend: 0, budget_duration: "24h" });
    let disconnect = true;
    fake.beforeResponse = ({ path, body, response }) => {
      if (disconnect && path === "/key/update" && body.key === "tok-android") {
        disconnect = false;
        response.socket?.destroy();
        return true;
      }
      return false;
    };

    const purchase = event();
    await expect(productionService(productionDeps()).apply(purchase)).rejects.toThrow(/projection|unresolved/i);
    expect(fake.posts("/key/update").filter((body) => body.key === "tok-android")).toHaveLength(1);
    expect(fake.posts("/key/update").filter((body) => body.key === "tok-web")).toHaveLength(0);
    expect(fake.posts("/user/update")).toHaveLength(0);
    const resetAfterAccept = fake.keys.get("tok-android")!.budget_reset_at;
    expect(resetAfterAccept).not.toBe("2027-01-01T00:00:00.000Z");

    fake.failKeyInfo = true;
    await expect(productionService(productionDeps()).apply(purchase)).rejects.toThrow(/projection|unresolved/i);
    expect(fake.posts("/key/update").filter((body) => body.key === "tok-android")).toHaveLength(1);
    expect(await markerStatus(`revenuecat:event:${purchase.id}`)).toBe("pending");

    fake.failKeyInfo = false;
    const recovered = await productionService(productionDeps()).apply(purchase);
    expect(recovered.status).toBe("recovered");
    expect(fake.posts("/key/update").filter((body) => body.key === "tok-android")).toHaveLength(1);
    expect(fake.posts("/key/update").filter((body) => body.key === "tok-web")).toHaveLength(1);
    expect(fake.posts("/user/update")).toHaveLength(1);
    expect(fake.keys.get("tok-android")!.budget_reset_at).toBe(resetAfterAccept);
    for (const token of ["tok-android", "tok-web"]) {
      expect(fake.keys.get(token)).toMatchObject({
        max_budget: 0.75,
        budget_duration: "24h",
        rpm_limit: 240,
        tpm_limit: 4_000_000,
        max_parallel_requests: 16,
      });
    }
    expect(await markerStatus(`revenuecat:remote:${uid}`)).toBe("replaced");
  }, 15_000);

  it("finishes delayed key application on a fresh retry without resending or restarting the window", async () => {
    await redis.set(`user:${uid}:keyid`, "tok-delayed");
    fake.addKey("tok-delayed", {
      max_budget: 0,
      budget_duration: "24h",
      budget_reset_at: "2027-02-03T04:05:06.000Z",
    });
    fake.users.set(uid, { spend: 0, budget_duration: "24h" });
    const intendedReset = "2027-03-04T05:06:07.000Z";
    let delayFirstApply = true;
    let applied!: () => void;
    const appliedPromise = new Promise<void>((resolve) => { applied = resolve; });
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    let readCount = 0;
    fake.beforeHandle = async ({ path, params, response }) => {
      if (delayFirstApply && path === "/key/info" && params.key === "tok-delayed") {
        readCount += 1;
        if (readCount === 2) {
          // Let the successful POST's immediate readback see the old budget.
          // The accepted mutation becomes visible only after that read returns.
          response.on("finish", () => {
            void gate.then(() => {
              const key = fake.keys.get("tok-delayed")!;
              key.max_budget = 0.75;
              key.rpm_limit = 240;
              key.tpm_limit = 4_000_000;
              key.max_parallel_requests = 16;
              key.budget_reset_at = intendedReset;
              applied();
            });
          });
        }
      }
      return false;
    };
    fake.beforeResponse = ({ path, body }) => {
      if (delayFirstApply && path === "/key/update" && body.key === "tok-delayed") {
        const key = fake.keys.get("tok-delayed")!;
        key.max_budget = 0;
        key.budget_reset_at = "2027-02-03T04:05:06.000Z";
      }
      return false;
    };

    const purchase = event();
    const first = await productionService(productionDeps()).apply(purchase).then(
      () => "resolved" as const,
      () => "rejected" as const,
    );
    expect(first).toBe("rejected");
    expect(fake.posts("/key/update")).toHaveLength(1);
    expect(await markerStatus(`revenuecat:remote:${uid}`)).toBe("pending");
    release();
    await appliedPromise;

    delayFirstApply = false;
    fake.beforeHandle = undefined;
    fake.beforeResponse = undefined;
    const recovered = await productionService(productionDeps()).apply(purchase);
    expect(recovered.status).toBe("recovered");
    expect(fake.posts("/key/update").filter((body) => body.key === "tok-delayed")).toHaveLength(1);
    expect(fake.keys.get("tok-delayed")).toMatchObject({
      max_budget: 0.75,
      rpm_limit: 240,
      tpm_limit: 4_000_000,
      max_parallel_requests: 16,
      budget_reset_at: intendedReset,
    });
  }, 15_000);

  it("does not acknowledge a key mutation when the remote drops a required rate-limit field", async () => {
    await redis.set(`user:${uid}:keyid`, "tok-stale-rates");
    fake.addKey("tok-stale-rates");
    fake.users.set(uid, { spend: 0, budget_duration: "24h" });
    let dropTpm = true;
    fake.beforeHandle = ({ path, body }) => {
      if (dropTpm && path === "/key/update" && body.key === "tok-stale-rates") {
        delete body.tpm_limit;
      }
      return false;
    };
    const purchase = event();
    await expect(productionService(productionDeps()).apply(purchase)).rejects.toThrow(/projection|unresolved/i);
    expect(await markerStatus(`revenuecat:event:${purchase.id}`)).toBe("pending");
    expect(fake.keys.get("tok-stale-rates")!.tpm_limit).toBeNull();

    dropTpm = false;
    fake.beforeHandle = undefined;
    const recovered = await productionService(productionDeps()).apply(purchase);
    expect(recovered.status).toBe("recovered");
    expect(fake.posts("/key/update").filter((body) => body.key === "tok-stale-rates")).toHaveLength(2);
    expect(fake.keys.get("tok-stale-rates")).toMatchObject({
      rpm_limit: 240,
      tpm_limit: 4_000_000,
      max_parallel_requests: 16,
    });
  });

  it("uses only the newer Free repair after an older paid intent is already verified", async () => {
    const base = createLiteLlmAdmin(fake.baseUrl, MASTER_KEY);
    const real = productionService(productionDeps(base));
    await real.apply(event());
    const paidBudget = fake.users.get(uid)!.max_budget!;
    const paidReset = fake.users.get(uid)!.budget_reset_at;
    fake.beforeResponse = ({ path, body, response }) => {
      if (path === "/user/update" && body.max_budget === paidBudget) {
        response.socket?.destroy();
        return true;
      }
      return false;
    };
    await expect(real.refresh(uid)).rejects.toThrow(/projection|unresolved/i);
    expect(fake.users.get(uid)?.max_budget).toBe(paidBudget);
    fake.beforeResponse = undefined;

    const refund = await real.apply(event({ type: "REFUND", occurredAt: NOW + 20 }));
    expect(refund.status).toBe("applied");
    const posts = fake.posts("/user/update");
    expect(posts.filter((body) => body.max_budget === paidBudget)).toHaveLength(2);
    expect(posts.filter((body) => body.max_budget === 10)).toHaveLength(1);
    expect(posts.at(-1)).toMatchObject({ max_budget: 10, budget_duration: "30d" });
    expect(fake.users.get(uid)?.max_budget).toBe(10);
    expect(paidReset).not.toBeNull();
  });

  it("recovers the existing-key mint mutation with metadata and rate limits intact", async () => {
    await redis.set(`user:${uid}:tier`, "plus");
    await redis.set(`user:${uid}:keyid`, "tok-existing-mint");
    await redis.set(`user:${uid}:key`, "sk-existing-mint");
    fake.addKey("tok-existing-mint", {
      max_budget: 0,
      budget_duration: "24h",
      rpm_limit: 240,
      tpm_limit: 4_000_000,
      max_parallel_requests: 16,
    });
    fake.users.set(uid, { spend: 0, budget_duration: "24h" });
    fake.beforeResponse = ({ path, response }) => {
      if (path === "/key/update") {
        response.socket?.destroy();
        return true;
      }
      return false;
    };
    await expect(litellmMintOrGet(productionDeps(), uid, "plus", "android"))
      .rejects.toThrow(/unresolved/i);
    expect(await billingUsers.getPendingRemoteOperation(db, uid)).toMatchObject({
      kind: "key",
      maxBudget: 0.75,
      rpmLimit: 240,
      tpmLimit: 4_000_000,
      maxParallelRequests: 16,
      extra: {
        user_id: uid,
        metadata: { tier: "plus", ovid_uid: uid, platform: "android" },
      },
    });
    fake.beforeResponse = undefined;
    await expect(litellmMintOrGet(productionDeps(), uid, "plus", "android"))
      .resolves.toBe("sk-existing-mint");
    expect(fake.posts("/key/update")).toHaveLength(1);
    expect(fake.keys.get("tok-existing-mint")).toMatchObject({
      max_budget: 0.75,
      rpm_limit: 240,
      tpm_limit: 4_000_000,
      max_parallel_requests: 16,
      metadata: { tier: "plus", ovid_uid: uid, platform: "android" },
    });
  });

  it("gives direct compatibility user-budget writes durable recovery", async () => {
    fake.users.set(uid, { spend: 0, budget_duration: "30d" });
    fake.beforeHandle = ({ path, response }) => {
      if (path === "/user/update") {
        response.socket?.destroy();
        return true;
      }
      return false;
    };
    const deps = productionDeps();
    await expect(ensureUserBudget(deps, uid, "free", false, null)).rejects.toThrow(/unresolved/i);
    expect(await billingUsers.getPendingRemoteOperation(db, uid)).toMatchObject({
      kind: "user",
      maxBudget: 10,
    });
    fake.beforeHandle = undefined;
    await ensureUserBudget(productionDeps(), uid, "free", false, null);
    expect(fake.users.get(uid)?.max_budget).toBe(10);
    expect(fake.posts("/user/update")).toHaveLength(2);
    expect(await markerStatus(`revenuecat:remote:${uid}`)).toBe("replaced");
  });

  it("gives rate-only key writers the same durable intent and verified retry", async () => {
    await redis.set(`user:${uid}:keyid`, "tok-rates");
    fake.addKey("tok-rates");
    fake.beforeResponse = ({ path, response }) => {
      if (path === "/key/update") {
        response.socket?.destroy();
        return true;
      }
      return false;
    };
    await poolPushRateLimits(productionDeps(), uid);
    expect(await billingUsers.getPendingRemoteOperation(db, uid)).toMatchObject({
      kind: "key",
      rpmLimit: 240,
      tpmLimit: 4_000_000,
      maxParallelRequests: 16,
    });
    fake.beforeResponse = undefined;
    await poolPushRateLimits(productionDeps(), uid);
    expect(fake.posts("/key/update")).toHaveLength(1);
    expect(fake.keys.get("tok-rates")).toMatchObject({
      rpm_limit: 240,
      tpm_limit: 4_000_000,
      max_parallel_requests: 16,
    });
    expect(await markerStatus(`revenuecat:remote:${uid}`)).toBe("replaced");
  });

  it("recovers an unversioned window-reset intent through a fresh entitlement wrapper", async () => {
    await redis.set(`user:${uid}:keyid`, "tok-reset");
    fake.addKey("tok-reset");
    fake.users.set(uid, { spend: 4, budget_duration: "30d" });
    fake.beforeHandle = ({ path, body, response }) => {
      if (path === "/user/update" && body.user_id === uid) {
        response.socket?.destroy();
        return true;
      }
      return false;
    };
    const deps = productionDeps();
    const interrupted = await resetWindowUser(deps, uid, { resetMonthFree: true, operationId: "remote-recovery-reset" });
    expect(interrupted.errors).toBe(1);
    expect(await billingUsers.getPendingRemoteOperation(db, uid)).toMatchObject({
      kind: "user",
      maxBudget: 10,
      spend: 0,
      budgetDuration: "30d",
    });

    fake.beforeHandle = undefined;
    const recovered = await productionService(productionDeps()).refresh(uid);
    expect(recovered.tier).toBe("free");
    expect(fake.users.get(uid)).toMatchObject({ max_budget: 10, spend: 0, budget_duration: "30d" });
    expect(fake.keys.get("tok-reset")).toMatchObject({ max_budget: 0.15, spend: 0 });
    expect(await markerStatus(`revenuecat:remote:${uid}`)).toBe("replaced");
  }, 15_000);
});
