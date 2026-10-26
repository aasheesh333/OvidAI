import {
  ONE_OFF_GRACE_MS,
  nextFireAfter,
  schedulePrompt,
  type ScheduleAutonomy,
  type ScheduleTrigger,
  type ScheduleUpdate,
} from "@ovid/shared";
import type { Db } from "./client.js";
import { messages, runs, sessions, users } from "./repos.js";
import { scheduleRuns, schedules } from "./scheduleRepos.js";
import { admitTurn } from "./turnOrdering.js";
import type { ScheduleRow, ScheduleRunRow } from "./schema.js";

/**
 * P4 Task 5: schedule domain service — the single choke point both the REST
 * routes (Task 11) and the agent tools (Task 13) call. It owns the rules that
 * must never diverge between the two surfaces:
 *
 *   - the cron tier gate (Free → 403 tier_required),
 *   - dedicated-session materialization (a schedule always has a session),
 *   - ownership checks (wrong owner and unknown id are both not_found),
 *   - next-fire computation and the one-off grace window,
 *   - the pause/resume state machine (Dart `resumeStopped` parity).
 *
 * Every operation takes an injectable `clock` so tests (and the scheduler's
 * fake clock) are exact; production callers omit it.
 */

export class ScheduleError extends Error {
  /** `busy` (Wave 5 run-now): the schedule's chat already has an active run. */
  readonly code: "not_found" | "tier_required" | "invalid_trigger" | "bad_request" | "busy";

  constructor(code: ScheduleError["code"], message: string) {
    super(message);
    this.name = "ScheduleError";
    this.code = code;
  }
}

const MAX_RETRIES = 3;

function now(clock: (() => Date) | undefined): Date {
  return (clock ?? (() => new Date()))();
}

/** Callers normally validate through zod; the service re-checks because the
 *  agent-tool path and direct callers must not bypass the invariant. */
function validateMaxRetries(maxRetries: number | undefined): void {
  if (maxRetries === undefined) return;
  if (!Number.isInteger(maxRetries) || maxRetries < 0 || maxRetries > MAX_RETRIES) {
    throw new ScheduleError(
      "bad_request",
      `maxRetries must be an integer between 0 and ${MAX_RETRIES}.`,
    );
  }
}

/** Cron is the one trigger gated by plan (Review Focus 4). A missing user row
 *  is Free by construction (`users.ensure` creates it with the column default). */
async function assertCronTier(db: Db, userId: string, trigger: ScheduleTrigger): Promise<void> {
  if (trigger.kind !== "cron") return;
  const user = await users.ensure(db, userId, null);
  if (user.tier === "free") {
    throw new ScheduleError("tier_required", "Cron schedules require Ovid Pro.");
  }
}

/**
 * First fire time at creation: one-offs keep their instant (a past one within
 * the 24 h grace is ALLOWED — the first tick fires it `ranLate` per the missed
 * run policy); recurring triggers ask the trigger engine.
 */
function initialNextRunAt(trigger: ScheduleTrigger, from: Date): Date {
  if (trigger.kind === "at") {
    const at = new Date(trigger.at);
    if (Number.isNaN(at.getTime())) {
      throw new ScheduleError("invalid_trigger", "at must be a valid ISO-8601 instant.");
    }
    if (at.getTime() <= from.getTime() - ONE_OFF_GRACE_MS) {
      throw new ScheduleError("invalid_trigger", "at is more than 24 h in the past.");
    }
    return at;
  }
  const next = nextFireAfter(trigger, from);
  if (next === null) {
    throw new ScheduleError("invalid_trigger", "Trigger does not produce a future occurrence.");
  }
  return next;
}

/**
 * Resume semantics (Dart `resumeStopped`): recurring triggers move to their
 * next slot; a one-off in the future keeps its instant; a missed one-off runs
 * on the next tick (`nextRunAt = now`).
 */
function resumeNextRunAt(trigger: ScheduleTrigger, from: Date): Date {
  if (trigger.kind !== "at") {
    const next = nextFireAfter(trigger, from);
    if (next === null) {
      throw new ScheduleError("invalid_trigger", "Trigger does not produce a future occurrence.");
    }
    return next;
  }
  const at = new Date(trigger.at);
  if (Number.isNaN(at.getTime())) {
    throw new ScheduleError("invalid_trigger", "at must be a valid ISO-8601 instant.");
  }
  return at.getTime() > from.getTime() ? at : from;
}

