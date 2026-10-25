/**
 * Internal file service (P7 Task 11) — the worker's warm-workspace read/write
 * surface, consumed by the gateway (Task 12) over the private `ovid-cloud`
 * network. It is NEVER host-published: `main.ts` listens on 0.0.0.0 inside
 * the container only, and every request must present the shared
 * `x-ovid-internal-token` header.
 *
 * Trust boundary (documented, deliberate): the gateway authenticates the end
 * user and enforces session ownership BEFORE proxying here. The service
 * therefore trusts `x-ovid-user-id` and never queries `sessions.user_id`
 * itself — a compromised gateway is already game over for the cloud.
 *
 * Read paths go through @ovid/storage's hydration engine:
 *  - WARM: `readWorkspaceFile` serves the disk file through the realpath jail;
 *  - COLD: the same call range-reads one member out of the archive and leaves
 *    the workspace dir ABSENT (the Studio lazy path — zero extraction).
 * Binary or oversize files are not inlined: they are registered through the
 * artifacts pipeline (`registerArtifact`) and answered with its presigned
 * download URL. That reuses the one presign mechanism we have and leaves a
 * `workspace_objects` artifact row as a real feature (download history).
 *
 * The service is built UNLISTENED (`buildFileService`) so tests drive it with
 * Fastify's `inject()`; `main.ts` owns `.listen()` and shutdown.
 */

import { stat } from "node:fs/promises";
import { join } from "node:path";
import Fastify, { type FastifyInstance, type FastifyReply } from "fastify";
import { assertSessionFileCapacity, ProjectFileLimitError, type Db } from "@ovid/db";
import type { EventLog } from "@ovid/events";
import type { UiManifest } from "@ovid/shared";
import { createInternalServiceAuth } from "./internalServiceAuth.js";
import { registerConnectionHealthRoutes } from "./connectionHealthRoutes.js";
import { registerStudioGitRoutes, type StudioGitRoutesDeps } from "./studioGitRoutes.js";
import { registerStudioPreviewRoutes } from "./studioPreviewRoutes.js";
import type { StudioPreviewManager } from "./studioPreview.js";
import type { ConnectionHealthInvocations } from "@ovid/mcp";
import {
  FileNotInArchiveError,
  FileTooLargeError,
  KeyLayoutError,
  NotFoundError,
  PreconditionFailedError,
  StorageError,
  WorkspaceStateError,
  assertSafeRelPath,
  contentTypeFor,
  deleteWorkspacePath,
  liveSubtree,
  liveTree,
  makeWorkspaceDir,
  moveWorkspacePath,
  readWorkspaceFile,
  registerArtifact,
  resolveWorkspaceDir,
  shouldPresign,
  writeWorkspaceFile,
  type ActivityTracker,
  type ArtifactWorkspaceObjectsRepo,
  type HydrateEventMirror,
  type HydrateFileManifestsRepo,
  type HydrateRunsRepo,
  type SandboxUidResolver,
  type StorageAdapter,
  type CdnConfig,
} from "@ovid/storage";

/** Cold-file redirect ceiling: extractFile buffers whole members (worker mem_limit 2 g). */
export const REDIRECT_MAX_BYTES = 64 * 1024 * 1024;

/** JSON body ceiling for PUT (the gateway caps decoded content at 8 MiB). */
const BODY_LIMIT_BYTES = 16 * 1024 * 1024;

export interface FileServiceDeps {
  db: Db;
  events: EventLog;
  storage: StorageAdapter;
  workspacesRoot: string;
  /**
   * Firebase userId → P2's numeric sandbox uid. Production wires
   * `users.allocateSandboxUid`; the file service must target the SAME
   * `{root}/{uid}/workspace` tree the agent runs in (C1).
   */
  sandboxUid: SandboxUidResolver;
  activity: ActivityTracker;
  internalToken: string;
  inlineMaxBytes: number;
  port: number;
  /** Default "0.0.0.0" (container-internal; never a host port). */
  host?: string;
  /** T9-review I2: the real @ovid/db repos the hydration/artifacts engines need. */
  fileManifests: HydrateFileManifestsRepo;
  /** The runs repo — the cross-session guard's runs half (liveSessionGuard). */
  runs: HydrateRunsRepo;
  eventMirror: HydrateEventMirror;
  workspaceObjects: ArtifactWorkspaceObjectsRepo;
  /** Default DEFAULT_PRESIGN_TTL_SECONDS (3600) inside registerArtifact. */
  presignTtlSeconds?: number;
  /**
   * W12: when configured, generated artifacts carry a signed CDN URL (the
   * object is immutable, so it is edge-cacheable for a year). Absent → the
   * existing presigned-S3 path is unchanged.
   */
  cdn?: CdnConfig;
  /** Production-composed Studio git surface; optional only for legacy file-service tests. */
  studioGit?: StudioGitRoutesDeps;
  /** Present only after the worker proves the studio_previews table exists. */
  studioPreviews?: StudioPreviewManager;
  /** Worker-owned health projection/refresh/disconnect lifecycle. */
  connectionHealthInvocations?: ConnectionHealthInvocations;
}

