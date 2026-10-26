import type { Db, Tx } from "@ovid/db";

/**
 * Next-run continuation for the Task 9 durable fold.
 *
 * `compactionRepos.foldCheckpoint` advances `compaction_cursors` and writes an
 * immutable `compaction_checkpoints` row, but the next run's request is built
 * by agent-core's loop from `session_agent_state.state.compaction` through
 * `applyCheckpoint` / `foldBoundaryFor`. Without a synchronizer the DB cursor
 * moves while the legacy replay state still points at the previous (or no)
 * checkpoint, so the next run re-sends folded history and can re-fold it.
 *
 * This module is the missing link. It is deliberately a separate, idempotent
 * step rather than part of the fold transaction:
 *
 *   - the fold transaction is the durable source of truth (checkpoint +
 *     cursor + exact history);
 *   - the legacy state is a derived projection of the cursor's current
 *     checkpoint;
 *   - a crash between the two is recoverable by `reconcile` /
 *     `recoverPendingCompactionContinuations`, which mirror the scheduler's
 *     bounded, per-item, idempotent settlement recovery
 *     (`schedulerTick.ts:330-351`).
 *
 * The projection is written with `ledger:null` on purpose: the legacy ledger
 * counts in-memory tool rows that are never persisted, so it must not be used
 * to index a durable window. `foldBoundaryFor` reads `cutoffMessageId` only.
 */

export interface CompactionContinuationActor {
  /** Fold scope: main session, or the worker's child session. */
  sessionId: string;
  rootTaskRunId: string;
  kind: "main" | "worker";
  logicalWorkerId: string | null;
  attemptId: string | null;
}

export interface CompactionContinuationInput {
  checkpointId: string;
  actor: CompactionContinuationActor;
}

export type CompactionContinuationStatus =
  | "applied"
  | "already_applied"
  | "superseded";

export interface CompactionContinuationResult {
  status: CompactionContinuationStatus;
  checkpointId: string;
  summary: string;
  cutoffMessageId: string;
  compactedAtCount: number;
}

export type CompactionContinuationErrorCode =
  | "checkpoint_not_found"
  | "checkpoint_scope_mismatch"
  | "checkpoint_not_syncable"
  | "continuation_cutoff_unprovable"
  | "continuation_scope_unprovable";

export class CompactionContinuationError extends Error {
  readonly name = "CompactionContinuationError";
  constructor(readonly code: CompactionContinuationErrorCode, message: string) {
    super(`${code}: ${message}`);
  }
}

export interface CompactionContinuation {
  /** Project one durable checkpoint into the legacy replay state. */
  sync(input: CompactionContinuationInput): Promise<CompactionContinuationResult>;
  /**
   * Recover the actor's current cursor checkpoint when the legacy state did
   * not get patched (crash between fold commit and synchronization). Returns
   * null when the actor has no cursor yet.
   */
  reconcile(actor: CompactionContinuationActor): Promise<CompactionContinuationResult | null>;
}

export interface CompactionContinuationReport {
  recovered: number;
  failed: number;
}

/** Bounded recovery batch, matching the scheduler's settlement recovery cap. */
const RECOVERY_BATCH_LIMIT = 50;

type PinnedSql = (
  strings: TemplateStringsArray,
  ...values: unknown[]
) => Promise<Array<Record<string, unknown>>>;

function txSql(tx: Tx): PinnedSql {
  return (tx as unknown as { session: { client: PinnedSql } }).session.client;
}

function actorIdOf(actor: CompactionContinuationActor): string {
  return actor.kind === "main" ? "main" : actor.logicalWorkerId ?? "";
}

function nonEmpty(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function countOf(value: unknown): number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : 0;
}

interface CheckpointRow {
  checkpointId: string;
  sessionId: string;
  summary: string | null;
  cutoffMessageId: string | null;
  ledgerVersion: number | null;
  rootTaskRunId: string;
  actorKind: string | null;
  actorId: string | null;
  logicalWorkerId: string | null;
  attemptId: string | null;
}

