import {
  billingUsers,
  type BillingPurchaseState,
  type Db,
  type PurchaseRow,
  type RevenueCatApplyResult,
  type RevenueCatEventWrite,
  type RevenueCatRefreshSnapshot,
  type RevenueCatTransferWrite,
} from "@ovid/db";
import { planFor, tierRank, type PlanTier } from "@ovid/shared";
import type { Redis } from "ioredis";
import { BillingError } from "./domain.js";
import { BILLING_PRODUCTS, type BillingPeriod } from "./products.js";
import {
  reserveBillingProjectionGeneration,
  type TierSink,
} from "./tierSink.js";
import { BILLING_REFRESH_GENERATION_KEY, withBillingAccountLock } from "../windows.js";

export interface BillingEntitlement {
  tier: PlanTier;
  productId: string | null;
  period: BillingPeriod | null;
  expiresAt: number | null;
  autoRenewing: boolean;
  purchaseState: BillingPurchaseState;
}

/** Only authenticated RevenueCat webhook parsing may construct this input. */
export interface RevenueCatEvent {
  id: string;
  type: string;
  occurredAt: number;
  appUserId: string;
  transactionId: string | null;
  productId: string | null;
  expiresAt: number | null;
  autoRenewing: boolean | null;
  cancelReason: string | null;
  environment: string | null;
  transferredFrom?: string[];
  newProductId?: string | null;
  gracePeriodExpiresAt?: number | null;
}

export interface EntitlementApplyResult {
  status: RevenueCatApplyResult["status"] | "ignored" | "recovered" | "deferred";
  entitlement: BillingEntitlement;
}

export interface EntitlementStore {
  listPurchases(db: Db, uid: string): Promise<PurchaseRow[]>;
  getPurchase(db: Db, transactionId: string): Promise<PurchaseRow | null>;
  applyRevenueCatEvent(db: Db, input: RevenueCatEventWrite): Promise<RevenueCatApplyResult>;
  transferRevenueCatEvent(db: Db, input: RevenueCatTransferWrite): Promise<RevenueCatApplyResult>;
  markRevenueCatEventProjected(db: Db, eventId: string): Promise<void>;
  beginRefresh(db: Db, uid: string, recoveryId?: string): Promise<RevenueCatRefreshSnapshot>;
  isLatestRefresh(db: Db, uid: string, generation: number): Promise<boolean>;
}

export interface EntitlementServiceDeps {
  db: Db;
  redis: Redis;
  clock?: () => number;
  /** The existing users/Redis-tier/LiteLLM sink; invoked only by this service. */
  setTier: TierSink;
  store?: EntitlementStore;
}

export interface EntitlementService {
  entitlement(uid: string): Promise<BillingEntitlement>;
  refresh(uid: string, recoveryId?: string): Promise<BillingEntitlement>;
  apply(event: RevenueCatEvent): Promise<EntitlementApplyResult>;
}

const HANDLED_EVENTS = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "SUBSCRIPTION_EXTENDED",
  "UPGRADE",
  "DOWNGRADE",
  "PRODUCT_CHANGE",
  "NON_RENEWING_PURCHASE",
  "UNCANCELLATION",
  "RESTORE",
  "BILLING_ISSUE",
  "REFUND_REVERSED",
  "CANCELLATION",
  "EXPIRATION",
  "REFUND",
  "PENDING",
  "TRANSFER",
]);
const EVENT_TIME_PREFIX = "rc-event-at:";
const MAX_REFRESH_GENERATIONS = 16;

function emptyEntitlement(): BillingEntitlement {
  return {
    tier: "free",
    productId: null,
    period: null,
    expiresAt: null,
    autoRenewing: false,
    purchaseState: "unknown",
  };
}

function productPeriod(productId: string): BillingPeriod | null {
  if (!Object.prototype.hasOwnProperty.call(BILLING_PRODUCTS, productId)) return null;
  return BILLING_PRODUCTS[productId as keyof typeof BILLING_PRODUCTS].period;
}

function purchaseVersion(row: PurchaseRow): number {
  if (row.accountHash?.startsWith(EVENT_TIME_PREFIX)) {
    const value = Number(row.accountHash.slice(EVENT_TIME_PREFIX.length));
    if (Number.isFinite(value)) return value;
  }
  return row.updatedAt;
}

/** Derive the public value from durable server fields, never from Redis or client text. */
function fromPurchase(row: PurchaseRow, now: number): BillingEntitlement {
  const expiresAt = row.expiresAt ?? null;
  const productId = row.productId || null;
  const period = productId === null ? null : productPeriod(productId);
  let purchaseState: BillingPurchaseState;
  switch (row.status) {
    case "active":
      purchaseState = !row.token.startsWith("revenuecat:") && !row.autoRenewing
        ? "cancelled"
        : "active";
      break;
    case "cancelled":
      purchaseState = "cancelled";
      break;
    case "pending":
      purchaseState = "pending";
      break;
    case "revoked":
    case "refunded":
      purchaseState = "refunded";
      break;
    case "expired":
      purchaseState = "expired";
      break;
    default:
      purchaseState = "unknown";
  }

  const canHaveAccess = purchaseState === "active" || purchaseState === "cancelled";
  if (canHaveAccess && (expiresAt === null || expiresAt <= now)) {
    purchaseState = "expired";
  }
  const entitled = purchaseState === "active" || purchaseState === "cancelled";
  return {
    tier: entitled ? planFor(row.tier).id : "free",
    productId,
    period,
    expiresAt,
    autoRenewing: entitled && purchaseState === "active" && row.autoRenewing,
    purchaseState,
  };
}

