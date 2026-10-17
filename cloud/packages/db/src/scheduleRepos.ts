import { and, asc, desc, eq, getTableColumns, inArray, isNotNull, isNull, lt, lte, ne, or, sql } from "drizzle-orm";
import type { ScheduleLastResult, ScheduleTrigger } from "@ovid/shared";
import type { Db } from "./client.js";
import { newId } from "./repos.js";
import {
  runs as runsTable,
  scheduleRuns as scheduleRunsTable,
  schedules as schedulesTable,
  type ScheduleRow,
  type ScheduleRunRow,
} from "./schema.js";

/**
 * P4 Task 4: scheduler persistence repos.
 *
 * Every mutating call is either a single conditional UPDATE … RETURNING (the
 * race guard) or an INSERT … ON CONFLICT DO NOTHING RETURNING (the claim
 * ledger). `schedule_runs` UNIQUE(schedule_id, scheduled_for) is the durable
 * idempotency key (spec §8): exactly one concurrent claimer inserts the
 * occurrence, everyone else gets null.
 */

/** The transaction handle drizzle hands to `db.transaction(cb)`. */
export type Tx = Parameters<Parameters<Db["transaction"]>[0]>[0];
/** Every method accepts a pool handle or an open transaction. */
export type DbOrTx = Db | Tx;

/**
 * Tx exposes the same query-builder surface as Db (both extend PgDatabase);
 * the only Db-only member is `$client`, which these repos never touch. The
 * cast keeps the public DbOrTx signature the plan pins without forcing every
 * call site to widen its own types.
 */
function q(db: DbOrTx): Db {
  return db as Db;
}

// Same opaque keyset cursor as sessions.list: "<updatedAt epoch ms>~<id>".
// Cursors are client-controlled, so decode degrades to "first page" instead of
// throwing on garbage (bounds mirror repos.ts).
const CURSOR_MS_MIN = -62_135_596_800_000; // 0001-01-01T00:00:00.000Z
const CURSOR_MS_MAX = 253_402_300_799_999; // 9999-12-31T23:59:59.999Z

function encodeScheduleCursor(row: ScheduleRow): string {
  return `${row.updatedAt.getTime()}~${row.id}`;
}

function decodeScheduleCursor(
  cursor: string | null | undefined,
): { updatedAt: Date; id: string } | null {
  if (!cursor) return null;
  const sep = cursor.indexOf("~");
  if (sep <= 0) return null;
  const ms = Number(cursor.slice(0, sep));
  const id = cursor.slice(sep + 1);
  if (
    !Number.isSafeInteger(ms) ||
    ms < CURSOR_MS_MIN ||
    ms > CURSOR_MS_MAX ||
    id.length === 0
  ) {
    return null;
  }
  return { updatedAt: new Date(ms), id };
}

