import { describe, expect, it } from "vitest";
import {
  PLANS,
  PLAN_TIERS,
  countedTokens,
  manualModelsAllowed,
  modelAllowedForTier,
  planFor,
  storageBytes,
  tierRank,
  tokenCapsFor,
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

describe("token caps", () => {
  it("gives Free the spec's 50M a day and 1.5B a month", () => {
    expect(PLANS.free.tokens).toEqual({
      perDay: 50_000_000,
      perMonth: 1_500_000_000,
    });
  });

  it("scales every paid tier by its auto multiplier over the Free baseline", () => {
    // The product's paid allowance is "1.5× / 5× / 20× the free allowance",
    // and `autoMultiplier` is the one place that ratio already lives. The
    // token caps must move with it: a plan that may spend 5× the money must
    // be allowed to move 5× the tokens.
    for (const tier of PLAN_TIERS) {
      const plan = PLANS[tier];
      expect(plan.tokens.perDay).toBe(
        Math.round(PLANS.free.tokens.perDay * plan.autoMultiplier),
      );
      expect(plan.tokens.perMonth).toBe(
        Math.round(PLANS.free.tokens.perMonth * plan.autoMultiplier),
      );
    }
    expect(PLAN_TIERS.map((t) => PLANS[t].tokens.perDay)).toEqual([
      50_000_000,
      75_000_000,
      250_000_000,
      1_000_000_000,
    ]);
    expect(PLAN_TIERS.map((t) => PLANS[t].tokens.perMonth)).toEqual([
      1_500_000_000,
      2_250_000_000,
      7_500_000_000,
      30_000_000_000,
    ]);
  });

  it("resolves caps through the same legacy-tier mapping as the plan", () => {
    expect(tokenCapsFor("7x")).toEqual(PLANS.plus.tokens);
    expect(tokenCapsFor("starter")).toEqual(PLANS.go.tokens);
    expect(tokenCapsFor("mystery")).toEqual(PLANS.free.tokens);
  });
});

describe("countedTokens", () => {
  it("counts input + output and leaves cache out of the cap", () => {
    // `run_usage` reports cache separately because it is priced separately;
    // adding it would count the same prompt twice on a cache hit.
    expect(
      countedTokens({
        inputTokens: 1_200,
        outputTokens: 300,
        cacheReadTokens: 900,
        cacheWriteTokens: 50,
      }),
    ).toBe(1_500);
  });

  it("never returns a negative or non-finite count", () => {
    expect(countedTokens({ inputTokens: -5, outputTokens: 0 })).toBe(0);
    expect(countedTokens({ inputTokens: Number.NaN, outputTokens: 10 })).toBe(10);
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
