/**
 * Per-plan storage quota (P3).
 *
 * Product truth: Free 3 GB, Ovid Go 5 GB, Ovid Plus 15 GB, Ovid Pro 75 GB.
 * Every upload must pass a quota reservation BEFORE the bytes are stored, and
 * an over-quota upload is refused with a typed error — never a generic 500.
 *
 * Attribution: storage is charged to the account whose plan pays for it. For a
 * Collab session that is the session CREATOR, even when a member uploads the
 * file (`storageAttribution`). A personal upload charges the uploader.
 *
 * Atomicity: `StorageQuotaLedger.tryReserve` is the authoritative check. A
 * production ledger MUST make the read-check-write one atomic operation (for
 * SQL: an `UPDATE … SET used = used + $bytes WHERE owner_uid = $1 AND used +
 * $bytes <= $limit RETURNING used`, or a row lock). `createMemoryStorageQuotaLedger`
 * is the in-process reference implementation used by tests and local wiring.
 *
 * Reservation lifetime: reserve before the upload, keep the reservation once
 * the object is stored, release it only when the upload failed (see
 * `withStorageQuota`). A crash between reserve and upload can leak a
 * reservation; a periodic reconciliation against the object ledger is the
 * caller's responsibility (the storage package cannot know attachment rows).
 */

import { StorageError } from "./errors.js";

// ---------------------------------------------------------------------------
// Plans
// ---------------------------------------------------------------------------

/** Canonical plan ids; server tier aliases resolve to these. */
export type StoragePlanId = "free" | "go" | "plus" | "pro";

/** Binary gigabyte (GiB), consistent with the rest of the storage package. */
export const BYTES_PER_GB = 1024 * 1024 * 1024;

/** Included storage per plan, in GB (exact product table). */
export const PLAN_STORAGE_GB: Readonly<Record<StoragePlanId, number>> = Object.freeze({
  free: 3,
  go: 5,
  plus: 15,
  pro: 75,
});

/** Included storage per plan, in bytes. */
export const PLAN_STORAGE_BYTES: Readonly<Record<StoragePlanId, number>> = Object.freeze({
  free: PLAN_STORAGE_GB.free * BYTES_PER_GB,
  go: PLAN_STORAGE_GB.go * BYTES_PER_GB,
  plus: PLAN_STORAGE_GB.plus * BYTES_PER_GB,
  pro: PLAN_STORAGE_GB.pro * BYTES_PER_GB,
});

/**
 * Tier/plan aliases. The cloud mints legacy tier ids (`3x`, `7x`, `15x`) and
 * the UI uses `starter`/`max` for Go/Pro; they map to the same four plans.
 * Anything unknown resolves to Free — a billing lookup must never grant more
 * storage than the smallest plan by accident.
 */
const PLAN_ALIASES: Readonly<Record<string, StoragePlanId>> = Object.freeze({
  free: "free",
  "free plan": "free",
  go: "go",
  "ovid go": "go",
  "3x": "go",
  starter: "go",
  plus: "plus",
  "ovid plus": "plus",
  "7x": "plus",
  pro: "pro",
  "ovid pro": "pro",
  "15x": "pro",
  max: "pro",
});

/** Resolve a stored tier/plan id to a canonical plan. Unknown → Free. */
export function resolveStoragePlan(tier: string | null | undefined): StoragePlanId {
  if (typeof tier !== "string") return "free";
  const key = tier.trim().toLowerCase().replace(/[_-]+/g, " ");
  return PLAN_ALIASES[key] ?? "free";
}

/** Included bytes for a canonical plan. */
export function storageLimitBytes(plan: StoragePlanId): number {
  return PLAN_STORAGE_BYTES[plan];
}

// ---------------------------------------------------------------------------
// Attribution
// ---------------------------------------------------------------------------

