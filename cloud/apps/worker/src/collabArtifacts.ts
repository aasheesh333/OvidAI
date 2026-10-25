import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { open, realpath, type FileHandle } from "node:fs/promises";
import { isAbsolute, relative, resolve, sep } from "node:path";
import { Transform } from "node:stream";
import { and, eq, sql } from "drizzle-orm";
import {
  CollabArtifactDeadline,
  CollabArtifactStorageError,
  ProjectFileLimitError,
  QuotaContractError,
  StorageReservationStore,
  assertProjectFileCapacity,
  classifyCollabArtifactAttemptHead,
  collabArtifactAttemptKey as recoveryAttemptKey,
  collabArtifactAttemptMayDelete,
  collabArtifactAttemptReservationId as recoveryAttemptReservationId,
  lockCollabArtifactAccountAuthority,
  lockProjectFiles,
  schema,
  verifyCollabArtifactObject,
  workspaceObjects as canonicalWorkspaceObjects,
  type CollabArtifactObjectExpectation,
  type Db,
  type StorageFinalizeInput,
  type StorageReservationInput,
  type StorageReservationResult,
  type WorkspaceObjectRow,
} from "@ovid/db";
import {
  assertSafeSegment,
  contentTypeFor,
  sanitizeCdnContentType,
  type HeadResult,
  type StorageAdapter,
} from "@ovid/storage";
import { ConfinementError, resolveConfined } from "./tools/confinement.js";

/**
 * No transaction or session advisory lock surrounds source/HEAD/GET/PUT/DELETE
 * I/O. A pending workspace_objects row is a durable, non-listable intent. Each
 * attempt has a new durable generation and a different immutable key. A stale
 * worker can finish only at its old key; it cannot overwrite or delete the key
 * a newer worker publishes. Short DB transactions compare room/member and
 * pending-attempt generations at every write boundary. Account UID locks and
 * durable account/session/member fingerprints are rechecked at those boundaries.
 * Canonical finalization and the pending -> active transition commit atomically.
 * A separate cumulative DB deadline bounds pool acquisition and all DB work.
 */

export interface CollabArtifactIdentity {
  actorUserId: string;
  ownerUserId: string;
  sessionId: string;
}

export interface CollabArtifactRegisterInput extends CollabArtifactIdentity {
  name: string;
  contentType?: string;
  sourcePath?: string;
  content?: Buffer;
  idempotencyKey: string;
  /** Optional caller cancellation; storage waiting is independently bounded. */
  signal?: AbortSignal;
}

export interface CollabArtifactRecord extends CollabArtifactIdentity {
  id: string;
  key: string;
  sizeBytes: number;
  sha256Hex: string;
  contentType: string;
}

export type CollabArtifactErrorCode =
  | "invalid_request"
  | "not_member"
  | "membership_changed"
  | "source_outside_workspace"
  | "source_unavailable"
  | "idempotency_conflict"
  | "artifact_deleted"
  | "artifact_unavailable"
  | "artifact_changed"
  | "artifact_in_progress"
  | "attempt_superseded"
  | "upload_limit_reached"
  | "storage_quota_exceeded"
  | "project_file_limit"
  | "lock_timeout"
  | "db_timeout"
  | "storage_timeout"
  | "storage_unavailable"
  | "cancelled"
  | "temporarily_unavailable";

export class CollabArtifactError extends Error {
  constructor(
    readonly code: CollabArtifactErrorCode,
    readonly resetsAt: Date | null = null,
    readonly retryable = false,
    options?: ErrorOptions,
  ) {
    super(code, options);
    this.name = "CollabArtifactError";
  }
}

export interface CollabArtifactExternalError {
  status: number;
  code: string;
  retryable: boolean;
  retryAfterSeconds: number | null;
}

function nestedCode(error: unknown): string | null {
  let current = error;
  for (let depth = 0; depth < 6 && current instanceof Error; depth += 1) {
    const code = (current as { code?: unknown }).code;
    if (typeof code === "string") return code;
    current = current.cause;
  }
  return null;
}

export function asCollabArtifactError(error: unknown): CollabArtifactError {
  if (error instanceof CollabArtifactError) return error;
  if (error instanceof CollabArtifactStorageError) {
    return new CollabArtifactError(
      error.code,
      null,
      error.code === "storage_timeout" || error.code === "db_timeout" ||
        error.code === "storage_unavailable" || error.code === "artifact_unavailable",
      { cause: error },
    );
  }
  if (error instanceof ProjectFileLimitError) {
    return new CollabArtifactError("project_file_limit", null, false, { cause: error });
  }
  if (error instanceof QuotaContractError) {
    if (error.code === "idempotency_conflict") {
      return new CollabArtifactError("idempotency_conflict", null, false, { cause: error });
    }
    if (error.code === "unknown_user") {
      return new CollabArtifactError("not_member", null, false, { cause: error });
    }
    return new CollabArtifactError("temporarily_unavailable", null, true, { cause: error });
  }
  const code = nestedCode(error);
  if (code === "55P03") return new CollabArtifactError("lock_timeout", null, true, { cause: error });
  if (code === "ENOENT" || code === "ENOTDIR") {
    return new CollabArtifactError("source_unavailable", null, false, { cause: error });
  }
  if (code === "ELOOP") {
    return new CollabArtifactError("source_outside_workspace", null, false, { cause: error });
  }
  if (code === "storage_quota_exceeded" || code === "upload_limit_reached") {
    return new CollabArtifactError(code, null, code === "upload_limit_reached", { cause: error });
  }
  if (code === "23505") {
    return new CollabArtifactError("idempotency_conflict", null, false, { cause: error });
  }
  return new CollabArtifactError("temporarily_unavailable", null, true, { cause: error });
}

/** Stable worker/gateway mapping; raw adapter, SQL and filesystem text is not exposed. */
export function collabArtifactErrorResponse(
  error: unknown,
  now = new Date(),
): CollabArtifactExternalError {
  const typed = asCollabArtifactError(error);
  const result = (status: number, code: string, retryable: boolean, retryAfterSeconds: number | null = null) => ({
    status, code, retryable, retryAfterSeconds,
  });
  switch (typed.code) {
    case "invalid_request":
    case "source_outside_workspace":
    case "source_unavailable":
      return result(400, "invalid_request", false);
    case "not_member": return result(403, "not_member", false);
    case "membership_changed": return result(503, "temporarily_unavailable", true, 1);
    case "idempotency_conflict": return result(409, "request_already_used", false);
    case "artifact_deleted": return result(410, "artifact_deleted", false);
    case "artifact_changed": return result(409, "artifact_changed", false);
    case "storage_quota_exceeded": return result(409, "storage_quota_exceeded", false);
    case "project_file_limit": return result(409, "project_file_limit", false);
    case "upload_limit_reached": {
      const retryAfterSeconds = typed.resetsAt === null
        ? null
        : Math.max(1, Math.ceil((typed.resetsAt.getTime() - now.getTime()) / 1000));
      return result(429, "upload_limit_reached", true, retryAfterSeconds);
    }
    case "cancelled": return result(499, "cancelled", false);
    case "artifact_unavailable":
    case "artifact_in_progress":
    case "attempt_superseded":
    case "lock_timeout":
    case "db_timeout":
    case "storage_timeout":
    case "storage_unavailable":
    case "temporarily_unavailable":
      return result(503, "temporarily_unavailable", true, 1);
  }
}

export interface CollabArtifactAccountAuthority {
  /** Null means no deletion row; the UID advisory lock covers that absent-row case. */
  state: string | null;
  updatedAt: string | null;
}

