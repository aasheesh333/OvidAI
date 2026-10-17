import {
  eventMirror,
  messages,
  schedules,
  scheduleRuns,
  type Db,
  type SettleableRunRow,
  type Tx,
} from "@ovid/db";
import type { EventLog, SystemBus } from "@ovid/events";
import { scheduleRetryBackoffMs, type SessionEvent, type SessionEventType } from "@ovid/shared";
import type { Notifier } from "./notify.js";

/**
 * P4 Task 9: the settle reconciler — the second half of the scheduler loop.
 * Where the tick (schedulerTick.ts) claims and fires occurrences, settle
 * watches the claimed `running` rows and closes them out: record success
 * (summary, transcript note, push), walk the retry ladder (30 s · 2^n, no
 * push — Dart parity: intermediate retries notify nobody), or terminalize
 * failure (transcript row + note, push, and for a recurring schedule the
 * spec §8 `paused / retries_exhausted` state).
 *
 * The reconcile scan (Task 4's `scheduleRuns.listSettleable`) surfaces two
 * arms:
 *  - terminal arm: the bound run went completed/failed/cancelled.
 *  - stale arm (lost-enqueue recovery, Review Focus 2): the occurrence has
 *    been `running` longer than `staleAfterMs` with no live run behind it
 *    (run_id NULL, run row missing, or the run still `queued` — e.g. the
 *    tick's enqueue failed, schedulerTick.ts case (i)).
 *
 * Idempotence (spec §8): every branch starts with the SAME conditional state
 * transition under a `FOR UPDATE` lock on the schedule_run row — lock, re
 * check `status = 'running'`, then mutate. Two overlapping settle passes
 * serialize on the lock; the loser sees the row already left `running` and
 * skips it SILENTLY, so notifications/transcript/push fire exactly once.
 * Task 4's `finish`/`scheduleRetry` are themselves conditional on
 * `status='running'` (defense in depth); the lock here is what tells the
 * WINNER it won before any side effect runs.
 *
 * Ordering: db transitions commit first (the bookkeeping is first-class),
 * then transcript emit, system publishes, and push (best-effort — a
 * throwing notifier is logged and never fails the pass; the Dart `onResult`
 * contract carried over from Task 7).
 */

/** Default lost-enqueue window (Review Focus 2): 2 minutes, the Dart value. */
export const SCHEDULE_ENQUEUE_LOST_MS = 120_000;

/** Run failure codes the retry ladder walks; everything else is terminal. */
export const RETRYABLE_RUN_CODES = ["model_transient_exhausted", "run_lost"] as const;

/** Max occurrences settled per pass (the tick's TICK_BATCH_LIMIT pattern). */
export const SETTLE_BATCH_LIMIT = 100;

export interface SettleDeps {
  db: Db;
  events: EventLog;
  system: SystemBus;
  notifier: Notifier;
  /** Injectable for tests; defaults to the wall clock. */
  clock?: () => Date;
  /** Override for SCHEDULE_ENQUEUE_LOST_MS; tests collapse the window. */
  staleAfterMs?: number;
}

/**
 * Classify a failed run's `last_error`. Retryable exactly for
 * RETRYABLE_RUN_CODES; every other code ("key_not_minted", "model_terminal",
 * anything unknown, and null/empty) is terminal. `code` is the passthrough
 * spelling the schedule_run row, lastResult, transcript, and push all carry
 * (null/empty normalizes to "unknown" — the run finished without a code).
 */
export function classifyRunFailure(lastError: string | null): {
  retryable: boolean;
  code: string;
} {
  const code = lastError !== null && lastError !== "" ? lastError : "unknown";
  const retryable = (RETRYABLE_RUN_CODES as readonly string[]).includes(code);
  return { retryable, code };
}

/**
 * Raw SQL pinned to the open transaction's connection (same sanctioned
 * escape hatch as schedulerTick.ts: the worker app does not depend on
 * drizzle-orm directly, and this is the only way to reach
 * `FOR UPDATE` through the repos' DbOrTx surface).
 */
type PinnedSql = (
  strings: TemplateStringsArray,
  ...values: unknown[]
) => Promise<Array<Record<string, unknown>>>;

function txSql(tx: Tx): PinnedSql {
  return (tx as unknown as { session: { client: PinnedSql } }).session.client;
}

/**
 * The idempotence gate: lock the occurrence row and confirm it is still
 * `running`. false = another settle pass (or any other writer) already moved
 * it — the caller skips the row silently.
 */
async function claimSettleTransition(tx: Tx, scheduleRunId: string): Promise<boolean> {
  const locked = await txSql(tx)`SELECT status FROM schedule_runs WHERE id = ${scheduleRunId} FOR UPDATE`;
  const status = locked[0]?.status;
  return status === "running";
}

