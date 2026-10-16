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
 * The sweep finds 'running' rows whose startedAt is older than staleAfterMs
 * and terminalizes each exactly like the processor terminalizes failures:
 * append+mirror `run_failed {runId, code:"run_lost"}` (same emit pattern —
 * events.append then eventMirror.put), then runs.finish(failed). Bounded to
 * 100 rows per pass (runs.listStaleRunning); main.ts re-runs it every 60 s.
 */

export interface StaleRunDeps {
  db: Db;
  events: EventLog;
  /** Injectable for tests; defaults to the wall clock. */
  clock?: () => Date;
}

/**
 * Terminalizes runs stranded in 'running'. Returns the number swept (0 = a
 * quiet pass). Errors are NOT caught here — the caller (main.ts) logs and
 * keeps the interval alive; a sweep that fails halfway leaves the remaining
 * rows for the next pass (finish() already ran for the ones emitted).
 */
export async function sweepStaleRuns(
  deps: StaleRunDeps,
  opts: { staleAfterMs: number },
): Promise<number> {
  const now = deps.clock?.() ?? new Date();
  const staleBefore = new Date(now.getTime() - opts.staleAfterMs);
  const stranded = await runs.listStaleRunning(deps.db, staleBefore);
  for (const run of stranded) {
    const event = await deps.events.append(run.sessionId, "run_failed", {
      runId: run.id,
      code: "run_lost",
    });
    await eventMirror.put(deps.db, event);
    await runs.finish(deps.db, run.id, "failed", "run_lost: stale sweep");
  }
  return stranded.length;
}
