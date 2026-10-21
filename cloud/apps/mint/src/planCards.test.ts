import { describe, expect, it } from "vitest";
import { loadMintEnv } from "./env.js";
import { planCards, planFeatures, playProductsFor } from "./planCards.js";
import { seedPlans, type PlanData } from "./planMath.js";
import { DEFAULT_PRODUCTS } from "./billing/products.js";

/**
 * SH-006 / SH-005 / SH-021: the Plans screen renders names, prices,
 * multipliers and feature copy from the server's LIVE plan table (owner-
 * editable in /admin), never from hard-coded tier copy.
 */

describe("planCards", () => {
  it("renders the seeded plan table (Free/Go/Plus/Pro) with tier aliases and Play products", () => {
    const cards = planCards(seedPlans(), DEFAULT_PRODUCTS);
    expect(cards.map((c) => [c.tier, c.id, c.name, c.price_usd, c.mult, c.window])).toEqual([
      ["free", "free", "Free", 0, 1, "24h"],
      ["3x", "starter", "Go", 5, 3, "24h"],
      ["7x", "pro", "Plus", 18, 23, "24h"],
      ["15x", "max", "Pro", 99, 43, "24h"],
    ]);
    expect(cards.map((c) => c.product_id)).toEqual([
      null,
      "ovid_plus_monthly",
      "ovid_pro_monthly",
      "ovid_max_monthly",
    ]);
    const pro = cards[2]!;
    expect(pro.features).toContain("About 23x the Free allowance");
    expect(pro.features).toContain("Allowance resets every 24h");
    expect(pro.features).toContain("All Ovid Cloud chat models");
    expect(pro.features).toContain("Image generation from the same allowance");
    expect(pro).toMatchObject({ aliases: ["7x"], window_hours: 24 });
    // The stale "About 7x" copy is gone for good.
    expect(JSON.stringify(cards)).not.toContain("About 7x");
    expect(JSON.stringify(cards)).not.toContain("About 15x");
  });

  it("follows admin edits: disabled plans are hidden, order is kept, mult/name/window flow through", () => {
    const plans: PlanData[] = seedPlans().map((p) =>
      p.id === "pro"
        ? { ...p, name: "Pro+", mult: 30, window_hours: 720 }
        : p.id === "max"
          ? { ...p, enabled: false }
          : p,
    );
    plans.push({
      id: "team", name: "Team", price_usd: 99.5, enabled: true, aliases: [],
      window_hours: 168, mult: 80, slow_mode: true, auto_oss: false,
    });
    const cards = planCards(plans, DEFAULT_PRODUCTS);
    expect(cards.map((c) => c.id)).toEqual(["free", "starter", "pro", "team"]);
    const pro = cards[2]!;
    expect(pro.name).toBe("Pro+");
    expect(pro.features).toContain("About 30x the Free allowance");
    expect(pro.features).toContain("Allowance resets every 30d");
    const team = cards[3]!;
    expect(team.tier).toBe("team"); // no alias → the id (what /usage `tier` reports)
    expect(team.product_id).toBeNull(); // no Play product targets it
    expect(team.price_usd).toBe(99.5);
    expect(team.features).toContain("Allowance resets every 7d");
  });

  it("feature copy: free, auto_oss, slow_mode, fractional and relative multipliers", () => {
    const [free, starter, pro] = seedPlans();
    expect(planFeatures(free!, 1)[0]).toBe("The standard Free allowance");
    expect(planFeatures(starter!, 1)).toEqual([
      "About 3x the Free allowance",
      "Allowance resets every 24h",
      "All Ovid Cloud chat models",
      "Image generation from the same allowance",
    ]);
    expect(planFeatures(pro!, 1)).toContain("Auto routes across fast open models");
    expect(planFeatures({ ...starter!, slow_mode: true }, 1)).toContain(
      "Keeps working in slow mode after the allowance runs out",
    );
    expect(planFeatures({ ...starter!, mult: 2.5 }, 1)[0]).toBe("About 2.5x the Free allowance");
    // Relative to the Free plan's own multiplier.
    expect(planFeatures({ ...starter!, mult: 6 }, 2)[0]).toBe("About 3x the Free allowance");
    expect(planFeatures({ ...starter!, mult: 1 }, 1)[0]).toBe("The same allowance as Free");
  });

  it("playProductsFor: billing service mapping, then OVID_PLAY_PRODUCTS, then the defaults", () => {
    const env = loadMintEnv({
      NODE_ENV: "test",
      DATABASE_URL: "postgres://x",
      REDIS_DB2_URL: "redis://x",
      LITELLM_BASE: "http://x",
      LITELLM_MASTER_KEY: "k",
      OVID_ADMIN_MASTER_KEY: "a",
      OVID_INTERNAL_API_SECRET: "i",
      FIREBASE_PROJECT_ID: "p",
    });
    expect(playProductsFor(env, undefined)).toEqual(DEFAULT_PRODUCTS);
    const custom = { ...env, play: { ...env.play, products: { sku_a: "7x" } } };
    expect(playProductsFor(custom, undefined)).toEqual({ sku_a: "7x" });
    expect(playProductsFor(custom, { products: { sku_b: "3x" } })).toEqual({ sku_b: "3x" });
  });
});
