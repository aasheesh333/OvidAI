import { createHash } from "node:crypto";

/**
 * UNWIRED no-storage-I/O dry-run projection for global storage discovery.
 * ExactDryRunOptions is data only. Execution owns the read port, clock, and
 * optional caller signal; none is serialized. There is no apply entrypoint,
 * storage/share port, timer, scheduler, route, or durable cursor/report store.
 * These are structural wire types only; the sole generation classifier and
 * fingerprint implementation remains in the new @ovid/db module.
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
export type JsonObject = { [key: string]: JsonValue };

export interface GlobalStorageCursor {
  schemaVersion: 1;
  cycleId: string;
  stream: GlobalStorageStream;
  highWaterId: string;
  afterId: string | null;
}

export interface LegacyEvidencePolicy {
  policyId: string;
  pre0038Boundary: string;
  allowedHostKinds: Array<"attachment" | "artifact">;
  creationAdmissionRule: "host_created_at_before_boundary";
  actorEvidenceRule: "owner_is_actor";
  reconstructReservedAtFromHostCreatedAt: boolean;
  rollingHistoryPolicyId: string;
  rollingHistoryMeaning: string;
}

/** Canonical, serializable semantics only: no handles, functions, secrets, or object identity. */
export interface ExactDryRunOptions {
  schemaVersion: 1;
  reportFormatVersion: 1;
  cycleId: string;
  stream: GlobalStorageStream;
  highWaterId: string;
  afterId: string | null;
  legacyEvidencePolicy: LegacyEvidencePolicy | null;
  olderThanMs: number;
  scanLimit: number;
  /** Exactly zero: this patch requests no HEAD or other storage operation. */
  ioLimit: 0;
  maxOwners: number;
  perOwnerIoLimit: number;
  reportLimit: number;
  deadlineMs: number;
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
  dryRunOnly: boolean;
}

export interface GlobalStorageGenerationView {
  version: 1;
  stream: GlobalStorageStream;
  raw: JsonObject;
  attachments: JsonObject[];
  workspaceObjects: JsonObject[];
  reservations: JsonObject[];
  reservationSetComplete: boolean;
  dependentShares: JsonObject[];
  dependentShareSetComplete: boolean;
  authority: {
    session: JsonObject[];
    ownerAccount: JsonObject[];
    actorAccount: JsonObject[];
    collabRooms: JsonObject[];
  };
  factsComplete: boolean;
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
  generation: GlobalStorageGenerationView;
  history: GlobalStorageHistoryEvidence;
}

export type GlobalStorageStopReason =
  | "scan_limit"
  | "owner_limit"
  | "report_limit"
  | "deadline"
  | "aborted"
  | null;

export interface GlobalStorageDryRunPage {
  outcomes: GlobalStoragePageOutcome[];
  examinedRawRows: number;
  scanComplete: boolean;
  reportCompleteForApproval: boolean;
  nextCursor: GlobalStorageCursor | null;
  stopReason: GlobalStorageStopReason;
  ownersTouched: number;
}

export interface GlobalStorageReadPageRequest {
  options: ExactDryRunOptions;
  observedAt: string;
  deadlineExceeded: () => boolean;
}

export interface GlobalStorageDiscoveryExecution {
  readPage(request: GlobalStorageReadPageRequest): Promise<GlobalStorageDryRunPage>;
  now: () => Date;
  signal?: AbortSignal;
}

export type GlobalStorageReviewAction =
  | "ordinary_review"
  | "collab_review"
  | "account_lifecycle_review"
  | "foreign_review"
  | "share_review"
  | "history_review"
  | "unresolved_review";

export interface GlobalStorageReportOutcome extends GlobalStoragePageOutcome {
  head: "not_requested";
  measuredBytes: null;
  measuredContentType: null;
  observedAt: string;
  proposedAction: GlobalStorageReviewAction;
  proposedActionReason: string;
  accountingOutcome: "notAttempted";
  physicalOutcome: "notAttempted";
  readbackOutcome: "notAttempted";
  completeness: {
    scanComplete: boolean;
    reportCompleteForApproval: boolean;
  };
}

