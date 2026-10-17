import { type Db, type ScheduleRow, messages, runs, schedules, scheduleRuns, users, type Tx } from "@ovid/db";
import type { SystemBus } from "@ovid/events";
import {
  isRecurringTrigger,
  nextFireAfter,
  nextIntervalSlot,
  nextSlotAfterMissed,
  schedulePrompt,
  decideMissedRun,
} from "@ovid/shared";
import { AGENT_RUN_JOB_NAME, addScheduleMirrorJob, type QueueServices } from "@ovid/queue";
import type { SettleDeps } from "./schedulerSettle.js";

/**
 * P4 Task 8: the scheduler's firing engine — occurrence claiming, the
 * missed-run policy, and the 15 s tick loop (Dart schedule_coordinator port,
 * cloud side).
 *
 * Concurrency contract (spec §8):
 *   - ONE Postgres transaction per schedule: the schedule row is locked
 *     `FOR UPDATE SKIP LOCKED`, so two concurrent fires of the SAME schedule
 *     serialize (the loser sees the advanced `next_run_at` → `not_due`) and
 *     fires of DIFFERENT schedules never block each other.
 *   - The durable idempotency key is `schedule_runs` UNIQUE(schedule_id,
 *     scheduled_for): a claim that loses the ledger race rolls its message +
 *     run inserts back and returns `duplicate_claim` (Review Focus 1 backstop).
 *   - The queue is only a wake-up MIRROR. The row is the source of truth:
 *     `expectedScheduledFor` is checked against the locked row's `nextRunAt`
 *     (±1 ms) so a stale mirror job that lost the race resolves to `not_due`
 *     instead of double-firing (T6 review note — jobId idempotence only holds
 *     while the delayed job exists; this fire-side check is what survives a
 *     redelivered/re-created mirror).
 *
 * Post-commit side effects (enqueue, system publish, mirror re-arm) run AFTER
 * the transaction commits and in the pinned order; an enqueue failure is
 * logged loudly and never rethrown — the run row stays `queued` and Task 9's
 * settle stale path recovers the occurrence.
 */

/** The plan-pinned tick cadence (Dart: 15 s). */
export const SCHEDULER_TICK_MS = 15_000;
/** Max due schedules handled per tick pass. */
export const TICK_BATCH_LIMIT = 50;

export interface SchedulerDeps {
  db: Db;
  queues: QueueServices;
  system: SystemBus;
  /** Injectable for tests; defaults to the wall clock. */
  clock?: () => Date;
}

export type FireOutcome =
  | "fired"
  | "retry_fired"
  | "skipped_next"
  | "paused"
  | "deferred_busy"
  | "duplicate_claim"
  | "not_due"
  | "not_found";

export interface TickReport {
  fired: number;
  retried: number;
  skipped: number;
  paused: number;
  deferred: number;
  duplicates: number;
}

/**
 * Raw SQL pinned to the open transaction's connection. drizzle's postgres-js
 * session keeps the transaction-scoped client on `session.client`; the worker
 * app does not (and must not) depend on drizzle-orm directly, so this is the
 * one sanctioned escape hatch for the `FOR UPDATE SKIP LOCKED` row lock the
 * repos do not expose (the brief's "or raw SQL" branch).
 */
type PinnedSql = (
  strings: TemplateStringsArray,
  ...values: unknown[]
) => Promise<Array<Record<string, unknown>>>;

function txSql(tx: Tx): PinnedSql {
  return (tx as unknown as { session: { client: PinnedSql } }).session.client;
}

/** Sentinel thrown inside the tx to force a ROLLBACK (lost the claim race). */
const CLAIM_LOST = Symbol("scheduler claim lost — rollback");

/**
 * Fire one occurrence of a schedule (retry pass first, then a new-occurrence
 * pass). `expectedScheduledFor` — what the CALLER believed `nextRunAt` was
 * when it decided this schedule is due (the tick passes the scanned row's
 * `nextRunAt`; a mirror job passes its own `scheduledFor`). NON-NULL values
 * are checked against the locked row: a mismatch means the row already moved
 * on → `not_due`. null SKIPS the guard entirely — that is how retry-driven
 * rows (next_run_at NULL) still fire.
 */
