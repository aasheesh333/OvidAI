import { timingSafeEqual } from "node:crypto";
import {
  billingPurchases,
  PurchaseConflictError,
  type Db,
  type EntitlementFields,
  type PurchaseRow,
} from "@ovid/db";
import type { Redis } from "ioredis";
import type { MintEnv } from "../env.js";
import { BillingError, evaluate } from "./domain.js";
import type { PlayDeveloperApi } from "./play.js";
import { createPlayApi } from "./play.js";
import { accountHash, loadProducts } from "./products.js";
import { createTierSink, type PublishTier, type TierSink } from "./tierSink.js";

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

export interface BillingService {
  readonly configured: boolean;
  /** Play product id -> tier (3x/7x/15x); planCards maps plans to products. */
  readonly products: Record<string, string>;
  verify(uid: string, body: unknown): Promise<BillingVerifyResult>;
  notify(envelope: unknown): Promise<void>;
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
  return loadProducts({});
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

  /** Recompute the user's best active purchase and push it to mint. */
  async function apply(uid: string | null): Promise<{ tier: string; best: PurchaseRow | null }> {
    if (uid === null || uid === "") {
      return { tier: "free", best: null };
    }
    const best = await store.effective(uid, Math.trunc(clock()));
    const tier = best?.tier ?? "free";
    await setTier(uid, tier, best?.expiresAt ?? null);
    return { tier, best };
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
    const entitlement = evaluate(resource, products, now);
    if (entitlement.account_hash === null) {
      if (requireAccountId) {
        throw new BillingError(403, "account_mismatch");
      }
    } else if (!safeEqual(entitlement.account_hash, accountHash(uid))) {
      throw new BillingError(403, "account_mismatch");
    }

    const row = await store.record(token, entitlement, now, uid);
    const { tier, best } = await apply(uid);
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
      expires_at: iso(best?.expiresAt ?? null),
      auto_renewing: Boolean(best?.autoRenewing),
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
    let resource;
    try {
      resource = await api!.getSubscription(token);
    } catch (err) {
      if (err instanceof BillingError && err.status < 500) {
        // Google does not know this token (forged, foreign package, or a
        // replayed token that has been purged). Redelivery cannot fix it, so
        // acknowledge instead of looping forever.
        return;
      }
      throw err;
    }
    let entitlement;
    try {
      entitlement = evaluate(resource, products, now);
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
    if (configured && uid !== null && uid !== "") {
      const best = await store.effective(uid, Math.trunc(clock()));
      if (best !== null) {
        fields.plan_expires_at = iso(best.expiresAt);
        fields.plan_auto_renews = best.autoRenewing;
        fields.plan_product_id = best.productId;
      }
    }
    return fields;
  }

  return {
    get configured() {
      return configured;
    },
    products,
    verify,
    notify,
    usageFields,
  };
}
