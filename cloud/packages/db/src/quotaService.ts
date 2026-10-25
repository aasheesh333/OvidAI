import { and, eq, sql, type SQL } from "drizzle-orm";
import { planFor, storageBytes as planStorageBytes } from "@ovid/shared";
import type { Db } from "./client.js";
import { newId } from "./repos.js";
import { attachments, users } from "./schema.js";

export const RUN_SOURCES = [
  "interactive",
  "schedule_create",
  "schedule_run_now",
  "schedule_tick",
  "schedule_retry",
  "parent_wake",
  "subagent",
  "collab",
] as const;

export type RunSource = (typeof RUN_SOURCES)[number];
export type QuotaWindow = "day" | "month";
export type QuotaCostSource = "litellm" | "provider";

export interface QuotaExhausted {
  ok: false;
  window: QuotaWindow;
  resetsAt: Date;
}

export type QuotaAdmission = { ok: true } | QuotaExhausted;
export type QuotaReservation = { ok: true; reservationId: string };

/** Mirrors agent-core Usage without introducing a package dependency. */
export interface QuotaUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens?: number;
  cacheWriteTokens?: number;
  requestedModel?: string | null;
  providerModel?: string | null;
  costUsd?: string | null;
  costSource?: QuotaCostSource | null;
}

export interface RunQuotaAdmissionInput {
  actorUserId: string;
  source: RunSource;
  runId: string;
  idempotencyKey: string;
}

export interface ModelCallReservationInput {
  actorUserId: string;
  runId: string;
  reservationKey: string;
  inputTokens: number;
  maxOutputTokens: number;
  attemptId?: string | null;
  requestedModel?: string | null;
  /** Optional conservative USD allowance; exact decimal with at most 10 places. */
  maxCostUsd?: string;
}

export interface RunQuotaServiceOptions {
  now?: () => Date;
  /** Test/forward-compatible override; the default is the canonical plan table. */
  tokenCaps?: { perDay: number; perMonth: number };
  /** Null/omitted windows have no configured USD ceiling. */
  usdCaps?: { perDay?: string | null; perMonth?: string | null };
}

export class QuotaContractError extends Error {
  constructor(readonly code: string) {
    super(code);
    this.name = "QuotaContractError";
  }
}

type Tx = Parameters<Parameters<Db["transaction"]>[0]>[0];
type Row = Record<string, unknown>;

async function rows<T extends Row>(tx: Tx, query: SQL): Promise<T[]> {
  return (await tx.execute(query)) as unknown as T[];
}

function requiredId(value: string, name: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new RangeError(`${name} must be a non-empty string`);
  }
  return value;
}

function tokenCount(value: number, name: string): number {
  if (!Number.isSafeInteger(value) || value < 0 || value > 2_147_483_647) {
    throw new RangeError(`${name} must be a non-negative 32-bit integer`);
  }
  return value;
}

function byteCount(value: number, name: string): number {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new RangeError(`${name} must be a non-negative safe integer`);
  }
  return value;
}

function modelValue(value: string | null | undefined): string | null | undefined {
  if (value === undefined || value === null) return value;
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new RangeError("model ids must be non-empty strings or null");
  }
  return value;
}

const DECIMAL_SCALE = 10;
const DECIMAL_FACTOR = 10n ** BigInt(DECIMAL_SCALE);
const DECIMAL_RE = /^\d+(?:\.\d{1,10})?$/;

function decimalUnits(value: string, name = "costUsd"): bigint {
  if (typeof value !== "string" || !DECIMAL_RE.test(value)) {
    throw new RangeError(`${name} must be a non-negative decimal with at most 10 places`);
  }
  const [whole, fraction = ""] = value.split(".");
  if (whole!.length > 28) throw new RangeError(`${name} exceeds numeric(38,10)`);
  return BigInt(whole!) * DECIMAL_FACTOR + BigInt(fraction.padEnd(DECIMAL_SCALE, "0"));
}

function nullableDecimal(value: string | null | undefined): string | null {
  if (value === undefined || value === null) return null;
  decimalUnits(value);
  return value;
}

function utcWindow(now: Date, kind: QuotaWindow): { start: Date; end: Date } {
  const start = kind === "day"
    ? new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()))
    : new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
  const end = kind === "day"
    ? new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1))
    : new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1));
  return { start, end };
}

async function lockUsers(tx: Tx, ids: readonly string[]): Promise<Map<string, string>> {
  const tiers = new Map<string, string>();
  for (const uid of [...new Set(ids)].sort()) {
    const found = await tx
      .select({ uid: users.uid, tier: users.tier })
      .from(users)
      .where(eq(users.uid, uid))
      .for("update")
      .limit(1);
    if (found[0] === undefined) throw new QuotaContractError("unknown_user");
    tiers.set(uid, found[0].tier);
  }
  return tiers;
}

interface CounterRow extends Row {
  actor_user_id: string;
  window_kind: QuotaWindow;
  window_start: Date;
  window_end: Date;
  used_tokens: number | string;
  reserved_tokens: number | string;
  used_usd: string;
  reserved_usd: string;
}

async function ensureCounter(
  tx: Tx,
  actorUserId: string,
  kind: QuotaWindow,
  start: Date,
  end: Date,
): Promise<void> {
  await tx.execute(sql`
    INSERT INTO usage_quota_counters
      (actor_user_id, window_kind, window_start, window_end)
    VALUES
      (${actorUserId}, ${kind}, ${start.toISOString()}::timestamptz,
       ${end.toISOString()}::timestamptz)
    ON CONFLICT (actor_user_id, window_kind, window_start) DO NOTHING`);
}

async function counterFor(
  tx: Tx,
  actorUserId: string,
  kind: QuotaWindow,
  now: Date,
): Promise<CounterRow> {
  const window = utcWindow(now, kind);
  await ensureCounter(tx, actorUserId, kind, window.start, window.end);
  const found = await rows<CounterRow>(tx, sql`
    SELECT * FROM usage_quota_counters
     WHERE actor_user_id = ${actorUserId}
       AND window_kind = ${kind}
       AND window_start = ${window.start.toISOString()}::timestamptz
     FOR UPDATE`);
  if (found[0] === undefined) throw new QuotaContractError("quota_counter_missing");
  return found[0];
}

