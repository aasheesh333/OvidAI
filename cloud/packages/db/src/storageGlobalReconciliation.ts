import { createHash } from "node:crypto";

import type { Db } from "./client.js";

/**
 * UNWIRED read-only global storage discovery.
 *
 * There is deliberately no storage adapter, mutation repository, apply function,
 * cursor store, or report store in this module. Every SQL statement is a bounded
 * SELECT. A page is a fresh observation, not a fleet snapshot or approval to act.
 */

export const GLOBAL_STORAGE_STREAMS = [
  "attachment",
  "workspace",
  "reservation",
  "share",
  "history",
] as const;

export type GlobalStorageStream = (typeof GLOBAL_STORAGE_STREAMS)[number];
export type JsonValue = null | boolean | number | string | JsonValue[] | {
  [key: string]: JsonValue;
};
export type CanonicalRow = { [key: string]: JsonValue };

export interface GlobalStorageCursor {
  schemaVersion: 1;
  cycleId: string;
  stream: GlobalStorageStream;
  /** Empty string is the immutable high-water marker for a cycle empty at opening. */
  highWaterId: string;
  afterId: string | null;
}

export interface LegacyEvidencePolicy {
  policyId: string;
  /** Canonical RFC 3339 UTC timestamp with millisecond precision. */
  pre0038Boundary: string;
  allowedHostKinds: Array<"attachment" | "artifact">;
  creationAdmissionRule: "host_created_at_before_boundary";
  actorEvidenceRule: "owner_is_actor";
  reconstructReservedAtFromHostCreatedAt: boolean;
  rollingHistoryPolicyId: string;
  rollingHistoryMeaning: string;
}

export interface GlobalStoragePageBounds {
  scanLimit: number;
  /** Exactly zero in this no-storage-I/O patch. */
  ioLimit: number;
  maxOwners: number;
  perOwnerIoLimit: number;
  reportLimit: number;
}

export interface GlobalStoragePageOptions {
  cursor: GlobalStorageCursor;
  bounds: GlobalStoragePageBounds;
  olderThanMs: number;
  legacyEvidencePolicy: LegacyEvidencePolicy | null;
}

export interface GlobalStorageReadRuntime {
  now: () => Date;
  /** Cooperative between bounded DB reads; no timer or query-cancellation claim. */
  deadlineExceeded: () => boolean;
}

export interface GlobalStorageCurrentFacts {
  attachments: unknown[];
  workspaceObjects: unknown[];
  reservations: unknown[];
  dependentShares: unknown[];
  session: unknown[];
  ownerAccount: unknown[];
  actorAccount: unknown[];
  collabRooms: unknown[];
}

export interface GlobalStorageGeneration {
  version: 1;
  stream: GlobalStorageStream;
  raw: CanonicalRow;
  attachments: CanonicalRow[];
  workspaceObjects: CanonicalRow[];
  reservations: CanonicalRow[];
  reservationSetComplete: boolean;
  dependentShares: CanonicalRow[];
  dependentShareSetComplete: boolean;
  authority: {
    session: CanonicalRow[];
    ownerAccount: CanonicalRow[];
    actorAccount: CanonicalRow[];
    collabRooms: CanonicalRow[];
  };
  factsComplete: boolean;
}

export type GlobalStorageDisposition =
  | "ordinary_candidate"
  | "collab_lifecycle_owned"
  | "account_lifecycle_owned"
  | "foreign_identity"
  | "share_candidate"
  | "history_candidate"
  | "unresolved";

export interface GlobalStorageClassification {
  disposition: GlobalStorageDisposition;
  reason: string;
  /** True means even a later ordinary apply design must not claim this outcome. */
  dryRunOnly: boolean;
}

export interface GlobalStorageHistoryEvidence {
  actorProvenance:
    | "existing_reservation"
    | "existing_history"
    | "owner_actor_policy"
    | "unresolved"
    | "not_applicable";
  originalFinalizedAt: string | null;
  originalFinalizedAtUnknown: boolean;
  reservedAtProvenance:
    | "existing_reservation"
    | "existing_history"
    | "approved_reconstruction"
    | "not_reconstructed"
    | "unresolved"
    | "not_applicable";
}

export interface GlobalStoragePageOutcome {
  version: 1;
  stream: GlobalStorageStream;
  rawId: string;
  identity: string;
  fingerprint: string;
  classification: GlobalStorageClassification;
  generation: GlobalStorageGeneration;
  history: GlobalStorageHistoryEvidence;
}

export type GlobalStorageStopReason =
  | "scan_limit"
  | "owner_limit"
  | "report_limit"
  | "deadline"
  | null;

export interface GlobalStorageRawPage {
  outcomes: GlobalStoragePageOutcome[];
  examinedRawRows: number;
  scanComplete: boolean;
  reportCompleteForApproval: boolean;
  nextCursor: GlobalStorageCursor | null;
  stopReason: GlobalStorageStopReason;
  ownersTouched: number;
}

export type GlobalStorageDiscoveryErrorCode =
  | "invalid_options"
  | "invalid_cursor"
  | "malformed_cursor_identity"
  | "invalid_clock"
  | "invalid_raw_page";

export class GlobalStorageDiscoveryError extends Error {
  readonly name = "GlobalStorageDiscoveryError";

  constructor(readonly code: GlobalStorageDiscoveryErrorCode, message: string) {
    super(message);
  }
}

interface UnsafeClient {
  unsafe(query: string, params?: unknown[]): Promise<unknown>;
}

const STREAMS = new Set<string>(GLOBAL_STORAGE_STREAMS);
const HISTORY_PREFIX = "upload-complete:";
const MAX_HOST_FACTS = 2;
const MAX_HOST_FACT_ROWS_WITH_OVERFLOW = MAX_HOST_FACTS + 1;
const MAX_RESERVATION_FACTS = 16;
const MAX_FACT_ROWS_WITH_OVERFLOW = MAX_RESERVATION_FACTS + 1;

const ATTACHMENT_COLUMNS = `
  id, session_id, user_id, project_id, name, size::text AS size, r2_key,
  content_type, content_type_declared, upload_status, actual_bytes::text AS actual_bytes,
  actual_content_type, finalized_at, message_id, created_at`;

const WORKSPACE_COLUMNS = `
  id, user_id, session_id, project_id, kind, r2_key, bytes::text AS bytes,
  sha256, content_type, generation::text AS generation, status, meta, created_at`;

const RESERVATION_COLUMNS = `
  id, actor_user_id, owner_user_id, session_id, object_id, state,
  declared_bytes::text AS declared_bytes, actual_bytes::text AS actual_bytes,
  actual_content_type, etag, reserved_at, finalized_at, released_at, created_at, updated_at`;

const ORDINARY_RESERVATION_FILTER = `
  id NOT LIKE 'upload-complete:%'
  AND id NOT LIKE 'artifact-share:%'
  AND (object_id IS NULL OR (
    object_id NOT LIKE 'upload-complete:%'
    AND object_id NOT LIKE 'charge:%'
    AND object_id NOT LIKE 'users/%/artifact-shares/%'
  ))`;

const SHARE_RESERVATION_FILTER = `
  id NOT LIKE 'upload-complete:%'
  AND (object_id IS NULL OR object_id NOT LIKE 'upload-complete:%')
  AND (
    id LIKE 'artifact-share:%'
    OR object_id LIKE 'charge:%'
    OR object_id LIKE 'users/%/artifact-shares/%'
  )`;

const HISTORY_RESERVATION_FILTER = `
  id LIKE 'upload-complete:%' OR object_id LIKE 'upload-complete:%'`;

function clientOf(db: Db): UnsafeClient {
  const client = (db as unknown as { $client?: UnsafeClient }).$client;
  if (client === undefined || typeof client.unsafe !== "function") {
    throw new GlobalStorageDiscoveryError(
      "invalid_options",
      "Global storage discovery requires the drizzle/postgres.js $client.unsafe read handle",
    );
  }
  return client;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value) && !(value instanceof Date);
}

function isDenseArray(value: unknown): value is unknown[] {
  if (!Array.isArray(value)) return false;
  for (let index = 0; index < value.length; index++) {
    if (!Object.prototype.hasOwnProperty.call(value, index) || value[index] === undefined) return false;
  }
  return true;
}

function invalidValue(kind: string, value?: unknown): JsonValue {
  return {
    $invalid: kind,
    ...(typeof value === "string" || typeof value === "number" || typeof value === "boolean"
      ? { value: String(value) }
      : {}),
  };
}

