import { describe, expect, it } from "vitest";
import {
  ConnectorLimitReachedError,
  ManualModelNotAllowedError,
  PLAN_ENTITLEMENTS,
  PlanGateError,
  StorageQuotaExceededError,
  assertConnectorSlotAvailable,
  assertModelAllowed,
  assertStorageAvailable,
  normalizePlanTier,
  planFor,
  remainingStorageBytes,
  storageQuotaBytesFor,
} from "./planGate.js";

const GB = 1024 ** 3;

describe("plan entitlements", () => {
  it("pins storage, custom connectors and manual models for every plan", () => {
    expect(PLAN_ENTITLEMENTS.free).toMatchObject({
      tier: "free",
      storageQuotaGb: 3,
      storageQuotaBytes: 3 * GB,
      customConnectorLimit: 0,
      manualModels: false,
    });
    expect(PLAN_ENTITLEMENTS.go).toMatchObject({
      tier: "go",
      storageQuotaGb: 5,
      storageQuotaBytes: 5 * GB,
      customConnectorLimit: 5,
      manualModels: false,
    });
    expect(PLAN_ENTITLEMENTS.plus).toMatchObject({
      tier: "plus",
      storageQuotaGb: 15,
      storageQuotaBytes: 15 * GB,
      customConnectorLimit: 20,
      manualModels: true,
    });
    expect(PLAN_ENTITLEMENTS.pro).toMatchObject({
      tier: "pro",
      storageQuotaGb: 75,
      storageQuotaBytes: 75 * GB,
      customConnectorLimit: 20,
      manualModels: true,
    });
  });

  it("normalizes plan ids and display names; unknown tiers fail closed to Free", () => {
    expect(normalizePlanTier("free")).toBe("free");
    expect(normalizePlanTier("  GO ")).toBe("go");
    expect(normalizePlanTier("Ovid Plus")).toBe("plus");
    expect(normalizePlanTier("ovid pro")).toBe("pro");
    expect(normalizePlanTier("PRO")).toBe("pro");
    // Legacy ids resolve to the same four plans (shared with @ovid/storage).
    expect(normalizePlanTier("3x")).toBe("go");
    expect(normalizePlanTier("starter")).toBe("go");
    expect(normalizePlanTier("7x")).toBe("plus");
    expect(normalizePlanTier("15x")).toBe("pro");
    expect(normalizePlanTier("max")).toBe("pro");
    expect(normalizePlanTier("team")).toBe("free");
    expect(normalizePlanTier("")).toBe("free");
    expect(normalizePlanTier(null)).toBe("free");
    expect(normalizePlanTier(undefined)).toBe("free");
  });

  it("returns the matching immutable entitlement set", () => {
    expect(planFor("go")).toBe(PLAN_ENTITLEMENTS.go);
    expect(planFor("nonsense")).toBe(PLAN_ENTITLEMENTS.free);
  });
});

describe("manual model gate", () => {
  it("allows Auto for Free and Go", () => {
    for (const tier of ["free", "go"] as const) {
      expect(() => assertModelAllowed(tier, undefined)).not.toThrow();
      expect(() => assertModelAllowed(tier, null)).not.toThrow();
      expect(() => assertModelAllowed(tier, "auto")).not.toThrow();
      expect(() => assertModelAllowed(tier, " AUTO ")).not.toThrow();
      expect(() => assertModelAllowed(tier, "auto · high")).not.toThrow();
    }
  });

  it("rejects a manual model on Free with a typed error", () => {
    try {
      assertModelAllowed("free", "gpt-5.3");
      expect.unreachable("Free must reject manual models");
    } catch (error) {
      expect(error).toBeInstanceOf(ManualModelNotAllowedError);
      expect(error).toBeInstanceOf(PlanGateError);
      const gate = error as ManualModelNotAllowedError;
      expect(gate.code).toBe("manual_model_not_allowed");
      expect(gate.status).toBe(403);
      expect(gate.tier).toBe("free");
      expect(gate.requestedModel).toBe("gpt-5.3");
      expect(gate.details).toMatchObject({ tier: "free", requiredPlans: ["plus", "pro"] });
      expect(gate.message).toMatch(/Plus or Ovid Pro/);
    }
  });

  it("rejects a manual model on Go", () => {
    expect(() => assertModelAllowed("go", "claude-sonnet-5")).toThrow(ManualModelNotAllowedError);
  });

  it("allows manual models on Plus and Pro", () => {
    for (const tier of ["plus", "pro"] as const) {
      expect(() => assertModelAllowed(tier, "gpt-5.3")).not.toThrow();
      expect(() => assertModelAllowed(tier, "auto")).not.toThrow();
    }
  });
});