function exhaustion(
  options: RunQuotaServiceOptions,
  tier: string,
  counters: Record<QuotaWindow, CounterRow>,
  additionalTokens: number,
  additionalUsd: string,
  admission: boolean,
): QuotaExhausted | null {
  const tokenCaps = options.tokenCaps ?? planFor(tier).tokens;
  const additionalCost = decimalUnits(additionalUsd);
  for (const kind of ["day", "month"] as const) {
    const counter = counters[kind];
    const used = Number(counter.used_tokens) + Number(counter.reserved_tokens);
    const cap = kind === "day" ? tokenCaps.perDay : tokenCaps.perMonth;
    const tokenTotal = used + (admission ? 0 : additionalTokens);
    if (
      Number.isFinite(cap) && cap > 0 &&
      (admission ? tokenTotal >= cap : tokenTotal > cap)
    ) {
      return { ok: false, window: kind, resetsAt: new Date(counter.window_end) };
    }
    const usdCap = kind === "day" ? options.usdCaps?.perDay : options.usdCaps?.perMonth;
    if (usdCap !== undefined && usdCap !== null) {
      const limit = decimalUnits(usdCap, `usdCaps.${kind}`);
      const total = decimalUnits(counter.used_usd) + decimalUnits(counter.reserved_usd) +
        (admission ? 0n : additionalCost);
      if (limit > 0n && (admission ? total >= limit : total > limit)) {
        return { ok: false, window: kind, resetsAt: new Date(counter.window_end) };
      }
    }
  }
  return null;
}

async function changeReservationAllowance(
  tx: Tx,
  reservation: Row,
  direction: 1 | -1,
  now: Date,
): Promise<void> {
  const tokens = Number(reservation.input_tokens) + Number(reservation.max_output_tokens);
  const cost = String(reservation.reserved_cost_usd);
  const amount = direction === 1 ? tokens : -tokens;
  const costAmount = direction === 1 ? cost : `-${cost}`;
  for (const [column, start] of [
    ["day", reservation.day_window_start],
    ["month", reservation.month_window_start],
  ] as const) {
    const startIso = start instanceof Date ? start.toISOString() : String(start);
    await tx.execute(sql`
      UPDATE usage_quota_counters
         SET reserved_tokens = reserved_tokens + ${amount},
             reserved_usd = reserved_usd + ${costAmount}::numeric,
             updated_at = ${now.toISOString()}::timestamptz
       WHERE actor_user_id = ${String(reservation.actor_user_id)}
         AND window_kind = ${column}
         AND window_start = ${startIso}::timestamptz`);
  }
}

function sameModel(a: unknown, b: string | null): boolean {
  return (a === null || a === undefined ? null : String(a)) === b;
}

export class RunQuotaService {
  constructor(private readonly db: Db, private readonly options: RunQuotaServiceOptions = {}) {}

  private now(): Date {
    const value = this.options.now?.() ?? new Date();
    if (!(value instanceof Date) || !Number.isFinite(value.getTime())) {
      throw new RangeError("quota clock returned an invalid Date");
    }
    return new Date(value.getTime());
  }

  async admitRun(input: RunQuotaAdmissionInput): Promise<QuotaAdmission> {
    requiredId(input.actorUserId, "actorUserId");
    requiredId(input.runId, "runId");
    requiredId(input.idempotencyKey, "idempotencyKey");
    if (!RUN_SOURCES.includes(input.source)) throw new RangeError("invalid RunSource");
    return this.db.transaction(async (tx) => {
      const tiers = await lockUsers(tx, [input.actorUserId]);
      const existing = await rows<Row>(tx, sql`
        SELECT * FROM usage_run_admissions
         WHERE actor_user_id = ${input.actorUserId}
           AND idempotency_key = ${input.idempotencyKey}
         LIMIT 1`);
      if (existing[0] !== undefined) {
        if (existing[0].run_id !== input.runId || existing[0].source !== input.source) {
          throw new QuotaContractError("idempotency_conflict");
        }
        return { ok: true as const };
      }
      // Initial admission must be anchored to a real canonical run. KEY SHARE
      // keeps a concurrent delete from removing it before the admission commits.
      const run = await rows<{ id: string }>(tx, sql`
        SELECT id FROM runs WHERE id = ${input.runId} FOR KEY SHARE`);
      if (run[0] === undefined) throw new QuotaContractError("run_not_found");
      const now = this.now();
      const counters = {
        day: await counterFor(tx, input.actorUserId, "day", now),
        month: await counterFor(tx, input.actorUserId, "month", now),
      };
      const denied = exhaustion(
        this.options,
        tiers.get(input.actorUserId)!,
        counters,
        0,
        "0",
        true,
      );
      if (denied !== null) return denied;
      await tx.execute(sql`
        INSERT INTO usage_run_admissions
          (id, actor_user_id, source, run_id, idempotency_key, created_at)
        VALUES
          (${newId()}, ${input.actorUserId}, ${input.source}, ${input.runId},
           ${input.idempotencyKey}, ${now.toISOString()}::timestamptz)`);
      return { ok: true as const };
    });
  }