function bestPurchase(rows: PurchaseRow[], now: number): BillingEntitlement {
  const values = rows.map((row) => ({ row, value: fromPurchase(row, now) }));
  const active = values
    .filter(({ value }) => value.tier !== "free")
    .sort((a, b) => {
      const rank = tierRank(b.value.tier) - tierRank(a.value.tier);
      if (rank !== 0) return rank;
      return (b.value.expiresAt ?? 0) - (a.value.expiresAt ?? 0);
    });
  if (active.length > 0) return active[0]!.value;
  if (values.length === 0) return emptyEntitlement();
  values.sort((a, b) => purchaseVersion(a.row) - purchaseVersion(b.row));
  return values.at(-1)!.value;
}

function eventPurchaseState(
  event: RevenueCatEvent,
  existing: PurchaseRow | null,
  expiresAt: number | null,
  now: number,
): BillingPurchaseState {
  if (event.type === "REFUND" ||
      (event.type === "CANCELLATION" && event.cancelReason === "CUSTOMER_SUPPORT")) {
    return "refunded";
  }
  if (event.type === "EXPIRATION") return "expired";
  if (event.type === "PENDING") return "pending";
  if (event.type === "CANCELLATION") {
    return expiresAt !== null && expiresAt > now ? "cancelled" : "expired";
  }
  if (event.type === "TRANSFER" && existing !== null) {
    if (existing.status === "revoked" || existing.status === "refunded") return "refunded";
    if (existing.status === "cancelled") {
      return expiresAt !== null && expiresAt > now ? "cancelled" : "expired";
    }
    if (existing.status === "expired") return "expired";
  }
  // REFUND_REVERSED deliberately reaches here: a future verified expiry
  // reactivates; an already-past expiry remains expiration-derived Free.
  return expiresAt !== null && expiresAt > now ? "active" : "expired";
}

async function writeEntitlementCache(
  redis: Redis,
  uid: string,
  value: BillingEntitlement,
  generation: number,
): Promise<boolean> {
  const serialized = JSON.stringify(value);
  if (typeof redis.eval === "function") {
    const result = await redis.eval(
      `if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
       redis.call('SET', KEYS[2], ARGV[2])
       return 1`,
      2,
      BILLING_REFRESH_GENERATION_KEY(uid),
      `user:${uid}:billing_entitlement`,
      String(generation),
      serialized,
    );
    return Number(result) === 1;
  }
  const current = await redis.get?.(BILLING_REFRESH_GENERATION_KEY(uid));
  if (current !== undefined && current !== null && current !== String(generation)) return false;
  await redis.set(`user:${uid}:billing_entitlement`, serialized);
  return true;
}

async function clearEntitlementCache(
  redis: Redis,
  uid: string,
  generation: number,
): Promise<void> {
  if (typeof redis.eval === "function") {
    await redis.eval(
      `if redis.call('GET', KEYS[1]) == ARGV[1] then redis.call('DEL', KEYS[2]) end
       return 1`,
      2,
      BILLING_REFRESH_GENERATION_KEY(uid),
      `user:${uid}:billing_entitlement`,
      String(generation),
    );
    return;
  }
  const current = await redis.get?.(BILLING_REFRESH_GENERATION_KEY(uid));
  if (current !== undefined && current !== null && current !== String(generation)) return;
  await redis.del?.(`user:${uid}:billing_entitlement`);
}