export interface StorageAttribution {
  /** The account whose plan and usage row pay for the bytes. */
  ownerUid: string;
  /** The account performing the upload (the creator in a personal session). */
  uploaderUid: string;
  /** True when the uploader is not the paying owner (a Collab member). */
  isCreator: boolean;
}

export interface StorageAttributionInput {
  uploaderUid: string;
  /**
   * The Collab session creator. Omit (or pass null) for a personal session —
   * the uploader then pays. The caller must read this from the session row,
   * never from client input.
   */
  sessionOwnerUid?: string | null;
}

function requireUid(value: string, field: string): string {
  if (typeof value !== "string" || value.trim() === "") {
    throw new StorageError(`${field} is required`, { code: "invalid_arg" });
  }
  return value.trim();
}

/** Creator-pays attribution, collapsing a personal session onto its uploader. */
export function storageAttribution(input: StorageAttributionInput): StorageAttribution {
  const uploaderUid = requireUid(input.uploaderUid, "uploaderUid");
  const ownerUid =
    input.sessionOwnerUid === undefined || input.sessionOwnerUid === null
      ? uploaderUid
      : requireUid(input.sessionOwnerUid, "sessionOwnerUid");
  return { ownerUid, uploaderUid, isCreator: ownerUid === uploaderUid };
}

// ---------------------------------------------------------------------------
// Usage + typed refusal
// ---------------------------------------------------------------------------

export const STORAGE_QUOTA_EXCEEDED_CODE = "storage_quota_exceeded";

export interface StorageQuotaSnapshot {
  ownerUid: string;
  uploaderUid: string;
  /** True when uploaderUid === ownerUid. */
  isCreator: boolean;
  plan: StoragePlanId;
  /** Plan allowance in bytes. */
  limitBytes: number;
  /** Bytes already attributed to the creator (post-reservation for a reservation). */
  usedBytes: number;
  /** `max(0, limitBytes - usedBytes)`. */
  availableBytes: number;
}

/** Details carried by a refused upload; safe for logs/analytics (no secrets). */
export interface StorageQuotaExceededDetails {
  ownerUid: string;
  uploaderUid: string;
  plan: StoragePlanId;
  limitBytes: number;
  usedBytes: number;
  requestedBytes: number;
}

/**
 * Refused because the creator's plan allowance would be exceeded. Routes map
 * `code === "storage_quota_exceeded"` to a 4xx (413/409) and must not write
 * the object or its ledger row.
 */
export class StorageQuotaExceededError extends StorageError {
  readonly ownerUid: string;
  readonly uploaderUid: string;
  readonly plan: StoragePlanId;
  readonly limitBytes: number;
  readonly usedBytes: number;
  readonly requestedBytes: number;
  /** Bytes that were available at refusal time (never negative). */
  readonly availableBytes: number;

  constructor(details: StorageQuotaExceededDetails) {
    super(
      `Storage limit exceeded: ${details.ownerUid} has used ${details.usedBytes} of ` +
        `${details.limitBytes} bytes on the ${details.plan} plan and cannot store ` +
        `${details.requestedBytes} more bytes. Free up space or upgrade the plan.`,
      { code: STORAGE_QUOTA_EXCEEDED_CODE },
    );
    this.ownerUid = details.ownerUid;
    this.uploaderUid = details.uploaderUid;
    this.plan = details.plan;
    this.limitBytes = details.limitBytes;
    this.usedBytes = details.usedBytes;
    this.requestedBytes = details.requestedBytes;
    this.availableBytes = Math.max(0, details.limitBytes - details.usedBytes);
  }
}

function assertByteCount(bytes: number, field: string): void {
  if (typeof bytes !== "number" || !Number.isSafeInteger(bytes) || bytes < 0) {
    throw new StorageError(`${field} must be a non-negative safe integer`, {
      code: "invalid_arg",
    });
  }
}