/** The runProcessor emit pattern: events.append, then the durable mirror. */
async function emit(
  deps: SettleDeps,
  sessionId: string,
  type: SessionEventType,
  payload: Record<string, unknown>,
): Promise<SessionEvent> {
  const event = await deps.events.append(sessionId, type, payload);
  await eventMirror.put(deps.db, event);
  return event;
}

/** Push is best-effort: a rejection is logged, never propagated. */
async function pushBestEffort(fn: () => Promise<void>): Promise<void> {
  try {
    await fn();
  } catch (err) {
    console.error("[settle] push failed", err);
  }
}

/** One settled occurrence's failure verdict (classification + context). */
interface FailureVerdict {
  retryable: boolean;
  code: string;
  message: string | null;
}

/**
 * One settle pass. Returns the number of occurrences settled (0 = quiet).
 * Per-row errors are caught and logged — one bad row never aborts the pass;
 * its row stays `running` and the next pass retries it.
 */
export async function settleScheduleRuns(deps: SettleDeps): Promise<number> {
  const now = deps.clock?.() ?? new Date();
  const staleAfterMs = deps.staleAfterMs ?? SCHEDULE_ENQUEUE_LOST_MS;
  const staleBefore = new Date(now.getTime() - staleAfterMs);
  const rows = await scheduleRuns.listSettleable(deps.db, {
    staleBefore,
    limit: SETTLE_BATCH_LIMIT,
  });

  let settled = 0;
  for (const row of rows) {
    try {
      if (await settleRow(deps, row, now, staleBefore)) settled += 1;
    } catch (err) {
      console.error("[settle] row failed", { scheduleRunId: row.id, err });
    }
  }
  return settled;
}

/** Classify + dispatch one settleable row. false = skipped (not ours). */
async function settleRow(
  deps: SettleDeps,
  row: SettleableRunRow,
  now: Date,
  staleBefore: Date,
): Promise<boolean> {
  // Success arm: the bound run completed.
  if (row.runStatus === "completed") return settleSucceeded(deps, row, now);

  // A still-live run is never settleable (the scan guarantees this); a
  // defensive skip keeps a racing writer from being second-guessed.
  if (row.runStatus === "running") return false;

  // Failure arms: failed / cancelled / orphan / queued-stale.
  const stale = row.startedAt !== null && row.startedAt.getTime() < staleBefore.getTime();
  let verdict: FailureVerdict;
  if (row.runStatus === null || row.runStatus === "queued") {
    // Orphan (run_id null / run row missing) or a run that never left the
    // queue. Both mean the enqueue was lost — retry the occurrence, and let
    // the ladder exhaust itself if it keeps happening.
    if (!stale) return false; // fresh occurrence — still inside the window
    verdict = { retryable: true, code: "run_lost", message: row.runError };
  } else if (row.runStatus === "cancelled") {
    // A user-stopped run is never retried (the intent was "stop").
    verdict = { retryable: false, code: "cancelled", message: row.runError };
  } else {
    // Run failed: the pinned classification formula.
    const c = classifyRunFailure(row.runError);
    verdict = { retryable: c.retryable, code: c.code, message: row.runError };
  }

  if (verdict.retryable && row.attempt <= row.scheduleMaxRetries) {
    return settleRetry(deps, row, now, verdict);
  }
  return settleFinalFailure(deps, row, now, verdict);
}

/** Success: finish the occurrence, record lastResult, complete one-offs. */
async function settleSucceeded(
  deps: SettleDeps,
  row: SettleableRunRow,
  now: Date,
): Promise<boolean> {
  const oneOff = row.scheduleTrigger.kind === "at";
  const outcome = await deps.db.transaction(async (tx) => {
    if (!(await claimSettleTransition(tx, row.id))) return null;
    const tdb = tx as unknown as Db;

    await scheduleRuns.finish(tdb, row.id, "succeeded");

    // Summary = the run's answer: the newest session message when it is an
    // assistant message (the run processor wrote it before finishing the
    // run), else null (no answer to quote).
    const { rows: newest } = await messages.page(tdb, row.scheduleSessionId, { limit: 1 });
    const summary =
      newest.length > 0 && newest[0].role === "assistant" ? newest[0].content : null;

    await schedules.update(tdb, row.scheduleId, {
      lastResult: {
        status: "succeeded",
        code: null,
        message: null,
        finishedAt: now.toISOString(),
        ranLate: row.ranLate,
      },
      // A one-off is done; a recurring schedule just keeps ticking.
      ...(oneOff ? { status: "completed", nextRunAt: null } : {}),
    });
    return { summary };
  });
  if (outcome === null) return false; // lost the idempotence race

  // Transcript note (the assistant message itself was already written by the
  // run processor — this only marks the occurrence boundary).
  await emit(deps, row.scheduleSessionId, "system_note", {
    scheduleId: row.scheduleId,
    scheduleRunId: row.id,
    status: "succeeded",
  });
  await deps.system.publish(row.scheduleUserId, {
    type: "schedule_run_succeeded",
    scheduleId: row.scheduleId,
    ts: now.toISOString(),
    payload: {
      scheduleRunId: row.id,
      scheduledFor: row.scheduledFor.toISOString(),
      summary: outcome.summary,
      scheduleCompleted: oneOff,
      autoDeniedApprovals: row.autoDenied.length,
    },
  });
  await pushBestEffort(() =>
    deps.notifier.notifyScheduleSucceeded({
      userId: row.scheduleUserId,
      scheduleId: row.scheduleId,
      sessionId: row.scheduleSessionId,
      title: row.scheduleTitle,
      summary: outcome.summary,
    }),
  );
  return true;
}

