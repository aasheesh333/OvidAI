import type { FastifyInstance } from "fastify";
import {
  artifactVault,
  decodeArtifactVaultCursor,
  encodeArtifactVaultCursor,
  sessions,
  type ArtifactVaultCategory,
  type ArtifactVaultOrigin,
} from "@ovid/db";
import { DEFAULT_PRESIGN_TTL_SECONDS } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { isUuid, notFound, parsePageLimit, queryValue, sendError } from "./http.js";

/**
 * The account Artifact Vault (FE-004/005/022) — one inventory over every
 * file the account owns, across all chats (including soft-deleted ones:
 * account retention), plus the source-explicit mint.
 *
 *   - GET /artifacts — bounded filters, all evaluated in SQL by the repo.
 *     The answer NEVER carries a saved URL, an R2 key or storage layout:
 *     rows are intent; `availability` is "unverified" until a mint's HEAD.
 *   - GET /artifacts/:id/url?source=generated|uploaded — ONE HEAD then a
 *     fresh presign on every call (no URL caching): missing object → typed
 *     404 artifact_unavailable, size mismatch → 409 artifact_incomplete,
 *     storage failure → typed 503. Private, no-store.
 */

const SOURCES: readonly ArtifactVaultOrigin[] = ["generated", "uploaded"];
const CATEGORIES: readonly ArtifactVaultCategory[] = ["image", "html", "code", "document", "other"];
const MAX_QUERY_CHARS = 128;

function vaultError(
  reply: Parameters<typeof sendError>[0],
  status: number,
  code: string,
  message: string,
) {
  // A minted URL is a bearer capability: nothing about it (or the keys it
  // came from) may be cached anywhere on the path.
  return sendError(reply, status, code, message)
    .header("cache-control", "private, no-store")
    .header("pragma", "no-cache");
}