export function createCompactionContinuation(options: {
  db: Db;
  now?: () => Date;
}): CompactionContinuation {
  const db = options.db;
  const now = options.now ?? (() => new Date());

  async function sync(
    input: CompactionContinuationInput,
  ): Promise<CompactionContinuationResult> {
    const { actor } = input;
    if (
      !nonEmpty(actor.sessionId) ||
      !nonEmpty(actor.rootTaskRunId) ||
      (actor.kind === "worker" && !nonEmpty(actor.logicalWorkerId))
    ) {
      throw new CompactionContinuationError(
        "continuation_scope_unprovable",
        "a canonical main/worker actor scope is required",
      );
    }
    const at = now();
    if (!Number.isFinite(at.getTime())) {
      throw new CompactionContinuationError(
        "continuation_scope_unprovable",
        "a finite clock is required",
      );
    }

    return db.transaction(async (tx) => {
      const sql = txSql(tx);
      const rows = await sql`
        SELECT checkpoint_id AS "checkpointId", session_id AS "sessionId", summary,
               cutoff_message_id AS "cutoffMessageId",
               ledger_version AS "ledgerVersion",
               root_task_run_id AS "rootTaskRunId",
               actor_kind AS "actorKind", actor_id AS "actorId",
               logical_worker_id AS "logicalWorkerId",
               attempt_id AS "attemptId"
          FROM compaction_checkpoints
         WHERE checkpoint_id = ${input.checkpointId}
         FOR SHARE`;
      const checkpoint = rows[0] as unknown as CheckpointRow | undefined;
      if (checkpoint === undefined) {
        throw new CompactionContinuationError(
          "checkpoint_not_found",
          "the folded checkpoint does not exist",
        );
      }
      const expectedActorId = actorIdOf(actor);
      if (
        checkpoint.sessionId !== actor.sessionId ||
        checkpoint.rootTaskRunId !== actor.rootTaskRunId ||
        checkpoint.actorKind !== actor.kind ||
        checkpoint.actorId !== expectedActorId ||
        (checkpoint.logicalWorkerId ?? null) !== (actor.logicalWorkerId ?? null) ||
        (checkpoint.attemptId ?? null) !== (actor.attemptId ?? null)
      ) {
        throw new CompactionContinuationError(
          "checkpoint_scope_mismatch",
          "the checkpoint belongs to a different actor scope",
        );
      }
      if (!nonEmpty(checkpoint.summary) || checkpoint.ledgerVersion === null) {
        // Migration-backfilled legacy references carry no runtime summary.
        // They cannot drive a next-run replay; never invent one.
        throw new CompactionContinuationError(
          "checkpoint_not_syncable",
          "the checkpoint has no runtime summary to replay",
        );
      }
      if (!nonEmpty(checkpoint.cutoffMessageId)) {
        throw new CompactionContinuationError(
          "continuation_cutoff_unprovable",
          "the checkpoint has no durable cutoff message for legacy replay",
        );
      }
      // The cutoff row must still exist in the actor's session: a truncation or
      // deletion between fold and synchronization must fail closed rather than
      // project a boundary that can never match the rebuilt window.
      const cutoffRows = await sql`
        SELECT id FROM messages
         WHERE id = ${checkpoint.cutoffMessageId}
           AND session_id = ${actor.sessionId}
         LIMIT 1`;
      if (cutoffRows.length === 0) {
        throw new CompactionContinuationError(
          "continuation_cutoff_unprovable",
          "the checkpoint cutoff message is not in the actor session",
        );
      }

      const cursorRows = await sql`
        SELECT checkpoint_id AS "checkpointId", ledger_version AS "ledgerVersion"
          FROM compaction_cursors
         WHERE session_id = ${actor.sessionId}
           AND root_task_run_id = ${actor.rootTaskRunId}
           AND actor_kind = ${actor.kind}
           AND actor_id = ${expectedActorId}
         LIMIT 1`;
      const cursor = cursorRows[0] as
        | { checkpointId: string | null; ledgerVersion: number | null }
        | undefined;
      if (
        cursor !== undefined &&
        cursor.checkpointId !== null &&
        cursor.checkpointId !== input.checkpointId &&
        (cursor.ledgerVersion ?? 0) > checkpoint.ledgerVersion
      ) {
        // A later fold already governs this actor. Never regress the replay
        // boundary to an older checkpoint.
        return {
          status: "superseded" as const,
          checkpointId: input.checkpointId,
          summary: checkpoint.summary,
          cutoffMessageId: checkpoint.cutoffMessageId,
          compactedAtCount: 0,
        };
      }

      const stateRows = await sql`
        SELECT state->'compaction' AS compaction
          FROM session_agent_state
         WHERE session_id = ${actor.sessionId}
         FOR UPDATE`;
      const existing = stateRows[0]?.compaction as
        | { summary?: unknown; cutoffMessageId?: unknown; compactedAtCount?: unknown }
        | null
        | undefined;

      if (
        existing != null &&
        existing.summary === checkpoint.summary &&
        existing.cutoffMessageId === checkpoint.cutoffMessageId
      ) {
        return {
          status: "already_applied" as const,
          checkpointId: input.checkpointId,
          summary: checkpoint.summary,
          cutoffMessageId: checkpoint.cutoffMessageId,
          compactedAtCount: countOf(existing.compactedAtCount),
        };
      }

      const compactedAtCount = countOf(existing?.compactedAtCount) + 1;
      const projection = JSON.stringify({
        // `ledger` stays null: the durable window is indexed by cutoffMessageId.
        ledger: null,
        summary: checkpoint.summary,
        cutoffMessageId: checkpoint.cutoffMessageId,
        compactedAtCount,
      });
      await sql`
        INSERT INTO session_agent_state (session_id, state)
        VALUES (${actor.sessionId},
                jsonb_build_object('compaction', ${projection}::jsonb))
        ON CONFLICT (session_id) DO UPDATE
        SET state = COALESCE(session_agent_state.state, '{}'::jsonb)
                  || jsonb_build_object('compaction', ${projection}::jsonb)`;

      return {
        status: "applied" as const,
        checkpointId: input.checkpointId,
        summary: checkpoint.summary,
        cutoffMessageId: checkpoint.cutoffMessageId,
        compactedAtCount,
      };
    });
  }

  async function reconcile(
    actor: CompactionContinuationActor,
  ): Promise<CompactionContinuationResult | null> {
    const expectedActorId = actorIdOf(actor);
    const rows = await db.$client.unsafe(
      "SELECT checkpoint_id AS \"checkpointId\" FROM compaction_cursors " +
      "WHERE session_id = $1 AND root_task_run_id = $2 AND actor_kind = $3 AND actor_id = $4 LIMIT 1",
      [actor.sessionId, actor.rootTaskRunId, actor.kind, expectedActorId],
    ) as Array<{ checkpointId?: unknown }>;
    const checkpointId = rows[0]?.checkpointId;
    if (!nonEmpty(checkpointId)) return null;
    return sync({ checkpointId, actor });
  }

  return { sync, reconcile };
}

