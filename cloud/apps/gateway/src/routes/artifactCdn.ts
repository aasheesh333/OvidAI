import type { FastifyInstance, FastifyReply } from "fastify";
import { artifactVault, attachments, sessions, type ArtifactVaultOrigin } from "@ovid/db";
import { contentTypeFor, mintCdnUrl } from "@ovid/storage";
import type { GatewayDeps } from "../app.js";
import { isUuid, notFound, queryValue, sendError } from "./http.js";

/**
 * W12 — signed-token CDN URLs (additive to the canonical presign mint).
 *
 *   GET /artifacts/:id/cdn-url?source=generated|uploaded[&download=1]
 *   GET /sessions/:id/attachments/:attachmentId/cdn-url[&download=1]
 *
 * These routes do NOT replace GET /artifacts/:id/url. They reuse the SAME
 * ownership/type/status validation (`artifactVault.get`) and the SAME single
 * HEAD availability proof, then mint a Worker capability instead of a
 * presigned S3 GET. A deployment without OVID_CDN_* answers the typed 503
 * `cdn_not_configured`; the client falls back to the canonical mint, so CDN
 * rollout never breaks artifact access.
 *
 * Cache safety: the URL is a bearer capability, so the JSON answer is
 * `private, no-store` and the URL is never logged. The OBJECT may be cached
 * publicly at the edge only because the Worker validates the token before
 * every read (see cloud/deploy/cdn/worker.js).
 */

const SOURCES: readonly ArtifactVaultOrigin[] = ["generated", "uploaded"];

function cdnError(
  reply: FastifyReply,
  status: number,
  code: string,
  message: string,
): FastifyReply {
  return sendError(reply, status, code, message)
    .header("cache-control", "private, no-store")
    .header("pragma", "no-cache");
}

function wantsDownload(query: Record<string, string | string[] | undefined>): boolean {
  const raw = queryValue(query.download) ?? queryValue(query.disposition);
  return raw === "1" || raw === "true" || raw === "attachment";
}

/** Shared HEAD proof: missing object → 404, wrong size → 409, throw → 503. */
async function verifyObject(
  deps: GatewayDeps,
  reply: FastifyReply,
  r2Key: string,
  expectedBytes: number,
): Promise<FastifyReply | null> {
  let head;
  try {
    head = await deps.storage!.head(r2Key);
  } catch (e) {
    console.warn("[gateway] cdn HEAD failed", { error: String(e) });
    return cdnError(
      reply,
      503,
      "artifact_storage_unavailable",
      "Ovid Cloud storage could not be reached. Try again shortly.",
    );
  }
  if (head === null) {
    return cdnError(
      reply,
      404,
      "artifact_unavailable",
      "This file is no longer available in Ovid Cloud.",
    );
  }
  if (head.bytes !== expectedBytes) {
    return cdnError(
      reply,
      409,
      "artifact_incomplete",
      "This file did not finish uploading. Remove and re-attach it.",
    );
  }
  return null;
}

export function registerArtifactCdnRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.get("/artifacts/:id/cdn-url", async (request, reply) => {
    const { id } = request.params as { id: string };
    const { uid } = request.principal;
    const query = request.query as Record<string, string | string[] | undefined>;

    if (!isUuid(id)) return cdnError(reply, 404, "not_found", "Artifact not found.");
    const rawSource = queryValue(query.source);
    const origin = SOURCES.find((s) => s === rawSource);
    if (origin === undefined) {
      return sendError(
        reply,
        400,
        "bad_request",
        "source must be 'generated' or 'uploaded'.",
      );
    }
    if (deps.storage === undefined) {
      console.warn(
        "[gateway] artifact CDN URL refused: no storage adapter configured (GatewayDeps.storage missing)",
      );
      return cdnError(
        reply,
        503,
        "storage_not_configured",
        "Artifact downloads are not configured on this deployment.",
      );
    }
    const cdn = deps.cdn;
    if (cdn === undefined) {
      return cdnError(
        reply,
        503,
        "cdn_not_configured",
        "CDN downloads are not configured on this deployment.",
      );
    }

    // Ownership + session association + kind + active status (same repo call
    // as the canonical mint; wrong owner/source/status is one 404).
    const row = await artifactVault.get(deps.db, uid, id, origin);
    if (row === null) return cdnError(reply, 404, "not_found", "Artifact not found.");

    const failed = await verifyObject(deps, reply, row.r2Key, row.sizeBytes);
    if (failed !== null) return failed;

    // NEVER log the URL — it is a bearer capability until expiresAt.
    // Uploads have no content-type column in the canonical table, so the
    // vault's fallback is always application/octet-stream; derive a usable
    // type from the display name for inline image/PDF previews.
    const contentType =
      origin === "uploaded" ? contentTypeFor(row.name) : row.contentType;
    const minted = mintCdnUrl(cdn, {
      key: row.r2Key,
      filename: row.name,
      contentType,
      disposition: wantsDownload(query) ? "attachment" : "inline",
      now: deps.clock?.() ?? new Date(),
    });
    return reply
      .header("cache-control", "private, no-store")
      .header("pragma", "no-cache")
      .send({
        url: minted.url,
        expiresAt: minted.expiresAt,
        cacheClass: minted.cacheClass,
      });
  });

  /**
   * Attachments equivalent. Uploads have no extension in their R2 key, so the
   * signed token carries the display name's content type; the Worker uses it
   * for inline rendering instead of guessing `application/octet-stream`.
   */
  app.get("/sessions/:id/attachments/:attachmentId/cdn-url", async (request, reply) => {
    const { id: sessionId, attachmentId } = request.params as {
      id: string;
      attachmentId: string;
    };
    const { uid } = request.principal;
    const query = request.query as Record<string, string | string[] | undefined>;

    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);
    if (!isUuid(attachmentId)) return cdnError(reply, 404, "not_found", "File not found.");

    const [row] = await attachments.getForSession(deps.db, sessionId, [attachmentId]);
    if (row === undefined) return cdnError(reply, 404, "not_found", "File not found.");

    if (deps.storage === undefined) {
      return cdnError(
        reply,
        503,
        "storage_not_configured",
        "File downloads are not configured on this deployment.",
      );
    }
    const cdn = deps.cdn;
    if (cdn === undefined) {
      return cdnError(
        reply,
        503,
        "cdn_not_configured",
        "CDN downloads are not configured on this deployment.",
      );
    }

    const failed = await verifyObject(deps, reply, row.r2Key, row.size);
    if (failed !== null) return failed;

    const minted = mintCdnUrl(cdn, {
      key: row.r2Key,
      filename: row.name,
      contentType: contentTypeFor(row.name),
      disposition: wantsDownload(query) ? "attachment" : "inline",
      now: deps.clock?.() ?? new Date(),
    });
    return reply
      .header("cache-control", "private, no-store")
      .header("pragma", "no-cache")
      .send({
        url: minted.url,
        expiresAt: minted.expiresAt,
        cacheClass: minted.cacheClass,
      });
  });
}