function jsonValue(value: unknown, seen = new Set<object>()): JsonValue {
  if (value === null) return null;
  if (typeof value === "string" || typeof value === "boolean") return value;
  if (typeof value === "number") {
    return Number.isFinite(value) && (!Number.isInteger(value) || Number.isSafeInteger(value))
      ? value
      : invalidValue("unsafe_or_nonfinite_number", value);
  }
  if (typeof value === "bigint") {
    const numeric = Number(value);
    return Number.isSafeInteger(numeric) ? numeric : invalidValue("unsafe_bigint", value.toString());
  }
  if (value instanceof Date) {
    return Number.isFinite(value.getTime()) ? value.toISOString() : invalidValue("invalid_timestamp");
  }
  if (typeof value === "undefined" || typeof value === "function" || typeof value === "symbol") {
    return invalidValue(`non_json_${typeof value}`);
  }
  if (typeof value !== "object") return invalidValue("non_json_value");
  if (seen.has(value)) return invalidValue("cyclic_value");
  seen.add(value);
  try {
    if (Array.isArray(value)) {
      if (!isDenseArray(value)) return invalidValue("sparse_array");
      return value.map((entry) => jsonValue(entry, seen));
    }
    const result: { [key: string]: JsonValue } = {};
    for (const key of Object.keys(value)) {
      result[key] = jsonValue((value as Record<string, unknown>)[key], seen);
    }
    return result;
  } finally {
    seen.delete(value);
  }
}

function canonicalInteger(value: unknown): JsonValue {
  if (value === null) return null;
  if (typeof value === "number" && Number.isSafeInteger(value)) return value;
  if (typeof value === "bigint") {
    const numeric = Number(value);
    return Number.isSafeInteger(numeric) ? numeric : invalidValue("unsafe_integer", value.toString());
  }
  if (typeof value === "string" && /^-?[0-9]+$/.test(value)) {
    const numeric = Number(value);
    if (Number.isSafeInteger(numeric)) return numeric;
    return invalidValue("unsafe_integer", value);
  }
  return invalidValue("invalid_integer", typeof value === "string" ? value : undefined);
}

function canonicalTimestamp(value: unknown): JsonValue {
  if (value === null) return null;
  const date = value instanceof Date ? value : typeof value === "string" ? new Date(value) : null;
  if (date === null || !Number.isFinite(date.getTime())) return invalidValue("invalid_timestamp");
  return date.toISOString();
}

const NUMERIC_FIELDS: Record<string, ReadonlySet<string>> = {
  attachment: new Set(["size", "actual_bytes"]),
  workspace: new Set(["bytes", "generation"]),
  reservation: new Set(["declared_bytes", "actual_bytes"]),
  room: new Set(["generation"]),
  other: new Set(),
};

const TIMESTAMP_FIELDS = new Set([
  "created_at",
  "updated_at",
  "finalized_at",
  "released_at",
  "reserved_at",
  "deleted_at",
]);

function normalizeRow(value: unknown, numericKind = "other"): CanonicalRow {
  if (!isRecord(value)) return { $invalid: "row" };
  const result: CanonicalRow = {};
  const numeric = NUMERIC_FIELDS[numericKind] ?? NUMERIC_FIELDS.other!;
  for (const key of Object.keys(value)) {
    const field = value[key];
    result[key] = numeric.has(key)
      ? canonicalInteger(field)
      : TIMESTAMP_FIELDS.has(key)
        ? canonicalTimestamp(field)
        : jsonValue(field);
  }
  return result;
}

function canonicalStringify(value: JsonValue): string {
  const visit = (current: JsonValue): string => {
    if (current === null || typeof current === "string" || typeof current === "boolean" || typeof current === "number") {
      return JSON.stringify(current);
    }
    if (Array.isArray(current)) {
      if (!isDenseArray(current)) {
        throw new GlobalStorageDiscoveryError("invalid_raw_page", "Sparse arrays are not canonical JSON");
      }
      return `[${current.map(visit).join(",")}]`;
    }
    return `{${Object.keys(current).sort().map((key) =>
      `${JSON.stringify(key)}:${visit(current[key]!)}`).join(",")}}`;
  };
  return visit(value);
}

function stringField(row: CanonicalRow | undefined, field: string): string | null {
  const value = row?.[field];
  return typeof value === "string" && value.length > 0 ? value : null;
}

function nullableStringField(row: CanonicalRow | undefined, field: string): string | null | undefined {
  const value = row?.[field];
  return value === null ? null : typeof value === "string" ? value : undefined;
}

function numberField(row: CanonicalRow | undefined, field: string): number | null {
  const value = row?.[field];
  return typeof value === "number" && Number.isSafeInteger(value) ? value : null;
}

function timestampField(row: CanonicalRow | undefined, field: string): string | null {
  const value = row?.[field];
  return typeof value === "string" && Number.isFinite(Date.parse(value)) ? value : null;
}

function requiredTimestamp(value: string, field: string): string {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime()) || date.toISOString() !== value) {
    throw new GlobalStorageDiscoveryError("invalid_options", `${field} must be canonical RFC 3339 UTC`);
  }
  return value;
}

function requiredString(value: unknown, field: string, allowEmpty = false): string {
  if (typeof value !== "string" || (!allowEmpty && value.trim() === "")) {
    throw new GlobalStorageDiscoveryError("invalid_options", `${field} must be a string`);
  }
  return value;
}

function boundedInteger(value: unknown, field: string, minimum: number, maximum: number): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new GlobalStorageDiscoveryError(
      "invalid_options",
      `${field} must be a safe integer ${minimum}..${maximum}`,
    );
  }
  return value;
}

function validatePolicy(policy: LegacyEvidencePolicy | null): LegacyEvidencePolicy | null {
  if (policy === null) return null;
  if (!isRecord(policy)) throw new GlobalStorageDiscoveryError("invalid_options", "Invalid legacy policy");
  requiredString(policy.policyId, "legacyEvidencePolicy.policyId");
  requiredTimestamp(policy.pre0038Boundary, "legacyEvidencePolicy.pre0038Boundary");
  if (!isDenseArray(policy.allowedHostKinds) || policy.allowedHostKinds.length === 0 ||
      policy.allowedHostKinds.some((kind) => kind !== "attachment" && kind !== "artifact") ||
      new Set(policy.allowedHostKinds).size !== policy.allowedHostKinds.length) {
    throw new GlobalStorageDiscoveryError("invalid_options", "Invalid legacy host-kind evidence scope");
  }
  if (policy.creationAdmissionRule !== "host_created_at_before_boundary" ||
      policy.actorEvidenceRule !== "owner_is_actor" ||
      typeof policy.reconstructReservedAtFromHostCreatedAt !== "boolean") {
    throw new GlobalStorageDiscoveryError("invalid_options", "Invalid legacy actor/admission evidence rule");
  }
  requiredString(policy.rollingHistoryPolicyId, "legacyEvidencePolicy.rollingHistoryPolicyId");
  requiredString(policy.rollingHistoryMeaning, "legacyEvidencePolicy.rollingHistoryMeaning");
  return {
    ...policy,
    allowedHostKinds: [...policy.allowedHostKinds],
  };
}

function validateCursor(cursor: GlobalStorageCursor): void {
  if (!isRecord(cursor) || cursor.schemaVersion !== 1 || !STREAMS.has(cursor.stream)) {
    throw new GlobalStorageDiscoveryError("invalid_cursor", "Unknown global storage cursor");
  }
  requiredString(cursor.cycleId, "cursor.cycleId");
  requiredString(cursor.highWaterId, "cursor.highWaterId", true);
  if (cursor.afterId !== null) requiredString(cursor.afterId, "cursor.afterId");
  if (cursor.highWaterId === "" && cursor.afterId !== null) {
    throw new GlobalStorageDiscoveryError("invalid_cursor", "An empty cycle cannot have an after cursor");
  }
  if (cursor.afterId !== null && cursor.highWaterId !== "" && cursor.afterId > cursor.highWaterId) {
    throw new GlobalStorageDiscoveryError("invalid_cursor", "Cursor is after its immutable high-water ID");
  }
}

function validatePageOptions(options: GlobalStoragePageOptions): void {
  if (!isRecord(options)) throw new GlobalStorageDiscoveryError("invalid_options", "Options are required");
  validateCursor(options.cursor);
  if (!isRecord(options.bounds)) throw new GlobalStorageDiscoveryError("invalid_options", "Bounds are required");
  boundedInteger(options.bounds.scanLimit, "scanLimit", 1, 100);
  boundedInteger(options.bounds.ioLimit, "ioLimit", 0, 0);
  boundedInteger(options.bounds.maxOwners, "maxOwners", 1, 16);
  boundedInteger(options.bounds.perOwnerIoLimit, "perOwnerIoLimit", 1, 8);
  boundedInteger(options.bounds.reportLimit, "reportLimit", 1, 100);
  boundedInteger(options.olderThanMs, "olderThanMs", 900_000, Number.MAX_SAFE_INTEGER);
  validatePolicy(options.legacyEvidencePolicy);
}

function streamTable(stream: GlobalStorageStream): "attachments" | "workspace_objects" | "storage_reservations" {
  if (stream === "attachment") return "attachments";
  if (stream === "workspace") return "workspace_objects";
  return "storage_reservations";
}

function streamColumns(stream: GlobalStorageStream): string {
  if (stream === "attachment") return ATTACHMENT_COLUMNS;
  if (stream === "workspace") return WORKSPACE_COLUMNS;
  return RESERVATION_COLUMNS;
}

function streamFilter(stream: GlobalStorageStream): string {
  if (stream === "reservation") return `AND (${ORDINARY_RESERVATION_FILTER})`;
  if (stream === "share") return `AND (${SHARE_RESERVATION_FILTER})`;
  if (stream === "history") return `AND (${HISTORY_RESERVATION_FILTER})`;
  return "";
}

