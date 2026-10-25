import { createHash } from "node:crypto";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { and, eq, sql, type SQL } from "drizzle-orm";
import {
  AttachmentFinalizeError,
  attachmentDeclarationMismatch,
  CollabArtifactDeadline,
  CollabError,
  CollabOrphanSweepScheduler,
  ProjectFileLimitError,
  QuotaContractError,
  StorageReservationStore,
  assertSessionFileCapacity,
  attachments,
  classifyCollabArtifactAttemptHead,
  collabArtifactAttemptMayDelete,
  collabOrphanSweepBudget,
  listCollabArtifactAttemptOrphanCandidates,
  lockCollabArtifactAccountAuthority,
  parseCollabArtifactAttemptReservationId,
  releaseCollabArtifactReservedAttempts,
  removeObject,
  schema,
  type CollabArtifactAttemptCursor,
  type CollabAuthorization,
  type Db,
  type RemoveStorageObjectResult,
  type StorageFinalizeInput,
  type StorageReservationInput,
  type StorageReservationResult,
} from "@ovid/db";
import {
  DEFAULT_PRESIGN_TTL_SECONDS,
  normalizeAttachmentContentType,
  sanitizeAttachmentName,
  type AttachmentUploadResponse,
} from "@ovid/shared";
import {
  assertSafeRelPath,
  isActiveCdnContentType,
  sanitizeCdnContentType,
  type HeadResult,
  type PresignGetOptions,
} from "@ovid/storage";
import type { AuthPrincipal } from "../auth.js";
import {
  ATTACHMENT_MAX_BYTES,
  ATTACHMENT_UPLOAD_TTL_SECONDS,
  attachmentObjectKey,
  type AttachmentFinalizeResponse,
  type AttachmentPresigner,
} from "../routes/attachments.js";
import { isUuid } from "../routes/http.js";

/**
 * Canonical collaboration objects. Host identity owns rows, keys and bytes;
 * the reservation actor remains the actual uploader/creator. Readiness and
 * actual-byte settlement are ONE database transaction. No turn/transcript
 * writer or second object store is introduced here.
 *
 * Register inside the existing authenticated Collab scope. The gateway
 * composition supplies membership, canonical stores and the real storage
 * adapter; tests may inject narrower ports.
 */

export type CollabObjectAccess = "owner" | "member" | null;

export interface CollabObjectAuthorizationInput {
  sessionId: string;
  objectOwnerUid: string;
  viewerUid: string;
}

export interface CollabSessionObjectAuthority {
  lifecycle: "active" | "closing" | "closed";
  viewerRole: "owner" | "participant";
  sessionDeleted: boolean;
  ownerAccountFenced: boolean;
  viewerAccountFenced: boolean;
}

export interface CollabAttachmentVersion {
  uploadStatus: "pending" | "ready" | "failed";
  actualBytes: number | null;
  actualContentType: string | null;
  finalizedAt: Date | null;
}

export interface CollabAttachmentRecord extends CollabAttachmentVersion {
  id: string;
  sessionId: string;
  ownerUid: string;
  uploaderUid: string;
  name: string;
  declaredBytes: number;
  key: string;
  declaredContentType: string;
  contentTypeDeclared: boolean;
  projectId: string | null;
  reservationState: "reserved" | "finalized" | "released" | null;
  createdAt: Date;
}

export interface CollabArtifactRecord {
  id: string;
  sessionId: string;
  ownerUid: string;
  creatorUid: string;
  name: string;
  bytes: number;
  key: string;
  contentType: string | null;
  status: "pending" | "active" | "deleted";
  reservationState: "reserved" | "finalized" | "released" | null;
  /** Immutable attempt identity, when this is a Collab generated artifact. */
  sha256: string;
  attempt: number | null;
  attemptReservationId: string | null;
  createdAt: Date;
}

export interface CollabObjectPage<T> {
  rows: T[];
  nextCursor: string | null;
}

/** Stable reserved-group identity; unlike a row cursor, partial drains cannot rewind it. */
export interface CollabReservedArtifactGroupCursor {
  ownerUid: string;
  sessionId: string;
  artifactId: string;
}

export interface CollabOrphanCandidate {
  kind: "attachment" | "artifact";
  id: string;
  sessionId: string;
  ownerUid: string;
  key: string;
}

/** A pending or superseded released generated-artifact attempt. */
export interface CollabArtifactAttemptOrphanCandidate {
  kind: "artifact_attempt";
  id: string;
  sessionId: string;
  ownerUid: string;
  key: string;
  actorUid?: string;
  attempt: number;
  attemptReservationId: string;
  declaredBytes: number;
  createdAt: Date;
}

export type CollabObjectOrphanCandidate =
  | (CollabOrphanCandidate & { createdAt: Date })
  | CollabArtifactAttemptOrphanCandidate;

export type CollabArtifactAttemptCleanupResult = "cleaned" | "missing" | "skipped";

export interface CollabObjectStore {
  readonly db: Db;
  sessionObjectAuthority(
    input: CollabObjectAuthorizationInput,
  ): Promise<CollabSessionObjectAuthority | null>;
  withAttachmentLock<T>(attachmentId: string, fn: () => Promise<T>): Promise<T>;
  assertSessionCapacity(input: { sessionId: string; ownerUid: string }): Promise<void>;
  getAttachment(input: {
    sessionId: string;
    ownerUid: string;
    attachmentId: string;
  }): Promise<CollabAttachmentRecord | null>;
  listAttachments(input: {
    sessionId: string;
    ownerUid: string;
    limit: number;
    beforeId: string | null;
  }): Promise<CollabObjectPage<CollabAttachmentRecord>>;
  createAttachment(input: {
    id: string;
    sessionId: string;
    ownerUid: string;
    name: string;
    declaredBytes: number;
    key: string;
    contentType: string;
  }): Promise<void>;
  /** Holds canonical row+reservation locks through the signing boundary. */
  withAttachmentSigningFence(input: {
    attachment: CollabAttachmentRecord;
    reservation: CollabStorageReservation;
    sign: () => Promise<string>;
  }): Promise<string>;
  /** Atomically publishes ready row and finalized actual-byte reservation. */
  finalizeAttachment(input: {
    id: string;
    sessionId: string;
    ownerUid: string;
    expected: CollabAttachmentVersion;
    expectedReservation: CollabStorageReservation;
    actualBytes: number;
    actualContentType: string | null;
    etag: string | null;
  }): Promise<StorageReservationResult>;
  /** CAS-fails an intent, and debits a previously finalized charge if needed. */
  failAttachment(input: {
    id: string;
    sessionId: string;
    ownerUid: string;
    expected: CollabAttachmentVersion;
    actualBytes: number | null;
    actualContentType: string | null;
  }): Promise<boolean>;
  /** Failed rows may be deleted only after their reservation is released. */
  deleteFailedAttachment(input: {
    id: string;
    sessionId: string;
    ownerUid: string;
    expected: CollabAttachmentVersion;
  }): Promise<boolean>;
  getArtifact(input: {
    sessionId: string;
    ownerUid: string;
    artifactId: string;
  }): Promise<CollabArtifactRecord | null>;
  listArtifacts(input: {
    sessionId: string;
    ownerUid: string;
    limit: number;
    beforeId: string | null;
  }): Promise<CollabObjectPage<CollabArtifactRecord>>;
  /** Soft-deletes and atomically removes any finalized/reserved artifact charge. */
  reconcileArtifact(input: { artifact: CollabArtifactRecord }): Promise<boolean>;
  /** Bounded DB-only discovery for the accounting-only reserved-release primitive. */
  listReservedArtifactAttempts(
    limit: number,
    before?: CollabReservedArtifactGroupCursor,
  ): Promise<{
    rows: CollabArtifactAttemptOrphanCandidate[];
    nextCursor: CollabReservedArtifactGroupCursor | null;
  }>;
  /** Exact registrar lock + released-attempt/active-generation fence. */
  cleanupArtifactAttempt(input: {
    candidate: CollabArtifactAttemptOrphanCandidate;
    inspect(key: string): Promise<"missing" | "owned" | "foreign">;
    remove(key: string): Promise<void>;
    /** One overall deadline for DB fences and storage callbacks. */
    deadline?: CollabArtifactDeadline;
  }): Promise<CollabArtifactAttemptCleanupResult>;
  /** Optional storage-I/O bound; DB validation/commit transactions stay outside it. */
  attemptIoDeadlineMs?: number;
  listOrphanCandidates(
    limit: number,
    before?: CollabArtifactAttemptCursor,
    sequence?: number,
  ): Promise<{
    rows: CollabObjectOrphanCandidate[];
    quarantined: number;
    nextCursor: CollabArtifactAttemptCursor | null;
  }>;
}

export interface CollabStorageReservation {
  reservationId: string;
  ownerUserId: string;
  uploaderUserId: string;
  sessionId: string;
  objectId: string | null;
  declaredBytes: number;
  actualBytes: number | null;
  actualContentType: string | null;
  etag: string | null;
  attachment?: boolean;
  state: "reserved" | "finalized" | "released";
}

export interface CollabReservationStore {
  reserve(input: StorageReservationInput): Promise<StorageReservationResult>;
  finalize(input: StorageFinalizeInput): Promise<StorageReservationResult>;
  release(input: { reservationId: string }): Promise<void>;
}

export interface CollabReservationPort extends CollabReservationStore {
  get(reservationId: string): Promise<CollabStorageReservation | null>;
  removeObject(input: { reservationId: string }): Promise<RemoveStorageObjectResult>;
}

export interface CollabObjectStorage extends AttachmentPresigner {
  head(key: string): Promise<HeadResult | null>;
  presignGet(key: string, ttlSeconds: number, options?: PresignGetOptions): Promise<string>;
  delete(key: string): Promise<void>;
}

export interface CollabObjectMembership {
  authorize(input: { principal: AuthPrincipal; token: string }): Promise<CollabAuthorization>;
}

export type CollabReservedRelease = typeof releaseCollabArtifactReservedAttempts;

export interface CollabObjectRouteDeps {
  membership: CollabObjectMembership;
  objects: CollabObjectStore;
  reservations: CollabReservationPort;
  storage?: CollabObjectStorage;
  clock?: () => Date;
  wallClockMs?: () => number;
  reservedRelease?: CollabReservedRelease;
  recoveryReservedGroupsPerPass?: number;
  recoveryReservedReleaseLimit?: number;
  downloadTtlSeconds?: number;
  /** Bounds one attempt's DB+storage work without holding DB locks across I/O. */
  attemptIoDeadlineMs?: number;
  /** Overall scheduled-pass deadline, including cleanup-port DB work and close. */
  recoveryDeadlineMs?: number;
  /** Candidate cap per scheduler pass; production default remains 50. */
  recoveryBatchLimit?: number;
  /** Periodic head rescan interval for late PUTs after an earlier HEAD-null. */
  orphanRescanMs?: number;
  /** Optional production sweeper; zero/undefined disables the timer. */
  orphanSweepMs?: number;
}

export interface CollabAttachmentTicket extends AttachmentUploadResponse {
  schemaVersion: 1;
  contentType: string;
  requiredHeaders: Record<string, string>;
  uploadHeaders: Record<string, string>;
}

export interface CollabAttachmentMetadata {
  kind: "attachment";
  attachmentId: string;
  sessionId: string;
  name: string;
  sizeBytes: number | null;
  contentType: string | null;
  status: "pending" | "ready";
  createdAt: string;
}

export interface CollabArtifactMetadata {
  kind: "artifact";
  artifactId: string;
  sessionId: string;
  name: string;
  sizeBytes: number;
  contentType: string | null;
  createdAt: string;
}

export type CollabObjectMetadata = CollabAttachmentMetadata | CollabArtifactMetadata;