  async reserveModelCall(
    input: ModelCallReservationInput,
  ): Promise<QuotaReservation | QuotaExhausted> {
    requiredId(input.actorUserId, "actorUserId");
    requiredId(input.runId, "runId");
    requiredId(input.reservationKey, "reservationKey");
    tokenCount(input.inputTokens, "inputTokens");
    tokenCount(input.maxOutputTokens, "maxOutputTokens");
    const requestedModel = modelValue(input.requestedModel) ?? null;
    const attemptId = input.attemptId === undefined || input.attemptId === null
      ? null
      : requiredId(input.attemptId, "attemptId");
    const reservedCost = input.maxCostUsd ?? "0";
    decimalUnits(reservedCost, "maxCostUsd");
    const allowance = input.inputTokens + input.maxOutputTokens;

    return this.db.transaction(async (tx) => {
      const tiers = await lockUsers(tx, [input.actorUserId]);
      const existingRows = await rows<Row>(tx, sql`
        SELECT * FROM usage_quota_reservations
         WHERE actor_user_id = ${input.actorUserId}
           AND reservation_key = ${input.reservationKey}
         FOR UPDATE`);
      const existing = existingRows[0];
      if (existing !== undefined) {
        const unchanged =
          existing.run_id === input.runId &&
          Number(existing.input_tokens) === input.inputTokens &&
          Number(existing.max_output_tokens) === input.maxOutputTokens &&
          sameModel(existing.requested_model, requestedModel) &&
          (existing.attempt_id ?? null) === attemptId &&
          decimalUnits(String(existing.reserved_cost_usd)) === decimalUnits(reservedCost);
        if (!unchanged) throw new QuotaContractError("idempotency_conflict");
        if (existing.state === "reserved" || existing.state === "settled") {
          return { ok: true as const, reservationId: String(existing.id) };
        }
        if (existing.state !== "released") throw new QuotaContractError("invalid_reservation_state");
      }

      // A new reservation requires a live canonical run. A retry of a released
      // reservation may instead rely on the session lineage captured while that
      // run existed; deletion must never erase it or make usage unledgerable.
      const run = await rows<{ session_id: string }>(tx, sql`
        SELECT session_id FROM runs WHERE id = ${input.runId} FOR KEY SHARE`);
      if (existing === undefined && run[0] === undefined) {
        throw new QuotaContractError("run_not_found");
      }
      const sessionId = existing?.session_id ?? run[0]?.session_id ?? null;
      if (sessionId === null) throw new QuotaContractError("run_lineage_missing");

      const now = this.now();
      const counters = {
        day: await counterFor(tx, input.actorUserId, "day", now),
        month: await counterFor(tx, input.actorUserId, "month", now),
      };
      const denied = exhaustion(
        this.options,
        tiers.get(input.actorUserId)!,
        counters,
        allowance,
        reservedCost,
        false,
      );
      if (denied !== null) return denied;

      const reservationId = existing === undefined ? newId() : String(existing.id);
      const admission = await rows<{ source: string }>(tx, sql`
        SELECT source FROM usage_run_admissions
         WHERE actor_user_id = ${input.actorUserId} AND run_id = ${input.runId}
         ORDER BY created_at DESC, id DESC LIMIT 1`);
      const runSource = existing?.run_source ?? admission[0]?.source ?? null;
      const dayStart = utcWindow(now, "day").start.toISOString();
      const monthStart = utcWindow(now, "month").start.toISOString();
      if (existing === undefined) {
        await tx.execute(sql`
          INSERT INTO usage_quota_reservations
            (id, actor_user_id, run_id, attempt_id, session_id, run_source,
             reservation_key, state, input_tokens, max_output_tokens, reserved_cost_usd,
             requested_model, day_window_start, month_window_start,
             reserved_at, created_at, updated_at)
          VALUES
            (${reservationId}, ${input.actorUserId}, ${input.runId}, ${attemptId},
             ${sessionId}, ${runSource},
             ${input.reservationKey}, 'reserved', ${input.inputTokens}, ${input.maxOutputTokens},
             ${reservedCost}::numeric, ${requestedModel},
             ${dayStart}::timestamptz, ${monthStart}::timestamptz,
             ${now.toISOString()}::timestamptz, ${now.toISOString()}::timestamptz,
             ${now.toISOString()}::timestamptz)`);
      } else {
        await tx.execute(sql`
          UPDATE usage_quota_reservations
             SET state = 'reserved', attempt_id = ${attemptId},
                 session_id = ${sessionId},
                 run_source = ${runSource},
                 reserved_cost_usd = ${reservedCost}::numeric,
                 requested_model = ${requestedModel}, provider_model = NULL,
                 actual_input_tokens = NULL, actual_output_tokens = NULL,
                 actual_cache_read_tokens = NULL, actual_cache_write_tokens = NULL,
                 cost_usd = NULL, cost_source = NULL, run_usage_id = NULL,
                 day_window_start = ${dayStart}::timestamptz,
                 month_window_start = ${monthStart}::timestamptz,
                 reserved_at = ${now.toISOString()}::timestamptz,
                 settled_at = NULL, released_at = NULL,
                 updated_at = ${now.toISOString()}::timestamptz
           WHERE id = ${reservationId}`);
      }
      await changeReservationAllowance(tx, {
        id: reservationId,
        actor_user_id: input.actorUserId,
        input_tokens: input.inputTokens,
        max_output_tokens: input.maxOutputTokens,
        reserved_cost_usd: reservedCost,
        day_window_start: dayStart,
        month_window_start: monthStart,
      }, 1, now);
      return { ok: true as const, reservationId };
    });
  }

