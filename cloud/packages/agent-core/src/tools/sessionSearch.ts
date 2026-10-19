// session_search tool (P3 Task 13) — the cloud port of Dart's SessionSearch +
// _handleSessionSearch (agent_service.dart): Postgres FTS over messages via
// @ovid/db's searchMessages (tsvector column, ts_rank_cd ordering, ts_headline
// snippets, ownership enforced by the sessions join — cross-user reads are
// zero rows, never an error).
//
// Dart parity kept: the literal-phrase switch (quoted phrases match the
// literal phrase), the maxLimit-100 / maxQueryLength-4096 clamps and their
// exact error copies. Cloud deltas: paging rides the repo's offset (the
// SQLite snapshot "generation" fence has no equivalent — the index is the
// table itself), and results render as `sessionId messageId: snippet` lines.

import { searchMessages, type Db } from "@ovid/db";

import type { Tool, ToolContext, ToolResult } from "../types.js";

/** Dart SessionSearch.maxQueryLength parity (UTF-16 code units; 4096). */
export const SESSION_SEARCH_MAX_QUERY_UTF16 = 4096;
/** Dart SessionSearch.maxLimit parity (100). */
export const SESSION_SEARCH_MAX_LIMIT = 100;

const DEFAULT_LIMIT = 20; // Dart default

/** Runs a tool body; user-level failures become isError results, never throws. */
async function run(body: () => Promise<ToolResult>): Promise<ToolResult> {
  try {
    return await body();
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return { content: `Error: ${msg}`, isError: true };
  }
}

/**
 * Wave 1a (owner rule R1 — session isolation): `crossSession` is the user's
 * "Share session memory" preference. false (the DEFAULT, fail-closed) confines
 * every search to the CALLING session: a `sessionId` naming another session is
 * refused and any foreign row is dropped. true restores the cross-session
 * search over every session the user owns.
 */
export function createSessionSearchTool(deps: { db: Db; crossSession?: boolean }): Tool {
  const { db } = deps;
  const crossSession = deps.crossSession === true;
  return {
    spec: {
      name: "session_search",
      description: crossSession
        ? "Search your past session transcripts with full-text ranking and " +
          "highlighted snippets. Quoted phrases match the literal phrase; " +
          "bare terms are ANDed. Optionally scope to one session id."
        : "Search THIS session's transcript with full-text ranking and " +
          "highlighted snippets. Quoted phrases match the literal phrase; " +
          "bare terms are ANDed. Other sessions are private unless the user " +
          "@-tags them or turns on Share session memory.",
      parameters: {
        type: "object",
        properties: {
          query: { type: "string", description: "Search text; quoted phrases match literally." },
          sessionId: { type: "string", description: "Restrict the search to this session." },
          limit: { type: "integer", description: `Max results (default ${DEFAULT_LIMIT}, max ${SESSION_SEARCH_MAX_LIMIT}).` },
        },
        required: ["query"],
      },
    },
    timeoutMs: 30_000,
    async execute(args: Record<string, unknown>, ctx: ToolContext) {
      return run(async () => {
        // Input clamps — Dart _handleSessionSearch copies (the repo re-clamps
        // defensively; these give the model the exact error text).
        const rawQuery = args.query;
        if (
          typeof rawQuery !== "string" ||
          rawQuery.length > SESSION_SEARCH_MAX_QUERY_UTF16
        ) {
          return {
            content:
              `Error: query must be text of at most ${SESSION_SEARCH_MAX_QUERY_UTF16} characters.`,
            isError: true,
          };
        }
        const query = rawQuery.trim();
        if (query === "") return { content: "query is required", isError: true };

        const rawLimit = args.limit;
        if (rawLimit !== undefined) {
          if (typeof rawLimit !== "number" || !Number.isInteger(rawLimit) || rawLimit < 0 || rawLimit > SESSION_SEARCH_MAX_LIMIT) {
            return { content: `Error: limit must be 0–${SESSION_SEARCH_MAX_LIMIT}.`, isError: true };
          }
        }
        const rawSessionId = args.sessionId;
        if (rawSessionId !== undefined && typeof rawSessionId !== "string") {
          return { content: "Error: sessionId must be a string.", isError: true };
        }

        if (
          !crossSession &&
          typeof rawSessionId === "string" &&
          rawSessionId !== "" &&
          rawSessionId !== ctx.sessionId
        ) {
          return {
            content:
              "Error: other sessions are private. Searching them needs the user to " +
              "@-tag the session or turn on Share session memory in Settings.",
            isError: true,
          };
        }
        const scope = crossSession
          ? typeof rawSessionId === "string"
            ? rawSessionId
            : undefined
          : ctx.sessionId;

        const res = await searchMessages(db, ctx.userId, query, {
          limit: typeof rawLimit === "number" ? rawLimit : undefined,
          offset: undefined,
          sessionId: scope,
        });
        const rows = crossSession
          ? res.rows
          : res.rows.filter((r) => r.sessionId === ctx.sessionId);
        if (rows.length === 0) return { content: "No matches." };
        const lines = rows.map((r) => `${r.sessionId} ${r.messageId}: ${r.snippet}`);
        return { content: lines.join("\n") };
      });
    },
  };
}
