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
import type { Db } from "@ovid/db";
import type { EventLog } from "@ovid/events";
import {
  FileNotInArchiveError,
  FileTooLargeError,
  KeyLayoutError,
  NotFoundError,
  StorageError,
  WorkspaceStateError,
  assertSafeRelPath,
  contentTypeFor,
  liveTree,
  readWorkspaceFile,
  registerArtifact,
  shouldPresign,
  workspaceDir,
  writeWorkspaceFile,
  type ActivityTracker,
  type ArtifactWorkspaceObjectsRepo,
  type HydrateEventMirror,
  type HydrateFileManifestsRepo,
  type StorageAdapter,
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
  activity: ActivityTracker;
  internalToken: string;
  inlineMaxBytes: number;
  port: number;
  /** Default "0.0.0.0" (container-internal; never a host port). */
  host?: string;
  /** T9-review I2: the real @ovid/db repos the hydration/artifacts engines need. */
  fileManifests: HydrateFileManifestsRepo;
  eventMirror: HydrateEventMirror;
  workspaceObjects: ArtifactWorkspaceObjectsRepo;
  /** Default DEFAULT_PRESIGN_TTL_SECONDS (3600) inside registerArtifact. */
  presignTtlSeconds?: number;
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
    activity: deps.activity,
    fileManifests: deps.fileManifests,
    eventMirror: deps.eventMirror,
  };

  // -- internal-token gate (every route) ----------------------------------
  app.addHook("preHandler", async (req, reply) => {
    const token = req.headers["x-ovid-internal-token"];
    if (typeof token !== "string" || token !== deps.internalToken) {
      return fail(reply, 401, "unauthenticated", "Missing or invalid internal token.");
    }
    const userId = req.headers["x-ovid-user-id"];
    if (typeof userId !== "string" || userId.trim() === "") {
      return fail(reply, 401, "unauthenticated", "Missing x-ovid-user-id.");
    }
  });

  // -- GET /internal/sessions/:sid/tree -----------------------------------
  app.get<{ Params: { sid: string } }>(
    "/internal/sessions/:sid/tree",
    async (req, reply) => {
      const userId = String(req.headers["x-ovid-user-id"]);
      try {
        const dir = workspaceDir(deps.workspacesRoot, userId, req.params.sid);
        if (!(await isDirectory(dir))) {
          return fail(reply, 404, "not_found", `workspace ${req.params.sid} is not warm`);
        }
        return { tree: await liveTree(dir) };
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
          },
          source === "warm"
            ? {
                userId,
                sessionId: req.params.sid,
                name: rel,
                contentType,
                sourcePath: join(
                  workspaceDir(deps.workspacesRoot, userId, req.params.sid),
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
            workspaceDir(deps.workspacesRoot, userId, req.params.sid),
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

      const body = req.body as { contentBase64?: unknown } | null | undefined;
      const content = decodeBase64(body?.contentBase64);
      if (content === null) {
        return fail(reply, 400, "bad_request", "contentBase64 must be valid base64");
      }

      try {
        const out = await writeWorkspaceFile(
          hydrateDeps,
          { userId, sessionId: req.params.sid, path: rawPath },
          content,
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
  app.setErrorHandler((err, _req, reply) => {
    const e = err as { statusCode?: number; message?: string };
    const status =
      typeof e.statusCode === "number" && e.statusCode >= 400 && e.statusCode < 500
        ? e.statusCode
        : 500;
    const code =
      status === 400 ? "bad_request" : status === 413 ? "file_too_large" : "internal";
    return fail(reply, status, code, e.message ?? "Internal server error.");
  });

  return app;
}
