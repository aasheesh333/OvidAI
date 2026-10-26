import { createHash } from "node:crypto";
import type { Readable } from "node:stream";
import { sql } from "drizzle-orm";
import type { Db } from "./client.js";
import { StorageReservationStore } from "./quotaService.js";
import {
  assertSafeRelPath,
  r2Keys,
  sanitizeCdnContentType,
  type HeadResult,
  type StorageAdapter,
} from "@ovid/storage";

/** Small, dependency-light storage/deadline recovery primitives for CollabArtifactRegistrar. */
export class CollabArtifactStorageError extends Error {
  constructor(
    readonly code:
      | "storage_timeout"
      | "db_timeout"
      | "cancelled"
      | "artifact_unavailable"
      | "artifact_changed"
      | "storage_unavailable",
    options?: ErrorOptions,
  ) {
    super(code, options);
    this.name = "CollabArtifactStorageError";
  }
}

export class CollabArtifactDeadline {
  private readonly controller = new AbortController();
  private readonly timer: NodeJS.Timeout;
  private readonly parentAbort: () => void;
  private readonly parentSignal?: AbortSignal;
  private readonly createdAt: number;

  constructor(
    private readonly totalMs: number,
    parentSignal?: AbortSignal,
    private readonly now: () => number = Date.now,
    private readonly timeoutCode: "storage_timeout" | "db_timeout" = "storage_timeout",
  ) {
    if (!Number.isSafeInteger(totalMs) || totalMs < 1) throw new RangeError("invalid storage deadline");
    this.createdAt = this.now();
    this.parentSignal = parentSignal;
    this.parentAbort = () => this.controller.abort(new CollabArtifactStorageError("cancelled"));
    if (parentSignal?.aborted === true) this.parentAbort();
    else parentSignal?.addEventListener("abort", this.parentAbort, { once: true });
    this.timer = setTimeout(() => {
      this.controller.abort(new CollabArtifactStorageError(this.timeoutCode));
    }, totalMs);
    this.timer.unref?.();
  }

  get signal(): AbortSignal {
    return this.controller.signal;
  }

  private reason(): CollabArtifactStorageError {
    const reason = this.controller.signal.reason as unknown;
    return reason instanceof CollabArtifactStorageError
      ? reason
      : new CollabArtifactStorageError("cancelled");
  }

  throwIfAborted(): void {
    if (this.controller.signal.aborted) throw this.reason();
    // Timer callbacks can be delayed by a stalled event loop; elapsed time is
    // authoritative even when that callback has not run yet.
    if (this.remainingMs() <= 0) {
      this.controller.abort(new CollabArtifactStorageError(this.timeoutCode));
      throw this.reason();
    }
  }

  remainingMs(): number {
    return Math.max(0, this.totalMs - (this.now() - this.createdAt));
  }

  async run<T>(operation: () => Promise<T>, onAbort?: () => void): Promise<T> {
    this.throwIfAborted();
    let rejectAborted!: (reason: CollabArtifactStorageError) => void;
    const aborted = new Promise<never>((_resolve, reject) => {
      rejectAborted = reject;
    });
    void aborted.catch(() => {});
    let didAbort = false;
    const abort = () => {
      if (didAbort) return;
      didAbort = true;
      try {
        onAbort?.();
      } finally {
        rejectAborted(this.reason());
      }
    };
    this.controller.signal.addEventListener("abort", abort, { once: true });
    if (this.controller.signal.aborted) abort();
    try {
      if (this.controller.signal.aborted) return await aborted;
      const pending = operation();
      // An abort can win the race while the operation is still in flight; a
      // late rejection must be observed, never surface as unhandled.
      void pending.catch(() => {});
      const result = await Promise.race([pending, aborted]);
      this.throwIfAborted();
      return result;
    } catch (error) {
      if (this.controller.signal.aborted) throw this.reason();
      throw error;
    } finally {
      this.controller.signal.removeEventListener("abort", abort);
    }
  }

  async sleep(ms: number): Promise<void> {
    this.throwIfAborted();
    const bounded = Math.max(0, Math.min(Math.floor(ms), this.remainingMs()));
    await this.run(() => new Promise<void>((resolve) => {
      const timer = setTimeout(resolve, bounded);
      timer.unref?.();
    }));
  }

  close(): void {
    clearTimeout(this.timer);
    this.parentSignal?.removeEventListener("abort", this.parentAbort);
  }
}