/** Retryable failure: arm the next attempt, publish, notify NOBODY. */
async function settleRetry(
  deps: SettleDeps,
  row: SettleableRunRow,
  now: Date,
  verdict: FailureVerdict,
): Promise<boolean> {
  const retryAt = new Date(now.getTime() + scheduleRetryBackoffMs(row.attempt));
  const won = await deps.db.transaction(async (tx) => {
    if (!(await claimSettleTransition(tx, row.id))) return false;
    await scheduleRuns.scheduleRetry(tx as unknown as Db, row.id, retryAt);
    return true;
  });
  if (!won) return false;

  // Dart parity: intermediate retries carry no push and no transcript write.
  await deps.system.publish(row.scheduleUserId, {
    type: "schedule_run_failed",
    scheduleId: row.scheduleId,
    ts: now.toISOString(),
    payload: {
      scheduleRunId: row.id,
      scheduledFor: row.scheduledFor.toISOString(),
      code: verdict.code,
      message: verdict.message,
      willRetry: true,
      retryAt: retryAt.toISOString(),
      autoDeniedApprovals: row.autoDenied.length,
    },
  });
  return true;
}

/**
 * Final failure: finish the occurrence, fail the one-off (or pause the
 * recurring schedule, spec §8), write the transcript row + note, publish,
 * push.
 */
async function settleFinalFailure(
  deps: SettleDeps,
  row: SettleableRunRow,
  now: Date,
  verdict: FailureVerdict,
): Promise<boolean> {
  const oneOff = row.scheduleTrigger.kind === "at";
  const won = await deps.db.transaction(async (tx) => {
    if (!(await claimSettleTransition(tx, row.id))) return false;
    const tdb = tx as unknown as Db;

    await scheduleRuns.finish(tdb, row.id, "failed", verdict.code);
    await schedules.update(tdb, row.scheduleId, {
      lastResult: {
        status: "failed",
        code: verdict.code,
        message: verdict.message,
        finishedAt: now.toISOString(),
        ranLate: row.ranLate,
      },
      // A failed one-off is terminal; a recurring schedule that exhausted its
      // retries pauses for review (spec §8) — never silently keeps firing.
      ...(oneOff
        ? { status: "failed" }
        : { status: "paused", pausedReason: "retries_exhausted" }),
    });
    // The transcript row the user reads in the session (the note below is
    // the live-stream marker; this is the durable message).
    await messages.append(tdb, {
      sessionId: row.scheduleSessionId,
      role: "system",
      content: `Scheduled task failed: ${verdict.message ?? verdict.code}`,
    });
    return true;
  });
  if (!won) return false;

  await emit(deps, row.scheduleSessionId, "system_note", {
    scheduleId: row.scheduleId,
    scheduleRunId: row.id,
    status: "failed",
    code: verdict.code,
  });
  await deps.system.publish(row.scheduleUserId, {
    type: "schedule_run_failed",
    scheduleId: row.scheduleId,
    ts: now.toISOString(),
    payload: {
      scheduleRunId: row.id,
      scheduledFor: row.scheduledFor.toISOString(),
      code: verdict.code,
      message: verdict.message,
      willRetry: false,
      retryAt: null,
      autoDeniedApprovals: row.autoDenied.length,
    },
  });
  if (!oneOff) {
    await deps.system.publish(row.scheduleUserId, {
      type: "schedule_run_paused",
      scheduleId: row.scheduleId,
      ts: now.toISOString(),
      payload: { reason: "retries_exhausted", code: verdict.code },
    });
  }
  // key_not_minted automatically carries the Q5 open-the-app body (Task 7).
  await pushBestEffort(() =>
    deps.notifier.notifyScheduleFailed({
      userId: row.scheduleUserId,
      scheduleId: row.scheduleId,
      sessionId: row.scheduleSessionId,
      title: row.scheduleTitle,
      code: verdict.code,
      error: verdict.message,
    }),
  );
  return true;
}
