/**
 * Idle sweeper (P7 Task 10) — one periodic pass, never throws.
 *
 * `sweepWorkspaces` is the whole state machine in one tick:
 *   1. reconcile the seam ↔ Postgres warm registry (and repair crash-stranded
 *      hibernating/hydrating rows),
 *   2. enqueue `reason:"idle"` hibernations for warm rows whose last activity
 *      (or row.updatedAt fallback) is at least IDLE_THRESHOLD_MS old,
 *   3. enforce the warm-byte cap / disk alert (least-recently-active first).
 *
 * The caller is the worker's `setInterval` (Task 11), so every failure is
 * logged and swallowed — one bad tick must never kill the sweeper. Idle
 * triggers are derived from activity keys + Postgres, never from a BullMQ
 * delayed-job registry (see the plan's "Idle-trigger choice").
 */

import {
  HIBERNATE_JOB_NAME,
  IDLE_THRESHOLD_MS,
  enforceWarmCap,
  reconcileWarmRegistry,
  storageJobId,
  type WarmConfig,
  type WarmDeps,
} from "./warmLru.js";

export interface SweepResult {
  registered: number;
  enqueuedIdle: number;
  enqueuedPressure: number;
}

export async function sweepWorkspaces(
  deps: WarmDeps,
  cfg: WarmConfig,
  opts: { now?: Date } = {},
): Promise<SweepResult> {
  const now = opts.now ?? (deps.clock?.() ?? new Date());
  const nowMs = now.getTime();
  let registered = 0;
  let enqueuedIdle = 0;
  let enqueuedPressure = 0;

  // -- (1) reconcile + crash recovery --------------------------------------
  try {
    const rec = await reconcileWarmRegistry(deps, cfg, { now });
    registered = rec.registered;
  } catch (err) {
    console.error("[sweeper] reconcileWarmRegistry failed", err);
  }

  // -- (2) idle pass --------------------------------------------------------
  try {
    const rows = await deps.fileManifests.listWarmForLru(deps.db);
    let activity = new Map<string, number>();
    try {
      activity = await deps.activity.readMany(rows.map((r) => r.sessionId));
    } catch (err) {
      // Cache-class redis: fall back to row.updatedAt for every session.
      console.error(
        "[sweeper] activity.readMany failed; using row.updatedAt fallback",
        err,
      );
    }

    for (const row of rows) {
      const lastActivity = activity.get(row.sessionId) ?? row.updatedAt.getTime();
      if (nowMs - lastActivity < IDLE_THRESHOLD_MS) continue;

      const generation = row.generation + 1;
      try {
        await Promise.resolve(
          deps.queues.hibernate.add(
            HIBERNATE_JOB_NAME,
            {
              sessionId: row.sessionId,
              userId: row.userId,
              generation,
              reason: "idle",
            },
            { jobId: storageJobId(row.sessionId, generation) },
          ),
        );
        enqueuedIdle += 1;
      } catch (err) {
        // One failed add must not skip the remaining idle sessions.
        console.error(
          `[sweeper] failed to enqueue idle hibernate for ${row.sessionId}`,
          err,
        );
      }
    }
  } catch (err) {
    console.error("[sweeper] idle pass failed", err);
  }

  // -- (3) warm cap / disk pressure ---------------------------------------
  try {
    const cap = await enforceWarmCap(deps, cfg);
    enqueuedPressure = cap.evicted;
  } catch (err) {
    console.error("[sweeper] enforceWarmCap failed", err);
  }

  return { registered, enqueuedIdle, enqueuedPressure };
}