export async function fireScheduleOccurrence(
  deps: SchedulerDeps,
  scheduleId: string,
  opts?: { expectedScheduledFor?: Date | null },
): Promise<FireOutcome> {
  const now = deps.clock?.() ?? new Date();
  /** Post-commit side effects, in the pinned order. */
  let postCommit: (() => Promise<void>) | null = null;

  /** Enqueue the agent run for a fired occurrence (step 5). Never rethrows. */
  const enqueue = async (row: ScheduleRow, runId: string, scheduleRunId: string, prompt: string): Promise<void> => {
    try {
      const tier = (await users.ensure(deps.db, row.userId, null)).tier;
      await deps.queues.agentRuns.add(
        AGENT_RUN_JOB_NAME,
        {
          runId,
          sessionId: row.sessionId,
          userId: row.userId,
          prompt,
          schedule: {
            scheduleId: row.id,
            scheduleRunId,
            autonomy: row.autonomy as "safe" | "auto",
          },
        },
        { jobId: runId, priority: tier === "free" ? 2 : 1 },
      );
    } catch (err) {
      // Never rethrow: the occurrence IS claimed and committed — the run row
      // stays 'queued' and Task 9's settle stale path recovers it.
      console.error("[scheduler] enqueue failed", { scheduleId: row.id, runId, err });
    }
  };

  let outcome: FireOutcome;
  try {
    outcome = await deps.db.transaction(async (tx) => {
      const tdb = tx as unknown as Db;

      // Step 1: lock the pending row, or classify why we cannot.
      const locked = await txSql(tx)`SELECT id FROM schedules WHERE id = ${scheduleId} AND status = 'pending' FOR UPDATE SKIP LOCKED`;
      if (locked.length === 0) {
        // Absent → not_found. Present but not pending (paused/cancelled/…),
        // or pending but another fire currently holds the lock → not_due.
        return (await schedules.getById(tdb, scheduleId)) === null ? "not_found" : "not_due";
      }
      const row = await schedules.getById(tdb, scheduleId);
      if (row === null || row.status !== "pending") return "not_found";

      // Mirror-race guard (row is the source of truth). NON-NULL expected
      // only: null is how retry-driven rows (next_run_at NULL) get through.
      if (opts?.expectedScheduledFor != null) {
        if (
          row.nextRunAt === null ||
          Math.abs(row.nextRunAt.getTime() - opts.expectedScheduledFor.getTime()) > 1
        ) {
          return "not_due";
        }
      }

      // Step 2: retry pass FIRST — a due retry is the alternative to the
      // expectedScheduledFor path, never both.
      const retry = await scheduleRuns.claimRetryDue(tdb, scheduleId, now);
      if (retry !== null) {
        if ((await runs.activeForSession(tdb, row.sessionId)) !== null) return "deferred_busy";
        const prompt = schedulePrompt(row.title, row.description);
        const message = await messages.append(tdb, {
          sessionId: row.sessionId,
          role: "user",
          content: prompt,
        });
        const run = await runs.create(tdb, {
          sessionId: row.sessionId,
          promptMessageId: message.id,
        });
        const claimed = await scheduleRuns.claimRetry(tdb, retry.id, run.id);
        if (claimed === null) throw CLAIM_LOST; // lost the retry race: rollback
        postCommit = () => enqueue(row, run.id, claimed!.id, prompt);
        return "retry_fired";
      }

      // Step 3: new-occurrence pass.
      if (row.nextRunAt === null || row.nextRunAt.getTime() > now.getTime()) return "not_due";
      const due = row.nextRunAt;

      // Busy defers with the row untouched — NO policy applied while the
      // session is busy (Dart parity: policy applies only when free).
      if ((await runs.activeForSession(tdb, row.sessionId)) !== null) return "deferred_busy";

      const decision = decideMissedRun(row.trigger, due, now);
      if (decision === "onTime" || decision === "runNow") {
        const ranLate = decision === "runNow";
        const prompt = schedulePrompt(row.title, row.description);
        const message = await messages.append(tdb, {
          sessionId: row.sessionId,
          role: "user",
          content: prompt,
        });
        const run = await runs.create(tdb, {
          sessionId: row.sessionId,
          promptMessageId: message.id,
        });
        const claimed = await scheduleRuns.claim(tdb, {
          scheduleId,
          scheduledFor: due,
          runId: run.id,
          ranLate,
        });
        if (claimed === null) throw CLAIM_LOST; // ledger race: rollback message+run

        // Advance: `every` stays anchored at the occurrence; other recurring
        // triggers take their next fire after now; one-offs are done.
        const next = isRecurringTrigger(row.trigger)
          ? row.trigger.kind === "every"
            ? nextIntervalSlot(due, row.trigger.seconds, now)
            : nextFireAfter(row.trigger, now)
          : null;
        await schedules.update(tdb, scheduleId, { nextRunAt: next });

        const nextRunAt = next;
        postCommit = async () => {
          await enqueue(row, run.id, claimed!.id, prompt);
          await deps.system.publish(row.userId, {
            type: "schedule_run_started",
            scheduleId,
            ts: now.toISOString(),
            payload: {
              scheduleRunId: claimed!.id,
              runId: run.id,
              scheduledFor: due.toISOString(),
              ranLate,
              attempt: claimed!.attempt,
            },
          });
          if (nextRunAt !== null) {
            await addScheduleMirrorJob(deps.queues, scheduleId, nextRunAt, now);
          }
        };
        return "fired";
      }

      if (decision === "skipToNext") {
        const skipped = await scheduleRuns.recordSkip(tdb, { scheduleId, scheduledFor: due });
        if (skipped === null) throw CLAIM_LOST; // someone else ledgered this occurrence
        const next = nextSlotAfterMissed(row.trigger, due, now);
        await schedules.update(tdb, scheduleId, { nextRunAt: next });
        const nextRunAt = next;
        postCommit = async () => {
          await deps.system.publish(row.userId, {
            type: "schedule_updated",
            scheduleId,
            ts: now.toISOString(),
            payload: {
              reason: "skipped_missed",
              skippedFor: due.toISOString(),
              nextRunAt: nextRunAt?.toISOString() ?? null,
            },
          });
          if (nextRunAt !== null) {
            await addScheduleMirrorJob(deps.queues, scheduleId, nextRunAt, now);
          }
        };
        return "skipped_next";
      }

      // pauseForReview (one-off, beyond grace): never fire a stale action by
      // surprise — pause and keep nextRunAt (informational; resume recomputes).
      await schedules.update(tdb, scheduleId, {
        status: "paused",
        pausedReason: "missed_beyond_grace",
      });
      postCommit = async () => {
        await deps.system.publish(row.userId, {
          type: "schedule_run_paused",
          scheduleId,
          ts: now.toISOString(),
          payload: { reason: "missed_beyond_grace", scheduledFor: due.toISOString() },
        });
      };
      return "paused";
    });
  } catch (err) {
    if (err === CLAIM_LOST) return "duplicate_claim";
    throw err;
  }

  if (postCommit !== null) await postCommit();
  return outcome;
}

