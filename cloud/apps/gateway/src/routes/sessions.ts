import type { FastifyInstance, FastifyReply } from "fastify";
import { z } from "zod";
import { runs, sessionState, sessions, users, type SessionRow } from "@ovid/db";
import { sessionPatchSchema, type Page, type SessionDto } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { badRequest, isUuid, notFound, parsePageLimit, queryValue, zodBadRequest } from "./http.js";

const MIN_CURSOR_MS = -62_135_596_800_000;
const MAX_CURSOR_MS = 253_402_300_799_999;

function snapshotTime(raw: string | null): number | null | undefined {
  if (raw === null) return undefined;
  const value = Number(raw);
  return Number.isSafeInteger(value) && value >= MIN_CURSOR_MS && value <= MAX_CURSOR_MS
    ? value
    : null;
}
import { cancelActiveRun } from "./runs.js";
import { isDurableWorkerSession, refusePublicWorkerControl } from "./workerControlGuards.js";

// Session routes — all mounted inside the authenticated /cloud/v1 scope.

export function toSessionDto(row: SessionRow): SessionDto {
  return {
    id: row.id,
    title: row.title,
    mode: row.mode as SessionDto["mode"],
    projectId: row.projectId,
    pinnedAt: row.pinnedAt?.toISOString() ?? null,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}

// title optional string; .strict() rejects unknown keys → 400 bad_request.
const createSessionBody = z.object({ title: z.string().optional() }).strict();
export function registerSessionRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.post("/sessions", async (request, reply) => {
    // A POST with no body at all is treated as {} — title is optional.
    const parsed = createSessionBody.safeParse(request.body ?? {});
    if (!parsed.success) return zodBadRequest(reply, parsed.error);

    const { uid, email } = request.principal;
    // Provision the users row BEFORE the insert (sessions.userId FK); the
    // upsert is idempotent and never touches tier.
    await users.ensure(deps.db, uid, email);

    const row = await sessions.create(deps.db, uid, parsed.data.title ?? null);
    return reply.code(201).send(toSessionDto(row));
  });

  app.get("/sessions", async (request, reply): Promise<Page<SessionDto> | FastifyReply> => {
    const query = request.query as Record<string, string | string[] | undefined>;
    const limit = parsePageLimit(query.limit);
    const cursor = queryValue(query.cursor);
    const snapshot = snapshotTime(queryValue(query.snapshot));
    if (snapshot === null) {
      return badRequest(reply, "snapshot must be an epoch-millisecond instant.");
    }
    const immutable = snapshot !== undefined;
    const { rows, nextCursor } = await sessions.list(
      deps.db,
      request.principal.uid,
      limit,
      cursor,
      immutable,
      snapshot,
    );
    return { items: rows.map(toSessionDto), nextCursor };
  });

  app.get("/sessions/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    // Shape guard: a malformed id gets the SAME 404 envelope as an unknown one
    // (no existence leaks either way) and never reaches the db — client typos
    // must not be able to produce a 500 from the id column binding.
    if (!isUuid(id)) return notFound(reply);
    // sessions.get is ownership-scoped: unknown id and wrong owner both come
    // back null → 404 (never 403 — no existence leaks).
    const row = await sessions.get(deps.db, id, request.principal.uid);
    if (row === null) return notFound(reply);
    return toSessionDto(row);
  });

  app.patch("/sessions/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    // Same shape guard as GET: malformed id → the SAME 404 envelope as an
    // unknown one, and it never reaches the db (client typos must not be able
    // to produce a 500 from the uuid column binding).
    if (!isUuid(id)) return notFound(reply);
    // Strict schema: unknown keys rejected, at least one field required
    // (an empty body or {} → 400 bad_request, NOT a no-op 200).
    const parsed = sessionPatchSchema.safeParse(request.body ?? {});
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    // Ownership precedes the global durable-child predicate: a foreign child
    // gets the same 404 as an unknown id, never a 403 existence oracle. Body
    // parsing stays first to preserve the ordinary invalid-body behavior.
    const existing = await sessions.get(deps.db, id, request.principal.uid);
    if (existing === null) return notFound(reply);
    // Full child PATCH refusal: title/mode/pinned are all main-controlled for
    // durable workers. Fence before sessions.update and sessionState.patch.
    if (await isDurableWorkerSession(deps.db, id)) {
      return refusePublicWorkerControl(reply);
    }
    // Preserve the ownership-scoped update for ordinary roots and its 404 if
    // the session disappears between the ownership read and this write.
    const row = await sessions.update(deps.db, id, request.principal.uid, parsed.data);
    if (row === null) return notFound(reply);
    // CH-001: the worker reads the mode from session_agent_state, not the
    // sessions column — keep the two in step so a chip change is honored by
    // the next run (and by server slash commands / schedules).
    if (parsed.data.mode !== undefined) {
      await sessionState.patch(deps.db, id, { mode: parsed.data.mode });
    }
    return toSessionDto(row);
  });

  app.delete("/sessions/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    // Same shape guard as GET/PATCH: malformed id → the SAME 404 envelope as
    // an unknown one, and it never reaches the db (client typos must not be
    // able to produce a 500 from the uuid column binding).
    if (!isUuid(id)) return notFound(reply);
    // sessions.get is ownership-scoped AND filters deleted_at: unknown id,
    // wrong owner, and already-deleted all come back null → the same 404.
    const row = await sessions.get(deps.db, id, request.principal.uid);
    if (row === null) return notFound(reply);
    // Account ownership is not main-agent cleanup authority. Refuse before the
    // cancellation loop or soft delete; canonical controls own child cleanup.
    if (await isDurableWorkerSession(deps.db, id)) {
      return refusePublicWorkerControl(reply);
    }

    // Cancel any still-active run FIRST — a soft-deleted session must not
    // leave a worker streaming into it. Same cooperative flow as POST
    // /runs/:id/cancel (flag + best-effort job remove + queued-race
    // terminalization), repeated once per active run (a session can hold
    // several queued). The seen-set + pass bound stop the loop when a run
    // only got flagged (the worker owns its terminalization — remove failed
    // or it was already claimed) instead of spinning on it.
    const seen = new Set<string>();
    for (let pass = 0; pass < 10; pass++) {
      const active = await runs.activeForSession(deps.db, id);
      if (active === null || !seen.add(active.id)) break;
      const status = await cancelActiveRun(deps, request.log, request.principal.uid, active.id);
      // Keep the shared helper's refusal terminal for DELETE too: never fall
      // through to soft-delete a child whose active run could not be cancelled.
      if (status === "refused") return refusePublicWorkerControl(reply);
    }

    // Soft delete: the row (and its messages/runs) stays as history, but
    // every read path filters deleted_at IS NULL from here on.
    await sessions.softDelete(deps.db, id, request.principal.uid);
    return reply.code(204).send();
  });
}