export type CollabObjectErrorCode =
  | "object_not_found"
  | "object_cleanup_required"
  | "attachment_too_large"
  | "attachment_not_uploaded"
  | "attachment_size_mismatch"
  | "attachment_type_mismatch"
  | "attachment_changed"
  | "artifact_unavailable"
  | "artifact_incomplete"
  | "upload_limit_reached"
  | "storage_quota_exceeded"
  | "temporarily_unavailable";

export class CollabObjectError extends Error {
  constructor(
    readonly code: CollabObjectErrorCode,
    readonly status: number,
    message: string,
    readonly retryAfterSeconds?: number,
  ) {
    super(message);
    this.name = "CollabObjectError";
  }
}

const MEMBERSHIP_MESSAGES = {
  invalid_request: "Invalid request",
  not_member: "Not a session member",
  invite_invalid: "Invitation is invalid",
  invite_not_found: "Invitation not found",
  member_not_found: "Member not found",
  session_closed: "Session is closed",
  session_full: "Session is full",
  owner_not_removable: "Owner cannot be removed",
  request_already_used: "Request was already used",
  temporarily_unavailable: "The collaboration service is temporarily unavailable",
} as const;

function objectNotFound(): CollabObjectError {
  return new CollabObjectError("object_not_found", 404, "This file is no longer available.");
}

function unavailable(): CollabObjectError {
  return new CollabObjectError(
    "temporarily_unavailable",
    503,
    "The collaboration object service is temporarily unavailable",
  );
}

function changed(): CollabObjectError {
  return new CollabObjectError("attachment_changed", 409, "The attachment upload is no longer active.");
}

function cleanupRequired(): CollabObjectError {
  return new CollabObjectError(
    "object_cleanup_required",
    503,
    "The failed upload needs cleanup before it can be retried.",
  );
}

function quotaFailure(
  result: Extract<StorageReservationResult, { ok: false }>,
  clock: () => Date,
): CollabObjectError {
  if (result.scope === "attachment") return changed();
  if (result.scope === "storage") {
    return new CollabObjectError(
      "storage_quota_exceeded",
      409,
      "The storage allowance for this plan is exhausted.",
    );
  }
  const retryAfterSeconds = result.resetsAt === null
    ? undefined
    : Math.max(1, Math.ceil((result.resetsAt.getTime() - clock().getTime()) / 1000));
  return new CollabObjectError(
    "upload_limit_reached",
    429,
    "The upload allowance for this plan is exhausted.",
    retryAfterSeconds,
  );
}

/** One mapper for canonical project capacity: always 409, never 413. */
export function collabObjectRefusal(reply: FastifyReply, error: unknown): FastifyReply {
  if (error instanceof CollabObjectError) {
    if (error.retryAfterSeconds !== undefined) reply.header("retry-after", error.retryAfterSeconds);
    return reply.code(error.status).send({
      schemaVersion: 1,
      code: error.code,
      message: error.message,
    });
  }
  if (error instanceof AttachmentFinalizeError) {
    const failure = error.code === "not_found"
      ? objectNotFound()
      : error.code === "size_mismatch"
        ? new CollabObjectError("attachment_size_mismatch", 409, error.message)
        : error.code === "type_mismatch"
          ? new CollabObjectError("attachment_type_mismatch", 409, error.message)
          : changed();
    return collabObjectRefusal(reply, failure);
  }
  if (error instanceof ProjectFileLimitError) {
    return reply.code(409).send({ schemaVersion: 1, code: error.code, message: error.message });
  }
  if (error instanceof CollabError) {
    return reply.code(error.status).send({
      schemaVersion: 1,
      code: error.code,
      message: MEMBERSHIP_MESSAGES[error.code],
    });
  }
  if (error instanceof QuotaContractError) {
    if (error.code === "idempotency_conflict") {
      return reply.code(409).send({
        schemaVersion: 1,
        code: "request_already_used",
        message: MEMBERSHIP_MESSAGES.request_already_used,
      });
    }
    if (error.code === "reservation_released" || error.code === "reservation_not_found") {
      const failure = changed();
      return reply.code(failure.status).send({
        schemaVersion: 1,
        code: failure.code,
        message: failure.message,
      });
    }
  }
  throw error;
}

function clock(deps: CollabObjectRouteDeps): Date {
  const value = deps.clock?.() ?? new Date();
  if (!(value instanceof Date) || !Number.isFinite(value.getTime())) {
    throw new RangeError("collab object clock returned an invalid Date");
  }
  return new Date(value.getTime());
}

function storage(deps: CollabObjectRouteDeps): CollabObjectStorage {
  if (deps.storage === undefined) throw unavailable();
  return deps.storage;
}

function token(request: FastifyRequest): string {
  const value = (request.params as { token?: unknown }).token;
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(value)) {
    throw new CollabError("not_member");
  }
  return value;
}

function strictBody(request: FastifyRequest, allowed: readonly string[]): Record<string, unknown> {
  const value: unknown = request.body;
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new CollabError("invalid_request");
  }
  const body = value as Record<string, unknown>;
  if (body.schemaVersion !== 1 || Object.keys(body).some((key) => !allowed.includes(key))) {
    throw new CollabError("invalid_request");
  }
  return body;
}

function strictQuery(request: FastifyRequest, allowed: readonly string[]): Record<string, unknown> {
  const query = request.query as Record<string, unknown>;
  if (Object.keys(query).some((key) => !allowed.includes(key))) {
    throw new CollabError("invalid_request");
  }
  return query;
}

function objectId(request: FastifyRequest, key: "attachmentId" | "artifactId"): string {
  const value = (request.params as Record<string, unknown>)[key];
  if (typeof value !== "string" || !isUuid(value)) throw objectNotFound();
  return value;
}

function pageQuery(request: FastifyRequest): { limit: number; beforeId: string | null } {
  const query = strictQuery(request, ["limit", "cursor"]);
  let limit = 30;
  if (query.limit !== undefined) {
    if (typeof query.limit !== "string" || !/^\d+$/.test(query.limit)) {
      throw new CollabError("invalid_request");
    }
    limit = Number(query.limit);
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) {
      throw new CollabError("invalid_request");
    }
  }
  if (query.cursor !== undefined) {
    if (typeof query.cursor !== "string" || !isUuid(query.cursor)) {
      throw new CollabError("invalid_request");
    }
    return { limit, beforeId: query.cursor };
  }
  return { limit, beforeId: null };
}

function attachmentVersion(row: CollabAttachmentRecord): CollabAttachmentVersion {
  return {
    uploadStatus: row.uploadStatus,
    actualBytes: row.actualBytes,
    actualContentType: row.actualContentType,
    finalizedAt: row.finalizedAt,
  };
}

function sameAttachmentVersion(a: CollabAttachmentVersion, b: CollabAttachmentVersion): boolean {
  return a.uploadStatus === b.uploadStatus &&
    a.actualBytes === b.actualBytes &&
    a.actualContentType === b.actualContentType &&
    (a.finalizedAt === null ? b.finalizedAt === null :
      b.finalizedAt !== null && a.finalizedAt.getTime() === b.finalizedAt.getTime());
}

function sameReservationVersion(a: CollabStorageReservation, b: CollabStorageReservation): boolean {
  return a.reservationId === b.reservationId &&
    a.ownerUserId === b.ownerUserId &&
    a.uploaderUserId === b.uploaderUserId &&
    a.sessionId === b.sessionId &&
    a.objectId === b.objectId &&
    a.declaredBytes === b.declaredBytes &&
    a.actualBytes === b.actualBytes &&
    a.actualContentType === b.actualContentType &&
    a.etag === b.etag &&
    a.state === b.state;
}

function sameArtifactVersion(a: CollabArtifactRecord, b: CollabArtifactRecord): boolean {
  return a.id === b.id &&
    a.sessionId === b.sessionId &&
    a.ownerUid === b.ownerUid &&
    a.creatorUid === b.creatorUid &&
    a.name === b.name &&
    a.bytes === b.bytes &&
    a.key === b.key &&
    a.contentType === b.contentType &&
    a.status === b.status &&
    a.reservationState === b.reservationState &&
    a.sha256 === b.sha256 &&
    a.attempt === b.attempt &&
    a.attemptReservationId === b.attemptReservationId &&
    a.createdAt.getTime() === b.createdAt.getTime();
}

function attachmentMetadata(row: CollabAttachmentRecord): CollabAttachmentMetadata | null {
  if (row.uploadStatus === "failed" || row.reservationState === "released") return null;
  if (row.uploadStatus === "ready" && row.reservationState !== "finalized") return null;
  return {
    kind: "attachment",
    attachmentId: row.id,
    sessionId: row.sessionId,
    name: row.name,
    sizeBytes: row.uploadStatus === "ready" ? row.actualBytes : null,
    contentType: row.uploadStatus === "ready" ? row.actualContentType : null,
    status: row.uploadStatus,
    createdAt: row.createdAt.toISOString(),
  };
}

function artifactMetadata(row: CollabArtifactRecord): CollabArtifactMetadata {
  return {
    kind: "artifact",
    artifactId: row.id,
    sessionId: row.sessionId,
    name: row.name,
    sizeBytes: row.bytes,
    contentType: row.contentType,
    createdAt: row.createdAt.toISOString(),
  };
}

function stableAttachmentId(sessionId: string, uploaderUid: string, idempotencyKey: string): string {
  const digest = createHash("sha256")
    .update(`collab-attachment\0${sessionId}\0${uploaderUid}\0${idempotencyKey}`, "utf8")
    .digest("hex")
    .slice(0, 32)
    .split("");
  digest[12] = "5";
  digest[16] = ((Number.parseInt(digest[16]!, 16) & 0x3) | 0x8).toString(16);
  const hex = digest.join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

async function query<T>(db: Db, statement: SQL): Promise<T[]> {
  return await db.execute(statement) as unknown as T[];
}

function dateValue(value: Date | string): Date {
  return value instanceof Date ? value : new Date(value);
}

function numberValue(value: number | string): number {
  const result = Number(value);
  if (!Number.isSafeInteger(result) || result < 0) throw new Error("invalid canonical object byte count");
  return result;
}

function nullableNumber(value: number | string | null): number | null {
  return value === null ? null : numberValue(value);
}

function artifactMeta(meta: unknown): {
  name: string | null;
  attempt: number | null;
  attemptReservationId: string | null;
} {
  const value = typeof meta === "string" ? JSON.parse(meta) as unknown : meta;
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return { name: null, attempt: null, attemptReservationId: null };
  }
  const record = value as Record<string, unknown>;
  const attempt = typeof record.attempt === "number" &&
    Number.isSafeInteger(record.attempt) && record.attempt > 0
    ? record.attempt
    : null;
  return {
    name: typeof record.name === "string" && record.name !== "" ? record.name : null,
    attempt,
    attemptReservationId: typeof record.attemptReservationId === "string"
      ? record.attemptReservationId
      : null,
  };
}

interface AttachmentSqlRow {
  id: string;
  session_id: string;
  owner_uid: string;
  uploader_uid: string | null;
  name: string;
  declared_bytes: number | string;
  r2_key: string;
  content_type: string;
  content_type_declared: boolean;
  project_id: string | null;
  upload_status: "pending" | "ready" | "failed";
  actual_bytes: number | string | null;
  actual_content_type: string | null;
  finalized_at: Date | string | null;
  reservation_state: "reserved" | "finalized" | "released" | null;
  created_at: Date | string;
}

