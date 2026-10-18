import type { FastifyInstance } from "fastify";
import { eventMirror, sessions } from "@ovid/db";
import type { SessionEvent } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { isUuid, notFound, queryValue } from "./http.js";

// Durable session-event reads — mounted inside the authenticated /cloud/v1
// scope. This is the REST mirror of the WS replay path: the thin client's
// `_restMirrorReader` (lib/core/cloud/cloud_ws.dart) calls it when a live
// stream cannot be attached, and the trajectory screen opens on the tail.

export const DEFAULT_EVENT_LIMIT = 200;
export const MAX_EVENT_LIMIT = 1000;

/**
 * Event-limit parsing, CLAMPED (never a 400) — same rule as
 * parsePageLimit, with the event route's own 200/1000 bounds:
 * missing/empty/non-numeric/NaN/<1 → default 200; >1000 → 1000; fractional
 * → floor. Accepts the string[] form repeated query params produce by using
 * the first value.
 */
export function parseEventLimit(raw: string | string[] | undefined): number {
  const text = Array.isArray(raw) ? raw[0] : raw;
  if (text === undefined || text.trim() === "") return DEFAULT_EVENT_LIMIT;
  const n = Number(text);
  if (!Number.isFinite(n) || n < 1) return DEFAULT_EVENT_LIMIT;
  if (n > MAX_EVENT_LIMIT) return MAX_EVENT_LIMIT;
  return Math.max(1, Math.floor(n));
}

/**
 * Redis-stream-id shape: `<ms>` or `<ms>-<sub>`, both non-negative integers.
 * Anything else is MALFORMED and ignored by the route (lenient degradation,
 * never a 400) — a garbage bound must not reach split_part/bigint casts.
 */
const EVENT_SEQ_RE = /^\d+(?:-\d+)?$/;

function parseSeqBound(raw: string | null): string | null {
  return raw !== null && EVENT_SEQ_RE.test(raw) ? raw : null;
}

export function registerEventRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.get("/sessions/:id/events", async (request, reply) => {
    const { id: sessionId } = request.params as { id: string };

    // Ownership FIRST, exactly like messages.ts: a malformed :id folds into
    // the same 404 envelope as an unknown/wrong-owner id (no existence
    // leaks, and client garbage never reaches the db).
    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, request.principal.uid);
    if (session === null) return notFound(reply);

    const query = request.query as Record<string, string | string[] | undefined>;
    const limit = parseEventLimit(query.limit);

    // Malformed cursors are IGNORED (the messages `before` rule): paging
    // params clamp-or-ignore, and a garbage value must never produce a 400.
    const after = parseSeqBound(queryValue(query.after));
    const before = parseSeqBound(queryValue(query.before));

    // DOCUMENTED CHOICE: when both are present, `after` wins and `before` is
    // ignored. `after` is the live-mirror resume cursor (the client's
    // `_restMirrorReader` only ever sends it); a caller mixing both is
    // ambiguous, so the forward direction — the one that makes progress on a
    // live stream — is deterministic. A malformed `after` is ignored, in
    // which case a valid `before` still applies.
    let events: SessionEvent[];
    if (after !== null) {
      events = await eventMirror.readSince(deps.db, sessionId, after, limit);
    } else {
      // No usable forward cursor: `before` pages backwards; absent (or
      // malformed) means the NEWEST page, ascending — the trajectory screen's
      // one-call tail open.
      events = await eventMirror.readBefore(deps.db, sessionId, before, limit);
    }
    return { events } satisfies { events: SessionEvent[] };
  });
}
