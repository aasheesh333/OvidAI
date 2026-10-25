/**
 * Artifacts pipeline (P7 Task 9) — one call turns a workspace file (or a
 * Buffer) into a durable R2 object + a `workspace_objects` row + an
 * `artifact_created` event carrying a presigned download URL.
 *
 * The digest is computed HERE and supplied to `storage.put`: R2's HEAD never
 * returns an object hash (multipart ETags are not hashes — the Task-2 carry),
 * so the uploader is the only source of truth for the ledger row. For a
 * `sourcePath` the file is hashed in one streaming pass and uploaded in a
 * second streaming pass — no whole-file buffering.
 *
 * The URL is deliberately never logged: it is a bearer capability for the
 * artifact until `expiresAt`. Publication is disabled unless the composition
 * injects the actual-byte reservation service; CDN additionally needs a grant.
 */

import { createHash, randomBytes } from "node:crypto";
import { createReadStream } from "node:fs";
import { DEFAULT_PRESIGN_TTL_SECONDS, signInternalRequest } from "@ovid/shared";

import type { StorageAdapter } from "./adapter.js";
import {
  isActiveCdnContentType,
  mintCdnUrl,
  sanitizeCdnContentType,
  type CdnConfig,
  type CdnDisposition,
} from "./cdn.js";
import { StorageError } from "./errors.js";
import { contentTypeFor, type HydrateDbLike, type HydrateEventLog } from "./hydrate.js";
import { r2Keys } from "./keys.js";

// ---------------------------------------------------------------------------
// Structural mirrors of the @ovid/db surface (exact signatures)
// ---------------------------------------------------------------------------

/** Mirror of @ovid/db's `workspaceObjects.registerArtifact`. */
export interface ArtifactWorkspaceObjectsRepo {
  registerArtifact(
    db: HydrateDbLike,
    i: {
      id: string;
      userId: string;
      sessionId: string;
      r2Key: string;
      bytes: number;
      sha256: string;
      contentType: string;
      meta: { name: string };
    },
  ): Promise<unknown>;
}

/** Mirror of @ovid/db's `eventMirror.put`. */
export interface ArtifactEventMirror {
  put(db: HydrateDbLike, e: Awaited<ReturnType<HydrateEventLog["append"]>>): Promise<void>;
}

export type ArtifactQuotaResult =
  | { ok: true; reservationId: string }
  | { ok: false; scope: "upload" | "storage"; resetsAt: Date | null };

/** Structural gateway/DB reservation seam; @ovid/storage has no DB dependency. */
export interface ArtifactQuota {
  reserveArtifact(input: {
    actorUserId: string;
    ownerUserId: string;
    sessionId: string;
    artifactId: string;
    declaredBytes: number;
  }): Promise<ArtifactQuotaResult>;
  finalizeUpload(input: {
    reservationId: string;
    actualBytes: number;
    actualContentType: string | null;
    etag: string | null;
  }): Promise<ArtifactQuotaResult>;
  releaseUpload(input: { reservationId: string }): Promise<void>;
  removeObject(input: { reservationId: string }): Promise<{ removed: boolean; freedBytes: number }>;
}

export interface ArtifactGrantFactoryInput {
  actorUserId: string;
  artifactId: string;
  sessionId: string;
  displayName: string;
  sizeBytes: number;
  key: string;
  versionHash: string;
  contentType: string;
  disposition: CdnDisposition;
}

export type ArtifactGrantFactory = (
  input: ArtifactGrantFactoryInput,
) => Promise<{ grantId: string; key: string }>;

export const ARTIFACT_GRANT_CREATE_PATH = "/internal/cdn-grants";

