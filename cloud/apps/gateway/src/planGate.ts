/**
 * Plan entitlement gate (P3).
 *
 * The single source of truth for what a plan may use on the gateway. The UI
 * greys out manual models and hides connector slots, but these checks are the
 * security boundary: a client that sends a manual model id or opens an extra
 * connector must be refused here.
 *
 * Product truth (spec §11):
 *   Free  $0   3 GB  Auto only  0 custom connectors
 *   Go    $5   5 GB  Auto only  5 custom connectors
 *   Plus  $18 15 GB  Auto + manual  20 custom connectors
 *   Pro   $99 75 GB  Auto + manual  20 custom connectors
 *
 * Unknown/missing tiers fail closed to Free. Callers pass `users.tier` (or a
 * RevenueCat entitlement mapped to one of the canonical ids).
 */

import { PLAN_STORAGE_BYTES, resolveStoragePlan } from "@ovid/storage";

const GB = 1024 ** 3;

export const PLAN_TIERS = ["free", "go", "plus", "pro"] as const;
export type PlanTier = (typeof PLAN_TIERS)[number];

export interface PlanEntitlements {
  readonly tier: PlanTier;
  readonly displayName: string;
  /** Quota as shown in the product ("3 GB"). Bytes use binary GB. */
  readonly storageQuotaGb: number;
  readonly storageQuotaBytes: number;
  readonly customConnectorLimit: number;
  readonly manualModels: boolean;
  /** True for Free/Go: only the Auto route may be selected. */
  readonly autoModelsOnly: boolean;
}

function entitlement(
  tier: PlanTier,
  displayName: string,
  storageQuotaGb: number,
  customConnectorLimit: number,
  manualModels: boolean,
): PlanEntitlements {
  return Object.freeze({
    tier,
    displayName,
    storageQuotaGb,
    storageQuotaBytes: PLAN_STORAGE_BYTES[tier],
    customConnectorLimit,
    manualModels,
    autoModelsOnly: !manualModels,
  });
}

export const PLAN_ENTITLEMENTS: Readonly<Record<PlanTier, PlanEntitlements>> = Object.freeze({
  free: entitlement("free", "Free", 3, 0, false),
  go: entitlement("go", "Ovid Go", 5, 5, false),
  plus: entitlement("plus", "Ovid Plus", 15, 20, true),
  pro: entitlement("pro", "Ovid Pro", 75, 20, true),
});

export type PlanGateErrorCode =
  | "manual_model_not_allowed"
  | "connector_limit_reached"
  | "storage_quota_exceeded"
  | "upload_limit_reached";

/** Common base so route handlers can map every plan refusal in one place. */
export class PlanGateError extends Error {
  constructor(
    readonly code: PlanGateErrorCode,
    readonly status: number,
    message: string,
    readonly details: Readonly<Record<string, unknown>> = {},
  ) {
    super(message);
    this.name = "PlanGateError";
  }
}

/** Free/Go received an explicit model id instead of Auto. */
export class ManualModelNotAllowedError extends PlanGateError {
  constructor(
    readonly tier: PlanTier,
    readonly requestedModel: string,
  ) {
    super(
      "manual_model_not_allowed",
      403,
      "Manual models require Ovid Plus or Ovid Pro. Free and Ovid Go use Auto only.",
      { tier, requestedModel, requiredPlans: ["plus", "pro"] },
    );
    this.name = "ManualModelNotAllowedError";
  }
}

/** The plan's custom-connector slots are already full (Free has none). */
export class ConnectorLimitReachedError extends PlanGateError {
  constructor(
    readonly tier: PlanTier,
    readonly currentCount: number,
    readonly limit: number,
  ) {
    super(
      "connector_limit_reached",
      403,
      limit === 0
        ? "Custom connectors are not included on the Free plan."
        : `Your plan includes ${limit} custom connector${limit === 1 ? "" : "s"}. Delete one before adding another.`,
      { tier, currentCount, limit },
    );
    this.name = "ConnectorLimitReachedError";
  }
}