export interface CollabArtifactObjectExpectation {
  sizeBytes: number;
  sha256Hex: string;
  contentType: string;
  artifactId: string;
  attemptReservationId: string;
}

export function requireCollabArtifactHead(
  head: HeadResult | null,
  expected: CollabArtifactObjectExpectation,
): HeadResult {
  if (head === null) throw new CollabArtifactStorageError("artifact_unavailable");
  if (!Number.isSafeInteger(head.bytes) || head.bytes < 0) {
    throw new CollabArtifactStorageError("artifact_changed");
  }
  const storedType = sanitizeCdnContentType(head.contentType ?? undefined);
  if (head.bytes !== expected.sizeBytes ||
      head.sha256Hex?.toLowerCase() !== expected.sha256Hex ||
      storedType !== expected.contentType ||
      head.metadata["ovid-collab-artifact"] !== expected.artifactId ||
      head.metadata["ovid-collab-attempt"] !== expected.attemptReservationId) {
    throw new CollabArtifactStorageError("artifact_changed");
  }
  return head;
}

function sameVersion(a: HeadResult, b: HeadResult): boolean {
  return a.bytes === b.bytes &&
    a.sha256Hex?.toLowerCase() === b.sha256Hex?.toLowerCase() &&
    sanitizeCdnContentType(a.contentType ?? undefined) ===
      sanitizeCdnContentType(b.contentType ?? undefined) &&
    a.etag === b.etag &&
    a.metadata["ovid-collab-artifact"] === b.metadata["ovid-collab-artifact"] &&
    a.metadata["ovid-collab-attempt"] === b.metadata["ovid-collab-attempt"];
}

/**
 * HEAD metadata is not content proof: R2's sha256 is caller-supplied metadata.
 * Hash the actual stored stream and bracket it with identical HEAD versions.
 */
export async function verifyCollabArtifactObject(
  storage: Pick<StorageAdapter, "head" | "get">,
  key: string,
  expected: CollabArtifactObjectExpectation,
  deadline: CollabArtifactDeadline,
): Promise<HeadResult> {
  const before = requireCollabArtifactHead(
    await deadline.run(() => storage.head(key)),
    expected,
  );
  const opened = await deadline.run(() => storage.get(key));
  if (opened === null) throw new CollabArtifactStorageError("artifact_unavailable");
  // Every adapter returns a Node stream; destroy() is the deadline seam.
  const stream = opened as Readable;
  const hash = createHash("sha256");
  let sizeBytes = 0;
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
      if (!Number.isSafeInteger(sizeBytes)) {
        throw new CollabArtifactStorageError("artifact_changed");
      }
    }
  } catch (error) {
    deadline.throwIfAborted();
    throw error;
  } finally {
    deadline.signal.removeEventListener("abort", destroy);
    stream.destroy();
  }
  if (sizeBytes !== expected.sizeBytes || hash.digest("hex") !== expected.sha256Hex) {
    throw new CollabArtifactStorageError("artifact_changed");
  }
  const after = requireCollabArtifactHead(
    await deadline.run(() => storage.head(key)),
    expected,
  );
  if (!sameVersion(before, after)) throw new CollabArtifactStorageError("artifact_changed");
  return after;
}

// ---------------------------------------------------------------------------
// Canonical generated-artifact attempt discovery/fencing. The Collab object
// owner's existing scheduled sweeper consumes these primitives; the registrar
// deliberately does not start a second timer or maintain a second candidate set.
// ---------------------------------------------------------------------------

export const COLLAB_ARTIFACT_ATTEMPT_MARKER = ":collab-attempt:";
export const COLLAB_ARTIFACT_ATTEMPT_METADATA = "ovid-collab-attempt";
export const COLLAB_ARTIFACT_ID_METADATA = "ovid-collab-artifact";
const ATTEMPT_ID_RE = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}):collab-attempt:([1-9][0-9]*)$/i;

export interface CollabArtifactAttemptOrphanCandidate {
  kind: "artifact_attempt";
  /** Canonical artifact id, not the attempt reservation id. */
  id: string;
  sessionId: string;
  ownerUid: string;
  /** Present from canonical reservation discovery; older ports may omit it. */
  actorUid?: string;
  key: string;
  attempt: number;
  attemptReservationId: string;
  declaredBytes: number;
  createdAt: Date;
}