function snapshotOf(
  attribution: StorageAttribution,
  plan: StoragePlanId,
  usedBytes: number,
): StorageQuotaSnapshot {
  const limitBytes = PLAN_STORAGE_BYTES[plan];
  return {
    ownerUid: attribution.ownerUid,
    uploaderUid: attribution.uploaderUid,
    isCreator: attribution.isCreator,
    plan,
    limitBytes,
    usedBytes,
    availableBytes: Math.max(0, limitBytes - usedBytes),
  };
}

/**
 * Pure cap check. The cap is inclusive: `used + incoming === limit` is allowed,
 * one byte more is refused. A zero-byte upload is always allowed (deleting
 * files, metadata-only entries) even after a downgrade left the account above
 * its new cap.
 */
export function assertStorageQuota(
  snapshot: StorageQuotaSnapshot,
  incomingBytes: number,
): void {
  assertByteCount(incomingBytes, "incomingBytes");
  if (incomingBytes === 0) return;
  if (snapshot.usedBytes + incomingBytes <= snapshot.limitBytes) return;
  throw new StorageQuotaExceededError({
    ownerUid: snapshot.ownerUid,
    uploaderUid: snapshot.uploaderUid,
    plan: snapshot.plan,
    limitBytes: snapshot.limitBytes,
    usedBytes: snapshot.usedBytes,
    requestedBytes: incomingBytes,
  });
}

// ---------------------------------------------------------------------------
// Ledger contract + in-memory reference
// ---------------------------------------------------------------------------

/**
 * Byte accounting for one paying account. The creator's row spans every
 * session they own, so Collab member uploads land on the same number.
 *
 * `tryReserve` must be atomic across concurrent uploads/processes. It returns
 * the new used total on success and null on refusal; it must never exceed the
 * supplied limit. `release` undoes a reservation (failed upload only).
 */
export interface StorageQuotaLedger {
  usedBytes(ownerUid: string): Promise<number>;
  tryReserve(ownerUid: string, bytes: number, limitBytes: number): Promise<number | null>;
  release(ownerUid: string, bytes: number): Promise<void>;
}

/**
 * In-process ledger for tests and single-process dev wiring. JS runs each
 * synchronous reservation body to completion, so interleaved `Promise.all`
 * uploads observe a consistent read-check-write. A multi-process deployment
 * needs the SQL/Redis equivalent (see the module comment).
 */
export function createMemoryStorageQuotaLedger(
  initial: Iterable<readonly [string, number]> = [],
): StorageQuotaLedger {
  const used = new Map<string, number>();
  for (const [uid, bytes] of initial) {
    if (typeof uid !== "string" || uid === "") {
      throw new StorageError("ledger uid must be a non-empty string", { code: "invalid_arg" });
    }
    assertByteCount(bytes, "ledger bytes");
    used.set(uid, bytes);
  }

  return {
    async usedBytes(ownerUid: string): Promise<number> {
      return used.get(ownerUid) ?? 0;
    },

    async tryReserve(
      ownerUid: string,
      bytes: number,
      limitBytes: number,
    ): Promise<number | null> {
      assertByteCount(bytes, "bytes");
      assertByteCount(limitBytes, "limitBytes");
      const current = used.get(ownerUid) ?? 0;
      const next = current + bytes;
      if (!Number.isSafeInteger(next)) {
        throw new StorageError("ledger byte count overflow", { code: "invalid_arg" });
      }
      if (next > limitBytes) return null;
      used.set(ownerUid, next);
      return next;
    },

    async release(ownerUid: string, bytes: number): Promise<void> {
      assertByteCount(bytes, "bytes");
      const current = used.get(ownerUid) ?? 0;
      used.set(ownerUid, Math.max(0, current - bytes));
    },
  };
}

// ---------------------------------------------------------------------------
// Upload gate
// ---------------------------------------------------------------------------

export interface StorageUsageInput extends StorageAttributionInput {
  /** The paying owner's tier/plan id (`free`, `3x`, `7x`, `15x`, …). */
  plan: string | null | undefined;
}