export const schedules = {
  async create(
    db: Db,
    input: {
      userId: string;
      sessionId: string;
      title: string;
      description: string;
      trigger: ScheduleTrigger;
      autonomy: string;
      maxRetries: number;
      nextRunAt: Date | null;
    },
  ): Promise<ScheduleRow> {
    const [row] = await db
      .insert(schedulesTable)
      .values({
        id: newId(),
        userId: input.userId,
        sessionId: input.sessionId,
        title: input.title,
        description: input.description,
        trigger: input.trigger,
        // The caller (scheduleService) validates the enum; this layer stores
        // what it is given (same discipline as sessions.update's mode).
        autonomy: input.autonomy as ScheduleRow["autonomy"],
        maxRetries: input.maxRetries,
        nextRunAt: input.nextRunAt,
      })
      .returning();
    return row!;
  },

  /** Ownership-scoped fetch: null on unknown id OR wrong owner (404, no leak). */
  async get(db: DbOrTx, scheduleId: string, userId: string): Promise<ScheduleRow | null> {
    const [row] = await q(db)
      .select()
      .from(schedulesTable)
      .where(and(eq(schedulesTable.id, scheduleId), eq(schedulesTable.userId, userId)))
      .limit(1);
    return row ?? null;
  },

  /** Internal fetch (worker): NOT owner-scoped — the scheduler owns the id. */
  async getById(db: DbOrTx, scheduleId: string): Promise<ScheduleRow | null> {
    const [row] = await q(db)
      .select()
      .from(schedulesTable)
      .where(eq(schedulesTable.id, scheduleId))
      .limit(1);
    return row ?? null;
  },

  /**
   * Most recently updated first; keyset over (updatedAt, id) — the exact
   * cursor format sessions.list uses. Cancelled rows are hidden unless
   * `includeCancelled` (the gateway list's default view).
   */
  async list(
    db: Db,
    userId: string,
    opts: { limit: number; cursor?: string | null; includeCancelled?: boolean },
  ): Promise<{ rows: ScheduleRow[]; nextCursor: string | null }> {
    const key = decodeScheduleCursor(opts.cursor);
    const filters = [eq(schedulesTable.userId, userId)];
    if (!opts.includeCancelled) filters.push(ne(schedulesTable.status, "cancelled"));
    if (key) {
      filters.push(
        or(
          lt(schedulesTable.updatedAt, key.updatedAt),
          and(eq(schedulesTable.updatedAt, key.updatedAt), lt(schedulesTable.id, key.id)),
        )!,
      );
    }
    const found = await db
      .select()
      .from(schedulesTable)
      .where(and(...filters))
      .orderBy(desc(schedulesTable.updatedAt), desc(schedulesTable.id))
      .limit(opts.limit + 1);
    const hasMore = found.length > opts.limit;
    const rows = hasMore ? found.slice(0, opts.limit) : found;
    const last = rows[rows.length - 1];
    return { rows, nextCursor: hasMore && last ? encodeScheduleCursor(last) : null };
  },

  /** Boot mirror resync: every pending schedule that still has a fire time. */
  async listPendingWithNextRun(db: Db): Promise<ScheduleRow[]> {
    return db
      .select()
      .from(schedulesTable)
      .where(and(eq(schedulesTable.status, "pending"), isNotNull(schedulesTable.nextRunAt)))
      .orderBy(asc(schedulesTable.nextRunAt));
  },

  /**
   * Due scan for the scheduler tick — the plan's pinned SQL, expressed with
   * the builder (semantics fixed, not syntax):
   *
   *   status='pending' AND (next_run_at <= now
   *     OR id IN (SELECT schedule_id FROM schedule_runs
   *               WHERE status='retry_scheduled' AND retry_at <= now))
   *   ORDER BY next_run_at ASC NULLS LAST LIMIT n FOR UPDATE SKIP LOCKED
   *
   * The retry arm is what lets a one-off (next_run_at NULL) retry fire. SKIP
   * LOCKED makes overlapping ticks partition the due set instead of blocking.
   * Callers MUST run this inside a transaction for the lock to mean anything.
   */
  async claimDue(db: DbOrTx, now: Date, limit: number): Promise<ScheduleRow[]> {
    const retryDue = q(db)
      .select({ scheduleId: scheduleRunsTable.scheduleId })
      .from(scheduleRunsTable)
      .where(
        and(
          eq(scheduleRunsTable.status, "retry_scheduled"),
          lte(scheduleRunsTable.retryAt, now),
        ),
      );
    return q(db)
      .select()
      .from(schedulesTable)
      .where(
        and(
          eq(schedulesTable.status, "pending"),
          or(lte(schedulesTable.nextRunAt, now), inArray(schedulesTable.id, retryDue)),
        ),
      )
      .orderBy(asc(schedulesTable.nextRunAt))
      .limit(limit)
      .for("update", { skipLocked: true });
  },

  /**
   * Partial update; bumps updatedAt in the same statement. null = row gone.
   * Keys set to undefined are left untouched (a null IS written).
   */
  async update(
    db: DbOrTx,
    scheduleId: string,
    patch: Partial<{
      title: string;
      description: string;
      trigger: ScheduleTrigger;
      autonomy: string;
      maxRetries: number;
      sessionId: string;
      status: string;
      pausedReason: string | null;
      nextRunAt: Date | null;
      lastResult: ScheduleLastResult | null;
    }>,
  ): Promise<ScheduleRow | null> {
    const set: Partial<typeof schedulesTable.$inferInsert> = { updatedAt: new Date() };
    if (patch.title !== undefined) set.title = patch.title;
    if (patch.description !== undefined) set.description = patch.description;
    if (patch.trigger !== undefined) set.trigger = patch.trigger;
    if (patch.autonomy !== undefined) set.autonomy = patch.autonomy as ScheduleRow["autonomy"];
    if (patch.maxRetries !== undefined) set.maxRetries = patch.maxRetries;
    if (patch.sessionId !== undefined) set.sessionId = patch.sessionId;
    if (patch.status !== undefined) set.status = patch.status as ScheduleRow["status"];
    if (patch.pausedReason !== undefined) set.pausedReason = patch.pausedReason;
    if (patch.nextRunAt !== undefined) set.nextRunAt = patch.nextRunAt;
    if (patch.lastResult !== undefined) set.lastResult = patch.lastResult;

    const [row] = await q(db)
      .update(schedulesTable)
      .set(set)
      .where(eq(schedulesTable.id, scheduleId))
      .returning();
    return row ?? null;
  },

  /**
   * Settle's schedule-level transition, CONDITIONAL on the schedule still
   * being `pending` (final review M2). A user cancel or pause between fire
   * and settle wins: the occurrence's `lastResult` is still recorded by the
   * caller, but the schedule is never resurrected into `completed`/`failed`
   * (or re-paused with a different reason) over that intent. Returns whether
   * the transition applied.
   */
  async transitionFromPending(
    db: DbOrTx,
    scheduleId: string,
    to: {
      status: "completed" | "failed" | "paused";
      pausedReason?: string;
      clearNextRunAt?: boolean;
    },
  ): Promise<boolean> {
    const [row] = await q(db)
      .update(schedulesTable)
      .set({
        status: to.status,
        ...(to.pausedReason !== undefined ? { pausedReason: to.pausedReason } : {}),
        ...(to.clearNextRunAt === true ? { nextRunAt: null } : {}),
        updatedAt: new Date(),
      })
      .where(
        and(eq(schedulesTable.id, scheduleId), eq(schedulesTable.status, "pending")),
      )
      .returning({ id: schedulesTable.id });
    return row !== undefined;
  },
};