export interface CollabArtifactAttemptCursor {
  createdAt: Date;
  attemptReservationId: string;
}

export function collabArtifactAttemptReservationId(artifactId: string, attempt: number): string {
  if (!Number.isSafeInteger(attempt) || attempt < 1) throw new RangeError("invalid artifact attempt");
  return `${artifactId}${COLLAB_ARTIFACT_ATTEMPT_MARKER}${attempt}`;
}

export function collabArtifactAttemptKey(input: {
  ownerUserId: string;
  sessionId: string;
  artifactId: string;
  attempt: number;
  sha256Hex: string;
  name: string;
}): string {
  if (!Number.isSafeInteger(input.attempt) || input.attempt < 1) {
    throw new RangeError("invalid artifact attempt");
  }
  return assertSafeRelPath(r2Keys.contentAddressedArtifact(
    input.ownerUserId,
    input.sessionId,
    `${input.artifactId}-attempt-${input.attempt}`,
    input.sha256Hex,
    input.name,
  ));
}

export function parseCollabArtifactAttemptReservationId(value: string): {
  artifactId: string;
  attempt: number;
} | null {
  const match = ATTEMPT_ID_RE.exec(value);
  if (match === null) return null;
  const attempt = Number(match[2]);
  if (!Number.isSafeInteger(attempt) || attempt < 1) return null;
  return { artifactId: match[1]!.toLowerCase(), attempt };
}

/**
 * Pure active-generation fence for every physical attempt cleanup. An active
 * row at the same generation/key is never collectible. A pending row whose
 * attempt reservation is already released is safe: publication requires the
 * reservation to be reserved, so that pending intent cannot later activate.
 * Deleted rows at the exact key are left to their canonical lifecycle path.
 */
export function collabArtifactAttemptMayDelete(input: {
  reservationState: "reserved" | "finalized" | "released" | null;
  reservationObjectId: string | null;
  candidateKey: string;
  candidateAttempt: number;
  current: {
    status: string;
    r2Key: string;
    attempt: number | null;
  } | null;
}): boolean {
  if (!Number.isSafeInteger(input.candidateAttempt) || input.candidateAttempt < 1) return false;
  if (input.reservationState !== "released" || input.reservationObjectId !== input.candidateKey) {
    return false;
  }
  if (input.current === null) return true;
  if (input.current.status !== "active" && input.current.status !== "pending" &&
      input.current.status !== "deleted") return false;
  if ((input.current.status === "active" || input.current.status === "pending") &&
      input.current.attempt === null) return false;
  if (input.current.status === "active" &&
      (input.current.r2Key === input.candidateKey || input.current.attempt === input.candidateAttempt)) {
    return false;
  }
  if (input.current.status === "deleted" && input.current.r2Key === input.candidateKey) return false;
  if (input.current.status === "pending" && input.current.r2Key === input.candidateKey &&
      input.current.attempt !== input.candidateAttempt) return false;
  return true;
}

export function classifyCollabArtifactAttemptHead(
  head: HeadResult | null,
  candidate: Pick<CollabArtifactAttemptOrphanCandidate, "id" | "attemptReservationId">,
): "missing" | "owned" | "foreign" {
  if (head === null) return "missing";
  return head.metadata[COLLAB_ARTIFACT_ID_METADATA] === candidate.id &&
    head.metadata[COLLAB_ARTIFACT_ATTEMPT_METADATA] === candidate.attemptReservationId
    ? "owned"
    : "foreign";
}

/**
 * Bounded released-attempt discovery. New reservations persist object_id as
 * the actual immutable key, so older attempt keys remain discoverable after
 * the canonical row advances. No key is guessed from the current row.
 */
