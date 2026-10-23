import { describe, expect, it } from "vitest";
import {
  PLANS,
  PLAN_TIERS,
  manualModelsAllowed,
  modelAllowedForTier,
  planFor,
  storageBytes,
  tierRank,
} from "./plans.js";

/**
 * The plan table is the one place the product's numbers live. These tests pin
 * the three things that used to drift: the multipliers, who may pick a model,
 * and what an unknown tier means.
 */

describe("PLANS", () => {
  it("carries the product's prices and multipliers", () => {
    expect(PLANS.free.autoMultiplier).toBe(1);
    expect(PLANS.go.autoMultiplier).toBe(1.5);
    expect(PLANS.plus.autoMultiplier).toBe(5);
    expect(PLANS.pro.autoMultiplier).toBe(20);

    expect([PLANS.go.priceUsd, PLANS.plus.priceUsd, PLANS.pro.priceUsd]).toEqual([
      5, 18, 99,
    ]);
    expect([PLANS.go.priceInr, PLANS.plus.priceInr, PLANS.pro.priceInr]).toEqual([
      499, 1799, 9999,
    ]);
  });

  it("carries the storage and file caps", () => {
    expect(PLAN_TIERS.map((t) => PLANS[t].storageGb)).toEqual([3, 5, 15, 75]);
    expect(PLAN_TIERS.map((t) => PLANS[t].projectFiles)).toEqual([80, 100, 150, 250]);
    expect(PLAN_TIERS.map((t) => PLANS[t].customConnectors)).toEqual([0, 5, 20, 20]);
    expect(PLANS.free.uploads).toEqual({ count: 50, windowHours: 24 });
    expect(PLANS.go.uploads).toEqual({ count: 80, windowHours: 3 });
  });
});

describe("manual model access", () => {
  it("is Free and Go only for the paid manual tiers", () => {
    expect(manualModelsAllowed("free")).toBe(false);
    expect(manualModelsAllowed("go")).toBe(false);
    expect(manualModelsAllowed("plus")).toBe(true);
    expect(manualModelsAllowed("pro")).toBe(true);
  });

  it("lets every tier use auto", () => {
    for (const tier of PLAN_TIERS) {
      expect(modelAllowedForTier(tier, "auto")).toBe(true);
      expect(modelAllowedForTier(tier, null)).toBe(true);
      expect(modelAllowedForTier(tier, "")).toBe(true);
    }
  });

  it("refuses a named model on an auto-only tier", () => {
    expect(modelAllowedForTier("free", "deepseek-v4.1-flash")).toBe(false);
    expect(modelAllowedForTier("go", "deepseek-v4.1-flash")).toBe(false);
    expect(modelAllowedForTier("plus", "deepseek-v4.1-flash")).toBe(true);
  });
});

describe("planFor", () => {
  it("is case- and whitespace-insensitive", () => {
    expect(planFor("  PLUS ").id).toBe("plus");
  });

  it("maps a legacy id onto the paid plan it used to be", () => {
    // `max` was the $60 top tier with manual models; reading it as Free would
    // take a paying account's allowance away.
    expect(planFor("max").id).toBe("pro");
    expect(planFor("starter").id).toBe("go");
    expect(planFor("max").manualModels).toBe(true);
  });

  it("maps the billing aliases the mint stored onto their tiers", () => {
    // The mint wrote `aliases[0]` into users.tier, so a paying account reads
    // back as "3x" / "7x" / "15x". Resolving those as Free is not a cosmetic
    // bug: it locks manual models for a Plus/Pro customer (messages.ts 402).
    expect(planFor("3x").id).toBe("go");
    expect(planFor("7x").id).toBe("plus");
    expect(planFor("15x").id).toBe("pro");
    expect(manualModelsAllowed("7x")).toBe(true);
    expect(manualModelsAllowed("15x")).toBe(true);
  });

  it("an unknown or missing tier is Free, never a paid plan", () => {
    for (const tier of [null, undefined, "", "mystery-tier", "enterprise"]) {
      expect(planFor(tier).id).toBe("free");
    }
  });

  it("storageBytes matches the gigabytes in the table", () => {
    expect(storageBytes("pro")).toBe(75 * 1024 ** 3);
    expect(storageBytes("nonsense")).toBe(3 * 1024 ** 3);
  });
});

describe("tierRank", () => {
  it("ranks the canonical ids cheapest first", () => {
    expect(PLAN_TIERS.map(tierRank)).toEqual([0, 1, 2, 3]);
  });

  it("ranks a legacy spelling the same as the tier it means", () => {
    // Billing compares ranks to pick a winning line item. A legacy string
    // ranked 0 would lose to a free row and reset a paying account.
    expect(tierRank("3x")).toBe(tierRank("go"));
    expect(tierRank("7x")).toBe(tierRank("plus"));
    expect(tierRank("15x")).toBe(tierRank("pro"));
    expect(tierRank("starter")).toBe(tierRank("go"));
    expect(tierRank("max")).toBe(tierRank("pro"));
  });

  it("ranks an unknown or missing tier as Free", () => {
    for (const tier of [null, undefined, "", "mystery", "enterprise"]) {
      expect(tierRank(tier)).toBe(0);
    }
  });
});
