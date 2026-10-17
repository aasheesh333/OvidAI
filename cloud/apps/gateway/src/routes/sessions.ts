import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { sessions, users, type SessionRow } from "@ovid/db";
import { sessionPatchSchema, type Page, type SessionDto } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { isUuid, notFound, parsePageLimit, queryValue, zodBadRequest } from "./http.js";

// Session routes — all mounted inside the authenticated /cloud/v1 scope.

export function toSessionDto(row: SessionRow): SessionDto {
  return {
    id: row.id,
    title: row.title,
    mode: row.mode as SessionDto["mode"],
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

  app.get("/sessions", async (request): Promise<Page<SessionDto>> => {
    const query = request.query as Record<string, string | string[] | undefined>;
    const limit = parsePageLimit(query.limit);
    const cursor = queryValue(query.cursor);
    const { rows, nextCursor } = await sessions.list(
      deps.db,
      request.principal.uid,
      limit,
      cursor,
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
    // sessions.update is ownership-scoped: unknown id and wrong owner both
    // come back null → 404 (never 403 — no existence leaks).
    const row = await sessions.update(deps.db, id, request.principal.uid, parsed.data);
    if (row === null) return notFound(reply);
    return toSessionDto(row);
  });
}
