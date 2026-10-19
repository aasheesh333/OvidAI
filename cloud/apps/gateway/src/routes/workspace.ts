import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { fileManifests, sessions } from "@ovid/db";
import {
  HYDRATE_JOB_NAME,
  HIBERNATE_JOB_NAME,
  storageJobId,
} from "@ovid/queue";
import {
  DEFAULT_HYDRATE_WAIT_MS,
  makeWorkspaceDirBodySchema,
  moveWorkspacePathBodySchema,
  putWorkspaceFileBodySchema,
  uiManifestSchema,
  type WorkspaceDeleteResponse,
  type WorkspaceMkdirResponse,
  type WorkspaceMoveResponse,
  type WorkspaceFileRedirect,
  type WorkspaceFileResponse,
  type WorkspaceFileWriteResponse,
  type WorkspaceTreeResponse,
} from "@ovid/shared";
import {
  KeyLayoutError,
  WorkspaceStateError,
  assertSafeRelPath,
  awaitWarm,
  shouldPresign,
} from "@ovid/storage";
import type { GatewayDeps } from "../app.js";
import { WorkerUnavailableError, type WorkerResult } from "../workerClient.js";
import { badRequest, isUuid, notFound, queryValue, sendError, zodBadRequest } from "./http.js";

/**
 * Workspace routes (P7 Task 12) — the Studio's virtual file tree.
 *
 * Three surfaces, one ownership rule (wrong owner and unknown session are
 * the same 404, before any body/path work):
 *
 *  - GET  .../workspace/tree — the <100 ms SLA path: a cold/hydrating row is
 *    answered from its stored uiTree with ZERO worker calls and ZERO
 *    extraction; only warm/no-row/hibernating sessions proxy the worker's
 *    live tree.
 *  - GET  .../workspace/file?path=… — ALWAYS proxied (the worker owns
 *    warm-vs-cold, including the lazy single-member archive read).
 *  - PUT  .../workspace/file — write-through: hydrate-if-cold (awaitWarm,
 *    202 "hydrating" on timeout — the client retries on the
 *    workspace_hydrated event), then the worker's atomic temp+rename write.
 *  - POST .../workspace/hydrate | hibernate — manual state controls.
 *
 * Activity bumps: file GET/PUT and manual controls bump the tracker (Studio
 * interaction is activity); the passive tree view does NOT.
 */

/** Fallback PUT cap when the composition did not thread one (8 MiB = 8 × 1 MiB). */
export const DEFAULT_PUT_MAX_BYTES = 8_388_608;

/** Route-level JSON body ceiling: base64 inflates ~4/3, plus JSON overhead. */
function putBodyLimit(putMaxBytes: number): number {
  return Math.max(1_048_576, putMaxBytes * 2);
}

/**
 * Strict base64 decode (mirrors the worker file service): canonical
 * padding/length/alphabet and the re-encoded form must equal the input —
 * Node's Buffer.from silently ignores garbage, so it cannot be trusted alone.
 */
function decodeBase64(input: string): Buffer | null {
  if (input.length % 4 !== 0) return null;
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(input)) return null;
  const buf = Buffer.from(input, "base64");
  if (buf.toString("base64") !== input) return null;
  return buf;
}

/**
 * Wire encoding for an inline read: utf8 iff the content type is textual
 * (text/* or the json-ish application set). `shouldPresign` with sizeBytes 0
 * can never trip its size arm, so this reuses the ONE textual-type set the
 * storage package already defines instead of growing a second copy here.
 */
function encodingFor(contentType: string): "utf8" | "base64" {
  return shouldPresign(contentType, 0, Number.POSITIVE_INFINITY) ? "base64" : "utf8";
}