export function registerArtifactVaultRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.get("/artifacts", async (request, reply) => {
    const { uid } = request.principal;
    const query = request.query as Record<string, string | string[] | undefined>;

    const rawSource = queryValue(query.source);
    let origin: ArtifactVaultOrigin | undefined;
    if (rawSource !== null) {
      origin = SOURCES.find((s) => s === rawSource);
      if (origin === undefined) {
        return sendError(
          reply,
          400,
          "bad_request",
          "source must be 'generated' or 'uploaded'.",
        );
      }
    }

    const rawType = queryValue(query.type);
    let category: ArtifactVaultCategory | undefined;
    if (rawType !== null) {
      category = CATEGORIES.find((c) => c === rawType);
      if (category === undefined) {
        return sendError(
          reply,
          400,
          "bad_request",
          "type must be one of 'image', 'html', 'code', 'document', 'other'.",
        );
      }
    }

    const search = queryValue(query.q);
    if (search !== null && search.length > MAX_QUERY_CHARS) {
      return sendError(
        reply,
        400,
        "bad_request",
        `q must be at most ${MAX_QUERY_CHARS} characters.`,
      );
    }

    const rawSessionId = queryValue(query.sessionId);
    let sessionId: string | undefined;
    if (rawSessionId !== null) {
      if (!isUuid(rawSessionId)) {
        return sendError(reply, 400, "bad_request", "sessionId must be a UUID.");
      }
      // Optional scope: a session the caller does not own is a 404, same as
      // every other session-scoped route (never a hint that it exists).
      if ((await sessions.get(deps.db, rawSessionId, uid)) === null) {
        return notFound(reply);
      }
      sessionId = rawSessionId;
    }

    const rawCursor = queryValue(query.cursor);
    let cursor: ReturnType<typeof decodeArtifactVaultCursor> = null;
    if (rawCursor !== null) {
      cursor = decodeArtifactVaultCursor(rawCursor);
      if (cursor === null) {
        return sendError(reply, 400, "bad_request", "cursor is malformed.");
      }
    }

    const { rows, nextCursor } = await artifactVault.page(deps.db, uid, {
      origin,
      category,
      search: search ?? undefined,
      sessionId,
      limit: parsePageLimit(query.limit),
      cursor,
    });

    return reply.header("cache-control", "private, no-store").send({
      items: rows.map((row) => ({
        id: row.id,
        sessionId: row.sessionId,
        sessionTitle: row.sessionTitle,
        name: row.name,
        origin: row.origin,
        category: row.category,
        sizeBytes: row.sizeBytes,
        contentType: row.contentType,
        createdAt: row.createdAt.toISOString(),
        availability: row.availability,
      })),
      nextCursor: nextCursor === null ? null : encodeArtifactVaultCursor(nextCursor),
    });
  });

  /**
   * Remove one artifact.
   *
   * `source` is required for the same reason the URL mint requires it: an id
   * alone is ambiguous across the two canonical sources, and guessing would
   * mean guessing which table to delete from.
   *
   * The bytes are deleted best-effort AFTER the row. A storage failure is
   * logged and still answers 200: the file is already gone from the user's
   * library and their quota, and an error would invite a retry that 404s.
   */
  app.delete("/artifacts/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    const { uid } = request.principal;
    const query = request.query as Record<string, string | string[] | undefined>;

    if (!isUuid(id)) {
      return vaultError(reply, 404, "not_found", "Artifact not found.");
    }
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

    const row = await artifactVault.remove(deps.db, uid, id, origin);
    if (row === null) {
      return vaultError(reply, 404, "not_found", "Artifact not found.");
    }

    if (deps.storage !== undefined) {
      try {
        await deps.storage.delete(row.r2Key);
      } catch (e) {
        // The row is gone either way; the object is now orphaned and a sweep
        // can reclaim it. Never log the key: it is a storage address.
        console.warn("[gateway] artifact bytes could not be deleted", {
          id,
          origin,
          error: String(e),
        });
      }
    }

    reply.header("cache-control", "no-store");
    return { id, origin, freedBytes: row.sizeBytes };
  });

  app.get("/artifacts/:id/url", async (request, reply) => {
    const { id } = request.params as { id: string };
    const { uid } = request.principal;
    const query = request.query as Record<string, string | string[] | undefined>;

    if (!isUuid(id)) {
      return vaultError(reply, 404, "not_found", "Artifact not found.");
    }
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
        "[gateway] artifact vault URL refused: no storage adapter configured (GatewayDeps.storage missing)",
      );
      return vaultError(
        reply,
        503,
        "storage_not_configured",
        "Artifact downloads are not configured on this deployment.",
      );
    }

    // Ownership + session association + kind + active status — all inside the
    // repo's joins. Wrong owner, wrong source, deleted row, tampered
    // association: all the same 404, never a hint.
    const row = await artifactVault.get(deps.db, uid, id, origin);
    if (row === null) {
      return vaultError(reply, 404, "not_found", "Artifact not found.");
    }

    // ONE HEAD per mint: uploaded rows are intent (the PUT may never have
    // completed) and generated bytes may have been evicted — a presign alone
    // would hand the client a capability for a 404.
    let head;
    try {
      head = await deps.storage.head(row.r2Key);
    } catch (e) {
      console.warn("[gateway] artifact vault HEAD failed", { id, origin, error: String(e) });
      return vaultError(
        reply,
        503,
        "artifact_storage_unavailable",
        "Ovid Cloud storage could not be reached. Try again shortly.",
      );
    }
    if (head === null) {
      return vaultError(
        reply,
        404,
        "artifact_unavailable",
        "This file is no longer available in Ovid Cloud.",
      );
    }
    if (head.bytes !== row.sizeBytes) {
      // Uploaded intent whose PUT never completed (or a truncated write):
      // the object exists but is NOT the file the row describes.
      return vaultError(
        reply,
        409,
        "artifact_incomplete",
        "This file did not finish uploading. Remove and re-attach it.",
      );
    }

    const ttlSeconds = deps.presignTtlSeconds ?? DEFAULT_PRESIGN_TTL_SECONDS;
    // NEVER log the URL — it is a bearer capability until expiresAt.
    const url = await deps.storage.presignGet(row.r2Key, ttlSeconds);
    const now = deps.clock?.() ?? new Date();
    return (
      reply
        .header("cache-control", "private, no-store")
        .header("pragma", "no-cache")
        // Explicit no content-type sniffing/caching of the capability body.
        .send({
          url,
          expiresAt: new Date(now.getTime() + ttlSeconds * 1000).toISOString(),
        })
    );
  });
}
