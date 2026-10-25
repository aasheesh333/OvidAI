import {
  artifactVault,
  attachments,
  newId,
  QuotaContractError,
  reconcileStorageUsage,
  removeObject as removeStorageObject,
  StorageReservationStore,
  sweepAbandonedStorageReservations,
  workspaceObjects,
  type Db,
  type StorageQuotaReservationResult,
  type StorageReservationResult,
} from "@ovid/db";
import { storageBytes as planStorageBytes } from "@ovid/shared";
import {
  isActiveCdnContentType,
  sanitizeCdnContentType,
  type CdnCacheClass,
  type CdnDisposition,
  type StorageAdapter,
} from "@ovid/storage";

export interface ReserveUploadInput {
  reservationId?: string;
  actorUserId: string;
  ownerUserId: string;
  sessionId: string;
  attachmentId: string;
  declaredBytes: number;
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

export interface FinalizeUploadInput {
  reservationId: string;
  actualBytes: number;
  actualContentType: string | null;
  etag: string | null;
  attachment?: boolean;
}

export interface StorageUsage {
  usedBytes: number;
  reservedBytes: number;
}

export interface ImmutableShare {
  grantId: string;
  displayName: string;
  key: string;
  versionHash: string;
  cacheClass: CdnCacheClass;
  disposition: CdnDisposition;
  contentType: string;
  sizeBytes: number;
}

export interface StorageQuotaOptions {
  db: Db;
  storage?: StorageAdapter;
  now?: () => Date;
}

export class StorageQuotaError extends Error {
  constructor(readonly code: string, message = code) {
    super(message);
    this.name = "StorageQuotaError";
  }
}

// postgres.js transaction handles share the Sql tag surface but not the full
// pool property surface. The helpers below deliberately need only that tag.
type Tx = unknown;
type Row = Record<string, unknown>;

type SqlCall = <T>(strings: TemplateStringsArray, ...values: unknown[]) => Promise<T>;
interface SqlQuery {
  strings: TemplateStringsArray;
  values: unknown[];
}

/** A local tagged-template carrier; postgres.js still receives the real tag. */
function sql(strings: TemplateStringsArray, ...values: unknown[]): SqlQuery {
  return { strings, values };
}

async function rows<T extends Row>(tx: Tx, query: SqlQuery): Promise<T[]> {
  return (tx as unknown as SqlCall)<T[]>(query.strings, ...query.values);
}

async function execute(tx: Tx, query: SqlQuery): Promise<void> {
  await (tx as unknown as SqlCall)<unknown>(query.strings, ...query.values);
}

async function lockUsers(tx: Tx, ids: readonly string[]): Promise<Map<string, string>> {
  const tiers = new Map<string, string>();
  for (const uid of [...new Set(ids)].sort()) {
    const found = await rows<{ uid: string; tier: string }>(tx, sql`
      SELECT uid, tier FROM users WHERE uid = ${uid} FOR UPDATE`);
    if (found[0] === undefined) throw new QuotaContractError("unknown_user");
    tiers.set(uid, found[0].tier);
  }
  return tiers;
}

function nowFrom(clock: (() => Date) | undefined): Date {
  const value = clock?.() ?? new Date();
  if (!Number.isFinite(value.getTime())) throw new RangeError("storage clock returned an invalid Date");
  return new Date(value.getTime());
}

function shareChargeId(artifactId: string, versionHash: string): string {
  return `artifact-share:${artifactId}:${versionHash}`;
}

function sharePrefix(ownerUserId: string, artifactId: string): string {
  return `users/${ownerUserId}/artifact-shares/${artifactId}/`;
}

function parseShareKey(value: unknown): { artifactId: string; versionHash: string } | null {
  if (typeof value !== "string") return null;
  const match = /^users\/[^/]+\/artifact-shares\/([0-9a-f-]{36})\/sha256-([a-f0-9]{64})\/object$/i.exec(value);
  return match === null ? null : { artifactId: match[1]!, versionHash: match[2]!.toLowerCase() };
}

interface ShareCopyRetirement {
  cleanup: boolean;
  removed: boolean;
}

/** Caller holds the per-share advisory lock and owner user lock in this tx. */
async function retireShareCopyTx(
  tx: Tx,
  input: {
    actorUserId: string;
    artifactId: string;
    versionHash: string;
    key: string;
    now: Date;
  },
): Promise<ShareCopyRetirement> {
  const active = await rows<{ count: number | string }>(tx, sql`
    SELECT count(*)::int AS count FROM storage_reservations
     WHERE object_id = ${input.key} AND state = 'finalized'
       AND declared_bytes = 0 AND actual_bytes = 0`);
  if (Number(active[0]!.count) > 0) return { cleanup: false, removed: false };

  const chargeId = shareChargeId(input.artifactId, input.versionHash);
  const found = await rows<Row>(tx, sql`
    SELECT * FROM storage_reservations WHERE id = ${chargeId} FOR UPDATE`);
  const charge = found[0];
  let removed = false;
  if (charge !== undefined && charge.state !== "released") {
    if (charge.state === "finalized") {
      if (charge.actual_bytes === null) throw new QuotaContractError("storage_counter_inconsistent");
      const bytes = Number(charge.actual_bytes);
      const debited = await rows<{ owner_user_id: string }>(tx, sql`
        UPDATE storage_usage_counters
           SET used_bytes = used_bytes - ${bytes}, updated_at = ${input.now.toISOString()}::timestamptz
         WHERE owner_user_id = ${input.actorUserId} AND used_bytes >= ${bytes}
        RETURNING owner_user_id`);
      if (debited[0] === undefined) throw new QuotaContractError("storage_counter_inconsistent");
      removed = true;
    } else if (charge.state === "reserved") {
      const declared = Number(charge.declared_bytes);
      const released = await rows<{ owner_user_id: string }>(tx, sql`
        UPDATE storage_usage_counters
           SET reserved_bytes = reserved_bytes - ${declared},
               updated_at = ${input.now.toISOString()}::timestamptz
         WHERE owner_user_id = ${input.actorUserId} AND reserved_bytes >= ${declared}
        RETURNING owner_user_id`);
      if (released[0] === undefined) throw new QuotaContractError("storage_counter_inconsistent");
      removed = true;
    } else {
      throw new QuotaContractError("invalid_reservation_state");
    }
    await execute(tx, sql`
      UPDATE storage_reservations
         SET state = 'released', actual_bytes = NULL, finalized_at = NULL,
             released_at = ${input.now.toISOString()}::timestamptz,
             updated_at = ${input.now.toISOString()}::timestamptz
       WHERE id = ${chargeId}`);
  }
  // Released/missing charge + no live grants is exactly the retryable orphan
  // shape. Cleanup may be repeated; counter removal itself happened at most once.
  return { cleanup: true, removed };
}

/** Transactional reservations plus persistent, reference-counted CDN grants. */
export class StorageQuota {
  private readonly reservations: StorageReservationStore;
  private readonly clock: () => Date;

