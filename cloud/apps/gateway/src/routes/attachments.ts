import type { FastifyInstance } from "fastify";
import { z } from "zod";
import {
  assertProjectFileCapacity,
  AttachmentFinalizeError,
  attachmentDeclarationMismatch,
  attachments,
  cleanupStorageObject,
  cleanupStorageObjectRace,
  newId,
  ProjectFileLimitError,
  QuotaContractError,
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
import { StorageQuota } from "../storageQuota.js";
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
  /** Optional quarantine seam for failed/cap-denied objects. */
  delete?(key: string): Promise<void>;
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

function quotaError(
  reply: Parameters<typeof sendError>[0],
  result: { scope: "upload" | "storage"; resetsAt: Date | null },
) {
  if (result.resetsAt !== null) {
    reply.header("retry-after", Math.max(1, Math.ceil((result.resetsAt.getTime() - Date.now()) / 1000)));
  }
  return result.scope === "upload"
    ? sendError(reply, 429, "upload_limit_reached", "The upload allowance for this plan is exhausted.")
    : sendError(reply, 409, "storage_quota_exceeded", "The storage allowance for this plan is exhausted.");
}

async function releaseReservation(quota: StorageQuota, reservationId: string): Promise<void> {
  await cleanupStorageObjectRace({
    removeObject: () => quota.removeObject({ reservationId }),
    releaseUpload: () => quota.releaseUpload({ reservationId }),
    deleteObject: async () => {},
    deleteRow: async () => {},
  });
}

export function registerAttachmentRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  const quota = new StorageQuota({ db: deps.db, storage: deps.storage, now: deps.clock });
  const compensate = async (attachmentId: string, uid: string, r2Key: string) => {
    await cleanupStorageObject(deps.db, { reservationId: attachmentId }, {
      now: deps.clock,
      deleteObject: async () => {
        const storage = deps.presigner ?? deps.storage;
        await storage?.delete?.(r2Key).catch(() => {});
      },
      deleteRow: async () => {
        await deps.db.$client`DELETE FROM attachments WHERE id = ${attachmentId} AND user_id = ${uid}`;
      },
    });
  };
  const releaseForRefusal = async (attachmentId: string, uid: string, r2Key: string) => {
    try {
      await releaseReservation(quota, attachmentId);
    } catch (error) {
      // A failed typed-refusal cleanup is still a post-reservation failure.
      // Escalate to full object/row compensation before infrastructure escapes.
      await compensate(attachmentId, uid, r2Key);
      throw error;
    }
  };
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
    await users.ensure(deps.db, uid, email);
    const reservation = await quota.reserveUpload({
      actorUserId: uid,
      ownerUserId: uid,
      sessionId,
      attachmentId,
      declaredBytes: size,
    });
    if (!reservation.ok) {
      if (reservation.scope === "attachment") {
        return sendError(reply, 409, "attachment_changed", "The attachment upload is no longer active.");
      }
      return quotaError(reply, reservation);
    }

    // Reserve before signing. A signer/row failure releases only the pending
    // reservation; the response shape and signed Content-Type stay unchanged.
    let uploadUrl: string;
    try {
      uploadUrl = await presigner.presignPut({
        key: r2Key,
        ttlSeconds: ATTACHMENT_UPLOAD_TTL_SECONDS,
        ...(declaredContentType !== undefined ? { contentType: declaredContentType } : {}),
      });
      await attachments.create(deps.db, {
        id: attachmentId,
        sessionId,
        userId: uid,
        name,
        size,
        r2Key,
        projectId: session.projectId,
        contentType: storedContentType,
        contentTypeDeclared: declaredContentType !== undefined,
      });
    } catch (err) {
      await releaseForRefusal(attachmentId, uid, r2Key);
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
      // Missing HEAD enters the same users → attachment → reservation fence
      // as valid legacy HEAD. A committed failure tombstone denies late PUT.
      try {
        const failed = await quota.reserveUpload({
          actorUserId: uid,
          ownerUserId: uid,
          sessionId,
          attachmentId,
          declaredBytes: owned.size,
          head: null,
        });
        if (!failed.ok) {
          if (failed.scope === "attachment") {
            await storage.delete?.(owned.r2Key).catch(() => {});
            return sendError(
              reply,
              409,
              "attachment_not_uploaded",
              "The attachment object has not reached storage.",
            );
          }
          return quotaError(reply, failed);
        }
        await releaseForRefusal(attachmentId, uid, owned.r2Key);
      } catch (err) {
        if (err instanceof QuotaContractError && err.code === "reservation_not_found") {
          return sendError(reply, 409, "attachment_not_uploaded", "The attachment object has not reached storage.");
        }
        if (err instanceof QuotaContractError &&
            (err.code === "attachment_failed" || err.code === "reservation_released")) {
          // A retry may encounter failed status with an older finalized charge.
          // Reconcile that charge before the same deterministic 409.
          await releaseForRefusal(attachmentId, uid, owned.r2Key);
        } else {
          throw err;
        }
      }
      try {
        await deps.db.$client`
          UPDATE attachments SET upload_status = 'failed', actual_bytes = NULL,
            actual_content_type = NULL, finalized_at = NULL
           WHERE id = ${attachmentId} AND user_id = ${uid}`;
      } catch (error) {
        // Release may already have debited a finalized charge. A later status
        // write failure still owes real object/host-row cleanup; released
        // reservations make the repeated remove a no-op, never a second debit.
        await compensate(attachmentId, uid, owned.r2Key);
        throw error;
      }
      return sendError(
        reply,
        409,
        "attachment_not_uploaded",
        "The attachment object has not reached storage.",
      );
    }

    try {
      // Idempotent for new uploads; repairs a pre-reservation legacy row with
      // the same canonical attachment identity before the existing HEAD checks.
      const reservation = await quota.reserveUpload({
        actorUserId: uid,
        ownerUserId: uid,
        sessionId,
        attachmentId,
        declaredBytes: owned.size,
        head: { bytes: head.bytes, contentType: head.contentType ?? null, etag: head.etag },
      });
      if (!reservation.ok) {
        if (reservation.scope === "attachment") {
          await storage.delete?.(owned.r2Key).catch(() => {});
          return sendError(reply, 409, "attachment_changed", "The attachment upload is no longer active.");
        }
        return quotaError(reply, reservation);
      }

      // Reject declaration mismatches before any used-byte transition. The
      // repository records the failed row; its guard does not require a
      // finalized reservation for this failure path.
      const mismatch = attachmentDeclarationMismatch(owned, {
        actualBytes: head.bytes,
        actualContentType: head.contentType ?? null,
      });
      if (mismatch !== null) {
        await attachments.finalizeUpload(deps.db, {
          id: attachmentId,
          sessionId,
          userId: uid,
          actualBytes: head.bytes,
          actualContentType: head.contentType ?? null,
        });
        throw new Error("unreachable: mismatch finalization did not refuse");
      }

      // The successful ready transition happens only after actual bytes are
      // settled. The repository independently requires this finalized proof,
      // which also fences direct worker finalization.
      const settled = await quota.finalizeUpload({
        reservationId: attachmentId,
        actualBytes: head.bytes,
        actualContentType: head.contentType ?? null,
        etag: head.etag,
        attachment: true,
      });
      if (!settled.ok) {
        // The declaration/HEAD checks passed, but the real bytes would cross
        // the owner's cap. Never leave a ready row or a pending reservation.
        await releaseForRefusal(attachmentId, uid, owned.r2Key);
        await deps.db.$client`
          UPDATE attachments SET upload_status = 'failed', finalized_at = NULL,
            actual_bytes = NULL, actual_content_type = NULL
           WHERE id = ${attachmentId} AND user_id = ${uid}`;
        await storage.delete?.(owned.r2Key).catch(() => {});
        return quotaError(reply, settled);
      }
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
      if (err instanceof QuotaContractError) {
        if (err.code === "reservation_released" || err.code === "attachment_failed") {
          await releaseForRefusal(attachmentId, uid, owned.r2Key);
          await storage.delete?.(owned.r2Key).catch(() => {});
          return sendError(reply, 409, "attachment_changed", "The attachment upload reservation is no longer active.");
        }
        // Every post-reservation exception gets bounded compensation before
        // an infrastructure error can escape with a charged/orphaned row.
        await compensate(attachmentId, uid, owned.r2Key);
        throw err;
      }
      if (!(err instanceof AttachmentFinalizeError)) {
        await compensate(attachmentId, uid, owned.r2Key);
        throw err;
      }
      if (err.code === "not_found") {
        await compensate(attachmentId, uid, owned.r2Key);
        return notFound(reply, "Attachment not found.");
      }
      await releaseForRefusal(attachmentId, uid, owned.r2Key);
      await storage.delete?.(owned.r2Key).catch(() => {});
      const code = err.code === "size_mismatch"
        ? "attachment_size_mismatch"
        : err.code === "type_mismatch"
          ? "attachment_type_mismatch"
          : "attachment_changed";
      return sendError(reply, 409, code, err.message);
    }
  });
}