export interface StorageUploadInput extends StorageUsageInput {
  /** Exact byte count the upload will store (server-measured). */
  bytes: number;
}

export interface StorageReservation extends StorageQuotaSnapshot {
  /** Bytes reserved by this upload. */
  bytes: number;
  /**
   * Undo the reservation after a failed upload. Idempotent; calling it after a
   * successful upload corrupts accounting, so only the failure path may.
   */
  release(): Promise<void>;
}

async function readSnapshot(
  ledger: StorageQuotaLedger,
  input: StorageUsageInput,
): Promise<StorageQuotaSnapshot> {
  const attribution = storageAttribution(input);
  const plan = resolveStoragePlan(input.plan);
  const usedBytes = await ledger.usedBytes(attribution.ownerUid);
  return snapshotOf(attribution, plan, usedBytes);
}

/** Current usage for the paying owner (never throws for being over quota). */
export async function readStorageUsage(
  ledger: StorageQuotaLedger,
  input: StorageUsageInput,
): Promise<StorageQuotaSnapshot> {
  return readSnapshot(ledger, input);
}

/** Read-only pre-flight; throws `StorageQuotaExceededError` when over quota. */
export async function checkStorageQuota(
  ledger: StorageQuotaLedger,
  input: StorageUploadInput,
): Promise<StorageQuotaSnapshot> {
  assertByteCount(input.bytes, "bytes");
  const snapshot = await readSnapshot(ledger, input);
  assertStorageQuota(snapshot, input.bytes);
  return snapshot;
}

/**
 * Atomically reserve room for one upload. This is the enforcement point: call
 * it before storing bytes and keep the reservation on success. Over quota
 * throws `StorageQuotaExceededError`; invalid sizes/ids throw `invalid_arg`.
 */
export async function reserveStorageForUpload(
  ledger: StorageQuotaLedger,
  input: StorageUploadInput,
): Promise<StorageReservation> {
  assertByteCount(input.bytes, "bytes");
  const attribution = storageAttribution(input);
  const plan = resolveStoragePlan(input.plan);
  const limitBytes = PLAN_STORAGE_BYTES[plan];

  // Zero-byte uploads cannot push an account over its cap and are allowed
  // even when a downgrade left usage above the new limit.
  if (input.bytes === 0) {
    const usedBytes = await ledger.usedBytes(attribution.ownerUid);
    return Object.freeze({
      ...snapshotOf(attribution, plan, usedBytes),
      bytes: 0,
      release: async () => {},
    });
  }

  const usedAfter = await ledger.tryReserve(attribution.ownerUid, input.bytes, limitBytes);
  if (usedAfter === null) {
    const usedBytes = await ledger.usedBytes(attribution.ownerUid);
    throw new StorageQuotaExceededError({
      ownerUid: attribution.ownerUid,
      uploaderUid: attribution.uploaderUid,
      plan,
      limitBytes,
      usedBytes,
      requestedBytes: input.bytes,
    });
  }

  let released = false;
  const release = async (): Promise<void> => {
    if (released) return;
    released = true;
    await ledger.release(attribution.ownerUid, input.bytes);
  };

  return Object.freeze({
    ...snapshotOf(attribution, plan, usedAfter),
    bytes: input.bytes,
    release,
  });
}

/**
 * Enforcement wrapper for an upload function: reserve first, run the upload,
 * release only when it throws. A refusal means the upload body never runs.
 */
export async function withStorageQuota<T>(
  ledger: StorageQuotaLedger,
  input: StorageUploadInput,
  upload: (reservation: StorageReservation) => Promise<T>,
): Promise<T> {
  const reservation = await reserveStorageForUpload(ledger, input);
  try {
    return await upload(reservation);
  } catch (err) {
    try {
      await reservation.release();
    } catch {
      // Best effort: the upload error is the caller's actionable failure.
      // A leaked reservation is repaired by usage reconciliation.
    }
    throw err;
  }
}
