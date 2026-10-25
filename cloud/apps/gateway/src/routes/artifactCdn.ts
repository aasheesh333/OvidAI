import type { FastifyInstance, FastifyReply } from "fastify";
import { z } from "zod";
import { artifactVault, attachments, sessions, type ArtifactVaultOrigin, type Db } from "@ovid/db";
import {
  contentTypeFor,
  isActiveCdnContentType,
  mintCdnUrl,
  sanitizeCdnContentType,
  type HeadResult,
  type StorageAdapter,
} from "@ovid/storage";
import { DEFAULT_PRESIGN_TTL_SECONDS, verifyInternalRequest } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { StorageQuota, StorageQuotaError } from "../storageQuota.js";
import { isUuid, notFound, queryValue, sendError, zodBadRequest } from "./http.js";

/**
 * Immutable objects may use CDN only through a frozen copy and a durable
 * grant. Mutable uploads/attachments always keep the existing short presign
 * path, even when a caller asks for a CDN URL or attempts a cache-class upgrade.
 */

const SOURCES: readonly ArtifactVaultOrigin[] = ["generated", "uploaded"];
export const CDN_GRANT_ASSERT_PATH = "/internal/cdn-grants/assert-active";
export const CDN_GRANT_CREATE_PATH = "/internal/cdn-grants";

function cdnError(reply: FastifyReply, status: number, code: string, message: string): FastifyReply {
  return sendError(reply, status, code, message)
    .header("cache-control", "private, no-store")
    .header("pragma", "no-cache");
}

function wantsDownload(query: Record<string, string | string[] | undefined>): boolean {
  const raw = queryValue(query.download) ?? queryValue(query.disposition);
  return raw === "1" || raw === "true" || raw === "attachment";
}

function downloadContentType(name: string): string {
  const extension = name.toLowerCase().split(".").pop();
  if (extension === "svg") return "image/svg+xml";
  if (extension === "xml") return "application/xml";
  if (extension === "xhtml") return "application/xhtml+xml";
  return contentTypeFor(name);
}

/** Shared HEAD proof: missing object → 404, wrong size → 409, throw → 503. */
async function verifyObject(
  deps: GatewayDeps,
  reply: FastifyReply,
  r2Key: string,
  expectedBytes: number,
): Promise<{ ok: true; head: HeadResult } | { ok: false; reply: FastifyReply }> {
  let head;
  try {
    head = await deps.storage!.head(r2Key);
  } catch (e) {
    console.warn("[gateway] cdn HEAD failed", { error: String(e) });
    return { ok: false, reply: cdnError(reply, 503, "artifact_storage_unavailable", "Ovid Cloud storage could not be reached. Try again shortly.") };
  }
  if (head === null) {
    return { ok: false, reply: cdnError(reply, 404, "artifact_unavailable", "This file is no longer available in Ovid Cloud.") };
  }
  if (head.bytes !== expectedBytes) {
    return { ok: false, reply: cdnError(reply, 409, "artifact_incomplete", "This file did not finish uploading. Remove and re-attach it.") };
  }
  return { ok: true, head };
}

async function shortUrl(
  deps: GatewayDeps,
  input: { key: string; filename: string; contentType: string; disposition: "inline" | "attachment" },
) {
  const contentType = sanitizeCdnContentType(input.contentType) ?? "application/octet-stream";
  const disposition = isActiveCdnContentType(contentType) ? "attachment" : input.disposition;
  const ttlSeconds = deps.presignTtlSeconds ?? DEFAULT_PRESIGN_TTL_SECONDS;
  const url = await deps.storage!.presignGet(
    input.key,
    ttlSeconds,
    disposition === "attachment"
      ? { disposition, filename: input.filename, contentType }
      : undefined,
  );
  const now = deps.clock?.() ?? new Date();
  return {
    url,
    expiresAt: new Date(now.getTime() + ttlSeconds * 1000).toISOString(),
    cacheClass: "short" as const,
    disposition,
    contentType,
  };
}

function shareFailure(reply: FastifyReply, error: unknown): FastifyReply {
  if (!(error instanceof StorageQuotaError)) throw error;
  switch (error.code) {
    case "artifact_not_found":
      return cdnError(reply, 404, "not_found", "Artifact not found.");
    case "artifact_unavailable":
      return cdnError(reply, 404, "artifact_unavailable", "This file is no longer available in Ovid Cloud.");
    case "artifact_incomplete":
    case "artifact_copy_mismatch":
      return cdnError(reply, 409, "artifact_incomplete", "This file did not finish uploading. Remove and re-attach it.");
    case "storage_quota_exceeded":
      return cdnError(reply, 409, "storage_quota_exceeded", "The storage allowance for this plan is exhausted.");
    default:
      return cdnError(reply, 409, "artifact_changed", "The artifact changed before its immutable share could be created.");
  }
}

