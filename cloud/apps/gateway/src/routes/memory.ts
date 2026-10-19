import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { createPrivateMemoryStore, userPreferences } from "@ovid/db";
import { isValidMemoryName, memoryPutBodySchema, PrivateMemoryError, type MemoryFileSummary } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { badRequest, isUuid, notFound, sendError, zodBadRequest } from "./http.js";

/**
 * R1 private memory: the /memory API reads and writes ONLY the
 * private_memory_files store (migration 0019). Nothing here touches the
 * shared workspace: no worker file calls, no .ovid/memory or
 * .ovid/session-memory paths, and no automatic import of legacy files.
 * Memory is isolated per chat by default; the user's explicit sharing
 * preference opens the shared scope. Every operation rechecks live-session
 * ownership inside the store's transaction.
 */
function invalidName(reply: FastifyReply): FastifyReply {
  return badRequest(reply, "Use a plain .md file name (up to 80 characters), for example notes.md.");
}

/** Maps a store error to its HTTP shape; driver detail never leaks (bind values could contain private facts). */
function storeError(reply: FastifyReply, err: unknown): FastifyReply {
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

interface MemoryCtx {
  uid: string;
  ns: { sessionId: string; shared: boolean };
  scope: "chat" | "shared";
}

async function memoryScope(deps: GatewayDeps, request: FastifyRequest, reply: FastifyReply): Promise<MemoryCtx | null> {
  const sid = (request.query as { sessionId?: unknown } | undefined)?.sessionId;
  if (sid === undefined) {
    sendError(reply, 409, "no_workspace", "Open a cloud chat first to manage its memory.");
    return null;
  }
  const uid = request.principal.uid;
  if (typeof sid !== "string" || !isUuid(sid)) {
    notFound(reply);
    return null;
  }
  // The store's transaction rechecks live-session ownership for the uid on
  // every operation, so the namespace is safe even without a precheck here.
  const prefs = await userPreferences.get(deps.db, uid);
  return { uid, ns: { sessionId: sid, shared: prefs.shareSessionMemory }, scope: prefs.shareSessionMemory ? "shared" : "chat" };
}

function sortMemory(items: MemoryFileSummary[]): MemoryFileSummary[] {
  return items.sort((a, b) => (a.name === "MEMORY.md" ? -1 : b.name === "MEMORY.md" ? 1 : a.name.localeCompare(b.name)));
}

export function registerMemoryRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  const store = createPrivateMemoryStore(deps.db);

  app.get("/memory", async (request, reply) => {
    if ((request.query as { sessionId?: unknown } | undefined)?.sessionId === undefined) {
      return { items: [], scope: "chat", requiresSession: true };
    }
    const ctx = await memoryScope(deps, request, reply);
    if (ctx === null) return reply;
    try {
      return { items: sortMemory(await store.list(ctx.uid, ctx.ns)), scope: ctx.scope };
    } catch (err) {
      return storeError(reply, err);
    }
  });

  app.get("/memory/:name", async (request, reply) => {
    const { name } = request.params as { name: string };
    if (!isValidMemoryName(name)) return invalidName(reply);
    const ctx = await memoryScope(deps, request, reply);
    if (ctx === null) return reply;
    try {
      const doc = await store.read(ctx.uid, ctx.ns, name);
      if (doc === null) return sendError(reply, 404, "not_found", "Memory file not found.");
      return { ...doc, scope: ctx.scope };
    } catch (err) {
      return storeError(reply, err);
    }
  });

  app.put("/memory/:name", async (request, reply) => {
    const { name } = request.params as { name: string };
    if (!isValidMemoryName(name)) return invalidName(reply);
    const parsed = memoryPutBodySchema.safeParse(request.body ?? undefined);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const ctx = await memoryScope(deps, request, reply);
    if (ctx === null) return reply;
    const { content, ifRevision } = parsed.data;
    try {
      const saved = await store.save(ctx.uid, ctx.ns, name, content, ifRevision);
      return { ...saved, scope: ctx.scope };
    } catch (err) {
      return storeError(reply, err);
    }
  });

  app.delete("/memory/:name", async (request, reply) => {
    const { name } = request.params as { name: string };
    if (!isValidMemoryName(name)) return invalidName(reply);
    const ctx = await memoryScope(deps, request, reply);
    if (ctx === null) return reply;
    try {
      const removed = await store.remove(ctx.uid, ctx.ns, name);
      if (!removed) return sendError(reply, 404, "not_found", "Memory file not found.");
      return reply.code(204).send();
    } catch (err) {
      return storeError(reply, err);
    }
  });
}
