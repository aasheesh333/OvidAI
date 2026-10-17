import { describe, expect, it } from "vitest";
import {
  BillingError,
  ENTITLED_STATES,
  evaluate,
  parsePlayTime,
  type Entitlement,
} from "./domain.js";
import {
  DEFAULT_PLAN_FEATURES,
  DEFAULT_PRODUCTS,
  TIER_RANK,
  TIERS,
  accountHash,
  loadProducts,
} from "./products.js";

/**
 * Port of server/billing/tests/test_billing.py's DomainTest +
 * products.test surface. Pure functions only — no DB, Redis or network.
 */

const NOW = 1_800_000_000; // 2027-01-15T08:00:00Z
const PRODUCTS = {
  ovid_plus_monthly: "3x",
  ovid_pro_monthly: "7x",
  ovid_max_monthly: "15x",
};

function iso(epoch: number): string {
  return new Date(epoch * 1000).toISOString().replace(/\.000Z$/, "Z");
}

function subscription(
  opts: {
    product?: string;
    state?: string;
    expiry?: number;
    uid?: string | null;
    auto?: boolean;
    linked?: string | null;
    ack?: boolean;
  } = {},
): Record<string, unknown> {
  const {
    product = "ovid_plus_monthly",
    state = "SUBSCRIPTION_STATE_ACTIVE",
    expiry = NOW + 30 * 86400,
    uid = "u1",
    auto = true,
    linked = null,
    ack = false,
  } = opts;
  const resource: Record<string, unknown> = {
    kind: "androidpublisher#subscriptionPurchaseV2",
    subscriptionState: state,
    acknowledgementState: ack
      ? "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED"
      : "ACKNOWLEDGEMENT_STATE_PENDING",
    lineItems: [
      {
        productId: product,
        expiryTime: iso(expiry),
        autoRenewingPlan: { autoRenewEnabled: auto },
      },
    ],
  };
  if (uid !== null) {
    resource.externalAccountIdentifiers = {
      obfuscatedExternalAccountId: accountHash(uid),
    };
  }
  if (linked) resource.linkedPurchaseToken = linked;
  return resource;
}

function codeOf(fn: () => unknown): string {
  try {
    fn();
  } catch (err) {
    expect(err).toBeInstanceOf(BillingError);
    return (err as BillingError).code;
  }
  throw new Error("expected BillingError");
}

describe("products (port of products.py)", () => {
  it("TIERS/TIER_RANK/DEFAULT_PRODUCTS are the Python constants", () => {
    expect([...TIERS]).toEqual(["free", "3x", "7x", "15x"]);
    expect(TIER_RANK).toEqual({ free: 0, "3x": 1, "7x": 2, "15x": 3 });
    expect(DEFAULT_PRODUCTS).toEqual({
      ovid_plus_monthly: "3x",
      ovid_pro_monthly: "7x",
      ovid_max_monthly: "15x",
    });
  });

  it("accountHash is sha256('ovid:'+uid) lower-hex (Dart ovidPlayAccountId parity)", () => {
    expect(accountHash("u1")).toBe(
      "2fb603638930415250222626810962fe2894298c862221efc2737b2060c293d8",
    );
    expect(accountHash("u1")).toHaveLength(64);
    expect(accountHash("u1")).not.toBe(accountHash("u2"));
  });

  it("DEFAULT_PLAN_FEATURES is the verbatim Python copy", () => {
    expect(DEFAULT_PLAN_FEATURES.free).toEqual([
      "All Ovid Cloud chat models",
      "About 30 messages a day",
      "Image generation within the daily allowance",
    ]);
    expect(DEFAULT_PLAN_FEATURES["15x"]).toEqual([
      "All Ovid Cloud chat models",
      "About 15x the Free allowance, pooled over 30 days",
      "Image generation from the same allowance",
      "Priority during busy periods",
    ]);
    expect(Object.keys(DEFAULT_PLAN_FEATURES)).toEqual(["free", "3x", "7x", "15x"]);
  });

  it("loadProducts: default, override, and invalid JSON/mappings throw", () => {
    expect(loadProducts({})).toEqual(DEFAULT_PRODUCTS);
    expect(loadProducts({ OVID_PLAY_PRODUCTS: '{"a": "7x"}' })).toEqual({ a: "7x" });
    for (const raw of ['{"a": "free"}', '{"a": "99x"}', "[]", "{}", "not-json"]) {
      expect(() => loadProducts({ OVID_PLAY_PRODUCTS: raw })).toThrow();
    }
  });
});

describe("parsePlayTime (port of domain.parse_time)", () => {
  it("truncates Play's nanosecond timestamps to microseconds like Python", () => {
    expect(parsePlayTime("2027-01-15T08:00:00.123456789Z")).toBe(
      parsePlayTime("2027-01-15T08:00:00.123456Z"),
    );
    expect(parsePlayTime("2027-01-15T08:00:00.123456789Z")).toBe(NOW);
  });

  it("accepts explicit offsets and treats a naive timestamp as UTC", () => {
    expect(parsePlayTime("2027-01-15T08:00:00+00:00")).toBe(NOW);
    expect(parsePlayTime("2027-01-15T09:00:00+01:00")).toBe(NOW);
    expect(parsePlayTime("2027-01-15T08:00:00")).toBe(NOW);
  });

  it("null/empty → null; garbage throws (evaluate treats it as no expiry)", () => {
    expect(parsePlayTime(null)).toBeNull();
    expect(parsePlayTime("")).toBeNull();
    expect(() => parsePlayTime("not-a-time")).toThrow();
  });
});