function attachmentRecord(row: AttachmentSqlRow): CollabAttachmentRecord {
  return {
    id: row.id,
    sessionId: row.session_id,
    ownerUid: row.owner_uid,
    uploaderUid: row.uploader_uid ?? row.owner_uid,
    name: row.name,
    declaredBytes: numberValue(row.declared_bytes),
    key: row.r2_key,
    declaredContentType: row.content_type,
    contentTypeDeclared: row.content_type_declared,
    projectId: row.project_id,
    uploadStatus: row.upload_status,
    actualBytes: nullableNumber(row.actual_bytes),
    actualContentType: row.actual_content_type,
    finalizedAt: row.finalized_at === null ? null : dateValue(row.finalized_at),
    reservationState: row.reservation_state,
    createdAt: dateValue(row.created_at),
  };
}

interface ArtifactSqlRow {
  id: string;
  session_id: string;
  owner_uid: string;
  creator_uid: string | null;
  meta: unknown;
  bytes: number | string;
  sha256: string;
  r2_key: string;
  content_type: string | null;
  status: "pending" | "active" | "deleted";
  reservation_state: "reserved" | "finalized" | "released" | null;
  created_at: Date | string;
}

function artifactRecord(row: ArtifactSqlRow): CollabArtifactRecord {
  const meta = artifactMeta(row.meta);
  return {
    id: row.id,
    sessionId: row.session_id,
    ownerUid: row.owner_uid,
    creatorUid: row.creator_uid ?? row.owner_uid,
    name: meta.name ?? "artifact",
    bytes: numberValue(row.bytes),
    key: row.r2_key,
    contentType: row.content_type,
    status: row.status,
    reservationState: row.reservation_state,
    sha256: row.sha256,
    attempt: meta.attempt,
    attemptReservationId: meta.attemptReservationId,
    createdAt: dateValue(row.created_at),
  };
}

interface ReservationSqlRow {
  id: string;
  actor_user_id: string;
  owner_user_id: string;
  session_id: string;
  object_id: string | null;
  declared_bytes: number | string;
  actual_bytes: number | string | null;
  actual_content_type: string | null;
  etag: string | null;
  state: "reserved" | "finalized" | "released";
}

function reservationRecord(row: ReservationSqlRow): CollabStorageReservation {
  return {
    reservationId: row.id,
    ownerUserId: row.owner_user_id,
    uploaderUserId: row.actor_user_id,
    sessionId: row.session_id,
    objectId: row.object_id,
    declaredBytes: numberValue(row.declared_bytes),
    actualBytes: nullableNumber(row.actual_bytes),
    actualContentType: row.actual_content_type,
    etag: row.etag,
    state: row.state,
  };
}

const ATTACHMENT_SELECT = sql`
  SELECT attachment.id, attachment.session_id, attachment.user_id AS owner_uid,
         reservation.actor_user_id AS uploader_uid, attachment.name,
         attachment.size AS declared_bytes, attachment.r2_key,
         attachment.content_type, attachment.content_type_declared,
         attachment.project_id, attachment.upload_status, attachment.actual_bytes,
         attachment.actual_content_type, attachment.finalized_at,
         reservation.state AS reservation_state, attachment.created_at
    FROM attachments attachment
    LEFT JOIN storage_reservations reservation
      ON reservation.id = attachment.id AND reservation.object_id = attachment.id`;

const ARTIFACT_SELECT = sql`
  SELECT object.id, object.session_id, object.user_id AS owner_uid,
         reservation.actor_user_id AS creator_uid, object.meta, object.bytes,
         object.sha256, object.r2_key, object.content_type, object.status,
         reservation.state AS reservation_state, object.created_at
    FROM workspace_objects object
    LEFT JOIN storage_reservations reservation
      ON reservation.id = object.id AND reservation.object_id = object.id`;

const RESERVATION_SELECT = sql`
  SELECT id, actor_user_id, owner_user_id, session_id, object_id,
         declared_bytes, actual_bytes, actual_content_type, etag, state
    FROM storage_reservations`;

async function readReservation(db: Db, reservationId: string): Promise<CollabStorageReservation | null> {
  const found = await query<ReservationSqlRow>(db, sql`${RESERVATION_SELECT} WHERE id = ${reservationId} LIMIT 1`);
  return found[0] === undefined ? null : reservationRecord(found[0]);
}

async function lockReservation(db: Db, reservationId: string): Promise<CollabStorageReservation | null> {
  const found = await query<ReservationSqlRow>(db, sql`
    ${RESERVATION_SELECT} WHERE id = ${reservationId} FOR UPDATE`);
  return found[0] === undefined ? null : reservationRecord(found[0]);
}

async function lockAttachment(db: Db, attachmentId: string): Promise<CollabAttachmentRecord | null> {
  const found = await query<AttachmentSqlRow>(db, sql`
    ${ATTACHMENT_SELECT} WHERE attachment.id = ${attachmentId} FOR UPDATE OF attachment`);
  return found[0] === undefined ? null : attachmentRecord(found[0]);
}

async function lockArtifact(db: Db, artifactId: string): Promise<CollabArtifactRecord | null> {
  const found = await query<ArtifactSqlRow>(db, sql`
    ${ARTIFACT_SELECT} WHERE object.id = ${artifactId} FOR UPDATE OF object`);
  return found[0] === undefined ? null : artifactRecord(found[0]);
}

function attemptCandidateStillCurrent(
  candidate: CollabArtifactAttemptOrphanCandidate,
  row: CollabArtifactRecord | null,
  reservation: CollabStorageReservation | null,
): boolean {
  const parsed = parseCollabArtifactAttemptReservationId(candidate.attemptReservationId);
  let keyShapeValid = false;
  try {
    const safeKey = assertSafeRelPath(candidate.key);
    const prefix = `users/${candidate.ownerUid}/artifacts/${candidate.sessionId}/${candidate.id}-attempt-${candidate.attempt}-`;
    keyShapeValid = safeKey === candidate.key && safeKey.startsWith(prefix) &&
      /^[a-f0-9]{16}-[^/]+$/.test(safeKey.slice(prefix.length));
  } catch {
    keyShapeValid = false;
  }
  if (!keyShapeValid ||
      parsed === null || parsed.artifactId !== candidate.id || parsed.attempt !== candidate.attempt ||
      (row !== null && (row.id !== candidate.id ||
        row.sessionId !== candidate.sessionId || row.ownerUid !== candidate.ownerUid)) ||
      reservation === null || reservation.reservationId !== candidate.attemptReservationId ||
      reservation.state !== "released" || reservation.objectId !== candidate.key ||
      (candidate.actorUid !== undefined && reservation.uploaderUserId !== candidate.actorUid) ||
      reservation.ownerUserId !== candidate.ownerUid || reservation.sessionId !== candidate.sessionId ||
      reservation.declaredBytes !== candidate.declaredBytes) return false;
  return collabArtifactAttemptMayDelete({
    reservationState: reservation.state,
    reservationObjectId: reservation.objectId,
    candidateKey: candidate.key,
    candidateAttempt: candidate.attempt,
    current: row === null ? null : {
      status: row.status,
      r2Key: row.key,
      attempt: row.attempt,
    },
  });
}

export type CollabArtifactAttemptDiscovery = (
  db: Db,
  input: {
    limit: number;
    before?: CollabArtifactAttemptCursor;
    deadline?: CollabArtifactDeadline;
  },
) => Promise<{
  rows: CollabArtifactAttemptOrphanCandidate[];
  quarantined?: number;
  nextCursor: CollabArtifactAttemptCursor | null;
}>;

/** Thin adapter: canonical discovery, quarantine accounting and raw cursor. */
export async function listCollabObjectArtifactAttempts(
  db: Db,
  input: {
    limit: number;
    before?: CollabArtifactAttemptCursor;
    deadline?: CollabArtifactDeadline;
  },
): Promise<{
  rows: CollabArtifactAttemptOrphanCandidate[];
  quarantined?: number;
  nextCursor: CollabArtifactAttemptCursor | null;
}> {
  return listCollabArtifactAttemptOrphanCandidates(db, input);
}

interface CollabArtifactAttemptLifecycle {
  sessionExists: boolean;
  sessionDeletedAt: string | null;
  accounts: Array<{ uid: string; state: string }>;
}

async function readAttemptLifecycle(
  db: Db,
  candidate: CollabArtifactAttemptOrphanCandidate,
  actorUid: string,
): Promise<CollabArtifactAttemptLifecycle> {
  const sessionRows = await query<{ deleted_at: Date | string | null }>(db, sql`
    SELECT deleted_at FROM sessions
     WHERE id = ${candidate.sessionId} AND user_id = ${candidate.ownerUid}
     LIMIT 1 FOR UPDATE`);
  const accounts = await query<{ uid: string; state: string }>(db, sql`
    SELECT uid, state FROM account_deletions
     WHERE uid IN (${candidate.ownerUid}, ${actorUid})
     ORDER BY uid FOR UPDATE`);
  const session = sessionRows[0];
  let sessionDeletedAt: string | null = null;
  if (session !== undefined && session.deleted_at !== null) {
    sessionDeletedAt = dateValue(session.deleted_at).toISOString();
  }
  return {
    sessionExists: session !== undefined,
    sessionDeletedAt,
    accounts: accounts.map((row) => ({ uid: row.uid, state: row.state })),
  };
}

function sameAttemptLifecycle(
  a: CollabArtifactAttemptLifecycle,
  b: CollabArtifactAttemptLifecycle,
): boolean {
  return a.sessionExists === b.sessionExists &&
    a.sessionDeletedAt === b.sessionDeletedAt &&
    JSON.stringify(a.accounts) === JSON.stringify(b.accounts);
}

/** Match StorageReservationStore's user-then-reservation lock order. */
async function lockReservationUsers(db: Db, expected: CollabStorageReservation): Promise<void> {
  for (const uid of [...new Set([expected.ownerUserId, expected.uploaderUserId])].sort()) {
    const found = await query<{ uid: string }>(db, sql`SELECT uid FROM users WHERE uid = ${uid} FOR UPDATE`);
    if (found[0] === undefined) throw new QuotaContractError("unknown_user");
  }
}

function assertReservationIdentity(
  reservation: CollabStorageReservation,
  input: { ownerUid: string; sessionId: string; id: string; declaredBytes: number },
): void {
  if (
    reservation.ownerUserId !== input.ownerUid ||
    reservation.sessionId !== input.sessionId ||
    reservation.objectId !== input.id ||
    reservation.declaredBytes !== input.declaredBytes
  ) throw changed();
}

class AtomicQuotaRollback extends Error {
  constructor(readonly result: Extract<StorageReservationResult, { ok: false }>) {
    super("atomic storage quota refusal");
  }
}

export interface CollabObjectStoreOptions {
  now?: () => Date;
  attemptIoDeadlineMs?: number;
  attemptDiscovery?: CollabArtifactAttemptDiscovery;
  /** Test/transaction adapters; production uses the canonical 0038 services. */
  reservationStore?(db: Db): CollabReservationStore;
  removeObject?(db: Db, input: { reservationId: string }): Promise<RemoveStorageObjectResult>;
}

