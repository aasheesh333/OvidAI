import type { FastifyInstance } from "fastify";
import { imageUsage, runUsage, type RunCursor, type UsageTotals } from "@ovid/db";
import type { GatewayDeps } from "../app.js";
import { badRequest, queryValue } from "./http.js";

/**
 * Wave 3: GET /cloud/v1/usage/history — the owner's "very detailed usage"
 * view over the run_usage token ledger (one row per model call, recorded by
 * the worker). Only the caller's own rows are ever read.
 *
 * Query:
 *   days              1..90, default 30 (clamped, never a 400)
 *   utcOffsetMinutes  integer -840..840, default 0 (400 when invalid) —
 *                     the client's UTC offset; day buckets and the window
 *                     start follow the client's calendar
 *   limit             runs page size, default 50, max 200 (clamped)
 *   before            opaque runs cursor from a previous `nextBefore` (400
 *                     when malformed)
 *
 * The window is [since, until): `since` = local midnight (days-1) days
 * before local today, `until` = now. Responses are camelCase like the rest
 * of the gateway API.
 */

const DEFAULT_DAYS = 30;
const MAX_DAYS = 90;
const MAX_OFFSET = 840;
const DAY_MS = 86_400_000;

function parseDays(raw: string | null): number {
  if (raw === null) return DEFAULT_DAYS;
  const n = Number(raw);
  if (!Number.isFinite(n)) return DEFAULT_DAYS;
  return Math.max(1, Math.min(MAX_DAYS, Math.floor(n)));
}

function parseOffset(raw: string | null): number | null {
  if (raw === null) return 0;
  if (!/^-?\d+$/.test(raw.trim())) return null;
  const n = Number(raw);
  return Number.isInteger(n) && n >= -MAX_OFFSET && n <= MAX_OFFSET ? n : null;
}

function parseLimit(raw: string | null): number | undefined {
  if (raw === null) return undefined;
  const n = Number(raw);
  return Number.isFinite(n) ? n : undefined;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function encodeRunCursor(c: RunCursor): string {
  return Buffer.from(`${c.createdAt.toISOString()}|${c.runId}`, "utf8").toString("base64url");
}

export function decodeRunCursor(raw: string): RunCursor | null {
  let text: string;
  try {
    text = Buffer.from(raw, "base64url").toString("utf8");
  } catch {
    return null;
  }
  const bar = text.indexOf("|");
  if (bar <= 0) return null;
  const at = new Date(text.slice(0, bar));
  const runId = text.slice(bar + 1);
  if (Number.isNaN(at.getTime()) || !UUID_RE.test(runId)) return null;
  return { createdAt: at, runId };
}

function zero(): UsageTotals {
  return {
    runs: 0,
    modelCalls: 0,
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
    costUsd: null,
  };
}

function iso(d: Date | null): string | null {
  return d === null ? null : d.toISOString();
}

export function registerUsageHistoryRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.get("/usage/history", async (request, reply) => {
    const q = (request.query ?? {}) as Record<string, string | string[] | undefined>;
    const days = parseDays(queryValue(q.days));
    const offset = parseOffset(queryValue(q.utcOffsetMinutes));
    if (offset === null) {
      return badRequest(reply, `utcOffsetMinutes must be an integer in [-${MAX_OFFSET}, ${MAX_OFFSET}].`);
    }
    const limit = parseLimit(queryValue(q.limit));
    const beforeRaw = queryValue(q.before);
    const before = beforeRaw === null ? null : decodeRunCursor(beforeRaw);
    if (beforeRaw !== null && before === null) {
      return badRequest(reply, "before is not a valid cursor.");
    }

    const userId = request.principal.uid;
    const until = deps.clock?.() ?? new Date();
    const offsetMs = offset * 60_000;
    // Local midnight of local "today", as a UTC-epoch instant in local terms.
    const localToday = Math.floor((until.getTime() + offsetMs) / DAY_MS) * DAY_MS;
    const since = new Date(localToday - (days - 1) * DAY_MS - offsetMs);
    const window = { userId, since, until };

    const [totals, byDay, models, sessions, page, images] = await Promise.all([
      runUsage.totals(deps.db, window),
      runUsage.byDay(deps.db, { ...window, utcOffsetMinutes: offset }),
      runUsage.byModel(deps.db, window),
      runUsage.bySession(deps.db, { ...window, limit: 50 }),
      runUsage.recentRuns(deps.db, { ...window, limit, before }),
      imageUsage.totals(deps.db, window),
    ]);

    const dayMap = new Map(byDay.map((d) => [d.date, d]));
    const dayList = [];
    for (let i = 0; i < days; i++) {
      const date = new Date(localToday - i * DAY_MS).toISOString().slice(0, 10);
      const found = dayMap.get(date);
      dayList.push({ date, ...(found === undefined ? zero() : stripDate(found)) });
    }

    reply.header("Cache-Control", "no-store");
    return {
      since: since.toISOString(),
      until: until.toISOString(),
      utcOffsetMinutes: offset,
      totals,
      images,
      days: dayList,
      models,
      sessions: sessions.map((s) => ({ ...s, lastAt: s.lastAt.toISOString() })),
      runs: page.rows.map((r) => ({
        runId: r.runId,
        sessionId: r.sessionId,
        sessionTitle: r.sessionTitle,
        status: r.status,
        startedAt: iso(r.startedAt),
        finishedAt: iso(r.finishedAt),
        models: r.models,
        requestedModels: r.requestedModels,
        providerModels: r.providerModels,
        costUsd: r.costUsd,
        modelCalls: r.modelCalls,
        inputTokens: r.inputTokens,
        outputTokens: r.outputTokens,
        cacheReadTokens: r.cacheReadTokens,
        cacheWriteTokens: r.cacheWriteTokens,
      })),
      nextBefore: page.next === null ? null : encodeRunCursor(page.next),
    };
  });
}

function stripDate(d: UsageTotals & { date: string }): UsageTotals {
  return {
    runs: d.runs,
    modelCalls: d.modelCalls,
    inputTokens: d.inputTokens,
    outputTokens: d.outputTokens,
    cacheReadTokens: d.cacheReadTokens,
    cacheWriteTokens: d.cacheWriteTokens,
    costUsd: d.costUsd,
  };
}
