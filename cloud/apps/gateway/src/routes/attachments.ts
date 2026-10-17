import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { attachments, newId, sessions, users } from "@ovid/db";
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
 * The P8-Q3 presigner seam: structurally the StorageAdapter.presignPut
 * contract from @ovid/storage (ruling R3 / contract 6 — `presignPut(key,
 * ttlSeconds)`), so the R2 adapter (or the fs adapter in dev) satisfies it
 * as-is. Injectable via GatewayDeps.presigner; the composition root wires it.
 */
export interface AttachmentPresigner {
  presignPut(key: string, ttlSeconds: number): Promise<string>;
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
const createAttachmentBody = z
  .object({ name: z.string().min(1), size: z.number().int().positive() })
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
    const uploadUrl = await presigner.presignPut(r2Key, ATTACHMENT_UPLOAD_TTL_SECONDS);

    // 5. Provision the users row (FK target) and persist the attachment.
    await users.ensure(deps.db, uid, email);
    await attachments.create(deps.db, {
      id: attachmentId,
      sessionId,
      userId: uid,
      name,
      size,
      r2Key,
    });

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
