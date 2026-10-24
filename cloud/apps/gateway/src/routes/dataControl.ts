import type { FastifyInstance, FastifyReply } from "fastify";
import { z } from "zod";
import { dataControlRepo } from "@ovid/db";
import type { GatewayDeps } from "../app.js";
import { sendError, zodBadRequest } from "./http.js";

/**
 * The two destructive settings actions.
 *
 *   POST /data/delete-all   — every chat and everything a chat owns, plus the
 *                             R2 objects those rows reference.
 *   POST /memory/reset      — every memory file the account owns: chat,
 *                             project and the shared (global) file.
 *
 * Destructive routes are written to be boring and hard to misuse:
 *
 *   - CONFIRMATION IS PART OF THE CONTRACT. The body carries the string the
 *     person typed; the route compares it, server-side, with the account's
 *     registered email. A mismatch is a typed 400 — never a silent success.
 *     There is no "confirm: true" flag and no query parameter.
 *   - THE SCOPE IS THE TOKEN. The uid comes from `request.principal`; a body
 *     field is rejected by the strict schema, so a caller cannot name someone
 *     else's account.
 *   - BYTES BEFORE ROWS. Storage objects are deleted through the existing
 *     StorageAdapter first. If that fails the database is untouched, so the
 *     operation cannot orphan an R2 object; a retry is safe because the
 *     adapter's delete is idempotent. Objects removed before a later failure
 *     are reported as a partial outcome, never as "nothing was deleted". A
 *     deployment without storage refuses before deleting any rows or bytes.
 *   - ONLY REFERENCED BYTES. The keys come from the caller's own rows
 *     (attachments + workspace_objects); nothing under the account's prefix is
 *     swept blindly, so an object the database does not know about survives.
 *   - A SECOND CALL IS FINE. Both operations are set deletes; they report
 *     zeroes rather than failing.
 *
 * Phone confirmation is NOT implemented: no phone number is stored anywhere
 * on the account, so a typed phone could not be verified. The route says so by
 * refusing the value as a mismatch rather than accepting something it cannot
 * check.
 */

const confirmationBody = z
  .object({
    /** The email address the person typed into the confirmation field. */
    confirmation: z.string().trim().min(1).max(320),
  })
  .strict();

/** Emails compare case-insensitively and whitespace-trimmed. */
function sameEmail(typed: string, registered: string): boolean {
  return typed.trim().toLowerCase() === registered.trim().toLowerCase();
}

/**
 * Runs the confirmation gate. Returns true when the caller proved ownership;
 * otherwise the reply has already been sent and the caller must return it.
 *
 * The comparison never echoes the registered address (not even in the error),
 * and a missing registered address is its own typed refusal — never a pass.
 */
async function confirm(
  deps: GatewayDeps,
  uid: string,
  principalEmail: string | null,
  body: unknown,
  reply: FastifyReply,
): Promise<boolean> {
  const parsed = confirmationBody.safeParse(body ?? undefined);
  if (!parsed.success) {
    zodBadRequest(reply, parsed.error);
    return false;
  }

  // The users row is the account's registered address; the verified token's
  // email is the fallback for an account that has no row yet (it has no data
  // to delete in that case either, but it can still reset an empty memory).
  const registered =
    (await dataControlRepo.registeredEmail(deps.db, uid)) ?? principalEmail;

  if (registered === null || registered.trim() === "") {
    sendError(
      reply,
      409,
      "confirmation_unavailable",
      "This account has no email address to confirm against, so this action is unavailable. Add an email address first.",
    );
    return false;
  }

  if (!sameEmail(parsed.data.confirmation, registered)) {
    sendError(
      reply,
      400,
      "confirmation_mismatch",
      "Type the email address registered on this account to confirm.",
    );
    return false;
  }
  return true;
}

export function registerDataControlRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.post("/data/delete-all", async (request, reply) => {
    const { uid, email } = request.principal;

    if (!(await confirm(deps, uid, email, request.body, reply))) return reply;

    const capabilities = request.headers["x-ovid-client-capabilities"];
    const supportsPartialOutcome =
      typeof capabilities === "string" &&
      capabilities.split(",").map((value) => value.trim()).includes("data-control-partial-v1");
    if (!supportsPartialOutcome) {
      // Older installed clients report an unknown error as "nothing deleted".
      // Refuse before touching bytes: only this pre-write refusal is safe for
      // them. Capable clients opt into the richer outcome vocabulary above.
      return sendError(
        reply,
        409,
        "client_upgrade_required",
        "This app version cannot safely report storage deletion results. Update Ovid Si before deleting your data. Nothing was deleted.",
      );
    }

    const keys = await dataControlRepo.ownedStorageKeys(deps.db, uid);

    // Rows are about to disappear; their bytes must not survive them. Without
    // an adapter there is no way to remove those bytes, so refuse the whole
    // operation rather than leave orphans behind.
    if (keys.length > 0 && deps.storage === undefined) {
      console.warn(
        "[gateway] delete-all refused: no storage adapter configured (GatewayDeps.storage missing)",
      );
      return sendError(
        reply,
        503,
        "storage_not_configured",
        "Object storage is not configured on this deployment, so your files cannot be removed. Nothing was deleted.",
      );
    }

    // Bytes first. A failure leaves every row (and therefore every reference)
    // intact for a retry, but earlier byte deletes cannot be rolled back. Say
    // exactly that instead of promising that nothing was deleted.
    let deletedStorageObjects = 0;
    for (const key of keys) {
      try {
        await deps.storage!.delete(key);
        deletedStorageObjects += 1;
      } catch (e) {
        // NEVER log the key: it is a storage address, not user-facing data.
        console.warn("[gateway] delete-all: storage delete failed", {
          uid,
          error: String(e),
        });
        if (deletedStorageObjects > 0) {
          return reply.code(503).send({
            error: {
              code: "storage_delete_partial",
              message: `At least ${deletedStorageObjects} stored ${deletedStorageObjects === 1 ? "file was" : "files were"} removed before another file could not be removed. Your chats were not deleted; try again to finish removing your data.`,
              confirmedDeletedStorageObjects: deletedStorageObjects,
            },
          });
        }
        return sendError(
          reply,
          503,
          "storage_delete_failed",
          "Your chats were not deleted. Stored-file removal may be incomplete; try again to finish.",
        );
      }
    }

    const counts = await dataControlRepo.deleteAllData(deps.db, uid);
    return reply.header("cache-control", "no-store").send({
      deleted: { ...counts, storageObjects: keys.length },
    });
  });

  app.post("/memory/reset", async (request, reply) => {
    const { uid, email } = request.principal;

    if (!(await confirm(deps, uid, email, request.body, reply))) return reply;

    const files = await dataControlRepo.resetAllMemory(deps.db, uid);
    return reply.header("cache-control", "no-store").send({ reset: { files } });
  });
}