/**
 * Replay already-committed fold facts into the legacy replay state. This has no
 * provider call and no fold: it discovers cursors whose current checkpoint is
 * not reflected in `session_agent_state`, then projects them in bounded order.
 * Per-item failures stay pending for a later pass; repeated passes are
 * idempotent because `sync` compares summary/cutoff before writing.
 */
export async function recoverPendingCompactionContinuations(
  deps: { db: Db; now?: () => Date },
  opts?: { limit?: number },
): Promise<CompactionContinuationReport> {
  const continuation = createCompactionContinuation(deps);
  const rows = await deps.db.$client.unsafe(
    "SELECT c.session_id AS \"sessionId\", c.root_task_run_id AS \"rootTaskRunId\", " +
    "c.actor_kind AS \"actorKind\", c.actor_id AS \"actorId\", " +
    "c.logical_worker_id AS \"logicalWorkerId\", c.attempt_id AS \"attemptId\", " +
    "c.checkpoint_id AS \"checkpointId\" " +
    "FROM compaction_cursors c " +
    "JOIN compaction_checkpoints k ON k.checkpoint_id = c.checkpoint_id " +
    "LEFT JOIN session_agent_state s ON s.session_id = c.session_id " +
    "WHERE c.checkpoint_id IS NOT NULL " +
    "AND k.summary IS NOT NULL AND k.ledger_version IS NOT NULL " +
    "AND (s.state->'compaction' IS NULL " +
    "  OR s.state->'compaction'->>'cutoffMessageId' IS DISTINCT FROM k.cutoff_message_id " +
    "  OR s.state->'compaction'->>'summary' IS DISTINCT FROM k.summary) " +
    "ORDER BY c.updated_at, c.session_id " +
    "LIMIT $1",
    [opts?.limit ?? RECOVERY_BATCH_LIMIT],
  ) as Array<{
    sessionId: string;
    rootTaskRunId: string;
    actorKind: "main" | "worker";
    logicalWorkerId: string | null;
    attemptId: string | null;
    checkpointId: string;
  }>;

  let recovered = 0;
  let failed = 0;
  for (const row of rows) {
    try {
      await continuation.sync({
        checkpointId: row.checkpointId,
        actor: {
          sessionId: row.sessionId,
          rootTaskRunId: row.rootTaskRunId,
          kind: row.actorKind,
          logicalWorkerId: row.logicalWorkerId,
          attemptId: row.attemptId,
        },
      });
      recovered += 1;
    } catch (err) {
      failed += 1;
      console.error("[compaction] continuation recovery failed", {
        sessionId: row.sessionId,
        checkpointId: row.checkpointId,
        err,
      });
    }
  }
  return { recovered, failed };
}
