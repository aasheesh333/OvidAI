import { createHash } from "node:crypto";
import type { FastifyInstance, FastifyReply } from "fastify";
import { sessions } from "@ovid/db";
import {
  isValidMemoryName,
  MEMORY_DIR,
  memoryPutBodySchema,
  type FileTreeNode,
  type MemoryFileDto,
  type MemoryFileSummary,
} from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { WorkerUnavailableError } from "../workerClient.js";
import { badRequest, sendError, zodBadRequest } from "./http.js";
import { callWarmWorker, relayWorkerError, workerOr503, workerUnavailable } from "./workspace.js";

/**
 * Wave 4 (SE-006) — the agent's memory files, for the user to read, edit and
 * delete. The memory_* tools keep them as Markdown under `.ovid/memory/` in
 * the user's cloud workspace (one per user, shared by every chat — R2), so
 * these routes go through the same worker file service as Studio, anchored on
 * the user's most recent chat (the file service addresses a workspace by a
 * session the caller owns).
 *
 *  - GET    /memory          → { items: [{ name, sizeBytes }] }
 *  - GET    /memory/:name    → { name, content, revision }
 *  - PUT    /memory/:name    { content, ifRevision? } → { name, content, revision }
 *  - DELETE /memory/:name    → 204
 *
 * A user with no chat yet has no workspace: the list is empty and a write
 * answers 409 no_workspace.
 */

function revisionOf(content: string): string {
  return createHash("sha256").update(content, "utf8").digest("hex");
}

async function anchorSession(deps: GatewayDeps, uid: string): Promise<string | null> {
  const { rows } = await sessions.list(deps.db, uid, 1);
  return rows[0]?.id ?? null;
}

function invalidName(reply: FastifyReply): FastifyReply {
  return badRequest(reply, "Use a plain .md file name (up to 80 characters), for example notes.md.");
}

function collectFiles(nodes: readonly FileTreeNode[] | undefined, out: MemoryFileSummary[]): void {
  for (const n of nodes ?? []) {
    if (n.type === "file" && isValidMemoryName(n.name)) {
      out.push({ name: n.name, sizeBytes: n.sizeBytes ?? 0 });
    }
    // Memory is a flat directory; nested folders are not memory files.
  }
}

export function registerMemoryRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.get("/memory", async (request, reply) => {
    const { uid } = request.principal;
    const sid = await anchorSession(deps, uid);
    if (sid === null) return { items: [] };
    const worker = workerOr503(deps, reply);
    if (worker === null) return reply;
    const result = await callWarmWorker(deps, request, reply, { sessionId: sid, uid }, () =>
      worker.getTree(uid, sid, MEMORY_DIR),
    );
    if (result === null) return reply;
    if (!result.ok) {
      // No memory folder yet = no memories.
      if (result.status === 404) return { items: [] };
      return relayWorkerError(reply, result.status, result.error.error.code, result.error.error.message);
    }
    const items: MemoryFileSummary[] = [];
    // A subtree answer lists the folder's children as its roots.
    collectFiles(result.value.tree.roots, items);
    items.sort((a, b) =>
      a.name === "MEMORY.md" ? -1 : b.name === "MEMORY.md" ? 1 : a.name.localeCompare(b.name),
    );
    return { items };
  });

  app.get("/memory/:name", async (request, reply) => {
    const { name } = request.params as { name: string };
    if (!isValidMemoryName(name)) return invalidName(reply);
    const { uid } = request.principal;
    const sid = await anchorSession(deps, uid);
    if (sid === null) return sendError(reply, 404, "not_found", "Memory file not found.");
    const worker = workerOr503(deps, reply);
    if (worker === null) return reply;
    let result;
    try {
      result = await worker.getFile(uid, sid, `${MEMORY_DIR}/${name}`);
    } catch (err) {
      if (err instanceof WorkerUnavailableError) return workerUnavailable(reply);
      throw err;
    }
    if (!result.ok) {
      if (result.status === 404) return sendError(reply, 404, "not_found", "Memory file not found.");
      return relayWorkerError(reply, result.status, result.error.error.code, result.error.error.message);
    }
    if (result.value.kind !== "content") {
      return sendError(reply, 413, "file_too_large", "This memory file is too large to open here.");
    }
    const content = Buffer.from(result.value.contentBase64, "base64").toString("utf8");
    const body: MemoryFileDto = { name, content, revision: revisionOf(content) };
    return body;
  });

  app.put("/memory/:name", async (request, reply) => {
    const { name } = request.params as { name: string };
    if (!isValidMemoryName(name)) return invalidName(reply);
    const parsed = memoryPutBodySchema.safeParse(request.body ?? undefined);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    if (parsed.data.content.includes("\u0000")) {
      return badRequest(reply, "Memory must be plain text.");
    }
    const { uid } = request.principal;
    const sid = await anchorSession(deps, uid);
    if (sid === null) {
      return sendError(
        reply,
        409,
        "no_workspace",
        "Start a chat first. Memory lives in your cloud workspace.",
      );
    }
    const worker = workerOr503(deps, reply);
    if (worker === null) return reply;
    const content = parsed.data.content;
    const ifRevision = parsed.data.ifRevision;
    const result = await callWarmWorker(deps, request, reply, { sessionId: sid, uid }, () =>
      worker.putFile(
        uid,
        sid,
        `${MEMORY_DIR}/${name}`,
        Buffer.from(content, "utf8").toString("base64"),
        ifRevision !== undefined ? { ifMatchSha256: ifRevision } : {},
      ),
    );
    if (result === null) return reply;
    if (!result.ok) {
      if (result.status === 409 && result.error.error.code === "baseline_mismatch") {
        return sendError(
          reply,
          409,
          "baseline_mismatch",
          "This memory changed since you opened it. Reload it and try again.",
        );
      }
      return relayWorkerError(reply, result.status, result.error.error.code, result.error.error.message);
    }
    const body: MemoryFileDto = { name, content, revision: revisionOf(content) };
    return body;
  });

  app.delete("/memory/:name", async (request, reply) => {
    const { name } = request.params as { name: string };
    if (!isValidMemoryName(name)) return invalidName(reply);
    const { uid } = request.principal;
    const sid = await anchorSession(deps, uid);
    if (sid === null) return sendError(reply, 404, "not_found", "Memory file not found.");
    const worker = workerOr503(deps, reply);
    if (worker === null) return reply;
    const result = await callWarmWorker(deps, request, reply, { sessionId: sid, uid }, () =>
      worker.deleteFile(uid, sid, `${MEMORY_DIR}/${name}`, false),
    );
    if (result === null) return reply;
    if (!result.ok) {
      if (result.status === 404) return sendError(reply, 404, "not_found", "Memory file not found.");
      return relayWorkerError(reply, result.status, result.error.error.code, result.error.error.message);
    }
    return reply.code(204).send();
  });
}
