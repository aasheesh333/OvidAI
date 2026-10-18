import type { FastifyInstance } from "fastify";
import { eventMirror, sessions } from "@ovid/db";
import type { SessionEvent } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { isUuid, notFound, queryValue } from "./http.js";

// Durable session-event reads — mounted inside the authenticated /cloud/v1
// scope. This is the REST mirror of the WS replay path: the thin client's
// `_restMirrorReader` (lib/core/cloud/cloud_ws.dart) calls it when a live
// stream cannot be attached; the trajectory screen opens on the tail with an
// explicit `tail=1`.

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

/**
 * `tail` opt-in: `1` or `true` (the two spellings a browser/Flutter query
 * builder produces). Absent/anything else → false. This is the ONLY way to
 * ask for the newest page, because a bare no-cursor request means "from the
 * beginning" (see the route comment).
 */
function parseTail(raw: string | null): boolean {
  return raw === "1" || raw === "true";
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
    // A present-but-EMPTY `after=`/`before=` is likewise absent (queryValue
    // returns null for ""), so `?after=` degrades to "from the beginning".
    const after = parseSeqBound(queryValue(query.after));
    const before = parseSeqBound(queryValue(query.before));
    const tail = parseTail(queryValue(query.tail));

    // PRECEDENCE (four-way), and why:
    //
    //   1. valid `after`  → readSince(after)   — exclusive forward resume.
    //   2. valid `before` → readBefore(before) — exclusive backward page.
    //   3. `tail=1|true`  → readBefore(null)   — the newest page, ascending.
    //   4. otherwise      → readSince(null)    — FROM THE BEGINNING.
    //
    // Rule 4 is the client contract, not an arbitrary default:
    // `CloudMirrorReader` in lib/core/cloud/cloud_ws.dart is documented as
    // "events with seq strictly AFTER lastSeq (null ⇒ from the beginning)",
    // and `_restMirrorReader` sends `'after': lastSeq ?? ''`. On a first-ever
    // subscribe whose WS replay degraded, lastSeq is null → `?after=` → this
    // branch must replay the WHOLE mirror. Defaulting to the newest page here
    // would silently truncate a long transcript (the client folds the tail
    // with no error). Callers that want the tail ask for it explicitly with
    // `tail=1` (the trajectory screen's one-call open).
    //
    // `after` wins over `before` (and over `tail`): it is the live-mirror
    // resume cursor; a request mixing both is ambiguous, so the forward
    // direction — the one that makes progress on a live stream — is
    // deterministic. A malformed `after` is ignored, in which case a valid
    // `before` (or `tail`) still applies.
    let events: SessionEvent[];
    if (after !== null) {
      events = await eventMirror.readSince(deps.db, sessionId, after, limit);
    } else if (before !== null) {
      events = await eventMirror.readBefore(deps.db, sessionId, before, limit);
    } else if (tail) {
      events = await eventMirror.readBefore(deps.db, sessionId, null, limit);
    } else {
      events = await eventMirror.readSince(deps.db, sessionId, null, limit);
    }
    return { events } satisfies { events: SessionEvent[] };
  });
}
