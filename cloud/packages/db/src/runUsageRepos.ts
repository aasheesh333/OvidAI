import { and, eq } from "drizzle-orm";
import type { Db } from "./client.js";
import { newId } from "./repos.js";
import {
  imageUsageFacts as imageUsageFactsTable,
  runUsage as runUsageTable,
  type ImageUsageFactRow,
  type RunUsageRow,
} from "./schema.js";

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
  /** Stable model-call identity; replaying it never inserts a second charge. */
  quotaCallId?: string | null;
  requestedModel?: string | null;
  providerModel?: string | null;
  costUsd?: string | null;
  costSource?: "litellm" | "provider" | null;
  /** Tests/backfill only; omitted → now(). */
  createdAt?: Date;
  /** Explicit billing classification for new quota-aware telemetry. */
  billingClass?: "ovid_allowance" | "byok";
}

export interface UsageWindow {
  userId: string;
  since: Date;
  until: Date;
  /** Allowance checks opt into one class; history defaults to all actual usage. */
  billingClass?: "ovid_allowance" | "byok";
}

export interface TokenSums {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
}

export interface CostSum {
  /** Exact numeric(38,10) text; null when no measured cost exists. */
  costUsd: string | null;
}

export interface UsageTotals extends TokenSums, CostSum {
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

export interface ImageUsageTotals {
  generateCount: number | null;
  editCount: number | null;
  costUsd: string | null;
}

export interface ImageUsageInput {
  account: string;
  request: string;
  sessionId: string | null;
  runId: string | null;
  op: "generate" | "edit";
  costUsd?: string | null;
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
  costUsd: string | null;
  images: ImageUsageTotals;
  lastAt: Date;
}

export interface UsageRun extends TokenSums, CostSum {
  runId: string;
  sessionId: string;
  sessionTitle: string | null;
  /** null when the runs row is gone. */
  status: string | null;
  startedAt: Date | null;
  finishedAt: Date | null;
  /** Keyset position: the run's created_at (first usage row when the run row is gone). */
  runCreatedAt: Date;
  /** Legacy requested-model array, retained for old DTO consumers. */
  models: string[];
  requestedModels: string[];
  /** Distinct provider-reported models, or null when none were reported. */
  providerModels: string[] | null;
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

function nullableNum(v: unknown): number | null {
  return v === null || v === undefined ? null : num(v);
}

function nullableText(v: unknown): string | null {
  return v === null || v === undefined ? null : String(v);
}

function nullableModel(v: string | null | undefined): string | null {
  return v === null || v === undefined || v.trim() === "" ? null : v;
}

const DECIMAL_RE = /^\d+(?:\.\d{1,10})?$/;

function cost(v: string | null | undefined): string | null {
  if (v === null || v === undefined) return null;
  if (!DECIMAL_RE.test(v)) {
    throw new RangeError("costUsd must be a non-negative decimal with at most 10 places");
  }
  const [whole] = v.split(".");
  if (whole!.length > 28) throw new RangeError("costUsd exceeds numeric(38,10)");
  return v;
}

function costSource(v: "litellm" | "provider" | null | undefined): "litellm" | "provider" | null {
  if (v === null || v === undefined) return null;
  if (v !== "litellm" && v !== "provider") throw new RangeError("invalid costSource");
  return v;
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
  return { runs: num(r.runs), modelCalls: num(r.model_calls), ...sums(r), costUsd: nullableText(r.cost_usd) };
}

function imagesOf(r: Row): ImageUsageTotals {
  return {
    generateCount: nullableNum(r.generate_count),
    editCount: nullableNum(r.edit_count),
    costUsd: nullableText(r.cost_usd),
  };
}

function clampLimit(limit: number | undefined, dflt = DEFAULT_LIMIT, max = MAX_LIMIT): number {
  if (limit === undefined || !Number.isFinite(limit)) return dflt;
  return Math.max(1, Math.min(max, Math.trunc(limit)));
}

export const runUsage = {
  clampLimit: (limit: number | undefined) => clampLimit(limit),

  /** One row per model call, idempotent by (runId, quotaCallId) when supplied. */
  async record(db: Db, row: RunUsageInput): Promise<RunUsageRow> {
    const quotaCallId = nullableModel(row.quotaCallId);
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
        quotaCallId,
        requestedModel:
          row.requestedModel === undefined ? nullableModel(row.model) : nullableModel(row.requestedModel),
        providerModel: nullableModel(row.providerModel),
        costUsd: cost(row.costUsd),
        costSource: costSource(row.costSource),
        ...(row.billingClass !== undefined ? { billingClass: row.billingClass } : {}),
        ...(row.createdAt !== undefined ? { createdAt: row.createdAt } : {}),
      })
      .onConflictDoNothing()
      .returning();
    if (inserted !== undefined) return inserted;
    if (quotaCallId !== null) {
      const [existing] = await db
        .select()
        .from(runUsageTable)
        .where(and(eq(runUsageTable.runId, row.runId), eq(runUsageTable.quotaCallId, quotaCallId)))
        .limit(1);
      if (existing !== undefined) return existing;
    }
    throw new Error("run_usage insert conflict");
  },

