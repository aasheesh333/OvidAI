import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { assertProjectFileCapacity, attachments, newId, ProjectFileLimitError, sessions, users } from "@ovid/db";
import {
  sanitizeAttachmentName,
  type AttachmentUploadResponse,
} from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { isUuid, notFound, sendError, zodBadRequest } from "./http.js";

// Attachment routes (P8 Task 3) — mounted inside the authenticated /cloud/v1
// scope. One endpoint: POST /sessions/:id/attachments → 201 with a presigned
// R2 PUT URL. The client uploads the bytes there directly (they never transit
// the gateway); the row records the intent, the object's presence is the
// client's side of the contract.

/**
 * Conditions the upload URL MUST sign. A presigned PUT that signs only the
 * key lets the client upload any number of bytes of any type (the row's
 * `size`/`name` are merely declared), so the declared length and media type
 * ride into the signature and the storage layer rejects a mismatch.
 */
export interface AttachmentUploadConditions {
  /** Exact byte length the client declared; signed as Content-Length. */
  contentLength: number;
  /** Media type the client declared; signed as Content-Type. */
  contentType: string;
}

/**
 * The P8-Q3 presigner seam: structurally the StorageAdapter.presignPut
 * contract from @ovid/storage (ruling R3 / contract 6 — `presignPut(key,
 * ttlSeconds, conditions)`), so the R2 adapter (or the fs adapter in dev)
 * satisfies it as-is (the optional third argument keeps every existing
 * two-argument adapter source-compatible). Injectable via
 * GatewayDeps.presigner; the composition root wires it.
 *
 * SECURITY: an adapter MUST sign `Content-Length` and `Content-Type` from
 * [AttachmentUploadConditions]; an adapter that ignores them re-opens the
 * unsigned-PUT hole (arbitrary size/type into the account's prefix).
 */
export interface AttachmentPresigner {
  presignPut(
    key: string,
    ttlSeconds: number,
    conditions?: AttachmentUploadConditions,
  ): Promise<string>;
}

/** Hard size cap (brief): anything over 25 MB is refused before signing. */
export const ATTACHMENT_MAX_BYTES = 25_000_000;

/** Presigned-PUT lifetime: 15 minutes is ample for a 25 MB upload. */
export const ATTACHMENT_UPLOAD_TTL_SECONDS = 900;

/** R2 object key for an attachment (spec §10 uploads layout, pinned by the brief). */
export function attachmentObjectKey(
  userId: string,
  sessionId: string,
  attachmentId: string,
): string {
  return `users/${userId}/sessions/${sessionId}/uploads/${attachmentId}`;
}

/** A single canonical `type/subtype` token (no parameters) — the signed value. */
const MEDIA_TYPE_RE = /^[a-z0-9][a-z0-9!#$&^_.+-]{0,63}\/[a-z0-9][a-z0-9!#$&^_.+-]{0,63}$/i;

// name non-empty string; size a positive integer; contentType an optional
// media type (defaults to application/octet-stream). .strict() rejects
// unknown keys.
const createAttachmentBody = z
  .object({
    name: z.string().min(1),
    size: z.number().int().positive(),
    contentType: z.string().regex(MEDIA_TYPE_RE).max(127).optional(),
  })
  .strict();

export function registerAttachmentRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  // Loud fallback (same mindset as the WS pty bridge): a gateway composed
  // without a presigner must never silently swallow attachment uploads — one
  // server-side warning per composition, every request answers 503.
  let warnedNoPresigner = false;

  app.post("/sessions/:id/attachments", async (request, reply) => {
    const { id: sessionId } = request.params as { id: string };
    const { uid, email } = request.principal;

    // 1. Ownership FIRST (same rule as every other :id route): malformed or
    //    unknown session, wrong owner → the same 404, before any body work.
    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);

    // 2. Body validation.
    const parsed = createAttachmentBody.safeParse(request.body ?? undefined);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const { name, size } = parsed.data;
    const contentType = parsed.data.contentType ?? "application/octet-stream";

    // 3. Size cap → 400 attachment_too_large (checked BEFORE signing and any
    //    write, so a refused upload costs neither).
    if (size > ATTACHMENT_MAX_BYTES) {
      return sendError(
        reply,
        400,
        "attachment_too_large",
        `Attachments are limited to ${ATTACHMENT_MAX_BYTES} bytes.`,
      );
    }

    // 3b. W1 follow-up (0022): a project chat's uploads share the project's
    //     file budget (memory + attachments + active artifacts). Check BEFORE
    //     presigning and before any row: a refused upload costs neither a URL
    //     nor a row, and the client never PUTs bytes. The insert repeats the
    //     check under the project-file lock as the race backstop.
    if (session.projectId !== null) {
      try {
        await assertProjectFileCapacity(deps.db, uid, session.projectId, 1);
      } catch (err) {
        if (err instanceof ProjectFileLimitError) {
          return sendError(reply, 409, err.code, err.message);
        }
        throw err;
      }
    }

    // 4. Presign. The presigner is the injectable seam; when absent the route
    //    is loud, never a silent no-op. Signing happens BEFORE the insert, so
    //    a failing presigner leaves no attachment row behind.
    const presigner = deps.presigner;
    if (presigner === undefined) {
      if (!warnedNoPresigner) {
        warnedNoPresigner = true;
        console.warn(
          "[gateway] attachment upload refused: no presigner configured (GatewayDeps.presigner missing)",
        );
      }
      return sendError(
        reply,
        503,
        "attachments_not_configured",
        "Attachment uploads are not configured on this deployment.",
      );
    }
    const attachmentId = newId();
    const r2Key = attachmentObjectKey(uid, sessionId, attachmentId);
    // The declared size/type are BOUND to the URL: the storage layer can only
    // accept a PUT whose Content-Length/Content-Type match this signature.
    const uploadUrl = await presigner.presignPut(r2Key, ATTACHMENT_UPLOAD_TTL_SECONDS, {
      contentLength: size,
      contentType,
    });

    // 5. Provision the users row (FK target) and persist the attachment.
    await users.ensure(deps.db, uid, email);
    try {
      await attachments.create(deps.db, {
        id: attachmentId,
        sessionId,
        userId: uid,
        name,
        size,
        r2Key,
        // Stamp from the session the route already loaded (authoritative at
        // creation time); the repo also re-checks the cap under its lock.
        projectId: session.projectId,
      });
    } catch (err) {
      if (err instanceof ProjectFileLimitError) {
        return sendError(reply, 409, err.code, err.message);
      }
      throw err;
    }

    // 6. Answer: the four-field wire contract. `path` is where the worker will
    //    materialize the file in the session workspace — uploads/{safe name}.
    //    expiresAt comes from the gateway clock (deps.clock when wired).
    const now = deps.clock?.() ?? new Date();
    const body: AttachmentUploadResponse = {
      attachmentId,
      uploadUrl,
      path: `uploads/${sanitizeAttachmentName(name)}`,
      expiresAt: new Date(now.getTime() + ATTACHMENT_UPLOAD_TTL_SECONDS * 1000).toISOString(),
    };
    return reply.code(201).send(body);
  });
}
