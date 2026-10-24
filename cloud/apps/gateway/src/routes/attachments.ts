import type { FastifyInstance } from "fastify";
import { z } from "zod";
import {
  assertProjectFileCapacity,
  AttachmentFinalizeError,
  attachments,
  newId,
  ProjectFileLimitError,
  sessions,
  users,
} from "@ovid/db";
import {
  normalizeAttachmentContentType,
  sanitizeAttachmentName,
  type AttachmentUploadResponse,
} from "@ovid/shared";
import type { HeadResult } from "@ovid/storage";
import type { GatewayDeps } from "../app.js";
import { isUuid, notFound, sendError, zodBadRequest } from "./http.js";

// Attachment routes (P8 Task 3) — mounted inside the authenticated /cloud/v1
// scope. Create returns a presigned R2 PUT; finalize turns actual HEAD evidence
// into a ready row. The bytes never transit the gateway, and a create ticket
// alone is never treated as proof that an object exists.

/**
 * The P8-Q3 presigner seam: structurally the StorageAdapter.presignPut
 * contract from @ovid/storage (ruling R3 / contract 6). The declared type is
 * optional independently of the stored octet-stream fallback: old clients do
 * not sign or send a Content-Type header. Injectable via GatewayDeps.presigner.
 */
export interface AttachmentPresigner {
  presignPut(input: { key: string; ttlSeconds: number; contentType?: string }): Promise<string>;
  /** Optional only for legacy create-only test fakes; finalize refuses without it. */
  head?(key: string): Promise<HeadResult | null>;
}

export interface AttachmentFinalizeResponse {
  attachmentId: string;
  status: "ready";
  size: number;
  contentType: string;
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
const finalizeAttachmentBody = z.object({}).strict();

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
    // The production composition wires the full adapter as `storage`; the
    // narrower presigner seam remains for route tests and older compositions.
    const presigner = deps.presigner ?? deps.storage;
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
        contentTypeDeclared: declaredContentType !== undefined,
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

  app.post("/sessions/:id/attachments/:attachmentId/finalize", async (request, reply) => {
    const { id: sessionId, attachmentId } = request.params as {
      id: string;
      attachmentId: string;
    };
    const { uid } = request.principal;

    // Ownership and attachment existence precede body validation and HEAD, so
    // a stranger cannot probe either resource through timing or error shape.
    if (!isUuid(sessionId) || !isUuid(attachmentId)) {
      return notFound(reply, "Attachment not found.");
    }
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply, "Attachment not found.");
    const [owned] = await attachments.getForSession(deps.db, sessionId, [attachmentId]);
    if (owned === undefined || owned.userId !== uid) {
      return notFound(reply, "Attachment not found.");
    }

    const parsed = finalizeAttachmentBody.safeParse(request.body === undefined ? {} : request.body);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);

    const storage = deps.presigner ?? deps.storage;
    if (storage?.head === undefined) {
      return sendError(
        reply,
        503,
        "attachments_not_configured",
        "Attachment upload verification is not configured on this deployment.",
      );
    }
    const head = await storage.head(owned.r2Key);
    if (head === null) {
      return sendError(
        reply,
        409,
        "attachment_not_uploaded",
        "The attachment object has not reached storage.",
      );
    }

    try {
      const row = await attachments.finalizeUpload(deps.db, {
        id: attachmentId,
        sessionId,
        userId: uid,
        actualBytes: head.bytes,
        actualContentType: head.contentType ?? null,
      });
      const body: AttachmentFinalizeResponse = {
        attachmentId: row.id,
        status: "ready",
        size: row.actualBytes!,
        contentType: row.actualContentType ?? row.contentType,
      };
      return reply.send(body);
    } catch (err) {
      if (!(err instanceof AttachmentFinalizeError)) throw err;
      if (err.code === "not_found") return notFound(reply, "Attachment not found.");
      const code = err.code === "size_mismatch"
        ? "attachment_size_mismatch"
        : err.code === "type_mismatch"
          ? "attachment_type_mismatch"
          : "attachment_changed";
      return sendError(reply, 409, code, err.message);
    }
  });
}
