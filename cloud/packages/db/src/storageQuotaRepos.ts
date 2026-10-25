import { sql } from "drizzle-orm";
import type { Db } from "./client.js";
import {
  QuotaContractError,
  lockAttachmentForStorageCleanup,
  reconcileStorageUsage,
  StorageReservationStore,
  type StorageQuotaReservationResult,
  type StorageReservationResult,
  type StorageReservationStoreOptions,
} from "./quotaService.js";

/** Public upload reservation identity: defaults to the canonical attachment id. */
export interface ReserveUploadInput {
  reservationId?: string;
  actorUserId: string;
  ownerUserId: string;
  sessionId: string;
  attachmentId: string;
  declaredBytes: number;
  /** Optional current HEAD evidence used atomically for legacy reconciliation. */
  head?: { bytes: number; contentType: string | null; etag: string | null } | null;
}

export interface ReserveArtifactInput {
  reservationId?: string;
  actorUserId: string;
  ownerUserId: string;
  sessionId: string;
  artifactId: string;
  declaredBytes: number;
}

export interface FinalizeStorageUploadInput {
  reservationId: string;
  actualBytes: number;
  actualContentType: string | null;
  etag: string | null;
  /** Recheck attachment status inside finalize's lock before charging/ready. */
  attachment?: boolean;
}

export interface RemoveStorageObjectResult {
  removed: boolean;
  freedBytes: number;
}

export interface StorageUsage {
  usedBytes: number;
  reservedBytes: number;
}

export interface StorageQuotaRepos {
  reserveUpload(input: ReserveUploadInput): Promise<StorageReservationResult>;
  finalizeUpload(input: FinalizeStorageUploadInput): Promise<StorageQuotaReservationResult>;
  releaseUpload(input: { reservationId: string }): Promise<void>;
  reserveArtifact(input: ReserveArtifactInput): Promise<StorageQuotaReservationResult>;
  removeObject(input: { reservationId: string }): Promise<RemoveStorageObjectResult>;
  storageUsage(ownerUserId: string): Promise<StorageUsage>;
}

function store(db: Db, options: StorageReservationStoreOptions): StorageReservationStore {
  return new StorageReservationStore(db, options);
}

function quotaOnly(result: StorageReservationResult): StorageQuotaReservationResult {
  if (!result.ok && result.scope === "attachment") {
    // Artifact/finalize contracts cannot produce this outcome. Do not cast an
    // invariant violation into a storage-cap refusal if that ever changes.
    throw new QuotaContractError("attachment_failed");
  }
  return result;
}

export async function reserveUpload(
  db: Db,
  input: ReserveUploadInput,
  options: StorageReservationStoreOptions = {},
): Promise<StorageReservationResult> {
  return store(db, options).reserve({
    reservationId: input.reservationId ?? input.attachmentId,
    ownerUserId: input.ownerUserId,
    uploaderUserId: input.actorUserId,
    sessionId: input.sessionId,
    objectId: input.attachmentId,
    declaredBytes: input.declaredBytes,
    attachment: true,
    head: input.head,
  });
}

export async function reserveArtifact(
  db: Db,
  input: ReserveArtifactInput,
  options: StorageReservationStoreOptions = {},
): Promise<StorageQuotaReservationResult> {
  return quotaOnly(await store(db, options).reserve({
    reservationId: input.reservationId ?? input.artifactId,
    ownerUserId: input.ownerUserId,
    uploaderUserId: input.actorUserId,
    sessionId: input.sessionId,
    objectId: input.artifactId,
    declaredBytes: input.declaredBytes,
  }));
}

export async function finalizeUpload(
  db: Db,
  input: FinalizeStorageUploadInput,
  options: StorageReservationStoreOptions = {},
): Promise<StorageQuotaReservationResult> {
  return store(db, options).finalize({
    reservationId: input.reservationId,
    actualBytes: input.actualBytes,
    contentType: input.actualContentType,
    etag: input.etag,
    attachment: input.attachment,
  });
}

export async function releaseUpload(
  db: Db,
  input: { reservationId: string },
  options: StorageReservationStoreOptions = {},
): Promise<void> {
  await store(db, options).release(input);
}

/**
 * A finalized object is removed exactly once. A replay is a truthful no-op,
 * never a second debit. Reserved (not yet real) objects must use releaseUpload.
 */