  async settleModelCall(input: {
    reservationId: string;
    usage: QuotaUsage;
  }): Promise<void> {
    requiredId(input.reservationId, "reservationId");
    tokenCount(input.usage.inputTokens, "usage.inputTokens");
    tokenCount(input.usage.outputTokens, "usage.outputTokens");
    const cacheRead = input.usage.cacheReadTokens === undefined
      ? 0
      : tokenCount(input.usage.cacheReadTokens, "usage.cacheReadTokens");
    const cacheWrite = input.usage.cacheWriteTokens === undefined
      ? 0
      : tokenCount(input.usage.cacheWriteTokens, "usage.cacheWriteTokens");
    const costUsd = nullableDecimal(input.usage.costUsd);
    if (
      input.usage.costSource !== undefined && input.usage.costSource !== null &&
      input.usage.costSource !== "litellm" && input.usage.costSource !== "provider"
    ) {
      throw new RangeError("invalid costSource");
    }
    modelValue(input.usage.requestedModel);
    modelValue(input.usage.providerModel);

    await this.db.transaction(async (tx) => {
      const identity = await rows<{ actor_user_id: string }>(tx, sql`
        SELECT actor_user_id FROM usage_quota_reservations
         WHERE id = ${input.reservationId} LIMIT 1`);
      if (identity[0] === undefined) throw new QuotaContractError("reservation_not_found");
      await lockUsers(tx, [identity[0].actor_user_id]);
      const found = await rows<Row>(tx, sql`
        SELECT * FROM usage_quota_reservations
         WHERE id = ${input.reservationId} FOR UPDATE`);
      const reservation = found[0]!;
      if (reservation.state === "released") {
        throw new QuotaContractError("reservation_released");
      }
      const requestedModel = input.usage.requestedModel === undefined
        ? (reservation.requested_model === null ? null : String(reservation.requested_model))
        : modelValue(input.usage.requestedModel)!;
      const providerModel = input.usage.providerModel === undefined
        ? (reservation.provider_model === null || reservation.provider_model === undefined
            ? null
            : String(reservation.provider_model))
        : modelValue(input.usage.providerModel)!;
      const costSource = input.usage.costSource ?? null;
      if (reservation.state === "settled") {
        const unchanged =
          Number(reservation.actual_input_tokens) === input.usage.inputTokens &&
          Number(reservation.actual_output_tokens) === input.usage.outputTokens &&
          Number(reservation.actual_cache_read_tokens) === cacheRead &&
          Number(reservation.actual_cache_write_tokens) === cacheWrite &&
          sameModel(reservation.requested_model, requestedModel) &&
          sameModel(reservation.provider_model, providerModel) &&
          sameModel(reservation.cost_source, costSource) &&
          (reservation.cost_usd === null || reservation.cost_usd === undefined
            ? costUsd === null
            : costUsd !== null && decimalUnits(String(reservation.cost_usd)) === decimalUnits(costUsd));
        if (!unchanged) throw new QuotaContractError("idempotency_conflict");
        return;
      }
      if (reservation.state !== "reserved") {
        throw new QuotaContractError("invalid_reservation_state");
      }

      const now = this.now();
      if (reservation.session_id === null || reservation.session_id === undefined) {
        // Actual usage is authoritative only in run_usage. Never mark a call
        // settled or move used counters when there is no session key to ledger.
        throw new QuotaContractError("run_lineage_missing");
      }
      const runUsageId = newId();
      // The old model column is NOT NULL. An empty legacy value carries no
      // model claim when both additive, nullable model facts are unknown.
      const legacyModel = requestedModel ?? providerModel ?? "";
      // run_usage deliberately has no run/session FK: the captured canonical
      // lineage remains ledgerable even if those rows are deleted mid-call.
      await tx.execute(sql`
        INSERT INTO run_usage
          (id, user_id, session_id, run_id, model, input_tokens, output_tokens,
           cache_read_tokens, cache_write_tokens, quota_reservation_id, quota_call_id,
           attempt_id, requested_model, provider_model, cost_usd, cost_source, created_at)
        VALUES
          (${runUsageId}, ${String(reservation.actor_user_id)}, ${String(reservation.session_id)},
           ${String(reservation.run_id)}, ${legacyModel}, ${input.usage.inputTokens},
           ${input.usage.outputTokens}, ${cacheRead}, ${cacheWrite}, ${input.reservationId},
           ${String(reservation.reservation_key)}, ${reservation.attempt_id ?? null},
           ${requestedModel}, ${providerModel}, ${costUsd}::numeric, ${costSource},
           ${now.toISOString()}::timestamptz)`);
      await changeReservationAllowance(tx, reservation, -1, now);
      await tx.execute(sql`
        UPDATE usage_quota_reservations
           SET state = 'settled', requested_model = ${requestedModel},
               provider_model = ${providerModel},
               actual_input_tokens = ${input.usage.inputTokens},
               actual_output_tokens = ${input.usage.outputTokens},
               actual_cache_read_tokens = ${cacheRead}, actual_cache_write_tokens = ${cacheWrite},
               cost_usd = ${costUsd}::numeric, cost_source = ${costSource},
               run_usage_id = ${runUsageId}, settled_at = ${now.toISOString()}::timestamptz,
               released_at = NULL, updated_at = ${now.toISOString()}::timestamptz
         WHERE id = ${input.reservationId}`);
    });
  }

  async releaseModelCall(reservationId: string): Promise<void> {
    requiredId(reservationId, "reservationId");
    await this.db.transaction(async (tx) => {
      const identity = await rows<{ actor_user_id: string }>(tx, sql`
        SELECT actor_user_id FROM usage_quota_reservations WHERE id = ${reservationId} LIMIT 1`);
      if (identity[0] === undefined) throw new QuotaContractError("reservation_not_found");
      await lockUsers(tx, [identity[0].actor_user_id]);
      const found = await rows<Row>(tx, sql`
        SELECT * FROM usage_quota_reservations WHERE id = ${reservationId} FOR UPDATE`);
      const reservation = found[0]!;
      if (reservation.state === "settled" || reservation.state === "released") return;
      if (reservation.state !== "reserved") {
        throw new QuotaContractError("invalid_reservation_state");
      }
      const now = this.now();
      await changeReservationAllowance(tx, reservation, -1, now);
      await tx.execute(sql`
        UPDATE usage_quota_reservations
           SET state = 'released', released_at = ${now.toISOString()}::timestamptz,
               updated_at = ${now.toISOString()}::timestamptz
         WHERE id = ${reservationId}`);
    });
  }
}

export interface StorageReservationInput {
  reservationId: string;
  ownerUserId: string;
  uploaderUserId: string;
  sessionId: string;
  declaredBytes: number;
  objectId?: string | null;
}

export interface StorageFinalizeInput {
  reservationId: string;
  actualBytes: number;
  contentType: string | null;
  etag: string | null;
}

export interface StorageQuotaExhausted {
  ok: false;
  scope: "upload" | "storage";
  resetsAt: Date | null;
}

export type StorageQuotaReservationResult =
  | { ok: true; reservationId: string }
  | StorageQuotaExhausted;

export interface StorageReservationStoreOptions {
  now?: () => Date;
  /** Test/forward-compatible override; defaults to the host's canonical plan. */
  storageBytes?: number;
  /** Test/forward-compatible override; defaults to the actor's canonical plan. */
  uploads?: { count: number; windowHours: number };
}

interface UploadCounter extends Row {
  used_uploads: number;
  reserved_uploads: number;
  oldest_at: Date | null;
}

async function storageCounter(tx: Tx, ownerUserId: string): Promise<Row> {
  await tx.execute(sql`
    INSERT INTO storage_usage_counters (owner_user_id) VALUES (${ownerUserId})
    ON CONFLICT (owner_user_id) DO NOTHING`);
  const found = await rows<Row>(tx, sql`
    SELECT * FROM storage_usage_counters WHERE owner_user_id = ${ownerUserId} FOR UPDATE`);
  return found[0]!;
}

