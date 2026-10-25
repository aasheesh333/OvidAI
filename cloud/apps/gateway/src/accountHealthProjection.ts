/**
 * Pure account-health projection for the Flutter complete-facts contract.
 *
 * The caller supplies facts it actually read. This adapter performs no I/O,
 * reads no clock, and never turns a missing or malformed value into zero.
 * In particular, standing.multiIpFlags is not security evidence: only the
 * security projection's own flag count can produce a security verdict.
 */

export type AccountHealthFacts = Readonly<Record<string, unknown>>;

export interface AccountHealthDevicesProjection {
  readonly total: number | null;
  readonly active: number | null;
  readonly currentRegistration: boolean | null;
  /** Flutter's committed wire spelling. */
  readonly currentRegistered: boolean | null;
  readonly [key: string]: unknown;
}

export type AccountHealthSecurityStatus = "ok" | "healthy" | "attention" | "degraded";

export interface AccountHealthSecurityProjection {
  readonly status: AccountHealthSecurityStatus | null;
  readonly flags: number | null;
  readonly checkedAt: string | null;
  /** Flutter's committed wire spellings. */
  readonly multiIpFlags: number | null;
  readonly lastCheckedAt: string | null;
  readonly [key: string]: unknown;
}

export interface AccountHealthUploadsProjection {
  readonly count: number | null;
  readonly windowHours: number | null;
  readonly [key: string]: unknown;
}

export type AccountHealthStatusLabel =
  | "Healthy"
  | "Banned"
  | "Attention needed · Deletion scheduled"
  | "Attention needed · Storage almost full"
  | "Attention needed · Daily limit reached"
  | "Attention needed · Security degraded"
  | "Attention needed · Security review"
  | "Attention needed · Status unknown";

export interface AccountHealthProjection {
  readonly [key: string]: unknown;
  readonly plan: unknown;
  readonly storage: unknown;
  readonly usage: unknown;
  readonly standing: unknown;
  readonly devices: AccountHealthDevicesProjection;
  readonly security: AccountHealthSecurityProjection;
  /** All device, security, and upload display facts are known and well formed. */
  readonly complete: boolean;
  /** Known means complete evidence, not necessarily a verified-good verdict. */
  readonly known: boolean;
  readonly statusLabel: AccountHealthStatusLabel;
}

type FactRecord = Record<string, unknown>;

interface RawFact {
  readonly present: boolean;
  readonly value: unknown;
}

interface Fact<T> {
  readonly present: boolean;
  readonly value: T | null;
}

const MISSING: RawFact = { present: false, value: undefined };

function isRecord(value: unknown): value is FactRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasOwn(record: FactRecord, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(record, key);
}

function rawField(record: FactRecord, key: string): RawFact {
  if (!hasOwn(record, key) || record[key] === undefined) return MISSING;
  return { present: true, value: record[key] };
}

function typedFact<T>(raw: RawFact, parse: (value: unknown) => T | null): Fact<T> {
  return raw.present ? { present: true, value: parse(raw.value) } : { present: false, value: null };
}

function field<T>(
  record: FactRecord,
  key: string,
  parse: (value: unknown) => T | null,
): Fact<T> {
  return typedFact(rawField(record, key), parse);
}

function aliasedField<T>(
  record: FactRecord,
  keys: readonly string[],
  parse: (value: unknown) => T | null,
): Fact<T> {
  for (const key of keys) {
    const raw = rawField(record, key);
    if (raw.present) return typedFact(raw, parse);
  }
  return { present: false, value: null };
}

/** A present malformed fact wins over a fallback; only an absent fact falls back. */
function fallback<T>(primary: Fact<T>, secondary: Fact<T>): Fact<T> {
  return primary.present ? primary : secondary;
}

function count(value: unknown): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
    ? value
    : null;
}

function booleanValue(value: unknown): boolean | null {
  return typeof value === "boolean" ? value : null;
}

function text(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed === "" ? null : trimmed;
}

function timestamp(value: unknown): string | null {
  if (value instanceof Date) {
    return Number.isFinite(value.getTime()) ? value.toISOString() : null;
  }
  const raw = text(value);
  return raw !== null && Number.isFinite(Date.parse(raw)) ? raw : null;
}

function securityStatus(value: unknown): AccountHealthSecurityStatus | null {
  const normalized = text(value)?.toLowerCase();
  return normalized === "ok" || normalized === "healthy" ||
      normalized === "attention" || normalized === "degraded"
    ? normalized
    : null;
}