export interface CollabArtifactAuthorization {
  role: "owner" | "member";
  roomId: string;
  roomGeneration: number;
  membershipGeneration: number;
  /** Durable lifecycle snapshots, rechecked at every registrar write boundary. */
  sessionUpdatedAt: string;
  ownerAccount: CollabArtifactAccountAuthority;
  actorAccount: CollabArtifactAccountAuthority;
}

/**
 * Implementations must lock/read authority inside the supplied short transaction.
 * Production callers must first invoke lockCollabArtifactAccountAuthority (the
 * registrar's lockArtifact does this) so deletion cannot change state mid-write.
 */
export interface CollabArtifactAuthorizationPort {
  authorize(
    input: CollabArtifactIdentity,
    db: Db,
  ): Promise<CollabArtifactAuthorization | null>;
}

interface RoomAuthorityRow {
  id: string;
  lifecycle: string;
  generation: number | string;
}

interface MemberAuthorityRow {
  participant_id: string;
  role: "owner" | "participant";
  status: string;
  generation: number | string;
}

/**
 * Real transaction-safe production adapter. It intentionally does not call
 * CollabRepos.authorize (which starts its own transaction). Room/member/session
 * row locks make close/revoke/delete linearize before or after this short DB
 * transaction; returned generations are rechecked at later write boundaries.
 */
export function createCollabArtifactAuthorizationPort(): CollabArtifactAuthorizationPort {
  return {
    async authorize(input, db) {
      // Idempotent within the registrar's outer transaction, and also safe for
      // a direct production caller that did not use lockArtifact first.
      await lockCollabArtifactAccountAuthority(db, input);
      const rooms = await db.execute(sql`
        SELECT id, lifecycle, generation FROM collab_rooms
         WHERE session_id = ${input.sessionId} AND owner_user_id = ${input.ownerUserId}
         LIMIT 1 FOR UPDATE`) as unknown as RoomAuthorityRow[];
      const room = rooms[0];
      if (room === undefined || room.lifecycle !== "active") return null;
      const members = await db.execute(sql`
        SELECT participant_id, role, status, generation FROM collab_members
         WHERE room_id = ${room.id} AND user_id = ${input.actorUserId}
         LIMIT 1 FOR UPDATE`) as unknown as MemberAuthorityRow[];
      const member = members[0];
      if (member === undefined || member.status !== "active") return null;
      const ownerMembers = await db.execute(sql`
        SELECT participant_id FROM collab_members
         WHERE room_id = ${room.id} AND user_id = ${input.ownerUserId}
           AND role = 'owner' AND status = 'active'
         LIMIT 1 FOR UPDATE`) as unknown as Array<{ participant_id: string }>;
      if (ownerMembers[0] === undefined) return null;
      const sessions = await db.execute(sql`
        SELECT deleted_at, updated_at FROM sessions
         WHERE id = ${input.sessionId} AND user_id = ${input.ownerUserId}
         LIMIT 1 FOR UPDATE`) as unknown as Array<{
        deleted_at: Date | string | null;
        updated_at: Date | string;
      }>;
      const session = sessions[0];
      if (session === undefined || session.deleted_at !== null) return null;
      // lockArtifact already holds the account lifecycle's exact UID advisory
      // locks (seed 714031). FOR UPDATE also protects existing rows, while the
      // advisory lock closes the initially-absent deletion-row race.
      const accountRows = await db.execute(sql`
        SELECT uid, state, updated_at FROM account_deletions
         WHERE uid IN (${input.ownerUserId}, ${input.actorUserId})
         ORDER BY uid FOR UPDATE`) as unknown as Array<{
        uid: string;
        state: string;
        updated_at: Date | string;
      }>;
      const accounts = new Map(accountRows.map((row) => [row.uid, row]));
      const account = (uid: string): CollabArtifactAccountAuthority | null => {
        const row = accounts.get(uid);
        if (row === undefined) return { state: null, updatedAt: null };
        if (row.state !== "active" && row.state !== "cancelled") return null;
        return {
          state: row.state,
          updatedAt: row.updated_at instanceof Date ? row.updated_at.toISOString() : String(row.updated_at),
        };
      };
      const ownerAccount = account(input.ownerUserId);
      const actorAccount = account(input.actorUserId);
      if (ownerAccount === null || actorAccount === null) return null;
      if (member.role === "owner") {
        if (input.actorUserId !== input.ownerUserId) return null;
      } else if (input.actorUserId === input.ownerUserId) return null;
      const roomGeneration = Number(room.generation);
      const membershipGeneration = Number(member.generation);
      if (!Number.isSafeInteger(roomGeneration) || roomGeneration < 1 ||
          !Number.isSafeInteger(membershipGeneration) || membershipGeneration < 1) {
        return null;
      }
      return {
        role: member.role === "owner" ? "owner" : "member",
        roomId: room.id,
        roomGeneration,
        membershipGeneration,
        sessionUpdatedAt: session.updated_at instanceof Date
          ? session.updated_at.toISOString()
          : String(session.updated_at),
        ownerAccount,
        actorAccount,
      };
    },
  };
}

export interface CollabArtifactReservationPort {
  reserve(input: StorageReservationInput): Promise<StorageReservationResult>;
  finalize(input: StorageFinalizeInput): Promise<StorageReservationResult>;
  release(input: { reservationId: string }): Promise<void>;
}

export interface CollabArtifactWorkspaceObjectsPort {
  getArtifact(db: Db, artifactId: string, userId: string): Promise<WorkspaceObjectRow | null>;
  registerArtifact(
    db: Db,
    input: {
      id: string;
      userId: string;
      sessionId: string;
      r2Key: string;
      bytes: number;
      sha256: string;
      contentType: string;
      meta: {
        name: string;
        creatorUserId: string;
        idempotencyKey: string;
        attempt: number;
        attemptReservationId: string;
      };
    },
  ): Promise<WorkspaceObjectRow>;
}

export interface CollabArtifactRegistrarDeps {
  db: Db;
  storage: Pick<StorageAdapter, "put" | "head" | "get" | "delete">;
  authorization: CollabArtifactAuthorizationPort;
  workspaceDir(ownerUserId: string, sessionId: string): Promise<string>;
  workspaceObjects?: CollabArtifactWorkspaceObjectsPort;
  reservationStore?(db: Db): CollabArtifactReservationPort;
  /** Production default issues SELECT pg_cancel_backend(pid) on another pooled connection. */
  cancelBackend?(backendPid: number): Promise<unknown>;
  /** One cumulative deadline for pool acquisition and all registrar DB work. */
  operationDeadlineMs?: number;
  /** All DB-critical sections are storage-I/O-free and bounded independently. */
  dbLockTimeoutMs?: number;
  dbStatementTimeoutMs?: number;
  /** Wait for an in-flight attempt before superseding it with a new generation. */
  pendingWaitMs?: number;
  /** Overall source/storage wait deadline, including orphan verification. */
  storageDeadlineMs?: number;
  cleanupDeadlineMs?: number;
}

interface ReservationView {
  id: string;
  actorUserId: string;
  ownerUserId: string;
  sessionId: string;
  objectId: string | null;
  state: "reserved" | "finalized" | "released";
  declaredBytes: number;
  actualBytes: number | null;
  actualContentType: string | null;
  etag: string | null;
}

interface PreparedContent {
  sizeBytes: number;
  sha256Hex: string;
  content: Buffer | null;
  source: FileHandle | null;
}

interface AttemptContext {
  artifactId: string;
  attempt: number;
  attemptReservationId: string;
  key: string;
}

class CommittedArtifact extends Error {
  constructor(readonly row: WorkspaceObjectRow) {
    super("artifact committed by a newer attempt");
  }
}