export interface GlobalStorageDryRunReportView {
  reportFormatVersion: 1;
  options: ExactDryRunOptions;
  cycle: {
    cycleId: string;
    stream: GlobalStorageStream;
    highWaterId: string;
    startingAfterId: string | null;
    endingAfterId: string | null;
  };
  page: {
    examinedRawRows: number;
    ownersTouched: number;
    stopReason: GlobalStorageStopReason;
  };
  nextCursor: GlobalStorageCursor | null;
  outcomes: GlobalStorageReportOutcome[];
  scanComplete: boolean;
  reportCompleteForApproval: boolean;
  byteEvidenceComplete: false;
  rollingHistoryComplete: false;
  usedBytes: null;
  projectedUsedBytes: null;
  dbDiscoverableCoverageOnly: true;
}

export interface GlobalStorageDryRunReport {
  bytes: Uint8Array;
  sha256: string;
  view: GlobalStorageDryRunReportView;
}

export class GlobalStorageReportError extends Error {
  readonly name = "GlobalStorageReportError";

  constructor(readonly code: "invalid_canonical_value" | "invalid_options" | "invalid_cursor" | "invalid_page" | "invalid_clock", message: string) {
    super(message);
  }
}

const STREAMS = new Set<string>(GLOBAL_STORAGE_STREAMS);
const DISPOSITIONS = new Set<GlobalStorageDisposition>([
  "ordinary_candidate",
  "collab_lifecycle_owned",
  "account_lifecycle_owned",
  "foreign_identity",
  "share_candidate",
  "history_candidate",
  "unresolved",
]);
const STOP_REASONS = new Set(["scan_limit", "owner_limit", "report_limit", "deadline", "aborted"]);
const ACTOR_PROVENANCE = new Set([
  "existing_reservation",
  "existing_history",
  "owner_actor_policy",
  "unresolved",
  "not_applicable",
]);
const RESERVED_AT_PROVENANCE = new Set([
  "existing_reservation",
  "existing_history",
  "approved_reconstruction",
  "not_reconstructed",
  "unresolved",
  "not_applicable",
]);
const CURSOR_KEYS = ["afterId", "cycleId", "highWaterId", "schemaVersion", "stream"];
const OPTION_KEYS = [
  "afterId",
  "cycleId",
  "deadlineMs",
  "highWaterId",
  "ioLimit",
  "legacyEvidencePolicy",
  "maxOwners",
  "olderThanMs",
  "perOwnerIoLimit",
  "reportFormatVersion",
  "reportLimit",
  "scanLimit",
  "schemaVersion",
  "stream",
];
const POLICY_KEYS = [
  "actorEvidenceRule",
  "allowedHostKinds",
  "creationAdmissionRule",
  "policyId",
  "pre0038Boundary",
  "reconstructReservedAtFromHostCreatedAt",
  "rollingHistoryMeaning",
  "rollingHistoryPolicyId",
];

function isRecord(value: unknown): value is Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function assertDenseArray(
  value: unknown,
  label: string,
  code: GlobalStorageReportError["code"],
): asserts value is unknown[] {
  if (!Array.isArray(value)) {
    throw new GlobalStorageReportError(code, `${label} must be an array`);
  }
  for (let index = 0; index < value.length; index++) {
    if (!Object.prototype.hasOwnProperty.call(value, index) || value[index] === undefined) {
      throw new GlobalStorageReportError(code, `${label} must be a dense array without missing or undefined index ${index}`);
    }
  }
}

function exactKeys(value: Record<string, unknown>, expected: readonly string[], label: string): void {
  const allowed = new Set(expected);
  const unknown = Object.keys(value).filter((key) => !allowed.has(key));
  if (unknown.length > 0 || Object.keys(value).length !== expected.length) {
    throw new GlobalStorageReportError("invalid_options", `${label} has unrecognized or missing fields: ${unknown.join(",")}`);
  }
}

function requiredString(value: unknown, field: string, allowEmpty = false): string {
  if (typeof value !== "string" || (!allowEmpty && value.trim() === "")) {
    throw new GlobalStorageReportError("invalid_options", `${field} must be a nonempty string`);
  }
  return value;
}