export async function listCollabArtifactAttemptOrphanCandidates(
  db: Db,
  input: { limit?: number; before?: CollabArtifactAttemptCursor; deadline?: CollabArtifactDeadline } = {},
): Promise<{
  rows: CollabArtifactAttemptOrphanCandidate[];
  /** Emitted by the real helper; optional for legacy injected discovery ports. */
  quarantined?: number;
  nextCursor: CollabArtifactAttemptCursor | null;
}> {
  const limit = input.limit ?? 50;
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
    throw new RangeError("artifact attempt orphan limit must be 1..100");
  }
  const before = input.before;
  if (before !== undefined && (!Number.isFinite(before.createdAt.getTime()) ||
      parseCollabArtifactAttemptReservationId(before.attemptReservationId) === null)) {
    throw new RangeError("invalid artifact attempt orphan cursor");
  }
  // Bind the cursor instant as an ISO string: drizzle installs identity
  // serializers on postgres-js, so a raw Date parameter is not encodable and
  // every continuation page would throw instead of paging.
  const beforeAt = before === undefined ? null : before.createdAt.toISOString();
  const query = () => db.execute(sql`
    SELECT id, actor_user_id, owner_user_id, session_id, object_id,
           declared_bytes, created_at
      FROM storage_reservations
     WHERE state = 'released'
       AND id ~ '^[0-9a-fA-F-]{36}:collab-attempt:[1-9][0-9]*$'
       AND object_id LIKE 'users/%/artifacts/%'
       AND (${beforeAt}::timestamptz IS NULL OR
            (created_at, id) > (${beforeAt}::timestamptz,
                                ${before?.attemptReservationId ?? null}::text))
     ORDER BY created_at, id
     LIMIT ${limit + 1}`);
  const found = await (input.deadline === undefined
    ? query()
    : runCollabArtifactRecoveryTransaction({
      db,
      deadline: input.deadline,
      fn: () => query(),
    })) as unknown as Array<{
    id: string;
    actor_user_id: string;
    owner_user_id: string;
    session_id: string;
    object_id: string;
    declared_bytes: number | string;
    created_at: Date | string;
  }>;
  const scanned = found.slice(0, limit);
  const rows: CollabArtifactAttemptOrphanCandidate[] = [];
  let quarantined = 0;
  for (const row of scanned) {
    const parsed = parseCollabArtifactAttemptReservationId(row.id);
    const declaredBytes = Number(row.declared_bytes);
    const createdAt = row.created_at instanceof Date ? row.created_at : new Date(row.created_at);
    if (parsed === null || !Number.isSafeInteger(declaredBytes) || declaredBytes < 0 ||
        !Number.isFinite(createdAt.getTime())) {
      throw new RangeError("invalid artifact attempt orphan row");
    }
    let key: string;
    try {
      key = assertSafeRelPath(row.object_id);
      if (key !== row.object_id) {
        quarantined += 1;
        continue;
      }
    } catch {
      // A malformed key is an accounting-only quarantine, never a page-level
      // failure or a guessed storage operation. Advance from the raw row below.
      quarantined += 1;
      continue;
    }
    rows.push({
      kind: "artifact_attempt",
      id: parsed.artifactId,
      sessionId: row.session_id,
      ownerUid: row.owner_user_id,
      actorUid: row.actor_user_id,
      key,
      attempt: parsed.attempt,
      attemptReservationId: row.id,
      declaredBytes,
      createdAt,
    });
  }
  const last = scanned.at(-1);
  const lastCreatedAt = last === undefined
    ? null
    : last.created_at instanceof Date ? last.created_at : new Date(last.created_at);
  if (lastCreatedAt !== null && !Number.isFinite(lastCreatedAt.getTime())) {
    throw new RangeError("invalid artifact attempt orphan cursor");
  }
  return {
    rows,
    quarantined,
    nextCursor: found.length > limit && last !== undefined && lastCreatedAt !== null
      ? { createdAt: lastCreatedAt, attemptReservationId: last.id }
      : null,
  };
}