export function createEntitlementService(deps: EntitlementServiceDeps): EntitlementService {
  const clock = deps.clock ?? (() => Math.floor(Date.now() / 1000));
  const store = deps.store ?? billingUsers;

  async function entitlement(uid: string): Promise<BillingEntitlement> {
    if (uid === "") return emptyEntitlement();
    return bestPurchase(await store.listPurchases(deps.db, uid), Math.trunc(clock()));
  }

  /**
   * Latest-refresh-wins projection. A blocked older writer can finish a side
   * effect, but its generation check then forces a fresh snapshot and repair
   * before it may return. Newer refreshes never wait on that network call.
   */
  async function refresh(uid: string, recoveryId?: string): Promise<BillingEntitlement> {
    if (uid === "") return emptyEntitlement();
    return withBillingAccountLock(deps.db, uid, async () => {
      for (let attempt = 0; attempt < MAX_REFRESH_GENERATIONS; attempt++) {
        // Allocation happens only after the account lock. No competing refresh
        // can allocate a newer generation midway through these side effects.
        const snapshot = await store.beginRefresh(deps.db, uid, recoveryId);
        const current = bestPurchase(snapshot.rows, Math.trunc(clock()));
        try {
          if (!(await store.isLatestRefresh(deps.db, uid, snapshot.generation))) continue;
          if (!(await reserveBillingProjectionGeneration(deps.redis, uid, snapshot.generation))) continue;
          await deps.setTier(
            uid,
            current.tier,
            current.tier === "free" ? null : current.expiresAt,
            snapshot.generation,
          );
          if (!(await store.isLatestRefresh(deps.db, uid, snapshot.generation))) continue;
          if (!(await writeEntitlementCache(deps.redis, uid, current, snapshot.generation))) continue;
          if (await store.isLatestRefresh(deps.db, uid, snapshot.generation)) return current;
        } catch (error) {
          if (!(await store.isLatestRefresh(deps.db, uid, snapshot.generation))) continue;
          // A failed current repair must not leave a stale paid entitlement readable.
          await clearEntitlementCache(deps.redis, uid, snapshot.generation);
          throw error;
        }
      }
      throw new BillingError(503, "billing_projection_retry");
    });
  }

  async function finish(
    event: RevenueCatEvent,
    result: RevenueCatApplyResult,
  ): Promise<EntitlementApplyResult> {
    const ownerUid = result.ownerUid ?? event.appUserId;
    if (result.status === "stale") {
      // A first stale delivery changes no authority and stays a projection no-op.
      // Its later replay still takes the normal verify/repair path below.
      await store.markRevenueCatEventProjected(deps.db, event.id);
      return { status: "stale", entitlement: await entitlement(ownerUid) };
    }
    const current = await refresh(ownerUid, event.id);
    for (const previousUid of new Set(result.previousUids)) {
      if (previousUid !== ownerUid) await refresh(previousUid, event.id);
    }
    await store.markRevenueCatEventProjected(deps.db, event.id);
    const status = result.status === "replayed" && result.projectionPending
      ? "recovered"
      : result.status;
    return { status, entitlement: current };
  }

  async function apply(event: RevenueCatEvent): Promise<EntitlementApplyResult> {
    // Explicit production-only policy: SANDBOX and missing/unknown environment
    // never write a purchase, marker, users row, Redis key, or LiteLLM budget.
    if (event.environment !== "PRODUCTION" || !HANDLED_EVENTS.has(event.type)) {
      return { status: "ignored", entitlement: await entitlement(event.appUserId) };
    }

    if (event.type === "TRANSFER" && event.transferredFrom !== undefined) {
      if (event.transferredFrom.length === 0) throw new BillingError(400, "invalid_event");
      const result = await store.transferRevenueCatEvent(deps.db, {
        eventId: event.id,
        fromUids: event.transferredFrom,
        toUid: event.appUserId,
        occurredAt: event.occurredAt,
      });
      return finish(event, result);
    }

    if (event.transactionId === null || event.transactionId === "") {
      throw new BillingError(400, "invalid_event");
    }
    const existing = await store.getPurchase(deps.db, event.transactionId);

    // A new_product_id is an upcoming change, not current access. Immediate
    // changes arrive with the accompanying RENEWAL/INITIAL_PURCHASE event.
    if (event.type === "PRODUCT_CHANGE" && typeof event.newProductId === "string") {
      return { status: "deferred", entitlement: await entitlement(event.appUserId) };
    }

    const productId = event.productId ?? existing?.productId ?? null;
    if (productId === null || !Object.prototype.hasOwnProperty.call(BILLING_PRODUCTS, productId)) {
      throw new BillingError(400, "unknown_product");
    }
    const product = BILLING_PRODUCTS[productId as keyof typeof BILLING_PRODUCTS];
    const now = Math.trunc(clock());
    let expiresAt = event.expiresAt ?? existing?.expiresAt ?? null;
    if (event.type === "BILLING_ISSUE") {
      expiresAt = event.gracePeriodExpiresAt ?? event.expiresAt ?? existing?.expiresAt ?? null;
    } else if (event.type === "CANCELLATION" && event.cancelReason === "BILLING_ERROR") {
      expiresAt = Math.max(expiresAt ?? 0, existing?.expiresAt ?? 0) || null;
    }
    const purchaseState = eventPurchaseState(event, existing, expiresAt, now);
    const entitled = purchaseState === "active" || purchaseState === "cancelled";
    // The durable field retains the last server-verified store preference so
    // refund reversal/lapsed renewal can restore it. Public projection masks
    // it unless the current purchase state is active (fromPurchase).
    const autoRenewing = purchaseState === "pending" ||
        (purchaseState === "cancelled" && event.cancelReason !== "BILLING_ERROR")
      ? false
      : event.autoRenewing ?? existing?.autoRenewing ?? false;

    const result = await store.applyRevenueCatEvent(deps.db, {
      eventId: event.id,
      transactionId: event.transactionId,
      uid: event.appUserId,
      occurredAt: event.occurredAt,
      entitlement: {
        tier: entitled ? product.tier : "free",
        productId,
        expiresAt,
        autoRenewing,
        purchaseState,
      },
    });
    return finish(event, result);
  }

  return { entitlement, refresh, apply };
}