function required(value: unknown, field: string): void {
  if (typeof value !== "string" || value.trim() === "") {
    throw new CollabArtifactError("invalid_request", null, false, {
      cause: new RangeError(`${field} must be non-empty`),
    });
  }
}

function validateInput(input: CollabArtifactRegisterInput): void {
  required(input.actorUserId, "actorUserId");
  required(input.ownerUserId, "ownerUserId");
  required(input.sessionId, "sessionId");
  required(input.name, "name");
  try {
    assertSafeSegment(input.ownerUserId);
    assertSafeSegment(input.sessionId);
  } catch (error) {
    throw new CollabArtifactError("invalid_request", null, false, { cause: error });
  }
  if (typeof input.idempotencyKey !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(input.idempotencyKey)) {
    throw new CollabArtifactError("invalid_request");
  }
  const hasSource = input.sourcePath !== undefined;
  const hasContent = input.content !== undefined;
  if (hasSource === hasContent || (hasContent && !Buffer.isBuffer(input.content))) {
    throw new CollabArtifactError("invalid_request");
  }
  if (hasSource) required(input.sourcePath!, "sourcePath");
}

function canonicalContentType(input: CollabArtifactRegisterInput): string {
  if (input.contentType !== undefined && typeof input.contentType !== "string") {
    throw new CollabArtifactError("invalid_request");
  }
  const value = sanitizeCdnContentType(input.contentType ?? contentTypeFor(input.name));
  if (value === undefined) throw new CollabArtifactError("invalid_request");
  return value;
}

function artifactIdFor(input: CollabArtifactRegisterInput): string {
  const digest = createHash("sha256")
    .update("ovid-collab-artifact-v2", "utf8")
    .update(JSON.stringify([
      input.ownerUserId,
      input.sessionId,
      input.actorUserId,
      input.idempotencyKey,
    ]), "utf8")
    .digest();
  digest[6] = 0x80 | (digest[6]! & 0x0f);
  digest[8] = 0x80 | (digest[8]! & 0x3f);
  const hex = digest.toString("hex").slice(0, 32);
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function attemptReservationId(artifactId: string, attempt: number): string {
  return recoveryAttemptReservationId(artifactId, attempt);
}

function attemptKey(
  input: CollabArtifactRegisterInput,
  artifactId: string,
  attempt: number,
  sha256Hex: string,
): string {
  // Attempt generation is part of the key, not merely metadata. A late PUT from
  // an older worker therefore cannot overwrite the active attempt's bytes.
  return recoveryAttemptKey({
    ownerUserId: input.ownerUserId,
    sessionId: input.sessionId,
    artifactId,
    attempt,
    sha256Hex,
    name: input.name,
  });
}

function assertByteCount(value: number): void {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new CollabArtifactError("artifact_changed");
  }
}

async function hashSource(handle: FileHandle, deadline: CollabArtifactDeadline) {
  const hash = createHash("sha256");
  let sizeBytes = 0;
  const stream = handle.createReadStream({ autoClose: false, start: 0 });
  const destroy = () => stream.destroy();
  deadline.signal.addEventListener("abort", destroy, { once: true });
  if (deadline.signal.aborted) destroy();
  try {
    deadline.throwIfAborted();
    for await (const chunk of stream) {
      deadline.throwIfAborted();
      const bytes = chunk as Buffer;
      hash.update(bytes);
      sizeBytes += bytes.length;
      assertByteCount(sizeBytes);
    }
  } finally {
    deadline.signal.removeEventListener("abort", destroy);
    stream.destroy();
  }
  return { sizeBytes, sha256Hex: hash.digest("hex") };
}

function insideRoot(rootReal: string, candidateReal: string): boolean {
  return candidateReal === rootReal || candidateReal.startsWith(`${rootReal}${sep}`);
}

function confinementInput(root: string, sourcePath: string): string {
  if (!isAbsolute(sourcePath) || sourcePath === "/workspace" || sourcePath.startsWith("/workspace/")) {
    return sourcePath;
  }
  const rel = relative(resolve(root), resolve(sourcePath));
  if (rel === "" || rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    return sourcePath;
  }
  return rel.split(sep).join("/");
}

async function prepareContent(
  deps: CollabArtifactRegistrarDeps,
  input: CollabArtifactRegisterInput,
  deadline: CollabArtifactDeadline,
): Promise<PreparedContent> {
  if (input.content !== undefined) {
    return {
      sizeBytes: input.content.length,
      sha256Hex: createHash("sha256").update(input.content).digest("hex"),
      content: input.content,
      source: null,
    };
  }
  const root = await deadline.run(() => deps.workspaceDir(input.ownerUserId, input.sessionId));
  let candidate: string;
  try {
    candidate = await deadline.run(() => resolveConfined(root, confinementInput(root, input.sourcePath!)));
  } catch (error) {
    if (error instanceof ConfinementError) {
      throw new CollabArtifactError("source_outside_workspace", null, false, { cause: error });
    }
    throw error;
  }
  const rootReal = await deadline.run(() => realpath(root));
  const sourceReal = await deadline.run(() => realpath(candidate));
  if (!insideRoot(rootReal, sourceReal)) {
    throw new CollabArtifactError("source_outside_workspace");
  }
  const handle = await deadline.run(() => open(sourceReal, constants.O_RDONLY | constants.O_NOFOLLOW)
    .then(async (opened) => {
      if (deadline.signal.aborted) {
        await opened.close().catch(() => {});
        deadline.throwIfAborted();
      }
      return opened;
    }));
  try {
    const descriptorReal = await deadline.run(() => realpath(`/proc/self/fd/${handle.fd}`));
    if (!insideRoot(rootReal, descriptorReal)) {
      throw new CollabArtifactError("source_outside_workspace");
    }
    const stat = await deadline.run(() => handle.stat());
    if (!stat.isFile()) throw new CollabArtifactError("invalid_request");
    const hashed = await hashSource(handle, deadline);
    return { ...hashed, content: null, source: handle };
  } catch (error) {
    await handle.close().catch(() => {});
    throw error;
  }
}

function quotaFailure(result: Extract<StorageReservationResult, { ok: false }>): CollabArtifactError {
  return new CollabArtifactError(
    result.scope === "upload" ? "upload_limit_reached" : "storage_quota_exceeded",
    result.resetsAt,
    result.scope === "upload",
  );
}

function metadata(row: WorkspaceObjectRow): Record<string, unknown> {
  return row.meta !== null && typeof row.meta === "object" ? row.meta : {};
}

function rowAttempt(row: WorkspaceObjectRow, artifactId: string): number {
  const meta = metadata(row);
  const attempt = meta.attempt;
  if (typeof attempt !== "number" || !Number.isSafeInteger(attempt) || attempt < 1 ||
      meta.attemptReservationId !== attemptReservationId(artifactId, attempt)) {
    throw new CollabArtifactError("artifact_unavailable", null, true);
  }
  return attempt;
}

function rowGeneration(row: WorkspaceObjectRow, artifactId: string): {
  status: string;
  r2Key: string;
  attempt: number | null;
} {
  return {
    status: row.status,
    r2Key: row.r2Key,
    attempt: row.status === "active" || row.status === "pending"
      ? rowAttempt(row, artifactId)
      : null,
  };
}

function baseRowMatches(
  row: WorkspaceObjectRow,
  input: CollabArtifactRegisterInput,
  prepared: PreparedContent,
  contentType: string,
): boolean {
  const meta = metadata(row);
  return row.kind === "artifact" &&
    row.userId === input.ownerUserId &&
    row.sessionId === input.sessionId &&
    row.bytes === prepared.sizeBytes &&
    row.sha256 === prepared.sha256Hex &&
    row.contentType === contentType &&
    meta.name === input.name &&
    meta.creatorUserId === input.actorUserId &&
    meta.idempotencyKey === input.idempotencyKey;
}