/** An upload would push account storage past the plan quota. */
export class StorageQuotaExceededError extends PlanGateError {
  constructor(
    readonly tier: PlanTier,
    readonly quotaBytes: number,
    readonly usedBytes: number,
    readonly incomingBytes: number,
  ) {
    const quotaGb = quotaBytes / GB;
    super(
      "storage_quota_exceeded",
      403,
      `This would exceed your plan's ${quotaGb} GB cloud storage. Delete files or upgrade to continue.`,
      { tier, quotaBytes, usedBytes, incomingBytes },
    );
    this.name = "StorageQuotaExceededError";
  }
}

function assertByteCount(value: number, label: string): void {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new RangeError(`${label} must be a non-negative safe integer`);
  }
}

function assertConnectorCount(value: number): void {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new RangeError("connector count must be a non-negative integer");
  }
}

/**
 * Canonicalize a stored tier/entitlement id. Accepts the canonical ids and
 * their display names ("Ovid Plus"); anything else is Free (fail closed).
 */
export function normalizePlanTier(raw: string | null | undefined): PlanTier {
  return resolveStoragePlan(raw);
}

export function planFor(raw: string | null | undefined): PlanEntitlements {
  return PLAN_ENTITLEMENTS[normalizePlanTier(raw)];
}

export function storageQuotaBytesFor(raw: string | null | undefined): number {
  return planFor(raw).storageQuotaBytes;
}

/** `true` for absent, empty or "auto" (including an "auto · high" effort suffix). */
export function isAutoModel(requested: string | null | undefined): boolean {
  if (requested === null || requested === undefined) return true;
  const trimmed = requested.trim();
  if (trimmed === "") return true;
  const base = trimmed.toLowerCase().split("·")[0]!.trim();
  return base === "auto";
}

/**
 * Throw [ManualModelNotAllowedError] when a Free/Go request names an explicit
 * model. Auto (absent, empty or "auto[…]") is always allowed.
 */
export function assertModelAllowed(
  rawTier: string | null | undefined,
  requestedModel: string | null | undefined,
): void {
  const plan = planFor(rawTier);
  if (plan.manualModels || isAutoModel(requestedModel)) return;
  throw new ManualModelNotAllowedError(plan.tier, requestedModel!.trim());
}

/**
 * Throw [ConnectorLimitReachedError] unless the account has a free custom
 * connector slot. `currentCount` must be the count of the user's custom
 * (non-curated) connectors before the create.
 */
export function assertConnectorSlotAvailable(
  rawTier: string | null | undefined,
  currentCount: number,
): void {
  assertConnectorCount(currentCount);
  const plan = planFor(rawTier);
  if (currentCount < plan.customConnectorLimit) return;
  throw new ConnectorLimitReachedError(plan.tier, currentCount, plan.customConnectorLimit);
}

/** Remaining account storage in bytes, clamped at zero. */
export function remainingStorageBytes(
  rawTier: string | null | undefined,
  usedBytes: number,
): number {
  assertByteCount(usedBytes, "usedBytes");
  return Math.max(0, storageQuotaBytesFor(rawTier) - usedBytes);
}

/**
 * Throw [StorageQuotaExceededError] when `usedBytes + incomingBytes` exceeds
 * the plan quota. Exactly at the quota is allowed; zero-byte reads/updates
 * still fail if the account is already over quota.
 */
export function assertStorageAvailable(
  rawTier: string | null | undefined,
  usedBytes: number,
  incomingBytes = 0,
): void {
  assertByteCount(usedBytes, "usedBytes");
  assertByteCount(incomingBytes, "incomingBytes");
  const plan = planFor(rawTier);
  const remaining = Math.max(0, plan.storageQuotaBytes - usedBytes);
  if (usedBytes <= plan.storageQuotaBytes && incomingBytes <= remaining) return;
  throw new StorageQuotaExceededError(plan.tier, plan.storageQuotaBytes, usedBytes, incomingBytes);
}