/** Canonical Postgres adapter. All state-changing CAS operations are transactional. */
export function createCollabObjectStore(
  db: Db,
  options: CollabObjectStoreOptions = {},
): CollabObjectStore {
  const now = () => options.now?.() ?? new Date();
  const reservations = (tx: Db): CollabReservationStore =>
    options.reservationStore?.(tx) ?? new StorageReservationStore(tx);
  const attemptDiscovery = options.attemptDiscovery ?? listCollabObjectArtifactAttempts;
  const removeFinalized = (tx: Db, reservationId: string) =>
    options.removeObject !== undefined
      ? options.removeObject(tx, { reservationId })
      : removeObject(tx, { reservationId }, { now });
  const attemptIoDeadlineMs = options.attemptIoDeadlineMs ?? 15_000;
  if (!Number.isSafeInteger(attemptIoDeadlineMs) || attemptIoDeadlineMs < 1) {
    throw new RangeError("attemptIoDeadlineMs must be a positive integer");
  }
  return {
    db,
    async sessionObjectAuthority(input) {
      const found = await query<{
        lifecycle: "active" | "closing" | "closed";
        viewer_role: "owner" | "participant";
        session_deleted: Date | string | null;
        owner_fenced: string | null;
        viewer_fenced: string | null;
      }>(db, sql`
        SELECT room.lifecycle, viewer.role AS viewer_role,
               session.deleted_at AS session_deleted,
               owner_deletion.uid AS owner_fenced,
               viewer_deletion.uid AS viewer_fenced
          FROM collab_rooms room
          JOIN sessions session ON session.id = room.session_id
          JOIN users host ON host.uid = room.owner_user_id
          JOIN users audience ON audience.uid = ${input.viewerUid}
          JOIN collab_members owner
            ON owner.room_id = room.id AND owner.role = 'owner'
           AND owner.status = 'active' AND owner.user_id = room.owner_user_id
          JOIN collab_members viewer
            ON viewer.room_id = room.id AND viewer.user_id = ${input.viewerUid}
           AND viewer.status = 'active'
          LEFT JOIN account_deletions owner_deletion
            ON owner_deletion.uid = room.owner_user_id
           AND owner_deletion.state NOT IN ('active', 'cancelled')
          LEFT JOIN account_deletions viewer_deletion
            ON viewer_deletion.uid = ${input.viewerUid}
           AND viewer_deletion.state NOT IN ('active', 'cancelled')
         WHERE room.session_id = ${input.sessionId}
           AND room.owner_user_id = ${input.objectOwnerUid}
         LIMIT 1`);
      const row = found[0];
      if (row === undefined) return null;
      return {
        lifecycle: row.lifecycle,
        viewerRole: row.viewer_role,
        sessionDeleted: row.session_deleted !== null,
        ownerAccountFenced: row.owner_fenced !== null,
        viewerAccountFenced: row.viewer_fenced !== null,
      };
    },

    async withAttachmentLock(attachmentId, fn) {
      return db.transaction(async (transaction) => {
        const tx = transaction as unknown as Db;
        await tx.execute(sql`
          SELECT pg_advisory_xact_lock(hashtextextended(${`ovid-collab-attachment:${attachmentId}`}, 0))`);
        return fn();
      });
    },

    async assertSessionCapacity(input) {
      await assertSessionFileCapacity(db, input.ownerUid, input.sessionId, 1);
    },

    async getAttachment(input) {
      const found = await query<AttachmentSqlRow>(db, sql`
        ${ATTACHMENT_SELECT}
        WHERE attachment.session_id = ${input.sessionId}
          AND attachment.user_id = ${input.ownerUid}
          AND attachment.id = ${input.attachmentId}
        LIMIT 1`);
      return found[0] === undefined ? null : attachmentRecord(found[0]);
    },

    async listAttachments(input) {
      const found = await query<AttachmentSqlRow>(db, sql`
        ${ATTACHMENT_SELECT}
        WHERE attachment.session_id = ${input.sessionId}
          AND attachment.user_id = ${input.ownerUid}
          AND attachment.upload_status = 'ready'
          AND reservation.state = 'finalized'
          AND (${input.beforeId}::text IS NULL OR attachment.id::text < ${input.beforeId}::text)
        ORDER BY attachment.id DESC
        LIMIT ${input.limit + 1}`);
      const rows = found.slice(0, input.limit).map(attachmentRecord);
      return {
        rows,
        nextCursor: found.length > input.limit ? rows.at(-1)?.id ?? null : null,
      };
    },

    async createAttachment(input) {
      await attachments.create(db, {
        id: input.id,
        sessionId: input.sessionId,
        userId: input.ownerUid,
        name: input.name,
        size: input.declaredBytes,
        r2Key: input.key,
        contentType: input.contentType,
        contentTypeDeclared: true,
      });
    },

    async withAttachmentSigningFence(input) {
      return db.transaction(async (transaction) => {
        const tx = transaction as unknown as Db;
        const current = await lockAttachment(tx, input.attachment.id);
        if (current === null) throw objectNotFound();
        const reservation = await lockReservation(tx, input.reservation.reservationId);
        if (reservation === null) throw changed();
        if (!sameAttachmentVersion(current, attachmentVersion(input.attachment)) ||
            !sameReservationVersion(reservation, input.reservation) ||
            current.uploadStatus !== "pending" || reservation.state !== "reserved") {
          if (current.uploadStatus === "failed") throw failedAttachment(current);
          throw changed();
        }
        assertReservationIdentity(reservation, {
          ownerUid: current.ownerUid,
          sessionId: current.sessionId,
          id: current.id,
          declaredBytes: current.declaredBytes,
        });
        if (reservation.uploaderUserId !== current.uploaderUid) throw changed();
        // Canonical finalize takes the same row/reservation locks, so it cannot
        // commit a terminal transition between this CAS and the signed URL.
        return input.sign();
      });
    },

    async finalizeAttachment(input) {
      try {
        return await db.transaction(async (transaction) => {
          const tx = transaction as unknown as Db;
          // Match the canonical store: users, attachment, then reservation.
          // The actual-byte settlement still precedes canonical ready.
          await lockReservationUsers(tx, input.expectedReservation);
          const current = await lockAttachment(tx, input.id);
          if (current === null) throw objectNotFound();
          if (!sameAttachmentVersion(current, input.expected)) throw changed();
          const reservation = await lockReservation(tx, input.id);
          if (reservation === null || !sameReservationVersion(reservation, input.expectedReservation)) {
            throw changed();
          }
          if (current.uploadStatus === "failed" || reservation.state === "released") {
            if (current.uploadStatus === "failed") throw failedAttachment(current);
            throw changed();
          }
          assertReservationIdentity(reservation, {
            ownerUid: input.ownerUid,
            sessionId: input.sessionId,
            id: input.id,
            declaredBytes: current.declaredBytes,
          });
          if (current.uploaderUid !== reservation.uploaderUserId) throw changed();

          // Declaration mismatches must fail before any used-byte transition.
          // The canonical repo records this typed failure and the enclosing
          // transaction rolls it back; the route's failure path then releases
          // and removes the host row/project slot.
          const mismatch = attachmentDeclarationMismatch({
            uploadStatus: current.uploadStatus,
            actualBytes: current.actualBytes,
            actualContentType: current.actualContentType,
            size: current.declaredBytes,
            contentTypeDeclared: current.contentTypeDeclared,
            contentType: current.declaredContentType,
          }, {
            actualBytes: input.actualBytes,
            actualContentType: input.actualContentType,
          });
          if (mismatch !== null) {
            await attachments.finalizeUpload(tx, {
              id: input.id,
              sessionId: input.sessionId,
              userId: input.ownerUid,
              actualBytes: input.actualBytes,
              actualContentType: input.actualContentType,
            });
            throw changed();
          }

          // Both repositories may open savepoints, but this enclosing
          // transaction is the sole commit boundary. Settle actual HEAD bytes
          // BEFORE the canonical ready guard. Any later failure rolls back
          // both charge and ready, while finalized reads replay idempotently.
          const settled = await reservations(tx).finalize({
            reservationId: input.id,
            actualBytes: input.actualBytes,
            contentType: input.actualContentType,
            etag: input.etag,
            attachment: true,
          });
          if (!settled.ok) throw new AtomicQuotaRollback(settled);
          await attachments.finalizeUpload(tx, {
            id: input.id,
            sessionId: input.sessionId,
            userId: input.ownerUid,
            actualBytes: input.actualBytes,
            actualContentType: input.actualContentType,
          });
          return settled;
        });
      } catch (error) {
        if (error instanceof AtomicQuotaRollback) return error.result;
        throw error;
      }
    },

    async failAttachment(input) {
      let debitFailed = false;
      const updated = await db.transaction(async (transaction) => {
        const tx = transaction as unknown as Db;
        await lockReservationUsers(tx, input.expectedReservation);
        const current = await lockAttachment(tx, input.id);
        if (current === null || !sameAttachmentVersion(current, input.expected)) return false;
        await tx.update(schema.attachments).set({
          uploadStatus: "failed",
          actualBytes: input.actualBytes,
          actualContentType: input.actualContentType,
          finalizedAt: null,
        }).where(and(
          eq(schema.attachments.id, input.id),
          eq(schema.attachments.sessionId, input.sessionId),
          eq(schema.attachments.userId, input.ownerUid),
        ));
        const reservation = await readReservation(tx, input.id);
        if (reservation?.state === "finalized") {
          try {
            await removeFinalized(tx, input.id);
          } catch {
            // The savepoint/inner transaction rolls back only the debit. Keep
            // the durable failed marker so the bounded sweeper can retry; the
            // object is never downloadable in this intermediate state.
            debitFailed = true;
          }
        }
        return true;
      });
      if (debitFailed) throw cleanupRequired();
      return updated;
    },

    async deleteFailedAttachment(input) {
      return db.transaction(async (transaction) => {
        const tx = transaction as unknown as Db;
        await lockReservationUsers(tx, input.expectedReservation);
        const current = await lockAttachment(tx, input.id);
        if (current === null || !sameAttachmentVersion(current, input.expected) ||
            current.uploadStatus !== "failed") return false;
        const reservation = await lockReservation(tx, input.id);
        if (reservation !== null && reservation.state !== "released") return false;
        const deleted = await tx.delete(schema.attachments).where(and(
          eq(schema.attachments.id, input.id),
          eq(schema.attachments.sessionId, input.sessionId),
          eq(schema.attachments.userId, input.ownerUid),
          eq(schema.attachments.uploadStatus, "failed"),
        )).returning({ id: schema.attachments.id });
        return deleted[0] !== undefined;
      });
    },

    async getArtifact(input) {
      const found = await query<ArtifactSqlRow>(db, sql`
        ${ARTIFACT_SELECT}
        WHERE object.session_id = ${input.sessionId}
          AND object.user_id = ${input.ownerUid}
          AND object.id = ${input.artifactId}
        LIMIT 1`);
      return found[0] === undefined ? null : artifactRecord(found[0]);
    },

    async listArtifacts(input) {
      const found = await query<ArtifactSqlRow>(db, sql`
        ${ARTIFACT_SELECT}
        WHERE object.session_id = ${input.sessionId}
          AND object.user_id = ${input.ownerUid}
          AND object.kind = 'artifact' AND object.status = 'active'
          AND reservation.state = 'finalized'
          AND (${input.beforeId}::text IS NULL OR object.id::text < ${input.beforeId}::text)
        ORDER BY object.id DESC
        LIMIT ${input.limit + 1}`);
      const rows = found.slice(0, input.limit).map(artifactRecord);
      return {
        rows,
        nextCursor: found.length > input.limit ? rows.at(-1)?.id ?? null : null,
      };
    },

    async reconcileArtifact(input) {
      let debitFailed = false;
      const updated = await db.transaction(async (transaction) => {
        const tx = transaction as unknown as Db;
        const expected = input.artifact;
        const current = await lockArtifact(tx, expected.id);
        if (current === null || current.sessionId !== expected.sessionId ||
            current.ownerUid !== expected.ownerUid || current.key !== expected.key ||
            current.bytes !== expected.bytes || current.contentType !== expected.contentType ||
            current.status !== expected.status) return false;
        await tx.update(schema.workspaceObjects).set({ status: "deleted" }).where(and(
          eq(schema.workspaceObjects.id, expected.id),
          eq(schema.workspaceObjects.userId, expected.ownerUid),
          eq(schema.workspaceObjects.sessionId, expected.sessionId),
        ));
        const reservation = await readReservation(tx, expected.id);
        try {
          if (reservation?.state === "finalized") {
            await removeFinalized(tx, expected.id);
          } else if (reservation?.state === "reserved") {
            await reservations(tx).release({ reservationId: expected.id });
          }
        } catch {
          // As with attachments, retain the tombstone for a later cleanup pass.
          debitFailed = true;
        }
        return true;
      });
      if (debitFailed) throw cleanupRequired();
      return updated;
    },

    async cleanupArtifactAttempt(input) {
      const { candidate } = input;
      const deadline = input.deadline ?? new CollabArtifactDeadline(attemptIoDeadlineMs);
      const ownsDeadline = input.deadline === undefined;
      type Claim = {
        row: CollabArtifactRecord | null;
        reservation: CollabStorageReservation;
        lifecycle: CollabArtifactAttemptLifecycle;
      };
      const transaction = async <T>(fn: (tx: Db) => Promise<T>): Promise<T> => deadline.run(() =>
        db.transaction(async (transaction) => {
          deadline.throwIfAborted();
          const tx = transaction as unknown as Db;
          const remaining = Math.max(1, Math.min(attemptIoDeadlineMs, deadline.remainingMs()));
          await tx.execute(sql`SET LOCAL lock_timeout = ${sql.raw(`'${remaining}ms'`)}`);
          await tx.execute(sql`SET LOCAL statement_timeout = ${sql.raw(`'${remaining}ms'`)}`);
          await tx.execute(sql`SET LOCAL idle_in_transaction_session_timeout = ${sql.raw(`'${remaining}ms'`)}`);
          const result = await fn(tx);
          // A timeout/close can never commit a late snapshot or cleanup claim.
          deadline.throwIfAborted();
          return result;
        }),
      );
      const snapshot = async (): Promise<Claim | null> => transaction(async (tx) => {
        let actorUid = candidate.actorUid;
        if (actorUid === undefined) {
          // Compatibility fallback for an older injected port. Canonical
          // discovery always supplies actorUid; never replace a known sender
          // with the host for account/UID authority.
          actorUid = (await readReservation(tx, candidate.attemptReservationId))?.uploaderUserId;
        }
        if (actorUid === undefined || actorUid.trim() === "") return null;
        await lockCollabArtifactAccountAuthority(tx, {
          ownerUserId: candidate.ownerUid,
          actorUserId: actorUid,
          sessionId: candidate.sessionId,
        });
        await tx.execute(sql`
          SELECT pg_advisory_xact_lock(hashtextextended(
            ${`ovid-collab-artifact:${candidate.ownerUid}:${candidate.sessionId}:${candidate.id}`}, 0))`);
        const lifecycle = await readAttemptLifecycle(tx, candidate, actorUid);
        const row = await lockArtifact(tx, candidate.id);
        const reservation = await lockReservation(tx, candidate.attemptReservationId);
        if (reservation === null || reservation.uploaderUserId !== actorUid ||
            !attemptCandidateStillCurrent(candidate, row, reservation)) return null;
        return { row, reservation, lifecycle };
      });
      const changed = (claim: Claim | null, current: Claim | null): boolean => {
        if (claim === null || current === null) return true;
        const artifactChanged = claim.row === null
          ? current.row !== null
          : current.row === null || !sameArtifactVersion(claim.row, current.row);
        // Missing workspace rows are a baseline, not a reason to skip the
        // reservation/session/account comparison after HEAD or DELETE.
        return artifactChanged ||
          !sameReservationVersion(claim.reservation, current.reservation) ||
          !sameAttemptLifecycle(claim.lifecycle, current.lifecycle);
      };

      try {
        // Claim and its UID/artifact/row locks commit before any storage I/O.
        const claimed = await snapshot();
        if (claimed === null) return "skipped" as const;
        const inspection = await deadline.run(() => input.inspect(candidate.key));
        if (inspection === "foreign") return "skipped" as const;
        if (inspection === "missing") return "missing" as const;

        // Fresh short DB-only pre-delete transaction. No lock is held by the
        // subsequent DELETE. A stale/newer-active attempt is never eligible.
        const beforeDelete = await snapshot();
        if (beforeDelete === null || changed(claimed, beforeDelete)) return "skipped" as const;
        await deadline.run(() => input.remove(candidate.key));

        // Detect a generation transition at the cleanup commit; never report a
        // changed/newer generation as successfully cleaned by a stale claim.
        const afterDelete = await snapshot();
        if (afterDelete !== null && !changed(claimed, afterDelete)) return "cleaned" as const;
        return "skipped" as const;
      } finally {
        if (ownsDeadline) deadline.close();
      }
    },

    async listReservedArtifactAttempts(limit, before) {
      if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
        throw new RangeError("reserved artifact attempt discovery limit must be 1..100");
      }
      if (before !== undefined &&
          parseCollabArtifactAttemptReservationId(`${before.artifactId}:collab-attempt:1`) === null) {
        throw new RangeError("invalid reserved artifact group cursor");
      }
      const found = await query<{
        id: string;
        artifact_id: string;
        actor_user_id: string;
        owner_user_id: string;
        session_id: string;
        object_id: string | null;
        declared_bytes: number | string;
        created_at: Date | string;
      }>(db, sql`
        SELECT * FROM (
          SELECT DISTINCT ON (owner_user_id, session_id, split_part(id, ':collab-attempt:', 1))
                 id, split_part(id, ':collab-attempt:', 1) AS artifact_id,
                 actor_user_id, owner_user_id, session_id, object_id,
                 declared_bytes, created_at
            FROM storage_reservations
           WHERE state = 'reserved'
             AND id ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}:collab-attempt:[1-9][0-9]*$'
           ORDER BY owner_user_id, session_id,
                    split_part(id, ':collab-attempt:', 1), created_at, id
        ) attempt_groups
        WHERE (${before?.artifactId ?? null}::text IS NULL OR
               (owner_user_id, session_id, artifact_id) >
               (${before?.ownerUid ?? null}::text, ${before?.sessionId ?? null}::text,
                ${before?.artifactId ?? null}::text))
        ORDER BY owner_user_id, session_id, artifact_id
        LIMIT ${limit + 1}`);
      const groups: CollabArtifactAttemptOrphanCandidate[] = [];
      for (const row of found.slice(0, limit)) {
        const parsed = parseCollabArtifactAttemptReservationId(row.id);
        const declaredBytes = Number(row.declared_bytes);
        const createdAt = dateValue(row.created_at);
        if (parsed === null || !Number.isSafeInteger(declaredBytes) || declaredBytes < 0 ||
            !Number.isFinite(createdAt.getTime())) continue;
        groups.push({
          kind: "artifact_attempt",
          id: parsed.artifactId,
          sessionId: row.session_id,
          ownerUid: row.owner_user_id,
          actorUid: row.actor_user_id,
          key: row.object_id ?? "",
          attempt: parsed.attempt,
          attemptReservationId: row.id,
          declaredBytes,
          createdAt,
        });
      }
      const lastRaw = found[Math.min(limit, found.length) - 1];
      return {
        rows: groups,
        nextCursor: found.length > limit && lastRaw !== undefined
          ? {
              ownerUid: lastRaw.owner_user_id,
              sessionId: lastRaw.session_id,
              artifactId: lastRaw.artifact_id,
            }
          : null,
      };
    },

    async listOrphanCandidates(limit, before, sequence = 0) {
      if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
        throw new RangeError("collab object orphan limit must be 1..100");
      }
      if (before !== undefined && (!Number.isFinite(before.createdAt.getTime()) ||
          parseCollabArtifactAttemptReservationId(before.attemptReservationId) === null)) {
        throw new RangeError("invalid collab artifact attempt cursor");
      }
      const budget = collabOrphanSweepBudget(limit, sequence);
      const ordinaryRows = await query<CollabOrphanCandidate & { created_at: Date | string }>(db, sql`
        SELECT * FROM (
          SELECT 'attachment' AS kind, attachment.id, attachment.session_id AS "sessionId",
                 attachment.user_id AS "ownerUid", attachment.r2_key AS key,
                 attachment.created_at
            FROM attachments attachment
            JOIN collab_rooms room ON room.session_id = attachment.session_id
           WHERE attachment.upload_status = 'failed'
          UNION ALL
          SELECT 'artifact' AS kind, object.id, object.session_id AS "sessionId",
                 object.user_id AS "ownerUid", object.r2_key AS key, object.created_at
            FROM workspace_objects object
            JOIN collab_rooms room ON room.session_id = object.session_id
           WHERE object.status = 'deleted'
          UNION ALL
          SELECT 'attachment' AS kind, reservation.id, reservation.session_id AS "sessionId",
                 reservation.owner_user_id AS "ownerUid",
                 ('users/' || reservation.owner_user_id || '/sessions/' || reservation.session_id ||
                  '/uploads/' || reservation.id) AS key,
                 reservation.created_at
            FROM storage_reservations reservation
            JOIN collab_rooms room ON room.session_id = reservation.session_id
            LEFT JOIN attachments attachment ON attachment.id = reservation.id
            LEFT JOIN workspace_objects object ON object.id = reservation.id
           WHERE reservation.state = 'released' AND reservation.object_id = reservation.id
             AND attachment.id IS NULL AND object.id IS NULL
        ) candidates
        ORDER BY created_at, kind, id
        LIMIT ${Math.max(1, budget.ordinary)}`);
      const ordinary = ordinaryRows.map(({ created_at, ...candidate }) => ({
        ...candidate,
        createdAt: dateValue(created_at),
      }));
      const hasOrdinary = ordinary.length > 0;
      const ordinaryBudget = hasOrdinary ? budget.ordinary : 0;
      // At limit one the sequence alternates classes. When a class has no
      // backlog, the other class may use the whole bounded pass.
      const attemptLimit = hasOrdinary ? budget.attempts : limit;
      const attemptPage = attemptLimit === 0
        ? { rows: [], quarantined: 0, nextCursor: before ?? null }
        : await attemptDiscovery(db, {
            limit: attemptLimit,
            ...(before === undefined ? {} : { before }),
          });
      return {
        rows: [...ordinary.slice(0, ordinaryBudget), ...attemptPage.rows]
          .sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime() ||
            a.kind.localeCompare(b.kind) || a.id.localeCompare(b.id) || a.key.localeCompare(b.key)),
        quarantined: attemptPage.quarantined ?? 0,
        nextCursor: attemptPage.nextCursor,
      };
    },
  };
}

