import { createHash } from "node:crypto";

/**
 * Port of server/billing/products.py — the Play product catalogue.
 *
 * Product IDs must match the subscriptions created in Play Console and the
 * client constants in lib/core/play_billing.dart (kOvidPlayProducts). They can
 * be overridden without a code change through OVID_PLAY_PRODUCTS.
 */

export const TIERS = ["free", "3x", "7x", "15x"] as const;

export const TIER_RANK: Record<string, number> = Object.fromEntries(
  TIERS.map((tier, rank) => [tier, rank]),
);

export const DEFAULT_PRODUCTS: Record<string, string> = {
  // Monthly first: /usage shows the first product that maps to a tier.
  ovid_plus_monthly: "3x",
  ovid_pro_monthly: "7x",
  ovid_max_monthly: "15x",
  // Yearly SKUs (10 monthly payments). Same tier, different billing period.
  ovid_plus_yearly: "3x",
  ovid_pro_yearly: "7x",
  ovid_max_yearly: "15x",
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
    if (typeof tier !== "string" || !(TIERS as readonly string[]).includes(tier) || tier === "free") {
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