export interface CreateScheduleArgs {
  userId: string;
  title: string;
  description: string;
  trigger: ScheduleTrigger;
  autonomy?: ScheduleAutonomy;
  maxRetries?: number;
  sessionId?: string | null;
  clock?: () => Date;
}

/**
 * Create a schedule. `users.ensure` provisions the row idempotently (a null
 * email never clobbers a stored one, and tier is never touched). An omitted
 * `sessionId` materializes a DEDICATED session titled after the schedule; a
 * supplied one is ownership-checked (wrong owner == unknown == not_found).
 */
export async function createSchedule(db: Db, args: CreateScheduleArgs): Promise<ScheduleRow> {
  validateMaxRetries(args.maxRetries);
  await assertCronTier(db, args.userId, args.trigger);

  const at = now(args.clock);
  const nextRunAt = initialNextRunAt(args.trigger, at);

  let sessionId: string;
  if (args.sessionId != null) {
    const session = await sessions.get(db, args.sessionId, args.userId);
    if (!session) throw new ScheduleError("not_found", "Session not found.");
    sessionId = session.id;
  } else {
    const session = await sessions.create(db, args.userId, args.title);
    sessionId = session.id;
  }

  return schedules.create(db, {
    userId: args.userId,
    sessionId,
    title: args.title,
    description: args.description,
    trigger: args.trigger,
    autonomy: args.autonomy ?? "safe",
    maxRetries: args.maxRetries ?? 0,
    nextRunAt,
  });
}

/** Key-order-insensitive structural equality for trigger JSON. */
function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (value !== null && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      const v = (value as Record<string, unknown>)[key];
      if (v !== undefined) out[key] = canonical(v);
    }
    return out;
  }
  return value;
}

export function sameTrigger(a: ScheduleTrigger, b: ScheduleTrigger): boolean {
  return JSON.stringify(canonical(a)) === JSON.stringify(canonical(b));
}

export interface UpdateScheduleArgs {
  userId: string;
  scheduleId: string;
  patch: ScheduleUpdate;
  clock?: () => Date;
}

type ScheduleUpdateFields = Parameters<typeof schedules.update>[2];

/**
 * Patch a schedule. Cancelled and completed rows are not editable; a FAILED
 * row is (Wave 5 FE-013: the user reviews, edits, then resumes it). Pausing
 * keeps `nextRunAt` (informational — `claimDue` filters on
 * `status='pending'`); resuming (from paused OR failed) recomputes it. A
 * trigger CHANGE on a pending schedule recomputes the next fire from now; a
 * patch that repeats the stored trigger is not a change (FE-017: renaming an
 * hourly task must not push its next run out). A change to cron re-checks
 * tier.
 */
export async function updateSchedule(db: Db, args: UpdateScheduleArgs): Promise<ScheduleRow> {
  const { userId, scheduleId, patch } = args;

  const existing = await schedules.get(db, scheduleId, userId);
  if (!existing) throw new ScheduleError("not_found", "Schedule not found.");
  if (existing.status === "cancelled" || existing.status === "completed") {
    throw new ScheduleError("bad_request", "Schedule is not editable.");
  }
  if (Object.keys(patch).length === 0) {
    throw new ScheduleError("bad_request", "At least one field must be provided.");
  }
  validateMaxRetries(patch.maxRetries);
  // FE-017: an unchanged trigger is not a trigger change.
  const triggerChanged =
    patch.trigger !== undefined && !sameTrigger(patch.trigger, existing.trigger);
  if (triggerChanged) {
    await assertCronTier(db, userId, patch.trigger!);
  }
  if (patch.sessionId !== undefined) {
    const session = await sessions.get(db, patch.sessionId, userId);
    if (!session) throw new ScheduleError("not_found", "Session not found.");
  }
  // Resume is meaningful from paused (Dart resumeStopped) and, after
  // review, from failed (FE-013).
  if (patch.status === "pending" && existing.status !== "paused" && existing.status !== "failed") {
    throw new ScheduleError("bad_request", "Only a paused or failed schedule can be resumed.");
  }
  if (patch.status === "paused" && existing.status !== "pending" && existing.status !== "paused") {
    throw new ScheduleError("bad_request", "Only an active schedule can be paused.");
  }

  const at = now(args.clock);
  const trigger = patch.trigger ?? existing.trigger;
  const set: ScheduleUpdateFields = {};

  if (patch.title !== undefined) set.title = patch.title;
  if (patch.description !== undefined) set.description = patch.description;
  if (triggerChanged) set.trigger = patch.trigger;
  if (patch.autonomy !== undefined) set.autonomy = patch.autonomy;
  if (patch.maxRetries !== undefined) set.maxRetries = patch.maxRetries;
  if (patch.sessionId !== undefined) set.sessionId = patch.sessionId;

  if (patch.status === "paused") {
    set.status = "paused";
    set.pausedReason = "user";
    // nextRunAt intentionally kept: paused rows never pass claimDue.
  } else if (patch.status === "pending") {
    set.status = "pending";
    set.pausedReason = null;
    set.nextRunAt = resumeNextRunAt(trigger, at);
  } else if (triggerChanged && existing.status === "pending") {
    set.nextRunAt = initialNextRunAt(trigger, at);
  }

  if (Object.keys(set).length === 0) return existing; // a no-op patch

  const updated = await schedules.update(db, scheduleId, set);
  if (!updated) throw new ScheduleError("not_found", "Schedule not found.");
  return updated;
}

