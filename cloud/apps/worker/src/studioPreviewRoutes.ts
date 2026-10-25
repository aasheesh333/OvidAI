import type { FastifyInstance, FastifyReply } from "fastify";
import { z } from "zod";

import { createInternalServiceAuth } from "./internalServiceAuth.js";
import {
  StudioPreviewError,
  readStudioPreviewStatic,
  type StudioPreviewManager,
  type StudioPreviewRecord,
} from "./studioPreview.js";

const BODY_LIMIT = 16 * 1024;
const PATH = z.string().min(1).max(4096);
const createBody = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("static"),
    workspacePath: PATH,
  }).strict(),
  z.object({
    kind: z.literal("dev_server"),
    projectDir: PATH,
    script: z.enum(["dev", "start", "preview"]),
  }).strict(),
]);

export interface StudioPreviewRoutesDeps {
  internalToken: string;
  previews: StudioPreviewManager;
}

export interface StudioPreviewDto {
  id: string;
  kind: "static" | "dev_server";
  status: "starting" | "running" | "stopping" | "stopped" | "failed" | "expired";
  generation: number;
  expiresAt: string;
  lastAccessAt: string | null;
  logAvailable: boolean;
}

/** Internal management DTOs never disclose process or network addressing. */
export function toStudioPreviewDto(record: StudioPreviewRecord): StudioPreviewDto {
  return {
    id: record.id,
    kind: record.kind,
    status: record.status,
    generation: record.generation,
    expiresAt: record.expiresAt,
    lastAccessAt: record.lastAccessAt,
    logAvailable: record.kind === "dev_server" && record.logBytes !== null,
  };
}

function fail(reply: FastifyReply, status: number, code: string, message: string): FastifyReply {
  return reply.code(status).send({ error: { code, message } });
}

function notFound(reply: FastifyReply): FastifyReply {
  return fail(reply, 404, "not_found", "Preview not found.");
}

/** Translate the real DB capacity handoff without importing or exposing DB internals. */
export function adaptStudioPreviewRouteError(err: unknown): StudioPreviewError | null {
  if (err instanceof StudioPreviewError) return err;
  if (err !== null && typeof err === "object" && "name" in err && "code" in err) {
    const named = err as { name?: unknown; code?: unknown };
    if (named.name === "StudioPreviewCapacityError" &&
        (named.code === "per_user_capacity" || named.code === "global_capacity")) {
      return new StudioPreviewError(
        named.code,
        named.code === "per_user_capacity"
          ? "This account has reached its preview process limit."
          : "Preview capacity is full. Retry shortly.",
      );
    }
  }
  return null;
}

function sendError(reply: FastifyReply, err: unknown): FastifyReply {
  const adapted = adaptStudioPreviewRouteError(err);
  if (adapted === null) return fail(reply, 500, "internal", "Internal server error.");
  switch (adapted.code) {
    case "invalid_request":
    case "invalid_path":
    case "invalid_script":
    case "invalid_bind":
      return fail(reply, 400, "bad_request", adapted.message);
    case "per_user_capacity":
    case "global_capacity":
      return fail(reply, 429, adapted.code, adapted.message);
    case "not_found":
      return notFound(reply);
    case "no_repo":
      return fail(reply, 409, "no_repo", adapted.message);
    case "log_unavailable":
      return fail(reply, 404, "log_unavailable", adapted.message);
    case "not_running":
      return fail(reply, 409, adapted.code, adapted.message);
    case "preview_closed":
      return fail(reply, 503, adapted.code, adapted.message);
    case "cleanup_unproven":
      return fail(reply, 503, adapted.code, adapted.message);
    case "lifecycle_conflict":
      return fail(reply, 409, adapted.code, adapted.message);
    default:
      return fail(reply, 500, "internal", "Internal server error.");
  }
}

