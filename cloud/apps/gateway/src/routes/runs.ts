import type { FastifyBaseLogger, FastifyInstance } from "fastify";
import { eventMirror, runs } from "@ovid/db";
import type { RunCancelResponse } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { isUuid, notFound, sendError } from "./http.js";

// Run routes (P8 Task 1): cooperative run cancel. All mounted inside the
// authenticated /cloud/v1 scope.

/** Terminal run statuses — cancellation is refused (409) once reached. */
const TERMINAL_RUN_STATUSES = new Set(["completed", "failed", "cancelled"]);

/** The one cancelled-run payload, shared verbatim by gateway and worker. */
export const CANCELLED_MESSAGE = "Stopped by user.";

/**
 * The cancel core shared by POST /runs/:id/cancel and DELETE /sessions/:id
 * (a deleted session cancels its still-active runs first): request the
 * cooperative flag, best-effort-remove the BullMQ job, and terminalize a
 * QUEUED run nobody claimed — the exact flow the cancel route owns. The
 * caller has already verified the run exists, is not terminal, and is owned
 * by `uid` (runs.get / sessions.get are ownership-scoped).
 *
 * Returns the verdict the cancel flow produced:
 *   - "cancelled": this process terminalized the run (it was still queued
 *     when the job was removed) — run_failed{cancelled} appended + mirrored
 *     BEFORE the status flip (the event-first pairing the worker pins, so
 *     the C1 wait loop's ordering guarantee holds);
 *   - "cancelling": the flag is set; the worker's throttled check owns the
 *     terminalization (job remove failed, or a worker already claimed it).
 *
 * Never throws for a queue failure — the flag + worker check cover it.
 */
export async function cancelActiveRun(
  deps: GatewayDeps,
  log: FastifyBaseLogger,
  uid: string,
  runId: string,
): Promise<"cancelled" | "cancelling"> {
  const row = await runs.get(deps.db, runId, uid);
  if (row === null || TERMINAL_RUN_STATUSES.has(row.status)) return "cancelling";

  // Conditional ownership-scoped write. null here means the run went
  // terminal between the read above and this UPDATE (race window) — the
  // flag then stays unset and the worker's own verdict is final.
  if ((await runs.requestCancel(deps.db, runId, uid)) === null) return "cancelling";

  // Best-effort job removal — a locked/active/missing job must never 5xx
  // the cancel call; the flag + worker check cover those cases.
  let removed = false;
  try {
    await deps.queues.agentRuns.remove(runId);
    removed = true;
  } catch (err) {
    log.warn({ err, runId }, "cancel: queue remove failed (best-effort)");
  }

  if (removed) {
    // Re-read: if a worker claimed the run (or already finished it) while we
    // were removing the job, the row is no longer 'queued' — degrade to
    // "cancelling" and let the worker's flag check terminalize. finish() is
    // conditional (I4b), so a concurrent terminalization is never clobbered.
    const fresh = await runs.get(deps.db, runId, uid);
    if (fresh !== null && fresh.status === "queued") {
      // Event BEFORE the status flip — the same ordering the worker pins
      // (runProcessor header): the next same-session run's C1 wait loop
      // unblocks on the flip, so its run_started lands strictly after this
      // terminal event.
      const event = await deps.events.append(row.sessionId, "run_failed", {
        code: "cancelled",
        message: CANCELLED_MESSAGE,
      });
      await eventMirror.put(deps.db, event);
      await runs.finish(deps.db, runId, "cancelled", CANCELLED_MESSAGE);
      return "cancelled";
    }
  }
  return "cancelling";
}

/**
 * POST /cloud/v1/runs/:id/cancel
 *
 * Contract: 202 {runId, status: "cancelled" | "cancelling"}. The flow is
 * cooperative, never destructive:
 *
 *   1. shape + ownership guard → 404 not_found (identical envelope for a
 *      malformed, unknown, or not-owned id — no existence leaks, and a
 *      malformed id never reaches the db);
 *   2. terminal check → 409 run_not_cancellable;
 *   3. cancelActiveRun: requestCancel + best-effort BullMQ remove + the
 *      queued-race terminalization (see its header for the verdicts).
 *
 * Every degrade path answers "cancelling" instead: remove failed, or the job
 * was already claimed (row 'running') — the worker's flag check owns the
 * terminalization there.
 */
export function registerRunRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.post("/runs/:id/cancel", async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return notFound(reply, "Run not found.");

    const row = await runs.get(deps.db, id, request.principal.uid);
    if (row === null) return notFound(reply, "Run not found.");
    if (TERMINAL_RUN_STATUSES.has(row.status)) {
      return sendError(
        reply,
        409,
        "run_not_cancellable",
        "This run has already finished and can no longer be cancelled.",
      );
    }

    // Null only in the race window where the run went terminal between the
    // read above and this conditional write — refuse rather than answer a
    // status that is already moot.
    const requested = await runs.requestCancel(deps.db, id, request.principal.uid);
    if (requested === null) {
      return sendError(
        reply,
        409,
        "run_not_cancellable",
        "This run has already finished and can no longer be cancelled.",
      );
    }

    const status = await cancelActiveRun(deps, request.log, request.principal.uid, id);
    const body: RunCancelResponse = { runId: id, status };
    return reply.code(202).send(body);
  });
}