/** Read the immutable cycle high-water. Empty string means an empty cycle, never a zero/fleet claim. */
export async function readGlobalStorageHighWater(
  db: Db,
  stream: GlobalStorageStream,
): Promise<string> {
  if (!STREAMS.has(stream)) throw new GlobalStorageDiscoveryError("invalid_options", "Unknown stream");
  const rows = await clientOf(db).unsafe(`
    SELECT MAX(id) AS high_water_id
      FROM ${streamTable(stream)}
     WHERE TRUE ${streamFilter(stream)}`) as Array<{ high_water_id?: unknown }>;
  if (!isDenseArray(rows) || rows.length !== 1) {
    throw new GlobalStorageDiscoveryError("invalid_raw_page", "High-water read did not return one row");
  }
  const value = rows[0]?.high_water_id;
  if (value === null || value === undefined) return "";
  if (typeof value !== "string" || value === "") {
    throw new GlobalStorageDiscoveryError("malformed_cursor_identity", "Malformed high-water primary key");
  }
  return value;
}

const CURRENT_FACTS_SQL = `
WITH seed_current_reservation AS (
  SELECT id, object_id FROM storage_reservations
   WHERE $3::text IS NOT NULL AND id = $3
   ORDER BY id LIMIT 2
),
seed_original_reservation AS (
  SELECT id, object_id FROM storage_reservations
   WHERE $4::text IS NOT NULL AND id = $4
   ORDER BY id LIMIT 2
),
current_share_identity AS (
  SELECT CASE
    WHEN object_id LIKE 'charge:%' THEN substring(object_id from 8)
    ELSE object_id
  END AS share_key
  FROM seed_current_reservation
  WHERE $10::text = 'share'
),
current_object_identity AS (
  SELECT
    CASE
      WHEN $10::text = 'history' THEN (
        SELECT COALESCE(object_id, id) FROM seed_original_reservation LIMIT 1
      )
      WHEN $10::text = 'share' THEN (
        SELECT split_part(share_key, '/', 4) FROM current_share_identity LIMIT 1
      )
      WHEN $10::text = 'reservation' THEN (
        SELECT object_id FROM seed_current_reservation LIMIT 1
      )
    END AS object_id,
    (SELECT share_key FROM current_share_identity LIMIT 1) AS share_key,
    (SELECT
      'artifact-share:' || split_part(share_key, '/', 4) || ':' ||
        substring(split_part(share_key, '/', 5) from 8)
     FROM current_share_identity LIMIT 1) AS charge_id
),
seed_attachments AS (
  SELECT ${ATTACHMENT_COLUMNS} FROM attachments a
   WHERE ($10::text = 'attachment' AND a.id = $1)
      OR ($10::text = 'workspace' AND a.id = $2)
      OR EXISTS (
        SELECT 1 FROM current_object_identity c
         WHERE c.object_id IS NOT NULL AND (a.id = c.object_id OR a.r2_key = c.object_id)
      )
   ORDER BY a.id LIMIT ${MAX_HOST_FACT_ROWS_WITH_OVERFLOW}
),
seed_workspaces AS (
  SELECT ${WORKSPACE_COLUMNS} FROM workspace_objects w
   WHERE ($10::text = 'attachment' AND w.id = $1)
      OR ($10::text = 'workspace' AND w.id = $2)
      OR EXISTS (
        SELECT 1 FROM current_object_identity c
         WHERE c.object_id IS NOT NULL AND (w.id = c.object_id OR w.r2_key = c.object_id)
      )
   ORDER BY w.id LIMIT ${MAX_HOST_FACT_ROWS_WITH_OVERFLOW}
),
seed_hosts AS (
  SELECT 'attachment' AS host_kind, id, r2_key FROM seed_attachments
  UNION ALL
  SELECT 'workspace' AS host_kind, id, r2_key FROM seed_workspaces
),
host_keys AS (
  SELECT DISTINCT r2_key FROM seed_hosts WHERE r2_key IS NOT NULL
),
matched_attachments AS (
  SELECT ${ATTACHMENT_COLUMNS} FROM attachments a
   WHERE EXISTS (SELECT 1 FROM seed_attachments s WHERE s.id = a.id)
      OR EXISTS (SELECT 1 FROM host_keys k WHERE a.r2_key = k.r2_key)
   ORDER BY a.id LIMIT ${MAX_HOST_FACT_ROWS_WITH_OVERFLOW}
),
matched_workspaces AS (
  SELECT ${WORKSPACE_COLUMNS} FROM workspace_objects w
   WHERE EXISTS (SELECT 1 FROM seed_workspaces s WHERE s.id = w.id)
      OR EXISTS (SELECT 1 FROM host_keys k WHERE w.r2_key = k.r2_key)
   ORDER BY w.id LIMIT ${MAX_HOST_FACT_ROWS_WITH_OVERFLOW}
),
matched_hosts AS (
  SELECT 'attachment' AS host_kind, id, r2_key FROM matched_attachments
  UNION ALL
  SELECT 'workspace' AS host_kind, id, r2_key FROM matched_workspaces
),
matched_reservations AS (
  SELECT ${RESERVATION_COLUMNS} FROM storage_reservations r
   WHERE ($3::text IS NOT NULL AND r.id = $3)
      OR ($4::text IS NOT NULL AND r.id = $4)
      OR ($10::text IN ('attachment', 'workspace') AND $1::text IS NOT NULL AND (r.object_id = $1 OR r.id = $1))
      OR ($10::text IN ('attachment', 'workspace') AND $2::text IS NOT NULL AND (r.object_id = $2 OR r.id = $2))
      OR EXISTS (
        SELECT 1 FROM current_object_identity c
         WHERE c.share_key IS NOT NULL AND (
           r.object_id = c.share_key OR r.object_id = 'charge:' || c.share_key OR r.id = c.charge_id
         )
      )
      OR EXISTS (
        SELECT 1 FROM matched_hosts h
         WHERE r.object_id = h.id OR r.object_id = h.r2_key OR r.id = h.id
      )
   ORDER BY r.id LIMIT ${MAX_FACT_ROWS_WITH_OVERFLOW}
),
dependent_shares AS (
  SELECT ${RESERVATION_COLUMNS} FROM storage_reservations r
   WHERE r.id NOT LIKE 'upload-complete:%'
     AND (r.object_id IS NULL OR r.object_id NOT LIKE 'upload-complete:%')
     AND (
       r.id LIKE 'artifact-share:%'
       OR r.object_id LIKE 'charge:%'
       OR r.object_id LIKE 'users/%/artifact-shares/%'
     )
     AND (
       EXISTS (SELECT 1 FROM current_object_identity c WHERE c.share_key IS NOT NULL AND (
         r.object_id = c.share_key OR r.object_id = 'charge:' || c.share_key OR r.id = c.charge_id
       ))
       OR EXISTS (
         SELECT 1 FROM matched_workspaces w
          WHERE w.kind = 'artifact'
            AND (
              r.object_id LIKE 'users/' || w.user_id || '/artifact-shares/' || w.id || '/%'
              OR r.id LIKE 'artifact-share:' || w.id || ':%'
            )
       )
       OR ($10::text = 'workspace' AND $8 IS NOT NULL AND $9 IS NOT NULL AND (
         r.object_id LIKE 'users/' || $9 || '/artifact-shares/' || $8 || '/%'
         OR r.id LIKE 'artifact-share:' || $8 || ':%'
       ))
     )
   ORDER BY r.id LIMIT ${MAX_FACT_ROWS_WITH_OVERFLOW}
)
SELECT
  COALESCE((SELECT json_agg(x ORDER BY x.id) FROM matched_attachments x), '[]'::json) AS attachments,
  COALESCE((SELECT json_agg(x ORDER BY x.id) FROM matched_workspaces x), '[]'::json) AS workspace_objects,
  COALESCE((SELECT json_agg(x ORDER BY x.id) FROM matched_reservations x), '[]'::json) AS reservations,
  COALESCE((SELECT json_agg(x ORDER BY x.id) FROM dependent_shares x), '[]'::json) AS dependent_shares,
  COALESCE((SELECT json_agg(x ORDER BY x.id) FROM (
    SELECT id, user_id, deleted_at, updated_at FROM sessions WHERE id = $7 LIMIT 2
  ) x), '[]'::json) AS "session",
  COALESCE((SELECT json_agg(x ORDER BY x.uid) FROM (
    SELECT $5::text AS uid,
           (SELECT EXISTS(SELECT 1 FROM users u WHERE u.uid = $5)) AS user_present,
           (SELECT a.state FROM account_deletions a WHERE a.uid = $5) AS state,
           (SELECT a.updated_at FROM account_deletions a WHERE a.uid = $5) AS updated_at
     WHERE $5::text IS NOT NULL LIMIT 2
  ) x), '[]'::json) AS owner_account,
  COALESCE((SELECT json_agg(x ORDER BY x.uid) FROM (
    SELECT $6::text AS uid,
           (SELECT EXISTS(SELECT 1 FROM users u WHERE u.uid = $6)) AS user_present,
           (SELECT a.state FROM account_deletions a WHERE a.uid = $6) AS state,
           (SELECT a.updated_at FROM account_deletions a WHERE a.uid = $6) AS updated_at
     WHERE $6::text IS NOT NULL LIMIT 2
  ) x), '[]'::json) AS actor_account,
  COALESCE((SELECT json_agg(x ORDER BY x.id) FROM (
    SELECT id, session_id, owner_user_id, request_id, lifecycle,
           generation::text AS generation, close_request_id, created_at, updated_at
      FROM collab_rooms WHERE session_id = $7 ORDER BY id LIMIT 2
  ) x), '[]'::json) AS collab_rooms`;

