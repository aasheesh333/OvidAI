import type { Db } from "./client.js";
import { newId } from "./repos.js";
import { runUsage as runUsageTable, type RunUsageRow } from "./schema.js";

/**
 * Wave 3: the per-model-call token ledger (`run_usage`) and the aggregates
 * behind GET /cloud/v1/usage/history.
 *
 * Every aggregate is scoped to ONE user and a half-open window
 * [since, until). `runs` counts DISTINCT run ids; `modelCalls` counts rows
 * (one per LiteLLM call). Sorting "by tokens" means input + output tokens
 * (cache counts are reported separately and never double-counted).
 */

export interface RunUsageInput {
  userId: string;
  sessionId: string;
  runId: string;
  /** The model id requested from LiteLLM. */
  model: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens?: number;
  cacheWriteTokens?: number;
  /** Tests/backfill only; omitted → now(). */
  createdAt?: Date;
}

export interface UsageWindow {
  userId: string;
  since: Date;
  until: Date;
}

export interface TokenSums {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
}

export interface UsageTotals extends TokenSums {
  runs: number;
  modelCalls: number;
}

export interface UsageDay extends UsageTotals {
  /** YYYY-MM-DD in the caller's UTC offset. */
  date: string;
}

export interface UsageModel extends UsageTotals {
  model: string;
}

export interface UsageSession {
  sessionId: string;
  /** null when the session was deleted (still counted) or never titled. */
  title: string | null;
  runs: number;
  modelCalls: number;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  lastAt: Date;
}

export interface UsageRun extends TokenSums {
  runId: string;
  sessionId: string;
  sessionTitle: string | null;
  /** null when the runs row is gone. */
  status: string | null;
  startedAt: Date | null;
  finishedAt: Date | null;
  /** Keyset position: the run's created_at (first usage row when the run row is gone). */
  runCreatedAt: Date;
  /** Distinct requested model ids, sorted. */
  models: string[];
  modelCalls: number;
}

export interface RunCursor {
  createdAt: Date;
  runId: string;
}

export const RUN_USAGE_MAX_OFFSET_MINUTES = 840;
const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 200;

/** Non-negative safe integer (usage from providers can be absent or odd). */
function count(v: number | undefined): number {
  if (typeof v !== "number" || !Number.isFinite(v) || v <= 0) return 0;
  return Math.min(Math.trunc(v), 2_147_483_647);
}

