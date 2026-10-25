import { describe, expect, it } from "vitest";
import { planFor } from "@ovid/shared";
import {
  BILLING_PRODUCTS,
  DEFAULT_PRODUCTS,
  selectBillingProduct,
} from "./products.js";

describe("canonical billing products", () => {
  it("maps all six monthly/yearly products to canonical tiers", () => {
    expect(BILLING_PRODUCTS).toEqual({
      ovid_plus_monthly: { tier: "go", period: "monthly" },
      ovid_plus_yearly: { tier: "go", period: "yearly" },
      ovid_pro_monthly: { tier: "plus", period: "monthly" },
      ovid_pro_yearly: { tier: "plus", period: "yearly" },
      ovid_max_monthly: { tier: "pro", period: "monthly" },
      ovid_max_yearly: { tier: "pro", period: "yearly" },
    });
    // The legacy plan-card map stays monthly-only; BILLING_PRODUCTS is the six-item authority.
    expect(DEFAULT_PRODUCTS).toEqual({
      ovid_plus_monthly: "go",
      ovid_pro_monthly: "plus",
      ovid_max_monthly: "pro",
    });
  });

  it("does not invent a yearly price or extra product fields", () => {
    for (const product of Object.values(BILLING_PRODUCTS)) {
      expect(Object.keys(product).sort()).toEqual(["period", "tier"]);
      expect(product).not.toHaveProperty("priceUsd");
      expect(product).not.toHaveProperty("priceInr");
    }
  });

  it("resolves every legacy spelling through planFor", () => {
    expect(["3x", "starter"].map((tier) => planFor(tier).id)).toEqual(["go", "go"]);
    expect(planFor("7x").id).toBe("plus");
    expect(["15x", "max"].map((tier) => planFor(tier).id)).toEqual(["pro", "pro"]);
  });

  it("selects only the exact requested period, never yearly to monthly", () => {
    expect(selectBillingProduct("ovid_pro_yearly", ["ovid_pro_monthly"])).toBeNull();
    expect(selectBillingProduct("ovid_pro_yearly", ["ovid_pro_yearly"])).toEqual({
      tier: "plus",
      period: "yearly",
    });
  });

  it("returns null for unknown or unconfigured products", () => {
    expect(selectBillingProduct("ovid_pro_monthly", [])).toBeNull();
    expect(selectBillingProduct("made_up", ["made_up"])).toBeNull();
    expect(selectBillingProduct("ovid_pro_yearly", ["ovid_pro_yearly_monthly"])).toBeNull();
  });
});