export async function removeObject(
  db: Db,
  input: { reservationId: string },
  options: Pick<StorageReservationStoreOptions, "now"> = {},
): Promise<RemoveStorageObjectResult> {
  if (typeof input.reservationId !== "string" || input.reservationId.length === 0) {
    throw new RangeError("reservationId must be a non-empty string");
  }
  const now = options.now?.() ?? new Date();
  if (!Number.isFinite(now.getTime())) throw new RangeError("storage clock returned an invalid Date");
  return db.transaction(async (tx) => {
    const identity = (await tx.execute(sql`
      SELECT actor_user_id, owner_user_id, session_id, object_id FROM storage_reservations
       WHERE id = ${input.reservationId} LIMIT 1`)) as unknown as Array<{
      actor_user_id: string;
      owner_user_id: string;
      session_id: string;
      object_id: string | null;
    }>;
    const first = identity[0];
    if (first === undefined) throw new QuotaContractError("reservation_not_found");
    const ids = [...new Set([first.owner_user_id, first.actor_user_id])].sort();
    for (const uid of ids) {
      const locked = (await tx.execute(sql`
        SELECT uid FROM users WHERE uid = ${uid} FOR UPDATE`)) as unknown as Array<{ uid: string }>;
      if (locked[0] === undefined) throw new QuotaContractError("unknown_user");
    }
    await lockAttachmentForStorageCleanup(tx, {
      reservationId: input.reservationId,
      ownerUserId: first.owner_user_id,
      uploaderUserId: first.actor_user_id,
      sessionId: first.session_id,
      declaredBytes: 0,
      objectId: first.object_id,
      attachment: first.object_id === input.reservationId,
    });
    const found = (await tx.execute(sql`
      SELECT * FROM storage_reservations WHERE id = ${input.reservationId} FOR UPDATE`)) as unknown as Array<{
      state: string;
      actor_user_id: string;
      owner_user_id: string;
      session_id: string;
      object_id: string | null;
      actual_bytes: number | string | null;
      actual_content_type: string | null;
      etag: string | null;
      reserved_at: Date | string;
      finalized_at: Date | string | null;
    }>;
    const reservation = found[0]!;
    if (reservation.state === "released") return { removed: false, freedBytes: 0 };
    if (reservation.state !== "finalized" || reservation.actual_bytes === null) {
      throw new QuotaContractError("invalid_reservation_state");
    }
    const actualBytes = Number(reservation.actual_bytes);
    const debited = (await tx.execute(sql`
      UPDATE storage_usage_counters
         SET used_bytes = used_bytes - ${actualBytes}, updated_at = ${now.toISOString()}::timestamptz
       WHERE owner_user_id = ${reservation.owner_user_id}
         AND used_bytes >= ${actualBytes}
      RETURNING owner_user_id`)) as unknown as Array<{ owner_user_id: string }>;
    if (debited[0] === undefined) throw new QuotaContractError("storage_counter_inconsistent");

    // Releasing bytes must not replenish the actor's rolling upload window.
    // Persist a zero-byte successful-upload fact before releasing the original
    // reservation. Failed-upload release never creates this fact. Internal
    // share copies/grants are reference accounting, not actor uploads.
    const objectId = reservation.object_id;
    const isInternalShare = objectId !== null && (
      objectId.startsWith("charge:") || objectId.includes("/artifact-shares/")
    );
    if (!isInternalShare) {
      const historyId = `upload-complete:${input.reservationId}`;
      await tx.execute(sql`
        INSERT INTO storage_reservations
          (id, actor_user_id, owner_user_id, session_id, object_id, state,
           declared_bytes, actual_bytes, actual_content_type, etag,
           reserved_at, finalized_at, created_at, updated_at)
        VALUES
          (${historyId}, ${reservation.actor_user_id}, ${reservation.owner_user_id},
           ${reservation.session_id}, ${`upload-complete:${objectId ?? input.reservationId}`},
           'finalized', 0, 0, ${reservation.actual_content_type}, ${reservation.etag},
           ${new Date(reservation.reserved_at).toISOString()}::timestamptz,
           ${new Date(reservation.finalized_at!).toISOString()}::timestamptz,
           ${now.toISOString()}::timestamptz, ${now.toISOString()}::timestamptz)
        ON CONFLICT (id) DO NOTHING`);
    }
    await tx.execute(sql`
      UPDATE storage_reservations
         SET state = 'released', actual_bytes = NULL, finalized_at = NULL,
             released_at = ${now.toISOString()}::timestamptz,
             updated_at = ${now.toISOString()}::timestamptz
       WHERE id = ${input.reservationId}`);
    return { removed: true, freedBytes: actualBytes };
  });
}

export interface StorageObjectCleanupOutcome {
  state: "released";
  freedBytes: number;
}

export interface CleanupStorageObjectRaceOptions {
  removeObject(): Promise<RemoveStorageObjectResult>;
  releaseUpload(): Promise<void>;
  deleteObject(): Promise<void>;
  deleteRow(): Promise<void>;
  maxAttempts?: number;
}

function storageErrorCode(error: unknown): string | null {
  return error instanceof QuotaContractError ? error.code : null;
}