function deviceRows(value: unknown): readonly unknown[] | null {
  if (Array.isArray(value)) return value;
  if (isRecord(value) && Array.isArray(value.rows)) return value.rows;
  return null;
}

function activeDeviceCount(rows: readonly unknown[]): number | null {
  if (rows.length === 0) return null;
  let active = 0;
  for (const row of rows) {
    if (!isRecord(row)) return null;
    const value = field(row, "active", booleanValue);
    if (!value.present || value.value === null) return null;
    if (value.value) active += 1;
  }
  return active;
}

function currentDeviceRegistration(rows: readonly unknown[]): boolean | null {
  if (rows.length === 0) return null;
  let registered = false;
  for (const row of rows) {
    if (!isRecord(row)) return null;
    const value = aliasedField(row, ["currentRegistration", "currentRegistered"], booleanValue);
    if (!value.present || value.value === null) return null;
    if (value.value) registered = true;
  }
  return registered;
}

function projectDevices(
  value: unknown,
  currentRegistration: Fact<boolean>,
): { value: AccountHealthDevicesProjection; complete: boolean } {
  const summary = isRecord(value) ? value : {};
  const rows = deviceRows(value);

  let total = aliasedField(summary, ["total", "count"], count);
  let active = field(summary, "active", count);
  let registration = aliasedField(
    summary,
    ["currentRegistration", "currentRegistered"],
    booleanValue,
  );
  registration = fallback(registration, currentRegistration);

  if (!total.present && rows !== null) {
    total = { present: true, value: rows.length };
  }
  if (!active.present && rows !== null) {
    active = { present: true, value: activeDeviceCount(rows) };
  }
  if (!registration.present && rows !== null) {
    registration = { present: true, value: currentDeviceRegistration(rows) };
  }

  // A null device source is unknown, never an empty device ledger. Likewise,
  // currentRegistration says nothing by itself about total/active counts.

  const consistent =
    (total.value === null || active.value === null || active.value <= total.value) &&
    !(total.value === 0 && registration.value === true);
  const complete =
    total.present && total.value !== null &&
    active.present && active.value !== null &&
    registration.present && registration.value !== null &&
    consistent;

  return {
    value: {
      ...summary,
      total: total.value,
      active: active.value,
      currentRegistration: registration.value,
      currentRegistered: registration.value,
    },
    complete,
  };
}

function projectSecurity(value: unknown): {
  value: AccountHealthSecurityProjection;
  complete: boolean;
  verifiedGood: boolean;
  attention: "degraded" | "review" | null;
} {
  const source = isRecord(value) ? value : {};
  const status = field(source, "status", securityStatus).value;
  const flags = aliasedField(source, ["flags", "multiIpFlags"], count).value;
  const checkedAt = aliasedField(source, ["checkedAt", "lastCheckedAt"], timestamp).value;
  const complete = status !== null && flags !== null && checkedAt !== null;
  const verifiedGood = complete &&
    (status === "ok" || status === "healthy") && flags === 0;
  const attention = complete && status === "degraded"
    ? "degraded"
    : complete && (status === "attention" || (flags !== null && flags > 0))
      ? "review"
      : null;

  return {
    value: {
      ...source,
      status,
      flags,
      checkedAt,
      multiIpFlags: flags,
      lastCheckedAt: checkedAt,
    },
    complete,
    verifiedGood,
    attention,
  };
}

function projectPlan(value: unknown): {
  readonly value: unknown;
  readonly uploads: AccountHealthUploadsProjection;
} {
  if (!isRecord(value)) {
    return {
      value: value ?? null,
      uploads: { count: null, windowHours: null },
    };
  }

  const limits = isRecord(value.limits) ? value.limits : null;
  const source = limits !== null && isRecord(limits.uploads) ? limits.uploads : {};
  // Committed Flutter reads only plan.limits.uploads.count/windowHours. Other
  // spellings and top-level upload sources are not evidence for this projection.
  const uploads: AccountHealthUploadsProjection = {
    ...source,
    count: field(source, "count", count).value,
    windowHours: field(source, "windowHours", count).value,
  };

  return {
    value: limits === null
      ? { ...value }
      : { ...value, limits: { ...limits, uploads } },
    uploads,
  };
}