describe("evaluate (port of domain.evaluate)", () => {
  it("ACTIVE, IN_GRACE_PERIOD and CANCELED grant until expiry", () => {
    for (const state of [
      "SUBSCRIPTION_STATE_ACTIVE",
      "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
      "SUBSCRIPTION_STATE_CANCELED",
    ]) {
      const ent = evaluate(subscription({ state }), PRODUCTS, NOW);
      expect([ent.status, ent.tier]).toEqual(["active", "3x"]);
    }
    const canceled = evaluate(
      subscription({ state: "SUBSCRIPTION_STATE_CANCELED" }),
      PRODUCTS,
      NOW,
    );
    expect(canceled.auto_renewing).toBe(false);
    expect(ENTITLED_STATES.has("SUBSCRIPTION_STATE_CANCELED")).toBe(true);
  });

  it("PENDING is pending; ON_HOLD/PAUSED/EXPIRED/PENDING_PURCHASE_CANCELED are expired", () => {
    const cases: Record<string, string> = {
      SUBSCRIPTION_STATE_PENDING: "pending",
      SUBSCRIPTION_STATE_ON_HOLD: "expired",
      SUBSCRIPTION_STATE_PAUSED: "expired",
      SUBSCRIPTION_STATE_EXPIRED: "expired",
      SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED: "expired",
    };
    for (const [state, status] of Object.entries(cases)) {
      const ent = evaluate(subscription({ state }), PRODUCTS, NOW);
      expect([ent.status, ent.tier]).toEqual([status, "free"]);
    }
    const past = evaluate(subscription({ expiry: NOW - 1 }), PRODUCTS, NOW);
    expect(past.tier).toBe("free");
  });

  it("an unknown productId never grants (400 unknown_product)", () => {
    expect(codeOf(() => evaluate(subscription({ product: "other" }), PRODUCTS, NOW))).toBe(
      "unknown_product",
    );
  });

  it("a non-object resource is 502 play_invalid_response", () => {
    for (const value of [null, "x", 42, []]) {
      try {
        evaluate(value, PRODUCTS, NOW);
        throw new Error("expected throw");
      } catch (err) {
        expect(err).toBeInstanceOf(BillingError);
        expect((err as BillingError).status).toBe(502);
        expect((err as BillingError).code).toBe("play_invalid_response");
      }
    }
  });

  it("two line items: highest TIER_RANK wins, then latest expiry", () => {
    const base = subscription();
    (base.lineItems as unknown[]) = [
      {
        productId: "ovid_max_monthly",
        expiryTime: iso(NOW + 10 * 86400),
        autoRenewingPlan: { autoRenewEnabled: true },
      },
      {
        productId: "ovid_plus_monthly",
        expiryTime: iso(NOW + 90 * 86400),
        autoRenewingPlan: { autoRenewEnabled: true },
      },
    ];
    expect(evaluate(base, PRODUCTS, NOW).tier).toBe("15x");

    (base.lineItems as unknown[]) = [
      {
        productId: "ovid_pro_monthly",
        expiryTime: iso(NOW + 10 * 86400),
        autoRenewingPlan: { autoRenewEnabled: true },
      },
      {
        productId: "ovid_pro_monthly",
        expiryTime: iso(NOW + 40 * 86400),
        autoRenewingPlan: { autoRenewEnabled: false },
      },
    ];
    const sameTier = evaluate(base, PRODUCTS, NOW);
    expect(sameTier.tier).toBe("7x");
    expect(sameTier.expires_at).toBe(NOW + 40 * 86400);
    expect(sameTier.auto_renewing).toBe(false);
  });

  it("carries linked token, account hash, acknowledgement and test purchase flags", () => {
    const ent: Entitlement = evaluate(
      subscription({ linked: "old-token", ack: true }),
      PRODUCTS,
      NOW,
    );
    expect(ent.linked_token).toBe("old-token");
    expect(ent.account_hash).toBe(accountHash("u1"));
    expect(ent.acknowledged).toBe(true);
    expect(ent.test_purchase).toBe(false);
    expect(ent.state).toBe("SUBSCRIPTION_STATE_ACTIVE");
    const test = subscription();
    test.testPurchase = {};
    expect(evaluate(test, PRODUCTS, NOW).test_purchase).toBe(true);
  });

  it("ignores line items with an unparseable expiry (expiry null ⇒ expired)", () => {
    const resource = subscription();
    (resource.lineItems as Record<string, unknown>[])[0]!.expiryTime = "garbage";
    const ent = evaluate(resource, PRODUCTS, NOW);
    expect(ent.expires_at).toBeNull();
    expect(ent.status).toBe("expired");
    expect(ent.tier).toBe("free");
  });
});