async function refreshUploadCounter(
  tx: Tx,
  actorUserId: string,
  windowHours: number,
  now: Date,
): Promise<UploadCounter> {
  const start = new Date(now.getTime() - windowHours * 3_600_000);
  const found = await rows<UploadCounter>(tx, sql`
    SELECT
      count(*) FILTER (WHERE state = 'finalized')::int AS used_uploads,
      count(*) FILTER (WHERE state = 'reserved')::int AS reserved_uploads,
      min(reserved_at) AS oldest_at
    FROM storage_reservations
    WHERE actor_user_id = ${actorUserId}
      AND state IN ('reserved', 'finalized')
      AND reserved_at >= ${start.toISOString()}::timestamptz
      AND reserved_at <= ${now.toISOString()}::timestamptz`);
  const counter = found[0] ?? { used_uploads: 0, reserved_uploads: 0, oldest_at: null };
  await tx.execute(sql`
    INSERT INTO upload_window_counters
      (actor_user_id, window_hours, window_start, window_end,
       used_uploads, reserved_uploads, updated_at)
    VALUES
      (${actorUserId}, ${windowHours}, ${start.toISOString()}::timestamptz,
       ${now.toISOString()}::timestamptz, ${counter.used_uploads},
       ${counter.reserved_uploads}, ${now.toISOString()}::timestamptz)
    ON CONFLICT (actor_user_id, window_hours) DO UPDATE SET
      window_start = EXCLUDED.window_start, window_end = EXCLUDED.window_end,
      used_uploads = EXCLUDED.used_uploads,
      reserved_uploads = EXCLUDED.reserved_uploads,
      updated_at = EXCLUDED.updated_at`);
  await rows<Row>(tx, sql`
    SELECT * FROM upload_window_counters
     WHERE actor_user_id = ${actorUserId} AND window_hours = ${windowHours}
     FOR UPDATE`);
  return counter;
}

export class StorageReservationStore {
  constructor(
    private readonly db: Db,
    private readonly options: StorageReservationStoreOptions = {},
  ) {}

  private now(): Date {
    const value = this.options.now?.() ?? new Date();
    if (!(value instanceof Date) || !Number.isFinite(value.getTime())) {
      throw new RangeError("storage clock returned an invalid Date");
    }
    return new Date(value.getTime());
  }

  private uploadPlan(tier: string): { count: number; windowHours: number } {
    const plan = this.options.uploads ?? planFor(tier).uploads;
    if (!Number.isInteger(plan.windowHours) || plan.windowHours <= 0) {
      throw new RangeError("upload windowHours must be a positive integer");
    }
    return plan;
  }

  private storagePlan(tier: string): number {
    const bytes = this.options.storageBytes ?? planStorageBytes(tier);
    if (!Number.isSafeInteger(bytes) || bytes < 0) {
      throw new RangeError("storage byte cap must be a non-negative safe integer");
    }
    return bytes;
  }

