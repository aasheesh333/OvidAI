import type { FastifyInstance } from "fastify";
import { sessions, workspaceObjects, type WorkspaceObjectRow } from "@ovid/db";
import {
  DEFAULT_PRESIGN_TTL_SECONDS,
  type ArtifactDto,
  type ArtifactUrlResponse,
  type Page,
} from "@ovid/shared";
import { isActiveCdnContentType, sanitizeCdnContentType } from "@ovid/storage";
import type { GatewayDeps } from "../app.js";
import { isUuid, notFound, parsePageLimit, queryValue, sendError } from "./http.js";

/**
 * Artifact routes (P7 Task 12) — the session's download history.
 *
 *  - GET /sessions/:id/artifacts?limit&cursor — keyset page of the session's
 *    active artifacts (newest first, messages.page conventions).
 *  - GET /sessions/:id/artifacts/:artifactId/url — a presigned download URL.
 *    The URL is a bearer capability until expiresAt and is NEVER logged.
 */

function toArtifactDto(row: WorkspaceObjectRow, sessionId: string): ArtifactDto {
  const metaName = row.meta?.name;
  const name = typeof metaName === "string" && metaName !== "" ? metaName : row.r2Key;
  return {
    id: row.id,
    sessionId: row.sessionId ?? sessionId,
    name,
    sizeBytes: row.bytes,
    contentType: row.contentType ?? "application/octet-stream",
    createdAt: row.createdAt.toISOString(),
  };
}

export function registerArtifactRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.get("/sessions/:id/artifacts", async (request, reply) => {
    const { id: sessionId } = request.params as { id: string };
    const { uid } = request.principal;

    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);

    const query = request.query as Record<string, string | string[] | undefined>;
    const limit = parsePageLimit(query.limit);
    // DOCUMENTED CHOICE (same lenient degradation as the sessions/messages
    // cursors): a malformed cursor is IGNORED and the first page is served —
    // paging params stay clamp-or-ignore everywhere.
    const rawCursor = queryValue(query.cursor);
    const beforeId = rawCursor !== null && isUuid(rawCursor) ? rawCursor : null;

    const { rows, nextCursor } = await workspaceObjects.listArtifacts(deps.db, sessionId, {
      limit,
      beforeId,
    });
    return {
      items: rows.map((row) => toArtifactDto(row, sessionId)),
      nextCursor,
    } satisfies Page<ArtifactDto>;
  });

  app.get("/sessions/:id/artifacts/:artifactId/url", async (request, reply) => {
    const { id: sessionId, artifactId } = request.params as {
      id: string;
      artifactId: string;
    };
    const { uid } = request.principal;

    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);
    if (!isUuid(artifactId)) return notFound(reply, "Artifact not found.");

    // Ownership-scoped: unknown id and wrong owner are the same 404.
    const row = await workspaceObjects.getArtifact(deps.db, artifactId, uid);
    if (row === null) return notFound(reply, "Artifact not found.");

    // FE-005 regression (cross-session hole): the mint must match the SAME
    // session the URL names — the artifact row's own session, when it has
    // one, and never a session the caller merely also owns; a tampered
    // association to a foreign session is rejected by getArtifact's owner
    // scoping. Unknown/unset association → 404, same as every miss.
    if (row.sessionId === null || row.sessionId !== sessionId) {
      return notFound(reply, "Artifact not found.");
    }
    // Only live artifacts mint: a soft-deleted row (or a non-artifact kind
    // reaching this route by id) is gone as far as downloads are concerned.
    if (row.status !== "active" || row.kind !== "artifact") {
      return notFound(reply, "Artifact not found.");
    }

    // The presign seam (same mindset as the attachments route): a gateway
    // composed without storage answers loudly, never a silent no-op.
    if (deps.storage === undefined) {
      console.warn(
        "[gateway] artifact URL refused: no storage adapter configured (GatewayDeps.storage missing)",
      );
      return sendError(
        reply,
        503,
        "storage_not_configured",
        "Artifact downloads are not configured on this deployment.",
      );
    }

    let head;
    try {
      head = await deps.storage.head(row.r2Key);
    } catch {
      return sendError(reply, 503, "artifact_storage_unavailable", "Ovid Cloud storage could not be reached. Try again shortly.");
    }
    if (head === null) {
      return sendError(reply, 404, "artifact_unavailable", "This file is no longer available in Ovid Cloud.");
    }
    if (head.bytes !== row.bytes) {
      return sendError(reply, 409, "artifact_incomplete", "This file did not finish uploading. Remove and re-attach it.");
    }

    const ttlSeconds = deps.presignTtlSeconds ?? DEFAULT_PRESIGN_TTL_SECONDS;
    // NEVER log the URL — it is a bearer capability until expiresAt. Active
    // content is always an attachment, even on this legacy short-URL route.
    const contentType = sanitizeCdnContentType(head.contentType ?? row.contentType ?? undefined) ?? "application/octet-stream";
    const url = await deps.storage.presignGet(
      row.r2Key,
      ttlSeconds,
      isActiveCdnContentType(contentType)
        ? { disposition: "attachment", filename: toArtifactDto(row, sessionId).name, contentType }
        : undefined,
    );
    const now = deps.clock?.() ?? new Date();
    const body: ArtifactUrlResponse = {
      url,
      expiresAt: new Date(now.getTime() + ttlSeconds * 1000).toISOString(),
    };
    return reply.code(200).send(body);
  });
}