  async totals(db: Db, w: UsageWindow): Promise<UsageTotals> {
    const rows = (await db.$client`
      SELECT count(DISTINCT run_id) AS runs,
             count(*) AS model_calls,
             coalesce(sum(input_tokens), 0) AS input_tokens,
             coalesce(sum(output_tokens), 0) AS output_tokens,
             coalesce(sum(cache_read_tokens), 0) AS cache_read_tokens,
             coalesce(sum(cache_write_tokens), 0) AS cache_write_tokens,
             sum(cost_usd)::text AS cost_usd
        FROM run_usage
       WHERE user_id = ${w.userId}
         AND created_at >= ${w.since.toISOString()}::timestamptz AND created_at < ${w.until.toISOString()}::timestamptz
         AND (${w.billingClass ?? null}::text IS NULL OR billing_class = ${w.billingClass ?? "ovid_allowance"})
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
             sum(cache_write_tokens) AS cache_write_tokens,
             sum(cost_usd)::text AS cost_usd
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
             sum(cache_write_tokens) AS cache_write_tokens,
             sum(cost_usd)::text AS cost_usd
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
      WITH run_sessions AS (
        SELECT u.user_id, u.session_id,
               count(DISTINCT u.run_id) AS runs,
               count(*) AS model_calls,
               sum(u.input_tokens) AS input_tokens,
               sum(u.output_tokens) AS output_tokens,
               sum(u.cache_read_tokens) AS cache_read_tokens,
               sum(u.cache_write_tokens) AS cache_write_tokens,
               sum(u.cost_usd)::text AS cost_usd,
               max(u.created_at) AS last_at
          FROM run_usage u
         WHERE u.user_id = ${w.userId}
           AND u.created_at >= ${w.since.toISOString()}::timestamptz AND u.created_at < ${w.until.toISOString()}::timestamptz
           AND (${w.billingClass ?? null}::text IS NULL OR u.billing_class = ${w.billingClass ?? "ovid_allowance"})
         GROUP BY u.user_id, u.session_id
      ), image_sessions AS (
        SELECT f.account AS user_id, f.session_id,
               sum(f.generate_count) AS generate_count,
               sum(f.edit_count) AS edit_count,
               sum(f.cost_usd)::text AS cost_usd,
               max(to_timestamp(j.created_at)) AS last_at
          FROM image_usage_facts f
          JOIN image_jobs j ON j.account = f.account AND j.request = f.request
         WHERE f.account = ${w.userId}
           AND f.session_id IS NOT NULL
           AND to_timestamp(j.created_at) >= ${w.since.toISOString()}::timestamptz
           AND to_timestamp(j.created_at) < ${w.until.toISOString()}::timestamptz
         GROUP BY f.account, f.session_id
      ), session_ids AS (
        SELECT user_id, session_id FROM run_sessions
        UNION
        SELECT user_id, session_id FROM image_sessions
      )
      SELECT ids.session_id,
             CASE WHEN s.deleted_at IS NULL THEN s.title ELSE NULL END AS title,
             coalesce(r.runs, 0) AS runs,
             coalesce(r.model_calls, 0) AS model_calls,
             coalesce(r.input_tokens, 0) AS input_tokens,
             coalesce(r.output_tokens, 0) AS output_tokens,
             coalesce(r.cache_read_tokens, 0) AS cache_read_tokens,
             coalesce(r.cache_write_tokens, 0) AS cache_write_tokens,
             r.cost_usd,
             i.generate_count,
             i.edit_count,
             i.cost_usd AS image_cost_usd,
             CASE
               WHEN r.last_at IS NULL THEN i.last_at
               WHEN i.last_at IS NULL THEN r.last_at
               ELSE greatest(r.last_at, i.last_at)
             END AS last_at
        FROM session_ids ids
        LEFT JOIN run_sessions r ON r.user_id = ids.user_id AND r.session_id = ids.session_id
        LEFT JOIN image_sessions i ON i.user_id = ids.user_id AND i.session_id = ids.session_id
        LEFT JOIN sessions s ON s.id = ids.session_id AND s.user_id = ids.user_id
       ORDER BY coalesce(r.input_tokens, 0) + coalesce(r.output_tokens, 0) DESC, last_at DESC
       LIMIT ${limit}
    `) as Row[];
    return rows.map((r) => ({
      sessionId: String(r.session_id),
      title: r.title === null || r.title === undefined ? null : String(r.title),
      runs: num(r.runs),
      modelCalls: num(r.model_calls),
      ...sums(r),
      costUsd: nullableText(r.cost_usd),
      images: imagesOf({ ...r, cost_usd: r.image_cost_usd }),
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
               array_agg(DISTINCT coalesce(u.requested_model, nullif(u.model, '')) ORDER BY coalesce(u.requested_model, nullif(u.model, '')))
                 FILTER (WHERE coalesce(u.requested_model, nullif(u.model, '')) IS NOT NULL) AS requested_models,
               array_agg(DISTINCT nullif(u.provider_model, '') ORDER BY nullif(u.provider_model, ''))
                 FILTER (WHERE nullif(u.provider_model, '') IS NOT NULL) AS provider_models,
               count(*) AS model_calls,
               sum(u.input_tokens) AS input_tokens,
               sum(u.output_tokens) AS output_tokens,
               sum(u.cache_read_tokens) AS cache_read_tokens,
               sum(u.cache_write_tokens) AS cache_write_tokens,
               sum(u.cost_usd)::text AS cost_usd
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
      requestedModels: Array.isArray(r.requested_models)
        ? (r.requested_models as unknown[]).map(String)
        : [],
      providerModels: Array.isArray(r.provider_models)
        ? (r.provider_models as unknown[]).map(String)
        : null,
      modelCalls: num(r.model_calls),
      ...sums(r),
      costUsd: nullableText(r.cost_usd),
    }));
    const last = mapped.at(-1);
    const next =
      rows.length > limit && last !== undefined
        ? { createdAt: last.runCreatedAt, runId: last.runId }
        : null;
    return { rows: mapped, next };
  },
};