function safeInteger(value: unknown, field: string, minimum: number, maximum: number): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || Object.is(value, -0) ||
      value < minimum || value > maximum) {
    throw new GlobalStorageReportError("invalid_options", `${field} must be a safe integer ${minimum}..${maximum}`);
  }
  return value;
}

function canonicalTimestamp(value: unknown, field: string): string {
  if (typeof value !== "string") {
    throw new GlobalStorageReportError("invalid_options", `${field} must be an RFC 3339 UTC string`);
  }
  const date = new Date(value);
  if (!Number.isFinite(date.getTime()) || date.toISOString() !== value) {
    throw new GlobalStorageReportError("invalid_options", `${field} must be canonical RFC 3339 UTC`);
  }
  return value;
}

function canonicalize(value: unknown, seen = new Set<object>()): JsonValue {
  if (value === null || typeof value === "string" || typeof value === "boolean") return value;
  if (typeof value === "number") {
    if (!Number.isFinite(value) || (Number.isInteger(value) && !Number.isSafeInteger(value))) {
      throw new GlobalStorageReportError("invalid_canonical_value", "JSON numbers must be finite and safe");
    }
    return value;
  }
  if (typeof value !== "object" || value === null) {
    throw new GlobalStorageReportError("invalid_canonical_value", "Only exact JSON values are serializable");
  }
  if (seen.has(value)) {
    throw new GlobalStorageReportError("invalid_canonical_value", "Cyclic values are not JSON");
  }
  seen.add(value);
  try {
    if (Array.isArray(value)) {
      assertDenseArray(value, "array", "invalid_canonical_value");
      return value.map((entry) => canonicalize(entry, seen));
    }
    if (!isRecord(value)) {
      throw new GlobalStorageReportError("invalid_canonical_value", "Only plain JSON objects are serializable");
    }
    const result: JsonObject = {};
    for (const key of Object.keys(value).sort()) {
      const field = value[key];
      if (field === undefined) {
        throw new GlobalStorageReportError("invalid_canonical_value", "Undefined is not canonical JSON");
      }
      result[key] = canonicalize(field, seen);
    }
    return result;
  } finally {
    seen.delete(value);
  }
}

/** UTF-8 JSON with recursively sorted object keys and significant array order. */
export function canonicalStorageGlobalJson(value: unknown): string {
  return JSON.stringify(canonicalize(value));
}

function parseCursor(value: unknown): GlobalStorageCursor {
  if (!isRecord(value)) throw new GlobalStorageReportError("invalid_cursor", "Cursor must be an object");
  exactKeys(value, CURSOR_KEYS, "cursor");
  if (value.schemaVersion !== 1 || typeof value.stream !== "string" || !STREAMS.has(value.stream)) {
    throw new GlobalStorageReportError("invalid_cursor", "Unknown cursor schema or stream");
  }
  const cycleId = requiredString(value.cycleId, "cursor.cycleId");
  const highWaterId = requiredString(value.highWaterId, "cursor.highWaterId", true);
  const afterId = value.afterId === null ? null : requiredString(value.afterId, "cursor.afterId");
  if (highWaterId === "" && afterId !== null) {
    throw new GlobalStorageReportError("invalid_cursor", "An empty cycle cannot have an after cursor");
  }
  if (afterId !== null && highWaterId !== "" && afterId > highWaterId) {
    throw new GlobalStorageReportError("invalid_cursor", "Cursor exceeds its high-water ID");
  }
  return {
    schemaVersion: 1,
    cycleId,
    stream: value.stream as GlobalStorageStream,
    highWaterId,
    afterId,
  };
}

export function encodeGlobalStorageCursor(cursor: GlobalStorageCursor): string {
  return canonicalStorageGlobalJson(parseCursor(cursor));
}

