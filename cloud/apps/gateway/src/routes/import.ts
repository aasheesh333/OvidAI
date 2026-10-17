import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import { messages, sessions, users, type SessionRow } from "@ovid/db";
import type { ImportReport, MessageDto } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { badRequest, isUuid, notFound, sendError, zodBadRequest } from "./http.js";

// P8 Task 4: bulk history import (Android thin-client transcripts+sessions —
// P8-Q5 ruling: import scope is exactly that). Mounted inside the
// authenticated /cloud/v1 scope; enqueues nothing (imported history is inert
// transcript, no agent runs are created).

/** Per-message shape — clientMsgId is REQUIRED: it is the idempotency key. */
const importMessageSchema = z
  .object({
    clientMsgId: z.string().min(1).max(64),
    role: z.enum(["user", "assistant", "system", "tool"]),
    content: z.string(),
    createdAt: z.string().datetime(),
  })
  .strict();

/**
 * Request body. `sessionId` (optional) is the CONTINUATION id: present → the
 * batch lands in that existing session (duplicates skip via (session,
 * clientMsgId)); absent → a fresh session is created, carrying `title` /
 * `createdAt` when supplied (timestamp fidelity, spec §13.3). The messages
 * array bounds are enforced by the ROUTE (not zod) so > 500 answers the
 * dedicated import_too_large code instead of a generic bad_request.
 */
const importBodySchema = z
  .object({
    sessionId: z.string().uuid().optional(),
    title: z.string().optional(),
    createdAt: z.string().datetime().optional(),
    messages: z.array(importMessageSchema),
  })
  .strict();

const MAX_IMPORT_MESSAGES = 500;

export function registerImportRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.post("/import/sessions", async (request: FastifyRequest, reply) => {
    const { uid, email } = request.principal;

    // 1. Shape validation (strict): unknown keys, malformed ids, non-ISO
    //    timestamps → 400 before anything is touched.
    const parsed = importBodySchema.safeParse(request.body ?? undefined);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const { sessionId, title, createdAt, messages: batch } = parsed.data;

    // 2. Size bounds: empty batch and > 500 per call are both 400, but with
    //    distinct codes (the client uses them differently: retry-with-more vs
    //    split-the-batch).
    if (batch.length === 0) {
      return badRequest(reply, "messages must contain at least one message.");
    }
    if (batch.length > MAX_IMPORT_MESSAGES) {
      return sendError(
        reply,
        400,
        "import_too_large",
        `A single import call may contain at most ${MAX_IMPORT_MESSAGES} messages.`,
      );
    }

    // 3. Resolve the target session. Continuation: ownership-scoped get —
    //    wrong owner and unknown id are the same 404 (never 403, no existence
    //    leaks; malformed ids already died at the shape guard above). Fresh:
    //    provision the users row (sessions.userId FK) then create with the
    //    client's title/createdAt when supplied.
    let session: SessionRow;
    if (sessionId !== undefined) {
      if (!isUuid(sessionId)) return notFound(reply);
      const existing = await sessions.get(deps.db, sessionId, uid);
      if (existing === null) return notFound(reply);
      session = existing;
    } else {
      await users.ensure(deps.db, uid, email);
      session = await sessions.create(
        deps.db,
        uid,
        title,
        createdAt !== undefined ? new Date(createdAt) : undefined,
      );
    }

    // 4. One bulk insert: ON CONFLICT (session, clientMsgId) DO NOTHING —
    //    re-sent ids are skipped, never duplicated or rewritten. Stored
    //    createdAt values are the CLIENT's.
    const report = await messages.importBulk(
      deps.db,
      session.id,
      batch.map((m) => ({
        clientMsgId: m.clientMsgId,
        role: m.role as MessageDto["role"],
        content: m.content,
        createdAt: new Date(m.createdAt),
      })),
    );

    // 5. Imported history is activity too — keep the session discoverable at
    //    the top of the list (same rule as send-message).
    await sessions.touch(deps.db, session.id);

    const body: ImportReport = {
      sessionId: session.id,
      imported: report.imported,
      skipped: report.skipped,
    };
    return reply.code(201).send(body);
  });
}
