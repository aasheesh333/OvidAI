import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { attachments, messages, runs, sessions, users, type Db, type MessageRow } from "@ovid/db";
import { AGENT_RUN_JOB_NAME } from "@ovid/queue";
import { MintInternalError, type MessageDto, type Page, type SendMessageResponse } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { DEFAULT_MINT_TIMEOUT_MS, MintTimeoutError } from "../keys.js";
import { badRequest, isUuid, notFound, parsePageLimit, queryValue, sendError, zodBadRequest } from "./http.js";

// Message routes — all mounted inside the authenticated /cloud/v1 scope.

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
// attachmentIds (P8 Task 3, additive + optional): uuid-shaped ids of
// attachments created via POST /sessions/:id/attachments; validated against
// the session's attachment rows below (unknown or cross-session id → 400).
// clientMsgId (P8 Task 4, additive + optional): caller-chosen idempotency
// key (1–64 chars). A re-send with the same (session, clientMsgId) replays
// the original answer instead of inserting a second message/run.
const sendMessageBody = z
  .object({
    content: z.string(),
    attachmentIds: z.array(z.string().uuid()).optional(),
    clientMsgId: z.string().min(1).max(64).optional(),
  })
  .strict();

/**
 * P8 Task 4: resolve a (sessionId, clientMsgId) that already exists.
 * - "none": no row holds the key — the send proceeds.
 * - "replay": the existing message produced a run → the route answers 202
 *   with the ORIGINAL {runId, userMessageId, status:"queued"} and inserts
 *   nothing (SendMessageResponse's status union is literally "queued" — the
 *   replay replays the original answer verbatim; run liveness is the client's
 *   to poll via GET /runs/:id).
 * - "conflict": the message has NO run (e.g. imported history holds the id)
 *   → 409 run_conflict, still inserting nothing.
 */
type ClientMsgIdResolution =
  | { kind: "none" }
  | { kind: "replay"; runId: string; userMessageId: string }
  | { kind: "conflict" };

async function resolveClientMsgId(
  db: Db,
  sessionId: string,
  clientMsgId: string,
): Promise<ClientMsgIdResolution> {
  const existing = await messages.findByClientMsgId(db, sessionId, clientMsgId);
  if (existing === null) return { kind: "none" };
  const run = await runs.getByPromptMessageId(db, existing.id);
  return run !== null
    ? { kind: "replay", runId: run.id, userMessageId: existing.id }
    : { kind: "conflict" };
}

// Review round 1 (IMPORTANT): the 409 window. A message row commits BEFORE
// its runs.create — a same-key concurrent send that resolves inside that gap
// observes "message exists, no run", which is the conflict shape, but the run
// is merely not there YET. Concluding 409 there would make a client that
// regenerates its key on 409 defeat the whole idempotency feature. So a
// conflict verdict is re-checked a bounded number of times before it is
// believed; if the run appears, the answer becomes the 202 replay.
const CONFLICT_HEAL_RETRIES = 3;
const CONFLICT_HEAL_DELAY_MS = 25;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** resolveClientMsgId, plus bounded healing of the transient conflict window. */
async function resolveClientMsgIdHealing(
  db: Db,
  sessionId: string,
  clientMsgId: string,
): Promise<ClientMsgIdResolution> {
  let resolved = await resolveClientMsgId(db, sessionId, clientMsgId);
  for (let attempt = 0; attempt < CONFLICT_HEAL_RETRIES && resolved.kind === "conflict"; attempt++) {
    await sleep(CONFLICT_HEAL_DELAY_MS);
    resolved = await resolveClientMsgId(db, sessionId, clientMsgId);
  }
  return resolved;
}

/** postgres unique-violation (23505), searching drizzle's .cause chain for the driver error. */
function isUniqueViolation(err: unknown): boolean {
  let e: unknown = err;
  for (let depth = 0; e instanceof Error && depth < 5; depth++) {
    if ((e as { code?: unknown }).code === "23505") return true;
    e = (e as { cause?: unknown }).cause;
  }
  return false;
}

/**
 * P10 Task 2: bounded internal-mint call. The provisioner contract takes no
 * signal, so the deadline is enforced here with a race — every provisioner
 * implementation is bounded, and the HTTP implementation ALSO passes its own
 * AbortSignal to fetch so the socket is released.
 *
 * P9 Task 9: the call carries the gateway's OWN verified uid. No client
 * Firebase token or App Check header crosses this boundary.
 */
