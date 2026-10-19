import { eventMirror, runs, type Db } from "@ovid/db";
import type { EventLog } from "@ovid/events";

/**
 * Stale-run sweeper — the recovery mechanism for stranded runs (Task 9 fix
 * round, controller ruling).
 *
 * Why it exists: BullMQ attempts:1 means an unknown/infra error thrown by the
 * processor FAILS the job permanently (failed ≠ stalled — no redelivery), and
 * on a worker crash mid-run the stalled handling also fails the job rather
 * than redelivering it. Even a hypothetical redelivery could not recover the
 * run: claimNext claims 'queued' rows only, so it would silently no-op. Net
 * effect without this sweeper: the run row stays 'running' forever, no
 * terminal event is ever emitted, and the client waits forever.
 *
 * The sweep finds 'running' rows whose LAST ACTIVITY is older than
 * staleAfterMs — last_active_at (the engine loop's per-emit heartbeat),
 * falling back to started_at for rows that never stamped one — and
 * terminalizes each exactly like the processor terminalizes failures:
 * claim the row with the conditional `runs.finish(...)` transition FIRST
 * (Task 2 claim-then-emit — only the winner of the `status='running'` race
 * proceeds), then append+mirror `run_failed {runId, code:"run_lost"}`. Two
 * concurrent sweeps therefore emit exactly one event per run. Without the
 * heartbeat a long-but-healthy run (a big tool loop, a slow model) crossed
 * the threshold on started_at alone and got run_lost mid-flight, arming a
 * CONCURRENT scheduler retry behind the still-live original. Bounded to 100
 * rows per pass (runs.listStaleRunning); main.ts re-runs it every 60 s.
 *
 * The queued half (wave-2 fix round): a worker death while a run WAITS for
 * its session turn strands the row in 'queued' — the same attempts:1 no-
 * redelivery rule, but with a worse blast radius: the zombie stays the
 * session's OLDEST active run (runs.activeForSession), so every later run
 * of that session burns a full queue-wait plus a concurrency slot behind it,
 * forever. Age for queued rows is COALESCE(last_active_at, created_at)
 * (runs.listStaleQueued): a queued waiter emits nothing, so created_at IS
 * its activity. Same claim-then-emit discipline, but the code is the one
 * the processor's own wait cap uses — `run_queue_wait_timeout` — so the
 * client folds a swept zombie exactly like a live waiter that gave up (the
 * canonical-code rule from final review M3: settle's classifyRunFailure
 * matches exact codes).
 */

export interface StaleRunDeps {
  db: Db;
  events: EventLog;
  /** Injectable for tests; defaults to the wall clock. */
  clock?: () => Date;
}

/**
 * Terminalizes runs stranded in 'running' (run_lost) and 'queued'
 * (run_queue_wait_timeout — the C1-wait zombie). Returns the total number
 * swept (0 = a quiet pass). Errors are NOT caught here — the caller (main.ts)
 * logs and keeps the interval alive; a sweep that fails halfway leaves the
 * remaining rows for the next pass (finish() already ran for the ones
 * emitted).
 */
export async function sweepStaleRuns(
  deps: StaleRunDeps,
  opts: { staleAfterMs: number },
): Promise<number> {
  const now = deps.clock?.() ?? new Date();
  const staleBefore = new Date(now.getTime() - opts.staleAfterMs);
  let swept = 0;

  // ---- 'running' half: crashed mid-run --------------------------------
  const stranded = await runs.listStaleRunning(deps.db, staleBefore);
  for (const run of stranded) {
    // Claim-then-emit (P10 Task 2): the conditional UPDATE is the race guard.
    // A concurrent sweep that listed the same row loses here and emits
    // nothing, so `run_failed` appears exactly once.
    // The canonical code, NOT a decorated one (final review M3): settle's
    // `classifyRunFailure` matches exact codes, so `"run_lost: stale sweep"`
    // classified a crashed scheduler-fired occurrence as TERMINAL and the
    // retry ladder never armed. The detail stays in the log.
    const claimed = await runs.finish(deps.db, run.id, "failed", "run_lost");
    if (!claimed) continue;
    swept += 1;
    console.warn("[staleRuns] swept run", { runId: run.id, detail: "run_lost: stale sweep" });
    const event = await deps.events.append(run.sessionId, "run_failed", {
      runId: run.id,
      code: "run_lost",
    });
    await eventMirror.put(deps.db, event);
  }

  // ---- 'queued' half: died waiting for the session turn -----------------
  // Same threshold, same claim-then-emit; the different code is the whole
  // point (a queued row never started, so run_lost would misclassify it as
  // a crashed occurrence — and the client already maps the processor's
  // wait-cap spelling).
  const zombies = await runs.listStaleQueued(deps.db, staleBefore);
  for (const run of zombies) {
    const claimed = await runs.finish(deps.db, run.id, "failed", "run_queue_wait_timeout");
    if (!claimed) continue;
    swept += 1;
    console.warn("[staleRuns] swept queued run", {
      runId: run.id,
      detail: "run_queue_wait_timeout: stale sweep",
    });
    const event = await deps.events.append(run.sessionId, "run_failed", {
      runId: run.id,
      code: "run_queue_wait_timeout",
    });
    await eventMirror.put(deps.db, event);
  }

  return swept;
}
