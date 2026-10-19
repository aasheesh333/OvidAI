import { createHash } from "node:crypto";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { sessions, userPreferences } from "@ovid/db";
import { isValidMemoryName, memoryDirectoryFor, memoryPutBodySchema, type FileTreeNode, type MemoryFileDto, type MemoryFileSummary } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { WorkerUnavailableError } from "../workerClient.js";
import { badRequest, isUuid, notFound, sendError, zodBadRequest } from "./http.js";
import { callWarmWorker, relayWorkerError, workerOr503, workerUnavailable } from "./workspace.js";

/**
 * Memory is isolated per chat by default (R1), even though workspace storage is
 * shared per user (R2). Every file operation requires an explicit owned chat.
 * Only the user's explicit sharing preference selects legacy .ovid/memory;
 * no recent-chat fallback, migration, or automatic global memory injection.
 */
async function memoryScope(deps: GatewayDeps, request: FastifyRequest, reply: FastifyReply) {
  const sid = (request.query as { sessionId?: unknown } | undefined)?.sessionId;
  if (sid === undefined) {
    sendError(reply, 409, "no_workspace", "Open a cloud chat first to manage its memory.");
    return null;
  }
  const uid = request.principal.uid;
  if (typeof sid !== "string" || !isUuid(sid) || (await sessions.get(deps.db, sid, uid)) === null) {
    notFound(reply);
    return null;
  }
  const prefs = await userPreferences.get(deps.db, uid);
  return { sid, uid, directory: memoryDirectoryFor(sid, prefs.shareSessionMemory), scope: prefs.shareSessionMemory ? "shared" : "chat" };
}

function revisionOf(content: string): string {
  return createHash("sha256").update(content, "utf8").digest("hex");
}
function invalidName(reply: FastifyReply): FastifyReply {
  return badRequest(reply, "Use a plain .md file name (up to 80 characters), for example notes.md.");
}
function collectFiles(nodes: readonly FileTreeNode[] | undefined, out: MemoryFileSummary[]): void {
  for (const n of nodes ?? []) {
    if (n.type === "file" && isValidMemoryName(n.name)) out.push({ name: n.name, sizeBytes: n.sizeBytes ?? 0 });
  }
}

export function registerMemoryRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.get("/memory", async (request, reply) => {
    if ((request.query as { sessionId?: unknown } | undefined)?.sessionId === undefined) {
      return { items: [], scope: "chat", requiresSession: true };
    }
    const ctx = await memoryScope(deps, request, reply);
    if (ctx === null) return reply;
    const { sid, uid, directory, scope } = ctx;
    const worker = workerOr503(deps, reply);
    if (worker === null) return reply;
    const result = await callWarmWorker(deps, request, reply, { sessionId: sid, uid }, () => worker.getTree(uid, sid, directory));
    if (result === null) return reply;
    if (!result.ok) {
      if (result.status === 404) return { items: [], scope };
      return relayWorkerError(reply, result.status, result.error.error.code, result.error.error.message);
    }
    const items: MemoryFileSummary[] = [];
    collectFiles(result.value.tree.roots, items);
    items.sort((a, b) => a.name === "MEMORY.md" ? -1 : b.name === "MEMORY.md" ? 1 : a.name.localeCompare(b.name));
    return { items, scope };
  });

  app.get("/memory/:name", async (request, reply) => {
    const { name } = request.params as { name: string };
    if (!isValidMemoryName(name)) return invalidName(reply);
    const ctx = await memoryScope(deps, request, reply);
    if (ctx === null) return reply;
    const { sid, uid, directory, scope } = ctx;
    const worker = workerOr503(deps, reply);
    if (worker === null) return reply;
    let result;
    try { result = await worker.getFile(uid, sid, `${directory}/${name}`); }
    catch (err) {
      if (err instanceof WorkerUnavailableError) return workerUnavailable(reply);
      throw err;
    }
    if (!result.ok) {
      if (result.status === 404) return sendError(reply, 404, "not_found", "Memory file not found.");
      return relayWorkerError(reply, result.status, result.error.error.code, result.error.error.message);
    }
    if (result.value.kind !== "content") return sendError(reply, 413, "file_too_large", "This memory file is too large to open here.");
    const content = Buffer.from(result.value.contentBase64, "base64").toString("utf8");
    const body: MemoryFileDto = { name, content, revision: revisionOf(content) };
    return { ...body, scope };
  });

  app.put("/memory/:name", async (request, reply) => {
    const { name } = request.params as { name: string };
    if (!isValidMemoryName(name)) return invalidName(reply);
    const parsed = memoryPutBodySchema.safeParse(request.body ?? undefined);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    if (parsed.data.content.includes("\u0000")) return badRequest(reply, "Memory must be plain text.");
    if (Buffer.byteLength(parsed.data.content, "utf8") > 32 * 1024) return badRequest(reply, "Memory must be at most 32 KiB.");
    const ctx = await memoryScope(deps, request, reply);
    if (ctx === null) return reply;
    const { sid, uid, directory, scope } = ctx;
    const worker = workerOr503(deps, reply);
    if (worker === null) return reply;
    const { content, ifRevision } = parsed.data;
    const result = await callWarmWorker(deps, request, reply, { sessionId: sid, uid }, () => worker.putFile(
      uid, sid, `${directory}/${name}`, Buffer.from(content, "utf8").toString("base64"),
      ifRevision !== undefined ? { ifMatchSha256: ifRevision } : {},
    ));
    if (result === null) return reply;
    if (!result.ok) {
      if (result.status === 409 && result.error.error.code === "baseline_mismatch") return sendError(reply, 409, "baseline_mismatch", "This memory changed since you opened it. Reload it and try again.");
      return relayWorkerError(reply, result.status, result.error.error.code, result.error.error.message);
    }
    const body: MemoryFileDto = { name, content, revision: revisionOf(content) };
    return { ...body, scope };
  });

  app.delete("/memory/:name", async (request, reply) => {
    const { name } = request.params as { name: string };
    if (!isValidMemoryName(name)) return invalidName(reply);
    const ctx = await memoryScope(deps, request, reply);
    if (ctx === null) return reply;
    const { sid, uid, directory } = ctx;
    const worker = workerOr503(deps, reply);
    if (worker === null) return reply;
    const result = await callWarmWorker(deps, request, reply, { sessionId: sid, uid }, () => worker.deleteFile(uid, sid, `${directory}/${name}`, false));
    if (result === null) return reply;
    if (!result.ok) {
      if (result.status === 404) return sendError(reply, 404, "not_found", "Memory file not found.");
      return relayWorkerError(reply, result.status, result.error.error.code, result.error.error.message);
    }
    return reply.code(204).send();
  });
}
