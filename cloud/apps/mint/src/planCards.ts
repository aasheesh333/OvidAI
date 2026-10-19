import type { MintEnv } from "./env.js";
import { DEFAULT_PRODUCTS } from "./billing/products.js";
import { storedTier, windowStr, type PlanData } from "./planMath.js";

/**
 * Server-authoritative plan cards for the app's Plans screen (SH-006,
 * SH-005, SH-021). Built from the LIVE plan table (Postgres `plans`, owner-
 * editable in /admin), so names, prices, multipliers and feature copy can
 * never drift from what the pools hook actually enforces. Returned by
 * POST /usage (`plans`) and GET /plans whether or not Play billing is
 * configured — the app shows real prices and facts regardless.
 */
export interface PlanCard {
  /** storedTier(plan): the first alias or the id — what /usage `tier` reports. */
  tier: string;
  id: string;
  name: string;
  price_usd: number;
  /** Allowance multiplier over the Free per-day allowance base. */
  mult: number;
  /** windowStr(window_hours): "24h", "30d", ... */
  window: string;
  window_hours: number;
  aliases: string[];
  features: string[];
  /** The Play subscription product mapped to this plan, or null. */
  product_id: string | null;
}

/** "23", "2.5", "0.75": integers bare, otherwise up to two decimals. */
function multText(n: number): string {
  if (!Number.isFinite(n)) return "0";
  const rounded = n >= 10 ? Math.round(n) : Math.round(n * 100) / 100;
  return String(rounded);
}

/**
 * Feature lines generated from the plan's own numbers. `freeMult` is the
 * Free plan's multiplier: the per-day allowance is free_daily × mult, so the
 * "N x the Free allowance" ratio is mult / freeMult whatever the windows.
 */
export function planFeatures(plan: PlanData, freeMult: number): string[] {
  const out: string[] = [];
  if (plan.id === "free") {
    out.push("The standard Free allowance");
  } else {
    const ratio = freeMult > 0 ? plan.mult / freeMult : plan.mult;
    out.push(
      Math.abs(ratio - 1) < 1e-9
        ? "The same allowance as Free"
        : `About ${multText(ratio)}x the Free allowance`,
    );
  }
  out.push(`Allowance resets every ${windowStr(plan.window_hours)}`);
  out.push("All Ovid Cloud chat models");
  out.push(
    plan.id === "free"
      ? "Image generation within the allowance"
      : "Image generation from the same allowance",
  );
  if (plan.auto_oss) out.push("Auto routes across fast open models");
  if (plan.slow_mode) out.push("Keeps working in slow mode after the allowance runs out");
  return out;
}

/** Enabled plans, in table order, as app-facing cards. */
export function planCards(plans: PlanData[], products: Record<string, string>): PlanCard[] {
  const freeMult = plans.find((p) => p.id === "free")?.mult ?? 1;
  const productEntries = Object.entries(products);
  return plans
    .filter((p) => p.enabled)
    .map((p) => {
      const names = new Set([p.id, ...p.aliases]);
      const product =
        p.id === "free" ? undefined : productEntries.find(([, tier]) => names.has(tier));
      return {
        tier: storedTier(p),
        id: p.id,
        name: p.name,
        price_usd: Number(p.price_usd),
        mult: Number(p.mult),
        window: windowStr(p.window_hours),
        window_hours: p.window_hours,
        aliases: [...p.aliases],
        features: planFeatures(p, freeMult),
        product_id: product?.[0] ?? null,
      };
    });
}

/**
 * Play product → tier mapping: the billing service's (when configured),
 * else OVID_PLAY_PRODUCTS, else the shipped defaults — so plan facts never
 * depend on Play being configured.
 */
export function playProductsFor(
  env: MintEnv,
  billing: { readonly products: Record<string, string> } | undefined,
): Record<string, string> {
  if (billing !== undefined) return billing.products;
  if (env.play.products !== null) return env.play.products;
  return DEFAULT_PRODUCTS;
}
