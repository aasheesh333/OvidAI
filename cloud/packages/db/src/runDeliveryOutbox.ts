import { and, asc, desc, eq, isNull, lt, or, sql } from "drizzle-orm";

import type { Db } from "./client.js";
import { newId } from "./repos.js";
import { runDeliveryOutbox, messages, runs, type RunDeliveryOutboxRow } from "./schema.js";

/**
 * Crash-safe final-response delivery ledger (migration 0042).
 *
 * The only durable identity is `run_id` (UNIQUE): a root run produces at most
 * one final answer, so a duplicate `record` is a replay, not a new delivery.
 * `message_id` is allocated inside the same transaction that inserts the
 * assistant row, so a committed outbox row always points at a committed
 * message and a rollback leaves neither behind.
 */

/** Longest error text retained on the row (the row is evidence, not a log). */
const MAX_ERROR_LENGTH = 500;

/**
 * Attempt-aware retry policy.
 *
 * A `pending` row is due only once its own backoff has elapsed:
 * `15s * 2^attempts`, capped at one hour. Without this, a completion push that
 * permanently reports `retry` (a broken FCM sender is `code:"error"`, not a
 * dead token, so `fanOut` reports `delivered=false`) would be retried on every
 * 15 s scheduler tick forever; 50 such rows would permanently occupy the
 * recovery batch head and starve every newer intent (a genuine crash-after-
 * commit would never be replayed and its run would be swept `run_lost`).
 *
 * `attempts` is capped so a permanently failing row stops re-fanning-out (one
 * `notifications` row per device per attempt) and stops consuming the batch.
 * The cap does NOT write `failed`: `failed` means "can never be delivered"
 * (missing message, run already terminalized), while a push failure can still
 * succeed later (credentials fixed, provider outage over). Such a row stays
 * `pending` — truthful: the delivery is unconfirmed — but is excluded from
 * automatic recovery and its `last_error` records that the budget is spent.
 * It can be replayed manually (reset `attempts`/`last_attempt_at`).
 */
export const RUN_DELIVERY_RETRY_BASE_MS = 15_000;
export const RUN_DELIVERY_RETRY_MAX_MS = 60 * 60_000;
/** 12 attempts ≈ 1 h 20 m of exponential backoff before the row is parked. */
export const RUN_DELIVERY_MAX_ATTEMPTS = 12;

/**
 * The backoff, evaluated by Postgres' own clock so two workers (and the
 * application clock) cannot disagree about due-ness. Mirrors
 * `RUN_DELIVERY_RETRY_BASE_MS * 2^attempts`, capped at the max.
 */
function retryCooldownSql() {
  return sql`make_interval(secs => LEAST(${RUN_DELIVERY_RETRY_BASE_MS / 1_000} * power(2, ${runDeliveryOutbox.attempts}), ${RUN_DELIVERY_RETRY_MAX_MS / 1_000}))`;
}

/** `last_attempt_at` is still inside the row's own backoff window. */
function pendingIsDueSql() {
  return sql`(${runDeliveryOutbox.lastAttemptAt} IS NULL OR ${runDeliveryOutbox.lastAttemptAt} < now() - ${retryCooldownSql()})`;
}

/** The automatic retry budget is spent: parked, not terminal. */
function withinAttemptBudgetSql() {
  return sql`${runDeliveryOutbox.attempts} < ${RUN_DELIVERY_MAX_ATTEMPTS}`;
}

/** A dead worker's lease is reclaimable; a live one is not. */
function leaseExpiredSql(leaseCutoff: Date) {
  return or(
    isNull(runDeliveryOutbox.lastAttemptAt),
    lt(runDeliveryOutbox.lastAttemptAt, leaseCutoff),
  );
}


function boundedError(error: unknown): string {
  const text = error instanceof Error ? error.message : String(error);
  return text.length > MAX_ERROR_LENGTH ? text.slice(0, MAX_ERROR_LENGTH) : text;
}