/** Approved 0038 image satellite; image_jobs remains the charge/result ledger. */
export const imageUsage = {
  async record(db: Db, row: ImageUsageInput): Promise<ImageUsageFactRow> {
    const [inserted] = await db
      .insert(imageUsageFactsTable)
      .values({
        account: row.account,
        request: row.request,
        sessionId: row.sessionId,
        runId: row.runId,
        generateCount: row.op === "generate" ? 1 : 0,
        editCount: row.op === "edit" ? 1 : 0,
        costUsd: cost(row.costUsd),
      })
      .onConflictDoNothing()
      .returning();
    if (inserted !== undefined) return inserted;
    const [existing] = await db
      .select()
      .from(imageUsageFactsTable)
      .where(and(
        eq(imageUsageFactsTable.account, row.account),
        eq(imageUsageFactsTable.request, row.request),
      ))
      .limit(1);
    if (existing === undefined) throw new Error("image_usage_facts insert conflict");
    return existing;
  },

  async totals(db: Db, w: UsageWindow): Promise<ImageUsageTotals> {
    const rows = (await db.$client`
      SELECT sum(f.generate_count) AS generate_count,
             sum(f.edit_count) AS edit_count,
             sum(f.cost_usd)::text AS cost_usd
        FROM image_usage_facts f
        JOIN image_jobs j ON j.account = f.account AND j.request = f.request
       WHERE f.account = ${w.userId}
         AND to_timestamp(j.created_at) >= ${w.since.toISOString()}::timestamptz
         AND to_timestamp(j.created_at) < ${w.until.toISOString()}::timestamptz
    `) as Row[];
    return imagesOf(rows[0] ?? {});
  },
};