/** Best-effort activity bump — a redis blip must never fail the request. */
let warnedNoActivity = false;
async function bumpActivity(deps: GatewayDeps, sessionId: string): Promise<void> {
  if (deps.activity === undefined) {
    if (!warnedNoActivity) {
      warnedNoActivity = true;
      console.warn(
        "[gateway] workspace activity bump skipped: no ActivityTracker configured (GatewayDeps.activity missing)",
      );
    }
    return;
  }
  await deps.activity.bump(sessionId).catch(() => {});
}

/** The worker proxy is the route's core — absent means loud 503, never a silent no-op. */
let warnedNoWorker = false;
function workerOr503(deps: GatewayDeps, reply: FastifyReply) {
  if (deps.worker === undefined) {
    if (!warnedNoWorker) {
      warnedNoWorker = true;
      console.warn(
        "[gateway] workspace route refused: no WorkerClient configured (GatewayDeps.worker missing)",
      );
    }
    sendError(
      reply,
      503,
      "file_service_not_configured",
      "The workspace file service is not configured on this deployment.",
    );
    return null;
  }
  return deps.worker;
}

/** 503 for every transport failure of the worker proxy. */
function workerUnavailable(reply: FastifyReply): FastifyReply {
  return sendError(
    reply,
    503,
    "unavailable",
    "The workspace file service is temporarily unavailable; please retry shortly.",
  );
}

/**
 * Relay a worker HTTP-level failure. 404/400/413 pass through with the
 * worker's code+message; anything else (and 409 outside the PUT retry path)
 * collapses to 503 — the gateway never invents detail it does not have.
 */
function relayWorkerError(
  reply: FastifyReply,
  status: number,
  code: string,
  message: string,
): FastifyReply {
  if (status === 404) return sendError(reply, 404, "not_found", message);
  if (status === 400) return sendError(reply, 400, "bad_request", message);
  if (status === 413) return sendError(reply, 413, "file_too_large", message);
  // Wave 2 Studio (ST-007/ST-008): a lost precondition is the client's
  // signal to show its conflict UI — relayed verbatim, never collapsed to
  // 503. `not_warm` is NOT in this set: it drives the re-warm retry.
  if (status === 409 && PRECONDITION_CODES.has(code)) {
    return sendError(reply, 409, code, message);
  }
  return workerUnavailable(reply);
}

/** Worker 409 codes that mean "your precondition failed", relayed as 409. */
const PRECONDITION_CODES = new Set(["baseline_mismatch", "already_exists", "not_empty"]);

/**
 * Hydrate-if-cold, then call the worker, with ONE re-warm + retry when the
 * worker reports `not_warm` (the workspace was hibernated between awaitWarm
 * and the call). Shared by every mutating route (PUT/DELETE/move/mkdir).
 *
 * Returns the worker result, or null when this helper already replied:
 * 202 {status:'hydrating'} when hydration outlasts the wait (the client
 * retries once warm), or 503 for queue/transport failures and a second
 * not_warm.
 */
async function callWarmWorker<T>(
  deps: GatewayDeps,
  request: FastifyRequest,
  reply: FastifyReply,
  ref: { sessionId: string; uid: string },
  call: () => Promise<WorkerResult<T>>,
): Promise<WorkerResult<T> | null> {
  const warmUp = (): Promise<unknown> =>
    awaitWarm(deps.db, deps.queues.hydrate, { sessionId: ref.sessionId, userId: ref.uid }, {
      reason: "write",
      timeoutMs: deps.hydrateWaitMs ?? DEFAULT_HYDRATE_WAIT_MS,
      fileManifests,
    });

  // A timeout is NOT an error: the client gets 202 and retries on the
  // workspace_hydrated event (the job is already queued — awaitWarm dedupes
  // through the storage job id).
  const warm = async (): Promise<boolean> => {
    try {
      await warmUp();
      return true;
    } catch (err) {
      if (err instanceof WorkspaceStateError && err.code === "hydrate_timeout") {
        reply.code(202).send({ status: "hydrating" });
        return false;
      }
      request.log.error({ err, sessionId: ref.sessionId }, "awaitWarm failed on a workspace write");
      sendError(
        reply,
        503,
        "unavailable",
        "The hydrate queue is temporarily unavailable; please retry shortly.",
      );
      return false;
    }
  };
  const isNotWarm = (r: WorkerResult<T>): boolean =>
    !r.ok && r.status === 409 && !PRECONDITION_CODES.has(r.error.error.code);

  if (!(await warm())) return null;
  let result: WorkerResult<T>;
  try {
    result = await call();
  } catch (err) {
    if (err instanceof WorkerUnavailableError) {
      workerUnavailable(reply);
      return null;
    }
    throw err;
  }

  // Eviction race: re-warm ONCE and retry; a second not_warm collapses to 503.
  if (isNotWarm(result)) {
    if (!(await warm())) return null;
    try {
      result = await call();
    } catch (err) {
      if (err instanceof WorkerUnavailableError) {
        workerUnavailable(reply);
        return null;
      }
      throw err;
    }
    if (isNotWarm(result)) {
      request.log.warn({ sessionId: ref.sessionId }, "worker refused a write not_warm twice");
      workerUnavailable(reply);
      return null;
    }
  }
  return result;
}