  async reserve(input: StorageReservationInput): Promise<StorageReservationResult> {
    requiredId(input.reservationId, "reservationId");
    requiredId(input.ownerUserId, "ownerUserId");
    requiredId(input.uploaderUserId, "uploaderUserId");
    requiredId(input.sessionId, "sessionId");
    byteCount(input.declaredBytes, "declaredBytes");
    const objectId = input.objectId ?? null;
    return this.db.transaction(async (tx) => {
      const tiers = await lockUsers(tx, [input.ownerUserId, input.uploaderUserId]);
      const existingRows = await rows<Row>(tx, sql`
        SELECT * FROM storage_reservations WHERE id = ${input.reservationId} FOR UPDATE`);
      const existing = existingRows[0];
      if (existing !== undefined) {
        const unchanged =
          existing.owner_user_id === input.ownerUserId &&
          existing.actor_user_id === input.uploaderUserId &&
          existing.session_id === input.sessionId &&
          Number(existing.declared_bytes) === input.declaredBytes &&
          (existing.object_id ?? null) === objectId;
        if (!unchanged) throw new QuotaContractError("idempotency_conflict");
        if (existing.state === "released") throw new QuotaContractError("reservation_released");
        return { ok: true as const, reservationId: input.reservationId };
      }
  /** Explicitly marks an ordinary attachment; other object kinds skip this fence. */
  attachment?: boolean;
  /** Current HEAD evidence from the caller's reservation/finalize transaction. */
  head?: { bytes: number; contentType: string | null; etag: string | null } | null;
}

export interface LegacyAttachmentReconciliation {
  outcome: "existing" | "pending" | "preserved" | "failed";
  ownerUserId: string;
}

/**
 * Called INSIDE StorageReservationStore.reserve's owner/user and attachment
 * lock scope. Never returns a valid HEAD to a later separate reservation: the
 * same transaction either preserves evidence, inserts a released failure
 * tombstone, or allows reservation creation with the still-current status.
 */
async function reconcileLegacyAttachmentTx(
  tx: Tx,
  input: StorageReservationInput,
  now: Date,
): Promise<LegacyAttachmentReconciliation> {
  if (input.head === undefined) return { outcome: "existing", ownerUserId: input.ownerUserId };
  if (input.attachment !== true) return { outcome: "existing", ownerUserId: input.ownerUserId };
  if (input.objectId === null || input.objectId !== input.reservationId) {
    throw new QuotaContractError("legacy_identity_mismatch");
  }
  // Lock users first in canonical sorted order, then the attachment, then its
  // reservation. Finalize/release use the same order for ordinary attachments.
  const attachmentRows = await tx
    .select()
    .from(attachments)
    .where(and(
      eq(attachments.id, input.reservationId),
      eq(attachments.sessionId, input.sessionId),
      eq(attachments.userId, input.ownerUserId),
    ))
    .for("update")
    .limit(1);
  const attachment = attachmentRows[0];
  const reservationRows = await rows<Row>(tx, sql`
    SELECT * FROM storage_reservations WHERE id = ${input.reservationId} FOR UPDATE`);
  const existing = reservationRows[0];
  if (existing !== undefined) return { outcome: "existing", ownerUserId: input.ownerUserId };
  if (attachment === undefined) throw new QuotaContractError("reservation_not_found");

  const head = input.head;
  const actualContentType = head?.contentType ?? null;
  const preserved = attachment.uploadStatus === "ready" &&
    attachment.actualBytes !== null && attachment.finalizedAt !== null &&
    head !== null && attachment.actualBytes === head.bytes &&
    (attachment.actualContentType ?? null) === actualContentType &&
    attachment.size === head.bytes &&
    (!attachment.contentTypeDeclared || attachment.contentType === actualContentType);
  if (preserved) {
    await tx.execute(sql`
      INSERT INTO storage_reservations
        (id, actor_user_id, owner_user_id, session_id, object_id, state,
         declared_bytes, actual_bytes, actual_content_type, etag,
         reserved_at, finalized_at, created_at, updated_at)
      VALUES
        (${input.reservationId}, ${input.uploaderUserId}, ${input.ownerUserId},
         ${input.sessionId}, ${input.objectId}, 'finalized',
         ${attachment.actualBytes}, ${attachment.actualBytes}, ${attachment.actualContentType},
         ${head!.etag}, ${attachment.createdAt.toISOString()}::timestamptz,
         ${attachment.finalizedAt!.toISOString()}::timestamptz,
         ${now.toISOString()}::timestamptz, ${now.toISOString()}::timestamptz)`);
    return { outcome: "preserved", ownerUserId: input.ownerUserId };
  }
  if (attachment.uploadStatus === "pending" && head !== null) {
    return { outcome: "pending", ownerUserId: input.ownerUserId };
  }

  // Failure also gets a released identity. The later reserve in THIS SAME
  // transaction sees it and refuses stale valid-HEAD recovery. Zero declared
  // bytes means this tombstone never consumes an actor upload slot.
  await tx.execute(sql`
    INSERT INTO storage_reservations
      (id, actor_user_id, owner_user_id, session_id, object_id, state,
       declared_bytes, reserved_at, released_at, created_at, updated_at)
    VALUES
      (${input.reservationId}, ${input.uploaderUserId}, ${input.ownerUserId},
       ${input.sessionId}, ${input.objectId}, 'released', 0,
       ${now.toISOString()}::timestamptz, ${now.toISOString()}::timestamptz,
       ${now.toISOString()}::timestamptz, ${now.toISOString()}::timestamptz)`);
  await tx.update(attachments).set({
    uploadStatus: "failed",
    actualBytes: null,
    actualContentType: null,
    finalizedAt: null,
  }).where(eq(attachments.id, attachment.id));
  return { outcome: "failed", ownerUserId: input.ownerUserId };
}

export async function lockAttachmentForStorageCleanup(
  tx: Tx,
  input: StorageReservationInput,
): Promise<void> {
  await lockAttachmentForUploadTx(tx, input, { allowFailed: true });
}

async function lockAttachmentForUploadTx(
  tx: Tx,
  input: StorageReservationInput,
  options: { allowFailed?: boolean; requirePresent?: boolean } = {},
): Promise<void> {
  if (input.attachment !== true || input.objectId !== input.reservationId) return;
  // Share/artifact non-upload keys do not have attachment rows; only the
  // canonical attachment identity participates in this status fence.
  const rows = await tx.select({ id: attachments.id, uploadStatus: attachments.uploadStatus })
    .from(attachments)
    .where(and(
      eq(attachments.id, input.reservationId),
      eq(attachments.sessionId, input.sessionId),
      eq(attachments.userId, input.ownerUserId),
    ))
    .for("update")
    .limit(1);
  const attachment = rows[0];
  if (attachment === undefined) {
    if (options.requirePresent === true) throw new QuotaContractError("attachment_not_found");
    return;
  }
  if (options.allowFailed !== true && attachment.uploadStatus === "failed") {
    throw new QuotaContractError("attachment_failed");
  }

      const now = this.now();
      const upload = this.uploadPlan(tiers.get(input.uploaderUserId)!);
      const window = await refreshUploadCounter(tx, input.uploaderUserId, upload.windowHours, now);
      if (
        Number.isFinite(upload.count) && upload.count > 0 &&
        Number(window.used_uploads) + Number(window.reserved_uploads) + 1 > upload.count
  attachment?: boolean;
      ) {
        const oldest = window.oldest_at === null ? null : new Date(window.oldest_at);
        return {
          ok: false as const,
          scope: "upload" as const,
          resetsAt: oldest === null
            ? new Date(now.getTime() + upload.windowHours * 3_600_000)
            : new Date(oldest.getTime() + upload.windowHours * 3_600_000),
        };
      }
      const counter = await storageCounter(tx, input.ownerUserId);
      const storageCap = this.storagePlan(tiers.get(input.ownerUserId)!);
export type StorageReservationResult =
  | StorageQuotaReservationResult
  | {
      ok: false;
      scope: "attachment";
      code: "attachment_failed";
      /** Non-quota refusals have no retry window; keeps failure projections total. */
      resetsAt: null;
    };

      if (Number(counter.used_bytes) + Number(counter.reserved_bytes) + input.declaredBytes > storageCap) {
        return { ok: false as const, scope: "storage" as const, resetsAt: null };
      }
      await tx.execute(sql`
        INSERT INTO storage_reservations
          (id, actor_user_id, owner_user_id, session_id, object_id, state,
  /** Internal deterministic lock-order synchronization; production leaves it undefined. */
  afterAttachmentLock?(operation: "finalize" | "release", reservationId: string): Promise<void>;
           declared_bytes, reserved_at, created_at, updated_at)
        VALUES
          (${input.reservationId}, ${input.uploaderUserId}, ${input.ownerUserId},
           ${input.sessionId}, ${objectId}, 'reserved', ${input.declaredBytes},
           ${now.toISOString()}::timestamptz, ${now.toISOString()}::timestamptz,
           ${now.toISOString()}::timestamptz)`);
      await tx.execute(sql`
        UPDATE storage_usage_counters
           SET reserved_bytes = reserved_bytes + ${input.declaredBytes},
               updated_at = ${now.toISOString()}::timestamptz
         WHERE owner_user_id = ${input.ownerUserId}`);
      await refreshUploadCounter(tx, input.uploaderUserId, upload.windowHours, now);
      return { ok: true as const, reservationId: input.reservationId };
    });
  }