/**
 * One tick pass: a short transaction claims the due batch (FOR UPDATE SKIP
 * LOCKED — overlapping ticks partition the set), then each schedule fires in
 * its OWN transaction. A fire that throws is caught and logged — Postgres is
 * authoritative and the next tick retries the schedule.
 */
export async function runSchedulerTick(deps: SchedulerDeps): Promise<TickReport> {
  const now = deps.clock?.() ?? new Date();
  const report: TickReport = {
    fired: 0,
    retried: 0,
    skipped: 0,
    paused: 0,
    deferred: 0,
    duplicates: 0,
  };
  // claimDue's lock only means something inside a transaction; commit
  // immediately so the locks never span the (slow) fire phase.
  const due = await deps.db.transaction((tx) => schedules.claimDue(tx, now, TICK_BATCH_LIMIT));

  for (const row of due) {
    try {
      const outcome = await fireScheduleOccurrence(deps, row.id, {
        expectedScheduledFor: row.nextRunAt,
      });
      switch (outcome) {
        case "fired":
          report.fired += 1;
          break;
        case "retry_fired":
          report.retried += 1;
          break;
        case "skipped_next":
          report.skipped += 1;
          break;
        case "paused":
          report.paused += 1;
          break;
        case "deferred_busy":
          report.deferred += 1;
          break;
        case "duplicate_claim":
          report.duplicates += 1;
          break;
        default:
          break; // not_due / not_found — raced; the row stays authoritative
      }
    } catch (err) {
      console.error("[scheduler] fire failed", { scheduleId: row.id, err });
    }
  }
  return report;
}

/**
 * The 15 s loop: settle (Task 9) then tick, every pass — the Dart
 * `_ticking` port. A pass still running when the next interval fires is
 * SKIPPED (overlap guard); pass errors are logged, never fatal.
 */
export interface SchedulerLoopDeps extends SchedulerDeps, SettleDeps {
  /**
   * Task-9 forward seam (remove when schedulerSettle.ts lands): until the
   * real settle exists the loop settles nothing. This is the ONLY stubbed
   * contract — everything else here is final.
   */
  settleScheduleRuns?: (deps: SettleDeps) => Promise<number>;
}

const noopSettle = async (_deps: SettleDeps): Promise<number> => 0;

export function startSchedulerLoop(
  deps: SchedulerLoopDeps,
  opts?: { intervalMs?: number },
): { stop(): void } {
  let ticking = false;
  const timer = setInterval(() => {
    if (ticking) return; // a pass still running → skip this interval
    ticking = true;
    void (async () => {
      try {
        await (deps.settleScheduleRuns ?? noopSettle)(deps);
        await runSchedulerTick(deps);
      } catch (err) {
        console.error("[scheduler] pass failed", err);
      } finally {
        ticking = false;
      }
    })();
  }, opts?.intervalMs ?? SCHEDULER_TICK_MS);
  timer.unref(); // never hold the process open by itself
  return {
    stop() {
      clearInterval(timer);
    },
  };
}