function requireBaseRow(
  row: WorkspaceObjectRow,
  input: CollabArtifactRegisterInput,
  prepared: PreparedContent,
  contentType: string,
): void {
  if (!baseRowMatches(row, input, prepared, contentType)) {
    throw new CollabArtifactError("idempotency_conflict");
  }
}

function activeRowMatches(
  row: WorkspaceObjectRow,
  input: CollabArtifactRegisterInput,
  prepared: PreparedContent,
  contentType: string,
  artifactId: string,
): boolean {
  if (!baseRowMatches(row, input, prepared, contentType)) return false;
  const attempt = rowAttempt(row, artifactId);
  return row.r2Key === attemptKey(input, artifactId, attempt, prepared.sha256Hex);
}

function reservationActorMatches(
  reservation: ReservationView,
  input: CollabArtifactRegisterInput,
): boolean {
  return reservation.actorUserId === input.actorUserId &&
    reservation.ownerUserId === input.ownerUserId &&
    reservation.sessionId === input.sessionId;
}

function reservationMatches(
  reservation: ReservationView,
  input: CollabArtifactRegisterInput,
  objectId: string,
): boolean {
  return reservationActorMatches(reservation, input) && reservation.objectId === objectId;
}

function attemptReservationIdentityMatches(
  reservation: ReservationView,
  input: CollabArtifactRegisterInput,
): boolean {
  // Accounting release depends only on reservation identity. Object-key
  // validity is an independent physical-cleanup decision, never an idempotency
  // precondition for releasing a noncanonical/legacy reservation.
  return reservationActorMatches(reservation, input);
}

function toRecord(
  input: CollabArtifactRegisterInput,
  attempt: AttemptContext,
  head: HeadResult,
  sha256Hex: string,
): CollabArtifactRecord {
  return {
    id: attempt.artifactId,
    key: attempt.key,
    sizeBytes: head.bytes,
    sha256Hex,
    contentType: sanitizeCdnContentType(head.contentType ?? undefined)!,
    actorUserId: input.actorUserId,
    ownerUserId: input.ownerUserId,
    sessionId: input.sessionId,
  };
}

function sameAccount(a: CollabArtifactAccountAuthority, b: CollabArtifactAccountAuthority): boolean {
  return a.state === b.state && a.updatedAt === b.updatedAt;
}

function sameGrant(a: CollabArtifactAuthorization, b: CollabArtifactAuthorization): boolean {
  return a.roomId === b.roomId &&
    a.roomGeneration === b.roomGeneration &&
    a.membershipGeneration === b.membershipGeneration &&
    a.sessionUpdatedAt === b.sessionUpdatedAt &&
    sameAccount(a.ownerAccount, b.ownerAccount) &&
    sameAccount(a.actorAccount, b.actorAccount);
}

function timeoutMs(value: number | undefined, fallback: number, allowZero = false): number {
  const resolved = value ?? fallback;
  if (!Number.isSafeInteger(resolved) || resolved < (allowZero ? 0 : 1)) {
    throw new RangeError("invalid CollabArtifactRegistrar timeout");
  }
  return resolved;
}

export class CollabArtifactRegistrar {
  private readonly workspaceObjects: CollabArtifactWorkspaceObjectsPort;
  private readonly dbLockTimeoutMs: number;
  private readonly dbStatementTimeoutMs: number;
  private readonly pendingWaitMs: number;
  private readonly operationDeadlineMs: number;
  private readonly storageDeadlineMs: number;
  private readonly cleanupDeadlineMs: number;

  constructor(private readonly deps: CollabArtifactRegistrarDeps) {
    this.workspaceObjects = deps.workspaceObjects ?? {
      getArtifact: (db, artifactId, userId) => canonicalWorkspaceObjects.getArtifact(db, artifactId, userId),
      registerArtifact: (db, input) => canonicalWorkspaceObjects.registerArtifact(db, input),
    };
    this.dbLockTimeoutMs = timeoutMs(deps.dbLockTimeoutMs, 5_000);
    this.dbStatementTimeoutMs = timeoutMs(deps.dbStatementTimeoutMs, 10_000);
    this.pendingWaitMs = timeoutMs(deps.pendingWaitMs, 5_000, true);
    this.operationDeadlineMs = timeoutMs(deps.operationDeadlineMs, 60_000);
    this.storageDeadlineMs = timeoutMs(deps.storageDeadlineMs, 30_000);
    this.cleanupDeadlineMs = timeoutMs(deps.cleanupDeadlineMs, 5_000);
  }

  private reservations(db: Db): CollabArtifactReservationPort {
    return this.deps.reservationStore?.(db) ?? new StorageReservationStore(db);
  }

  /**
   * Every use is a short DB-only transaction. The operation deadline also
   * covers pool acquisition; pg_cancel_backend interrupts a started query,
   * while a late acquisition throws before its first statement or write.
   */
  private async transaction<T>(
    fn: (tx: Db) => Promise<T>,
    deadline: CollabArtifactDeadline,
  ): Promise<T> {
    let backendPid: number | null = null;
    const work = () => this.deps.db.transaction(async (transaction) => {
      deadline.throwIfAborted();
      const tx = transaction as unknown as Db;
      const pid = await tx.execute(sql`SELECT pg_backend_pid() AS pid`) as unknown as Array<{ pid: number }>;
      const parsedPid = Number(pid[0]?.pid);
      if (!Number.isSafeInteger(parsedPid) || parsedPid <= 0) {
        throw new CollabArtifactError("temporarily_unavailable", null, true);
      }
      backendPid = parsedPid;
      const remaining = deadline.remainingMs();
      if (remaining <= 0) deadline.throwIfAborted();
      const statement = Math.max(1, Math.min(this.dbStatementTimeoutMs, remaining));
      const lock = Math.max(1, Math.min(this.dbLockTimeoutMs, remaining));
      await tx.execute(sql`SET LOCAL lock_timeout = ${sql.raw(`'${lock}ms'`)}`);
      await tx.execute(sql`SET LOCAL statement_timeout = ${sql.raw(`'${statement}ms'`)}`);
      await tx.execute(sql`SET LOCAL idle_in_transaction_session_timeout = ${sql.raw(`'${statement}ms'`)}`);
      deadline.throwIfAborted();
      const result = await fn(tx);
      // If the operation aborted while callback work was in flight, never let
      // a late callback resolution commit its reservation/intent/publication.
      deadline.throwIfAborted();
      return result;
    });
    try {
      return await deadline.run(work);
    } catch (error) {
      const pid = backendPid;
      if (pid !== null && deadline.signal.aborted) {
        const cancellation = this.deps.cancelBackend !== undefined
          ? this.deps.cancelBackend(pid)
          : typeof this.deps.db.$client === "function"
            ? this.deps.db.$client`SELECT pg_cancel_backend(${pid})`
            : undefined;
        // Cancellation is bounded too; statement_timeout remains the backstop
        // if a saturated pool cannot supply the independent cancellation call.
        await Promise.race([
          Promise.resolve(cancellation).catch(() => {}),
          new Promise<void>((resolve) => {
            const timer = setTimeout(resolve, 100);
            timer.unref?.();
          }),
        ]);
      }
      throw error;
    }
  }

  private async lockArtifact(db: Db, artifactId: string, input: CollabArtifactIdentity): Promise<void> {
    // Same authority as withUidLock/account deletion, including absent rows.
    // UID -> artifact -> room/member/session is also the lifecycle-safe order:
    // deletion takes UID then Collab room locks, never the reverse.
    await lockCollabArtifactAccountAuthority(db, input);
    await db.execute(sql`
      SELECT pg_advisory_xact_lock(hashtextextended(${`ovid-collab-artifact:${input.ownerUserId}:${input.sessionId}:${artifactId}`}, 0))`);
  }