  async finalize(input: StorageFinalizeInput): Promise<StorageQuotaReservationResult> {
/**
 * Idempotent pre-0038/actual-byte reconciliation. Live reservations are the
 * authority for objects they cover; ready legacy attachments and active
 * legacy artifacts without a live reservation are backfilled from actual row
 * bytes. Failed/pending declarations never become used bytes. Immutable-share
 * copies are included through their finalized real charge, not a second ledger.
 * Caller must hold the owner user lock in this transaction.
 */
async function reconcileStorageUsageTx(tx: Tx, ownerUserId: string, now: Date): Promise<Row> {
  const found = await rows<Row>(tx, sql`
    INSERT INTO storage_usage_counters
      (owner_user_id, used_bytes, reserved_bytes, updated_at)
    SELECT
      ${ownerUserId},
      COALESCE((
        SELECT sum(r.actual_bytes) FROM storage_reservations r
         WHERE r.owner_user_id = ${ownerUserId} AND r.state = 'finalized'
      ), 0)
      + COALESCE((
        SELECT sum(a.actual_bytes) FROM attachments a
         WHERE a.user_id = ${ownerUserId}
           AND a.upload_status = 'ready' AND a.actual_bytes IS NOT NULL
           AND NOT EXISTS (
             SELECT 1 FROM storage_reservations r
              WHERE r.object_id = a.id AND r.state IN ('reserved', 'finalized')
           )
      ), 0)
      + COALESCE((
        SELECT sum(w.bytes) FROM workspace_objects w
         WHERE w.user_id = ${ownerUserId}
           AND w.kind = 'artifact' AND w.status = 'active'
           AND NOT EXISTS (
             SELECT 1 FROM storage_reservations r
              WHERE r.object_id = w.id AND r.state IN ('reserved', 'finalized')
           )
      ), 0),
      COALESCE((
        SELECT sum(r.declared_bytes) FROM storage_reservations r
         WHERE r.owner_user_id = ${ownerUserId} AND r.state = 'reserved'
      ), 0),
      ${now.toISOString()}::timestamptz
    ON CONFLICT (owner_user_id) DO UPDATE SET
      used_bytes = EXCLUDED.used_bytes,
      reserved_bytes = EXCLUDED.reserved_bytes,
      updated_at = EXCLUDED.updated_at
    RETURNING used_bytes, reserved_bytes`);
  return found[0]!;
}

/** Reconcile one owner before a public usage read or an external sweep. */
export async function reconcileStorageUsage(
  db: Db,
  ownerUserId: string,
  now = new Date(),
): Promise<{ usedBytes: number; reservedBytes: number }> {
  requiredId(ownerUserId, "ownerUserId");
  if (!Number.isFinite(now.getTime())) throw new RangeError("storage clock returned an invalid Date");
  return db.transaction(async (tx) => {
    await lockUsers(tx, [ownerUserId]);
    const counter = await reconcileStorageUsageTx(tx, ownerUserId, now);
    return {
      usedBytes: Number(counter.used_bytes),
      reservedBytes: Number(counter.reserved_bytes),
    };
  });
}

export interface AbandonedStorageReservation {
  reservationId: string;
  ownerUserId: string;
  sessionId: string;
  objectId: string | null;
}

/** Bounded stale-release batch; each row keeps its own transaction/idempotency. */
export async function sweepAbandonedStorageReservations(
  db: Db,
  input: { now?: Date; olderThanMs?: number; ownerUserId?: string; limit?: number } = {},
): Promise<AbandonedStorageReservation[]> {
  const now = input.now ?? new Date();
  const olderThanMs = input.olderThanMs ?? 3_600_000;
  const limit = input.limit ?? 100;
  if (!Number.isFinite(now.getTime()) || !Number.isSafeInteger(olderThanMs) || olderThanMs < 0) {
    throw new RangeError("invalid abandoned-reservation sweep clock/window");
  }
  if (!Number.isInteger(limit) || limit < 1 || limit > 1000) {
    throw new RangeError("abandoned-reservation sweep limit must be 1..1000");
  }
  const cutoff = new Date(now.getTime() - olderThanMs).toISOString();
  const owner = input.ownerUserId ?? null;
  const candidates = await db.$client<{
    id: string;
    owner_user_id: string;
    session_id: string;
    object_id: string | null;
  }[]>`
    SELECT id, owner_user_id, session_id, object_id FROM storage_reservations
     WHERE state = 'reserved' AND reserved_at < ${cutoff}::timestamptz
       AND (${owner}::text IS NULL OR owner_user_id = ${owner})
     ORDER BY reserved_at, id LIMIT ${limit}`;
  const store = new StorageReservationStore(db, { now: () => now });
  const released: AbandonedStorageReservation[] = [];
  for (const row of candidates) {
    try {
      await store.release({ reservationId: row.id });
    } catch (error) {
      // It finalized between candidate selection and its own transaction.
      // That is a live upload now, never an abandoned row to release/delete.
      if (error instanceof QuotaContractError && error.code === "reservation_finalized") continue;
      throw error;
    }
    released.push({
      reservationId: row.id,
      ownerUserId: row.owner_user_id,
      sessionId: row.session_id,
      objectId: row.object_id,
    });
  }
  return released;
}

    requiredId(input.reservationId, "reservationId");
    byteCount(input.actualBytes, "actualBytes");
    if (input.contentType !== null && input.contentType.trim().length === 0) {
      throw new RangeError("contentType must be non-empty or null");
    }
    return this.db.transaction(async (tx) => {
      const identity = await rows<Row>(tx, sql`
        SELECT actor_user_id, owner_user_id, session_id, object_id
          FROM storage_reservations WHERE id = ${input.reservationId} LIMIT 1`);
      if (identity[0] === undefined) throw new QuotaContractError("reservation_not_found");
      const tiers = await lockUsers(tx, [String(identity[0].owner_user_id), String(identity[0].actor_user_id)]);
      const found = await rows<Row>(tx, sql`
        SELECT * FROM storage_reservations WHERE id = ${input.reservationId} FOR UPDATE`);
      const reservation = found[0]!;
      if (reservation.state === "released") throw new QuotaContractError("reservation_released");
      -- Internal immutable-share charges/grants are not uploads. Real upload
      -- and artifact reservations use their canonical object id (or legacy
      -- NULL); only the explicit artifact-shares key namespace is excluded.
      AND (
        object_id IS NULL OR (
          object_id NOT LIKE 'charge:%'
          AND object_id NOT LIKE 'users/%/artifact-shares/%'
        )
      )
      if (reservation.state === "finalized") {
        const unchanged =
          Number(reservation.actual_bytes) === input.actualBytes &&
          sameModel(reservation.actual_content_type, input.contentType) &&
          sameModel(reservation.etag, input.etag);
        if (!unchanged) throw new QuotaContractError("idempotency_conflict");
        return { ok: true as const, reservationId: input.reservationId };
      }
      if (reservation.state !== "reserved") throw new QuotaContractError("invalid_reservation_state");

      const now = this.now();
      const ownerUserId = String(reservation.owner_user_id);
      const actorUserId = String(reservation.actor_user_id);
      const declared = Number(reservation.declared_bytes);
      const counter = await storageCounter(tx, ownerUserId);
      const storageCap = this.storagePlan(tiers.get(ownerUserId)!);
      const projected =
        Number(counter.used_bytes) + Number(counter.reserved_bytes) - declared + input.actualBytes;
      if (projected > storageCap) {
        return { ok: false as const, scope: "storage" as const, resetsAt: null };
      }
      await tx.execute(sql`
        UPDATE storage_usage_counters
           SET used_bytes = used_bytes + ${input.actualBytes},
               reserved_bytes = reserved_bytes - ${declared},
               updated_at = ${now.toISOString()}::timestamptz
         WHERE owner_user_id = ${ownerUserId}`);
      await tx.execute(sql`
        UPDATE storage_reservations
           SET state = 'finalized', actual_bytes = ${input.actualBytes},
               actual_content_type = ${input.contentType}, etag = ${input.etag},
               finalized_at = ${now.toISOString()}::timestamptz,
               updated_at = ${now.toISOString()}::timestamptz
         WHERE id = ${input.reservationId}`);
      const upload = this.uploadPlan(tiers.get(actorUserId)!);
      await refreshUploadCounter(tx, actorUserId, upload.windowHours, now);
      return { ok: true as const, reservationId: input.reservationId };
    });
  }