  constructor(private readonly options: StorageQuotaOptions) {
    this.clock = options.now ?? (() => new Date());
    this.reservations = new StorageReservationStore(options.db, { now: this.clock });
  }

  private now(): Date {
    return nowFrom(this.clock);
  }

  private adapter(): StorageAdapter {
    if (this.options.storage === undefined) throw new StorageQuotaError("storage_not_configured");
    return this.options.storage;
  }

  private async deleteShareBytes(key: string): Promise<boolean> {
    try {
      await this.adapter().delete(key);
      return true;
    } catch {
      // Never log the object key or a signed URL. Durable grant revocation is
      // independent of this retryable byte-cleanup outcome.
      console.warn("[gateway] immutable share bytes are pending cleanup");
      return false;
    }
  }

  private async reconcileUnusedShareCopy(input: {
    actorUserId: string;
    artifactId: string;
    versionHash: string;
    key: string;
  }): Promise<void> {
    try {
      await this.options.db.$client.begin(async (tx) => {
        await execute(tx, sql`
          SELECT pg_advisory_xact_lock(hashtext(${`ovid-share:${input.actorUserId}:${input.artifactId}:${input.versionHash}`}))`);
        await lockUsers(tx, [input.actorUserId]);
        const retired = await retireShareCopyTx(tx, {
          ...input,
          now: this.now(),
        });
        if (retired.cleanup) await this.deleteShareBytes(input.key);
      });
    } catch {
      console.warn("[gateway] immutable share charge is pending reconciliation");
    }
  }