  private async authorize(
    db: Db,
    input: CollabArtifactIdentity,
    expected?: CollabArtifactAuthorization,
  ): Promise<CollabArtifactAuthorization> {
    const grant = await this.deps.authorization.authorize(input, db);
    if (grant === null) throw new CollabArtifactError("not_member");
    if (expected !== undefined && !sameGrant(expected, grant)) {
      throw new CollabArtifactError("membership_changed", null, true);
    }
    return grant;
  }

  private async row(
    db: Db,
    artifactId: string,
    ownerUserId: string,
    forUpdate: boolean,
  ): Promise<WorkspaceObjectRow | null> {
    if (!forUpdate) return this.workspaceObjects.getArtifact(db, artifactId, ownerUserId);
    const found = await db
      .select()
      .from(schema.workspaceObjects)
      .where(and(
        eq(schema.workspaceObjects.id, artifactId),
        eq(schema.workspaceObjects.userId, ownerUserId),
      ))
      .limit(1)
      .for("update");
    return found[0] ?? null;
  }

  private async reservation(
    db: Db,
    reservationId: string,
    forUpdate = false,
  ): Promise<ReservationView | null> {
    const locking = forUpdate ? sql` FOR UPDATE` : sql``;
    const found = await db.execute(sql`
      SELECT id, actor_user_id, owner_user_id, session_id, object_id, state,
             declared_bytes, actual_bytes, actual_content_type, etag
        FROM storage_reservations WHERE id = ${reservationId} LIMIT 1${locking}`) as unknown as Array<{
      id: string;
      actor_user_id: string;
      owner_user_id: string;
      session_id: string;
      object_id: string | null;
      state: ReservationView["state"];
      declared_bytes: number | string;
      actual_bytes: number | string | null;
      actual_content_type: string | null;
      etag: string | null;
    }>;
    const row = found[0];
    if (row === undefined) return null;
    return {
      id: row.id,
      actorUserId: row.actor_user_id,
      ownerUserId: row.owner_user_id,
      sessionId: row.session_id,
      objectId: row.object_id,
      state: row.state,
      declaredBytes: Number(row.declared_bytes),
      actualBytes: row.actual_bytes === null ? null : Number(row.actual_bytes),
      actualContentType: row.actual_content_type,
      etag: row.etag,
    };
  }

  private async attempts(
    db: Db,
    artifactId: string,
  ): Promise<{
    rows: Array<{ reservation: ReservationView; attempt: number }>;
    highestAttempt: number;
    reservedAttempts: number;
  }> {
    // One bounded query, no per-attempt reads. Window values cover the whole
    // history even though only the newest 64 candidates enter this page.
    // The artifact advisory lock serializes writers; canonical reservation
    // methods retain their own row locks for state transitions.
    const found = await db.execute(sql`
      SELECT id, actor_user_id, owner_user_id, session_id, object_id, state,
             declared_bytes, actual_bytes, actual_content_type, etag,
             max((regexp_replace(id, '^.*:collab-attempt:', ''))::numeric) OVER () AS highest_attempt,
             count(*) FILTER (WHERE state = 'reserved') OVER () AS reserved_attempts
        FROM storage_reservations
       WHERE id ~ ${`^${artifactId}:collab-attempt:[1-9][0-9]*$`}
       ORDER BY created_at DESC, id DESC
       LIMIT 64`) as unknown as Array<Record<string, unknown>>;
    const rows: Array<{ reservation: ReservationView; attempt: number }> = [];
    for (const raw of found) {
      const id = String(raw.id);
      const attempt = Number(id.slice(`${artifactId}:collab-attempt:`.length));
      const declaredBytes = Number(raw.declared_bytes);
      const actualBytes = raw.actual_bytes === null ? null : Number(raw.actual_bytes);
      if (!Number.isSafeInteger(attempt) || attempt < 1 ||
          !Number.isSafeInteger(declaredBytes) || declaredBytes < 0 ||
          (actualBytes !== null && (!Number.isSafeInteger(actualBytes) || actualBytes < 0))) {
        throw new CollabArtifactError("artifact_unavailable", null, true);
      }
      rows.push({
        attempt,
        reservation: {
          id,
          actorUserId: String(raw.actor_user_id),
          ownerUserId: String(raw.owner_user_id),
          sessionId: String(raw.session_id),
          objectId: raw.object_id === null ? null : String(raw.object_id),
          state: String(raw.state) as ReservationView["state"],
          declaredBytes,
          actualBytes,
          actualContentType: raw.actual_content_type === null ? null : String(raw.actual_content_type),
          etag: raw.etag === null ? null : String(raw.etag),
        },
      });
    }
    const highestAttempt = Number(found[0]?.highest_attempt ?? 0);
    const reservedAttempts = Number(found[0]?.reserved_attempts ?? 0);
    if (!Number.isSafeInteger(highestAttempt) || highestAttempt < 0 ||
        !Number.isSafeInteger(reservedAttempts) || reservedAttempts < 0) {
      throw new CollabArtifactError("artifact_unavailable", null, true);
    }
    return { rows, highestAttempt, reservedAttempts };
  }

  private async reservedAttemptsPage(
    db: Db,
    artifactId: string,
    limit = 64,
  ): Promise<Array<{ reservation: ReservationView; attempt: number }>> {
    const found = await db.execute(sql`
      SELECT id, actor_user_id, owner_user_id, session_id, object_id, state,
             declared_bytes, actual_bytes, actual_content_type, etag
        FROM storage_reservations
       WHERE state = 'reserved'
         AND id ~ ${`^${artifactId}:collab-attempt:[1-9][0-9]*$`}
       ORDER BY created_at, id
       LIMIT ${limit}`) as unknown as Array<Record<string, unknown>>;
    const rows: Array<{ reservation: ReservationView; attempt: number }> = [];
    for (const raw of found) {
      const id = String(raw.id);
      const attempt = Number(id.slice(`${artifactId}:collab-attempt:`.length));
      if (!Number.isSafeInteger(attempt) || attempt < 1) {
        throw new CollabArtifactError("artifact_unavailable", null, true);
      }
      const declaredBytes = Number(raw.declared_bytes);
      const actualBytes = raw.actual_bytes === null ? null : Number(raw.actual_bytes);
      if (!Number.isSafeInteger(declaredBytes) || declaredBytes < 0 ||
          (actualBytes !== null && (!Number.isSafeInteger(actualBytes) || actualBytes < 0))) {
        throw new CollabArtifactError("artifact_unavailable", null, true);
      }
      rows.push({
        reservation: {
          id,
          actorUserId: String(raw.actor_user_id),
          ownerUserId: String(raw.owner_user_id),
          sessionId: String(raw.session_id),
          objectId: raw.object_id === null ? null : String(raw.object_id),
          state: "reserved",
          declaredBytes,
          actualBytes,
          actualContentType: raw.actual_content_type === null ? null : String(raw.actual_content_type),
          etag: raw.etag === null ? null : String(raw.etag),
        },
        attempt,
      });
    }
    return rows;
  }