interface ErrorEnvelope {
  error: { code: string; message: string };
}

function fail(
  reply: FastifyReply,
  status: number,
  code: string,
  message: string,
): FastifyReply {
  const body: ErrorEnvelope = { error: { code, message } };
  return reply.code(status).send(body);
}

/**
 * Strict base64 decode: canonical padding/length/alphabet, and the re-encoded
 * form must equal the input (Node's Buffer.from silently ignores garbage).
 */
function decodeBase64(input: unknown): Buffer | null {
  if (typeof input !== "string") return null;
  if (input.length % 4 !== 0) return null;
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(input)) return null;
  const buf = Buffer.from(input, "base64");
  if (buf.toString("base64") !== input) return null;
  return buf;
}

/** The manifest of a workspace that does not exist yet (ST-003). */
function emptyManifest(): UiManifest {
  return {
    version: 1,
    generatedAt: new Date().toISOString(),
    truncated: false,
    totals: { files: 0, dirs: 0, bytes: 0 },
    roots: [],
  };
}

async function isDirectory(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isDirectory();
  } catch {
    return false;
  }
}

/** Map an engine error onto the pinned HTTP envelope; unknown → 500. */
function sendEngineError(reply: FastifyReply, err: unknown): FastifyReply {
  if (err instanceof KeyLayoutError) {
    return fail(reply, 400, "bad_request", err.message);
  }
  if (err instanceof FileNotInArchiveError || err instanceof NotFoundError) {
    return fail(reply, 404, "not_found", err.message);
  }
  if (err instanceof WorkspaceStateError && err.code === "not_warm") {
    return fail(reply, 409, "not_warm", err.message);
  }
  if (err instanceof FileTooLargeError) {
    return fail(reply, 413, "file_too_large", err.message);
  }
  if (err instanceof PreconditionFailedError) {
    // baseline_mismatch | already_exists | not_empty — the gateway relays
    // these 409s verbatim (only `not_warm` drives its re-warm retry).
    return fail(reply, 409, err.code, err.message);
  }
  if (err instanceof ProjectFileLimitError) {
    // W1 follow-up (0022): a project chat's file budget is full. Typed 4xx
    // before storage.put; the gateway relays the envelope verbatim.
    return fail(reply, 409, err.code, err.message);
  }
  if (err instanceof StorageError) {
    return fail(reply, 500, "internal", err.message);
  }
  const message = err instanceof Error ? err.message : String(err);
  return fail(reply, 500, "internal", message);
}