  private async sweepOwner(ownerUserId: string): Promise<void> {
    const stale = await sweepAbandonedStorageReservations(this.options.db, {
      ownerUserId,
      now: this.now(),
      olderThanMs: 3_600_000,
      limit: 100,
    });
    if (this.options.storage === undefined) return;
    for (const row of stale) {
      if (row.objectId === null) continue;
      const [attachment] = await attachments.getForSession(
        this.options.db,
        row.sessionId,
        [row.objectId],
      );
      if (attachment?.userId !== ownerUserId) continue;
      await this.options.storage.delete(attachment.r2Key).catch(() => {
        console.warn("[gateway] abandoned attachment bytes are pending cleanup");
      });
    }
  }

  async reserveUpload(input: ReserveUploadInput): Promise<StorageReservationResult> {
    await this.sweepOwner(input.ownerUserId);
    return this.reservations.reserve({
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

  async reserveArtifact(input: ReserveArtifactInput): Promise<StorageQuotaReservationResult> {
    await this.sweepOwner(input.ownerUserId);
    const result = await this.reservations.reserve({
      reservationId: input.reservationId ?? input.artifactId,
      ownerUserId: input.ownerUserId,
      uploaderUserId: input.actorUserId,
      sessionId: input.sessionId,
      objectId: input.artifactId,
      declaredBytes: input.declaredBytes,
    });
    if (!result.ok && result.scope === "attachment") {
      throw new QuotaContractError("attachment_failed");
    }
    return result;
  }

  finalizeUpload(input: FinalizeUploadInput): Promise<StorageQuotaReservationResult> {
    return this.reservations.finalize({
      reservationId: input.reservationId,
      actualBytes: input.actualBytes,
      contentType: input.actualContentType,
      etag: input.etag,
      attachment: input.attachment,
    });
  }

  async releaseUpload(input: { reservationId: string }): Promise<void> {
    await this.reservations.release(input);
  }

  async storageUsage(ownerUserId: string): Promise<StorageUsage> {
    return reconcileStorageUsage(this.options.db, ownerUserId, this.now());
  }

  async assertUploadFinalized(input: {
    reservationId: string;
    ownerUserId: string;
    actualBytes: number;
  }): Promise<boolean> {
    const found = await this.options.db.$client<{ id: string }[]>`
      SELECT id FROM storage_reservations
       WHERE id = ${input.reservationId} AND object_id = ${input.reservationId}
         AND owner_user_id = ${input.ownerUserId} AND state = 'finalized'
         AND actual_bytes = ${input.actualBytes}
         AND object_id NOT LIKE 'charge:%'
         AND object_id NOT LIKE 'users/%/artifact-shares/%'
       LIMIT 1`;
    return found[0] !== undefined;
  }

  async removeObject(input: { reservationId: string }): Promise<{ removed: boolean; freedBytes: number }> {
    const now = this.now();
    return removeStorageObject(this.options.db, input, { now: () => now });
  }

  /** Copy and charge one deterministic source version, reviving it after zero refs. */
  private async reserveShareCopy(input: {
    actorUserId: string;
    sessionId: string;
    artifactId: string;
    versionHash: string;
    key: string;
    declaredBytes: number;
  }): Promise<string> {
    await reconcileStorageUsage(this.options.db, input.actorUserId, this.now());
    const reservationId = shareChargeId(input.artifactId, input.versionHash);
    const now = this.now();
    await this.options.db.$client.begin(async (tx) => {
      await execute(tx, sql`
        SELECT pg_advisory_xact_lock(hashtext(${`ovid-share:${input.actorUserId}:${input.artifactId}:${input.versionHash}`}))`);
      const tiers = await lockUsers(tx, [input.actorUserId]);
      const existing = await rows<Row>(tx, sql`
        SELECT * FROM storage_reservations WHERE id = ${reservationId} FOR UPDATE`);
      const current = existing[0];
      if (current !== undefined) {
        const unchanged = current.owner_user_id === input.actorUserId &&
          current.actor_user_id === input.actorUserId &&
          current.session_id === input.sessionId &&
          current.object_id === `charge:${input.key}` &&
          Number(current.declared_bytes) === input.declaredBytes;
        if (!unchanged) throw new QuotaContractError("idempotency_conflict");
        if (current.state === "finalized" || current.state === "reserved") return;
        const cap = planStorageBytes(tiers.get(input.actorUserId)!);
        const counter = await rows<{ used_bytes: number | string; reserved_bytes: number | string }>(tx, sql`
          SELECT used_bytes, reserved_bytes FROM storage_usage_counters
           WHERE owner_user_id = ${input.actorUserId} FOR UPDATE`);
        if (Number(counter[0]?.used_bytes ?? 0) + Number(counter[0]?.reserved_bytes ?? 0) + input.declaredBytes > cap) {
          throw new StorageQuotaError("storage_quota_exceeded");
        }
        await execute(tx, sql`
          UPDATE storage_usage_counters
             SET reserved_bytes = reserved_bytes + ${input.declaredBytes},
                 updated_at = ${now.toISOString()}::timestamptz
           WHERE owner_user_id = ${input.actorUserId}`);
        await execute(tx, sql`
          UPDATE storage_reservations
             SET state = 'reserved', actual_bytes = NULL, actual_content_type = NULL,
                 etag = NULL, reserved_at = ${now.toISOString()}::timestamptz,
                 finalized_at = NULL, released_at = NULL,
                 updated_at = ${now.toISOString()}::timestamptz
           WHERE id = ${reservationId}`);
        return;
      }

      const cap = planStorageBytes(tiers.get(input.actorUserId)!);
      await execute(tx, sql`
        INSERT INTO storage_usage_counters (owner_user_id) VALUES (${input.actorUserId})
        ON CONFLICT (owner_user_id) DO NOTHING`);
      const counter = await rows<{ used_bytes: number | string; reserved_bytes: number | string }>(tx, sql`
        SELECT used_bytes, reserved_bytes FROM storage_usage_counters
         WHERE owner_user_id = ${input.actorUserId} FOR UPDATE`);
      if (Number(counter[0]!.used_bytes) + Number(counter[0]!.reserved_bytes) + input.declaredBytes > cap) {
        throw new StorageQuotaError("storage_quota_exceeded");
      }
      await execute(tx, sql`
        INSERT INTO storage_reservations
          (id, actor_user_id, owner_user_id, session_id, object_id, state,
           declared_bytes, reserved_at, created_at, updated_at)
        VALUES
          (${reservationId}, ${input.actorUserId}, ${input.actorUserId}, ${input.sessionId},
           ${`charge:${input.key}`}, 'reserved', ${input.declaredBytes},
           ${now.toISOString()}::timestamptz, ${now.toISOString()}::timestamptz,
           ${now.toISOString()}::timestamptz)`);
      await execute(tx, sql`
        UPDATE storage_usage_counters
           SET reserved_bytes = reserved_bytes + ${input.declaredBytes},
               updated_at = ${now.toISOString()}::timestamptz
         WHERE owner_user_id = ${input.actorUserId}`);
    });
    return reservationId;
  }

  private async copyVersion(sourceKey: string, key: string, input: {
    bytes: number;
    contentType: string;
    versionHash: string;
    metadata: Record<string, string>;
  }): Promise<{ bytes: number; contentType: string | null; etag: string | null }> {
    const storage = this.adapter();
    let head = await storage.head(key);
    if (head === null) {
      if (storage.copy !== undefined) {
        await storage.copy(sourceKey, key);
      } else {
        const body = await storage.get(sourceKey);
        if (body === null) throw new StorageQuotaError("artifact_unavailable");
        await storage.put(key, body, {
          contentType: input.contentType,
          sha256Hex: input.versionHash,
          metadata: input.metadata,
        });
      }
      head = await storage.head(key);
    }
    if (head === null || head.bytes !== input.bytes) {
      throw new StorageQuotaError("artifact_copy_mismatch");
    }
    if (head.sha256Hex === null || head.sha256Hex.toLowerCase() !== input.versionHash) {
      throw new StorageQuotaError("artifact_copy_mismatch");
    }
    return { bytes: head.bytes, contentType: head.contentType ?? null, etag: head.etag };
  }

  async createImmutableShare(input: {
    actorUserId: string;
    artifactId: string;
    displayName: string;
  }): Promise<ImmutableShare> {
    const db = this.options.db;
    const row = await artifactVault.get(db, input.actorUserId, input.artifactId, "generated");
    const canonical = await workspaceObjects.getArtifact(db, input.artifactId, input.actorUserId);
    if (row === null || canonical === null) throw new StorageQuotaError("artifact_not_found");
    const sourceHead = await this.adapter().head(row.r2Key);
    if (sourceHead === null) throw new StorageQuotaError("artifact_unavailable");
    if (sourceHead.bytes !== row.sizeBytes) throw new StorageQuotaError("artifact_incomplete");
    if (sourceHead.sha256Hex === null) {
      throw new StorageQuotaError("artifact_version_unknown");
    }
    if (sourceHead.sha256Hex.toLowerCase() !== canonical.sha256.toLowerCase()) {
      throw new StorageQuotaError("artifact_changed");
    }
    const versionHash = canonical.sha256.toLowerCase();
    if (!/^[a-f0-9]{64}$/.test(versionHash)) throw new StorageQuotaError("artifact_version_unknown");
    const contentType = sanitizeCdnContentType(sourceHead.contentType ?? row.contentType) ?? "application/octet-stream";
    const key = `${sharePrefix(input.actorUserId, input.artifactId)}sha256-${versionHash}/object`;
    const reservationId = await this.reserveShareCopy({
      actorUserId: input.actorUserId,
      sessionId: row.sessionId,
      artifactId: input.artifactId,
      versionHash,
      key,
      declaredBytes: sourceHead.bytes,
    });
    try {
      const copied = await this.copyVersion(row.r2Key, key, {
        bytes: sourceHead.bytes,
        contentType,
        versionHash,
        metadata: sourceHead.metadata,
      });
      const finalized = await this.finalizeUpload({
        reservationId,
        actualBytes: copied.bytes,
        actualContentType: copied.contentType,
        etag: copied.etag,
      });
      if (!finalized.ok) throw new StorageQuotaError("storage_quota_exceeded");
    } catch (error) {
      await this.reconcileUnusedShareCopy({
        actorUserId: input.actorUserId,
        artifactId: input.artifactId,
        versionHash,
        key,
      });
      throw error;
    }

    const grantId = newId();
    const now = this.now();
    try {
      await db.$client.begin(async (tx) => {
        await execute(tx, sql`
          SELECT pg_advisory_xact_lock(hashtext(${`ovid-share:${input.actorUserId}:${input.artifactId}:${versionHash}`}))`);
        const source = await rows<{ status: string }>(tx, sql`
          SELECT status FROM workspace_objects
           WHERE id = ${input.artifactId} AND user_id = ${input.actorUserId}
             AND kind = 'artifact' FOR UPDATE`);
        if (source[0]?.status !== "active") throw new StorageQuotaError("artifact_not_found");
        const charge = await rows<{ state: string }>(tx, sql`
          SELECT state FROM storage_reservations WHERE id = ${reservationId} FOR UPDATE`);
        if (charge[0]?.state !== "finalized") throw new StorageQuotaError("artifact_copy_not_finalized");
        await execute(tx, sql`
          INSERT INTO storage_reservations
            (id, actor_user_id, owner_user_id, session_id, object_id, state,
             declared_bytes, actual_bytes, actual_content_type, etag,
             reserved_at, finalized_at, created_at, updated_at)
          VALUES
            (${grantId}, ${input.actorUserId}, ${input.actorUserId}, ${row.sessionId}, ${key},
             'finalized', 0, 0, ${contentType}, ${versionHash},
             ${now.toISOString()}::timestamptz, ${now.toISOString()}::timestamptz,
             ${now.toISOString()}::timestamptz, ${now.toISOString()}::timestamptz)`);
      });
    } catch (error) {
      // A failed final grant insert must not strand an unreferenced charged
      // copy. Existing independent grants, if any, keep both charge and bytes.
      await this.reconcileUnusedShareCopy({
        actorUserId: input.actorUserId,
        artifactId: input.artifactId,
        versionHash,
        key,
      });
      throw error;
    }
    return {
      grantId,
      displayName: input.displayName.trim() === "" ? row.name : input.displayName,
      key,
      versionHash,
      cacheClass: "immutable",
      disposition: isActiveCdnContentType(contentType) ? "attachment" : "inline",
      contentType,
      sizeBytes: sourceHead.bytes,
    };
  }

  async assertActive(grantId: string, versionHash: string): Promise<boolean> {
    if (!/^[A-Za-z0-9_-]{1,128}$/.test(grantId) || !/^[a-f0-9]{64}$/i.test(versionHash)) return false;
    const normalizedVersionHash = versionHash.toLowerCase();
    const found = await this.options.db.$client<{
      object_id: string | null;
      owner_user_id: string;
      actor_user_id: string;
    }[]>`
      SELECT object_id, owner_user_id, actor_user_id FROM storage_reservations
       WHERE id = ${grantId} AND declared_bytes = 0 AND actual_bytes = 0
         AND etag = ${normalizedVersionHash} LIMIT 1`;
    const grant = found[0];
    const parsed = parseShareKey(grant?.object_id);
    if (grant === undefined || parsed === null ||
        grant.owner_user_id !== grant.actor_user_id ||
        parsed.versionHash !== normalizedVersionHash) return false;
    // A grant is live only while both its independent reference and the real
    // charged copy are live. This single statement fences grant and charge in
    // one READ COMMITTED snapshot before any edge cache lookup.
    const chargeId = shareChargeId(parsed.artifactId, parsed.versionHash);
    const key = String(grant.object_id);
    const active = await this.options.db.$client<{ id: string }[]>`
      SELECT g.id FROM storage_reservations g
       INNER JOIN storage_reservations c ON c.id = ${chargeId}
       WHERE g.id = ${grantId} AND g.state = 'finalized'
         AND g.declared_bytes = 0 AND g.actual_bytes = 0
         AND g.object_id = ${key} AND g.etag = ${normalizedVersionHash}
         AND c.state = 'finalized' AND c.object_id = ${`charge:${key}`}
         AND c.actual_bytes IS NOT NULL
       LIMIT 1`;
    return active[0] !== undefined;
  }

  async revokeImmutableShare(input: {
    actorUserId: string;
    grantId: string;
  }): Promise<{ revoked: boolean; objectRemoved: boolean }> {
    const now = this.now();
    const outcome = await this.options.db.$client.begin(async (tx) => {
      const identity = await rows<{ owner_user_id: string; actor_user_id: string }>(tx, sql`
        SELECT owner_user_id, actor_user_id FROM storage_reservations
         WHERE id = ${input.grantId} LIMIT 1`);
      if (identity[0]?.owner_user_id !== input.actorUserId ||
          identity[0].actor_user_id !== input.actorUserId) {
        return { revoked: false, objectRemoved: false };
      }
      const found = await rows<Row>(tx, sql`
        SELECT * FROM storage_reservations WHERE id = ${input.grantId} FOR UPDATE`);
      const grant = found[0]!;
      const parsed = parseShareKey(grant.object_id);
      if (parsed === null || Number(grant.declared_bytes) !== 0 ||
          (grant.state === "finalized" && Number(grant.actual_bytes) !== 0) ||
          typeof grant.etag !== "string" || grant.etag.toLowerCase() !== parsed.versionHash) {
        return { revoked: false, objectRemoved: false };
      }
      const key = String(grant.object_id);
      // Share creation takes this same lock before checking source/charge and
      // inserting a grant. A last-reference decision is therefore serialized
      // with every new reference to this exact frozen object.
      await execute(tx, sql`
        SELECT pg_advisory_xact_lock(hashtext(${`ovid-share:${input.actorUserId}:${parsed.artifactId}:${parsed.versionHash}`}))`);
      await lockUsers(tx, [input.actorUserId]);
      const revoked = grant.state === "finalized";
      if (revoked) {
        await execute(tx, sql`
          UPDATE storage_reservations
             SET state = 'released', actual_bytes = NULL, finalized_at = NULL,
                 released_at = ${now.toISOString()}::timestamptz,
                 updated_at = ${now.toISOString()}::timestamptz
           WHERE id = ${input.grantId}`);
      } else if (grant.state !== "released") {
        throw new QuotaContractError("invalid_reservation_state");
      }
      const retired = await retireShareCopyTx(tx, {
        actorUserId: input.actorUserId,
        artifactId: parsed.artifactId,
        versionHash: parsed.versionHash,
        key,
        now,
      });
      let objectRemoved = retired.removed;
      // Keep the per-share advisory lock through physical deletion. A revive
      // waits for this transaction and therefore cannot get a live grant to a
      // key that the old generation is still deleting.
      if (retired.cleanup && !(await this.deleteShareBytes(key))) objectRemoved = false;
      return { revoked, objectRemoved };
    });
    return { revoked: outcome.revoked, objectRemoved: outcome.objectRemoved };
  }

  /** Deleting a source synchronously closes every dependent grant before bytes go. */
  async revokeArtifactShares(actorUserId: string, artifactId: string): Promise<void> {
    const prefix = sharePrefix(actorUserId, artifactId);
    const grants = await this.options.db.$client<{ id: string }[]>`
      SELECT id FROM storage_reservations
       WHERE owner_user_id = ${actorUserId}
         AND state IN ('finalized', 'released')
         AND (actual_bytes = 0 OR actual_bytes IS NULL)
         AND strpos(object_id, ${prefix}) = 1
       ORDER BY id`;
    for (const grant of grants) {
      await this.revokeImmutableShare({ actorUserId, grantId: grant.id });
    }
  }
}