/** DB-only recovery transaction with cumulative acquisition/query cancellation. */
export async function runCollabArtifactRecoveryTransaction<T>(input: {
  db: Db;
  deadline: CollabArtifactDeadline;
  fn(tx: Db): Promise<T>;
  lockTimeoutMs?: number;
  statementTimeoutMs?: number;
  cancelBackend?(backendPid: number): Promise<unknown>;
}): Promise<T> {
  let backendPid: number | null = null;
  const work = () => input.db.transaction(async (transaction) => {
    input.deadline.throwIfAborted();
    const tx = transaction as unknown as Db;
    const pid = await tx.execute(sql`SELECT pg_backend_pid() AS pid`) as unknown as Array<{ pid: number }>;
    const parsed = Number(pid[0]?.pid);
    if (!Number.isSafeInteger(parsed) || parsed <= 0) {
      throw new CollabArtifactStorageError("storage_unavailable");
    }
    backendPid = parsed;
    const remaining = input.deadline.remainingMs();
    if (remaining <= 0) input.deadline.throwIfAborted();
    const lock = Math.max(1, Math.min(input.lockTimeoutMs ?? 5_000, remaining));
    const statement = Math.max(1, Math.min(input.statementTimeoutMs ?? 10_000, remaining));
    await tx.execute(sql`SET LOCAL lock_timeout = ${sql.raw(`'${lock}ms'`)}`);
    await tx.execute(sql`SET LOCAL statement_timeout = ${sql.raw(`'${statement}ms'`)}`);
    await tx.execute(sql`SET LOCAL idle_in_transaction_session_timeout = ${sql.raw(`'${statement}ms'`)}`);
    input.deadline.throwIfAborted();
    const result = await input.fn(tx);
    input.deadline.throwIfAborted();
    return result;
  });
  try {
    return await input.deadline.run(work);
  } catch (error) {
    const pid = backendPid;
    if (pid !== null && input.deadline.signal.aborted) {
      const cancellation = input.cancelBackend !== undefined
        ? input.cancelBackend(pid)
        : typeof input.db.$client === "function"
          ? input.db.$client`SELECT pg_cancel_backend(${pid})`
          : undefined;
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

export interface CollabArtifactRecoveryAuthority {
  ownerUserId: string;
  actorUserId: string;
  sessionId: string;
  artifactId: string;
}

/** Same UID/advisory identities as publication; this function performs no I/O. */
export async function lockCollabArtifactRecoveryAuthority(
  db: Db,
  input: CollabArtifactRecoveryAuthority,
): Promise<void> {
  for (const uid of [...new Set([input.ownerUserId, input.actorUserId])].sort()) {
    await db.execute(sql`SELECT pg_advisory_xact_lock(hashtextextended(${uid}, 714031))`);
  }
  await db.execute(sql`
    SELECT pg_advisory_xact_lock(hashtextextended(
      ${`ovid-collab-artifact:${input.ownerUserId}:${input.sessionId}:${input.artifactId}`}, 0))`);
}

export interface CollabArtifactAttemptCleanupFence {
  allowed: boolean;
  sessionDeleted: boolean;
  accountFenced: boolean;
  accountUpdatedAt: Record<string, string | null>;
}

/**
 * Short DB-only fence used before and after storage inspection. No HEAD/GET/
 * DELETE is performed by this function. Administrative cleanup can continue
 * after close/deletion for released non-active attempts, but the current
 * deleted/account snapshots are returned and re-read before physical deletion.
 */
export async function readCollabArtifactAttemptCleanupFence(
  db: Db,
  candidate: CollabArtifactAttemptOrphanCandidate,
  deadline: CollabArtifactDeadline,
): Promise<CollabArtifactAttemptCleanupFence> {
  return runCollabArtifactRecoveryTransaction({
    db,
    deadline,
    fn: async (tx) => {
      await lockCollabArtifactRecoveryAuthority(tx, {
        ownerUserId: candidate.ownerUid,
        actorUserId: candidate.actorUid ?? candidate.ownerUid,
        sessionId: candidate.sessionId,
        artifactId: candidate.id,
      });
      // Match registrar authority/session -> workspace row -> reservation order.
      const sessionRows = await tx.execute(sql`
        SELECT deleted_at FROM sessions WHERE id = ${candidate.sessionId} LIMIT 1 FOR UPDATE`) as unknown as Array<{
        deleted_at: Date | string | null;
      }>;
      const accountRows = await tx.execute(sql`
        SELECT uid, state, updated_at FROM account_deletions
         WHERE uid IN (${candidate.ownerUid}, ${candidate.actorUid ?? candidate.ownerUid})
         ORDER BY uid FOR UPDATE`) as unknown as Array<{
        uid: string;
        state: string;
        updated_at: Date | string;
      }>;
      const currentRows = await tx.execute(sql`
        SELECT status, r2_key, meta FROM workspace_objects
         WHERE id = ${candidate.id} AND user_id = ${candidate.ownerUid}
           AND session_id = ${candidate.sessionId}
         LIMIT 1 FOR UPDATE`) as unknown as Array<{
        status: string;
        r2_key: string;
        meta: Record<string, unknown> | null;
      }>;
      const current = currentRows[0];
      const reservationRows = await tx.execute(sql`
        SELECT actor_user_id, owner_user_id, session_id, object_id, state
          FROM storage_reservations WHERE id = ${candidate.attemptReservationId}
          LIMIT 1 FOR UPDATE`) as unknown as Array<{
        actor_user_id: string;
        owner_user_id: string;
        session_id: string;
        object_id: string | null;
        state: "reserved" | "finalized" | "released";
      }>;
      const reservation = reservationRows[0];
      const currentAttempt = current?.meta?.attempt;
      const attempt = typeof currentAttempt === "number" && Number.isSafeInteger(currentAttempt)
        ? currentAttempt
        : null;
      const accountUpdatedAt: Record<string, string | null> = {};
      for (const row of accountRows) {
        accountUpdatedAt[row.uid] = row.updated_at instanceof Date
          ? row.updated_at.toISOString()
          : String(row.updated_at);
      }
      let keyShapeValid = false;
      try {
        const safeKey = assertSafeRelPath(candidate.key);
        const prefix = `users/${candidate.ownerUid}/artifacts/${candidate.sessionId}/${candidate.id}-attempt-${candidate.attempt}-`;
        const parsed = parseCollabArtifactAttemptReservationId(candidate.attemptReservationId);
        keyShapeValid = parsed?.artifactId === candidate.id && parsed.attempt === candidate.attempt &&
          safeKey === candidate.key && safeKey.startsWith(prefix) &&
          /^[a-f0-9]{16}-[^/]+$/.test(safeKey.slice(prefix.length));
      } catch {
        keyShapeValid = false;
      }
      const allowed = keyShapeValid &&
        reservation !== undefined &&
        candidate.actorUid !== undefined &&
        reservation.actor_user_id === candidate.actorUid &&
        reservation.owner_user_id === candidate.ownerUid &&
        reservation.session_id === candidate.sessionId &&
        collabArtifactAttemptMayDelete({
          reservationState: reservation.state,
          reservationObjectId: reservation.object_id,
          candidateKey: candidate.key,
          candidateAttempt: candidate.attempt,
          current: current === undefined ? null : {
            status: current.status,
            r2Key: current.r2_key,
            attempt,
          },
        });
      return {
        allowed,
        sessionDeleted: sessionRows[0] !== undefined && sessionRows[0].deleted_at !== null,
        accountFenced: accountRows.some((row) => row.state !== "active" && row.state !== "cancelled"),
        accountUpdatedAt,
      };
    },
  });
}

export interface CollabArtifactReservedReleasePort {
  release(input: { reservationId: string }): Promise<void>;
}

/** One bounded accounting-only reserved-attempt release pass, no storage I/O. */
export async function releaseCollabArtifactReservedAttempts(input: {
  db: Db;
  ownerUserId: string;
  sessionId: string;
  artifactId: string;
  deadline: CollabArtifactDeadline;
  limit?: number;
  reservationStore?(db: Db): CollabArtifactReservedReleasePort;
}): Promise<{ released: number; remaining: number }> {
  const limit = input.limit ?? 64;
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
    throw new RangeError("reserved-attempt release limit must be 1..100");
  }
  return runCollabArtifactRecoveryTransaction({
    db: input.db,
    deadline: input.deadline,
    fn: async (tx) => {
      // First read actor identities without advisory locks, then take all UID
      // locks in the same UID -> artifact order as publication. Re-read under
      // those locks before any state transition; no object/HEAD work occurs.
      const candidates = await tx.execute(sql`
        SELECT id, actor_user_id FROM storage_reservations
         WHERE state = 'reserved'
           AND id ~ ${`^${input.artifactId}:collab-attempt:[1-9][0-9]*$`}
           AND owner_user_id = ${input.ownerUserId}
           AND session_id = ${input.sessionId}
         ORDER BY created_at, id
         LIMIT ${limit}`) as unknown as Array<{ id: string; actor_user_id: string }>;
      for (const uid of [...new Set([
        input.ownerUserId,
        ...candidates.map((row) => row.actor_user_id),
      ])].sort()) {
        await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtextextended(${uid}, 714031))`);
      }
      await tx.execute(sql`
        SELECT pg_advisory_xact_lock(hashtextextended(
          ${`ovid-collab-artifact:${input.ownerUserId}:${input.sessionId}:${input.artifactId}`}, 0))`);
      const lockedCandidates = await tx.execute(sql`
        SELECT id, actor_user_id FROM storage_reservations
         WHERE state = 'reserved'
           AND id ~ ${`^${input.artifactId}:collab-attempt:[1-9][0-9]*$`}
           AND owner_user_id = ${input.ownerUserId}
           AND session_id = ${input.sessionId}
         ORDER BY created_at, id
         LIMIT ${limit} FOR UPDATE`) as unknown as Array<{ id: string; actor_user_id: string }>;
      const lockedUids = new Set([
        input.ownerUserId,
        ...candidates.map((row) => row.actor_user_id),
      ]);
      if (lockedCandidates.some((row) => !lockedUids.has(row.actor_user_id))) {
        // A new actor arrived between the identity read and lock acquisition.
        // Retry next pass rather than release without that actor's UID fence.
        throw new CollabArtifactStorageError("storage_unavailable");
      }
      const store = input.reservationStore?.(tx) ?? new StorageReservationStore(tx);
      let released = 0;
      for (const candidate of lockedCandidates) {
        await store.release({ reservationId: candidate.id });
        released += 1;
      }
      const remainingRows = await tx.execute(sql`
        SELECT count(*)::int AS count FROM storage_reservations
         WHERE state = 'reserved'
           AND id ~ ${`^${input.artifactId}:collab-attempt:[1-9][0-9]*$`}
           AND owner_user_id = ${input.ownerUserId}
           AND session_id = ${input.sessionId}`) as unknown as Array<{ count: number | string }>;
      return { released, remaining: Number(remainingRows[0]?.count ?? 0) };
    },
  });
}

export interface CollabArtifactAttemptCleanupPort {
  cleanupArtifactAttempt(input: {
    candidate: CollabArtifactAttemptOrphanCandidate;
    inspect(key: string): Promise<"missing" | "owned" | "foreign">;
    remove(key: string): Promise<void>;
    /** Overall sweep deadline; cleanup-port DB work must use it too. */
    deadline: CollabArtifactDeadline;
    signal: AbortSignal;
  }): Promise<"cleaned" | "missing" | "skipped">;
}

/** Canonical short-fence/lock-free storage cleanup used by scheduled recovery. */
export async function cleanupCollabArtifactAttemptWithShortFences(input: {
  db: Db;
  storage: Pick<StorageAdapter, "head" | "delete">;
  candidate: CollabArtifactAttemptOrphanCandidate;
  deadline: CollabArtifactDeadline;
}): Promise<"cleaned" | "missing" | "skipped"> {
  const before = await readCollabArtifactAttemptCleanupFence(
    input.db,
    input.candidate,
    input.deadline,
  );
  if (!before.allowed) return "skipped";
  // No DB/advisory/row lock is held across this storage call.
  const head = await input.deadline.run(() => input.storage.head(input.candidate.key));
  const ownership = classifyCollabArtifactAttemptHead(head, input.candidate);
  if (ownership === "missing") return "missing";
  if (ownership === "foreign") return "skipped";
  // Fresh DB-only transaction immediately before physical deletion. Storage
  // HEAD above and DELETE below are both outside every DB lock.
  const after = await readCollabArtifactAttemptCleanupFence(
    input.db,
    input.candidate,
    input.deadline,
  );
  if (!after.allowed) return "skipped";
  await input.deadline.run(() => input.storage.delete(input.candidate.key));
  return "cleaned";
}

/**
 * One scheduled-pass primitive for the existing Collab object sweeper. The
 * default path uses canonical short DB-only fences; an optional integration
 * port receives the same overall deadline. This is not another timer or an
 * unfenced delete.
 */
export async function reconcileCollabArtifactAttemptOrphans(deps: {
  db: Db;
  /** Optional integration port; its DB work is also raced by the sweep deadline. */
  cleanup?: CollabArtifactAttemptCleanupPort["cleanupArtifactAttempt"];
  storage: Pick<StorageAdapter, "head" | "delete">;
  limit?: number;
  before?: CollabArtifactAttemptCursor;
  deadline?: CollabArtifactDeadline;
}): Promise<{
  examined: number;
  cleaned: number;
  missing: number;
  skipped: number;
  failed: number;
  deadlineExceeded: boolean;
  nextCursor: CollabArtifactAttemptCursor | null;
}> {
  const operationDeadline = deps.deadline ?? new CollabArtifactDeadline(30_000);
  const cleanupPort = deps.cleanup;
  try {
    const page = await listCollabArtifactAttemptOrphanCandidates(deps.db, {
      limit: deps.limit,
      before: deps.before,
      deadline: operationDeadline,
    });
    let cleaned = 0;
    let missing = 0;
    let skipped = 0;
    let failed = 0;
    for (const candidate of page.rows) {
      if (operationDeadline.signal.aborted) break;
      try {
        const invoke = () => cleanupPort === undefined
          ? cleanupCollabArtifactAttemptWithShortFences({
            db: deps.db,
            storage: deps.storage,
            candidate,
            deadline: operationDeadline,
          })
          : cleanupPort({
            candidate,
            deadline: operationDeadline,
            signal: operationDeadline.signal,
            inspect: async (key) => {
              const head = await operationDeadline.run(() => deps.storage.head(key));
              return classifyCollabArtifactAttemptHead(head, candidate);
            },
            remove: (key) => operationDeadline.run(() => deps.storage.delete(key)),
          });
        // Includes optional cleanup-port DB work in the same overall deadline.
        const outcome = await operationDeadline.run(invoke);
        if (outcome === "cleaned") cleaned += 1;
        else if (outcome === "missing") missing += 1;
        else skipped += 1;
      } catch {
        failed += 1;
        if (operationDeadline.signal.aborted) break;
      }
    }
    return {
      examined: page.rows.length,
      cleaned,
      missing,
      skipped,
      failed,
      deadlineExceeded: operationDeadline.signal.aborted,
      nextCursor: page.nextCursor,
    };
  } finally {
    if (deps.deadline === undefined) operationDeadline.close();
  }
}

export interface CollabOrphanSweepBudget {
  ordinary: number;
  attempts: number;
}

/** Reserve ordinary work every pass; limit=1 alternates classes by pass parity. */
export function collabOrphanSweepBudget(limit: number, sequence: number): CollabOrphanSweepBudget {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100 ||
      !Number.isSafeInteger(sequence) || sequence < 0) {
    throw new RangeError("invalid orphan sweep budget");
  }
  if (limit === 1) return sequence % 2 === 0 ? { ordinary: 1, attempts: 0 } : { ordinary: 0, attempts: 1 };
  const ordinary = Math.max(1, Math.floor(limit / 2));
  return { ordinary, attempts: limit - ordinary };
}

export interface CollabOrphanSweepPlan extends CollabOrphanSweepBudget {
  sequence: number;
  forceHead: boolean;
  attemptCursor: CollabArtifactAttemptCursor | undefined;
}

/**
 * Cursor progress plus an independent periodic head rescan. A sustained stream
 * of new full pages cannot postpone the delayed old-missing/late-PUT rescan.
 */
export class CollabOrphanSweepScheduler {
  private sequence = 0;
  private completedSequence = -1;
  private attemptCursor: CollabArtifactAttemptCursor | undefined;
  private lastHeadScanAt: number | null = null;

  constructor(
    private readonly options: {
      rescanDelayMs?: number;
      now?: () => number;
    } = {},
  ) {
    const delay = options.rescanDelayMs ?? 30_000;
    if (!Number.isSafeInteger(delay) || delay < 1) throw new RangeError("invalid orphan rescan delay");
    this.rescanDelayMs = delay;
    this.now = options.now ?? Date.now;
  }

  private readonly rescanDelayMs: number;
  private readonly now: () => number;

  nextPlan(limit = 50): CollabOrphanSweepPlan {
    const now = this.now();
    const forceHead = this.lastHeadScanAt === null ||
      now - this.lastHeadScanAt >= this.rescanDelayMs;
    const plan: CollabOrphanSweepPlan = {
      ...collabOrphanSweepBudget(limit, this.sequence),
      sequence: this.sequence,
      forceHead,
      attemptCursor: forceHead ? undefined : this.attemptCursor,
    };
    this.sequence += 1;
    return plan;
  }

  complete(plan: CollabOrphanSweepPlan, nextAttemptCursor: CollabArtifactAttemptCursor | null): void {
    if (plan.sequence >= this.sequence || plan.sequence <= this.completedSequence) {
      throw new RangeError("orphan sweep plan completed out of order");
    }
    this.completedSequence = plan.sequence;
    if (plan.forceHead) {
      // A rescue scan is independent of forward pagination. Only initialize
      // forward progress when none exists; never rewind a later-page cursor to
      // the head pass's continuation point.
      if (this.attemptCursor === undefined) {
        this.attemptCursor = nextAttemptCursor ?? undefined;
      }
      this.lastHeadScanAt = this.now();
    } else {
      this.attemptCursor = nextAttemptCursor ?? undefined;
    }
  }
}