export function registerArtifactCdnRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  const quota = new StorageQuota({ db: deps.db, storage: deps.storage, now: deps.clock });

  app.get("/artifacts/:id/cdn-url", async (request, reply) => {
    const { id } = request.params as { id: string };
    const { uid } = request.principal;
    const query = request.query as Record<string, string | string[] | undefined>;
    if (!isUuid(id)) return cdnError(reply, 404, "not_found", "Artifact not found.");
    const origin = SOURCES.find((s) => s === queryValue(query.source));
    if (origin === undefined) {
      return sendError(reply, 400, "bad_request", "source must be 'generated' or 'uploaded'.");
    }
    if (deps.storage === undefined) {
      return cdnError(reply, 503, "storage_not_configured", "Artifact downloads are not configured on this deployment.");
    }

    const row = await artifactVault.get(deps.db, uid, id, origin);
    if (row === null) return cdnError(reply, 404, "not_found", "Artifact not found.");

    // Mutable objects never enter the grant/CDN path, regardless of CDN config.
    if (origin === "uploaded") {
      const verified = await verifyObject(deps, reply, row.r2Key, row.sizeBytes);
      if (!verified.ok) return verified.reply;
      const body = await shortUrl(deps, {
        key: row.r2Key,
        filename: row.name,
        contentType: verified.head.contentType ?? downloadContentType(row.name),
        disposition: wantsDownload(query) ? "attachment" : "inline",
      });
      return reply.header("cache-control", "private, no-store").header("pragma", "no-cache").send(body);
    }

    const cdn = deps.cdn;
    if (cdn === undefined) {
      return cdnError(reply, 503, "cdn_not_configured", "CDN downloads are not configured on this deployment.");
    }
    if (Buffer.byteLength((cdn.grantInternalSecret ?? "").trim(), "utf8") < 32) {
      return cdnError(reply, 503, "cdn_grant_not_configured", "Revocable CDN grants are not configured on this deployment.");
    }

    try {
      const share = await quota.createImmutableShare({
        actorUserId: uid,
        artifactId: id,
        displayName: row.name,
      });
      const disposition = wantsDownload(query) ? "attachment" : share.disposition;
      const minted = mintCdnUrl(cdn, {
        key: share.key,
        filename: share.displayName,
        contentType: share.contentType,
        disposition,
        grantId: share.grantId,
        versionHash: share.versionHash,
        now: deps.clock?.() ?? new Date(),
      });
      return reply.header("cache-control", "private, no-store").header("pragma", "no-cache").send({
        url: minted.url,
        expiresAt: minted.expiresAt,
        cacheClass: minted.cacheClass,
        grantId: share.grantId,
        versionHash: share.versionHash,
        disposition,
        contentType: share.contentType,
      });
    } catch (error) {
      if (error instanceof StorageQuotaError) return shareFailure(reply, error);
      console.warn("[gateway] immutable artifact share failed", { error: String(error) });
      return cdnError(reply, 503, "artifact_storage_unavailable", "Ovid Cloud storage could not be reached. Try again shortly.");
    }
  });

  app.delete("/artifact-shares/:grantId", async (request, reply) => {
    const { grantId } = request.params as { grantId: string };
    const { uid } = request.principal;
    if (!isUuid(grantId)) return cdnError(reply, 404, "not_found", "Artifact share not found.");
    const result = await quota.revokeImmutableShare({ actorUserId: uid, grantId });
    return reply.header("cache-control", "private, no-store").send(result);
  });

  app.get("/sessions/:id/attachments/:attachmentId/cdn-url", async (request, reply) => {
    const { id: sessionId, attachmentId } = request.params as { id: string; attachmentId: string };
    const { uid } = request.principal;
    const query = request.query as Record<string, string | string[] | undefined>;
    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);
    if (!isUuid(attachmentId)) return cdnError(reply, 404, "not_found", "File not found.");
    const [row] = await attachments.getForSession(deps.db, sessionId, [attachmentId]);
    if (row === undefined || row.userId !== uid) return cdnError(reply, 404, "not_found", "File not found.");
    // Ready status alone is insufficient: the reservation must still be live
    // for exactly these actual bytes. Released/failed/late-PUT objects never mint.
    const actualBytes = row.actualBytes;
    if (row.uploadStatus !== "ready" || actualBytes === null ||
        !(await quota.assertUploadFinalized({
          reservationId: attachmentId,
          ownerUserId: uid,
          actualBytes,
        }))) {
      return cdnError(reply, 404, "artifact_unavailable", "This file is not available for download.");
    }
    if (deps.storage === undefined) {
      return cdnError(reply, 503, "storage_not_configured", "File downloads are not configured on this deployment.");
    }

    const verified = await verifyObject(deps, reply, row.r2Key, actualBytes);
    if (!verified.ok) return verified.reply;
    const body = await shortUrl(deps, {
      key: row.r2Key,
      filename: row.name,
      contentType: verified.head.contentType ?? row.actualContentType ?? downloadContentType(row.name),
      disposition: wantsDownload(query) ? "attachment" : "inline",
    });
    return reply.header("cache-control", "private, no-store").header("pragma", "no-cache").send(body);
  });
}

