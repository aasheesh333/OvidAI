import { DateTime, Info } from "luxon";
import { z } from "zod";
// cron-parser 4.9.0 ships an ESM-shaped .d.ts (named exports) over a CJS
// build whose `module.exports` is a function object, so Node's CJS-ESM
// interop only exposes it as the default export. Resolve both shapes once
// at module load; either way `parseExpression` is the same v4 API the plan
// pins (`parseExpression(expr, { tz, currentDate }).next().toDate()`).
import * as cronParserModule from "cron-parser";

const cronParser =
  (cronParserModule as unknown as { default?: typeof cronParserModule }).default ??
  cronParserModule;

/**
 * Schedule trigger engine + missed-run catch-up policy — TypeScript port of
 * `lib/core/schedule_coordinator.dart` (`MissedRunPolicy` and the next-fire
 * rules), with the cloud plan's tz-aware `daily_at`/`cron` extensions.
 * All instants are UTC; timezones exist only inside trigger evaluation.
 */

export const SCHEDULE_TRIGGER_KINDS = ["at", "every", "daily_at", "cron"] as const;
export type ScheduleTriggerKind = (typeof SCHEDULE_TRIGGER_KINDS)[number];

export type ScheduleTrigger =
  | { kind: "at"; at: string } // ISO-8601 instant, stored UTC-normalized
  | { kind: "every"; seconds: number } // integer >= 300
  | { kind: "daily_at"; time: string; tz: string } // "HH:mm" + IANA tz
  | { kind: "cron"; expr: string; tz: string }; // 5-field cron + IANA tz

/** Catch-up tolerance (Dart: Duration(minutes: 2)) — alarm/boot jitter. */
export const MISSED_TOLERANCE_MS = 120_000;
/** One-off tasks still run when at most this late (Dart: 24 h). */
export const ONE_OFF_GRACE_MS = 86_400_000;
/** Upper bound of a recurring task's grace window (Dart: 6 h). */
export const RECURRING_GRACE_CAP_MS = 21_600_000;

/** What to do with an occurrence that fell due while Ovid was not running. */
export type MissedRunDecision = "onTime" | "runNow" | "skipToNext" | "pauseForReview";

const HH_MM = /^([01]\d|2[0-3]):[0-5]\d$/;

// luxon 3.x calls this `isValidIANAZone` (the plan's `isValidTimezone` name
// does not exist on the pinned luxon ^3.5 line).
const ianaTz = z
  .string()
  .refine((tz) => Info.isValidIANAZone(tz), { message: "tz must be a valid IANA timezone" });

/** 5-field cron syntax only: cron-parser 4.x would otherwise also accept
 * 6-field (seconds) expressions, which the wire contract forbids. */
function isValidCronExpression(expr: string): boolean {
  if (expr.trim().split(/\s+/).length !== 5) return false;
  try {
    cronParser.parseExpression(expr);
    return true;
  } catch {
    return false;
  }
}

const atTrigger = z
  .object({
    kind: z.literal("at"),
    at: z.string().refine((s) => !Number.isNaN(Date.parse(s)), {
      message: "at must be a parseable ISO-8601 instant",
    }),
  })
  .strict();

const everyTrigger = z
  .object({
    kind: z.literal("every"),
    seconds: z.number().int().min(300),
  })
  .strict();

const dailyAtTrigger = z
  .object({
    kind: z.literal("daily_at"),
    time: z.string().regex(HH_MM, { message: "time must be HH:mm" }),
    tz: ianaTz,
  })
  .strict();

const cronTrigger = z
  .object({
    kind: z.literal("cron"),
    expr: z.string().refine(isValidCronExpression, {
      message: "expr must be a valid 5-field cron expression",
    }),
    tz: ianaTz,
  })
  .strict();

/** Discriminated union on "kind"; strict variants so a payload carrying
 *  fields of two kinds at once (e.g. `at` + `seconds`) is rejected. */
export const scheduleTriggerSchema: z.ZodType<ScheduleTrigger> = z.discriminatedUnion("kind", [
  atTrigger,
  everyTrigger,
  dailyAtTrigger,
  cronTrigger,
]);

/** Everything but "at" recurs (Dart MissedRunPolicy.isRecurring). */
export function isRecurringTrigger(trigger: ScheduleTrigger): boolean {
  return trigger.kind !== "at";
}

/** First slot strictly after `from`; `null` when a one-off already elapsed. */
export function nextFireAfter(trigger: ScheduleTrigger, from: Date): Date | null {
  switch (trigger.kind) {
    case "at": {
      const at = new Date(trigger.at).getTime();
      return Number.isNaN(at) || at <= from.getTime() ? null : new Date(at);
    }
    case "every":
      return new Date(from.getTime() + trigger.seconds * 1000);
    case "daily_at":
      return nextDailyAt(trigger.time, trigger.tz, from);
    case "cron": {
      const iterator = cronParser.parseExpression(trigger.expr, {
        tz: trigger.tz,
        currentDate: from,
      });
      return iterator.next().toDate();
    }
  }
}