/**
 * One settleable occurrence plus the run/schedule context settle needs.
 * `schedule*` fields come from the joined schedule; `runStatus`/`runError`
 * are null for a lost-enqueue orphan (run_id null or the run row missing).
 *
 * The occurrence's OWN `sessionId`/`triggerKind` are the pinned columns on
 * schedule_runs (final review M1) — settle must use those, never the live
 * schedule row, for transcript/summary/push routing and the one-off decision.
 */
export interface SettleableRunRow extends ScheduleRunRow {
  runStatus: string | null;
  runError: string | null;
  scheduleStatus: string;
  scheduleTitle: string;
  scheduleUserId: string;
  scheduleMaxRetries: number;
}

export const scheduleRuns = {
  /**
   * Claim an occurrence: INSERT … ON CONFLICT (schedule_id, scheduled_for)
   * DO NOTHING RETURNING. The first caller wins; null = another claimer owns
   * this occurrence (the ledger race).
   *
   * `sessionId`/`triggerKind` are REQUIRED: the caller pins the routing
   * context the occurrence executes with (final review M1), so a later
   * session rebind cannot misroute settle's reporting.
   */
  async claim(
    db: DbOrTx,
    input: {
      scheduleId: string;
      scheduledFor: Date;
      runId: string;
      ranLate: boolean;
      sessionId: string;
      triggerKind: ScheduleTrigger["kind"];
    },
  ): Promise<ScheduleRunRow | null> {
    const [row] = await q(db)
      .insert(scheduleRunsTable)
      .values({
        id: newId(),
        scheduleId: input.scheduleId,
        scheduledFor: input.scheduledFor,
        sessionId: input.sessionId,
        triggerKind: input.triggerKind,
        runId: input.runId,
        status: "running",
        ranLate: input.ranLate,
        startedAt: new Date(),
      })
      .onConflictDoNothing({
        target: [scheduleRunsTable.scheduleId, scheduleRunsTable.scheduledFor],
      })
      .returning();
    return row ?? null;
  },

  /** Record a skipped (missed-beyond-policy) occurrence under the same ledger. */
  async recordSkip(
    db: DbOrTx,
    input: {
      scheduleId: string;
      scheduledFor: Date;
      sessionId: string;
      triggerKind: ScheduleTrigger["kind"];
    },
  ): Promise<ScheduleRunRow | null> {
    const [row] = await q(db)
      .insert(scheduleRunsTable)
      .values({
        id: newId(),
        scheduleId: input.scheduleId,
        scheduledFor: input.scheduledFor,
        sessionId: input.sessionId,
        triggerKind: input.triggerKind,
        status: "skipped",
      })
      .onConflictDoNothing({
        target: [scheduleRunsTable.scheduleId, scheduleRunsTable.scheduledFor],
      })
      .returning();
    return row ?? null;
  },

  /** Oldest retry that is due for this schedule, or null. */
  async claimRetryDue(
    db: DbOrTx,
    scheduleId: string,
    now: Date,
  ): Promise<ScheduleRunRow | null> {
    const [row] = await q(db)
      .select()
      .from(scheduleRunsTable)
      .where(
        and(
          eq(scheduleRunsTable.scheduleId, scheduleId),
          eq(scheduleRunsTable.status, "retry_scheduled"),
          lte(scheduleRunsTable.retryAt, now),
        ),
      )
      .orderBy(asc(scheduleRunsTable.retryAt), asc(scheduleRunsTable.id))
      .limit(1);
    return row ?? null;
  },

  /**
   * Atomically turn a due retry into the running occurrence bound to the new
   * run. Conditional on status='retry_scheduled' — null = lost the race.
   *
   * `context` re-pins the occurrence's routing context for the retry run: the
   * retry is a NEW run created against the schedule's current binding, so the
   * occurrence must follow it (final review M1). Omitted = keep the pin.
   */
  async claimRetry(
    db: DbOrTx,
    scheduleRunId: string,
    runId: string,
    context?: { sessionId: string; triggerKind: ScheduleTrigger["kind"] },
  ): Promise<ScheduleRunRow | null> {
    const [row] = await q(db)
      .update(scheduleRunsTable)
      .set({
        status: "running",
        runId,
        startedAt: new Date(),
        retryAt: null,
        ...(context !== undefined
          ? { sessionId: context.sessionId, triggerKind: context.triggerKind }
          : {}),
      })
      .where(
        and(
          eq(scheduleRunsTable.id, scheduleRunId),
          eq(scheduleRunsTable.status, "retry_scheduled"),
        ),
      )
      .returning();
    return row ?? null;
  },

  /**
   * Arm a retry: attempt+1 and the next retry instant. Conditional on
   * status='running' so two overlapping settle passes cannot double-bump
   * (the loser's UPDATE matches zero rows).
   */
  async scheduleRetry(db: DbOrTx, scheduleRunId: string, retryAt: Date): Promise<void> {
    await q(db)
      .update(scheduleRunsTable)
      .set({
        status: "retry_scheduled",
        attempt: sql`${scheduleRunsTable.attempt} + 1`,
        retryAt,
      })
      .where(
        and(eq(scheduleRunsTable.id, scheduleRunId), eq(scheduleRunsTable.status, "running")),
      );
  },

  /**
   * Terminal transition. Conditional on status='running' (settle idempotence);
   * a second call is a silent no-op.
   */
  async finish(
    db: DbOrTx,
    scheduleRunId: string,
    status: "succeeded" | "failed",
    error?: string | null,
  ): Promise<void> {
    await q(db)
      .update(scheduleRunsTable)
      .set({
        status,
        finishedAt: new Date(),
        ...(error !== undefined ? { error } : {}),
      })
      .where(
        and(eq(scheduleRunsTable.id, scheduleRunId), eq(scheduleRunsTable.status, "running")),
      );
  },

  async getByRunId(db: DbOrTx, runId: string): Promise<ScheduleRunRow | null> {
    const [row] = await q(db)
      .select()
      .from(scheduleRunsTable)
      .where(eq(scheduleRunsTable.runId, runId))
      .limit(1);
    return row ?? null;
  },

  /** Append one auto-denied approval entry (jsonb `||` keeps it atomic). */
  async appendAutoDenied(
    db: DbOrTx,
    scheduleRunId: string,
    entry: { toolName: string; summary: string; ts: string },
  ): Promise<void> {
    await q(db)
      .update(scheduleRunsTable)
      .set({
        autoDenied: sql`${scheduleRunsTable.autoDenied} || ${JSON.stringify(entry)}::jsonb`,
      })
      .where(eq(scheduleRunsTable.id, scheduleRunId));
  },

  /**
   * The settle reconciler's scan — the plan's pinned SQL, expressed with the
   * builder:
   *
   *   sr.status='running' AND (
   *     r.status IN ('completed','failed','cancelled')
   *     OR (sr.started_at < staleBefore
   *         AND (sr.run_id IS NULL OR r.id IS NULL OR r.status='queued')))
   *   ORDER BY sr.started_at ASC LIMIT n
   *
   * A `running` run is never settleable (it is genuinely alive); a queued or
   * missing run past the stale window is the lost-enqueue recovery path.
   */
  async listSettleable(
    db: DbOrTx,
    opts: { staleBefore: Date; limit: number },
  ): Promise<SettleableRunRow[]> {
    return q(db)
      .select({
        ...getTableColumns(scheduleRunsTable),
        runStatus: runsTable.status,
        runError: runsTable.lastError,
        scheduleStatus: schedulesTable.status,
        scheduleTitle: schedulesTable.title,
        scheduleUserId: schedulesTable.userId,
        scheduleMaxRetries: schedulesTable.maxRetries,
      })
      .from(scheduleRunsTable)
      .innerJoin(schedulesTable, eq(schedulesTable.id, scheduleRunsTable.scheduleId))
      .leftJoin(runsTable, eq(runsTable.id, scheduleRunsTable.runId))
      .where(
        and(
          eq(scheduleRunsTable.status, "running"),
          or(
            inArray(runsTable.status, ["completed", "failed", "cancelled"]),
            and(
              lt(scheduleRunsTable.startedAt, opts.staleBefore),
              or(
                isNull(scheduleRunsTable.runId),
                isNull(runsTable.id),
                eq(runsTable.status, "queued"),
              ),
            ),
          ),
        ),
      )
      .orderBy(asc(scheduleRunsTable.startedAt))
      .limit(opts.limit);
  },

  /**
   * Newest-first occurrence page for the schedule detail route. Cursor is the
   * last id (messages.page pattern; UUIDv7 ids are time-ordered).
   */
  async listForSchedule(
    db: Db,
    scheduleId: string,
    opts: { limit: number; beforeId?: string | null },
  ): Promise<{ rows: ScheduleRunRow[]; nextCursor: string | null }> {
    const where = opts.beforeId
      ? and(eq(scheduleRunsTable.scheduleId, scheduleId), lt(scheduleRunsTable.id, opts.beforeId))
      : eq(scheduleRunsTable.scheduleId, scheduleId);
    const found = await db
      .select()
      .from(scheduleRunsTable)
      .where(where)
      .orderBy(desc(scheduleRunsTable.id))
      .limit(opts.limit + 1);
    const hasMore = found.length > opts.limit;
    const rows = hasMore ? found.slice(0, opts.limit) : found;
    const last = rows[rows.length - 1];
    return { rows, nextCursor: hasMore && last ? last.id : null };
  },
};
