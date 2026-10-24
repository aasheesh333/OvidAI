import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { assertProjectFileCapacity, attachments, newId, ProjectFileLimitError, sessions, users } from "@ovid/db";
import {
  normalizeAttachmentContentType,
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
 * The P8-Q3 presigner seam: structurally the StorageAdapter.presignPut
 * contract from @ovid/storage (ruling R3 / contract 6). The declared type is
 * optional independently of the stored octet-stream fallback: old clients do
 * not sign or send a Content-Type header. Injectable via GatewayDeps.presigner.
 */
export interface AttachmentPresigner {
  presignPut(input: { key: string; ttlSeconds: number; contentType?: string }): Promise<string>;
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

// name non-empty string; size a positive integer. .strict() rejects unknown keys.
// The optional transform keeps absent distinct from the canonical stored fallback.
const normalizedContentType = z.string().transform((value, ctx) => {
  try {
    return normalizeAttachmentContentType(value);
  } catch {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Invalid attachment contentType" });
    return z.NEVER;
  }
});
const createAttachmentBody = z
  .object({
    name: z.string().min(1),
    size: z.number().int().positive(),
    contentType: normalizedContentType.optional(),
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
    const { name, size, contentType: declaredContentType } = parsed.data;
    const storedContentType = normalizeAttachmentContentType(declaredContentType);

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
    const uploadUrl = await presigner.presignPut({
      key: r2Key,
      ttlSeconds: ATTACHMENT_UPLOAD_TTL_SECONDS,
      ...(declaredContentType !== undefined ? { contentType: declaredContentType } : {}),
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
        contentType: storedContentType,
      });
    } catch (err) {
      if (err instanceof ProjectFileLimitError) {
        return sendError(reply, 409, err.code, err.message);
      }
      throw err;
    }

    // 6. Answer: the additive wire contract. New servers always emit the
    //    canonical stored type and the exact headers the signed PUT requires.
    //    expiresAt comes from the gateway clock (deps.clock when wired).
    const now = deps.clock?.() ?? new Date();
    const body: AttachmentUploadResponse = {
      attachmentId,
      uploadUrl,
      path: `uploads/${sanitizeAttachmentName(name)}`,
      expiresAt: new Date(now.getTime() + ATTACHMENT_UPLOAD_TTL_SECONDS * 1000).toISOString(),
      contentType: storedContentType,
      uploadHeaders: declaredContentType === undefined
        ? {}
        : { "Content-Type": declaredContentType },
    };
    return reply.code(201).send(body);
  });
}
