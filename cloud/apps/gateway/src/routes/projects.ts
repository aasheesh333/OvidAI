import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { createPrivateMemoryStore, ProjectError, projectFileCap, projectsRepo, users, type ProjectSummary } from "@ovid/db";
import {
  createProjectBodySchema,
  isValidMemoryName,
  memoryPutBodySchema,
  moveSessionProjectBodySchema,
  PrivateMemoryError,
  renameProjectBodySchema,
  type MemoryFileSummary,
  type ProjectDto,
} from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { badRequest, isUuid, notFound, sendError, zodBadRequest } from "./http.js";
import { toSessionDto } from "./sessions.js";

/**
 * W1 Projects — user-owned chat folders with private project memory.
 *
 * Ownership is always the caller's uid: an unknown id and another user's id
 * both answer the same 404 envelope (no existence leaks). Project memory
 * reuses the private_memory_files store under `project:<uuid>` scope; the
 * store re-checks project ownership inside its transaction, and the plan cap
 * (80/100/150/250) is applied atomically there.
 */
function toProjectDto(row: ProjectSummary): ProjectDto {
  return {
    id: row.id,
    name: row.name,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
    sessionCount: row.sessionCount,
    fileCount: row.fileCount,
    fileCap: row.fileCap,
  };
}

function invalidName(reply: FastifyReply): FastifyReply {
  return badRequest(reply, "Use a plain .md file name (up to 80 characters), for example notes.md.");
}

/** Store errors never relay driver detail (bind values can hold private facts). */
function memoryError(reply: FastifyReply, err: unknown): FastifyReply {
  if (!(err instanceof PrivateMemoryError)) throw err;
  switch (err.code) {
    case "not_found":
      return notFound(reply);
    case "baseline_mismatch":
      return sendError(reply, 409, "baseline_mismatch", "This memory changed since you opened it. Reload it and try again.");
    case "bad_request":
    case "limit_reached":
      return badRequest(reply, err.message);
    default:
      return sendError(reply, 503, "unavailable", err.message);
  }
}

function projectError(reply: FastifyReply, err: unknown): FastifyReply {
  if (!(err instanceof ProjectError)) throw err;
  switch (err.code) {
    case "not_found":
      return notFound(reply);
    case "name_taken":
      return sendError(reply, 409, "name_taken", err.message);
    default:
      return badRequest(reply, err.message);
  }
}

function sortMemory(items: MemoryFileSummary[]): MemoryFileSummary[] {
  return items.sort((a, b) => (a.name === "MEMORY.md" ? -1 : b.name === "MEMORY.md" ? 1 : a.name.localeCompare(b.name)));
}

interface ProjectCtx {
  uid: string;
  projectId: string;
  cap: number;
}

/**
 * Resolve `:id` to an owned project. The memory store re-checks ownership in
 * its transaction; this precheck keeps a foreign/unknown id on the same 404
 * path and lets the cap be computed once per request.
 */
async function projectCtx(deps: GatewayDeps, request: FastifyRequest, reply: FastifyReply): Promise<ProjectCtx | null> {
  const { id } = request.params as { id: string };
  const uid = request.principal.uid;
  if (!isUuid(id)) {
    notFound(reply);
    return null;
  }
  const project = await projectsRepo.get(deps.db, uid, id);
  if (project === null) {
    notFound(reply);
    return null;
  }
  return { uid, projectId: id, cap: await projectFileCap(deps.db, uid) };
}