/** Reservation mutations remain in the canonical 0038 services. */
export function createCollabReservationPort(
  db: Db,
  store: CollabReservationStore = new StorageReservationStore(db),
  options: CollabObjectStoreOptions = {},
): CollabReservationPort {
  return {
    reserve: (input) => store.reserve(input),
    finalize: (input) => store.finalize(input),
    release: (input) => store.release(input),
    get: (reservationId) => readReservation(db, reservationId),
    removeObject: (input) => removeObject(db, input, options),
  };
}

/** The one session/object authorization function used by every object mint. */
export function createCollabObjectAuthorizer(
  store: Pick<CollabObjectStore, "sessionObjectAuthority">,
): (input: CollabObjectAuthorizationInput) => Promise<CollabObjectAccess> {
  return async function authorizeSessionObject(
    input: CollabObjectAuthorizationInput,
  ): Promise<CollabObjectAccess> {
    if (input.sessionId === "" || input.objectOwnerUid === "" || input.viewerUid === "") return null;
    const authority = await store.sessionObjectAuthority(input);
    if (
      authority === null || authority.lifecycle !== "active" || authority.sessionDeleted ||
      authority.ownerAccountFenced || authority.viewerAccountFenced
    ) return null;
    if (authority.viewerRole === "owner") {
      return input.viewerUid === input.objectOwnerUid ? "owner" : null;
    }
    return input.viewerUid === input.objectOwnerUid ? null : "member";
  };
}

export class CollabObjectService {
  private readonly authorize: ReturnType<typeof createCollabObjectAuthorizer>;