export interface CdnGrantRouteDeps {
  db: Db;
  cdnGrantSecret: string;
  storage?: StorageAdapter;
  clock?: () => Date;
}

const grantCheckBody = z.object({
  grantId: z.string().regex(/^[A-Za-z0-9_-]{1,128}$/),
  versionHash: z.string().regex(/^[a-f0-9]{64}$/i),
}).strict();

const grantCreateBody = z.object({
  actorUserId: z.string().min(1).max(256),
  artifactId: z.string().uuid(),
  displayName: z.string().min(1).max(255),
}).strict();

/**
 * Register this on the gateway's root/internal listener, OUTSIDE user auth.
 * The only credential is the signed service request; grant ids are never user
 * authorization tokens and no object key or URL crosses this route.
 */
export function registerCdnGrantRoutes(app: FastifyInstance, deps: CdnGrantRouteDeps): void {
  if (Buffer.byteLength(deps.cdnGrantSecret, "utf8") < 32) {
    throw new Error("cdnGrantSecret must be at least 32 bytes");
  }
  const quota = new StorageQuota({ db: deps.db, storage: deps.storage, now: deps.clock });

  app.post(CDN_GRANT_CREATE_PATH, async (request, reply) => {
    const parsed = grantCreateBody.safeParse(request.body ?? undefined);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const timestamp = request.headers["x-ovid-timestamp"];
    const signature = request.headers["x-ovid-signature"];
    const now = Math.floor((deps.clock?.() ?? new Date()).getTime() / 1000);
    if (typeof timestamp !== "string" || typeof signature !== "string" ||
        !verifyInternalRequest(
          deps.cdnGrantSecret,
          "POST",
          CDN_GRANT_CREATE_PATH,
          `${parsed.data.actorUserId}:${parsed.data.artifactId}`,
          timestamp,
          signature,
          now,
        )) {
      return cdnError(reply, 403, "forbidden", "The internal grant request could not be verified.");
    }
    if (deps.storage === undefined) {
      return cdnError(reply, 503, "storage_not_configured", "Artifact storage is not configured.");
    }
    try {
      const share = await quota.createImmutableShare(parsed.data);
      return reply.header("cache-control", "no-store").code(201).send(share);
    } catch (error) {
      if (error instanceof StorageQuotaError) return shareFailure(reply, error);
      return cdnError(reply, 503, "cdn_grant_unavailable", "The artifact grant could not be created.");
    }
  });

  app.post(CDN_GRANT_ASSERT_PATH, async (request, reply) => {
    const parsed = grantCheckBody.safeParse(request.body ?? undefined);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const timestamp = request.headers["x-ovid-timestamp"];
    const signature = request.headers["x-ovid-signature"];
    const now = Math.floor((deps.clock?.() ?? new Date()).getTime() / 1000);
    if (typeof timestamp !== "string" || typeof signature !== "string" ||
        !verifyInternalRequest(
          deps.cdnGrantSecret,
          "POST",
          CDN_GRANT_ASSERT_PATH,
          `${parsed.data.grantId}:${parsed.data.versionHash}`,
          timestamp,
          signature,
          now,
        )) {
      return cdnError(reply, 403, "forbidden", "The internal grant request could not be verified.");
    }
    const active = await quota.assertActive(parsed.data.grantId, parsed.data.versionHash);
    return reply.header("cache-control", "no-store").send({ active });
  });
}