  /** Drain every older reserved generation before replay or another attempt. */
  private async drainReservedAttempts(
    input: CollabArtifactRegisterInput,
    artifactId: string,
    grant: CollabArtifactAuthorization,
    dbDeadline: CollabArtifactDeadline,
  ): Promise<void> {
    for (;;) {
      dbDeadline.throwIfAborted();
      const drained = await this.transaction(async (tx) => {
        await this.lockArtifact(tx, artifactId, input);
        await this.authorize(tx, input, grant);
        const rows = await this.reservedAttemptsPage(tx, artifactId);
        for (const { reservation } of rows) {
          // Legacy/noncanonical object ids are accounting-only here. Physical
          // cleanup later requires the exact immutable key independently.
          if (!attemptReservationIdentityMatches(reservation, input)) {
            throw new CollabArtifactError("idempotency_conflict");
          }
          await this.reservations(tx).release({ reservationId: reservation.id });
        }
        return rows.length;
      }, dbDeadline);
      if (drained === 0) return;
      // The advisory artifact lock is held across each DB-only page. Loop until
      // an empty page proves no reserved generation remains; the cumulative DB
      // deadline is the bounded retryable outcome for excessive/stalled history.
    }
  }

  private attemptContext(
    input: CollabArtifactRegisterInput,
    artifactId: string,
    attempt: number,
    prepared: PreparedContent,
  ): AttemptContext {
    return {
      artifactId,
      attempt,
      attemptReservationId: attemptReservationId(artifactId, attempt),
      key: attemptKey(input, artifactId, attempt, prepared.sha256Hex),
    };
  }

  private expectation(attempt: AttemptContext, prepared: PreparedContent, contentType: string) {
    return {
      sizeBytes: prepared.sizeBytes,
      sha256Hex: prepared.sha256Hex,
      contentType,
      artifactId: attempt.artifactId,
      attemptReservationId: attempt.attemptReservationId,
    } satisfies CollabArtifactObjectExpectation;
  }

  private async preflight(
    input: CollabArtifactRegisterInput,
    artifactId: string,
    dbDeadline: CollabArtifactDeadline,
  ): Promise<CollabArtifactAuthorization> {
    return this.transaction(async (tx) => {
      await this.lockArtifact(tx, artifactId, input);
      const grant = await this.authorize(tx, input);
      const existing = await this.row(tx, artifactId, input.ownerUserId, true);
      if (existing?.status === "deleted") throw new CollabArtifactError("artifact_deleted");
      return grant;
    }, dbDeadline);
  }

  private async beginOrReplay(
    input: CollabArtifactRegisterInput,
    artifactId: string,
    prepared: PreparedContent,
    contentType: string,
    grant: CollabArtifactAuthorization,
    deadline: CollabArtifactDeadline,
    dbDeadline: CollabArtifactDeadline,
  ): Promise<{ kind: "attempt"; attempt: AttemptContext } | { kind: "replay"; row: WorkspaceObjectRow }> {
    const waitUntil = Date.now() + this.pendingWaitMs;
    for (;;) {
      deadline.throwIfAborted();
      const result = await this.transaction(async (tx) => {
        await this.lockArtifact(tx, artifactId, input);
        await this.authorize(tx, input, grant);
        const existing = await this.row(tx, artifactId, input.ownerUserId, true);
        if (existing?.status === "deleted") throw new CollabArtifactError("artifact_deleted");
        if (existing !== null) requireBaseRow(existing, input, prepared, contentType);

        const attemptPage = await this.attempts(tx, artifactId);
        const attempts = attemptPage.rows;
        if (attemptPage.reservedAttempts > 0) {
          // This also runs for an active replay: older reserved attempts are
          // never abandoned behind a finalized public charge.
          if (Date.now() < waitUntil) return { kind: "wait" as const };
          return { kind: "drain" as const };
        }
        if (existing?.status === "active") {
          requireBaseRow(existing, input, prepared, contentType);
          if (!activeRowMatches(existing, input, prepared, contentType, artifactId)) {
            throw new CollabArtifactError("idempotency_conflict");
          }
          return { kind: "replay" as const, row: existing };
        }
        if (attempts.some(({ reservation }) => reservation.state === "finalized")) {
          // An attempt reservation is never the final public charge. This shape
          // is inconsistent and must not be repaired by inventing an active row.
          throw new CollabArtifactError("artifact_unavailable", null, true);
        }
        const reserved = attempts.filter(({ reservation }) => reservation.state === "reserved");
        if (reserved.length > 0) {
          throw new CollabArtifactError("artifact_in_progress", null, true);
        }
        const previous = existing === null ? 0 : rowAttempt(existing, artifactId);
        const highest = Math.max(previous, attemptPage.highestAttempt);
        const next = highest + 1;
        if (!Number.isSafeInteger(next)) throw new CollabArtifactError("temporarily_unavailable", null, true);
        const attempt = this.attemptContext(input, artifactId, next, prepared);
        const reservation = await this.reservations(tx).reserve({
          reservationId: attempt.attemptReservationId,
          ownerUserId: input.ownerUserId,
          uploaderUserId: input.actorUserId,
          sessionId: input.sessionId,
          objectId: attempt.key,
          declaredBytes: prepared.sizeBytes,
        });
        if (!reservation.ok) throw quotaFailure(reservation);

        const meta = {
          name: input.name,
          creatorUserId: input.actorUserId,
          idempotencyKey: input.idempotencyKey,
          attempt: next,
          attemptReservationId: attempt.attemptReservationId,
        };
        if (existing === null) {
          await this.workspaceObjects.registerArtifact(tx, {
            id: artifactId,
            userId: input.ownerUserId,
            sessionId: input.sessionId,
            r2Key: attempt.key,
            bytes: prepared.sizeBytes,
            sha256: prepared.sha256Hex,
            contentType,
            meta,
          });
          const pending = await tx
            .update(schema.workspaceObjects)
            .set({ status: "pending" })
            .where(and(
              eq(schema.workspaceObjects.id, artifactId),
              eq(schema.workspaceObjects.userId, input.ownerUserId),
              eq(schema.workspaceObjects.status, "active"),
            ))
            .returning({ id: schema.workspaceObjects.id });
          if (pending[0] === undefined) throw new CollabArtifactError("temporarily_unavailable", null, true);
        } else {
          const pending = await tx
            .update(schema.workspaceObjects)
            .set({ r2Key: attempt.key, meta, status: "pending" })
            .where(and(
              eq(schema.workspaceObjects.id, artifactId),
              eq(schema.workspaceObjects.userId, input.ownerUserId),
              eq(schema.workspaceObjects.status, "pending"),
            ))
            .returning({ id: schema.workspaceObjects.id });
          if (pending[0] === undefined) throw new CollabArtifactError("attempt_superseded", null, true);
        }
        return { kind: "attempt" as const, attempt };
      }, dbDeadline);
      if (result.kind === "drain") {
        await this.drainReservedAttempts(input, artifactId, grant, dbDeadline);
        // Re-read the row/highest generation only after an empty reserved page.
        continue;
      }
      if (result.kind !== "wait" && result.kind !== "drain") return result;
      await deadline.sleep(Math.min(
        25,
        Math.max(1, waitUntil - Date.now()),
        Math.max(1, dbDeadline.remainingMs()),
      ));
    }
  }

  private async requireAttemptCurrent(
    input: CollabArtifactRegisterInput,
    attempt: AttemptContext,
    prepared: PreparedContent,
    contentType: string,
    grant: CollabArtifactAuthorization,
    dbDeadline: CollabArtifactDeadline,
  ): Promise<void> {
    await this.transaction(async (tx) => {
      await this.lockArtifact(tx, attempt.artifactId, input);
      await this.authorize(tx, input, grant);
      const row = await this.row(tx, attempt.artifactId, input.ownerUserId, true);
      if (row?.status === "active") throw new CommittedArtifact(row);
      if (row === null || row.status !== "pending") {
        throw new CollabArtifactError("attempt_superseded", null, true);
      }
      requireBaseRow(row, input, prepared, contentType);
      if (rowAttempt(row, attempt.artifactId) !== attempt.attempt || row.r2Key !== attempt.key) {
        throw new CollabArtifactError("attempt_superseded", null, true);
      }
      const reservation = await this.reservation(tx, attempt.attemptReservationId, true);
      if (reservation === null || reservation.state !== "reserved" ||
          !reservationMatches(reservation, input, attempt.key) ||
          reservation.declaredBytes !== prepared.sizeBytes) {
        throw new CollabArtifactError("attempt_superseded", null, true);
      }
    }, dbDeadline);
  }

