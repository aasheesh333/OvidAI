import { describe, expect, it, vi } from "vitest";
import { BillingError } from "./domain.js";
import type { RevenueCatEvent } from "./entitlements.js";
import {
  constantTimeSecretEqual,
  createRevenueCatWebhook,
  parseRevenueCatEvent,
} from "./revenuecatWebhook.js";

const SECRET = "rc-webhook-test-secret";
const NOW_MS = 1_800_000_000_000;

function envelope(overrides: Record<string, unknown> = {}): unknown {
  return {
    event: {
      id: "event-1",
      type: "INITIAL_PURCHASE",
      event_timestamp_ms: NOW_MS,
      app_user_id: "user-1",
      original_app_user_id: "user-1",
      original_transaction_id: "transaction-1",
      product_id: "ovid_pro_yearly",
      expiration_at_ms: NOW_MS + 365 * 86_400_000,
      auto_renew_status: true,
      environment: "PRODUCTION",
      // These client/store display fields are deliberately not authority.
      price: 0.01,
      currency: "XXX",
      period: "monthly",
      ...overrides,
    },
  };
}

describe("RevenueCat webhook authentication and parsing", () => {
  it("uses the constant-time comparison for same-length and different-length secrets", () => {
    expect(constantTimeSecretEqual(SECRET, SECRET)).toBe(true);
    expect(constantTimeSecretEqual("wrong", SECRET)).toBe(false);
    expect(constantTimeSecretEqual(`${SECRET}-longer`, SECRET)).toBe(false);
    expect(constantTimeSecretEqual("", SECRET)).toBe(false);
    expect(constantTimeSecretEqual(SECRET, "")).toBe(false);
  });

  it("accepts the configured Authorization value and Bearer form", async () => {
    const process = vi.fn(async (_event: RevenueCatEvent) => ({
      status: "applied" as const,
      entitlement: {
        tier: "plus" as const,
        productId: "ovid_pro_yearly",
        period: "yearly" as const,
        expiresAt: NOW_MS / 1000 + 365 * 86_400,
        autoRenewing: true,
        purchaseState: "active" as const,
      },
    }));
    const handle = createRevenueCatWebhook({ secret: SECRET, process });

    const direct = await handle(SECRET, envelope());
    const bearer = await handle(`Bearer ${SECRET}`, envelope());
    expect(direct.status).toBe(200);
    expect(bearer.status).toBe(200);
    expect(direct.payload).toMatchObject({ ok: true, status: "applied" });
    expect(process).toHaveBeenCalledTimes(2);
  });

  it("rejects a wrong secret through the same comparison path without processing", async () => {
    const process = vi.fn();
    const handle = createRevenueCatWebhook({ secret: SECRET, process });
    const response = await handle("wrong-length", envelope());
    expect(response).toEqual({
      status: 401,
      payload: { ok: false, error: { code: "unauthorized" } },
    });
    expect(process).not.toHaveBeenCalled();
  });

  it("fails closed when webhook authorization is unconfigured", async () => {
    const process = vi.fn();
    const handle = createRevenueCatWebhook({ secret: null, process });
    expect((await handle(SECRET, envelope())).status).toBe(503);
    expect(process).not.toHaveBeenCalled();
  });

  it("parses server-verified fields and drops price/client period text", async () => {
    const process = vi.fn(async (_event: RevenueCatEvent) => ({
      status: "applied" as const,
      entitlement: {
        tier: "free" as const,
        productId: null,
        period: null,
        expiresAt: null,
        autoRenewing: false,
        purchaseState: "unknown" as const,
      },
    }));
    const handle = createRevenueCatWebhook({ secret: SECRET, process });
    await handle(SECRET, envelope());

    const event = process.mock.calls[0]![0];
    expect(event).toEqual({
      id: "event-1",
      type: "INITIAL_PURCHASE",
      occurredAt: NOW_MS / 1000,
      appUserId: "user-1",
      transactionId: "transaction-1",
      productId: "ovid_pro_yearly",
      expiresAt: NOW_MS / 1000 + 365 * 86_400,
      autoRenewing: true,
      cancelReason: null,
      environment: "PRODUCTION",
    });
    expect(event).not.toHaveProperty("price");
    expect(event).not.toHaveProperty("period");
  });

  it("preserves RevenueCat millisecond ordering when converting to epoch seconds", async () => {
    const process = vi.fn(async (event: RevenueCatEvent) => ({
      status: "applied" as const,
      entitlement: {
        tier: "free" as const,
        productId: null,
        period: null,
        expiresAt: null,
        autoRenewing: false,
        purchaseState: "unknown" as const,
      },
    }));
    const handle = createRevenueCatWebhook({ secret: SECRET, process });
    await handle(SECRET, envelope({ event_timestamp_ms: NOW_MS + 900 }));
    expect(process.mock.calls[0]![0].occurredAt).toBe(NOW_MS / 1000 + 0.9);
  });

  it("rejects malformed events instead of guessing an entitlement", async () => {
    const process = vi.fn();
    const handle = createRevenueCatWebhook({ secret: SECRET, process });
    for (const body of [null, {}, { event: {} }, envelope({ id: "" }), envelope({ event_timestamp_ms: "now" })]) {
      const response = await handle(SECRET, body);
      expect(response.status).toBe(400);
      expect(response.payload).toEqual({ ok: false, error: { code: "invalid_event" } });
    }
    expect(process).not.toHaveBeenCalled();
  });

  it("maps known contract errors and hides unexpected processing failures", async () => {
    const unknown = createRevenueCatWebhook({
      secret: SECRET,
      process: async () => {
        throw new BillingError(400, "unknown_product");
      },
    });
    expect(await unknown(SECRET, envelope())).toEqual({
      status: 400,
      payload: { ok: false, error: { code: "unknown_product" } },
    });

    const broken = createRevenueCatWebhook({
      secret: SECRET,
      process: async () => {
        throw new Error("database credentials must not leak");
      },
    });
    const response = await broken(SECRET, envelope());
    expect(response.status).toBe(503);
    expect(JSON.stringify(response.payload)).not.toContain("database credentials");
  });

  it("parses the official TRANSFER fixture using transferred_from/to only", () => {
    const parsed = parseRevenueCatEvent({
      event: {
        app_id: "1234567890",
        event_timestamp_ms: 78789789798798,
        id: "CD489E0E-5D52-4E03-966B-A7F17788E432",
        store: "APP_STORE",
        transferred_from: ["00005A1C-6091-4F81-BE77-F0A83A271AB6"],
        transferred_to: ["4BEDB450-8EF2-11E9-B475-0800200C9A66"],
        type: "TRANSFER",
        environment: "PRODUCTION",
      },
      api_version: "1.0",
    });
    expect(parsed).toEqual({
      id: "CD489E0E-5D52-4E03-966B-A7F17788E432",
      type: "TRANSFER",
      occurredAt: 78789789798798 / 1000,
      appUserId: "4BEDB450-8EF2-11E9-B475-0800200C9A66",
      transferredFrom: ["00005A1C-6091-4F81-BE77-F0A83A271AB6"],
      transactionId: null,
      productId: null,
      expiresAt: null,
      autoRenewing: null,
      cancelReason: null,
      environment: "PRODUCTION",
    });
  });

  it("parses official BILLING_ISSUE grace and PRODUCT_CHANGE deferred fields", () => {
    const billingIssue = parseRevenueCatEvent({
      event: {
        event_timestamp_ms: 1601337601013,
        product_id: "com.revenuecat.myapp.monthly",
        period_type: "NORMAL",
        purchased_at_ms: 1598640647000,
        expiration_at_ms: 1601319047000,
        grace_period_expiration_at_ms: 1601933447000,
        environment: "PRODUCTION",
        transaction_id: "100000000000002",
        original_transaction_id: "100000000000000",
        app_user_id: "$RCAnonymousID:12345678-1234-1234-1234-123456789123",
        original_app_user_id: "$RCAnonymousID:12345678-1234-1234-1234-123456789123",
        store: "APP_STORE",
        type: "BILLING_ISSUE",
        id: "12345678-1234-1234-1234-12345678912",
        app_id: "1234567890",
      },
      api_version: "1.0",
    });
    expect(billingIssue).toMatchObject({
      environment: "PRODUCTION",
      expiresAt: 1601319047,
      gracePeriodExpiresAt: 1601933447,
    });

    const change = parseRevenueCatEvent({
      event: {
        event_timestamp_ms: 1601338594769,
        product_id: "com.revenuecat.myapp.monthly",
        period_type: "NORMAL",
        purchased_at_ms: 1601304429682,
        expiration_at_ms: 1601311606660,
        environment: "PRODUCTION",
        transaction_id: "GPA.1234-1234-1234-12345",
        original_transaction_id: "GPA.1234-1234-1234-12345",
        app_user_id: "$RCAnonymousID:12345678-1234-1234-1234-123456789123",
        original_app_user_id: "$RCAnonymousID:12345678-1234-1234-1234-123456789123",
        new_product_id: "com.revenuecat.myapp.yearly",
        store: "PLAY_STORE",
        type: "PRODUCT_CHANGE",
        id: "12345678-1234-1234-1234-12345678912",
        app_id: "1234567890",
      },
      api_version: "1.0",
    });
    expect(change).toMatchObject({
      productId: "com.revenuecat.myapp.monthly",
      newProductId: "com.revenuecat.myapp.yearly",
      environment: "PRODUCTION",
    });
  });

  it("keeps optional auto_renew_status unknown and parses only explicit booleans", () => {
    for (const type of ["RENEWAL", "SUBSCRIPTION_EXTENDED", "BILLING_ISSUE", "REFUND_REVERSED"]) {
      const parsed = parseRevenueCatEvent(envelope({ type, auto_renew_status: undefined }));
      expect(parsed).not.toBeNull();
      expect(parsed!.autoRenewing).toBeNull();
    }
    expect(parseRevenueCatEvent(envelope({ auto_renew_status: false }))!.autoRenewing).toBe(false);
    expect(parseRevenueCatEvent(envelope({ auto_renew_status: true }))!.autoRenewing).toBe(true);
    expect(parseRevenueCatEvent(envelope({ auto_renew_status: "true" }))).toBeNull();
    expect(parseRevenueCatEvent(envelope({ auto_renew_status: null }))).toBeNull();
  });

  it("parses official SUBSCRIPTION_EXTENDED and REFUND_REVERSED events", () => {
    for (const type of ["SUBSCRIPTION_EXTENDED", "REFUND_REVERSED"] as const) {
      const parsed = parseRevenueCatEvent({
        event: {
          event_timestamp_ms: 1697451462232,
          product_id: "com.subscription.weekly",
          period_type: "NORMAL",
          purchased_at_ms: 1696846623000,
          expiration_at_ms: 1697451423000,
          environment: "PRODUCTION",
          transaction_id: "123456789012345",
          original_transaction_id: "123456789012345",
          app_user_id: "1234567890",
          original_app_user_id: "1234567890",
          store: "APP_STORE",
          type,
          id: "12345678-1234-1234-1234-123456789012",
          app_id: "1234567890",
        },
        api_version: "1.0",
      });
      expect(parsed).toMatchObject({
        type,
        environment: "PRODUCTION",
        productId: "com.subscription.weekly",
        expiresAt: 1697451423,
      });
    }
  });
});
