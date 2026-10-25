import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate, type Db } from "./client.js";
import {
  billingUsers,
  type RevenueCatEntitlementWrite,
} from "./billingRepos.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const NOW = 1_800_000_000;
const RUN_ID = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
let sequence = 0;

function entitlement(overrides: Partial<RevenueCatEntitlementWrite> = {}): RevenueCatEntitlementWrite {
  return {
    tier: "plus",
    productId: "ovid_pro_yearly",
    expiresAt: NOW + 365 * 86_400,
    autoRenewing: true,
    purchaseState: "active",
    ...overrides,
  };
}

describe.skipIf(!TEST_DATABASE_URL)("billingUsers RevenueCat authority (isolated test Postgres)", () => {
  let db: Db;

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  function input(overrides: Record<string, unknown> = {}) {
    sequence += 1;
    return {
      eventId: `repo-event-${RUN_ID}-${sequence}`,
      transactionId: `repo-transaction-${RUN_ID}-${sequence}`,
      uid: `repo-user-${RUN_ID}-${sequence}`,
      occurredAt: NOW + sequence,
      entitlement: entitlement(),
      ...overrides,
    };
  }

  it("claims an event ID globally, so a replay cannot mutate another transaction", async () => {
    const first = input();
    expect((await billingUsers.applyRevenueCatEvent(db, first)).status).toBe("applied");
    const replay = await billingUsers.applyRevenueCatEvent(db, {
      ...first,
      transactionId: `${first.transactionId}-forged`,
      entitlement: entitlement({ tier: "pro", productId: "ovid_max_yearly" }),
    });
    expect(replay.status).toBe("replayed");
    expect(await billingUsers.getPurchase(db, `${first.transactionId}-forged`)).toBeNull();
  });

  it("rejects a stale event without changing verified product/state/expiry", async () => {
    const first = input({ occurredAt: NOW + 100 });
    await billingUsers.applyRevenueCatEvent(db, first);
    const stale = await billingUsers.applyRevenueCatEvent(db, {
      ...first,
      eventId: `${first.eventId}-stale`,
      occurredAt: NOW + 99,
      entitlement: entitlement({ purchaseState: "refunded", tier: "free", autoRenewing: false }),
    });
    expect(stale.status).toBe("stale");
    expect(await billingUsers.getPurchase(db, first.transactionId)).toMatchObject({
      uid: first.uid,
      tier: "plus",
      status: "active",
      productId: "ovid_pro_yearly",
      autoRenewing: true,
      updatedAt: NOW + 100,
    });
  });

  it("rebinds an existing transaction only through the server event writer", async () => {
    const first = input();
    await billingUsers.applyRevenueCatEvent(db, first);
    const switched = await billingUsers.applyRevenueCatEvent(db, {
      ...first,
      eventId: `${first.eventId}-switch`,
      uid: `${first.uid}-new`,
      occurredAt: first.occurredAt + 1,
    });
    expect(switched).toMatchObject({ status: "applied", previousUid: first.uid });
    expect(await billingUsers.getPurchase(db, first.transactionId)).toMatchObject({
      uid: `${first.uid}-new`,
      tier: "plus",
    });
    expect(await billingUsers.listPurchases(db, first.uid)).toEqual([]);
    expect(await billingUsers.listPurchases(db, `${first.uid}-new`)).toHaveLength(1);

    const replayInput = {
      ...first,
      eventId: `${first.eventId}-switch`,
      uid: `${first.uid}-new`,
      occurredAt: first.occurredAt + 1,
    };
    const replay = await billingUsers.applyRevenueCatEvent(db, replayInput);
    expect(replay).toMatchObject({
      status: "replayed",
      previousUid: first.uid,
      projectionPending: true,
    });
  });

  it("retains every acknowledged key mutation field in a durable pending intent", async () => {
    const uid = `remote-fields-${RUN_ID}`;
    const { generation } = await billingUsers.beginRefresh(db, uid);
    const operation = {
      uid,
      generation,
      kind: "key" as const,
      target: "hashed-key-1",
      maxBudget: 0.75,
      budgetDuration: "24h",
      spend: 0,
      rpmLimit: 240,
      tpmLimit: 4_000_000,
      maxParallelRequests: 16,
      extra: {
        user_id: uid,
        metadata: { tier: "plus", platform: "android" },
        models: ["auto", "ovid-image"],
        team_id: "team-web",
      },
    };
    expect(await billingUsers.beginRemoteOperation(db, operation)).toBe(true);
    expect(await billingUsers.getPendingRemoteOperation(db, operation.uid)).toMatchObject(operation);
  });

  it("serializes concurrent first events so a newer refund wins an older active insert", async () => {
    const first = input({
      transactionId: `concurrent-${RUN_ID}`,
      occurredAt: NOW + 100,
    });
    const newer = {
      ...first,
      eventId: `${first.eventId}-newer-refund`,
      occurredAt: NOW + 200,
      entitlement: entitlement({ tier: "free", purchaseState: "refunded", autoRenewing: false }),
    };
    const fn = `task4_pause_active_${Date.now()}_${process.pid}`;
    const token = `revenuecat:purchase:${first.transactionId}`;
    await db.$client.unsafe(`
      CREATE OR REPLACE FUNCTION ${fn}() RETURNS trigger AS $$
      BEGIN
        IF NEW.status = 'active' THEN PERFORM pg_sleep(0.3); END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER ${fn}_trigger BEFORE INSERT ON billing_purchases
      FOR EACH ROW WHEN (NEW.token = '${token}')
      EXECUTE FUNCTION ${fn}();
    `);
    const secondDb = createDb(TEST_DATABASE_URL!);
    try {
      const olderPromise = billingUsers.applyRevenueCatEvent(db, first);
      await new Promise((resolve) => setTimeout(resolve, 50));
      const newerPromise = billingUsers.applyRevenueCatEvent(secondDb, newer);
      await Promise.all([olderPromise, newerPromise]);

      expect(await billingUsers.getPurchase(db, first.transactionId)).toMatchObject({
        status: "refunded",
        tier: "free",
        autoRenewing: false,
        updatedAt: NOW + 200,
      });
    } finally {
      await secondDb.$client.end({ timeout: 5 });
      await db.$client.unsafe(`DROP TRIGGER IF EXISTS ${fn}_trigger ON billing_purchases; DROP FUNCTION IF EXISTS ${fn}()`);
    }
  });
});