export function decodeGlobalStorageCursor(encoded: string | Uint8Array): GlobalStorageCursor {
  let text: string;
  try {
    text = typeof encoded === "string" ? encoded : new TextDecoder("utf-8", { fatal: true }).decode(encoded);
  } catch {
    throw new GlobalStorageReportError("invalid_cursor", "Cursor is not exact UTF-8");
  }
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new GlobalStorageReportError("invalid_cursor", "Cursor is not JSON");
  }
  const cursor = parseCursor(value);
  const canonicalText = canonicalStorageGlobalJson(cursor);
  if (canonicalText !== text) {
    throw new GlobalStorageReportError("invalid_cursor", "Cursor JSON is not canonical");
  }
  if (typeof encoded !== "string") {
    const canonicalBytes = new TextEncoder().encode(canonicalText);
    if (canonicalBytes.length !== encoded.length || canonicalBytes.some((byte, index) => byte !== encoded[index])) {
      throw new GlobalStorageReportError("invalid_cursor", "Cursor bytes are not exact canonical UTF-8");
    }
  }
  return cursor;
}

function parseLegacyPolicy(value: unknown): LegacyEvidencePolicy | null {
  if (value === null) return null;
  if (!isRecord(value)) throw new GlobalStorageReportError("invalid_options", "Legacy policy must be an object or null");
  exactKeys(value, POLICY_KEYS, "legacyEvidencePolicy");
  const allowedHostKinds = value.allowedHostKinds;
  assertDenseArray(allowedHostKinds, "legacyEvidencePolicy.allowedHostKinds", "invalid_options");
  if (allowedHostKinds.length === 0 ||
      allowedHostKinds.some((kind) => kind !== "attachment" && kind !== "artifact") ||
      new Set(allowedHostKinds).size !== allowedHostKinds.length) {
    throw new GlobalStorageReportError("invalid_options", "Invalid legacy host-kind scope");
  }
  if (value.creationAdmissionRule !== "host_created_at_before_boundary" ||
      value.actorEvidenceRule !== "owner_is_actor" ||
      typeof value.reconstructReservedAtFromHostCreatedAt !== "boolean") {
    throw new GlobalStorageReportError("invalid_options", "Invalid legacy evidence rule");
  }
  return {
    policyId: requiredString(value.policyId, "legacyEvidencePolicy.policyId"),
    pre0038Boundary: canonicalTimestamp(value.pre0038Boundary, "legacyEvidencePolicy.pre0038Boundary"),
    allowedHostKinds: [...allowedHostKinds] as Array<"attachment" | "artifact">,
    creationAdmissionRule: "host_created_at_before_boundary",
    actorEvidenceRule: "owner_is_actor",
    reconstructReservedAtFromHostCreatedAt: value.reconstructReservedAtFromHostCreatedAt,
    rollingHistoryPolicyId: requiredString(value.rollingHistoryPolicyId, "legacyEvidencePolicy.rollingHistoryPolicyId"),
    rollingHistoryMeaning: requiredString(value.rollingHistoryMeaning, "legacyEvidencePolicy.rollingHistoryMeaning"),
  };
}

export function parseExactDryRunOptions(value: unknown): ExactDryRunOptions {
  if (!isRecord(value)) throw new GlobalStorageReportError("invalid_options", "Options must be an object");
  exactKeys(value, OPTION_KEYS, "options");
  const cursor = parseCursor({
    schemaVersion: value.schemaVersion,
    cycleId: value.cycleId,
    stream: value.stream,
    highWaterId: value.highWaterId,
    afterId: value.afterId,
  });
  if (value.reportFormatVersion !== 1) {
    throw new GlobalStorageReportError("invalid_options", "Unknown report format version");
  }
  return {
    ...cursor,
    reportFormatVersion: 1,
    legacyEvidencePolicy: parseLegacyPolicy(value.legacyEvidencePolicy),
    olderThanMs: safeInteger(value.olderThanMs, "olderThanMs", 900_000, Number.MAX_SAFE_INTEGER),
    scanLimit: safeInteger(value.scanLimit, "scanLimit", 1, 100),
    ioLimit: safeInteger(value.ioLimit, "ioLimit", 0, 0) as 0,
    maxOwners: safeInteger(value.maxOwners, "maxOwners", 1, 16),
    perOwnerIoLimit: safeInteger(value.perOwnerIoLimit, "perOwnerIoLimit", 1, 8),
    reportLimit: safeInteger(value.reportLimit, "reportLimit", 1, 100),
    deadlineMs: safeInteger(value.deadlineMs, "deadlineMs", 1, Number.MAX_SAFE_INTEGER),
  };
}