async function ensureKeyBounded(deps: GatewayDeps, uid: string): Promise<void> {
  const timeoutMs = deps.mintTimeoutMs ?? DEFAULT_MINT_TIMEOUT_MS;
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([
      deps.mint.ensureKeyForUid(uid),
      new Promise<never>((_resolve, reject) => {
        timer = setTimeout(() => reject(new MintTimeoutError(timeoutMs)), timeoutMs);
        timer.unref?.();
      }),
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

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

    // 2b. clientMsgId idempotency (P8 Task 4) — BEFORE attachment validation:
    //     a retry whose attachmentIds went stale/garbage must still replay
    //     the original answer (the ORIGINAL send already succeeded), and a
    //     conflicting id must never create rows. Runs before mint too, so a
    //     replay touches no side effects at all. Conflict verdicts heal
    //     (bounded re-check) — the winner's run may not exist yet.
    const clientMsgId = parsed.data.clientMsgId;
    if (clientMsgId !== undefined) {
      const resolved = await resolveClientMsgIdHealing(deps.db, sessionId, clientMsgId);
      if (resolved.kind === "replay") {
        const body: SendMessageResponse = {
          runId: resolved.runId,
          userMessageId: resolved.userMessageId,
          status: "queued",
        };
        return reply.code(202).send(body);
      }
      if (resolved.kind === "conflict") {
        return sendError(
          reply,
          409,
          "run_conflict",
          "This clientMsgId is already used by a message that has no run.",
        );
      }
    }

    // 2c. Attachment validation (P8 Task 3) — BEFORE any write (no orphan
    //     rows on a 400). Every id must resolve to an attachment row of THIS
    //     session; getForSession is session-scoped, so a valid id belonging to
    //     another session counts as unknown.
    const requestedAttachmentIds = [...new Set(parsed.data.attachmentIds ?? [])];
    if (requestedAttachmentIds.length > 0) {
      const known = await attachments.getForSession(
        deps.db,
        sessionId,
        requestedAttachmentIds,
      );
      if (known.length !== requestedAttachmentIds.length) {
        return badRequest(reply, "attachmentIds contains an unknown attachment id.");
      }
    }

    // 3. Provision the users row (FK target for everything below); its tier
    //    sets the queue priority (free → 2, anything else → 1).
    const user = await users.ensure(deps.db, uid, email);

    // 4. Key provisioning BEFORE any write: if mint fails, no message row,
    //    no run row and no queue job are left behind (ordering pinned by
    //    messages.test.ts). 402/429 envelopes are relayed verbatim; every
    //    other failure collapses to 409 key_not_minted. P9 Task 9: mint is
    //    called with the gateway's own verified uid (signed server-to-server).
    try {
      await ensureKeyBounded(deps, uid);
    } catch (err) {
      // P10 Task 2: a deadline breach is a bounded, retryable dependency
      // failure — NOT a "this account has no key" verdict.
      if (
        err instanceof MintTimeoutError ||
        (typeof err === "object" && err !== null && (err as { name?: unknown }).name === "TimeoutError")
      ) {
        request.log.warn({ err, sessionId }, "key provisioning timed out; run not enqueued");
        return sendError(
          reply,
          503,
          "unavailable",
          "Key provisioning timed out; please retry shortly.",
        );
      }
      if (err instanceof MintInternalError && (err.status === 402 || err.status === 429)) {
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

    // 5. Persist the user message, create the run row, then enqueue. With a
    //    clientMsgId the insert is guarded by the per-session partial unique
    //    index: a concurrent same-key send that raced past the check above
    //    resolves here into the same replay/409 answer — never a 500.
    let userMessage: MessageRow;
    try {
      userMessage = await messages.append(deps.db, {
        sessionId,
        role: "user",
        content,
        ...(clientMsgId !== undefined ? { clientMsgId } : {}),
      });
    } catch (err) {
      if (clientMsgId === undefined || !isUniqueViolation(err)) throw err;
      // The losing side of a concurrent same-key race — and it may be landing
      // inside the winner's message-commit→runs.create gap, so the verdict
      // heals the same way (bounded re-check) before any 409 is answered.
      const resolved = await resolveClientMsgIdHealing(deps.db, sessionId, clientMsgId);
      if (resolved.kind === "replay") {
        const body: SendMessageResponse = {
          runId: resolved.runId,
          userMessageId: resolved.userMessageId,
          status: "queued",
        };
        return reply.code(202).send(body);
      }
      return sendError(
        reply,
        409,
        "run_conflict",
        "This clientMsgId is already used by a message that has no run.",
      );
    }
    const run = await runs.create(deps.db, {
      sessionId,
      promptMessageId: userMessage.id,
    });
    const priority = user.tier === "free" ? 2 : 1;
    try {
      await deps.queues.agentRuns.add(
        AGENT_RUN_JOB_NAME,
        // P2 Task 12: tier rides the payload so the worker's sandbox attach
        // applies the tier-matched workspace quota (optional on the wire —
        // old consumers simply never see it). P8 Task 3: attachmentIds ride
        // the same way, present ONLY when the request sent a non-empty list
        // (the job wire stays additive for pre-P8 consumers).
        {
          runId: run.id,
          sessionId,
          userId: uid,
          prompt: content,
          tier: user.tier,
          ...(requestedAttachmentIds.length > 0
            ? { attachmentIds: requestedAttachmentIds }
            : {}),
        },
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
    // P7 Task 12: a send is the strongest activity signal — the tracker the
    // hibernator consults. Best-effort by design (pinned): a redis blip must
    // never fail an otherwise-accepted send. WS watching does NOT bump
    // (passive — pinned in Task 10's trigger rationale); P2 (pty) and P6
    // (browser) add their own bumps at their channels.
    if (deps.activity !== undefined) {
      void deps.activity.bump(sessionId).catch(() => {});
    }
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