/**
 * Daily wall-clock slot strictly after `from` in `tz`, resolved per calendar
 * day so DST behaves like the Dart port's calendar boundaries: a gap time
 * shifts forward (02:30 -> 03:30 EDT), a fold time takes the earlier offset,
 * and each day is evaluated from its own calendar components — the shifted
 * wall time of a gap day never leaks into the next day's slot.
 */
function nextDailyAt(time: string, tz: string, from: Date): Date {
  if (!Number.isFinite(from.getTime())) throw new RangeError("from must be a finite Date");
  const [hour, minute] = time.split(":").map(Number);
  let day = DateTime.fromJSDate(from, { zone: tz });
  for (;;) {
    const candidate = DateTime.fromObject(
      { year: day.year, month: day.month, day: day.day, hour, minute, second: 0, millisecond: 0 },
      { zone: tz },
    );
    if (candidate.toMillis() > from.getTime()) return candidate.toUTC().toJSDate();
    day = day.plus({ days: 1 });
  }
}

/**
 * First interval slot at/after `now`, anchored at the occurrence
 * (`scheduledFor`), skipping every fully-missed period — Dart
 * `MissedRunPolicy.nextSlot`: steps = (now − due).inSeconds ~/ interval + 1
 * (truncating division; the slot is NOT simply now + interval).
 */
export function nextIntervalSlot(scheduledFor: Date, seconds: number, now: Date): Date {
  const steps = Math.trunc((now.getTime() - scheduledFor.getTime()) / 1000 / seconds) + 1;
  return new Date(scheduledFor.getTime() + steps * seconds * 1000);
}

/**
 * Grace window for a missed occurrence (Dart MissedRunPolicy.graceFor):
 * half the interval for `every` (truncated to whole seconds, capped at 6 h),
 * 6 h for `daily_at`/`cron`, 24 h for one-offs.
 */
export function graceMsFor(trigger: ScheduleTrigger): number {
  switch (trigger.kind) {
    case "every": {
      const half = Math.trunc(trigger.seconds / 2) * 1000;
      return Math.min(half, RECURRING_GRACE_CAP_MS);
    }
    case "daily_at":
    case "cron":
      return RECURRING_GRACE_CAP_MS;
    case "at":
      return ONE_OFF_GRACE_MS;
  }
}

/**
 * Dart MissedRunPolicy.decide: within tolerance (or still in the future) →
 * onTime; within the grace window → runNow (several missed occurrences
 * collapse into that single late run); beyond grace → recurring skipToNext,
 * one-off pauseForReview (never fire a stale action by surprise).
 */
export function decideMissedRun(trigger: ScheduleTrigger, due: Date, now: Date): MissedRunDecision {
  const late = now.getTime() - due.getTime();
  if (late <= MISSED_TOLERANCE_MS) return "onTime";
  if (late <= graceMsFor(trigger)) return "runNow";
  return isRecurringTrigger(trigger) ? "skipToNext" : "pauseForReview";
}

/**
 * First recurring slot strictly after `now` once an occurrence was skipped
 * (Dart MissedRunPolicy.nextSlot): `every` stays anchored at the missed
 * occurrence; `daily_at`/`cron` take their next fire after now; one-offs
 * have no next slot.
 */
export function nextSlotAfterMissed(trigger: ScheduleTrigger, due: Date, now: Date): Date | null {
  switch (trigger.kind) {
    case "at":
      return null;
    case "every":
      return nextIntervalSlot(due, trigger.seconds, now);
    case "daily_at":
    case "cron":
      return nextFireAfter(trigger, now);
  }
}

/** Retry backoff after a retryable failure: 30 s · 2^(attempt−1), attempt >= 1
 *  (Dart `30 * (1 << attempt)` with the 0-based attempt re-based to 1). */
export function scheduleRetryBackoffMs(attempt: number): number {
  if (!Number.isInteger(attempt) || attempt < 1) {
    throw new RangeError("attempt must be an integer >= 1");
  }
  return 30_000 * 2 ** (attempt - 1);
}

/** Deterministic human echo of a trigger (pinned templates). */
export function describeTrigger(trigger: ScheduleTrigger): string {
  switch (trigger.kind) {
    case "at":
      return `once at ${new Date(trigger.at).toISOString()}`;
    case "every":
      return `every ${trigger.seconds} seconds`;
    case "daily_at":
      return `daily at ${trigger.time} (${trigger.tz})`;
    case "cron":
      return `cron '${trigger.expr}' (${trigger.tz})`;
  }
}