/**
 * Soft delete. Owner-scoped (wrong owner == not_found) and idempotent: an
 * already-cancelled schedule is a no-op, never an error.
 */
export async function cancelSchedule(
  db: Db,
  args: { userId: string; scheduleId: string },
): Promise<void> {
  const existing = await schedules.get(db, args.scheduleId, args.userId);
  if (!existing) throw new ScheduleError("not_found", "Schedule not found.");
  if (existing.status === "cancelled") return;

  const updated = await schedules.update(db, args.scheduleId, {
    status: "cancelled",
    pausedReason: null,
  });
  if (!updated) throw new ScheduleError("not_found", "Schedule not found.");
}

export interface RunScheduleNowResult {
  schedule: ScheduleRow;
  runId: string;
  scheduleRun: ScheduleRunRow;
  /** The transcript prompt the run executes (the caller enqueues it). */
  prompt: string;
}

/**
 * Wave 5 FE-012 "Run now": claim ONE immediate occurrence of a schedule —
 * the same message + run + ledger rows the scheduler tick writes for a due
 * occurrence (scheduledFor = now, never late) — WITHOUT touching the
 * schedule's own `nextRunAt` or status. The caller enqueues the run after
 * this commits (and publishes `schedule_run_started`); the settle reconciler
 * then closes the occurrence like any other (an unenqueued run is recovered
 * by its stale arm).
 *
 * Runnable: pending, paused and failed (a test run during review).
 * Cancelled/completed → bad_request; another active run in the chat → busy;
 * wrong owner or unknown id → not_found.
 */
export async function runScheduleNow(
  db: Db,
  args: { userId: string; scheduleId: string; clock?: () => Date },
): Promise<RunScheduleNowResult> {
  const at = now(args.clock);
  return db.transaction(async (tx) => {
    const tdb = tx as unknown as Db;
    const row = await schedules.get(tdb, args.scheduleId, args.userId);
    if (!row) throw new ScheduleError("not_found", "Schedule not found.");
    if (row.status === "cancelled" || row.status === "completed") {
      throw new ScheduleError("bad_request", "This schedule can no longer run.");
    }
    if ((await runs.activeForSession(tdb, row.sessionId)) !== null) {
      throw new ScheduleError("busy", "This schedule's chat is already running a task.");
    }
    const prompt = schedulePrompt(row.title, row.description);
    const message = await messages.append(tdb, {
      sessionId: row.sessionId,
      role: "user",
      content: prompt,
    });
    // Admit through the turn-ordering primitive, not `runs.create`. This
    // takes the session advisory lock and stamps
    // `created_at = GREATEST(clock_timestamp(), session max + 1µs)`, so the
    // immediate run participates in the same admission order as every other
    // turn. `defaultNow()` (transaction-start time) could otherwise place
    // this run before a turn admitted while the transaction was open, which
    // makes `seq` disagree with admission order and drops a legitimate run
    // as `newer_turn_running`.
    const run = await admitTurn(tdb, { sessionId: row.sessionId, promptMessageId: message.id });
    const scheduleRun = await scheduleRuns.claim(tdb, {
      scheduleId: row.id,
      scheduledFor: at,
      runId: run.runId,
      ranLate: false,
      sessionId: row.sessionId,
      triggerKind: row.trigger.kind,
    });
    if (scheduleRun === null) {
      // The tick ledgered this exact instant a moment ago: the run it fired
      // is the "run now" the user asked for.
      throw new ScheduleError("busy", "This schedule is starting a run right now.");
    }
    return { schedule: row, runId: run.runId, scheduleRun, prompt };
  });
}
