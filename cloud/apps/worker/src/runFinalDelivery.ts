import {
  eventMirror,
  messages,
  notificationDeliveryClaims,
  runDeliveryOutboxRepo,
  runs,
  type Db,
  type RunDeliveryOutboxRow,
} from "@ovid/db";
import type { EventLog } from "@ovid/events";

/**
 * Crash-safe final-response delivery for ROOT runs.
 *
 * The loss windows this closes (see runProcessor/loop call sites):
 *   1. model finished → assistant row committed: closed by committing the
 *      assistant row and the outbox intent in ONE transaction, so the answer
 *      exists iff the intent exists (a crash before the commit leaves no
 *      phantom answer, a crash after it leaves a replayable intent);
 *   2. row committed → message_completed / run_completed emitted: closed by
 *      replaying both events from the outbox row, guarded by the durable
 *      event mirror (the stable identities are `messageId` and `runId`);
 *   3. events emitted → completion push: closed by marking the row
 *      `delivered` only after the notifier's own claim row reports
 *      `delivered`. An unknown push outcome leaves the row `pending`, which
 *      is truthful: the intent is retried, never reported as delivered.
 *
 * At-least-once, idempotent consumption: the row's UNIQUE `run_id` means one
 * intent per run, `message_id` is allocated inside the record transaction (so
 * replay never appends a second assistant row), and both event replays are
 * mirror-checked. Recovery is a bounded, sequential batch with per-item
 * continuation — a poisoned row is marked `failed` (or left `pending` when the
 * failure is retryable) and never blocks the rest.
 */

/** Longest lease on a `delivering` row; a dead worker's row is reclaimed after it. */
export const FINAL_DELIVERY_LEASE_MS = 2 * 60_000;
/** Max outbox rows replayed per recovery pass. */
export const FINAL_DELIVERY_BATCH_LIMIT = 50;

export interface FinalDeliveryNotifier {
  notifyAgentFinished?: (a: {
    userId: string;
    runId: string;
    sessionId: string;
  }) => Promise<"delivered" | "retry" | void>;
}

export interface FinalDeliveryDeps {
  db: Db;
  events: EventLog;
  notifier?: FinalDeliveryNotifier;
  /** Injectable for tests; defaults to the wall clock. */
  clock?: () => Date;
}

/** The agent-core port: one root run's final answer. */
export interface FinalResponseDeliveryInput {
  runId: string;
  sessionId: string;
  content: string;
  /** Exact `run_completed` payload (runId + optional usage) for replay. */
  completionPayload: Record<string, unknown>;
}

/** Per-run binding of the identities the outbox row needs but the loop lacks. */
export interface FinalDeliveryBinding {
  userId: string;
  scheduled: boolean;
}

/**
 * A delivery outcome that can never succeed. It is the ONLY way a row becomes
 * `failed`; every unknown/transient outcome stays `pending` for a later pass.
 */
export class TerminalDeliveryError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "TerminalDeliveryError";
  }
}