type AccountStatus = "active" | "deletionPending" | "banned" | null;

function deletionFact(value: unknown): { known: boolean; pending: boolean | null } {
  if (!isRecord(value)) return { known: false, pending: null };
  const state = field(value, "state", text);
  const pending = field(value, "pending", booleanValue);
  const deleteAfter = field(value, "deleteAfter", timestamp);
  return {
    known:
      (state.present && state.value !== null) ||
      (pending.present && pending.value !== null) ||
      (deleteAfter.present && deleteAfter.value !== null),
    pending: pending.value,
  };
}

function accountStatus(value: unknown): AccountStatus {
  const standing = isRecord(value) ? value : {};
  const banned = field(standing, "banned", booleanValue).value;
  const deletion = deletionFact(standing.deletion);

  if (banned === true) return "banned";
  if (deletion.pending === true) return "deletionPending";
  if (banned === null) return null;
  if (!deletion.known) return "active";
  if (deletion.pending === null) return null;
  return "active";
}

function storageFraction(value: unknown): number | null {
  if (!isRecord(value)) return null;
  const used = field(value, "usedBytes", count).value;
  const quota = field(value, "quotaBytes", count).value;
  if (used === null || quota === null || quota <= 0) return null;
  return Math.min(1, Math.max(0, used / quota));
}

function dailyUsageFraction(value: unknown): number | null {
  if (!isRecord(value)) return null;
  const today = isRecord(value.today) ? value.today : {};
  const used = field(today, "tokensUsed", count).value;
  const cap = field(today, "tokenCap", count).value;
  if (used === null || cap === null || cap <= 0) return null;
  return Math.min(1, Math.max(0, used / cap));
}

function statusLabel(input: {
  readonly standing: unknown;
  readonly storage: unknown;
  readonly usage: unknown;
  readonly complete: boolean;
  readonly securityVerifiedGood: boolean;
  readonly securityAttention: "degraded" | "review" | null;
}): AccountHealthStatusLabel {
  const standing = accountStatus(input.standing);
  if (standing === "banned") return "Banned";
  if (standing === "deletionPending") return "Attention needed · Deletion scheduled";
  if ((storageFraction(input.storage) ?? 0) >= 0.9) {
    return "Attention needed · Storage almost full";
  }
  if ((dailyUsageFraction(input.usage) ?? 0) >= 1) {
    return "Attention needed · Daily limit reached";
  }
  if (input.securityAttention === "degraded") {
    return "Attention needed · Security degraded";
  }
  if (input.securityAttention === "review") {
    return "Attention needed · Security review";
  }
  if (standing === null || !input.complete || !input.securityVerifiedGood) {
    return "Attention needed · Status unknown";
  }
  return "Healthy";
}

/**
 * Add the device/security projection and canonical nested plan upload facts
 * to the already-read account DTO. Existing plan, storage, usage, standing,
 * entitlement, and unrelated additive fields are retained. Alternate
 * top-level upload sources are excluded and derived verdicts are recomputed.
 */
export function projectAccountHealth(input: AccountHealthFacts): AccountHealthProjection {
  const facts: FactRecord = isRecord(input) ? input : {};
  const currentRegistration = field(facts, "currentRegistration", booleanValue);
  const devices = projectDevices(facts.devices, currentRegistration);
  const security = projectSecurity(facts.security);
  const plan = projectPlan(facts.plan);
  const uploadsComplete =
    plan.uploads.count !== null && plan.uploads.windowHours !== null;
  const complete = devices.complete && security.complete && uploadsComplete;

  // Flutter ignores these alternate top-level upload sources. Exclude them
  // from the projected DTO too, so a partial canonical plan cannot be hidden
  // by a second top-level representation. Derived verdict inputs below are
  // always overwritten from canonical facts rather than trusted.
  const existingFacts = { ...facts };
  delete existingFacts.uploads;
  delete existingFacts.uploadWindow;

  return {
    ...existingFacts,
    plan: plan.value,
    storage: facts.storage ?? null,
    usage: facts.usage ?? null,
    standing: facts.standing ?? null,
    devices: devices.value,
    security: security.value,
    complete,
    known: complete,
    statusLabel: statusLabel({
      standing: facts.standing,
      storage: facts.storage,
      usage: facts.usage,
      complete,
      securityVerifiedGood: security.verifiedGood,
      securityAttention: security.attention,
    }),
  };
}
