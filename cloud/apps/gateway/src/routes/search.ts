import type { FastifyInstance } from "fastify";
import { MESSAGES_SEARCH_MAX_OFFSET, searchMessages } from "@ovid/db";
import type { GatewayDeps } from "../app.js";
import { isUuid, parsePageLimit, queryValue, sendError } from "./http.js";

/**
 * Global message search — the route over the FTS index that already exists.
 *
 * `@ovid/db`'s `searchMessages` is the whole search: tsvector match
 * (`plainto` for bare terms, `websearch` for a quoted phrase), cover-density
 * ranking, `ts_headline` snippets, the query/limit/offset clamps, and — the
 * part this route must never re-implement — the `sessions.user_id` join that
 * makes a cross-account query return zero rows instead of another person's
 * messages.
 *
 * What this route adds, and only this:
 *
 *   - the scope is `request.principal.uid`. There is deliberately no `userId`
 *     query parameter: a search that took its owner from the wire would be a
 *     transcript leak with extra steps.
 *   - pagination is offset-based (what the repo returns) and clamped, never a
 *     400 for a big number. A caller paging past the end gets an empty page.
 *   - `sessionId` narrows a global search to one chat. A session the caller
 *     does not own is not a 404 here: the ownership join already answers with
 *     zero rows, which leaks neither existence nor content.
 *
 * A blank `q` answers an empty page rather than an error — the repo treats
 * "nothing to match" as "no results", and the client's search box is allowed
 * to be empty while the person is still typing.
 */

/** Offset clamp, mirroring the repo's `MESSAGES_SEARCH_MAX_OFFSET`. */
function parseOffset(raw: string | string[] | undefined): number {
  const text = Array.isArray(raw) ? raw[0] : raw;
  if (text === undefined || text.trim() === "") return 0;
  const n = Number(text);
  if (!Number.isFinite(n) || n < 1) return 0;
  return Math.min(Math.floor(n), MESSAGES_SEARCH_MAX_OFFSET);
}

export function registerSearchRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.get("/search/messages", async (request, reply) => {
    const query = request.query as Record<string, string | string[] | undefined>;

    const limit = parsePageLimit(query.limit);
    const offset = parseOffset(query.offset);

    const rawSessionId = queryValue(query.sessionId);
    let sessionId: string | undefined;
    if (rawSessionId !== null) {
      // Shape guard before the uuid column binding: a malformed id would raise
      // 22P02 and surface as a 500. Any canonical UUID is safe to bind.
      if (!isUuid(rawSessionId)) {
        return sendError(reply, 400, "bad_request", "sessionId must be a UUID.");
      }
      sessionId = rawSessionId;
    }

    // Missing and whitespace-only queries are the same "no term yet" state.
    const q = queryValue(query.q)?.trim() ?? "";
    const page =
      q === ""
        ? { rows: [], total: 0 }
        : await searchMessages(deps.db, request.principal.uid, q, {
            limit,
            offset,
            sessionId,
          });

    return reply.header("cache-control", "private, no-store").send({
      items: page.rows.map((row) => ({
        messageId: row.messageId,
        sessionId: row.sessionId,
        role: row.role,
        rank: row.rank,
        snippet: row.snippet,
      })),
      total: page.total,
      limit,
      offset,
    });
  });
}