export function registerProjectRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  const store = createPrivateMemoryStore(deps.db);

  // ── projects ─────────────────────────────────────────────────────────────

  app.get("/projects", async (request): Promise<{ items: ProjectDto[] }> => {
    const rows = await projectsRepo.list(deps.db, request.principal.uid);
    return { items: rows.map(toProjectDto) };
  });

  app.post("/projects", async (request, reply) => {
    const parsed = createProjectBodySchema.safeParse(request.body ?? {});
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const { uid, email } = request.principal;
    // Satisfy the projects.user_id FK for a brand-new account (idempotent).
    await users.ensure(deps.db, uid, email);
    try {
      const row = await projectsRepo.create(deps.db, uid, parsed.data.name);
      if (row === null) return sendError(reply, 409, "name_taken", "You already have a project with that name.");
      const summary = await projectsRepo.list(deps.db, uid);
      const created = summary.find((p) => p.id === row.id);
      return reply.code(201).send(toProjectDto(created ?? { ...row, sessionCount: 0, fileCount: 0, fileCap: await projectFileCap(deps.db, uid) }));
    } catch (err) {
      return projectError(reply, err);
    }
  });

  app.patch("/projects/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return notFound(reply);
    const parsed = renameProjectBodySchema.safeParse(request.body ?? {});
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    try {
      const row = await projectsRepo.rename(deps.db, request.principal.uid, id, parsed.data.name);
      if (row === null) return notFound(reply);
      const summary = (await projectsRepo.list(deps.db, request.principal.uid)).find((p) => p.id === id);
      return toProjectDto(summary ?? { ...row, sessionCount: 0, fileCount: 0, fileCap: await projectFileCap(deps.db, request.principal.uid) });
    } catch (err) {
      return projectError(reply, err);
    }
  });

  app.delete("/projects/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return notFound(reply);
    const removed = await projectsRepo.delete(deps.db, request.principal.uid, id);
    if (!removed) return notFound(reply);
    return reply.code(204).send();
  });

  // ── move a chat into / out of a project ──────────────────────────────────

  app.post("/sessions/:id/project", async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return notFound(reply);
    const parsed = moveSessionProjectBodySchema.safeParse(request.body ?? {});
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const { projectId } = parsed.data;
    if (projectId !== null && !isUuid(projectId)) return notFound(reply);
    try {
      const row = await projectsRepo.moveSession(deps.db, request.principal.uid, id, projectId);
      if (row === null) return notFound(reply);
      return toSessionDto(row);
    } catch (err) {
      return projectError(reply, err);
    }
  });

  // ── project memory (private_memory_files, `project:<uuid>` scope) ────────

  app.get("/projects/:id/memory", async (request, reply) => {
    const ctx = await projectCtx(deps, request, reply);
    if (ctx === null) return reply;
    try {
      const items = await store.list(ctx.uid, { projectId: ctx.projectId, maxFiles: ctx.cap });
      return { items: sortMemory(items), scope: "project", cap: ctx.cap };
    } catch (err) {
      return memoryError(reply, err);
    }
  });

  app.get("/projects/:id/memory/:name", async (request, reply) => {
    const { name } = request.params as { id: string; name: string };
    if (!isValidMemoryName(name)) return invalidName(reply);
    const ctx = await projectCtx(deps, request, reply);
    if (ctx === null) return reply;
    try {
      const doc = await store.read(ctx.uid, { projectId: ctx.projectId, maxFiles: ctx.cap }, name);
      if (doc === null) return sendError(reply, 404, "not_found", "Memory file not found.");
      return { ...doc, scope: "project" };
    } catch (err) {
      return memoryError(reply, err);
    }
  });

  app.put("/projects/:id/memory/:name", async (request, reply) => {
    const { name } = request.params as { id: string; name: string };
    if (!isValidMemoryName(name)) return invalidName(reply);
    const parsed = memoryPutBodySchema.safeParse(request.body ?? undefined);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const ctx = await projectCtx(deps, request, reply);
    if (ctx === null) return reply;
    const { content, ifRevision } = parsed.data;
    try {
      const saved = await store.save(ctx.uid, { projectId: ctx.projectId, maxFiles: ctx.cap }, name, content, ifRevision);
      return { ...saved, scope: "project" };
    } catch (err) {
      return memoryError(reply, err);
    }
  });

  app.delete("/projects/:id/memory/:name", async (request, reply) => {
    const { name } = request.params as { id: string; name: string };
    if (!isValidMemoryName(name)) return invalidName(reply);
    const ctx = await projectCtx(deps, request, reply);
    if (ctx === null) return reply;
    try {
      const removed = await store.remove(ctx.uid, { projectId: ctx.projectId, maxFiles: ctx.cap }, name);
      if (!removed) return sendError(reply, 404, "not_found", "Memory file not found.");
      return reply.code(204).send();
    } catch (err) {
      return memoryError(reply, err);
    }
  });
}
