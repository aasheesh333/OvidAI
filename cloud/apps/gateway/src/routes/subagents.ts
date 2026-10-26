import type { FastifyInstance } from "fastify";
import {
  readSubagentRosterSession,
  sessions,
  SubagentRosterCursorError,
  SubagentRosterTooLargeError,
} from "@ovid/db";
import type { GatewayDeps } from "../app.js";
import { badRequest, isUuid, notFound, queryValue } from "./http.js";

const DEFAULT_SUBAGENT_LIMIT = 50;
const MAX_SUBAGENT_LIMIT = 200;

/** Wire-compatible limit parser: default 50, clamp to 200, floor fractions. */
export function parseSubagentLimit(raw: string | string[] | undefined): number {
  const text = Array.isArray(raw) ? raw[0] : raw;
  if (text === undefined || text.trim() === "") return DEFAULT_SUBAGENT_LIMIT;
  const value = Number(text);
  if (!Number.isFinite(value) || value < 1) return DEFAULT_SUBAGENT_LIMIT;
  return Math.min(MAX_SUBAGENT_LIMIT, Math.max(1, Math.floor(value)));
}

/** GET /sessions/:id/subagents — read-only client-compatible worker projection. */
export function registerSubagentRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.get("/sessions/:id/subagents", async (request, reply) => {
    const { id: sessionId } = request.params as { id: string };

    // Ownership precedes cursor parsing and every roster read. Malformed,
    // unknown, foreign and soft-deleted sessions all share the same 404.
    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, request.principal.uid);
    if (session === null) return notFound(reply);

    const query = request.query as Record<string, string | string[] | undefined>;
    const after = queryValue(query.after);
    const limit = parseSubagentLimit(query.limit);
    try {
      const page = await readSubagentRosterSession(deps.db, { sessionId, limit, after });
      return reply.header("cache-control", "private, no-store").send(page);
    } catch (error) {
      if (error instanceof SubagentRosterCursorError) {
        return badRequest(reply, "after is not a valid worker cursor.");
      }
      if (error instanceof SubagentRosterTooLargeError) {
        return reply.code(503).send({
          error: {
            code: "temporarily_unavailable",
            message: "The subagent roster is too large to read safely. Try again after older work settles.",
          },
        });
      }
      throw error;
    }
  });
}