describe("custom connector slot gate", () => {
  it("refuses every custom connector on Free", () => {
    try {
      assertConnectorSlotAvailable("free", 0);
      expect.unreachable("Free must refuse custom connectors");
    } catch (error) {
      expect(error).toBeInstanceOf(ConnectorLimitReachedError);
      expect(error).toBeInstanceOf(PlanGateError);
      const gate = error as ConnectorLimitReachedError;
      expect(gate.code).toBe("connector_limit_reached");
      expect(gate.status).toBe(403);
      expect(gate.tier).toBe("free");
      expect(gate.limit).toBe(0);
      expect(gate.currentCount).toBe(0);
      expect(gate.message).toMatch(/not included on the Free plan/);
    }
  });

  it("allows Go up to 5 connectors and refuses the 6th", () => {
    for (const count of [0, 1, 4]) {
      expect(() => assertConnectorSlotAvailable("go", count)).not.toThrow();
    }
    expect(() => assertConnectorSlotAvailable("go", 5)).toThrow(ConnectorLimitReachedError);
  });

  it("allows Plus and Pro up to 20 connectors and refuses the 21st", () => {
    for (const tier of ["plus", "pro"] as const) {
      expect(() => assertConnectorSlotAvailable(tier, 19)).not.toThrow();
      expect(() => assertConnectorSlotAvailable(tier, 20)).toThrow(ConnectorLimitReachedError);
    }
  });

  it("rejects an impossible connector count", () => {
    expect(() => assertConnectorSlotAvailable("go", -1)).toThrow(RangeError);
    expect(() => assertConnectorSlotAvailable("go", 1.5)).toThrow(RangeError);
  });
});

describe("storage quota gate", () => {
  it("exposes the plan quota in bytes", () => {
    expect(storageQuotaBytesFor("free")).toBe(3 * GB);
    expect(storageQuotaBytesFor("go")).toBe(5 * GB);
    expect(storageQuotaBytesFor("plus")).toBe(15 * GB);
    expect(storageQuotaBytesFor("pro")).toBe(75 * GB);
  });

  it("allows bytes exactly up to the Free quota and refuses one byte more", () => {
    expect(() => assertStorageAvailable("free", 0, 3 * GB)).not.toThrow();
    expect(() => assertStorageAvailable("free", 3 * GB, 0)).not.toThrow();

    try {
      assertStorageAvailable("free", 3 * GB, 1);
      expect.unreachable("Free storage quota must be enforced");
    } catch (error) {
      expect(error).toBeInstanceOf(StorageQuotaExceededError);
      expect(error).toBeInstanceOf(PlanGateError);
      const gate = error as StorageQuotaExceededError;
      expect(gate.code).toBe("storage_quota_exceeded");
      expect(gate.status).toBe(403);
      expect(gate.tier).toBe("free");
      expect(gate.quotaBytes).toBe(3 * GB);
      expect(gate.usedBytes).toBe(3 * GB);
      expect(gate.incomingBytes).toBe(1);
      expect(gate.message).toMatch(/3 GB/);
    }
  });

  it("enforces the Go, Plus and Pro quotas", () => {
    expect(() => assertStorageAvailable("go", 5 * GB - 10, 10)).not.toThrow();
    expect(() => assertStorageAvailable("go", 5 * GB - 10, 11)).toThrow(StorageQuotaExceededError);

    expect(() => assertStorageAvailable("plus", 15 * GB - 10, 10)).not.toThrow();
    expect(() => assertStorageAvailable("plus", 15 * GB - 10, 11)).toThrow(StorageQuotaExceededError);

    expect(() => assertStorageAvailable("pro", 75 * GB - 10, 10)).not.toThrow();
    expect(() => assertStorageAvailable("pro", 75 * GB - 10, 11)).toThrow(StorageQuotaExceededError);
  });

  it("refuses when usage is already over quota even with no new bytes", () => {
    expect(() => assertStorageAvailable("free", 3 * GB + 1, 0)).toThrow(StorageQuotaExceededError);
  });

  it("reports remaining bytes clamped at zero", () => {
    expect(remainingStorageBytes("go", 1 * GB)).toBe(4 * GB);
    expect(remainingStorageBytes("go", 5 * GB)).toBe(0);
    expect(remainingStorageBytes("go", 6 * GB)).toBe(0);
  });

  it("rejects invalid byte counts", () => {
    expect(() => assertStorageAvailable("go", -1, 0)).toThrow(RangeError);
    expect(() => assertStorageAvailable("go", 0, -1)).toThrow(RangeError);
    expect(() => assertStorageAvailable("go", 0.5, 0)).toThrow(RangeError);
    expect(() => remainingStorageBytes("go", Number.NaN)).toThrow(RangeError);
  });
});
