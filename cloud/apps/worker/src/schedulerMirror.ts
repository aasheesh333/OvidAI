/**
 * P4 Task 10 — the scheduler's boot mirror resync + the BullMQ schedules
 * consumer.
 *
 * Postgres is authoritative; the `schedules` queue is only a wake-up mirror of
 * `schedules.nextRunAt`. `resyncScheduleMirror` rebuilds that mirror at boot
 * (a crashed worker may have lost delayed jobs; deterministic jobIds make
 * re-adding the same occurrence a no-op). The fire processor validates the
 * mirror payload and hands the occurrence to Task 8's `fireScheduleOccurrence`,
 * whose expectedScheduledFor guard makes a stale mirror a normal no-op.
 *
 * A malformed mirror payload COMPLETES (never retries): the mirror is not
 * authoritative, so retrying garbage cannot help. Only infrastructure throws
 * propagate, and BullMQ's default handling owns those.
 */

import { schedules, type Db } from "@ovid/db";
import {
  addScheduleMirrorJob,
  scheduleFireJobSchema,
  type QueueServices,
  type ScheduleFireJob,
} from "@ovid/queue";

import { fireScheduleOccurrence, type SchedulerDeps } from "./schedulerTick.js";

export interface MirrorResyncDeps {
  db: Db;
  queues: QueueServices;
  /** Injectable for tests; defaults to the wall clock. */
  clock?: () => Date;
}

/**
 * Re-arm one delayed mirror job per pending schedule that has a next run.
 * Returns the number of add ATTEMPTS (idempotent jobIds mean a re-add after a
 * crash still counts, but produces no duplicate job).
 */
export async function resyncScheduleMirror(deps: MirrorResyncDeps): Promise<number> {
  const now = deps.clock?.() ?? new Date();
  const rows = await schedules.listPendingWithNextRun(deps.db);
  let added = 0;
  for (const row of rows) {
    if (row.nextRunAt === null) continue; // listPendingWithNextRun guarantees non-null
    await addScheduleMirrorJob(deps.queues, row.id, row.nextRunAt, now);
    added += 1;
  }
  return added;
}

/**
 * The `schedules` queue consumer. Every outcome of `fireScheduleOccurrence`
 * (including `not_due` and `duplicate_claim`) is a normal completion — the
 * row, not the mirror job, decides whether anything happened.
 */
export function createScheduleFireProcessor(
  deps: SchedulerDeps,
): (job: { data: ScheduleFireJob }) => Promise<void> {
  return async (job) => {
    const parsed = scheduleFireJobSchema.safeParse(job.data);
    if (!parsed.success) {
      console.error(
        "[scheduler] invalid mirror job — completing without retry",
        parsed.error.issues,
      );
      return;
    }
    await fireScheduleOccurrence(deps, parsed.data.scheduleId, {
      expectedScheduledFor: new Date(parsed.data.scheduledFor),
    });
  };
}