/** Register below the existing file service, or standalone behind this scoped gate. */
export function registerStudioPreviewRoutes(
  app: FastifyInstance,
  deps: StudioPreviewRoutesDeps,
): void {
  app.register(async (scoped) => {
    scoped.addHook("preHandler", createInternalServiceAuth(deps.internalToken));
    scoped.addHook("onSend", async (_req, reply) => {
      reply.header("cache-control", "private, no-store");
    });

    scoped.post<{ Params: { sid: string } }>(
      "/internal/sessions/:sid/previews",
      { bodyLimit: BODY_LIMIT },
      async (req, reply) => {
        const parsed = createBody.safeParse(req.body);
        if (!parsed.success) {
          return fail(reply, 400, "bad_request", "Invalid Studio preview definition.");
        }
        try {
          const record = await deps.previews.start({
            userId: String(req.headers["x-ovid-user-id"]),
            sessionId: req.params.sid,
            ...parsed.data,
          });
          return reply.code(201).send(toStudioPreviewDto(record));
        } catch (err) {
          return sendError(reply, err);
        }
      },
    );

    scoped.get<{ Params: { sid: string } }>(
      "/internal/sessions/:sid/previews",
      async (req, reply) => {
        try {
          const records = await deps.previews.get({
            userId: String(req.headers["x-ovid-user-id"]),
            sessionId: req.params.sid,
          });
          return { items: records.map(toStudioPreviewDto) };
        } catch (err) {
          return sendError(reply, err);
        }
      },
    );

    scoped.get<{ Params: { sid: string; pid: string } }>(
      "/internal/sessions/:sid/previews/:pid",
      async (req, reply) => {
        try {
          const record = await deps.previews.get({
            userId: String(req.headers["x-ovid-user-id"]),
            sessionId: req.params.sid,
            id: req.params.pid,
          });
          if (record === null) return notFound(reply);
          return toStudioPreviewDto(record);
        } catch (err) {
          return sendError(reply, err);
        }
      },
    );

    scoped.post<{ Params: { sid: string; pid: string } }>(
      "/internal/sessions/:sid/previews/:pid/stop",
      { bodyLimit: 1 },
      async (req, reply) => {
        try {
          const owner = {
            userId: String(req.headers["x-ovid-user-id"]),
            sessionId: req.params.sid,
            id: req.params.pid,
          };
          if (await deps.previews.get(owner) === null) return notFound(reply);
          const record = await deps.previews.stop(owner);
          if (record === null) return notFound(reply);
          return toStudioPreviewDto(record);
        } catch (err) {
          return sendError(reply, err);
        }
      },
    );

    scoped.get<{ Params: { sid: string; pid: string } }>(
      "/internal/sessions/:sid/previews/:pid/logs",
      async (req, reply) => {
        try {
          const logs = await deps.previews.logs({
            userId: String(req.headers["x-ovid-user-id"]),
            sessionId: req.params.sid,
            id: req.params.pid,
          });
          if (logs === null) return notFound(reply);
          return logs;
        } catch (err) {
          if (err instanceof StudioPreviewError && err.code === "log_unavailable") {
            return notFound(reply);
          }
          return sendError(reply, err);
        }
      },
    );

    const staticBytes = async (req: {
      params: { sid: string; pid: string; "*"?: string };
      headers: Record<string, unknown>;
    }, reply: FastifyReply): Promise<FastifyReply | unknown> => {
      try {
        const record = await deps.previews.get({
          userId: String(req.headers["x-ovid-user-id"]),
          sessionId: req.params.sid,
          id: req.params.pid,
        });
        if (record === null || record.kind !== "static") return notFound(reply);
        const accessed = await deps.previews.touch({
          userId: String(req.headers["x-ovid-user-id"]),
          sessionId: req.params.sid,
          id: req.params.pid,
          generation: record.generation,
          kind: record.kind,
        });
        if (accessed === null) return notFound(reply);
        const file = await readStudioPreviewStatic(accessed, req.params["*"] ?? "");
        return reply
          .header("content-type", file.contentType)
          .header("content-length", String(file.sizeBytes))
          .header("x-content-type-options", "nosniff")
          .send(file.bytes);
      } catch (err) {
        if (err instanceof StudioPreviewError &&
            (err.code === "log_unavailable" || err.code === "not_running")) {
          return notFound(reply);
        }
        return sendError(reply, err);
      }
    };

    scoped.get<{ Params: { sid: string; pid: string } }>(
      "/internal/sessions/:sid/previews/:pid/static",
      staticBytes,
    );
    scoped.get<{ Params: { sid: string; pid: string; "*": string } }>(
      "/internal/sessions/:sid/previews/:pid/static/*",
      staticBytes,
    );
  });
}