function cursorFromOptions(options: ExactDryRunOptions): GlobalStorageCursor {
  return {
    schemaVersion: 1,
    cycleId: options.cycleId,
    stream: options.stream,
    highWaterId: options.highWaterId,
    afterId: options.afterId,
  };
}

function sameScope(left: GlobalStorageCursor, right: GlobalStorageCursor): boolean {
  return left.schemaVersion === right.schemaVersion && left.cycleId === right.cycleId &&
    left.stream === right.stream && left.highWaterId === right.highWaterId;
}

function pageInteger(value: unknown, field: string, minimum: number, maximum: number): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new GlobalStorageReportError("invalid_page", `${field} is outside its page bound`);
  }
  return value;
}

function validateOutcome(value: unknown, options: ExactDryRunOptions): GlobalStoragePageOutcome {
  if (!isRecord(value) || value.version !== 1 || value.stream !== options.stream ||
      typeof value.rawId !== "string" || value.rawId === "" ||
      typeof value.identity !== "string" || value.identity === "" ||
      typeof value.fingerprint !== "string" || !/^sha256:[0-9a-f]{64}$/.test(value.fingerprint)) {
    throw new GlobalStorageReportError("invalid_page", "Outcome identity or full fingerprint is missing");
  }
  if (options.highWaterId === "" || value.rawId > options.highWaterId ||
      options.afterId !== null && value.rawId <= options.afterId) {
    throw new GlobalStorageReportError("invalid_page", "Outcome is outside the immutable keyset");
  }
  if (!isRecord(value.classification) || !DISPOSITIONS.has(value.classification.disposition as GlobalStorageDisposition) ||
      typeof value.classification.reason !== "string" || value.classification.reason === "" ||
      typeof value.classification.dryRunOnly !== "boolean") {
    throw new GlobalStorageReportError("invalid_page", "Outcome classification is malformed");
  }
  const generation = value.generation;
  if (!isRecord(generation) || generation.version !== 1 || generation.stream !== options.stream ||
      !isRecord(generation.raw) || typeof generation.factsComplete !== "boolean" ||
      !Array.isArray(generation.attachments) || !Array.isArray(generation.workspaceObjects) ||
      !Array.isArray(generation.reservations) || !Array.isArray(generation.dependentShares) ||
      typeof generation.reservationSetComplete !== "boolean" ||
      typeof generation.dependentShareSetComplete !== "boolean" ||
      !isRecord(generation.authority) ||
      !Array.isArray(generation.authority.session) || !Array.isArray(generation.authority.ownerAccount) ||
      !Array.isArray(generation.authority.actorAccount) || !Array.isArray(generation.authority.collabRooms)) {
    throw new GlobalStorageReportError("invalid_page", "Outcome generation is incomplete");
  }
  for (const field of ["attachments", "workspaceObjects", "reservations", "dependentShares"] as const) {
    assertDenseArray(generation[field], `generation.${field}`, "invalid_page");
  }
  for (const field of ["session", "ownerAccount", "actorAccount", "collabRooms"] as const) {
    assertDenseArray(generation.authority[field], `generation.authority.${field}`, "invalid_page");
  }
  if (!isRecord(value.history) ||
      typeof value.history.actorProvenance !== "string" || !ACTOR_PROVENANCE.has(value.history.actorProvenance) ||
      !(typeof value.history.originalFinalizedAt === "string" || value.history.originalFinalizedAt === null) ||
      typeof value.history.originalFinalizedAtUnknown !== "boolean" ||
      typeof value.history.reservedAtProvenance !== "string" || !RESERVED_AT_PROVENANCE.has(value.history.reservedAtProvenance)) {
    throw new GlobalStorageReportError("invalid_page", "Outcome history provenance is incomplete");
  }
  if (value.history.originalFinalizedAtUnknown === true && value.history.originalFinalizedAt !== null) {
    throw new GlobalStorageReportError("invalid_page", "Unknown original finalization cannot carry a timestamp");
  }
  if (typeof value.history.originalFinalizedAt === "string") {
    canonicalTimestamp(value.history.originalFinalizedAt, "history.originalFinalizedAt");
  }
  return value as unknown as GlobalStoragePageOutcome;
}