/** Signed gateway grant creation for every worker artifact publisher. */
export function createHttpArtifactGrantFactory(options: {
  /** Null/empty is a typed unavailable outcome when CDN publication is attempted. */
  baseUrl: string | null;
  secret: string;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
  now?: () => number;
}): ArtifactGrantFactory {
  const fetchImpl = options.fetchImpl ?? fetch;
  const timeoutMs = options.timeoutMs ?? 5_000;
  const now = options.now ?? (() => Date.now());
  return async (input) => {
    if ((options.baseUrl ?? "").trim() === "") {
      throw new StorageError("artifact grant service base URL is not configured", {
        code: "cdn_grant_not_configured",
      });
    }
    if (Buffer.byteLength(options.secret, "utf8") < 32) {
      throw new StorageError("artifact grant service requires a 32-byte secret", {
        code: "cdn_grant_not_configured",
      });
    }
    try {
      const url = new URL(ARTIFACT_GRANT_CREATE_PATH, options.baseUrl!);
      const timestamp = Math.floor(now() / 1000);
      const response = await fetchImpl(url, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "X-Ovid-Timestamp": Buffer.from(String(timestamp)).toString("base64"),
          "X-Ovid-Signature": signInternalRequest(
            options.secret,
            "POST",
            ARTIFACT_GRANT_CREATE_PATH,
            `${input.actorUserId}:${input.artifactId}`,
            timestamp,
          ),
        },
        body: JSON.stringify({
          actorUserId: input.actorUserId,
          artifactId: input.artifactId,
          displayName: input.displayName,
        }),
        signal: AbortSignal.timeout(timeoutMs),
      });
      if (!response.ok) {
        throw new StorageError(`artifact grant creation failed with HTTP ${response.status}`, {
          code: "cdn_grant_unavailable",
        });
      }
      const body = await response.json() as { grantId?: unknown; key?: unknown };
      if (typeof body.grantId !== "string" || typeof body.key !== "string") {
        throw new StorageError("artifact grant creation returned an invalid response", {
          code: "cdn_grant_unavailable",
        });
      }
      return { grantId: body.grantId, key: body.key };
    } catch (error) {
      if (error instanceof StorageError) throw error;
      throw new StorageError("artifact grant service is unavailable", {
        code: "cdn_grant_unavailable",
        cause: error,
      });
    }
  };
}

export type ArtifactProjectCapacity = (
  db: HydrateDbLike,
  userId: string,
  sessionId: string,
  additional?: number,
) => Promise<unknown>;

export interface ArtifactDeps {
  db: HydrateDbLike;
  events: HydrateEventLog;
  storage: StorageAdapter;
  /** Default DEFAULT_PRESIGN_TTL_SECONDS (3600). */
  presignTtlSeconds?: number;
  /**
   * W12: with grantFactory, artifact_created carries a grant-backed signed
   * CDN URL for this immutable version. Without either dependency the existing
   * short presign path is unchanged; CDN config alone never mints a URL.
   */
  cdn?: CdnConfig;
  /** Absent CDN/grant service => legacy short presign, never a grantless CDN URL. */
  grantFactory?: ArtifactGrantFactory;
  /** Required for publication; absence is a loud disabled outcome, never a bypass. */
  quota?: ArtifactQuota;
  /** Refuse before reservation/PUT/finalization; absent is typed unavailable. */
  assertProjectFileCapacity?: ArtifactProjectCapacity;
  clock?: () => Date;
  /** The real @ovid/db repo namespaces, injected by the wiring layer. */
  workspaceObjects: ArtifactWorkspaceObjectsRepo;
  eventMirror: ArtifactEventMirror;
}

export interface ArtifactInput {
  userId: string;
  /** Host/owner defaults to legacy userId; actor defaults to owner. */
  ownerUserId?: string;
  actorUserId?: string;
  sessionId: string;
  name: string;
  contentType?: string;
  /** Exactly one of sourcePath | content. */
  sourcePath?: string;
  content?: Buffer;
}

export interface ArtifactRecord {
  id: string;
  key: string;
  sizeBytes: number;
  sha256Hex: string;
  contentType: string;
  url: string;
  expiresAt: string;
}

// ---------------------------------------------------------------------------
// UUIDv7 — the artifact id IS the keyset cursor, so ids must be time-ordered.
// A local implementation keeps @ovid/storage free of a uuid dependency; the
// 12-bit rand_a field is a monotonic counter within one millisecond so ids
// created in the same tick still sort in creation order.
// ---------------------------------------------------------------------------

let lastMs = -1;
let seq = 0;