export interface FinalDelivery {
  /**
   * The agent-core `FinalResponseDelivery` port. Identical to `deliverForRun`;
   * the loop calls it with the exact run/session/content/completion payload.
   */
  deliver(input: FinalResponseDeliveryInput): Promise<void>;
  /** Record the intent + assistant row, then deliver it (the inline path). */
  deliverForRun(input: FinalResponseDeliveryInput): Promise<void>;
  /** Idempotent replay of one durable intent (the recovery path). */
  deliverRow(row: RunDeliveryOutboxRow): Promise<void>;
  /** Bounded, sequential recovery batch with per-item continuation. */
  recover(opts?: { limit?: number }): Promise<{ delivered: number; failed: number; pending: number }>;
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function createFinalDelivery(
  deps: FinalDeliveryDeps,
  binding?: FinalDeliveryBinding,
): FinalDelivery {
  const clock = deps.clock ?? ((): Date => new Date());

  async function record(
    input: FinalResponseDeliveryInput,
    bound: FinalDeliveryBinding,
  ): Promise<RunDeliveryOutboxRow> {
    return runDeliveryOutboxRepo.record(deps.db, {
      runId: input.runId,
      sessionId: input.sessionId,
      userId: bound.userId,
      content: input.content,
      completionPayload: input.completionPayload,
      scheduled: bound.scheduled,
      now: clock(),
    });
  }

  async function deliverRow(row: RunDeliveryOutboxRow): Promise<void> {
    // ---- 1. the answer must still exist (it was committed with the intent) --
    const message = await messages.get(deps.db, row.messageId);
    if (message === null) {
      throw new TerminalDeliveryError(
        `final message ${row.messageId} is missing for run ${row.runId}`,
      );
    }
    if (message.sessionId !== row.sessionId) {
      throw new TerminalDeliveryError(
        `final message ${row.messageId} belongs to another session`,
      );
    }
    if (message.role !== "assistant") {
      throw new TerminalDeliveryError(
        `final message ${row.messageId} is not an assistant row`,
      );
    }

    // ---- 2. truthful terminal state: a run already terminalized as anything
    // other than 'completed' (stale sweep, cancel) must not gain a
    // run_completed after its own terminal event.
    const run = await runs.getById(deps.db, row.runId);
    if (run === null) {
      throw new TerminalDeliveryError(`run ${row.runId} is missing for its delivery intent`);
    }
    if (run.status !== "completed" && run.status !== "running" && run.status !== "queued") {
      throw new TerminalDeliveryError(
        `run ${row.runId} was terminalized as '${run.status}' before delivery`,
      );
    }

    // ---- 3. replay both terminal events, keyed by their stable identities.
    // The mirror is the durable proof that the event was observed; a miss may
    // append once more (documented residual: a crash between the Redis XADD
    // and the mirror write can duplicate one event, never a message row or a
    // push — the client dedupes by messageId/runId).
    const messageCompleted = await eventMirror.hasPayloadValue(
      deps.db,
      row.sessionId,
      "message_completed",
      "messageId",
      row.messageId,
    );
    if (!messageCompleted) {
      const event = await deps.events.append(row.sessionId, "message_completed", {
        messageId: row.messageId,
        content: message.content,
      });
      await eventMirror.put(deps.db, event);
    }

    const runCompleted = await eventMirror.hasPayloadValue(
      deps.db,
      row.sessionId,
      "run_completed",
      "runId",
      row.runId,
    );
    if (!runCompleted) {
      const event = await deps.events.append(
        row.sessionId,
        "run_completed",
        row.completionPayload,
      );
      await eventMirror.put(deps.db, event);
    }

    // ---- 4. terminal flip AFTER the events (the C1 ordering contract: the
    // next same-session run unblocks on the flip, so its run_started lands
    // strictly after this run_completed).
    const finished = await runs.finish(deps.db, row.runId, "completed");
    if (!finished) {
      const after = await runs.getById(deps.db, row.runId);
      if (after === null || after.status !== "completed") {
        throw new TerminalDeliveryError(
          `run ${row.runId} lost its terminal race (status '${after?.status ?? "missing"}')`,
        );
      }
    }

    // ---- 5. completion push: only a confirmed fan-out counts as delivered.
    // Scheduled runs use notifyScheduleSucceeded (the settle path), and a
    // composition without a notifier has nothing to push.
    if (row.scheduled || deps.notifier?.notifyAgentFinished === undefined) return;
    const outcome = await deps.notifier.notifyAgentFinished({
      userId: row.userId,
      runId: row.runId,
      sessionId: row.sessionId,
    });
    if (outcome === "retry") {
      throw new Error(`completion notification for run ${row.runId} reported retry`);
    }
  }

  // `deliver` (the agent-core port method) is wired to `deliverForRun` at the
  // return below, so a destructured call never depends on `this`.
  const delivery: Omit<FinalDelivery, "deliver"> = {
    async deliverForRun(input) {
      if (binding === undefined) {
        throw new Error("final delivery: no per-run binding (userId/scheduled)");
      }
      const recorded = await record(input, binding);
      const now = clock();
      // Claim BEFORE any side effect, exactly like the recovery path: a
      // scheduler tick scanning `pending` concurrently must not deliver the
      // same intent at the same time as this processor.
      const row = await runDeliveryOutboxRepo.claim(
        deps.db,
        recorded.outboxId,
        new Date(now.getTime() - FINAL_DELIVERY_LEASE_MS),
        now,
      );
      if (row === null) return; // already delivered, or another worker owns it
      try {
        await deliverRow(row);
      } catch (error) {
        if (error instanceof TerminalDeliveryError) {
          await runDeliveryOutboxRepo.markFailed(deps.db, row.outboxId, error, row.attempts, clock());
          return;
        }
        // Unknown outcome: the answer and the intent are committed, so a later
        // pass (this tick or after a restart) replays it. Swallow: a delivery
        // failure must never turn a finished run into a failed job.
        await runDeliveryOutboxRepo.markPending(deps.db, row.outboxId, error, row.attempts, clock());
        console.error("[run-delivery] final delivery left pending for retry", {
          runId: row.runId,
          err: errorText(error),
        });
        return;
      }
      await runDeliveryOutboxRepo.markDelivered(deps.db, row.outboxId, row.attempts, clock());
    },

    async deliverRow(row) {
      try {
        await deliverRow(row);
      } catch (error) {
        if (error instanceof TerminalDeliveryError) {
          await runDeliveryOutboxRepo.markFailed(deps.db, row.outboxId, error, row.attempts, clock());
          return;
        }
        await runDeliveryOutboxRepo.markPending(deps.db, row.outboxId, error, row.attempts, clock());
        throw error;
      }
      await runDeliveryOutboxRepo.markDelivered(deps.db, row.outboxId, row.attempts, clock());
    },

    async recover(opts) {
      const now = clock();
      const cutoff = new Date(now.getTime() - FINAL_DELIVERY_LEASE_MS);
      const due = await runDeliveryOutboxRepo.listDue(
        deps.db,
        opts?.limit ?? FINAL_DELIVERY_BATCH_LIMIT,
        cutoff,
      );
      const report = { delivered: 0, failed: 0, pending: 0 };
      for (const candidate of due) {
        // Single-writer claim: a live lease elsewhere (or a concurrent tick)
        // yields null and this item is skipped, never double-delivered.
        const row = await runDeliveryOutboxRepo.claim(deps.db, candidate.outboxId, cutoff, clock());
        if (row === null) continue;
        try {
          await deliverRow(row);
          await runDeliveryOutboxRepo.markDelivered(deps.db, row.outboxId, row.attempts, clock());
          report.delivered += 1;
        } catch (error) {
          if (error instanceof TerminalDeliveryError) {
            await runDeliveryOutboxRepo.markFailed(deps.db, row.outboxId, error, row.attempts, clock());
            report.failed += 1;
            continue;
          }
          // Per-item continuation: a poisoned row stays pending for the next
          // pass and never blocks the rest of the batch.
          await runDeliveryOutboxRepo.markPending(deps.db, row.outboxId, error, row.attempts, clock());
          report.pending += 1;
          console.error("[run-delivery] recovery item still pending", {
            runId: row.runId,
            err: errorText(error),
          });
        }
      }
      return report;
    },
  };

  return { ...delivery, deliver: (input) => delivery.deliverForRun(input) };
}