  async release(input: { reservationId: string }): Promise<void> {
    requiredId(input.reservationId, "reservationId");
    await this.db.transaction(async (tx) => {
      const identity = await rows<Row>(tx, sql`
        SELECT actor_user_id, owner_user_id, session_id, object_id
          FROM storage_reservations WHERE id = ${input.reservationId} LIMIT 1`);
      if (identity[0] === undefined) throw new QuotaContractError("reservation_not_found");
      const tiers = await lockUsers(tx, [String(identity[0].owner_user_id), String(identity[0].actor_user_id)]);
      const found = await rows<Row>(tx, sql`
        SELECT * FROM storage_reservations WHERE id = ${input.reservationId} FOR UPDATE`);
      const reservation = found[0]!;
      if (reservation.state === "released") return;
      if (reservation.state === "finalized") throw new QuotaContractError("reservation_finalized");
      if (reservation.state !== "reserved") throw new QuotaContractError("invalid_reservation_state");
      const now = this.now();
      const ownerUserId = String(reservation.owner_user_id);
      const actorUserId = String(reservation.actor_user_id);
      const declared = Number(reservation.declared_bytes);
      await storageCounter(tx, ownerUserId);
      await tx.execute(sql`
        UPDATE storage_usage_counters
           SET reserved_bytes = reserved_bytes - ${declared},
      if (input.attachment === true && input.head !== undefined) {
        const legacy = await reconcileLegacyAttachmentTx(tx, input, this.now());
        if (legacy.outcome === "failed") {
          // Return a committed refusal. Throwing here would roll back the
          // failed status/tombstone and reopen stale-HEAD recovery.
          return {
            ok: false as const,
            scope: "attachment" as const,
            code: "attachment_failed" as const,
            resetsAt: null,
          };
        }
        if (legacy.outcome === "preserved") {
          const now = this.now();
          const upload = this.uploadPlan(tiers.get(input.uploaderUserId)!);
          await refreshUploadCounter(tx, input.uploaderUserId, upload.windowHours, now);
          return { ok: true as const, reservationId: input.reservationId };
        }
      }
      await lockAttachmentForUploadTx(tx, input);
               updated_at = ${now.toISOString()}::timestamptz
         WHERE owner_user_id = ${ownerUserId}`);
      await tx.execute(sql`
        UPDATE storage_reservations
           SET state = 'released', released_at = ${now.toISOString()}::timestamptz,
               updated_at = ${now.toISOString()}::timestamptz
         WHERE id = ${input.reservationId}`);
      const upload = this.uploadPlan(tiers.get(actorUserId)!);
      await refreshUploadCounter(tx, actorUserId, upload.windowHours, now);
    });
  }
}
      await reconcileStorageUsageTx(tx, input.ownerUserId, now);
      const reservationIdentity = identity[0]!;
      await lockAttachmentForUploadTx(tx, {
        reservationId: input.reservationId,
        ownerUserId: String(reservationIdentity.owner_user_id),
        uploaderUserId: String(reservationIdentity.actor_user_id),
        sessionId: String(reservationIdentity.session_id),
        declaredBytes: 0,
        objectId: reservationIdentity.object_id === null
          ? null
          : String(reservationIdentity.object_id),
        attachment: input.attachment === true,
      }, { requirePresent: true });
      await this.options.afterAttachmentLock?.("finalize", input.reservationId);
      await reconcileStorageUsageTx(tx, ownerUserId, now);
      const reservationIdentity = identity[0]!;
      await lockAttachmentForUploadTx(tx, {
        reservationId: input.reservationId,
        ownerUserId: String(reservationIdentity.owner_user_id),
        uploaderUserId: String(reservationIdentity.actor_user_id),
        sessionId: String(reservationIdentity.session_id),
        declaredBytes: 0,
        objectId: reservationIdentity.object_id === null
          ? null
          : String(reservationIdentity.object_id),
        attachment: reservationIdentity.object_id === input.reservationId,
      }, { allowFailed: true });
      await this.options.afterAttachmentLock?.("release", input.reservationId);
      // Releasing a pending upload revokes its application-level finalize
      // capability. A presigned late PUT may still create an orphan, but the
      // failed row cannot finalize or mint a download. Replay also repairs
      // rows released by older code that incorrectly stayed pending.
      if (reservation.state !== "finalized" && reservation.object_id !== null) {
        await tx.execute(sql`
          UPDATE attachments
             SET upload_status = 'failed', actual_bytes = NULL,
                 actual_content_type = NULL, finalized_at = NULL
           WHERE id = ${reservation.object_id} AND upload_status = 'pending'`);
      }