  constructor(readonly deps: CollabObjectRouteDeps) {
    this.authorize = createCollabObjectAuthorizer(deps.objects);
  }

  authorizeSessionObject(input: CollabObjectAuthorizationInput): Promise<CollabObjectAccess> {
    return this.authorize(input);
  }
}

interface RoomContext extends CollabAuthorization {
  access: Exclude<CollabObjectAccess, null>;
}

async function roomContext(
  request: FastifyRequest,
  service: CollabObjectService,
): Promise<RoomContext> {
  const principal = request.principal;
  const auth = await service.deps.membership.authorize({ principal, token: token(request) });
  const access = await service.authorizeSessionObject({
    sessionId: auth.sessionId,
    objectOwnerUid: auth.ownerUserId,
    viewerUid: principal.uid,
  });
  if (access === null) throw new CollabError("not_member");
  return { ...auth, access };
}

async function requireCurrentAccess(
  service: CollabObjectService,
  context: RoomContext,
  viewerUid: string,
): Promise<void> {
  const access = await service.authorizeSessionObject({
    sessionId: context.sessionId,
    objectOwnerUid: context.ownerUserId,
    viewerUid,
  });
  if (access === null) throw new CollabError("not_member");
}

async function head(storageAdapter: CollabObjectStorage, key: string): Promise<HeadResult | null> {
  try {
    return await storageAdapter.head(key);
  } catch {
    throw unavailable();
  }
}

function failedAttachment(row: CollabAttachmentRecord): CollabObjectError {
  if (row.actualBytes === null) {
    return new CollabObjectError(
      "attachment_not_uploaded",
      409,
      "The attachment object has not reached storage.",
    );
  }
  if (row.actualBytes !== row.declaredBytes) {
    return new CollabObjectError(
      "attachment_size_mismatch",
      409,
      "The uploaded object size does not match the attachment declaration.",
    );
  }
  if (row.contentTypeDeclared && row.actualContentType !== row.declaredContentType) {
    return new CollabObjectError(
      "attachment_type_mismatch",
      409,
      "The uploaded object Content-Type does not match the attachment declaration.",
    );
  }
  return changed();
}

function assertSameRequest(
  row: CollabAttachmentRecord,
  context: RoomContext,
  viewerUid: string,
  input: { name: string; size: number; contentType: string },
): void {
  if (
    row.sessionId !== context.sessionId || row.ownerUid !== context.ownerUserId ||
    row.uploaderUid !== viewerUid
  ) throw objectNotFound();
  if (
    row.name !== input.name || row.declaredBytes !== input.size ||
    !row.contentTypeDeclared || row.declaredContentType !== input.contentType
  ) throw new CollabError("request_already_used");
}

/**
 * Fail/CAS, release or debit, delete bytes, then remove the failed host row so
 * it cannot retain a project slot. The released reservation remains as the
 * late-PUT tombstone; every step is idempotent and retryable.
 */
async function cleanupAttachment(
  deps: CollabObjectRouteDeps,
  row: CollabAttachmentRecord,
  observed: { bytes: number | null; contentType: string | null },
): Promise<void> {
  const current = await deps.objects.getAttachment({
    sessionId: row.sessionId,
    ownerUid: row.ownerUid,
    attachmentId: row.id,
  });
  if (current !== null) {
    const failed = await deps.objects.failAttachment({
      id: current.id,
      sessionId: current.sessionId,
      ownerUid: current.ownerUid,
      expected: attachmentVersion(current),
      actualBytes: observed.bytes,
      actualContentType: observed.contentType,
    });
    if (!failed) throw cleanupRequired();
  }

  let reservation = await deps.reservations.get(row.id);
  if (reservation?.state === "reserved") {
    try {
      await deps.reservations.release({ reservationId: row.id });
    } catch (error) {
      if (error instanceof QuotaContractError && error.code === "reservation_finalized") {
        await deps.reservations.removeObject({ reservationId: row.id });
      } else if (!(error instanceof QuotaContractError) ||
                 (error.code !== "reservation_not_found" && error.code !== "reservation_released")) {
        throw cleanupRequired();
      }
    }
  } else if (reservation?.state === "finalized") {
    await deps.reservations.removeObject({ reservationId: row.id });
  }
  reservation = await deps.reservations.get(row.id);
  if (reservation !== null && reservation.state !== "released") throw cleanupRequired();

  try {
    await storage(deps).delete(row.key);
  } catch {
    throw cleanupRequired();
  }

  const failedRow = await deps.objects.getAttachment({
    sessionId: row.sessionId,
    ownerUid: row.ownerUid,
    attachmentId: row.id,
  });
  if (failedRow !== null) {
    if (failedRow.uploadStatus !== "failed") throw cleanupRequired();
    const deleted = await deps.objects.deleteFailedAttachment({
      id: failedRow.id,
      sessionId: failedRow.sessionId,
      ownerUid: failedRow.ownerUid,
      expected: attachmentVersion(failedRow),
    });
    if (!deleted) throw cleanupRequired();
  }
}

async function cleanupArtifact(
  deps: CollabObjectRouteDeps,
  row: CollabArtifactRecord,
): Promise<void> {
  const reconciled = await deps.objects.reconcileArtifact({ artifact: row });
  if (!reconciled) throw cleanupRequired();
  const reservation = await deps.reservations.get(row.id);
  if (reservation?.state === "reserved") {
    await deps.reservations.release({ reservationId: row.id });
  } else if (reservation?.state === "finalized") {
    await deps.reservations.removeObject({ reservationId: row.id });
  }
  try {
    await storage(deps).delete(row.key);
  } catch {
    throw cleanupRequired();
  }
}

function pendingRecord(input: {
  id: string;
  sessionId: string;
  ownerUid: string;
  uploaderUid: string;
  name: string;
  size: number;
  key: string;
  contentType: string;
  createdAt: Date;
}): CollabAttachmentRecord {
  return {
    id: input.id,
    sessionId: input.sessionId,
    ownerUid: input.ownerUid,
    uploaderUid: input.uploaderUid,
    name: input.name,
    declaredBytes: input.size,
    key: input.key,
    declaredContentType: input.contentType,
    contentTypeDeclared: true,
    projectId: null,
    uploadStatus: "pending",
    actualBytes: null,
    actualContentType: null,
    finalizedAt: null,
    reservationState: "reserved",
    createdAt: input.createdAt,
  };
}

function ticketFor(row: CollabAttachmentRecord, uploadUrl: string, now: Date): CollabAttachmentTicket {
  const requiredHeaders = { "Content-Type": row.declaredContentType };
  return {
    schemaVersion: 1,
    attachmentId: row.id,
    uploadUrl,
    path: `uploads/${sanitizeAttachmentName(row.name)}`,
    expiresAt: new Date(now.getTime() + ATTACHMENT_UPLOAD_TTL_SECONDS * 1000).toISOString(),
    contentType: row.declaredContentType,
    requiredHeaders,
    uploadHeaders: { ...requiredHeaders },
  };
}

async function createAttachment(
  request: FastifyRequest,
  service: CollabObjectService,
): Promise<CollabAttachmentTicket> {
  const { deps } = service;
  const context = await roomContext(request, service);
  const body = strictBody(request, ["schemaVersion", "idempotencyKey", "name", "size", "contentType"]);
  strictQuery(request, []);
  const key = body.idempotencyKey;
  if (typeof key !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(key)) {
    throw new CollabError("invalid_request");
  }
  if (typeof body.name !== "string" || body.name === "" ||
      typeof body.size !== "number" || !Number.isSafeInteger(body.size) || body.size <= 0 ||
      typeof body.contentType !== "string") {
    throw new CollabError("invalid_request");
  }
  const size = body.size;
  if (size > ATTACHMENT_MAX_BYTES) {
    throw new CollabObjectError(
      "attachment_too_large",
      400,
      `Attachments are limited to ${ATTACHMENT_MAX_BYTES} bytes.`,
    );
  }
  let contentType: string;
  try {
    contentType = normalizeAttachmentContentType(body.contentType);
  } catch {
    throw new CollabError("invalid_request");
  }
  const input = { name: body.name, size, contentType };
  const viewerUid = request.principal.uid;
  const attachmentId = stableAttachmentId(context.sessionId, viewerUid, key);
  const r2Key = attachmentObjectKey(context.ownerUserId, context.sessionId, attachmentId);
  storage(deps);

  return deps.objects.withAttachmentLock(attachmentId, async () => {
    let row = await deps.objects.getAttachment({
      sessionId: context.sessionId,
      ownerUid: context.ownerUserId,
      attachmentId,
    });
    let reservation = await deps.reservations.get(attachmentId);
    const synthetic = pendingRecord({
      id: attachmentId,
      sessionId: context.sessionId,
      ownerUid: context.ownerUserId,
      uploaderUid: viewerUid,
      ...input,
      key: r2Key,
      createdAt: clock(deps),
    });
    if (row !== null) {
      assertSameRequest(row, context, viewerUid, input);
      if (row.uploadStatus === "failed") {
        await cleanupAttachment(deps, row, {
          bytes: row.actualBytes,
          contentType: row.actualContentType,
        });
        throw failedAttachment(row);
      }
      if (row.uploadStatus === "ready" || reservation?.state === "finalized") throw changed();
    }
    if (reservation !== null) {
      assertReservationIdentity(reservation, {
        ownerUid: context.ownerUserId,
        sessionId: context.sessionId,
        id: attachmentId,
        declaredBytes: size,
      });
      if (reservation.uploaderUserId !== viewerUid || reservation.state !== "reserved") {
        if (reservation.state === "released") await cleanupAttachment(deps, row ?? synthetic, {
          bytes: null,
          contentType: null,
        });
        throw changed();
      }
    } else {
      // Canonical capacity preflight is BEFORE reservation, signing and PUT;
      // attachments.create repeats it under the project lock as the race backstop.
      await deps.objects.assertSessionCapacity({
        sessionId: context.sessionId,
        ownerUid: context.ownerUserId,
      });
      const reserved = await deps.reservations.reserve({
        reservationId: attachmentId,
        ownerUserId: context.ownerUserId,
        uploaderUserId: viewerUid,
        sessionId: context.sessionId,
        objectId: attachmentId,
        declaredBytes: size,
      });
      if (!reserved.ok) throw quotaFailure(reserved, () => clock(deps));
      reservation = await deps.reservations.get(attachmentId);
      if (reservation === null) throw new Error("canonical storage reservation disappeared");
    }

    try {
      await requireCurrentAccess(service, context, viewerUid);
      if (row === null) {
        try {
          await deps.objects.createAttachment({
            id: attachmentId,
            sessionId: context.sessionId,
            ownerUid: context.ownerUserId,
            name: input.name,
            declaredBytes: size,
            key: r2Key,
            contentType,
          });
        } catch (error) {
          const existing = await deps.objects.getAttachment({
            sessionId: context.sessionId,
            ownerUid: context.ownerUserId,
            attachmentId,
          });
          if (existing === null) {
            if (error instanceof ProjectFileLimitError) {
              await cleanupAttachment(deps, synthetic, { bytes: null, contentType: null });
            }
            throw error;
          }
          row = existing;
        }
        row ??= await deps.objects.getAttachment({
          sessionId: context.sessionId,
          ownerUid: context.ownerUserId,
          attachmentId,
        });
        if (row === null) throw new Error("canonical attachment insert returned no row");
        assertSameRequest(row, context, viewerUid, input);
      }
    } catch (error) {
      await cleanupAttachment(deps, row ?? synthetic, { bytes: null, contentType: null });
      throw error;
    }

    const uploadUrl = await deps.objects.withAttachmentSigningFence({
      attachment: row,
      reservation,
      sign: async () => {
        try {
          return await storage(deps).presignPut({
            key: row!.key,
            ttlSeconds: ATTACHMENT_UPLOAD_TTL_SECONDS,
            contentType,
          });
        } catch {
          // Pending intent remains retryable with the same row/reservation.
          throw unavailable();
        }
      },
    });
    const ticket = ticketFor(row, uploadUrl, clock(deps));

    // Close the response-side race as well: a terminal transition committed
    // after the lock released is never answered with a fresh ticket.
    const latestRow = await deps.objects.getAttachment({
      sessionId: context.sessionId,
      ownerUid: context.ownerUserId,
      attachmentId,
    });
    const latestReservation = await deps.reservations.get(attachmentId);
    if (latestRow === null || latestReservation === null ||
        !sameAttachmentVersion(latestRow, attachmentVersion(row)) ||
        !sameReservationVersion(latestReservation, reservation) ||
        latestRow.uploadStatus !== "pending" || latestReservation.state !== "reserved") {
      if (latestRow?.uploadStatus === "failed" || latestReservation?.state === "released") {
        await cleanupAttachment(deps, latestRow ?? synthetic, { bytes: null, contentType: null });
      }
      throw changed();
    }
    try {
      await requireCurrentAccess(service, context, viewerUid);
    } catch (error) {
      await cleanupAttachment(deps, row, { bytes: null, contentType: null });
      throw error;
    }
    return ticket;
  });
}