interface ShareIdentity {
  key: string;
  ownerUserId: string;
  artifactId: string;
  versionHash: string;
  chargeId: string;
}

/** Read-only identity extraction. No grant predicate, advisory key, debit, or lifecycle mutation lives here. */
function parseShareIdentity(value: string | null): ShareIdentity | null {
  if (value === null) return null;
  const parts = value.split("/");
  if (parts.length !== 6 || parts[0] !== "users" || parts[1] === "" ||
      parts[2] !== "artifact-shares" || parts[5] !== "object") return null;
  const artifactId = parts[3]!;
  const digest = parts[4]!;
  if (!/^[0-9a-f-]{36}$/i.test(artifactId) || !digest.startsWith("sha256-")) return null;
  const versionHash = digest.slice("sha256-".length).toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(versionHash)) return null;
  return {
    key: value,
    ownerUserId: parts[1]!,
    artifactId,
    versionHash,
    chargeId: `artifact-share:${artifactId}:${versionHash}`,
  };
}

function rawObject(raw: Record<string, unknown>): {
  owner: string | null;
  actor: string | null;
  session: string | null;
  objectAddress: string | null;
  attachmentId: string | null;
  workspaceId: string | null;
  originalReservationId: string | null;
  share: ShareIdentity | null;
  shareKey: string | null;
} {
  const stream = raw.__stream;
  const owner = typeof raw.owner_user_id === "string" ? raw.owner_user_id
    : typeof raw.user_id === "string" ? raw.user_id : null;
  const actor = stream === "reservation" || stream === "share" || stream === "history"
    ? typeof raw.actor_user_id === "string" ? raw.actor_user_id : null
    : owner;
  const session = typeof raw.session_id === "string" ? raw.session_id : null;
  const objectId = typeof raw.object_id === "string" ? raw.object_id : null;
  let objectAddress = stream === "reservation" ? objectId : null;
  let originalReservationId: string | null = null;
  if (stream === "history") {
    const id = typeof raw.id === "string" ? raw.id : null;
    originalReservationId = id?.startsWith(HISTORY_PREFIX) ? id.slice(HISTORY_PREFIX.length) : null;
    objectAddress = objectId?.startsWith(HISTORY_PREFIX) ? objectId.slice(HISTORY_PREFIX.length) : null;
  }
  const shareKey = stream === "share"
    ? objectId?.startsWith("charge:") ? objectId.slice("charge:".length) : objectId
    : null;
  const share = parseShareIdentity(shareKey);
  return {
    owner,
    actor,
    session,
    objectAddress,
    attachmentId: stream === "attachment" && typeof raw.id === "string" ? raw.id : null,
    workspaceId: (stream === "workspace" && typeof raw.id === "string" ? raw.id : null) ?? share?.artifactId ?? null,
    originalReservationId,
    share,
    shareKey,
  };
}

async function readCurrentFacts(
  client: UnsafeClient,
  stream: GlobalStorageStream,
  raw: Record<string, unknown>,
): Promise<GlobalStorageCurrentFacts> {
  const identity = rawObject({ ...raw, __stream: stream });
  const result = await client.unsafe(CURRENT_FACTS_SQL, [
    identity.attachmentId,
    identity.workspaceId,
    typeof raw.id === "string" ? raw.id : null,
    identity.originalReservationId,
    identity.owner,
    identity.actor,
    identity.session,
    stream === "workspace" && typeof raw.id === "string" ? raw.id : shareArtifactId(identity),
    identity.owner,
    stream,
  ]);
  if (!Array.isArray(result) || result.length !== 1 || !isRecord(result[0])) {
    throw new GlobalStorageDiscoveryError("invalid_raw_page", "Current-fact read returned a malformed row");
  }
  const row = result[0];
  const array = (camel: string, snake: string): unknown[] => {
    const value = row[camel] ?? row[snake];
    if (!isDenseArray(value)) throw new GlobalStorageDiscoveryError("invalid_raw_page", `Missing or sparse bounded ${camel} facts`);
    return value;
  };
  return {
    attachments: array("attachments", "attachments"),
    workspaceObjects: array("workspaceObjects", "workspace_objects"),
    reservations: array("reservations", "reservations"),
    dependentShares: array("dependentShares", "dependent_shares"),
    session: array("session", "session"),
    ownerAccount: array("ownerAccount", "owner_account"),
    actorAccount: array("actorAccount", "actor_account"),
    collabRooms: array("collabRooms", "collab_rooms"),
  };
}

function shareArtifactId(identity: ReturnType<typeof rawObject>): string | null {
  return identity.share?.artifactId ?? null;
}

function emptyFacts(): GlobalStorageCurrentFacts {
  return {
    attachments: [],
    workspaceObjects: [],
    reservations: [],
    dependentShares: [],
    session: [],
    ownerAccount: [],
    actorAccount: [],
    collabRooms: [],
  };
}

export interface GlobalStorageClassificationInput {
  stream: GlobalStorageStream;
  raw: Record<string, unknown>;
  facts: GlobalStorageCurrentFacts;
  factsComplete?: boolean;
}

export interface GlobalStorageClassificationOptions {
  observedAt: string;
  olderThanMs: number;
  legacyEvidencePolicy: LegacyEvidencePolicy | null;
}

interface ResolvedGeneration {
  generation: GlobalStorageGeneration;
  raw: CanonicalRow;
  currentRaw: CanonicalRow;
  host: { kind: "attachment" | "workspace"; row: CanonicalRow } | null;
  hostAmbiguous: boolean;
  rawCurrentIdentityMismatch: boolean;
  relatedReservations: CanonicalRow[];
  identity: ReturnType<typeof rawObject>;
  share: ShareIdentity | null;
}

function normalizeFacts(facts: GlobalStorageCurrentFacts): {
  attachments: CanonicalRow[];
  workspaceObjects: CanonicalRow[];
  reservations: CanonicalRow[];
  dependentShares: CanonicalRow[];
  session: CanonicalRow[];
  ownerAccount: CanonicalRow[];
  actorAccount: CanonicalRow[];
  collabRooms: CanonicalRow[];
  complete: boolean;
} {
  const arrays = [
    facts.attachments,
    facts.workspaceObjects,
    facts.reservations,
    facts.dependentShares,
    facts.session,
    facts.ownerAccount,
    facts.actorAccount,
    facts.collabRooms,
  ];
  let complete = true;
  for (const array of arrays) {
    if (!isDenseArray(array)) {
      complete = false;
      continue;
    }
    for (const row of array) {
      if (!isRecord(row)) {
        complete = false;
        break;
      }
    }
  }
  const rows = (input: unknown[], kind = "other") =>
    isDenseArray(input) ? input.map((row) => normalizeRow(row, kind)) : [];
  return {
    attachments: rows(facts.attachments, "attachment"),
    workspaceObjects: rows(facts.workspaceObjects, "workspace"),
    reservations: rows(facts.reservations, "reservation"),
    dependentShares: rows(facts.dependentShares, "reservation"),
    session: rows(facts.session),
    ownerAccount: rows(facts.ownerAccount),
    actorAccount: rows(facts.actorAccount),
    collabRooms: rows(facts.collabRooms, "room"),
    complete,
  };
}

function uniqueRows(rows: CanonicalRow[]): CanonicalRow[] {
  const result: CanonicalRow[] = [];
  const seen = new Set<string>();
  for (const row of rows) {
    const key = canonicalStringify(row);
    if (!seen.has(key)) {
      seen.add(key);
      result.push(row);
    }
  }
  return result;
}