function newArtifactId(nowMs: number): string {
  const ms = Math.floor(nowMs);
  if (ms === lastMs) {
    seq = (seq + 1) & 0x0fff;
  } else {
    lastMs = ms;
    // randomInt's max is exclusive: 0..0x0fff
    seq = randomBytes(2).readUInt16BE(0) & 0x0fff;
  }
  const b = Buffer.alloc(16);
  b.writeUIntBE(ms % 0x1000000000000, 0, 6); // 48-bit unix ms, big-endian
  b[6] = 0x70 | ((seq >> 8) & 0x0f); // version 7 + rand_a high nibble
  b[7] = seq & 0xff; // rand_a low byte
  const rest = randomBytes(8);
  b[8] = 0x80 | (rest[0]! & 0x3f); // RFC 4122 variant + rand_b
  rest.copy(b, 9, 1, 8);
  const hex = b.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

function sha256Hex(buf: Buffer): string {
  return createHash("sha256").update(buf).digest("hex");
}

/** One streaming pass over a file: exact byte count + sha256. */
async function hashFile(path: string): Promise<{ sizeBytes: number; sha256Hex: string }> {
  const hash = createHash("sha256");
  let sizeBytes = 0;
  for await (const chunk of createReadStream(path)) {
    const buf = chunk as Buffer;
    hash.update(buf);
    sizeBytes += buf.length;
  }
  return { sizeBytes, sha256Hex: hash.digest("hex") };
}

// ---------------------------------------------------------------------------
// registerArtifact
// ---------------------------------------------------------------------------

export async function registerArtifact(
  deps: ArtifactDeps,
  input: ArtifactInput,
): Promise<ArtifactRecord> {
  const hasSource = input.sourcePath !== undefined;
  const hasContent = input.content !== undefined;
  if (hasSource === hasContent) {
    throw new StorageError(
      "registerArtifact requires exactly one of sourcePath | content",
      { code: "invalid_arg" },
    );
  }

  if (deps.quota === undefined || deps.assertProjectFileCapacity === undefined) {
    // Production composition must inject the real quota and project-capacity
    // services. Until then publication is explicitly disabled instead of
    // creating an unreserved or over-project-cap object/row.
    throw new StorageError("artifact storage quota is not configured", {
      code: "storage_quota_not_configured",
    });
  }

  const assertProjectFileCapacity = deps.assertProjectFileCapacity;
  const clock = deps.clock ?? (() => new Date());
  const at = clock();
  const ttlSeconds = deps.presignTtlSeconds ?? DEFAULT_PRESIGN_TTL_SECONDS;
  let contentType = input.contentType ?? contentTypeFor(input.name);
  const ownerUserId = input.ownerUserId ?? input.userId;
  const actorUserId = input.actorUserId ?? ownerUserId;

  const id = newArtifactId(at.getTime());
  let reserved = false;
  let finalized = false;
  let rowRegistered = false;

  async function reserveBytes(): Promise<void> {
    if (deps.quota === undefined) return;
    const reservation = await deps.quota.reserveArtifact({
      actorUserId,
      ownerUserId,
      sessionId: input.sessionId,
      artifactId: id,
      declaredBytes: sizeBytes,
    });
    if (!reservation.ok) {
      throw new StorageError(
        reservation.scope === "upload" ? "upload_limit_reached" : "storage_quota_exceeded",
        { code: reservation.scope === "upload" ? "upload_limit_reached" : "storage_quota_exceeded" },
      );
    }
    reserved = true;
  }

  async function finalizeBytes(key: string): Promise<void> {
    if (deps.quota === undefined) return;
    const head = await deps.storage.head(key);
    if (head === null) {
      throw new StorageError("stored artifact has no HEAD metadata", { code: "artifact_unavailable" });
    }
    // Actual storage metadata, not the declaration or source-file stat, is the
    // billing evidence. Keep the row and counter on that same byte count.
    sizeBytes = head.bytes;
    contentType = sanitizeCdnContentType(head.contentType ?? undefined) ?? contentType;
    const settled = await deps.quota.finalizeUpload({
      reservationId: id,
      actualBytes: head.bytes,
      actualContentType: head.contentType ?? null,
      etag: head.etag,
    });
    if (!settled.ok) {
      throw new StorageError(
        settled.scope === "upload" ? "upload_limit_reached" : "storage_quota_exceeded",
        { code: settled.scope === "upload" ? "upload_limit_reached" : "storage_quota_exceeded" },
      );
    }
    finalized = true;
  }

  async function cleanupUnregistered(key: string): Promise<void> {
    if (deps.quota === undefined || rowRegistered) return;
    if (finalized) {
      await deps.quota.removeObject({ reservationId: id });
    } else if (reserved) {
      await deps.quota.releaseUpload({ reservationId: id });
    }
    await deps.storage.delete(key).catch(() => {});
  }

  let sizeBytes: number;
  let sha256: string;
  if (hasContent) {
    const content = input.content!;
    sizeBytes = content.length;
    sha256 = sha256Hex(content);
    // W12: the key is content-addressed AND unique (id) — see r2Keys.
    const key = r2Keys.contentAddressedArtifact(
      ownerUserId,
      input.sessionId,
      id,
      sha256,
      input.name,
    );
    await assertProjectFileCapacity(deps.db, ownerUserId, input.sessionId, 1);
    await reserveBytes();
    try {
      const put = await deps.storage.put(key, content, { contentType, sha256Hex: sha256 });
      if (put.bytes !== sizeBytes) {
        throw new StorageError(
          `storage.put counted ${put.bytes} bytes for ${key} but the content is ${sizeBytes}`,
          { code: "artifact_length_mismatch" },
        );
      }
      await finalizeBytes(key);
      return await finish(key);
    } catch (error) {
      await cleanupUnregistered(key);
      throw error;
    }
  }

  const sourcePath = input.sourcePath!;
  ({ sizeBytes, sha256Hex: sha256 } = await hashFile(sourcePath));
  const key = r2Keys.contentAddressedArtifact(
    ownerUserId,
    input.sessionId,
    id,
    sha256,
    input.name,
  );
  await assertProjectFileCapacity(deps.db, ownerUserId, input.sessionId, 1);
  await reserveBytes();
  try {
    const put = await deps.storage.put(key, createReadStream(sourcePath), {
      contentType,
      sha256Hex: sha256,
    });
    if (put.bytes !== sizeBytes) {
      throw new StorageError(
        `storage.put counted ${put.bytes} bytes for ${key} but the file is ${sizeBytes}`,
        { code: "artifact_length_mismatch" },
      );
    }
    await finalizeBytes(key);
    return await finish(key);
  } catch (error) {
    await cleanupUnregistered(key);
    throw error;
  }

  /** Row + event + capability once the object is stored. */
  async function finish(key: string): Promise<ArtifactRecord> {
    await deps.workspaceObjects.registerArtifact(deps.db, {
      id,
      userId: ownerUserId,
      sessionId: input.sessionId,
      r2Key: key,
      bytes: sizeBytes,
      sha256,
      contentType,
      meta: { name: input.name },
    });
    rowRegistered = true;

    // Prefer CDN only when a durable grant can be created for this exact
    // version. CDN configuration alone is insufficient: absent grant service
    // keeps the legacy short-presign path and never emits a grantless v1 URL.
    let url: string;
    let expiresAt: string;
    if (deps.cdn !== undefined && deps.grantFactory !== undefined) {
      const disposition = isActiveCdnContentType(sanitizeCdnContentType(contentType))
        ? "attachment"
        : "inline";
      const grant = await deps.grantFactory({
        actorUserId,
        artifactId: id,
        sessionId: input.sessionId,
        displayName: input.name,
        sizeBytes,
        key,
        versionHash: sha256,
        contentType,
        disposition,
      });
      const minted = mintCdnUrl(deps.cdn, {
        key: grant.key,
        filename: input.name,
        contentType,
        disposition,
        grantId: grant.grantId,
        versionHash: sha256,
        now: at,
      });
      url = minted.url;
      expiresAt = minted.expiresAt;
    } else {
      const active = isActiveCdnContentType(sanitizeCdnContentType(contentType));
      url = await deps.storage.presignGet(
        key,
        ttlSeconds,
        active
          ? { disposition: "attachment", filename: input.name, contentType }
          : undefined,
      );
      expiresAt = new Date(at.getTime() + ttlSeconds * 1000).toISOString();
    }

    const event = await deps.events.append(input.sessionId, "artifact_created", {
      artifactId: id,
      name: input.name,
      sessionId: input.sessionId,
      sizeBytes,
      contentType,
      url,
      expiresAt,
    });
    await deps.eventMirror.put(deps.db, event);

    // NEVER log `url` — it is a bearer capability until expiresAt.
    return { id, key, sizeBytes, sha256Hex: sha256, contentType, url, expiresAt };
  }
}