function declarationMismatch(
  row: CollabAttachmentRecord,
  actual: HeadResult,
): CollabObjectError | null {
  if (row.uploadStatus === "ready") {
    return actual.bytes !== row.actualBytes || (actual.contentType ?? null) !== row.actualContentType
      ? changed()
      : null;
  }
  if (actual.bytes !== row.declaredBytes) {
    return new CollabObjectError(
      "attachment_size_mismatch",
      409,
      "The uploaded object size does not match the attachment declaration.",
    );
  }
  if (row.contentTypeDeclared && (actual.contentType ?? null) !== row.declaredContentType) {
    return new CollabObjectError(
      "attachment_type_mismatch",
      409,
      "The uploaded object Content-Type does not match the attachment declaration.",
    );
  }
  return null;
}

async function settledAfterFinalize(
  deps: CollabObjectRouteDeps,
  original: CollabAttachmentRecord,
  actual: HeadResult,
): Promise<CollabAttachmentRecord | null> {
  const row = await deps.objects.getAttachment({
    sessionId: original.sessionId,
    ownerUid: original.ownerUid,
    attachmentId: original.id,
  });
  if (row === null || row.uploaderUid !== original.uploaderUid || declarationMismatch(row, actual) !== null) {
    return null;
  }
  const reservation = await deps.reservations.get(original.id);
  try {
    assertReadySettlement(row, reservation);
  } catch {
    return null;
  }
  return row;
}

async function finalizeAttachment(
  request: FastifyRequest,
  service: CollabObjectService,
): Promise<AttachmentFinalizeResponse & { schemaVersion: 1 }> {
  const { deps } = service;
  const context = await roomContext(request, service);
  const attachmentId = objectId(request, "attachmentId");
  strictBody(request, ["schemaVersion"]);
  strictQuery(request, []);
  const storageAdapter = storage(deps);

  return deps.objects.withAttachmentLock(attachmentId, async () => {
    const row = await deps.objects.getAttachment({
      sessionId: context.sessionId,
      ownerUid: context.ownerUserId,
      attachmentId,
    });
    if (row === null) throw objectNotFound();
    const reservation = await deps.reservations.get(attachmentId);
    if (reservation === null || row.uploaderUid !== reservation.uploaderUserId) throw objectNotFound();
    if (row.uploaderUid !== request.principal.uid) throw objectNotFound();
    assertReservationIdentity(reservation, {
      ownerUid: context.ownerUserId,
      sessionId: context.sessionId,
      id: attachmentId,
      declaredBytes: row.declaredBytes,
    });
    await requireCurrentAccess(service, context, request.principal.uid);

    if (row.uploadStatus === "failed") {
      await cleanupAttachment(deps, row, {
        bytes: row.actualBytes,
        contentType: row.actualContentType,
      });
      throw failedAttachment(row);
    }
    if (reservation.state === "released") {
      await cleanupAttachment(deps, row, { bytes: null, contentType: null });
      throw changed();
    }

    const actual = await head(storageAdapter, row.key);
    if (actual === null) {
      await cleanupAttachment(deps, row, { bytes: null, contentType: null });
      throw new CollabObjectError(
        "attachment_not_uploaded",
        409,
        "The attachment object has not reached storage.",
      );
    }
    const mismatch = declarationMismatch(row, actual);
    if (mismatch !== null) {
      await cleanupAttachment(deps, row, {
        bytes: actual.bytes,
        contentType: actual.contentType ?? null,
      });
      throw mismatch;
    }
    await requireCurrentAccess(service, context, request.principal.uid);

    let settled: StorageReservationResult;
    try {
      settled = await deps.objects.finalizeAttachment({
        id: row.id,
        sessionId: row.sessionId,
        ownerUid: row.ownerUid,
        expected: attachmentVersion(row),
        expectedReservation: reservation,
        actualBytes: actual.bytes,
        actualContentType: actual.contentType ?? null,
        etag: actual.etag,
      });
    } catch (error) {
      if (error instanceof AttachmentFinalizeError && error.code === "not_found") throw objectNotFound();
      // A different request may have won an idempotent settle while this one
      // failed. Never delete that valid committed object from a stale request.
      const recovered = await settledAfterFinalize(deps, row, actual);
      if (recovered !== null) {
        settled = { ok: true, reservationId: attachmentId };
      } else {
        const latest = await deps.objects.getAttachment({
          sessionId: context.sessionId,
          ownerUid: context.ownerUserId,
          attachmentId,
        });
        await cleanupAttachment(deps, latest ?? row, {
          bytes: actual.bytes,
          contentType: actual.contentType ?? null,
        });
        throw error;
      }
    }
    if (!settled.ok) {
      const recovered = await settledAfterFinalize(deps, row, actual);
      if (recovered !== null) {
        settled = { ok: true, reservationId: attachmentId };
      } else {
        const latest = await deps.objects.getAttachment({
          sessionId: context.sessionId,
          ownerUid: context.ownerUserId,
          attachmentId,
        });
        await cleanupAttachment(deps, latest ?? row, {
          bytes: actual.bytes,
          contentType: actual.contentType ?? null,
        });
        throw quotaFailure(settled, () => clock(deps));
      }
    }
    await requireCurrentAccess(service, context, request.principal.uid);
    return {
      schemaVersion: 1,
      attachmentId,
      status: "ready",
      size: actual.bytes,
      contentType: actual.contentType ?? row.declaredContentType,
    };
  });
}

function assertReadySettlement(
  row: CollabAttachmentRecord,
  reservation: CollabStorageReservation | null,
): asserts reservation is CollabStorageReservation {
  if (row.uploadStatus !== "ready" || reservation === null || reservation.state !== "finalized" ||
      row.reservationState !== "finalized" || reservation.actualBytes !== row.actualBytes ||
      reservation.actualContentType !== row.actualContentType) {
    if (row.uploadStatus === "pending") {
      throw new CollabObjectError(
        "attachment_not_uploaded",
        409,
        "The attachment object has not reached storage.",
      );
    }
    throw objectNotFound();
  }
  assertReservationIdentity(reservation, {
    ownerUid: row.ownerUid,
    sessionId: row.sessionId,
    id: row.id,
    declaredBytes: row.declaredBytes,
  });
}

async function mintUrl(
  service: CollabObjectService,
  context: RoomContext,
  viewerUid: string,
  input: { key: string; name: string; contentType: string | null },
): Promise<{ schemaVersion: 1; url: string; expiresAt: string }> {
  const { deps } = service;
  const ttlSeconds = deps.downloadTtlSeconds ?? DEFAULT_PRESIGN_TTL_SECONDS;
  const contentType = sanitizeCdnContentType(input.contentType) ?? "application/octet-stream";
  const options: PresignGetOptions | undefined = isActiveCdnContentType(contentType)
    ? { disposition: "attachment", filename: input.name, contentType }
    : undefined;
  await requireCurrentAccess(service, context, viewerUid);
  let url: string;
  try {
    url = await storage(deps).presignGet(input.key, ttlSeconds, options);
  } catch {
    throw unavailable();
  }
  await requireCurrentAccess(service, context, viewerUid);
  return {
    schemaVersion: 1,
    url,
    expiresAt: new Date(clock(deps).getTime() + ttlSeconds * 1000).toISOString(),
  };
}

/** Bounded retry for terminal reservations/failed rows, including late PUTs. */
export async function reconcileCollabObjectOrphans(
  deps: CollabObjectRouteDeps,
  limit = 50,
  before?: CollabArtifactAttemptCursor,
  suppliedDeadline?: CollabArtifactDeadline,
  sequence = 0,
): Promise<{
  examined: number;
  cleaned: number;
  failed: number;
  skipped: number;
  quarantined: number;
  nextCursor: CollabArtifactAttemptCursor | null;
}> {
  const deadline = suppliedDeadline ?? new CollabArtifactDeadline(deps.recoveryDeadlineMs ?? 20_000);
  const ownsDeadline = suppliedDeadline === undefined;
  const boundedLimit = Math.min(Math.max(limit, 1), 100);
  let cleaned = 0;
  let failed = 0;
  let skipped = 0;
  try {
    const page = await deadline.run(() => deps.objects.listOrphanCandidates(boundedLimit, before, sequence));
    for (const candidate of page.rows) {
      try {
        if (candidate.kind === "artifact_attempt") {
          const outcome = await deadline.run(() => deps.objects.cleanupArtifactAttempt({
            candidate,
            deadline,
            inspect: async (key) => {
              const actual = await deadline.run(() => head(storage(deps), key));
              const ownership = classifyCollabArtifactAttemptHead(actual, candidate);
              return ownership === "owned" && actual?.bytes !== candidate.declaredBytes
                ? "foreign"
                : ownership;
            },
            remove: (key) => deadline.run(() => storage(deps).delete(key)),
          }));
          if (outcome === "skipped") skipped += 1;
          else cleaned += 1;
          continue;
        }

        let didClean = false;
        await deadline.run(async () => {
          if (candidate.kind === "attachment") {
            const row = await deps.objects.getAttachment({
              sessionId: candidate.sessionId,
              ownerUid: candidate.ownerUid,
              attachmentId: candidate.id,
            });
            const reservation = await deps.reservations.get(candidate.id);
            if (row?.uploadStatus === "ready" && reservation?.state === "finalized") return;
            await cleanupAttachment(deps, row ?? {
              id: candidate.id,
              sessionId: candidate.sessionId,
              ownerUid: candidate.ownerUid,
              uploaderUid: reservation?.uploaderUserId ?? candidate.ownerUid,
              name: "attachment",
              declaredBytes: reservation?.declaredBytes ?? 0,
              key: candidate.key,
              declaredContentType: "application/octet-stream",
              contentTypeDeclared: false,
              projectId: null,
              uploadStatus: "failed",
              actualBytes: null,
              actualContentType: null,
              finalizedAt: null,
              reservationState: reservation?.state ?? "released",
              createdAt: new Date(0),
            }, { bytes: null, contentType: null });
            didClean = true;
          } else {
            const row = await deps.objects.getArtifact({
              sessionId: candidate.sessionId,
              ownerUid: candidate.ownerUid,
              artifactId: candidate.id,
            });
            if (row?.status === "active" && row.reservationState === "finalized") return;
            if (row !== null) {
              await cleanupArtifact(deps, row);
            } else {
              const reservation = await deps.reservations.get(candidate.id);
              if (reservation?.state === "finalized") {
                await deps.reservations.removeObject({ reservationId: candidate.id });
              } else if (reservation?.state === "reserved") {
                await deps.reservations.release({ reservationId: candidate.id });
              }
              await storage(deps).delete(candidate.key);
            }
            didClean = true;
          }
        });
        if (didClean) cleaned += 1;
        else skipped += 1;
      } catch {
        failed += 1;
      }
    }
    return {
      examined: page.rows.length,
      cleaned,
      failed,
      skipped,
      quarantined: page.quarantined,
      nextCursor: page.nextCursor,
    };
  } finally {
    if (ownsDeadline) deadline.close();
  }
}