  private async replay(
    input: CollabArtifactRegisterInput,
    artifactId: string,
    prepared: PreparedContent,
    contentType: string,
    grant: CollabArtifactAuthorization,
    deadline: CollabArtifactDeadline,
    dbDeadline: CollabArtifactDeadline,
  ): Promise<CollabArtifactRecord> {
    const existing = await this.transaction(async (tx) => {
      await this.lockArtifact(tx, artifactId, input);
      await this.authorize(tx, input, grant);
      const row = await this.row(tx, artifactId, input.ownerUserId, true);
      if (row?.status === "deleted") throw new CollabArtifactError("artifact_deleted");
      if (row === null || row.status !== "active") {
        throw new CollabArtifactError("artifact_in_progress", null, true);
      }
      requireBaseRow(row, input, prepared, contentType);
      if (!activeRowMatches(row, input, prepared, contentType, artifactId)) {
        throw new CollabArtifactError("artifact_changed");
      }
      const reservation = await this.reservation(tx, artifactId, true);
      if (reservation === null || reservation.state !== "finalized" ||
          !reservationMatches(reservation, input, artifactId) ||
          reservation.actualBytes !== prepared.sizeBytes) {
        throw new CollabArtifactError("artifact_unavailable", null, true);
      }
      return row;
    }, dbDeadline);
    const attemptNumber = rowAttempt(existing, artifactId);
    const attempt: AttemptContext = {
      artifactId,
      attempt: attemptNumber,
      attemptReservationId: attemptReservationId(artifactId, attemptNumber),
      key: existing.r2Key,
    };
    // Replay independently rehashes the stored bytes; HEAD's caller-supplied
    // sha256 and a same-length mutation are not accepted as proof.
    const stored = await verifyCollabArtifactObject(
      this.deps.storage,
      attempt.key,
      this.expectation(attempt, prepared, contentType),
      deadline,
    );
    await this.transaction(async (tx) => {
      await this.lockArtifact(tx, artifactId, input);
      await this.authorize(tx, input, grant);
      const current = await this.row(tx, artifactId, input.ownerUserId, true);
      if (current?.status === "deleted") throw new CollabArtifactError("artifact_deleted");
      if (current === null || current.status !== "active" ||
          !activeRowMatches(current, input, prepared, contentType, artifactId)) {
        throw new CollabArtifactError("artifact_changed");
      }
      const reservation = await this.reservation(tx, artifactId, true);
      if (reservation === null || reservation.state !== "finalized" ||
          reservation.actualBytes !== stored.bytes ||
          reservation.actualContentType !== stored.contentType ||
          reservation.etag !== stored.etag) {
        throw new CollabArtifactError("artifact_changed");
      }
    }, dbDeadline);
    return toRecord(input, attempt, stored, prepared.sha256Hex);
  }

  private async putPrepared(
    prepared: PreparedContent,
    attempt: AttemptContext,
    contentType: string,
    deadline: CollabArtifactDeadline,
  ): Promise<void> {
    const options = {
      contentType,
      sha256Hex: prepared.sha256Hex,
      metadata: {
        "ovid-collab-artifact": attempt.artifactId,
        "ovid-collab-attempt": attempt.attemptReservationId,
      },
    };
    if (prepared.content !== null) {
      const put = await deadline.run(() => this.deps.storage.put(attempt.key, prepared.content!, options));
      if (put.bytes !== prepared.sizeBytes) throw new CollabArtifactError("artifact_changed");
      return;
    }
    const uploadedHash = createHash("sha256");
    let uploadedBytes = 0;
    const source = prepared.source!.createReadStream({ autoClose: false, start: 0 });
    const meter = new Transform({
      transform(chunk: Buffer, _encoding, callback) {
        uploadedHash.update(chunk);
        uploadedBytes += chunk.length;
        callback(null, chunk);
      },
    });
    source.on("error", (error) => meter.destroy(error));
    const destroy = () => {
      source.destroy();
      meter.destroy();
    };
    deadline.signal.addEventListener("abort", destroy, { once: true });
    if (deadline.signal.aborted) destroy();
    try {
      deadline.throwIfAborted();
      const put = await deadline.run(
        () => this.deps.storage.put(attempt.key, source.pipe(meter), options),
        destroy,
      );
      if (put.bytes !== prepared.sizeBytes || uploadedBytes !== prepared.sizeBytes ||
          uploadedHash.digest("hex") !== prepared.sha256Hex) {
        throw new CollabArtifactError("artifact_changed");
      }
    } finally {
      deadline.signal.removeEventListener("abort", destroy);
      destroy();
    }
  }

  private async publish(
    input: CollabArtifactRegisterInput,
    attempt: AttemptContext,
    prepared: PreparedContent,
    contentType: string,
    grant: CollabArtifactAuthorization,
    stored: HeadResult,
    dbDeadline: CollabArtifactDeadline,
  ): Promise<CollabArtifactRecord> {
    return this.transaction(async (tx) => {
      await this.lockArtifact(tx, attempt.artifactId, input);
      // This lock/read and all subsequent mutations are in one DB-only
      // transaction. No HEAD/GET/PUT intervenes after this generation check.
      await this.authorize(tx, input, grant);
      const row = await this.row(tx, attempt.artifactId, input.ownerUserId, true);
      if (row?.status === "active") throw new CommittedArtifact(row);
      if (row === null || row.status !== "pending") {
        throw new CollabArtifactError("attempt_superseded", null, true);
      }
      requireBaseRow(row, input, prepared, contentType);
      if (rowAttempt(row, attempt.artifactId) !== attempt.attempt || row.r2Key !== attempt.key) {
        throw new CollabArtifactError("attempt_superseded", null, true);
      }
      const pending = await this.reservation(tx, attempt.attemptReservationId, true);
      if (pending === null || pending.state !== "reserved" ||
          !reservationMatches(pending, input, attempt.key) ||
          pending.declaredBytes !== prepared.sizeBytes) {
        throw new CollabArtifactError("attempt_superseded", null, true);
      }
      if (row.projectId !== null) {
        await lockProjectFiles(tx, input.ownerUserId, row.projectId);
        await assertProjectFileCapacity(tx, input.ownerUserId, row.projectId, 1);
      }

      // The public reservation keeps the canonical artifact id (the gateway's
      // creator join depends on it). The attempt reservation was the durable
      // pre-write intent; conversion is atomic and charges actual bytes once.
      await this.reservations(tx).release({ reservationId: attempt.attemptReservationId });
      const reservation = await this.reservations(tx).reserve({
        reservationId: attempt.artifactId,
        ownerUserId: input.ownerUserId,
        uploaderUserId: input.actorUserId,
        sessionId: input.sessionId,
        objectId: attempt.artifactId,
        declaredBytes: stored.bytes,
      });
      if (!reservation.ok) throw quotaFailure(reservation);
      const settled = await this.reservations(tx).finalize({
        reservationId: attempt.artifactId,
        actualBytes: stored.bytes,
        contentType: stored.contentType ?? null,
        etag: stored.etag,
      });
      if (!settled.ok) throw quotaFailure(settled);
      const active = await tx
        .update(schema.workspaceObjects)
        .set({ status: "active" })
        .where(and(
          eq(schema.workspaceObjects.id, attempt.artifactId),
          eq(schema.workspaceObjects.userId, input.ownerUserId),
          eq(schema.workspaceObjects.status, "pending"),
          eq(schema.workspaceObjects.r2Key, attempt.key),
          sql`${schema.workspaceObjects.meta}->>'attemptReservationId' = ${attempt.attemptReservationId}`,
        ))
        .returning({ id: schema.workspaceObjects.id });
      if (active[0] === undefined) throw new CollabArtifactError("attempt_superseded", null, true);
      return toRecord(input, attempt, stored, prepared.sha256Hex);
    }, dbDeadline);
  }

