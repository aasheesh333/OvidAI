import {
  ONE_OFF_GRACE_MS,
  nextFireAfter,
  type ScheduleAutonomy,
  type ScheduleTrigger,
  type ScheduleUpdate,
} from "@ovid/shared";
import type { Db } from "./client.js";
import { sessions, users } from "./repos.js";
import { schedules } from "./scheduleRepos.js";
import type { ScheduleRow } from "./schema.js";

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
  readonly code: "not_found" | "tier_required" | "invalid_trigger" | "bad_request";

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

export interface UpdateScheduleArgs {
  userId: string;
  scheduleId: string;
  patch: ScheduleUpdate;
  clock?: () => Date;
}

type ScheduleUpdateFields = Parameters<typeof schedules.update>[2];

/**
 * Patch a schedule. Terminal rows (cancelled/completed/failed) are not
 * editable. Pausing keeps `nextRunAt` (informational — `claimDue` filters on
 * `status='pending'`); resuming recomputes it. A trigger change on a pending
 * schedule recomputes the next fire from now; a change to cron re-checks tier.
 */
export async function updateSchedule(db: Db, args: UpdateScheduleArgs): Promise<ScheduleRow> {
  const { userId, scheduleId, patch } = args;

  const existing = await schedules.get(db, scheduleId, userId);
  if (!existing) throw new ScheduleError("not_found", "Schedule not found.");
  if (
    existing.status === "cancelled" ||
    existing.status === "completed" ||
    existing.status === "failed"
  ) {
    throw new ScheduleError("bad_request", "Schedule is not editable.");
  }
  if (Object.keys(patch).length === 0) {
    throw new ScheduleError("bad_request", "At least one field must be provided.");
  }
  validateMaxRetries(patch.maxRetries);
  if (patch.trigger !== undefined) {
    await assertCronTier(db, userId, patch.trigger);
  }
  if (patch.sessionId !== undefined) {
    const session = await sessions.get(db, patch.sessionId, userId);
    if (!session) throw new ScheduleError("not_found", "Session not found.");
  }
  // Resume is only meaningful from paused (Dart resumeStopped).
  if (patch.status === "pending" && existing.status !== "paused") {
    throw new ScheduleError("bad_request", "Only a paused schedule can be resumed.");
  }

  const at = now(args.clock);
  const trigger = patch.trigger ?? existing.trigger;
  const set: ScheduleUpdateFields = {};

  if (patch.title !== undefined) set.title = patch.title;
  if (patch.description !== undefined) set.description = patch.description;
  if (patch.trigger !== undefined) set.trigger = patch.trigger;
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
  } else if (patch.trigger !== undefined && existing.status === "pending") {
    set.nextRunAt = initialNextRunAt(trigger, at);
  }

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
