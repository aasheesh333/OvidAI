import type { EntitlementFields } from "@ovid/db";
import { tierRank } from "@ovid/shared";

/**
 * Pure evaluation of a Play `SubscriptionPurchaseV2` into an entitlement.
 * Port of server/billing/domain.py — no I/O, so every state transition is
 * unit-testable.
 */

/** States in which the user keeps access until `expiryTime`. */
export const ENTITLED_STATES: ReadonlySet<string> = new Set([
  "SUBSCRIPTION_STATE_ACTIVE",
  "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
  "SUBSCRIPTION_STATE_CANCELED",
]);

const PENDING_STATES: ReadonlySet<string> = new Set(["SUBSCRIPTION_STATE_PENDING"]);

export class BillingError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(code);
    this.name = "BillingError";
  }
}

/**
 * What one purchase token currently grants. Extends the persisted ledger
 * shape pinned in Task 2 with the verify-time-only fields.
 */
export interface Entitlement extends EntitlementFields {
  acknowledged: boolean;
  test_purchase: boolean;
  state: string;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * Parse Play's RFC-3339 timestamps to epoch seconds. Play may send nanosecond
 * precision; Python's datetime accepts at most microseconds, so the fractional
 * part is truncated to 6 digits (a naive timestamp is UTC, like Python).
 */
export function parsePlayTime(value: string | null): number | null {
  if (value === null || value === undefined || value === "") {
    return null;
  }
  if (typeof value !== "string") {
    throw new TypeError("play timestamp must be a string");
  }
  let text = value.replace("Z", "+00:00");
  const dot = text.indexOf(".");
  if (dot >= 0) {
    const head = text.slice(0, dot);
    const rest = text.slice(dot + 1);
    const digits = (rest.match(/^\d+/) ?? [""])[0]!;
    const suffix = rest.slice(digits.length);
    text = `${head}.${digits.slice(0, 6)}${suffix}`;
  }
  // Python treats a naive datetime as UTC; Date.parse treats it as local.
  if (!/[zZ]$/.test(text) && !/[+-]\d{2}:?\d{2}$/.test(text)) {
    text += "Z";
  }
  const ms = Date.parse(text);
  if (!Number.isFinite(ms)) {
    throw new Error(`invalid Play timestamp: ${value}`);
  }
  return Math.trunc(ms / 1000);
}

/**
 * Map a SubscriptionPurchaseV2 resource to an Entitlement.
 *
 * `products` maps product IDs to tiers; unknown products never grant a tier.
 * `now` is epoch seconds.
 */
export function evaluate(
  resource: unknown,
  products: Record<string, string>,
  now: number,
): Entitlement {
  if (!isRecord(resource)) {
    throw new BillingError(502, "play_invalid_response");
  }
  const state =
    typeof resource.subscriptionState === "string" && resource.subscriptionState !== ""
      ? resource.subscriptionState
      : "SUBSCRIPTION_STATE_UNSPECIFIED";

  const items: Array<{ product: string; expiry: number | null; auto: boolean }> = [];
  const rawItems = resource.lineItems;
  if (Array.isArray(rawItems)) {
    for (const item of rawItems) {
      if (!isRecord(item)) {
        continue;
      }
      const product = item.productId;
      if (typeof product !== "string" || !Object.prototype.hasOwnProperty.call(products, product)) {
        continue;
      }
      let expiry: number | null;
      try {
        expiry = parsePlayTime(
          typeof item.expiryTime === "string" ? item.expiryTime : null,
        );
      } catch {
        expiry = null;
      }
      const plan = isRecord(item.autoRenewingPlan) ? item.autoRenewingPlan : {};
      items.push({ product, expiry, auto: Boolean(plan.autoRenewEnabled) });
    }
  }
  if (items.length === 0) {
    throw new BillingError(400, "unknown_product");
  }

  // Highest tier first, then the latest expiry (an upgrade line wins).
  items.sort((a, b) => {
    const rankDiff = tierRank(products[a.product]) - tierRank(products[b.product]);
    if (rankDiff !== 0) {
      return -rankDiff;
    }
    return (b.expiry ?? 0) - (a.expiry ?? 0);
  });
  const [chosen] = items as [typeof items[number]];

  const ids = isRecord(resource.externalAccountIdentifiers)
    ? resource.externalAccountIdentifiers
    : {};
  const accountHashValue = ids.obfuscatedExternalAccountId;
  const linked = resource.linkedPurchaseToken;

  const common = {
    product_id: chosen.product,
    expires_at: chosen.expiry,
    auto_renewing: chosen.auto && state !== "SUBSCRIPTION_STATE_CANCELED",
    linked_token: typeof linked === "string" && linked !== "" ? linked : null,
    account_hash:
      typeof accountHashValue === "string" && accountHashValue !== "" ? accountHashValue : null,
    acknowledged: resource.acknowledgementState === "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED",
    test_purchase: Object.prototype.hasOwnProperty.call(resource, "testPurchase"),
    state,
  };

  if (PENDING_STATES.has(state)) {
    return { status: "pending", tier: "free", ...common };
  }
  if (ENTITLED_STATES.has(state) && chosen.expiry !== null && chosen.expiry > now) {
    return { status: "active", tier: products[chosen.product]!, ...common };
  }
  return { status: "expired", tier: "free", ...common };
}