function validatePage(options: ExactDryRunOptions, page: GlobalStorageDryRunPage): GlobalStorageDryRunPage {
  if (!isRecord(page) || !Array.isArray(page.outcomes) ||
      typeof page.scanComplete !== "boolean" || typeof page.reportCompleteForApproval !== "boolean") {
    throw new GlobalStorageReportError("invalid_page", "Malformed dry-run page");
  }
  assertDenseArray(page.outcomes, "page.outcomes", "invalid_page");
  const examined = pageInteger(page.examinedRawRows, "examinedRawRows", 0, options.scanLimit);
  pageInteger(page.ownersTouched, "ownersTouched", 0, options.maxOwners);
  if (page.outcomes.length !== examined || page.outcomes.length > options.reportLimit ||
      examined > 0 && page.ownersTouched < 1 || examined === 0 && page.ownersTouched !== 0) {
    throw new GlobalStorageReportError("invalid_page", "Page examined-row, outcome, owner, or report bound is inconsistent");
  }
  if (page.stopReason !== null && (typeof page.stopReason !== "string" || !STOP_REASONS.has(page.stopReason))) {
    throw new GlobalStorageReportError("invalid_page", "Unknown page stop reason");
  }
  if (!page.scanComplete && page.stopReason === null) {
    throw new GlobalStorageReportError("invalid_page", "Incomplete page needs a structural stop reason");
  }
  if ((page.stopReason === "deadline" || page.stopReason === "aborted") && page.reportCompleteForApproval) {
    throw new GlobalStorageReportError("invalid_page", "Deadline/aborted page cannot be complete for approval");
  }
  const outcomes = page.outcomes.map((entry) => validateOutcome(entry, options));
  for (let index = 1; index < outcomes.length; index++) {
    if (outcomes[index]!.rawId <= outcomes[index - 1]!.rawId) {
      throw new GlobalStorageReportError("invalid_page", "Raw outcomes do not follow immutable keyset order");
    }
  }
  let nextCursor: GlobalStorageCursor | null = null;
  if (page.nextCursor !== null) {
    nextCursor = parseCursor(page.nextCursor);
    const initial = cursorFromOptions(options);
    if (!sameScope(nextCursor, initial)) {
      throw new GlobalStorageReportError("invalid_page", "Next cursor changed cycle/stream/high-water scope");
    }
    const expectedAfter = outcomes.at(-1)?.rawId ?? options.afterId;
    if (nextCursor.afterId !== expectedAfter) {
      throw new GlobalStorageReportError("invalid_page", "Next cursor skips an unexamined or malformed item");
    }
  }
  if (page.scanComplete !== (nextCursor === null)) {
    throw new GlobalStorageReportError("invalid_page", "scanComplete and nextCursor disagree");
  }
  return {
    ...page,
    outcomes,
    nextCursor,
  };
}

function reviewAction(disposition: GlobalStorageDisposition): GlobalStorageReviewAction {
  switch (disposition) {
    case "ordinary_candidate": return "ordinary_review";
    case "collab_lifecycle_owned": return "collab_review";
    case "account_lifecycle_owned": return "account_lifecycle_review";
    case "foreign_identity": return "foreign_review";
    case "share_candidate": return "share_review";
    case "history_candidate": return "history_review";
    case "unresolved": return "unresolved_review";
  }
}

