import { timingSafeEqual } from "node:crypto";
import {
  billingPurchases,
  PurchaseConflictError,
  type Db,
  type EntitlementFields,
  type PurchaseRow,
} from "@ovid/db";
import type { Redis } from "ioredis";
import { planFor } from "@ovid/shared";
import type { MintEnv } from "../env.js";
import { BillingError, evaluate } from "./domain.js";
import type { PlayDeveloperApi } from "./play.js";
import { createPlayApi } from "./play.js";
import {
  accountHash,
  BILLING_PRODUCTS,
  selectBillingProduct,
  type BillingPeriod,
} from "./products.js";
import { createTierSink, type PublishTier, type TierSink } from "./tierSink.js";
import {
  createEntitlementService,
  type BillingEntitlement,
  type EntitlementApplyResult,
  type EntitlementStore,
  type RevenueCatEvent,
} from "./entitlements.js";

/**
 * Play Billing service — port of server/billing/api.py BillingService.
 *
 * `verify` is the only path that can bind a purchase token to an account;
 * `notify` is the RTDN path. Both recompute the user's best active purchase
 * from the DURABLE Postgres ledger (billing_purchases) and push the result
 * through the tier sink. The only Google write is the best-effort
 * acknowledgement of a verified active purchase (SH-002).
 */

const MAX_TOKEN = 4096;
/** RTDN subscriptionNotification.notificationType 12 = SUBSCRIPTION_REVOKED. */
const REVOKED = 12;

export interface PurchaseLedger {
  get(token: string): Promise<PurchaseRow | null>;
  record(
    token: string,
    entitlement: EntitlementFields,
    now: number,
    uid?: string | null,
  ): Promise<PurchaseRow>;
  mark(token: string, status: "revoked" | "replaced", now: number): Promise<PurchaseRow | null>;
  effective(uid: string, now: number): Promise<PurchaseRow | null>;
}

/** Durable Postgres ledger wrapper; a cross-account race is the 409 contract. */
export function createPurchaseLedger(db: Db): PurchaseLedger {
  return {
    get: (token) => billingPurchases.get(db, token),
    async record(token, entitlement, now, uid) {
      try {
        return await billingPurchases.record(db, token, entitlement, now, uid);
      } catch (err) {
        if (err instanceof PurchaseConflictError) {
          throw new BillingError(409, "purchase_owned_by_another_account");
        }
        throw err;
      }
    },
    mark: (token, status, now) => billingPurchases.mark(db, token, status, now),
    effective: (uid, now) => billingPurchases.effective(db, uid, now),
  };
}

export interface BillingVerifyResult {
  status: number;
  payload: Record<string, unknown>;
}

export interface BillingOffering {
  productId: string;
  tier: string;
  period: BillingPeriod;
}

export interface BillingService {
  readonly configured: boolean;
  /** Play product id -> canonical or legacy tier; planCards maps plans to products. */
  readonly products: Record<string, string>;
  verify(uid: string, body: unknown): Promise<BillingVerifyResult>;
  notify(envelope: unknown): Promise<void>;
  revenueCat(event: RevenueCatEvent): Promise<EntitlementApplyResult>;
  entitlement(uid: string): Promise<BillingEntitlement>;
  offerings(): { available: boolean; products: BillingOffering[] };
  usageFields(uid: string | null): Promise<Record<string, unknown>>;
}