function num(v: unknown): number {
  if (v === null || v === undefined) return 0;
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

function date(v: unknown): Date | null {
  if (v === null || v === undefined) return null;
  return v instanceof Date ? v : new Date(String(v));
}

function validateOffset(minutes: number): number {
  if (
    !Number.isInteger(minutes) ||
    minutes < -RUN_USAGE_MAX_OFFSET_MINUTES ||
    minutes > RUN_USAGE_MAX_OFFSET_MINUTES
  ) {
    throw new RangeError(
      `utcOffsetMinutes must be an integer in [-${RUN_USAGE_MAX_OFFSET_MINUTES}, ${RUN_USAGE_MAX_OFFSET_MINUTES}]`,
    );
  }
  return minutes;
}

type Row = Record<string, unknown>;

function sums(r: Row): TokenSums {
  return {
    inputTokens: num(r.input_tokens),
    outputTokens: num(r.output_tokens),
    cacheReadTokens: num(r.cache_read_tokens),
    cacheWriteTokens: num(r.cache_write_tokens),
  };
}

function totalsOf(r: Row): UsageTotals {
  return { runs: num(r.runs), modelCalls: num(r.model_calls), ...sums(r) };
}

function clampLimit(limit: number | undefined, dflt = DEFAULT_LIMIT, max = MAX_LIMIT): number {
  if (limit === undefined || !Number.isFinite(limit)) return dflt;
  return Math.max(1, Math.min(max, Math.trunc(limit)));
}

export const runUsage = {
  clampLimit: (limit: number | undefined) => clampLimit(limit),

  /** One row per model call. Counts are clamped to non-negative integers. */
  async record(db: Db, row: RunUsageInput): Promise<RunUsageRow> {
    const [inserted] = await db
      .insert(runUsageTable)
      .values({
        id: newId(),
        userId: row.userId,
        sessionId: row.sessionId,
        runId: row.runId,
        model: row.model,
        inputTokens: count(row.inputTokens),
        outputTokens: count(row.outputTokens),
        cacheReadTokens: count(row.cacheReadTokens),
        cacheWriteTokens: count(row.cacheWriteTokens),
        ...(row.createdAt !== undefined ? { createdAt: row.createdAt } : {}),
      })
      .returning();
    return inserted!;
  },

  async totals(db: Db, w: UsageWindow): Promise<UsageTotals> {
    const rows = (await db.$client`
      SELECT count(DISTINCT run_id) AS runs,
             count(*) AS model_calls,
             coalesce(sum(input_tokens), 0) AS input_tokens,
             coalesce(sum(output_tokens), 0) AS output_tokens,
             coalesce(sum(cache_read_tokens), 0) AS cache_read_tokens,
             coalesce(sum(cache_write_tokens), 0) AS cache_write_tokens
        FROM run_usage
       WHERE user_id = ${w.userId}
         AND created_at >= ${w.since.toISOString()}::timestamptz AND created_at < ${w.until.toISOString()}::timestamptz
    `) as Row[];
    return totalsOf(rows[0] ?? {});
  },

  /** Days that HAVE usage, newest first, bucketed at the caller's UTC offset. */
  async byDay(db: Db, w: UsageWindow & { utcOffsetMinutes: number }): Promise<UsageDay[]> {
    const offset = validateOffset(w.utcOffsetMinutes);
    const rows = (await db.$client`
      SELECT to_char((created_at AT TIME ZONE 'UTC') + make_interval(mins => ${offset}::int), 'YYYY-MM-DD') AS day,
             count(DISTINCT run_id) AS runs,
             count(*) AS model_calls,
             sum(input_tokens) AS input_tokens,
             sum(output_tokens) AS output_tokens,
             sum(cache_read_tokens) AS cache_read_tokens,
             sum(cache_write_tokens) AS cache_write_tokens
        FROM run_usage
       WHERE user_id = ${w.userId}
         AND created_at >= ${w.since.toISOString()}::timestamptz AND created_at < ${w.until.toISOString()}::timestamptz
       GROUP BY day
       ORDER BY day DESC
    `) as Row[];
    return rows.map((r) => ({ date: String(r.day), ...totalsOf(r) }));
  },

  /** Per requested model, by input+output tokens desc (then name). */
  async byModel(db: Db, w: UsageWindow): Promise<UsageModel[]> {
    const rows = (await db.$client`
      SELECT model,
             count(DISTINCT run_id) AS runs,
             count(*) AS model_calls,
             sum(input_tokens) AS input_tokens,
             sum(output_tokens) AS output_tokens,
             sum(cache_read_tokens) AS cache_read_tokens,
             sum(cache_write_tokens) AS cache_write_tokens
        FROM run_usage
       WHERE user_id = ${w.userId}
         AND created_at >= ${w.since.toISOString()}::timestamptz AND created_at < ${w.until.toISOString()}::timestamptz
       GROUP BY model
       ORDER BY sum(input_tokens) + sum(output_tokens) DESC, model ASC
    `) as Row[];
    return rows.map((r) => ({ model: String(r.model), ...totalsOf(r) }));
  },

  /**
   * Top sessions by input+output tokens. Titles come from `sessions`, but a
   * soft-deleted session's title is never returned (its usage still counts).
   */
  async bySession(db: Db, w: UsageWindow & { limit?: number }): Promise<UsageSession[]> {
    const limit = clampLimit(w.limit, 50, MAX_LIMIT);
    const rows = (await db.$client`
      SELECT u.session_id,
             CASE WHEN s.deleted_at IS NULL THEN s.title ELSE NULL END AS title,
             count(DISTINCT u.run_id) AS runs,
             count(*) AS model_calls,
             sum(u.input_tokens) AS input_tokens,
             sum(u.output_tokens) AS output_tokens,
             sum(u.cache_read_tokens) AS cache_read_tokens,
             sum(u.cache_write_tokens) AS cache_write_tokens,
             max(u.created_at) AS last_at
        FROM run_usage u
        LEFT JOIN sessions s ON s.id = u.session_id AND s.user_id = u.user_id
       WHERE u.user_id = ${w.userId}
         AND u.created_at >= ${w.since.toISOString()}::timestamptz AND u.created_at < ${w.until.toISOString()}::timestamptz
       GROUP BY u.session_id, s.title, s.deleted_at
       ORDER BY sum(u.input_tokens) + sum(u.output_tokens) DESC, max(u.created_at) DESC
       LIMIT ${limit}
    `) as Row[];
    return rows.map((r) => ({
      sessionId: String(r.session_id),
      title: r.title === null || r.title === undefined ? null : String(r.title),
      runs: num(r.runs),
      modelCalls: num(r.model_calls),
      ...sums(r),
      lastAt: date(r.last_at)!,
    }));
  },

  /**
   * Runs with usage in the window, newest first by (run created_at, run id).
   * `before` is the exclusive keyset cursor; `next` is set when more remain.
   */
  async recentRuns(
    db: Db,
    w: UsageWindow & { limit?: number; before?: RunCursor | null },
  ): Promise<{ rows: UsageRun[]; next: RunCursor | null }> {
    const limit = clampLimit(w.limit);
    const before = w.before ?? null;
    const beforeAt = before === null ? null : before.createdAt.toISOString();
    const beforeId = before?.runId ?? null;
    const rows = (await db.$client`
      SELECT * FROM (
        SELECT u.run_id,
               min(u.session_id) AS session_id,
               CASE WHEN s.deleted_at IS NULL THEN s.title ELSE NULL END AS session_title,
               r.status,
               r.started_at,
               r.finished_at,
               coalesce(r.created_at, min(u.created_at)) AS run_created_at,
               array_agg(DISTINCT u.model ORDER BY u.model) AS models,
               count(*) AS model_calls,
               sum(u.input_tokens) AS input_tokens,
               sum(u.output_tokens) AS output_tokens,
               sum(u.cache_read_tokens) AS cache_read_tokens,
               sum(u.cache_write_tokens) AS cache_write_tokens
          FROM run_usage u
          LEFT JOIN runs r ON r.id = u.run_id
          LEFT JOIN sessions s ON s.id = u.session_id AND s.user_id = u.user_id
         WHERE u.user_id = ${w.userId}
           AND u.created_at >= ${w.since.toISOString()}::timestamptz AND u.created_at < ${w.until.toISOString()}::timestamptz
         GROUP BY u.run_id, r.status, r.started_at, r.finished_at, r.created_at, s.title, s.deleted_at
      ) page
      WHERE ${beforeAt}::timestamptz IS NULL
         OR (page.run_created_at, page.run_id) < (${beforeAt}::timestamptz, ${beforeId}::char(36))
      ORDER BY page.run_created_at DESC, page.run_id DESC
      LIMIT ${limit + 1}
    `) as Row[];
    const mapped: UsageRun[] = rows.slice(0, limit).map((r) => ({
      runId: String(r.run_id),
      sessionId: String(r.session_id),
      sessionTitle:
        r.session_title === null || r.session_title === undefined ? null : String(r.session_title),
      status: r.status === null || r.status === undefined ? null : String(r.status),
      startedAt: date(r.started_at),
      finishedAt: date(r.finished_at),
      runCreatedAt: date(r.run_created_at)!,
      models: Array.isArray(r.models) ? (r.models as unknown[]).map(String) : [],
      modelCalls: num(r.model_calls),
      ...sums(r),
    }));
    const last = mapped.at(-1);
    const next =
      rows.length > limit && last !== undefined
        ? { createdAt: last.runCreatedAt, runId: last.runId }
        : null;
    return { rows: mapped, next };
  },
};