/** Path validation shared by the routes: KeyLayoutError → 400, else the normalized path. */
function safeRel(reply: FastifyReply, raw: string): string | null {
  try {
    return assertSafeRelPath(raw);
  } catch (err) {
    if (err instanceof KeyLayoutError) {
      badRequest(reply, err.message);
      return null;
    }
    throw err;
  }
}

export function registerWorkspaceRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  // -- GET tree ------------------------------------------------------------

  app.get("/sessions/:id/workspace/tree", async (request, reply) => {
    const { id: sessionId } = request.params as { id: string };
    const { uid } = request.principal;

    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);

    const row = await fileManifests.get(deps.db, sessionId);

    // ST-015: `?path=` lists ONE folder (the rest of a pruned manifest
    // directory). Only a warm workspace has a live tree to list; a cold or
    // hydrating one answers 409 not_warm so the client can wake it first.
    const rawSub = queryValue((request.query as Record<string, string | string[] | undefined>).path);
    if (rawSub !== null && rawSub !== "") {
      const sub = safeRel(reply, rawSub);
      if (sub === null) return reply;
      if (row !== null && (row.state === "cold" || row.state === "hydrating")) {
        return sendError(
          reply,
          409,
          "not_warm",
          "The workspace is asleep; wake it to list this folder.",
        );
      }
      const subWorker = workerOr503(deps, reply);
      if (subWorker === null) return reply;
      let subLive;
      try {
        subLive = await subWorker.getTree(uid, sessionId, sub);
      } catch (err) {
        if (err instanceof WorkerUnavailableError) return workerUnavailable(reply);
        throw err;
      }
      if (!subLive.ok) {
        return relayWorkerError(
          reply,
          subLive.status,
          subLive.error.error.code,
          subLive.error.error.message,
        );
      }
      const subBody: WorkspaceTreeResponse = {
        sessionId,
        state: "warm",
        generation: row?.generation ?? 0,
        source: "live",
        tree: subLive.value.tree,
      };
      return reply.code(200).send(subBody);
    }

    // Manifest path (the SLA path): cold or hydrating rows answer from the
    // stored pruned tree — zero worker calls, zero extraction. The stored
    // tree is re-validated: a corrupt jsonb must surface as a loud 500, never
    // as a silently-wrong client tree.
    if (row !== null && (row.state === "cold" || row.state === "hydrating")) {
      const parsed = uiManifestSchema.safeParse(row.uiTree);
      if (!parsed.success) {
        request.log.error(
          { sessionId },
          "stored uiTree fails uiManifestSchema — answering 500",
        );
        return sendError(reply, 500, "internal", "Internal server error.");
      }
      const body: WorkspaceTreeResponse = {
        sessionId,
        state: row.state,
        generation: row.generation,
        source: "manifest",
        tree: parsed.data,
      };
      return reply.code(200).send(body);
    }

    // Live path: warm, hibernating (dir still present until the pack
    // completes) or never-registered sessions proxy the worker's live tree.
    const worker = workerOr503(deps, reply);
    if (worker === null) return reply;
    let live;
    try {
      live = await worker.getTree(uid, sessionId);
    } catch (err) {
      if (err instanceof WorkerUnavailableError) return workerUnavailable(reply);
      throw err;
    }
    if (!live.ok) {
      request.log.warn({ sessionId, status: live.status }, "worker tree call failed");
      return relayWorkerError(reply, live.status, live.error.error.code, live.error.error.message);
    }
    const body: WorkspaceTreeResponse = {
      sessionId,
      state: "warm",
      generation: row?.generation ?? 0,
      source: "live",
      tree: live.value.tree,
    };
    return reply.code(200).send(body);
  });

  // -- GET file ------------------------------------------------------------

  app.get("/sessions/:id/workspace/file", async (request, reply) => {
    const { id: sessionId } = request.params as { id: string };
    const { uid } = request.principal;

    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);

    // Path validation BEFORE the proxy (a hostile path never reaches the
    // worker) and BEFORE the activity bump (a 400 is not interaction).
    const rawPath = queryValue((request.query as Record<string, string | string[] | undefined>).path);
    if (rawPath === null) {
      return badRequest(reply, "query parameter 'path' is required.");
    }
    let rel: string;
    try {
      rel = assertSafeRelPath(rawPath);
    } catch (err) {
      if (err instanceof KeyLayoutError) return badRequest(reply, err.message);
      throw err;
    }

    // Studio interaction = activity: a read keeps the workspace warm.
    await bumpActivity(deps, sessionId);

    const worker = workerOr503(deps, reply);
    if (worker === null) return reply;
    let result;
    try {
      result = await worker.getFile(uid, sessionId, rel);
    } catch (err) {
      if (err instanceof WorkerUnavailableError) return workerUnavailable(reply);
      throw err;
    }
    if (!result.ok) {
      return relayWorkerError(
        reply,
        result.status,
        result.error.error.code,
        result.error.error.message,
      );
    }

    const value = result.value;
    if (value.kind === "redirect") {
      const body: WorkspaceFileRedirect = {
        path: value.path,
        sizeBytes: value.sizeBytes,
        contentType: value.contentType,
        downloadUrl: value.downloadUrl,
        expiresAt: value.expiresAt,
      };
      return reply.code(200).send(body);
    }
    const encoding = encodingFor(value.contentType);
    const body: WorkspaceFileResponse = {
      path: value.path,
      sizeBytes: value.sizeBytes,
      contentType: value.contentType,
      encoding,
      content:
        encoding === "utf8"
          ? Buffer.from(value.contentBase64, "base64").toString("utf8")
          : value.contentBase64,
    };
    return reply.code(200).send(body);
  });

  // -- PUT file (write-through) ---------------------------------------------

  app.put(
    "/sessions/:id/workspace/file",
    { bodyLimit: putBodyLimit(deps.putMaxBytes ?? DEFAULT_PUT_MAX_BYTES) },
    async (request, reply) => {
      const { id: sessionId } = request.params as { id: string };
      const { uid } = request.principal;

      if (!isUuid(sessionId)) return notFound(reply);
      const session = await sessions.get(deps.db, sessionId, uid);
      if (session === null) return notFound(reply);

      // Exactly one content field (zod refine); unknown keys rejected.
      const parsed = putWorkspaceFileBodySchema.safeParse(request.body ?? undefined);
      if (!parsed.success) return zodBadRequest(reply, parsed.error);
      const { path, contentBase64, contentUtf8 } = parsed.data;

      const content =
        contentBase64 !== undefined
          ? decodeBase64(contentBase64)
          : Buffer.from(contentUtf8!, "utf8");
      if (content === null) {
        return badRequest(reply, "contentBase64 must be valid base64.");
      }

      const cap = deps.putMaxBytes ?? DEFAULT_PUT_MAX_BYTES;
      if (content.length > cap) {
        return badRequest(reply, `file too large (max ${cap} bytes).`);
      }

      let rel: string;
      try {
        rel = assertSafeRelPath(path);
      } catch (err) {
        if (err instanceof KeyLayoutError) return badRequest(reply, err.message);
        throw err;
      }

      const worker = workerOr503(deps, reply);
      if (worker === null) return reply;

      // Hydrate-if-cold + one eviction-race retry (callWarmWorker). The
      // worker serializes precondition + replacement with overlapping Studio
      // mutations in its process. Raw agent/shell and other-process writes
      // do not participate: ST-007 is still partial for those races.
      const b64 = content.toString("base64");
      const preconditions = {
        ...(parsed.data.ifMatchSha256 !== undefined
          ? { ifMatchSha256: parsed.data.ifMatchSha256 }
          : {}),
        ...(parsed.data.ifNoneMatch === "*" ? { ifNoneMatch: true } : {}),
      };
      const result = await callWarmWorker(deps, request, reply, { sessionId, uid }, () =>
        worker.putFile(uid, sessionId, rel, b64, preconditions),
      );
      if (result === null) return reply;

      if (!result.ok) {
        return relayWorkerError(
          reply,
          result.status,
          result.error.error.code,
          result.error.error.message,
        );
      }

      await bumpActivity(deps, sessionId);
      const body: WorkspaceFileWriteResponse = {
        path: result.value.path,
        sizeBytes: result.value.sizeBytes,
        sha256: result.value.sha256,
      };
      return reply.code(200).send(body);
    },
  );

  // -- DELETE file / folder (Wave 2 Studio, ST-008) ---------------------------

  app.delete("/sessions/:id/workspace/file", async (request, reply) => {
    const { id: sessionId } = request.params as { id: string };
    const { uid } = request.principal;

    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);

    const query = request.query as Record<string, string | string[] | undefined>;
    const rawPath = queryValue(query.path);
    if (rawPath === null) return badRequest(reply, "query parameter 'path' is required.");
    const rel = safeRel(reply, rawPath);
    if (rel === null) return reply;
    const recursive = queryValue(query.recursive) === "true";

    const worker = workerOr503(deps, reply);
    if (worker === null) return reply;
    const result = await callWarmWorker(deps, request, reply, { sessionId, uid }, () =>
      worker.deleteFile(uid, sessionId, rel, recursive),
    );
    if (result === null) return reply;
    if (!result.ok) {
      return relayWorkerError(reply, result.status, result.error.error.code, result.error.error.message);
    }
    await bumpActivity(deps, sessionId);
    const body: WorkspaceDeleteResponse = { path: result.value.path, type: result.value.type };
    return reply.code(200).send(body);
  });

  // -- POST move / rename (Wave 2 Studio, ST-008) ------------------------------

  app.post("/sessions/:id/workspace/move", async (request, reply) => {
    const { id: sessionId } = request.params as { id: string };
    const { uid } = request.principal;

    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);

    const parsed = moveWorkspacePathBodySchema.safeParse(request.body ?? undefined);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const from = safeRel(reply, parsed.data.from);
    if (from === null) return reply;
    const to = safeRel(reply, parsed.data.to);
    if (to === null) return reply;

    const worker = workerOr503(deps, reply);
    if (worker === null) return reply;
    const result = await callWarmWorker(deps, request, reply, { sessionId, uid }, () =>
      worker.movePath(uid, sessionId, from, to),
    );
    if (result === null) return reply;
    if (!result.ok) {
      return relayWorkerError(reply, result.status, result.error.error.code, result.error.error.message);
    }
    await bumpActivity(deps, sessionId);
    const body: WorkspaceMoveResponse = { from: result.value.from, to: result.value.to };
    return reply.code(200).send(body);
  });

  // -- POST mkdir (Wave 2 Studio, ST-008) --------------------------------------

  app.post("/sessions/:id/workspace/mkdir", async (request, reply) => {
    const { id: sessionId } = request.params as { id: string };
    const { uid } = request.principal;

    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);

    const parsed = makeWorkspaceDirBodySchema.safeParse(request.body ?? undefined);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const rel = safeRel(reply, parsed.data.path);
    if (rel === null) return reply;

    const worker = workerOr503(deps, reply);
    if (worker === null) return reply;
    const result = await callWarmWorker(deps, request, reply, { sessionId, uid }, () =>
      worker.makeDir(uid, sessionId, rel),
    );
    if (result === null) return reply;
    if (!result.ok) {
      return relayWorkerError(reply, result.status, result.error.error.code, result.error.error.message);
    }
    await bumpActivity(deps, sessionId);
    const body: WorkspaceMkdirResponse = { path: result.value.path, created: result.value.created };
    return reply.code(200).send(body);
  });

  // -- POST hydrate -----------------------------------------------------------

  app.post("/sessions/:id/workspace/hydrate", async (request, reply) => {
    const { id: sessionId } = request.params as { id: string };
    const { uid } = request.principal;

    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);

    const row = await fileManifests.get(deps.db, sessionId);
    // No row = never hibernated: the disk IS the truth, nothing to restore.
    if (row === null || row.state === "warm") {
      return reply.code(200).send({ status: "warm" });
    }
    if (row.state === "hydrating") {
      return reply.code(202).send({ status: "hydrating" });
    }
    if (row.state === "hibernating") {
      return sendError(
        reply,
        409,
        "invalid_state",
        "The workspace is hibernating; retry once it completes.",
      );
    }

    // cold → enqueue the hydrate job (idempotent through the storage job id).
    try {
      await deps.queues.hydrate.add(
        HYDRATE_JOB_NAME,
        {
          sessionId,
          userId: uid,
          generation: row.generation,
          reason: "manual",
        },
        { jobId: storageJobId(sessionId, row.generation) },
      );
    } catch (err) {
      request.log.error({ err, sessionId }, "hydrate enqueue failed");
      return sendError(
        reply,
        503,
        "unavailable",
        "The hydrate queue is temporarily unavailable; please retry shortly.",
      );
    }
    return reply.code(202).send({ status: "hydrating" });
  });

  // -- POST hibernate ---------------------------------------------------------

  app.post("/sessions/:id/workspace/hibernate", async (request, reply) => {
    const { id: sessionId } = request.params as { id: string };
    const { uid } = request.principal;

    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);

    const row = await fileManifests.get(deps.db, sessionId);
    if (row === null) {
      // Documented seam: the sweeper registers warm workspaces within 30 s —
      // a brand-new session may not have a row yet. 409, not 500.
      return sendError(
        reply,
        409,
        "invalid_state",
        "The workspace is not registered yet; the sweeper registers warm workspaces within 30 s — retry shortly.",
      );
    }
    if (row.state === "cold") {
      return reply.code(200).send({ status: "cold" });
    }
    if (row.state === "hydrating" || row.state === "hibernating") {
      return sendError(
        reply,
        409,
        "invalid_state",
        "The workspace is mid-transition; retry once it settles.",
      );
    }

    // warm → enqueue the pack job claiming generation + 1.
    const generation = row.generation + 1;
    try {
      await deps.queues.hibernate.add(
        HIBERNATE_JOB_NAME,
        { sessionId, userId: uid, generation, reason: "manual" },
        { jobId: storageJobId(sessionId, generation) },
      );
    } catch (err) {
      request.log.error({ err, sessionId }, "hibernate enqueue failed");
      return sendError(
        reply,
        503,
        "unavailable",
        "The hibernate queue is temporarily unavailable; please retry shortly.",
      );
    }
    return reply.code(202).send({ status: "hibernating" });
  });
}
