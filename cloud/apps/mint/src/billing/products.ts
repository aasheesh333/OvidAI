import { createHash } from "node:crypto";

/**
 * Port of server/billing/products.py — the Play product catalogue.
 *
 * Product IDs must match the subscriptions created in Play Console and the
 * client constants in lib/core/play_billing.dart (kOvidPlayProducts). They can
 * be overridden without a code change through OVID_PLAY_PRODUCTS.
 */

/**
 * The canonical plan ids, cheapest first — `@ovid/shared`'s table order.
 *
 * `storedTier` writes one of these into `users.tier`, so this list is what a
 * purchase and the gateway agree on.
 */
export const TIERS = ["free", "go", "plus", "pro"] as const;

/**
 * Every tier string a Play product may map to, canonical ids first.
 *
 * The legacy spellings stay accepted for two reasons: an install configured
 * through `OVID_PLAY_PRODUCTS` may still name one, and rows written by an
 * earlier deployment hold `3x` / `7x` / `15x` (or the first seed's ids).
 * Rejecting them would either refuse to boot or reset a paying account.
 */
export const PRODUCT_TIERS = [
  "free",
  "go",
  "plus",
  "pro",
  "3x",
  "7x",
  "15x",
  "starter",
  "max",
] as const;

/**
 * Tier → rank lives in `@ovid/shared` (`tierRank`), next to the plan table,
 * because three copies of it had already drifted: billing picked a winning
 * line item with it, `@ovid/db` picked a winning purchase, and the mint
 * normalised a stored tier with it. One function, one order.
 */
export const DEFAULT_PRODUCTS: Record<string, string> = {
  ovid_plus_monthly: "go",
  ovid_pro_monthly: "plus",
  ovid_max_monthly: "pro",
};

/*
 * Plan feature copy used to live here (DEFAULT_PLAN_FEATURES, "About 7x the
 * Free allowance"...) and contradicted the real plan table. Plan cards are
 * now generated from the live plans in ../planCards.ts (SH-006).
 */

/**
 * `OVID_PLAY_PRODUCTS` is a non-empty JSON object of product id → tier. A
 * missing/empty variable means DEFAULT_PRODUCTS. Anything invalid throws (the
 * Python loader raises ValueError; the process must not boot half-configured).
 */
export function loadProducts(env: { OVID_PLAY_PRODUCTS?: string }): Record<string, string> {
  const raw = env.OVID_PLAY_PRODUCTS?.trim();
  if (raw === undefined || raw === "") {
    return { ...DEFAULT_PRODUCTS };
  }
  const parsed: unknown = JSON.parse(raw);
  if (
    typeof parsed !== "object" ||
    parsed === null ||
    Array.isArray(parsed) ||
    Object.keys(parsed).length === 0
  ) {
    throw new Error("OVID_PLAY_PRODUCTS must be a non-empty JSON object");
  }
  for (const [product, tier] of Object.entries(parsed as Record<string, unknown>)) {
    if (
      typeof tier !== "string" ||
      !(PRODUCT_TIERS as readonly string[]).includes(tier) ||
      tier === "free"
    ) {
      throw new Error(`invalid product mapping ${JSON.stringify(product)} -> ${JSON.stringify(tier)}`);
    }
  }
  return { ...(parsed as Record<string, string>) };
}

/**
 * Value the client passes as Play `obfuscatedAccountId`: lower-case hex
 * SHA-256 of `"ovid:" + uid` — exactly `ovidPlayAccountId` in
 * lib/core/play_billing.dart. It binds a purchase token to the account.
 */
export function accountHash(uid: string): string {
  return createHash("sha256").update(`ovid:${uid}`, "utf8").digest("hex");
}