  private async abandon(
    attempt: AttemptContext,
    input: CollabArtifactIdentity,
    dbDeadline: CollabArtifactDeadline,
  ): Promise<void> {
    // Accounting-only release is intentionally not member-gated: an uncommitted
    // charge must still be released after close/revoke/deletion. Physical object
    // cleanup below is separately full-grant fenced. A fresh short transaction
    // proves the current reservation state before any object cleanup is considered.
    await this.transaction(async (tx) => {
      await this.lockArtifact(tx, attempt.artifactId, input);
      const reservation = await this.reservation(tx, attempt.attemptReservationId, true);
      if (reservation?.state === "reserved") {
        await this.reservations(tx).release({ reservationId: attempt.attemptReservationId });
      }
    }, dbDeadline);
  }

  private async cleanupReleasedAttempts(
    input: CollabArtifactRegisterInput,
    artifactId: string,
    prepared: PreparedContent,
    grant: CollabArtifactAuthorization,
    dbDeadline: CollabArtifactDeadline,
  ): Promise<void> {
    const deadline = new CollabArtifactDeadline(this.cleanupDeadlineMs, dbDeadline.signal);
    try {
      const snapshot = await this.transaction(async (tx) => {
        await this.lockArtifact(tx, artifactId, input);
        await this.authorize(tx, input, grant);
        const row = await this.row(tx, artifactId, input.ownerUserId, true);
        const attempts = await this.attempts(tx, artifactId);
        return {
          current: row === null ? null : rowGeneration(row, artifactId),
          released: attempts.rows.filter(({ reservation }) => reservation.state === "released"),
        };
      }, dbDeadline);
      for (const { reservation, attempt } of snapshot.released) {
        deadline.throwIfAborted();
        const expectedKey = attemptKey(input, artifactId, attempt, prepared.sha256Hex);
        // Legacy null/artifactId/mismatched object ids are accounting-only.
        // Never derive a key from them or issue a guessed HEAD/DELETE.
        if (reservation.objectId !== expectedKey) continue;
        const key = expectedKey;
        const candidate = {
          id: artifactId,
          attemptReservationId: reservation.id,
          key,
          attempt,
        };
        if (!collabArtifactAttemptMayDelete({
          reservationState: reservation.state,
          reservationObjectId: reservation.objectId,
          candidateKey: key,
          candidateAttempt: attempt,
          current: snapshot.current,
        })) continue;
        const head = await deadline.run(() => this.deps.storage.head(key));
        if (classifyCollabArtifactAttemptHead(head, candidate) !== "owned") {
          continue; // Unknown/mismatched bytes are never deleted or adopted.
        }
        // Re-read authority, current generation and reservation immediately
        // before the destructive operation. A released attempt cannot publish.
        const mayDelete = await this.transaction(async (tx) => {
          await this.lockArtifact(tx, artifactId, input);
          await this.authorize(tx, input, grant);
          const currentRow = await this.row(tx, artifactId, input.ownerUserId, true);
          const current = await this.reservation(tx, reservation.id, true);
          return collabArtifactAttemptMayDelete({
            reservationState: current?.state ?? null,
            reservationObjectId: current?.objectId ?? null,
            candidateKey: key,
            candidateAttempt: attempt,
            current: currentRow === null ? null : rowGeneration(currentRow, artifactId),
          });
        }, dbDeadline);
        // The DB lock is intentionally released before DELETE. It is safe:
        // this immutable attempt key can never become a newer active key after
        // its reservation is released; lifecycle changes cannot reuse it.
        if (mayDelete) await deadline.run(() => this.deps.storage.delete(key));
      }
    } finally {
      deadline.close();
    }
  }

  async register(original: CollabArtifactRegisterInput): Promise<CollabArtifactRecord> {
    if (original === null || typeof original !== "object") {
      throw new CollabArtifactError("invalid_request");
    }
    validateInput(original);
    // Snapshot caller-owned bytes before the first await.
    const input = original.content === undefined
      ? original
      : { ...original, content: Buffer.from(original.content) };
    const contentType = canonicalContentType(input);
    const artifactId = artifactIdFor(input);
    const deadline = new CollabArtifactDeadline(this.storageDeadlineMs, input.signal);
    const dbDeadline = new CollabArtifactDeadline(
      this.operationDeadlineMs,
      input.signal,
      Date.now,
      "db_timeout",
    );
    let prepared: PreparedContent | null = null;
    let attempt: AttemptContext | null = null;
    try {
      deadline.throwIfAborted();
      dbDeadline.throwIfAborted();
      // Authorization precedes even source reads. Later short transactions
      // compare the same generations before reservation, PUT and DB publication.
      const grant = await this.preflight(input, artifactId, dbDeadline);
      deadline.throwIfAborted();
      prepared = await prepareContent(this.deps, input, deadline);
      try {
        const started = await this.beginOrReplay(input, artifactId, prepared, contentType, grant, deadline, dbDeadline);
        if (started.kind === "replay") {
          const replayed = await this.replay(input, artifactId, prepared, contentType, grant, deadline, dbDeadline);
          await this.cleanupReleasedAttempts(input, artifactId, prepared, grant, dbDeadline).catch(() => {});
          return replayed;
        }
        attempt = started.attempt;

        // Never adopt a pre-existing object from caller-supplied HEAD metadata.
        // A new generation uses a new key; collision means stop, not overwrite.
        const collision = await deadline.run(() => this.deps.storage.head(attempt!.key));
        if (collision !== null) throw new CollabArtifactError("artifact_changed");
        // No unchecked HEAD/hash I/O follows this revalidation before the PUT.
        await this.requireAttemptCurrent(input, attempt, prepared, contentType, grant, dbDeadline);
        deadline.throwIfAborted();
        dbDeadline.throwIfAborted();
        await this.putPrepared(prepared, attempt, contentType, deadline);
        const stored = await verifyCollabArtifactObject(
          this.deps.storage,
          attempt.key,
          this.expectation(attempt, prepared, contentType),
          deadline,
        );
        deadline.throwIfAborted();
        dbDeadline.throwIfAborted();
        const record = await this.publish(input, attempt, prepared, contentType, grant, stored, dbDeadline);
        await this.cleanupReleasedAttempts(input, artifactId, prepared, grant, dbDeadline).catch(() => {});
        return record;
      } catch (error) {
        if (attempt !== null) {
          await this.abandon(attempt, input, dbDeadline).catch(() => {});
          await this.cleanupReleasedAttempts(input, artifactId, prepared!, grant, dbDeadline).catch(() => {});
        }
        if (error instanceof CommittedArtifact) {
          return await this.replay(input, artifactId, prepared, contentType, grant, deadline, dbDeadline);
        }
        throw asCollabArtifactError(error);
      }
    } catch (error) {
      throw asCollabArtifactError(error);
    } finally {
      if (prepared?.source != null) await prepared.source.close().catch(() => {});
      dbDeadline.close();
      deadline.close();
    }
  }
}
