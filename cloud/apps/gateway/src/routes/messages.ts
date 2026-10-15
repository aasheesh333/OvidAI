import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import { messages, runs, sessions, users, type MessageRow } from "@ovid/db";
import { AGENT_RUN_JOB_NAME } from "@ovid/queue";
import type { MessageDto, Page, SendMessageResponse } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { MintHttpError } from "../keys.js";
import { badRequest, isUuid, notFound, parsePageLimit, queryValue, sendError, zodBadRequest } from "./http.js";

// Message routes — all mounted inside the authenticated /cloud/v1 scope.

const BEARER_PREFIX = "Bearer ";

/**
 * The caller's raw identity headers for the mint passthrough (authHook has
 * already verified both). ensureKey's contract is (idToken, appCheck|null),
 * so Authorization is re-prefixed with Bearer by the HTTP provisioner.
 */
function mintIdentity(request: FastifyRequest): { idToken: string; appCheck: string | null } {
  const authorization = queryValue(request.headers.authorization);
  const idToken =
    authorization !== null && authorization.startsWith(BEARER_PREFIX)
      ? authorization.slice(BEARER_PREFIX.length)
      : "";
  return { idToken, appCheck: queryValue(request.headers["x-firebase-appcheck"]) };
}

export function toMessageDto(row: MessageRow): MessageDto {
  return {
    id: row.id,
    sessionId: row.sessionId,
    role: row.role as MessageDto["role"],
    content: row.content,
    createdAt: row.createdAt.toISOString(),
  };
}

// content required non-empty string; .strict() rejects unknown keys.
const sendMessageBody = z.object({ content: z.string() }).strict();

export function registerMessageRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.post("/sessions/:id/messages", async (request, reply) => {
    const { id: sessionId } = request.params as { id: string };
    const { uid, email } = request.principal;

    // 1. Ownership FIRST: wrong owner and unknown session are both 404 (never
    //    403), before body validation so nobody can probe a session they
    //    don't own through validation behavior. The shape guard folds a
    //    malformed :id into the same 404 envelope (identical message — still
    //    no existence leaks) and keeps client garbage away from the db.
    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);

    // 2. Body validation: missing/empty/whitespace-only content → 400.
    const parsed = sendMessageBody.safeParse(request.body ?? undefined);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const content = parsed.data.content;
    if (content.trim() === "") {
      return badRequest(reply, "content must be a non-empty string.");
    }

    // 3. Provision the users row (FK target for everything below); its tier
    //    sets the queue priority (free → 2, anything else → 1).
    const user = await users.ensure(deps.db, uid, email);

    // 4. Key provisioning BEFORE any write: if mint fails, no message row,
    //    no run row and no queue job are left behind (ordering pinned by
    //    messages.test.ts). 402/429 envelopes are relayed verbatim; every
    //    other failure collapses to 409 key_not_minted.
    const { idToken, appCheck } = mintIdentity(request);
    try {
      await deps.mint.ensureKey(idToken, appCheck);
    } catch (err) {
      if (err instanceof MintHttpError && (err.status === 402 || err.status === 429)) {
        return reply.code(err.status).send(err.body);
      }
      request.log.warn({ err, sessionId }, "key provisioning failed; run not enqueued");
      return sendError(
        reply,
        409,
        "key_not_minted",
        "No model API key is provisioned for this account.",
      );
    }

    // 5. Persist the user message, create the run row, then enqueue.
    const userMessage = await messages.append(deps.db, {
      sessionId,
      role: "user",
      content,
    });
    const run = await runs.create(deps.db, {
      sessionId,
      promptMessageId: userMessage.id,
    });
    const priority = user.tier === "free" ? 2 : 1;
    try {
      await deps.queues.agentRuns.add(
        AGENT_RUN_JOB_NAME,
        { runId: run.id, sessionId, userId: uid, prompt: content },
        { jobId: run.id, priority },
      );
    } catch (err) {
      // Documented ruling: the user message row stays and the run row is LEFT
      // 'queued' (not deleted) so an operator/reconciler can re-enqueue it;
      // the client sees 503 and can retry (jobId=runId keeps re-adds
      // idempotent on the queue side).
      request.log.error({ err, runId: run.id, sessionId }, "queue add failed; run row left queued");
      return sendError(
        reply,
        503,
        "unavailable",
        "Run queue is temporarily unavailable; please retry shortly.",
      );
    }

    // 6. Bump session activity and answer 202 — the run executes async.
    await sessions.touch(deps.db, sessionId);
    const body: SendMessageResponse = {
      runId: run.id,
      userMessageId: userMessage.id,
      status: "queued",
    };
    return reply.code(202).send(body);
  });

  app.get("/sessions/:id/messages", async (request, reply) => {
    const { id: sessionId } = request.params as { id: string };
    // Ownership 404 first — same rule as every other :id route (malformed :id
    // folds into the same envelope via the shape guard, never a 500).
    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, request.principal.uid);
    if (session === null) return notFound(reply);

    const query = request.query as Record<string, string | string[] | undefined>;
    const limit = parsePageLimit(query.limit);
    // DOCUMENTED CHOICE: a malformed `before` is IGNORED and the first page is
    // served — the same lenient degradation the sessions-list `cursor` has
    // (garbage cursor → first page, pinned in sessions.test.ts). Not a 400:
    // paging params stay clamp-or-ignore everywhere, and an unguarded value
    // would reach the keyset id comparison, where bpchar string ordering makes
    // results arbitrary (e.g. before=0 filters EVERY UUIDv7 id out → empty
    // page instead of the intended "no valid cursor → start over").
    const rawBefore = queryValue(query.before);
    const beforeId = rawBefore !== null && isUuid(rawBefore) ? rawBefore : null;
    const { rows, nextCursor } = await messages.page(deps.db, sessionId, {
      limit,
      beforeId,
    });
    // Newest-first keyset page (UUIDv7 id order); nextCursor is the oldest id.
    return { items: rows.map(toMessageDto), nextCursor } satisfies Page<MessageDto>;
  });
}