export function buildFileService(deps: FileServiceDeps): FastifyInstance {
  const app = Fastify({ logger: false, bodyLimit: BODY_LIMIT_BYTES });

  const hydrateDeps = {
    db: deps.db,
    events: deps.events,
    storage: deps.storage,
    workspacesRoot: deps.workspacesRoot,
    sandboxUid: deps.sandboxUid,
    activity: deps.activity,
    fileManifests: deps.fileManifests,
    runs: deps.runs,
    eventMirror: deps.eventMirror,
  };
  const opsDeps = {
    sandboxUid: deps.sandboxUid,
    workspacesRoot: deps.workspacesRoot,
    activity: deps.activity,
  };

  // -- internal-token gate (every route) ----------------------------------
  app.addHook("preHandler", createInternalServiceAuth(deps.internalToken));

  if (deps.studioGit !== undefined) registerStudioGitRoutes(app, deps.studioGit);
  if (deps.studioPreviews !== undefined) {
    registerStudioPreviewRoutes(app, {
      internalToken: deps.internalToken,
      previews: deps.studioPreviews,
    });
  }
  registerConnectionHealthRoutes(app, { invocations: deps.connectionHealthInvocations });

  // -- GET /internal/sessions/:sid/tree[?path=sub] ------------------------
  // ST-003: the agent workspace dir only exists once the agent has run a
  // tool for this user. A workspace that was never created is EMPTY, not an
  // error — 200 with an empty manifest so Studio renders its empty state.
  // `?path=` (ST-015) lists one folder of a warm workspace (the "load the
  // rest" of a pruned manifest directory); a missing folder is 404.
  app.get<{ Params: { sid: string }; Querystring: { path?: string } }>(
    "/internal/sessions/:sid/tree",
    async (req, reply) => {
      const userId = String(req.headers["x-ovid-user-id"]);
      const sub = req.query.path;
      try {
        const dir = await resolveWorkspaceDir(
          deps.sandboxUid,
          deps.workspacesRoot,
          userId,
          req.params.sid,
        );
        if (typeof sub === "string" && sub !== "") {
          const rel = assertSafeRelPath(sub);
          if (!(await isDirectory(dir))) {
            return fail(reply, 404, "not_found", `'${rel}' is not present in the workspace`);
          }
          return { tree: await liveSubtree(dir, rel) };
        }
        if (!(await isDirectory(dir))) {
          return { tree: emptyManifest() };
        }
        return { tree: await liveTree(dir) };
      } catch (err) {
        return sendEngineError(reply, err);
      }
    },
  );

  // -- DELETE /internal/sessions/:sid/file?path=...[&recursive=true] ------
  app.delete<{ Params: { sid: string }; Querystring: { path?: string; recursive?: string } }>(
    "/internal/sessions/:sid/file",
    async (req, reply) => {
      const userId = String(req.headers["x-ovid-user-id"]);
      const rawPath = req.query.path;
      if (typeof rawPath !== "string" || rawPath === "") {
        return fail(reply, 400, "bad_request", "query parameter 'path' is required");
      }
      try {
        return await deleteWorkspacePath(
          opsDeps,
          { userId, sessionId: req.params.sid, path: rawPath },
          { recursive: req.query.recursive === "true" },
        );
      } catch (err) {
        return sendEngineError(reply, err);
      }
    },
  );

  // -- POST /internal/sessions/:sid/move {from,to} ------------------------
  app.post<{ Params: { sid: string } }>(
    "/internal/sessions/:sid/move",
    async (req, reply) => {
      const userId = String(req.headers["x-ovid-user-id"]);
      const body = req.body as { from?: unknown; to?: unknown } | null | undefined;
      if (typeof body?.from !== "string" || typeof body?.to !== "string") {
        return fail(reply, 400, "bad_request", "body must be {from, to}");
      }
      try {
        return await moveWorkspacePath(opsDeps, {
          userId,
          sessionId: req.params.sid,
          from: body.from,
          to: body.to,
        });
      } catch (err) {
        return sendEngineError(reply, err);
      }
    },
  );

  // -- POST /internal/sessions/:sid/mkdir {path} --------------------------
  app.post<{ Params: { sid: string } }>(
    "/internal/sessions/:sid/mkdir",
    async (req, reply) => {
      const userId = String(req.headers["x-ovid-user-id"]);
      const body = req.body as { path?: unknown } | null | undefined;
      if (typeof body?.path !== "string" || body.path === "") {
        return fail(reply, 400, "bad_request", "body must be {path}");
      }
      try {
        return await makeWorkspaceDir(opsDeps, {
          userId,
          sessionId: req.params.sid,
          path: body.path,
        });
      } catch (err) {
        return sendEngineError(reply, err);
      }
    },
  );

  // -- GET /internal/sessions/:sid/file?path=... --------------------------
  app.get<{ Params: { sid: string }; Querystring: { path?: string } }>(
    "/internal/sessions/:sid/file",
    async (req, reply) => {
      const userId = String(req.headers["x-ovid-user-id"]);
      const rawPath = req.query.path;
      if (typeof rawPath !== "string" || rawPath === "") {
        return fail(reply, 400, "bad_request", "query parameter 'path' is required");
      }

      let rel: string;
      try {
        rel = assertSafeRelPath(rawPath);
      } catch (err) {
        return sendEngineError(reply, err);
      }

      const ref = { userId, sessionId: req.params.sid, path: rel };

      const redirect = async (
        sizeBytes: number,
        contentType: string,
        source: "warm" | "archive",
        bytes?: Buffer,
      ): Promise<unknown> => {
        // W1 follow-up (0022): registering this download as an artifact in a
        // project chat consumes a project file slot. Refuse BEFORE the object
        // is stored (registerArtifact calls storage.put) and before any row.
        // The repo repeats the check under the project-file lock.
        try {
          await assertSessionFileCapacity(deps.db, userId, req.params.sid, 1);
        } catch (err) {
          if (err instanceof ProjectFileLimitError) {
            return fail(reply, 409, err.code, err.message);
          }
          throw err;
        }
        const artifact = await registerArtifact(
          {
            db: deps.db,
            events: deps.events,
            storage: deps.storage,
            workspaceObjects: deps.workspaceObjects,
            eventMirror: deps.eventMirror,
            ...(deps.presignTtlSeconds !== undefined
              ? { presignTtlSeconds: deps.presignTtlSeconds }
              : {}),
            ...(deps.cdn !== undefined ? { cdn: deps.cdn } : {}),
          },
          source === "warm"
            ? {
                userId,
                sessionId: req.params.sid,
                name: rel,
                contentType,
                sourcePath: join(
                  await resolveWorkspaceDir(
                    deps.sandboxUid,
                    deps.workspacesRoot,
                    userId,
                    req.params.sid,
                  ),
                  rel,
                ),
              }
            : {
                userId,
                sessionId: req.params.sid,
                name: rel,
                contentType,
                content: bytes!,
              },
        );
        return {
          kind: "redirect" as const,
          path: rel,
          sizeBytes,
          contentType,
          downloadUrl: artifact.url,
          expiresAt: artifact.expiresAt,
        };
      };

      try {
        const result = await readWorkspaceFile(hydrateDeps, ref, {
          maxBytes: deps.inlineMaxBytes,
        });
        if (shouldPresign(result.contentType, result.sizeBytes, deps.inlineMaxBytes)) {
          // WARM streams from disk; COLD uses the already-buffered member.
          return await redirect(
            result.sizeBytes,
            result.contentType,
            result.source,
            result.bytes,
          );
        }
        return {
          kind: "content" as const,
          path: rel,
          sizeBytes: result.sizeBytes,
          sha256Hex: result.sha256Hex,
          contentType: result.contentType,
          contentBase64: result.bytes.toString("base64"),
          source: result.source,
        };
      } catch (err) {
        if (err instanceof FileTooLargeError) {
          const sizeBytes = err.sizeBytes;
          const contentType = contentTypeFor(rel);
          const warm = await isDirectory(
            await resolveWorkspaceDir(
              deps.sandboxUid,
              deps.workspacesRoot,
              userId,
              req.params.sid,
            ),
          );
          if (warm) {
            return await redirect(sizeBytes, contentType, "warm");
          }
          // Cold: extractFile buffers the member, so cap it before reading.
          if (sizeBytes > REDIRECT_MAX_BYTES) {
            return fail(
              reply,
              413,
              "file_too_large",
              `'${rel}' is ${sizeBytes} bytes (> ${REDIRECT_MAX_BYTES} max for a cold redirect)`,
            );
          }
          try {
            const full = await readWorkspaceFile(hydrateDeps, ref, {
              maxBytes: REDIRECT_MAX_BYTES,
            });
            return await redirect(full.sizeBytes, full.contentType, full.source, full.bytes);
          } catch (readErr) {
            return sendEngineError(reply, readErr);
          }
        }
        return sendEngineError(reply, err);
      }
    },
  );

  // -- PUT /internal/sessions/:sid/file?path=... --------------------------
  app.put<{ Params: { sid: string }; Querystring: { path?: string } }>(
    "/internal/sessions/:sid/file",
    async (req, reply) => {
      const userId = String(req.headers["x-ovid-user-id"]);
      const rawPath = req.query.path;
      if (typeof rawPath !== "string" || rawPath === "") {
        return fail(reply, 400, "bad_request", "query parameter 'path' is required");
      }

      const body = req.body as
        | { contentBase64?: unknown; ifMatchSha256?: unknown; ifNoneMatch?: unknown }
        | null
        | undefined;
      const content = decodeBase64(body?.contentBase64);
      if (content === null) {
        return fail(reply, 400, "bad_request", "contentBase64 must be valid base64");
      }
      const ifMatchSha256 = body?.ifMatchSha256;
      if (ifMatchSha256 !== undefined && (typeof ifMatchSha256 !== "string" || !/^[0-9a-f]{64}$/.test(ifMatchSha256))) {
        return fail(reply, 400, "bad_request", "ifMatchSha256 must be a lowercase sha256 hex digest");
      }
      const ifNoneMatch = body?.ifNoneMatch === true || body?.ifNoneMatch === "*";

      try {
        const out = await writeWorkspaceFile(
          hydrateDeps,
          { userId, sessionId: req.params.sid, path: rawPath },
          content,
          {
            ...(typeof ifMatchSha256 === "string" ? { ifMatchSha256 } : {}),
            ...(ifNoneMatch ? { ifNoneMatch: true } : {}),
          },
        );
        return {
          path: out.path,
          sizeBytes: out.sizeBytes,
          sha256: out.sha256Hex,
        };
      } catch (err) {
        return sendEngineError(reply, err);
      }
    },
  );

  // Malformed JSON / body-limit errors still use the one envelope.
  app.setErrorHandler((err, req, reply) => {
    const e = err as { statusCode?: number; message?: string };
    const status =
      typeof e.statusCode === "number" && e.statusCode >= 400 && e.statusCode < 500
        ? e.statusCode
        : 500;
    if (req.url.includes("/studio-git/")) {
      if (status === 413) {
        return fail(reply, 413, "bad_request", "Studio git request body is too large.");
      }
      if (status === 400) {
        return fail(reply, 400, "bad_request", "Invalid Studio git request.");
      }
      return fail(reply, 500, "internal", "Internal server error.");
    }
    const code =
      status === 400 ? "bad_request" : status === 413 ? "file_too_large" : "internal";
    return fail(reply, status, code, e.message ?? "Internal server error.");
  });

  return app;
}