export interface RecordFinalResponseInput {
  runId: string;
  sessionId: string;
  userId: string;
  content: string;
  /** Exact `run_completed` payload, replayed verbatim by the outbox. */
  completionPayload: Record<string, unknown>;
  scheduled: boolean;
  now?: Date;
}

export const runDeliveryOutboxRepo = {
  /**
   * Durably record the final answer and the delivery intent in ONE
   * transaction. The assistant row and the outbox row either both commit or
   * neither does. Replaying the same run returns the existing row (and does
   * not append a second assistant message).
   *
   * The run row is locked FIRST: concurrent recorders for one run serialize,
   * so the check-then-insert cannot produce a second message row. The lock is
   * the run's own row (never a session/user lock), so it cannot deadlock with
   * the delivery's `runs.finish`.
   */
  async record(db: Db, input: RecordFinalResponseInput): Promise<RunDeliveryOutboxRow> {
    const now = input.now ?? new Date();
    return db.transaction(async (tx) => {
      const [run] = await tx
        .select({ id: runs.id })
        .from(runs)
        .where(eq(runs.id, input.runId))
        .limit(1)
        .for("update");
      if (run === undefined) {
        throw new Error(`run delivery outbox: unknown run ${input.runId}`);
      }

      const [existing] = await tx
        .select()
        .from(runDeliveryOutbox)
        .where(eq(runDeliveryOutbox.runId, input.runId))
        .limit(1);
      if (existing !== undefined) return existing;

      const messageId = newId();
      await tx.insert(messages).values({
        id: messageId,
        sessionId: input.sessionId,
        role: "assistant",
        content: input.content,
      });

      const [inserted] = await tx
        .insert(runDeliveryOutbox)
        .values({
          outboxId: newId(),
          runId: input.runId,
          sessionId: input.sessionId,
          userId: input.userId,
          messageId,
          scheduled: input.scheduled,
          completionPayload: input.completionPayload,
          status: "pending",
          createdAt: now,
          updatedAt: now,
        })
        .returning();
      if (inserted === undefined) {
        throw new Error("run delivery outbox: insert returned no row");
      }

      // Push the stale-run sweeper's clock forward: recovery gets a full
      // stale window to deliver even if this process dies immediately after
      // the commit (no `last_active_at` bump has happened since the last
      // model delta).
      await tx
        .update(runs)
        .set({ lastActiveAt: now })
        .where(eq(runs.id, input.runId));

      return inserted;
    });
  },

  async get(db: Db, runId: string): Promise<RunDeliveryOutboxRow | null> {
    const [row] = await db
      .select()
      .from(runDeliveryOutbox)
      .where(eq(runDeliveryOutbox.runId, runId))
      .limit(1);
    return row ?? null;
  },

  async getById(db: Db, outboxId: string): Promise<RunDeliveryOutboxRow | null> {
    const [row] = await db
      .select()
      .from(runDeliveryOutbox)
      .where(eq(runDeliveryOutbox.outboxId, outboxId))
      .limit(1);
    return row ?? null;
  },

  /**
   * Bounded recovery batch, least-recently-touched first.
   *
   * A `pending` row is due only when its own attempt-aware backoff has
   * elapsed (`last_attempt_at IS NULL OR last_attempt_at < now() -
   * LEAST(15s * 2^attempts, 1h)`) and its attempt budget is not spent; a
   * `delivering` row is due only once its lease has expired (the worker that
   * claimed it died). Terminal and parked rows are never returned.
   *
   * Ordering is `(last_attempt_at IS NULL) DESC, COALESCE(last_attempt_at,
   * created_at), created_at, outbox_id`: a never-attempted intent is always
   * ahead of a retried one (so a fresh crash-after-commit intent is reachable
   * even when a full batch of retries becomes due at once), and among retries
   * the one that has waited longest goes first.
   */
  async listDue(db: Db, limit: number, leaseCutoff: Date): Promise<RunDeliveryOutboxRow[]> {
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
      throw new RangeError("run delivery recovery limit must be an integer from 1 to 100");
    }
    return db
      .select()
      .from(runDeliveryOutbox)
      .where(
        or(
          and(
            eq(runDeliveryOutbox.status, "pending"),
            withinAttemptBudgetSql(),
            pendingIsDueSql(),
          ),
          and(eq(runDeliveryOutbox.status, "delivering"), leaseExpiredSql(leaseCutoff)),
        ),
      )
      .orderBy(
        desc(sql`(${runDeliveryOutbox.lastAttemptAt} IS NULL)`),
        asc(sql`coalesce(${runDeliveryOutbox.lastAttemptAt}, ${runDeliveryOutbox.createdAt})`),
        asc(runDeliveryOutbox.createdAt),
        asc(runDeliveryOutbox.outboxId),
      )
      .limit(limit);
  },

  /**
   * Single-writer claim. Returns the claimed row, or null when another worker
   * owns a live lease, the row already reached a terminal state, or the row is
   * not yet due (inside its backoff / out of attempts). This is the only place
   * `attempts` advances, and it applies the SAME due-ness predicate as
   * `listDue`: a caller that skips `listDue` cannot bypass the cooldown.
   */
  async claim(
    db: Db,
    outboxId: string,
    leaseCutoff: Date,
    now = new Date(),
  ): Promise<RunDeliveryOutboxRow | null> {
    const [row] = await db
      .update(runDeliveryOutbox)
      .set({
        status: "delivering",
        attempts: sql`${runDeliveryOutbox.attempts} + 1`,
        lastAttemptAt: now,
        updatedAt: now,
      })
      .where(
        and(
          eq(runDeliveryOutbox.outboxId, outboxId),
          or(
            and(
              eq(runDeliveryOutbox.status, "pending"),
              withinAttemptBudgetSql(),
              pendingIsDueSql(),
            ),
            and(eq(runDeliveryOutbox.status, "delivering"), leaseExpiredSql(leaseCutoff)),
          ),
        ),
      )
      .returning();
    return row ?? null;
  },

  /**
   * Retryable outcome: fenced by the in-flight attempt so a stale worker
   * cannot repend a row after another owner has already finished it.
   */
  async markPending(
    db: Db,
    outboxId: string,
    error: unknown,
    attempts: number,
    now = new Date(),
  ): Promise<void> {
    await db
      .update(runDeliveryOutbox)
      .set({
        status: "pending",
        lastError: boundedError(error),
        updatedAt: now,
      })
      .where(
        and(
          eq(runDeliveryOutbox.outboxId, outboxId),
          eq(runDeliveryOutbox.status, "delivering"),
          eq(runDeliveryOutbox.attempts, attempts),
        ),
      );
  },

  /** Truthful terminal verdict: this intent can never be delivered. */
  async markFailed(
    db: Db,
    outboxId: string,
    error: unknown,
    attempts: number,
    now = new Date(),
  ): Promise<void> {
    await db
      .update(runDeliveryOutbox)
      .set({
        status: "failed",
        lastError: boundedError(error),
        updatedAt: now,
      })
      .where(
        and(
          eq(runDeliveryOutbox.outboxId, outboxId),
          eq(runDeliveryOutbox.status, "delivering"),
          eq(runDeliveryOutbox.attempts, attempts),
        ),
      );
  },

  /** Only after message + events + notification are all confirmed. */
  async markDelivered(
    db: Db,
    outboxId: string,
    attempts: number,
    now = new Date(),
  ): Promise<void> {
    await db
      .update(runDeliveryOutbox)
      .set({
        status: "delivered",
        deliveredAt: now,
        lastError: null,
        updatedAt: now,
      })
      .where(
        and(
          eq(runDeliveryOutbox.outboxId, outboxId),
          eq(runDeliveryOutbox.status, "delivering"),
          eq(runDeliveryOutbox.attempts, attempts),
        ),
      );
  },
};