export interface BillingServiceDeps {
  db: Db;
  redis: Redis;
  env: MintEnv;
  verifyIdentity?: unknown;
  /** Redis projection (Task 4/5) — tier keys with EXAT expiry+600. */
  projection: PublishTier;
  /** Task 5/8 reapply path (LiteLLM budgets). Defaults to a no-op. */
  reapplyUser?: (uid: string) => Promise<unknown>;
  /** Full tier sink override (tests). Defaults to createTierSink(...). */
  setTier?: TierSink;
  store?: PurchaseLedger;
  /** Defaults to billingUsers' durable purchase/event repository. */
  entitlementStore?: EntitlementStore;
  /** Play API; `null` = billing disabled, `undefined` = build from env. */
  api?: PlayDeveloperApi | null;
  clock?: () => number;
  products?: Record<string, string>;
  requireAccountId?: boolean;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Python's `_iso`: UTC ISO-8601 with a literal Z and no fractional part. */
function iso(epoch: number | null): string | null {
  if (epoch === null || epoch === undefined) {
    return null;
  }
  return new Date(epoch * 1000).toISOString().replace(/\.000Z$/, "Z");
}

function safeEqual(a: string, b: string): boolean {
  const left = Buffer.from(a, "utf8");
  const right = Buffer.from(b, "utf8");
  return left.length === right.length && timingSafeEqual(left, right);
}

function resolveProducts(env: MintEnv, override?: Record<string, string>): Record<string, string> {
  if (override !== undefined) {
    return override;
  }
  if (env.play.products !== null) {
    return { ...env.play.products };
  }
  return Object.fromEntries(
    Object.entries(BILLING_PRODUCTS).map(([productId, product]) => [productId, product.tier]),
  );
}

function evaluateCanonical(
  resource: unknown,
  products: Record<string, string>,
  now: number,
): ReturnType<typeof evaluate> {
  const entitlement = evaluate(resource, products, now);
  return { ...entitlement, tier: planFor(entitlement.tier).id };
}

function buildApi(env: MintEnv, api: PlayDeveloperApi | null | undefined): PlayDeveloperApi | null {
  if (api !== undefined) {
    return api;
  }
  const file = env.play.serviceAccountFile;
  if (file === null) {
    return null;
  }
  return createPlayApi(env.play.packageName, file);
}

export function createBillingService(deps: BillingServiceDeps): BillingService {
  const clock = deps.clock ?? (() => Math.floor(Date.now() / 1000));
  const products = resolveProducts(deps.env, deps.products);
  const api = buildApi(deps.env, deps.api);
  const store = deps.store ?? createPurchaseLedger(deps.db);
  const requireAccountId = deps.requireAccountId ?? deps.env.play.requireAccountId;
  const setTier =
    deps.setTier ??
    createTierSink({
      db: deps.db,
      redis: deps.redis,
      projection: deps.projection,
      reapplyUser: deps.reapplyUser ?? (async () => undefined),
    });
  const configured = api !== null && store !== null;
  const entitlements = createEntitlementService({
    db: deps.db,
    redis: deps.redis,
    clock,
    setTier,
    ...(deps.entitlementStore !== undefined ? { store: deps.entitlementStore } : {}),
  });

  /** Recompute the canonical entitlement and use its one projection writer. */
  async function apply(uid: string | null): Promise<{ tier: string; current: BillingEntitlement }> {
    if (uid === null || uid === "") {
      return {
        tier: "free",
        current: {
          tier: "free",
          productId: null,
          period: null,
          expiresAt: null,
          autoRenewing: false,
          purchaseState: "unknown",
        },
      };
    }
    const current = await entitlements.refresh(uid);
    return { tier: current.tier, current };
  }

  async function verify(uid: string, body: unknown): Promise<BillingVerifyResult> {
    if (!configured) {
      throw new BillingError(503, "billing_unavailable");
    }
    if (!isRecord(body)) {
      throw new BillingError(400, "invalid_request");
    }
    const token = body.purchase_token;
    const product = body.product_id;
    const packageName =
      typeof body.package_name === "string" && body.package_name !== ""
        ? body.package_name
        : deps.env.play.packageName;
    if (
      typeof token !== "string" ||
      token === "" ||
      token.length > MAX_TOKEN ||
      typeof product !== "string"
    ) {
      throw new BillingError(400, "invalid_request");
    }
    if (packageName !== deps.env.play.packageName) {
      throw new BillingError(400, "wrong_package");
    }
    if (!Object.prototype.hasOwnProperty.call(products, product)) {
      throw new BillingError(400, "unknown_product");
    }

    const existing = await store.get(token);
    if (existing !== null && existing.uid !== null && existing.uid !== uid) {
      throw new BillingError(409, "purchase_owned_by_another_account");
    }

    const resource = await api!.getSubscription(token);
    const now = Math.trunc(clock());
    const entitlement = evaluateCanonical(resource, products, now);
    if (entitlement.account_hash === null) {
      if (requireAccountId) {
        throw new BillingError(403, "account_mismatch");
      }
    } else if (!safeEqual(entitlement.account_hash, accountHash(uid))) {
      throw new BillingError(403, "account_mismatch");
    }

    const row = await store.record(token, entitlement, now, uid);
    const { tier, current } = await apply(uid);
    const active = row.status === "active";
    if (active && !entitlement.acknowledged && api!.acknowledgeSubscription !== undefined) {
      // SH-002: acknowledge server-side too, so a client that dies between
      // this response and completePurchase cannot let Play auto-refund a
      // purchase we already granted. Best effort: the tier is set, and the
      // client acknowledges when it sees `acknowledge: true`.
      try {
        await api!.acknowledgeSubscription(row.productId, token);
      } catch (err) {
        console.log(
          `[mint] billing: server-side acknowledge failed: ${err instanceof Error ? err.name : String(err)}`,
        );
      }
    }
    const payload: Record<string, unknown> = {
      ok: active,
      status: row.status,
      tier,
      product_id: row.productId,
      expires_at: iso(current.expiresAt),
      auto_renewing: current.autoRenewing,
      // The client acknowledges (completePurchase) only when this is true.
      acknowledge: active,
    };
    return { status: row.status === "pending" ? 202 : 200, payload };
  }

  async function notify(envelope: unknown): Promise<void> {
    if (!configured) {
      throw new BillingError(503, "billing_unavailable");
    }
    // Malformed pushes are acknowledged; redelivery cannot fix them.
    if (!isRecord(envelope) || !isRecord(envelope.message)) {
      return;
    }
    const data = envelope.message.data;
    if (typeof data !== "string") {
      return;
    }
    let payload: unknown;
    try {
      payload = JSON.parse(Buffer.from(data, "base64").toString("utf8"));
    } catch {
      return;
    }
    if (!isRecord(payload)) {
      return;
    }
    if (payload.packageName != null && payload.packageName !== deps.env.play.packageName) {
      return;
    }

    const now = Math.trunc(clock());
    const voided = payload.voidedPurchaseNotification;
    if (isRecord(voided) && typeof voided.purchaseToken === "string" && voided.purchaseToken !== "") {
      const row = await store.mark(voided.purchaseToken, "revoked", now);
      if (row !== null) {
        await apply(row.uid);
      }
      return;
    }

    const notification = payload.subscriptionNotification;
    if (
      !isRecord(notification) ||
      typeof notification.purchaseToken !== "string" ||
      notification.purchaseToken === ""
    ) {
      // testNotification / one-time products: nothing to do.
      return;
    }
    const token = notification.purchaseToken;
    // A Play 503 propagates so Pub/Sub retries.
    const resource = await api!.getSubscription(token);
    let entitlement;
    try {
      entitlement = evaluateCanonical(resource, products, now);
    } catch (err) {
      if (err instanceof BillingError) {
        // Unknown product etc. — redelivery cannot fix it.
        return;
      }
      throw err;
    }

    let row = await store.record(token, entitlement, now);
    let oldOwner: string | null = null;
    if (entitlement.linked_token !== null) {
      const linked = await store.get(entitlement.linked_token);
      oldOwner = linked?.uid ?? null;
    }
    if (notification.notificationType === REVOKED) {
      row = (await store.mark(token, "revoked", now)) ?? row;
    }
    // Unbound tokens (verify never reached us) are applied at /billing/verify.
    await apply(row.uid);
    if (oldOwner !== null && oldOwner !== row.uid) {
      await apply(oldOwner);
    }
  }

  async function usageFields(uid: string | null): Promise<Record<string, unknown>> {
    const fields: Record<string, unknown> = {
      billing_enabled: configured,
    };
    if (uid !== null && uid !== "") {
      const current = await entitlements.entitlement(uid);
      if (current.productId !== null) {
        fields.plan_expires_at = iso(current.expiresAt);
        fields.plan_auto_renews = current.autoRenewing;
        fields.plan_product_id = current.productId;
        fields.plan_period = current.period;
        fields.plan_purchase_state = current.purchaseState;
      }
    }
    return fields;
  }

  function offerings(): { available: boolean; products: BillingOffering[] } {
    if (!configured) return { available: false, products: [] };
    const available = Object.keys(products).flatMap((productId) => {
      const product = selectBillingProduct(productId, [productId]);
      return product === null ? [] : [{ productId, ...product }];
    });
    return { available: available.length > 0, products: available };
  }

  return {
    get configured() {
      return configured;
    },
    products,
    verify,
    notify,
    revenueCat: (event) => entitlements.apply(event),
    entitlement: (uid) => entitlements.entitlement(uid),
    offerings,
    usageFields,
  };
}