/**
 * Bounded remove/release reconciliation for reserved ↔ finalized races.
 * removeObject is authoritative for finalized usage; release is only for
 * reserved usage. A finalized release retries remove instead of skipping the
 * debit. Object and row cleanup run on every outcome, including infra errors.
 */
export async function cleanupStorageObjectRace(
  options: CleanupStorageObjectRaceOptions,
): Promise<StorageObjectCleanupOutcome> {
  const maxAttempts = options.maxAttempts ?? 3;
  if (!Number.isInteger(maxAttempts) || maxAttempts < 1 || maxAttempts > 10) {
    throw new RangeError("cleanup maxAttempts must be an integer 1..10");
  }
  let terminal = false;
  let freedBytes = 0;
  let lastError: unknown = null;

  for (let attempt = 0; attempt < maxAttempts && !terminal; attempt++) {
    try {
      const removed = await options.removeObject();
      freedBytes += removed.freedBytes;
      terminal = true;
      break;
    } catch (error) {
      const code = storageErrorCode(error);
      if (code === "reservation_not_found") {
        terminal = true;
        break;
      }
      if (code === "reservation_finalized") continue;
      if (code !== "invalid_reservation_state") {
        lastError = error;
        break;
      }
      try {
        await options.releaseUpload();
        terminal = true;
        break;
      } catch (releaseError) {
        const releaseCode = storageErrorCode(releaseError);
        if (releaseCode === "reservation_finalized") continue;
        if (releaseCode === "reservation_not_found") {
          terminal = true;
          break;
        }
        lastError = releaseError;
        break;
      }
    }
  }

  try {
    await options.deleteObject();
  } finally {
    await options.deleteRow();
  }
  if (!terminal) {
    throw lastError ?? new Error("storage cleanup did not reach a stable terminal state");
  }
  return { state: "released", freedBytes };
}

export async function cleanupStorageObject(
  db: Db,
  input: { reservationId: string },
  options: Omit<CleanupStorageObjectRaceOptions, "removeObject" | "releaseUpload"> &
    Pick<StorageReservationStoreOptions, "now">,
): Promise<StorageObjectCleanupOutcome> {
  return cleanupStorageObjectRace({
    removeObject: () => removeObject(db, input, { now: options.now }),
    releaseUpload: () => releaseUpload(db, input, { now: options.now }),
    deleteObject: options.deleteObject,
    deleteRow: options.deleteRow,
    ...(options.maxAttempts !== undefined ? { maxAttempts: options.maxAttempts } : {}),
  });
}

export async function storageUsage(db: Db, ownerUserId: string): Promise<StorageUsage> {
  await reconcileStorageUsage(db, ownerUserId);
  const rows = await db.$client<{
    used_bytes: number | string;
    reserved_bytes: number | string;
  }[]>`
    SELECT used_bytes, reserved_bytes FROM storage_usage_counters
     WHERE owner_user_id = ${ownerUserId}`;
  return {
    usedBytes: Number(rows[0]?.used_bytes ?? 0),
    reservedBytes: Number(rows[0]?.reserved_bytes ?? 0),
  };
}

export function createStorageQuotaRepos(
  db: Db,
  options: StorageReservationStoreOptions = {},
): StorageQuotaRepos {
  const reservations = store(db, options);
  return {
    reserveUpload: (input) => reservations.reserve({
      reservationId: input.reservationId ?? input.attachmentId,
      ownerUserId: input.ownerUserId,
      uploaderUserId: input.actorUserId,
      sessionId: input.sessionId,
      objectId: input.attachmentId,
      declaredBytes: input.declaredBytes,
      attachment: true,
      head: input.head,
    }),
    reserveArtifact: async (input) => quotaOnly(await reservations.reserve({
      reservationId: input.reservationId ?? input.artifactId,
      ownerUserId: input.ownerUserId,
      uploaderUserId: input.actorUserId,
      sessionId: input.sessionId,
      objectId: input.artifactId,
      declaredBytes: input.declaredBytes,
    })),
    finalizeUpload: (input) => reservations.finalize({
      reservationId: input.reservationId,
      actualBytes: input.actualBytes,
      contentType: input.actualContentType,
      etag: input.etag,
      attachment: input.attachment,
    }),
    releaseUpload: (input) => reservations.release(input),
    removeObject: (input) => removeObject(db, input, options),
    storageUsage: (ownerUserId) => storageUsage(db, ownerUserId),
  };
}

/** Namespace form for callers that follow the other @ovid/db repo surfaces. */
export const storageQuotaRepos = {
  reserveUpload,
  reserveArtifact,
  finalizeUpload,
  releaseUpload,
  removeObject,
  cleanupObject: cleanupStorageObject,
  storageUsage,
};

export type { StorageQuotaReservationResult, StorageReservationResult } from "./quotaService.js";