function resolveGeneration(input: GlobalStorageClassificationInput, factsComplete: boolean): ResolvedGeneration {
  const normalized = normalizeFacts(input.facts);
  const raw = normalizeRow(input.raw,
    input.stream === "attachment" ? "attachment"
      : input.stream === "workspace" ? "workspace" : "reservation");
  const reservationRows = uniqueRows(normalized.reservations);
  const currentRawReservation = input.stream === "reservation" || input.stream === "share" || input.stream === "history"
    ? reservationRows.find((row) => stringField(row, "id") === stringField(raw, "id"))
    : undefined;
  const currentRawHost = input.stream === "attachment"
    ? normalized.attachments.find((row) => stringField(row, "id") === stringField(raw, "id"))
    : input.stream === "workspace"
      ? normalized.workspaceObjects.find((row) => stringField(row, "id") === stringField(raw, "id"))
      : undefined;
  const currentRaw = currentRawReservation ?? currentRawHost ?? raw;
  const rawIdentity = rawObject({ ...raw, __stream: input.stream });
  const identity = rawObject({ ...currentRaw, __stream: input.stream });
  const originalReservation = input.stream === "history"
    ? reservationRows.find((row) => stringField(row, "id") === identity.originalReservationId)
    : undefined;
  const currentObjectAddress = input.stream === "history"
    ? originalReservation === undefined
      ? null
      : nullableStringField(originalReservation, "object_id") ?? identity.originalReservationId
    : identity.objectAddress;
  const rawOriginalIdentityMismatch = input.stream === "history" && originalReservation !== undefined &&
    rawIdentity.objectAddress !== currentObjectAddress;
  const rawCurrentIdentityMismatch = stringField(raw, "id") !== stringField(currentRaw, "id") ||
    (input.stream === "attachment" || input.stream === "workspace"
      ? nullableStringField(raw, "r2_key") !== nullableStringField(currentRaw, "r2_key")
      : nullableStringField(raw, "object_id") !== nullableStringField(currentRaw, "object_id")) ||
    rawOriginalIdentityMismatch;

  let hostCandidates: Array<{ kind: "attachment" | "workspace"; row: CanonicalRow }> = [];
  if (input.stream === "attachment") {
    hostCandidates = normalized.attachments
      .filter((row) => stringField(row, "id") === stringField(raw, "id"))
      .map((row) => ({ kind: "attachment" as const, row }));
  } else if (input.stream === "workspace") {
    hostCandidates = normalized.workspaceObjects
      .filter((row) => stringField(row, "id") === stringField(raw, "id"))
      .map((row) => ({ kind: "workspace" as const, row }));
  } else if (input.stream === "share") {
    hostCandidates = normalized.workspaceObjects
      .filter((row) => stringField(row, "id") === identity.share?.artifactId)
      .map((row) => ({ kind: "workspace" as const, row }));
  } else {
    hostCandidates = [
      ...normalized.attachments.filter((row) =>
        stringField(row, "id") === currentObjectAddress || stringField(row, "r2_key") === currentObjectAddress)
        .map((row) => ({ kind: "attachment" as const, row })),
      ...normalized.workspaceObjects.filter((row) =>
        stringField(row, "id") === currentObjectAddress || stringField(row, "r2_key") === currentObjectAddress)
        .map((row) => ({ kind: "workspace" as const, row })),
    ];
  }
  const host = hostCandidates.length === 1 ? hostCandidates[0]! : null;
  const hostAmbiguous = hostCandidates.length > 1 ||
    normalized.attachments.length + normalized.workspaceObjects.length > 1;

  const relatedReservations = reservationRows.filter((row) => {
    const id = stringField(row, "id");
    const objectId = nullableStringField(row, "object_id");
    if (input.stream === "history") {
      return id === identity.originalReservationId || id === stringField(raw, "id") ||
        (host !== null && (objectId === stringField(host.row, "id") || objectId === stringField(host.row, "r2_key") || id === stringField(host.row, "id")));
    }
    if (input.stream === "share") return true;
    if (host !== null) {
      return objectId === stringField(host.row, "id") || objectId === stringField(host.row, "r2_key") || id === stringField(host.row, "id") || id === stringField(raw, "id");
    }
    return id === stringField(raw, "id") || id === identity.originalReservationId || objectId === currentObjectAddress;
  });

  const hostSetComplete = normalized.attachments.length <= MAX_HOST_FACTS &&
    normalized.workspaceObjects.length <= MAX_HOST_FACTS;
  const reservationSetComplete = normalized.reservations.length <= MAX_RESERVATION_FACTS;
  const dependentShareSetComplete = normalized.dependentShares.length <= MAX_RESERVATION_FACTS;
  const generation: GlobalStorageGeneration = {
    version: 1,
    stream: input.stream,
    raw,
    attachments: normalized.attachments,
    workspaceObjects: normalized.workspaceObjects,
    reservations: reservationRows,
    reservationSetComplete,
    dependentShares: normalized.dependentShares,
    dependentShareSetComplete,
    authority: {
      session: normalized.session,
      ownerAccount: normalized.ownerAccount,
      actorAccount: normalized.actorAccount,
      collabRooms: normalized.collabRooms,
    },
    factsComplete: factsComplete && normalized.complete && hostSetComplete &&
      reservationSetComplete && dependentShareSetComplete,
  };

  return {
    generation,
    raw,
    currentRaw,
    host,
    hostAmbiguous,
    rawCurrentIdentityMismatch,
    relatedReservations,
    identity,
    share: identity.share,
  };
}

function classification(
  disposition: GlobalStorageDisposition,
  reason: string,
  dryRunOnly: boolean,
): GlobalStorageClassification {
  return { disposition, reason, dryRunOnly };
}

function hasInvalidMarker(value: JsonValue): boolean {
  if (value === null || typeof value !== "object") return false;
  if (Array.isArray(value)) return !isDenseArray(value) || value.some(hasInvalidMarker);
  if (typeof value.$invalid === "string") return true;
  return Object.values(value).some(hasInvalidMarker);
}