export function registerCollabObjectRoutes(app: FastifyInstance, deps: CollabObjectRouteDeps): void {
  const service = new CollabObjectService(deps);
  app.addHook("onSend", async (_request, reply) => {
    reply.header("Cache-Control", "private, no-store");
    reply.header("Pragma", "no-cache");
  });

  if (deps.orphanSweepMs !== undefined && deps.orphanSweepMs > 0) {
    const rescanMs = deps.orphanRescanMs ?? 300_000;
    const batchLimit = deps.recoveryBatchLimit ?? 50;
    const recoveryDeadlineMs = deps.recoveryDeadlineMs ?? 20_000;
    const reservedGroupsPerPass = deps.recoveryReservedGroupsPerPass ?? 8;
    const reservedReleaseLimit = deps.recoveryReservedReleaseLimit ?? 64;
    for (const value of [rescanMs, recoveryDeadlineMs]) {
      if (!Number.isSafeInteger(value) || value < 1) {
        throw new RangeError("collab recovery intervals/deadline must be positive integers");
      }
    }
    for (const value of [batchLimit, reservedGroupsPerPass, reservedReleaseLimit]) {
      if (!Number.isSafeInteger(value) || value < 1 || value > 100) {
        throw new RangeError("collab recovery batch limits must be within 1..100");
      }
    }
    const planner = new CollabOrphanSweepScheduler({
      rescanDelayMs: rescanMs,
      now: deps.wallClockMs ?? Date.now,
    });
    const reservedRelease = deps.reservedRelease ?? releaseCollabArtifactReservedAttempts;
    let reservedCursor: CollabReservedArtifactGroupCursor | undefined;
    let closing = false;
    let active: Promise<void> | null = null;
    let activeDeadline: CollabArtifactDeadline | null = null;
    const abort = new AbortController();
    const releaseReserved = async (deadline: CollabArtifactDeadline) => {
      const page = await deadline.run(() =>
        deps.objects.listReservedArtifactAttempts(reservedGroupsPerPass, reservedCursor));
      // Stable selected group identities advance even when a group later throws
      // or exceeds its bounded remaining follow-up. Failed work is retried on a
      // later wrap, never allowed to hold the same first page forever.
      reservedCursor = page.nextCursor ?? undefined;
      for (const candidate of page.rows) {
        try {
          let remaining = 0;
          // At most eight helper calls per selected group per pass. This drains
          // normal remaining work while preventing a no-progress group from
          // spinning indefinitely inside one deadline.
          for (let followup = 0; followup < 8; followup += 1) {
            const result = await reservedRelease({
              db: deps.objects.db,
              ownerUserId: candidate.ownerUid,
              sessionId: candidate.sessionId,
              artifactId: candidate.id,
              deadline,
              limit: reservedReleaseLimit,
            });
            remaining = result.remaining;
            if (remaining === 0) break;
            if (result.released === 0) break;
          }
          if (remaining > 0) {
            console.warn("[gateway] collab reserved artifact release has remaining work");
          }
        } catch {
          // Thrown group errors are not success. The cursor still advances so
          // later groups receive bounded turns before this group is retried.
          console.warn("[gateway] collab reserved artifact release remains pending");
        }
      }
    };
    const sweep = async (deadline: CollabArtifactDeadline) => {
      const plan = planner.nextPlan(batchLimit);
      // Accounting-only reserved release always precedes orphan discovery and
      // is DB-only; HEAD/DELETE below never run under these DB locks.
      await releaseReserved(deadline);
      const result = await reconcileCollabObjectOrphans(
        deps,
        batchLimit,
        plan.attemptCursor,
        deadline,
        plan.sequence,
      );
      planner.complete(plan, result.nextCursor);
      if (result.failed > 0) console.warn("[gateway] collab object orphan cleanup remains pending");
      if (result.quarantined > 0) {
        console.warn("[gateway] collab object recovery quarantined malformed attempt keys", {
          count: result.quarantined,
        });
      }
    };
    const schedule = () => {
      if (active !== null || closing) return;
      const deadline = new CollabArtifactDeadline(recoveryDeadlineMs, abort.signal);
      activeDeadline = deadline;
      active = (async () => {
        try {
          await sweep(deadline);
        } catch {
          console.warn("[gateway] collab object orphan sweep failed; retry scheduled");
        } finally {
          deadline.close();
          if (activeDeadline === deadline) activeDeadline = null;
        }
      })().finally(() => { active = null; });
    };
    const timer = setInterval(schedule, deps.orphanSweepMs);
    timer.unref();
    app.addHook("onClose", async () => {
      closing = true;
      clearInterval(timer);
      abort.abort();
      // Close cancels the overall pass deadline as well as storage callbacks;
      // the awaited active promise therefore cannot wait forever on a slow port.
      await active;
    });
  }

  app.post("/chat/:token/attachments", async (request, reply) => {
    try {
      return reply.code(201).send(await createAttachment(request, service));
    } catch (error) { return collabObjectRefusal(reply, error); }
  });

  app.post("/chat/:token/attachments/:attachmentId/finalize", async (request, reply) => {
    try {
      return reply.send(await finalizeAttachment(request, service));
    } catch (error) { return collabObjectRefusal(reply, error); }
  });

  app.get("/chat/:token/attachments", async (request, reply) => {
    try {
      const context = await roomContext(request, service);
      const page = pageQuery(request);
      const result = await deps.objects.listAttachments({
        sessionId: context.sessionId,
        ownerUid: context.ownerUserId,
        ...page,
      });
      await requireCurrentAccess(service, context, request.principal.uid);
      return reply.send({
        schemaVersion: 1,
        items: result.rows.map(attachmentMetadata).filter((row) => row !== null),
        nextCursor: result.nextCursor,
      });
    } catch (error) { return collabObjectRefusal(reply, error); }
  });

  app.get("/chat/:token/attachments/:attachmentId", async (request, reply) => {
    try {
      const context = await roomContext(request, service);
      const attachmentId = objectId(request, "attachmentId");
      strictQuery(request, []);
      const row = await deps.objects.getAttachment({
        sessionId: context.sessionId,
        ownerUid: context.ownerUserId,
        attachmentId,
      });
      if (row === null) throw objectNotFound();
      const metadata = attachmentMetadata(row);
      if (metadata === null) throw objectNotFound();
      await requireCurrentAccess(service, context, request.principal.uid);
      return reply.send({ schemaVersion: 1, ...metadata });
    } catch (error) { return collabObjectRefusal(reply, error); }
  });

  app.get("/chat/:token/attachments/:attachmentId/url", async (request, reply) => {
    try {
      const context = await roomContext(request, service);
      const attachmentId = objectId(request, "attachmentId");
      strictQuery(request, []);
      return deps.objects.withAttachmentLock(attachmentId, async () => {
        const row = await deps.objects.getAttachment({
          sessionId: context.sessionId,
          ownerUid: context.ownerUserId,
          attachmentId,
        });
        if (row === null) throw objectNotFound();
        const reservation = await deps.reservations.get(attachmentId);
        assertReadySettlement(row, reservation);
        const actual = await head(storage(deps), row.key);
        if (actual === null || declarationMismatch(row, actual) !== null) {
          await cleanupAttachment(deps, row, {
            bytes: actual?.bytes ?? null,
            contentType: actual?.contentType ?? null,
          });
          if (actual === null) throw objectNotFound();
          throw changed();
        }
        const minted = await mintUrl(service, context, request.principal.uid, {
          key: row.key,
          name: row.name,
          contentType: actual.contentType ?? row.actualContentType ?? row.declaredContentType,
        });
        const latest = await deps.objects.getAttachment({
          sessionId: context.sessionId,
          ownerUid: context.ownerUserId,
          attachmentId,
        });
        const latestReservation = await deps.reservations.get(attachmentId);
        if (latest === null || !sameAttachmentVersion(latest, attachmentVersion(row)) ||
            latestReservation === null || !sameReservationVersion(latestReservation, reservation)) {
          throw changed();
        }
        return reply.send(minted);
      });
    } catch (error) { return collabObjectRefusal(reply, error); }
  });

  app.get("/chat/:token/artifacts", async (request, reply) => {
    try {
      const context = await roomContext(request, service);
      const page = pageQuery(request);
      const result = await deps.objects.listArtifacts({
        sessionId: context.sessionId,
        ownerUid: context.ownerUserId,
        ...page,
      });
      await requireCurrentAccess(service, context, request.principal.uid);
      return reply.send({
        schemaVersion: 1,
        items: result.rows.map(artifactMetadata),
        nextCursor: result.nextCursor,
      });
    } catch (error) { return collabObjectRefusal(reply, error); }
  });

  app.get("/chat/:token/artifacts/:artifactId", async (request, reply) => {
    try {
      const context = await roomContext(request, service);
      const artifactId = objectId(request, "artifactId");
      strictQuery(request, []);
      const row = await deps.objects.getArtifact({
        sessionId: context.sessionId,
        ownerUid: context.ownerUserId,
        artifactId,
      });
      if (row === null || row.status !== "active" || row.reservationState !== "finalized") {
        throw objectNotFound();
      }
      await requireCurrentAccess(service, context, request.principal.uid);
      return reply.send({ schemaVersion: 1, ...artifactMetadata(row) });
    } catch (error) { return collabObjectRefusal(reply, error); }
  });

  app.get("/chat/:token/artifacts/:artifactId/url", async (request, reply) => {
    try {
      const context = await roomContext(request, service);
      const artifactId = objectId(request, "artifactId");
      strictQuery(request, []);
      const row = await deps.objects.getArtifact({
        sessionId: context.sessionId,
        ownerUid: context.ownerUserId,
        artifactId,
      });
      if (row === null || row.status !== "active" || row.reservationState !== "finalized") {
        throw objectNotFound();
      }
      const reservation = await deps.reservations.get(artifactId);
      if (reservation === null || reservation.state !== "finalized" ||
          reservation.actualBytes !== row.bytes) throw objectNotFound();
      const access = await service.authorizeSessionObject({
        sessionId: row.sessionId,
        objectOwnerUid: row.ownerUid,
        viewerUid: request.principal.uid,
      });
      if (access === null || row.ownerUid !== context.ownerUserId || row.sessionId !== context.sessionId) {
        throw objectNotFound();
      }
      const actual = await head(storage(deps), row.key);
      if (actual === null || actual.bytes !== row.bytes ||
          (row.contentType !== null && actual.contentType !== row.contentType)) {
        await cleanupArtifact(deps, row);
        if (actual === null) {
          throw new CollabObjectError(
            "artifact_unavailable",
            404,
            "This file is no longer available in Ovid Cloud.",
          );
        }
        throw new CollabObjectError(
          "artifact_incomplete",
          409,
          "This file did not finish uploading. Remove and re-attach it.",
        );
      }
      const minted = await mintUrl(service, context, request.principal.uid, {
        key: row.key,
        name: row.name,
        contentType: actual.contentType ?? row.contentType,
      });
      const latest = await deps.objects.getArtifact({
        sessionId: context.sessionId,
        ownerUid: context.ownerUserId,
        artifactId,
      });
      if (latest === null || latest.status !== "active" || latest.reservationState !== "finalized") {
        throw changed();
      }
      return reply.send(minted);
    } catch (error) { return collabObjectRefusal(reply, error); }
  });
}