/** Project exactly one already-read page. No cross-page/fleet aggregate is accepted. */
export function createGlobalStorageDryRunReport(input: {
  options: ExactDryRunOptions;
  page: GlobalStorageDryRunPage;
  observedAt: string;
}): GlobalStorageDryRunReport {
  const options = parseExactDryRunOptions(input.options);
  const observedAt = canonicalTimestamp(input.observedAt, "observedAt");
  const page = validatePage(options, input.page);
  assertDenseArray(page.outcomes, "page.outcomes", "invalid_page");
  const reportCompleteForApproval = page.reportCompleteForApproval &&
    page.stopReason !== "deadline" && page.stopReason !== "aborted" &&
    page.outcomes.every((outcome) =>
      outcome.generation.factsComplete && outcome.classification.reason !== "raw_current_identity_mismatch");
  const outcomes: GlobalStorageReportOutcome[] = page.outcomes.map((outcome) => ({
    ...outcome,
    head: "not_requested",
    measuredBytes: null,
    measuredContentType: null,
    observedAt,
    proposedAction: reviewAction(outcome.classification.disposition),
    proposedActionReason: outcome.classification.reason,
    accountingOutcome: "notAttempted",
    physicalOutcome: "notAttempted",
    readbackOutcome: "notAttempted",
    completeness: {
      scanComplete: page.scanComplete,
      reportCompleteForApproval,
    },
  }));
  const logicalValue: GlobalStorageDryRunReportView = {
    reportFormatVersion: 1,
    options,
    cycle: {
      cycleId: options.cycleId,
      stream: options.stream,
      highWaterId: options.highWaterId,
      startingAfterId: options.afterId,
      endingAfterId: outcomes.at(-1)?.rawId ?? options.afterId,
    },
    page: {
      examinedRawRows: page.examinedRawRows,
      ownersTouched: page.ownersTouched,
      stopReason: page.stopReason,
    },
    nextCursor: page.nextCursor,
    outcomes,
    scanComplete: page.scanComplete,
    reportCompleteForApproval,
    byteEvidenceComplete: false,
    rollingHistoryComplete: false,
    usedBytes: null,
    projectedUsedBytes: null,
    dbDiscoverableCoverageOnly: true,
  };
  const bytes = new TextEncoder().encode(canonicalStorageGlobalJson(logicalValue));
  const sha256 = createHash("sha256").update(bytes).digest("hex");
  const view = JSON.parse(new TextDecoder().decode(bytes)) as GlobalStorageDryRunReportView;
  return { bytes, sha256, view };
}

function abortedPage(options: ExactDryRunOptions, stopReason: "deadline" | "aborted"): GlobalStorageDryRunPage {
  return {
    outcomes: [],
    examinedRawRows: 0,
    scanComplete: false,
    reportCompleteForApproval: false,
    nextCursor: cursorFromOptions(options),
    stopReason,
    ownersTouched: 0,
  };
}

/** The only authorized primitive. It composes no production dependency and performs no mutation. */
export async function inspectGlobalStoragePage(
  execution: GlobalStorageDiscoveryExecution,
  exactOptions: ExactDryRunOptions,
): Promise<GlobalStorageDryRunReport> {
  const options = parseExactDryRunOptions(exactOptions);
  if (typeof execution.readPage !== "function" || typeof execution.now !== "function") {
    throw new GlobalStorageReportError("invalid_options", "Execution read port and clock are required separately");
  }
  const readClock = (): Date => {
    const value = execution.now();
    if (!(value instanceof Date) || !Number.isFinite(value.getTime())) {
      throw new GlobalStorageReportError("invalid_clock", "Execution clock returned an invalid Date");
    }
    return value;
  };
  const started = readClock();
  const observedAt = started.toISOString();
  const deadlineAt = started.getTime() + options.deadlineMs;
  if (!Number.isSafeInteger(deadlineAt)) {
    throw new GlobalStorageReportError("invalid_options", "Deadline exceeds the safe clock range");
  }
  const deadlineExceeded = (): boolean => {
    if (execution.signal?.aborted === true) return true;
    try {
      return readClock().getTime() >= deadlineAt;
    } catch {
      return true;
    }
  };
  const isAborted = (): boolean => execution.signal?.aborted === true;
  if (isAborted()) {
    return createGlobalStorageDryRunReport({ options, page: abortedPage(options, "aborted"), observedAt });
  }
  if (deadlineExceeded()) {
    return createGlobalStorageDryRunReport({ options, page: abortedPage(options, "deadline"), observedAt });
  }

  let page = validatePage(options, await execution.readPage({ options, observedAt, deadlineExceeded }));
  if (isAborted()) {
    page = { ...page, reportCompleteForApproval: false, stopReason: "aborted" };
  } else if (deadlineExceeded()) {
    page = { ...page, reportCompleteForApproval: false, stopReason: "deadline" };
  }
  return createGlobalStorageDryRunReport({ options, page, observedAt });
}