function validBytes(row: CanonicalRow, field: string, nullable: boolean): boolean {
  const value = row[field];
  if (nullable && value === null) return true;
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function validReservationRow(row: CanonicalRow): boolean {
  if (hasInvalidMarker(row) || stringField(row, "id") === null ||
      stringField(row, "actor_user_id") === null || stringField(row, "owner_user_id") === null ||
      stringField(row, "session_id") === null || !validBytes(row, "declared_bytes", false) ||
      !validBytes(row, "actual_bytes", true) || timestampField(row, "reserved_at") === null ||
      timestampField(row, "created_at") === null || timestampField(row, "updated_at") === null) {
    return false;
  }
  const state = stringField(row, "state");
  const actual = row.actual_bytes;
  const finalized = timestampField(row, "finalized_at");
  const released = timestampField(row, "released_at");
  if (state === "reserved") return actual === null && finalized === null && released === null;
  if (state === "finalized") return actual !== null && finalized !== null && released === null;
  if (state === "released") return actual === null && finalized === null && released !== null;
  return false;
}

function validHostRow(row: CanonicalRow, kind: "attachment" | "workspace"): boolean {
  if (hasInvalidMarker(row) || stringField(row, "id") === null ||
      stringField(row, "user_id") === null || stringField(row, "session_id") === null ||
      stringField(row, "r2_key") === null || timestampField(row, "created_at") === null) return false;
  if (kind === "attachment") {
    return ["pending", "ready", "failed"].includes(stringField(row, "upload_status") ?? "") &&
      validBytes(row, "size", false) && validBytes(row, "actual_bytes", true) &&
      typeof row.content_type_declared === "boolean";
  }
  return stringField(row, "kind") !== null && stringField(row, "status") !== null &&
    validBytes(row, "bytes", false) && /^[0-9a-f]{64}$/i.test(stringField(row, "sha256") ?? "") &&
    (row.generation === null || typeof row.generation === "number" && Number.isSafeInteger(row.generation));
}

function reservationState(
  rows: CanonicalRow[],
): { state: "reserved" | "finalized" | "released" | "missing" | "invalid"; row: CanonicalRow | null } {
  const relevant = rows.filter((row) => !stringField(row, "id")?.startsWith(HISTORY_PREFIX));
  if (relevant.length === 0) return { state: "missing", row: null };
  const ids = relevant.map((row) => stringField(row, "id"));
  if (ids.some((id) => id === null) || new Set(ids).size !== ids.length) {
    return { state: "invalid", row: null };
  }
  if (relevant.some((row) => !validReservationRow(row))) {
    return { state: "invalid", row: null };
  }
  const live = relevant.filter((row) => stringField(row, "state") !== "released");
  if (live.length > 1) return { state: "invalid", row: null };
  if (live.length === 1) return { state: stringField(live[0], "state") as "reserved" | "finalized", row: live[0]! };
  return { state: "released", row: relevant[relevant.length - 1]! };
}

function accountState(row: CanonicalRow | undefined): string | null {
  const value = row?.state;
  return value === null || value === undefined ? null : typeof value === "string" ? value : "invalid";
}

function hasLiveGrant(rows: CanonicalRow[], identity: ShareIdentity): boolean {
  return rows.some((row) =>
    stringField(row, "id") !== identity.chargeId &&
    nullableStringField(row, "object_id") === identity.key &&
    stringField(row, "state") === "finalized" &&
    numberField(row, "declared_bytes") === 0 && numberField(row, "actual_bytes") === 0 &&
    stringField(row, "etag")?.toLowerCase() === identity.versionHash);
}

function legacyEligibility(
  host: { kind: "attachment" | "workspace"; row: CanonicalRow },
  options: GlobalStorageClassificationOptions,
): { eligible: boolean; history?: GlobalStorageHistoryEvidence } {
  const policy = options.legacyEvidencePolicy;
  if (policy === null) return { eligible: false };
  const hostKind = host.kind === "attachment" ? "attachment" : stringField(host.row, "kind");
  if (hostKind !== "attachment" && hostKind !== "artifact") return { eligible: false };
  if (!policy.allowedHostKinds.includes(hostKind)) return { eligible: false };
  const createdAt = timestampField(host.row, "created_at");
  if (createdAt === null) return { eligible: false };
  const createdMs = Date.parse(createdAt);
  const observedMs = Date.parse(options.observedAt);
  const boundaryMs = Date.parse(policy.pre0038Boundary);
  if (createdMs > observedMs || createdMs >= boundaryMs) return { eligible: false };
  const finalizedAt = host.kind === "attachment" ? timestampField(host.row, "finalized_at") : null;
  return {
    eligible: true,
    history: {
      actorProvenance: "owner_actor_policy",
      originalFinalizedAt: finalizedAt,
      originalFinalizedAtUnknown: host.kind === "attachment" && finalizedAt === null,
      reservedAtProvenance: policy.reconstructReservedAtFromHostCreatedAt
        ? "approved_reconstruction"
        : "not_reconstructed",
    },
  };
}

function existingHistory(
  stream: GlobalStorageStream,
  host: { kind: "attachment" | "workspace"; row: CanonicalRow } | null,
  reservation: { state: string; row: CanonicalRow | null },
): GlobalStorageHistoryEvidence {
  const reservationFinalizedAt = timestampField(reservation.row ?? undefined, "finalized_at");
  const originalFinalizedAt = host?.kind === "attachment"
    ? timestampField(host.row, "finalized_at") ?? reservationFinalizedAt
    : host === null ? reservationFinalizedAt : null;
  return {
    actorProvenance: stream === "history" ? "existing_history"
      : reservation.row === null ? "unresolved" : "existing_reservation",
    originalFinalizedAt,
    originalFinalizedAtUnknown: host?.kind === "attachment" && originalFinalizedAt === null,
    reservedAtProvenance: stream === "history" ? "existing_history"
      : reservation.row === null ? "unresolved" : "existing_reservation",
  };
}

/**
 * The sole classifier/fingerprint used by all five streams. The discovering raw
 * row is retained for evidence, while current host/reservation/authority rows
 * drive the label. No branch performs or schedules a mutation.
 */
export function classifyGlobalStorageGeneration(
  input: GlobalStorageClassificationInput,
  options: GlobalStorageClassificationOptions,
): GlobalStoragePageOutcome {
  if (!STREAMS.has(input.stream) || !isRecord(input.raw)) {
    throw new GlobalStorageDiscoveryError("invalid_raw_page", "A raw row and known stream are required");
  }
  requiredTimestamp(options.observedAt, "observedAt");
  boundedInteger(options.olderThanMs, "olderThanMs", 900_000, Number.MAX_SAFE_INTEGER);
  const policy = validatePolicy(options.legacyEvidencePolicy);
  const resolved = resolveGeneration(input, input.factsComplete !== false);
  const { generation, raw, currentRaw, host } = resolved;
  const rawId = stringField(raw, "id") ?? "malformed";
  const fingerprint = `sha256:${createHash("sha256")
    .update("ovid:storage-global-generation:v1\u0000", "utf8")
    .update(canonicalStringify(generation as unknown as JsonValue), "utf8")
    .digest("hex")}`;
  let result: GlobalStorageClassification = classification("unresolved", "malformed_row", true);
  let history: GlobalStorageHistoryEvidence = {
    actorProvenance: "unresolved",
    originalFinalizedAt: null,
    originalFinalizedAtUnknown: false,
    reservedAtProvenance: "unresolved",
  };

  const effectiveIdentity = rawObject({ ...currentRaw, __stream: input.stream });
  const owner = effectiveIdentity.owner;
  const actor = effectiveIdentity.actor;
  const sessionId = effectiveIdentity.session;
  const session = generation.authority.session.length === 1 ? generation.authority.session[0] : undefined;
  const ownerAccount = generation.authority.ownerAccount.length === 1 ? generation.authority.ownerAccount[0] : undefined;
  const actorAccount = generation.authority.actorAccount.length === 1 ? generation.authority.actorAccount[0] : undefined;
  const rooms = generation.authority.collabRooms;
  const reservation = reservationState(resolved.relatedReservations);
  const rawReservationMatches = generation.reservations.filter((row) => stringField(row, "id") === rawId);
  const rawReservation = rawReservationMatches.length === 1 ? rawReservationMatches[0] : undefined;
  const currentReservation = rawReservation ?? (input.stream === "reservation" || input.stream === "share" || input.stream === "history" ? currentRaw : null);
  const dependentShares = uniqueRows([
    ...generation.dependentShares,
    ...(input.stream === "share" ? generation.reservations : []),
  ]);

  const finish = () => ({
    version: 1 as const,
    stream: input.stream,
    rawId,
    identity: resolved.share !== null
      ? `share:${resolved.share.ownerUserId}/${resolved.share.artifactId}/${resolved.share.versionHash}`
      : host !== null
        ? `${host.kind}:${stringField(host.row, "id") ?? "malformed"}`
        : input.stream === "history" ? `history:${rawId}` : `${input.stream}:${rawId}`,
    fingerprint,
    classification: result,
    generation,
    history,
  });

  if (!generation.factsComplete) {
    result = classification("unresolved", "current_facts_unavailable", true);
    return finish();
  }
  if (rawId === "malformed" || owner === null || sessionId === null || actor === null) return finish();
  if ((input.stream === "attachment" || input.stream === "workspace") && host === null) {
    result = classification("unresolved", resolved.hostAmbiguous ? "host_identity_ambiguous" : "host_changed", true);
    return finish();
  }
  if ((input.stream === "reservation" || input.stream === "share" || input.stream === "history") && rawReservation === undefined) {
    result = classification("unresolved", rawReservationMatches.length > 1 ? "reservation_identity_ambiguous" : "reservation_changed", true);
    return finish();
  }
  if (resolved.hostAmbiguous) {
    result = classification("unresolved", "host_identity_ambiguous", true);
    return finish();
  }
  if (resolved.rawCurrentIdentityMismatch) {
    result = classification("unresolved", "raw_current_identity_mismatch", true);
    return finish();
  }
  if (!generation.reservationSetComplete || !generation.dependentShareSetComplete) {
    result = classification("unresolved", "bounded_fact_set_incomplete", true);
    return finish();
  }
  if (session === undefined || stringField(session, "id") !== sessionId) {
    result = classification("foreign_identity", "session_authority_missing", true);
    return finish();
  }
  if (stringField(session, "user_id") !== owner) {
    result = classification("foreign_identity", "session_owner_mismatch", true);
    return finish();
  }
  if (ownerAccount === undefined || stringField(ownerAccount, "uid") !== owner || ownerAccount.user_present === false) {
    result = classification("foreign_identity", "owner_account_missing", true);
    return finish();
  }
  if (actorAccount === undefined || stringField(actorAccount, "uid") !== actor || actorAccount.user_present === false) {
    result = classification("unresolved", "actor_authority_unresolved", true);
    return finish();
  }
  const malformedAccount = (account: CanonicalRow) =>
    hasInvalidMarker(account) || account.user_present !== undefined && typeof account.user_present !== "boolean" ||
    accountState(account) !== null && timestampField(account, "updated_at") === null;
  const malformedRoom = (room: CanonicalRow) =>
    hasInvalidMarker(room) || stringField(room, "id") === null ||
    !["active", "closing", "closed"].includes(stringField(room, "lifecycle") ?? "") ||
    numberField(room, "generation") === null || (numberField(room, "generation") ?? 0) < 1 ||
    timestampField(room, "created_at") === null || timestampField(room, "updated_at") === null;
  if (hasInvalidMarker(session) || timestampField(session, "updated_at") === null ||
      malformedAccount(ownerAccount) || malformedAccount(actorAccount) || rooms.some(malformedRoom)) {
    result = classification("unresolved", "authority_evidence_unresolved", true);
    return finish();
  }
  if (host !== null && (stringField(host.row, "user_id") !== owner || stringField(host.row, "session_id") !== sessionId)) {
    result = classification("foreign_identity", "host_owner_session_mismatch", true);
    return finish();
  }
  if (host !== null) {
    const key = stringField(host.row, "r2_key");
    if (key === null) {
      result = classification("unresolved", "host_key_unresolved", true);
      return finish();
    }
    if (key.startsWith("users/") && !key.startsWith(`users/${owner}/`)) {
      result = classification("foreign_identity", "host_key_owner_mismatch", true);
      return finish();
    }
    if (host.kind === "attachment" && key.startsWith(`users/${owner}/sessions/`) &&
        !key.startsWith(`users/${owner}/sessions/${sessionId}/`)) {
      result = classification("foreign_identity", "host_key_session_mismatch", true);
      return finish();
    }
    if (host.kind === "workspace" && key.startsWith(`users/${owner}/artifacts/`) &&
        !key.startsWith(`users/${owner}/artifacts/${sessionId}/`)) {
      result = classification("foreign_identity", "host_key_session_mismatch", true);
      return finish();
    }
    const hostId = stringField(host.row, "id");
    if (hostId === null) {
      result = classification("unresolved", "host_key_unresolved", true);
      return finish();
    }
    const attachmentPrefix = `users/${owner}/sessions/${sessionId}/uploads/`;
    if (host.kind === "attachment" && key.startsWith(attachmentPrefix) && key !== `${attachmentPrefix}${hostId}`) {
      result = classification("foreign_identity", "host_key_identity_mismatch", true);
      return finish();
    }
    const artifactPrefix = `users/${owner}/artifacts/${sessionId}/`;
    const artifactName = key.startsWith(artifactPrefix) ? key.slice(artifactPrefix.length) : null;
    if (host.kind === "workspace" && stringField(host.row, "kind") === "artifact" && artifactName !== null &&
        artifactName !== hostId && !artifactName.startsWith(`${hostId}-`)) {
      result = classification("foreign_identity", "host_key_identity_mismatch", true);
      return finish();
    }
  }
  if (rooms.length > 1) {
    result = classification("unresolved", "collab_mapping_unresolved", true);
    return finish();
  }
  if (rooms.length === 1 && (stringField(rooms[0], "session_id") !== sessionId || stringField(rooms[0], "owner_user_id") !== owner)) {
    result = classification("foreign_identity", "collab_authority_mismatch", true);
    return finish();
  }
  const ownerLifecycle = accountState(ownerAccount);
  if (ownerLifecycle === "invalid" || !["active", "cancelled", null].includes(ownerLifecycle)) {
    result = classification("account_lifecycle_owned", "owner_account_lifecycle", true);
    return finish();
  }
  if (rooms.length === 1) {
    result = classification("collab_lifecycle_owned", "canonical_collab_room", true);
    history = existingHistory(input.stream, host, reservation);
    return finish();
  }

  const attemptLike = rawId.includes(":collab-attempt:") ||
    (host?.kind === "workspace" && host.row.meta !== null && host.row.meta !== undefined &&
      typeof host.row.meta === "object" && !Array.isArray(host.row.meta) &&
      (host.row.meta.attemptReservationId !== undefined || host.row.meta.attemptNumber !== undefined));
  if (attemptLike) {
    result = classification("unresolved", "collab_mapping_unresolved", true);
    return finish();
  }

  const rawShapeValid = input.stream === "attachment"
    ? validHostRow(raw, "attachment")
    : input.stream === "workspace" ? validHostRow(raw, "workspace") : validReservationRow(raw);
  const currentShapeValid = input.stream === "attachment"
    ? validHostRow(currentRaw, "attachment")
    : input.stream === "workspace" ? validHostRow(currentRaw, "workspace") : validReservationRow(currentRaw);
  if (!rawShapeValid || !currentShapeValid || host !== null && !validHostRow(host.row, host.kind)) {
    result = classification("unresolved", "malformed_row", true);
    return finish();
  }

  history = existingHistory(input.stream, host, reservation);

  if (input.stream === "share") {
    const share = resolved.share;
    const shareIds = dependentShares.map((row) => stringField(row, "id"));
    if (shareIds.some((id) => id === null) || new Set(shareIds).size !== shareIds.length) {
      result = classification("unresolved", "share_identity_unresolved", true);
      return finish();
    }
    const shareObject = nullableStringField(currentReservation ?? currentRaw, "object_id");
    if (share === null || shareObject === null || shareObject === undefined) {
      result = classification("unresolved", "share_identity_unresolved", true);
      return finish();
    }
    if (share.ownerUserId !== owner || actor !== owner || shareObject !== share.key && shareObject !== `charge:${share.key}`) {
      result = classification("foreign_identity", "share_identity_mismatch", true);
      return finish();
    }
    if (host === null) {
      result = classification("unresolved", "share_source_unresolved", true);
      return finish();
    }
    if (stringField(host.row, "kind") !== "artifact") {
      result = classification("foreign_identity", "share_identity_mismatch", true);
      return finish();
    }
    if (stringField(host.row, "sha256")?.toLowerCase() !== share.versionHash) {
      result = classification("foreign_identity", "share_identity_mismatch", true);
      return finish();
    }
    const isCharge = shareObject === `charge:${share.key}`;
    const currentShareId = stringField(currentReservation ?? currentRaw, "id");
    if ((isCharge && currentShareId !== share.chargeId) ||
        (!isCharge && currentShareId?.startsWith("artifact-share:") === true)) {
      result = classification("foreign_identity", "share_identity_mismatch", true);
      return finish();
    }
    if (!isCharge) {
      const declared = numberField(currentReservation ?? currentRaw, "declared_bytes");
      const actual = numberField(currentReservation ?? currentRaw, "actual_bytes");
      const state = stringField(currentReservation ?? currentRaw, "state");
      if (declared !== 0 || stringField(currentReservation ?? currentRaw, "etag")?.toLowerCase() !== share.versionHash ||
          !(state === "finalized" && actual === 0 || state === "released" && actual === null && currentRaw.actual_bytes === null)) {
        result = classification("foreign_identity", "share_identity_mismatch", true);
        return finish();
      }
    }
    const grants = dependentShares.filter((row) =>
      stringField(row, "id") !== share.chargeId && nullableStringField(row, "object_id") === share.key);
    if (grants.some((row) => stringField(row, "owner_user_id") !== share.ownerUserId ||
        stringField(row, "actor_user_id") !== share.ownerUserId ||
        stringField(row, "session_id") !== stringField(host.row, "session_id"))) {
      result = classification("foreign_identity", "share_identity_mismatch", true);
      return finish();
    }
    if (grants.some((row) => numberField(row, "declared_bytes") !== 0 ||
        stringField(row, "etag")?.toLowerCase() !== share.versionHash ||
        stringField(row, "state") === "finalized" && numberField(row, "actual_bytes") !== 0)) {
      result = classification("foreign_identity", "share_identity_mismatch", true);
      return finish();
    }
    if (grants.some((row) => !validReservationRow(row) || stringField(row, "state") === "reserved")) {
      result = classification("unresolved", "share_identity_unresolved", true);
      return finish();
    }
    if (hasLiveGrant(grants, share)) {
      result = classification("share_candidate", "live_grant_preserves_copy", true);
      return finish();
    }
    const charges = dependentShares.filter((row) => nullableStringField(row, "object_id") === `charge:${share.key}`);
    if (charges.some((row) => stringField(row, "id") !== share.chargeId ||
        stringField(row, "owner_user_id") !== share.ownerUserId ||
        stringField(row, "actor_user_id") !== share.ownerUserId ||
        stringField(row, "session_id") !== stringField(host.row, "session_id"))) {
      result = classification("foreign_identity", "share_identity_mismatch", true);
      return finish();
    }
    if (charges.some((row) => !validReservationRow(row))) {
      result = classification("unresolved", "share_identity_unresolved", true);
      return finish();
    }
    result = classification("share_candidate", "unreferenced_share_review", true);
    return finish();
  }

  if (host !== null && host.kind === "workspace" && stringField(host.row, "kind") !== "artifact") {
    result = classification("unresolved", "unsupported_host_kind", true);
    return finish();
  }

  if (host?.kind === "workspace" && stringField(host.row, "status") === "active") {
    if (reservation.state === "released") {
      result = classification("unresolved", "live_accounting_inconsistent", true);
    } else if (reservation.state === "invalid") {
      result = classification("unresolved", "reservation_set_unresolved", true);
    } else if (reservation.state === "missing") {
      const legacy = legacyEligibility(host, { ...options, legacyEvidencePolicy: policy });
      if (legacy.eligible) {
        result = classification("ordinary_candidate", "active_source_reconciliation", false);
        history = legacy.history!;
      } else {
        result = classification("unresolved", "legacy_evidence_unresolved", true);
      }
    } else {
      result = classification("ordinary_candidate", "active_source_reconciliation", false);
    }
    return finish();
  }

  if (host?.kind === "attachment" && ["ready", "pending"].includes(stringField(host.row, "upload_status") ?? "")) {
    if (reservation.state === "released") {
      result = classification("unresolved", "live_host_reservation_inconsistent", true);
    } else if (reservation.state === "invalid") {
      result = classification("unresolved", "reservation_set_unresolved", true);
    } else if (reservation.state === "missing") {
      const legacy = legacyEligibility(host, { ...options, legacyEvidencePolicy: policy });
      if (legacy.eligible) {
        result = classification("ordinary_candidate", "legacy_evidence_candidate", false);
        history = legacy.history!;
      } else {
        result = classification("unresolved", "legacy_evidence_unresolved", true);
      }
    } else {
      const stale = stringField(host.row, "upload_status") === "pending" && reservation.state === "reserved" &&
        timestampField(reservation.row ?? undefined, "reserved_at") !== null &&
        Date.parse(timestampField(reservation.row ?? undefined, "reserved_at")!) <= Date.parse(options.observedAt) - options.olderThanMs;
      result = classification("ordinary_candidate", stale ? "stale_reserved_attachment" : "attachment_reconciliation", false);
    }
    return finish();
  }

  if (host?.kind === "workspace" && stringField(host.row, "status") === "deleted") {
    if (reservation.state === "invalid") {
      result = classification("unresolved", "reservation_set_unresolved", true);
    } else if (timestampField(session, "deleted_at") !== null) {
      result = classification("unresolved", "soft_deleted_session_retains_files", true);
    } else if (dependentShares.length > 0) {
      result = classification("ordinary_candidate", "deleted_source_shares_pending", true);
    } else {
      result = classification("ordinary_candidate", "deleted_source_reconciliation", false);
    }
    return finish();
  }

  if (host?.kind === "workspace") {
    result = classification("unresolved", "workspace_generation_unresolved", true);
    return finish();
  }

  if (host?.kind === "attachment" && stringField(host.row, "upload_status") === "failed") {
    if (reservation.state === "reserved" || reservation.state === "finalized") {
      result = classification("ordinary_candidate", "failed_host_accounting_reconciliation", false);
    } else if (reservation.state === "released") {
      result = timestampField(session, "deleted_at") !== null
        ? classification("unresolved", "soft_deleted_session_retains_files", true)
        : classification("ordinary_candidate", "terminal_physical_candidate", false);
    } else {
      result = classification("unresolved", "failed_host_reservation_unresolved", true);
    }
    return finish();
  }

  if (host?.kind === "attachment") {
    result = classification("unresolved", "attachment_generation_unresolved", true);
    return finish();
  }

  if (input.stream === "history") {
    const id = stringField(currentRaw, "id");
    const objectId = nullableStringField(currentRaw, "object_id");
    const originalId = resolved.identity.originalReservationId;
    const originalMatches = originalId === null ? [] : generation.reservations.filter((row) =>
      stringField(row, "id") === originalId);
    if (originalId === null || originalMatches.length !== 1) {
      result = classification("unresolved", "history_original_unresolved", true);
      return finish();
    }
    const original = originalMatches[0]!;
    const originalObject = nullableStringField(original, "object_id");
    const originalObjectIdentity = originalObject === null ? originalId : originalObject;
    const identityMatches = originalObjectIdentity !== undefined && originalObjectIdentity !== "" &&
      id === `${HISTORY_PREFIX}${originalId}` &&
      objectId === `${HISTORY_PREFIX}${originalObjectIdentity}` &&
      stringField(currentRaw, "owner_user_id") === stringField(original, "owner_user_id") &&
      stringField(currentRaw, "actor_user_id") === stringField(original, "actor_user_id") &&
      stringField(currentRaw, "session_id") === stringField(original, "session_id");
    if (!identityMatches) {
      result = classification("foreign_identity", "history_identity_mismatch", true);
      return finish();
    }
    const validShape = id?.startsWith(HISTORY_PREFIX) === true && objectId?.startsWith(HISTORY_PREFIX) === true &&
      stringField(currentRaw, "state") === "finalized" && numberField(currentRaw, "declared_bytes") === 0 &&
      numberField(currentRaw, "actual_bytes") === 0 && timestampField(currentRaw, "reserved_at") !== null &&
      timestampField(currentRaw, "finalized_at") !== null && currentRaw.released_at === null &&
      reservation.state !== "invalid" && stringField(original, "state") === "released";
    if (!validShape) {
      result = classification("unresolved", "unrecognized_history_shape", true);
      return finish();
    }
    history = {
      actorProvenance: "existing_history",
      originalFinalizedAt: timestampField(currentRaw, "finalized_at"),
      originalFinalizedAtUnknown: false,
      reservedAtProvenance: "existing_history",
    };
    result = classification("history_candidate", "successful_upload_history", true);
    return finish();
  }

  if (input.stream === "reservation") {
    if (stringField(currentRaw, "state") === "finalized" &&
        numberField(currentRaw, "declared_bytes") === 0 && numberField(currentRaw, "actual_bytes") === 0) {
      result = classification("unresolved", "unrecognized_history_shape", true);
    } else if (reservation.state === "reserved" || reservation.state === "finalized") {
      result = classification("ordinary_candidate", "missing_host_accounting_reconciliation", false);
    } else {
      result = classification("unresolved", "missing_host_reservation_unresolved", true);
    }
    return finish();
  }

  return finish();
}

function rawOwner(stream: GlobalStorageStream, raw: Record<string, unknown>): string {
  const value = stream === "attachment" || stream === "workspace" ? raw.user_id : raw.owner_user_id;
  return typeof value === "string" && value !== "" ? value : "\u0000malformed-owner";
}

function emptyPage(
  cursor: GlobalStorageCursor,
  scanComplete: boolean,
  reportCompleteForApproval: boolean,
  stopReason: GlobalStorageStopReason,
): GlobalStorageRawPage {
  return {
    outcomes: [],
    examinedRawRows: 0,
    scanComplete,
    reportCompleteForApproval,
    nextCursor: scanComplete ? null : { ...cursor },
    stopReason,
    ownersTouched: 0,
  };
}

/** Read one bounded raw page. Every examined valid-ID row produces an outcome and advances afterId. */
export async function readGlobalStoragePage(
  db: Db,
  options: GlobalStoragePageOptions,
  runtime: GlobalStorageReadRuntime,
): Promise<GlobalStorageRawPage> {
  validatePageOptions(options);
  if (typeof runtime.now !== "function" || typeof runtime.deadlineExceeded !== "function") {
    throw new GlobalStorageDiscoveryError("invalid_options", "Runtime clock/deadline are required separately");
  }
  const now = runtime.now();
  if (!(now instanceof Date) || !Number.isFinite(now.getTime())) {
    throw new GlobalStorageDiscoveryError("invalid_clock", "Invalid discovery clock");
  }
  const observedAt = now.toISOString();
  const cursor = options.cursor;
  if (cursor.highWaterId === "" || cursor.afterId === cursor.highWaterId) {
    return emptyPage(cursor, true, true, null);
  }
  if (runtime.deadlineExceeded()) return emptyPage(cursor, false, false, "deadline");

  const client = clientOf(db);
  const rawRows = await client.unsafe(`
    SELECT ${streamColumns(cursor.stream)}
      FROM ${streamTable(cursor.stream)}
     WHERE ($1::text IS NULL OR id > $1::text) AND id <= $2::text ${streamFilter(cursor.stream)}
     ORDER BY id LIMIT $3::int`, [cursor.afterId, cursor.highWaterId, options.bounds.scanLimit + 1]);
  if (!isDenseArray(rawRows)) {
    throw new GlobalStorageDiscoveryError("invalid_raw_page", "Raw reader did not return a dense array");
  }

  const outcomes: GlobalStoragePageOutcome[] = [];
  const owners = new Set<string>();
  let afterId = cursor.afterId;
  let index = 0;
  let stopReason: GlobalStorageStopReason = null;

  for (; index < rawRows.length; index++) {
    if (index >= options.bounds.scanLimit) {
      stopReason = "scan_limit";
      break;
    }
    if (runtime.deadlineExceeded()) {
      stopReason = "deadline";
      break;
    }
    if (outcomes.length >= options.bounds.reportLimit) {
      stopReason = "report_limit";
      break;
    }
    const raw = rawRows[index];
    if (!isRecord(raw)) {
      throw new GlobalStorageDiscoveryError("malformed_cursor_identity", "Raw row is not an object");
    }
    const rawId = raw.id;
    if (typeof rawId !== "string" || rawId === "") {
      // No valid immutable key exists, so advancing would skip an unexaminable row.
      throw new GlobalStorageDiscoveryError("malformed_cursor_identity", "Raw row has no valid cursor primary key");
    }
    if (rawId > cursor.highWaterId || afterId !== null && rawId <= afterId) {
      throw new GlobalStorageDiscoveryError("invalid_raw_page", "Raw reader escaped its ordered high-water keyset");
    }
    const owner = rawOwner(cursor.stream, raw);
    if (!owners.has(owner) && owners.size >= options.bounds.maxOwners) {
      stopReason = "owner_limit";
      break;
    }
    if (runtime.deadlineExceeded()) {
      stopReason = "deadline";
      break;
    }

    let currentFacts: GlobalStorageCurrentFacts;
    let factsComplete = true;
    try {
      currentFacts = await readCurrentFacts(client, cursor.stream, raw);
    } catch {
      // One bounded failed attempt becomes an explicit unresolved outcome. The
      // raw cursor can progress, but incomplete current facts block approval.
      currentFacts = emptyFacts();
      factsComplete = false;
    }
    const outcome = classifyGlobalStorageGeneration(
      { stream: cursor.stream, raw, facts: currentFacts, factsComplete },
      { observedAt, olderThanMs: options.olderThanMs, legacyEvidencePolicy: options.legacyEvidencePolicy },
    );
    outcomes.push(outcome);
    owners.add(owner);
    afterId = rawId;

    if (runtime.deadlineExceeded()) {
      stopReason = "deadline";
      index++;
      break;
    }
  }

  const allFetchedRowsExamined = index >= rawRows.length;
  const scanComplete = allFetchedRowsExamined && rawRows.length <= options.bounds.scanLimit;
  const reportCompleteForApproval = stopReason !== "deadline" && outcomes.every((outcome) =>
    outcome.generation.factsComplete && outcome.classification.reason !== "raw_current_identity_mismatch");
  return {
    outcomes,
    examinedRawRows: outcomes.length,
    scanComplete,
    reportCompleteForApproval,
    nextCursor: scanComplete ? null : { ...cursor, afterId },
    stopReason: scanComplete ? stopReason : stopReason ?? "scan_limit",
    ownersTouched: owners.size,
  };
}
