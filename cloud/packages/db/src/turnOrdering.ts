// Current-turn ordering (A1/A2) — the durable, dependency-closed primitive
// the run loop lacks: a per-session monotonic turn sequence, an ordered claim,
// an idempotent/fenced Stop, and crash recovery re-derived from rows only.
//
// WHAT A "TURN" IS. A turn is one `runs` row: the gateway persists the user
// prompt message first and then the run that consumes it (messages.ts). The
// product already relies on that pairing (steering.ts merges queued runs into
// the active one), so this module does not invent a second turn table — it
// gives the existing rows the ordering identity they never had.
//
// WHY `seq` IS DERIVED, NOT STORED. A1/A2 may not add a schema column or a
// migration, and a memory counter cannot survive a restart. `seq` is therefore
// the turn's 1-based ordinal among the session's runs ordered by
// (created_at, id) — a pure function of durable rows. `admitTurn` makes that
// ordering *admission* ordering by inserting under a per-session advisory
// transaction lock with `created_at = GREATEST(clock_timestamp(),
// max(created_at) + 1µs)`, so no two turns of one session can tie or invert,
// even if the database clock steps backwards. Every run producer (gateway
// send, scheduler tick, "run now") admits through this module and therefore
// serializes on the same lock. `runs.create` still exists as a lower-level
// primitive; a caller that used it would get a deterministic ordinal
// (`defaultNow()` is transaction-start time), just not a guaranteed
// admission-order one.
//
// FENCES. All mutations take `pg_advisory_xact_lock` on the session and then
// `SELECT … FOR UPDATE` the session's runs, so admission, claim, Stop and
// recovery are serialized per session. Stop is fenced by the exact run id and,
// when supplied, the derived `seq`: a delayed Stop for turn N can never touch
// turn N+1, because it only ever writes the turn it names (and, when the
// caller explicitly asks, that turn's already-accepted successors).
//
// FAIL-CLOSED. Ambiguous durable state (two running turns, a running turn
// behind a queued one, an active turn whose prompt row is gone) is reported as
// `ambiguous` with the observed turns and NO mutation. Recovery never guesses.

import { sql } from "drizzle-orm";

import type { Db } from "./client.js";
import { newId } from "./repos.js";

export type TurnStatus = "queued" | "running" | "completed" | "failed" | "cancelled";

/** One durable turn: a `runs` row plus its derived per-session ordinal. */
export interface TurnRecord {
  runId: string;
  /** 1-based, gap-free within the session, ordered by (createdAt, runId). */
  seq: number;
  status: TurnStatus;
  cancelRequested: boolean;
  promptMessageId: string | null;
  /** Whether the prompt message row still exists (recovery precondition). */
  promptPresent: boolean;
  createdAt: Date;
  startedAt: Date | null;
  finishedAt: Date | null;
}

/** Admission could not be proven safe; nothing was written. */
export class TurnOrderingError extends Error {
  constructor(
    readonly code: "prompt_missing" | "prompt_already_has_run_in_other_session",
    message: string,
  ) {
    super(message);
    this.name = "TurnOrderingError";
  }
}

type Tx = Parameters<Parameters<Db["transaction"]>[0]>[0];
/** Both `Db` and its transaction expose this shape; the module only runs SQL. */
type Executor = { execute(query: ReturnType<typeof sql>): Promise<unknown> };

interface RawTurnRow {
  run_id: string;
  status: string;
  cancel_requested: boolean;
  prompt_message_id: string | null;
  prompt_present: boolean;
  /** Raw `db.execute` rows carry timestamps as strings, not Date objects. */
  created_at: Date | string;
  started_at: Date | string | null;
  finished_at: Date | string | null;
}

function asDate(value: Date | string): Date {
  return value instanceof Date ? value : new Date(value);
}

const ACTIVE = new Set<TurnStatus>(["queued", "running"]);

function isActive(status: TurnStatus): boolean {
  return ACTIVE.has(status);
}

function isTerminal(status: TurnStatus): boolean {
  return !isActive(status);
}

function asStatus(value: string): TurnStatus {
  if (
    value === "queued" ||
    value === "running" ||
    value === "completed" ||
    value === "failed" ||
    value === "cancelled"
  ) {
    return value;
  }
  // A status outside the schema's documented union is not a turn we can order
  // truthfully. Surface it instead of silently mapping it to "queued".
  throw new Error(`turn ordering: unknown run status: ${value}`);
}

const TURN_COLUMNS = sql`
  r.id AS run_id,
  r.status,
  r.cancel_requested,
  r.prompt_message_id,
  EXISTS (SELECT 1 FROM messages m WHERE m.id = r.prompt_message_id) AS prompt_present,
  r.created_at,
  r.started_at,
  r.finished_at
`;

async function lockSession(tx: Tx, sessionId: string): Promise<void> {
  await tx.execute(
    sql`SELECT pg_advisory_xact_lock(hashtextextended(${`turn-ordering:${sessionId}`}, 0))`,
  );
}

/**
 * Read the session's turns in canonical order. One statement, so the result is
 * a consistent snapshot even without a transaction. `forUpdate` additionally
 * locks every run row (mutation paths only).
 */
async function loadTurns(
  executor: Executor,
  sessionId: string,
  forUpdate: boolean,
): Promise<TurnRecord[]> {
  const rows = (await executor.execute(sql`
    SELECT ${TURN_COLUMNS}
    FROM runs r
    WHERE r.session_id = ${sessionId}
    ORDER BY r.created_at, r.id
    ${forUpdate ? sql`FOR UPDATE OF r` : sql``}
  `)) as unknown as RawTurnRow[];
  return rows.map((row, index) => ({
    runId: row.run_id,
    seq: index + 1,
    status: asStatus(row.status),
    cancelRequested: row.cancel_requested,
    promptMessageId: row.prompt_message_id,
    promptPresent: row.prompt_present,
    createdAt: asDate(row.created_at),
    startedAt: row.started_at === null ? null : asDate(row.started_at),
    finishedAt: row.finished_at === null ? null : asDate(row.finished_at),
  }));
}

/** The session's turns in canonical order, with their derived sequence. */
export async function listTurns(db: Db, sessionId: string): Promise<TurnRecord[]> {
  return loadTurns(db, sessionId, false);
}

/**
 * Admit one accepted turn and assign it the session's next sequence.
 *
 * - The prompt message must belong to the session (fail closed otherwise).
 * - Re-admitting the same prompt is a replay: it returns the existing turn
 *   instead of creating a second run for one prompt.
 * - The inserted `created_at` is strictly greater than every earlier turn of
 *   the session, so `seq` equals admission order and survives a restart.
 */
export async function admitTurn(
  db: Db,
  input: { sessionId: string; promptMessageId: string },
): Promise<TurnRecord> {
  return db.transaction(async (tx) => {
    await lockSession(tx, input.sessionId);

    const existing = (await tx.execute(sql`
      SELECT r.id, r.session_id
      FROM runs r
      WHERE r.prompt_message_id = ${input.promptMessageId}
      ORDER BY r.created_at, r.id
      LIMIT 1
    `)) as unknown as Array<{ id: string; session_id: string }>;
    const replay = existing[0];
    if (replay !== undefined) {
      if (replay.session_id !== input.sessionId) {
        throw new TurnOrderingError(
          "prompt_already_has_run_in_other_session",
          "This prompt already belongs to a run in another session.",
        );
      }
      const turns = await loadTurns(tx, input.sessionId, false);
      const found = turns.find((turn) => turn.runId === replay.id);
      if (found === undefined) {
        throw new TurnOrderingError("prompt_missing", "The replayed run is not visible in its session.");
      }
      return found;
    }

    const prompt = (await tx.execute(sql`
      SELECT m.id
      FROM messages m
      WHERE m.id = ${input.promptMessageId} AND m.session_id = ${input.sessionId}
      LIMIT 1
    `)) as unknown as Array<{ id: string }>;
    if (prompt.length === 0) {
      throw new TurnOrderingError(
        "prompt_missing",
        "The prompt message does not exist in this session; no turn was admitted.",
      );
    }

    const runId = newId();
    const inserted = (await tx.execute(sql`
      INSERT INTO runs (id, session_id, status, prompt_message_id, created_at)
      SELECT
        ${runId},
        ${input.sessionId},
        'queued',
        ${input.promptMessageId},
        GREATEST(
          clock_timestamp(),
          COALESCE(
            (SELECT max(created_at) + interval '1 microsecond'
               FROM runs
              WHERE session_id = ${input.sessionId}),
            clock_timestamp()
          )
        )
      RETURNING id
    `)) as unknown as Array<{ id: string }>;
    if (inserted.length === 0) {
      throw new TurnOrderingError("prompt_missing", "Turn admission wrote no run row.");
    }

    const turns = await loadTurns(tx, input.sessionId, false);
    const turn = turns.find((candidate) => candidate.runId === runId);
    if (turn === undefined) {
      throw new TurnOrderingError("prompt_missing", "The admitted turn is not visible in its session.");
    }
    return turn;
  });
}

export type ClaimTurnResult =
  | { kind: "claimed"; turn: TurnRecord }
  | { kind: "already_running"; turn: TurnRecord }
  | { kind: "terminal"; turn: TurnRecord }
  | { kind: "cancelled"; turn: TurnRecord }
  | { kind: "not_oldest"; turn: TurnRecord; blocking: TurnRecord }
  | {
      kind: "ambiguous";
      reason: "multiple_running" | "newer_turn_running";
      turns: TurnRecord[];
    }
  | { kind: "unknown" };

/**
 * Claim one turn for execution (queued → running).
 *
 * A claim is granted only when the requested turn is still queued, not
 * cancel-requested, the oldest active turn of its session, and no other turn
 * of the session is already running. A queued successor is never executed
 * ahead of an older accepted turn, and a turn carrying a durable Stop flag is
 * never executed at all (`cancelled` — the caller emits and terminalizes it).
 */
export async function claimTurn(
  db: Db,
  input: { sessionId: string; runId: string },
): Promise<ClaimTurnResult> {
  return db.transaction(async (tx) => {
    await lockSession(tx, input.sessionId);
    const turns = await loadTurns(tx, input.sessionId, true);
    const turn = turns.find((candidate) => candidate.runId === input.runId);
    if (turn === undefined) return { kind: "unknown" };

    const running = turns.filter((candidate) => candidate.status === "running");
    if (running.length > 1) {
      return { kind: "ambiguous", reason: "multiple_running", turns };
    }
    if (turn.status === "running") return { kind: "already_running", turn };
    if (isTerminal(turn.status)) return { kind: "terminal", turn };
    if (turn.cancelRequested) return { kind: "cancelled", turn };

    const blocking = turns.find(
      (candidate) => candidate.seq < turn.seq && isActive(candidate.status),
    );
    if (blocking !== undefined) return { kind: "not_oldest", turn, blocking };
    if (running.length === 1) {
      // No earlier active turn exists, so the running one is a successor:
      // the queue executed out of order. Fail closed rather than interleave.
      return { kind: "ambiguous", reason: "newer_turn_running", turns };
    }

    const claimed = (await tx.execute(sql`
      UPDATE runs
         SET status = 'running', started_at = clock_timestamp()
       WHERE id = ${turn.runId} AND status = 'queued'
      RETURNING id
    `)) as unknown as Array<{ id: string }>;
    if (claimed.length === 0) {
      // A writer outside this module (a direct `runs.claimNext`) won the row
      // between our read and write. Re-derive instead of guessing.
      const after = await loadTurns(tx, input.sessionId, false);
      const current = after.find((candidate) => candidate.runId === input.runId);
      if (current === undefined) return { kind: "unknown" };
      if (current.status === "running") return { kind: "already_running", turn: current };
      return { kind: "terminal", turn: current };
    }

    const after = await loadTurns(tx, input.sessionId, false);
    const claimedTurn = after.find((candidate) => candidate.runId === turn.runId);
    if (claimedTurn === undefined) {
      // The row we just claimed is no longer visible (deleted concurrently).
      // Report the truth instead of returning `undefined` as a turn.
      return { kind: "unknown" };
    }
    return { kind: "claimed", turn: claimedTurn };
  });
}

export type ClaimSteerTurnResult =
  | { kind: "claimed"; turn: TurnRecord }
  | { kind: "stopped"; active: TurnRecord }
  | { kind: "cancelled"; turn: TurnRecord }
  | { kind: "not_next"; turn: TurnRecord; next: TurnRecord | null }
  | { kind: "not_active"; active: TurnRecord }
  | { kind: "unknown" };

/**
 * Claim the next queued turn for steering into an already-active turn.
 *
 * Unlike `claimTurn`, the active turn is allowed to be running (it is the
 * absorber), and the candidate is the OLDEST queued turn accepted after it —
 * never a later one. A Stop on the active turn closes steering immediately
 * (`stopped`), and a cancel-requested candidate is never merged (`cancelled`).
 */
export async function claimSteerTurn(
  db: Db,
  input: { sessionId: string; activeRunId: string; runId: string },
): Promise<ClaimSteerTurnResult> {
  return db.transaction(async (tx) => {
    await lockSession(tx, input.sessionId);
    const turns = await loadTurns(tx, input.sessionId, true);

    const active = turns.find((candidate) => candidate.runId === input.activeRunId);
    if (active === undefined) return { kind: "unknown" };
    const oldestActive = turns.find((candidate) => isActive(candidate.status));
    if (oldestActive === undefined || oldestActive.runId !== active.runId) {
      return { kind: "not_active", active };
    }
    if (active.cancelRequested) return { kind: "stopped", active };

    const next =
      turns.find(
        (candidate) =>
          candidate.status === "queued" && candidate.seq > active.seq,
      ) ?? null;
    const candidate = turns.find((turn) => turn.runId === input.runId);
    if (candidate === undefined) return { kind: "unknown" };
    if (candidate.status !== "queued") return { kind: "not_next", turn: candidate, next };
    if (candidate.cancelRequested) return { kind: "cancelled", turn: candidate };
    if (next === null || next.runId !== candidate.runId) {
      return { kind: "not_next", turn: candidate, next };
    }

    const claimed = (await tx.execute(sql`
      UPDATE runs
         SET status = 'running', started_at = clock_timestamp()
       WHERE id = ${candidate.runId} AND status = 'queued'
      RETURNING id
    `)) as unknown as Array<{ id: string }>;
    if (claimed.length === 0) {
      const after = await loadTurns(tx, input.sessionId, false);
      const current = after.find((turn) => turn.runId === candidate.runId);
      return current === undefined
        ? { kind: "unknown" }
        : { kind: "not_next", turn: current, next: null };
    }

    const after = await loadTurns(tx, input.sessionId, false);
    const claimedTurn = after.find((turn) => turn.runId === candidate.runId);
    if (claimedTurn === undefined) {
      // The row we just claimed is no longer visible (deleted concurrently).
      // Report the truth instead of returning `undefined` as a turn.
      return { kind: "unknown" };
    }
    return { kind: "claimed", turn: claimedTurn };
  });
}

export type StopTurnResult =
  | { kind: "stopped"; turn: TurnRecord; flagged: TurnRecord[] }
  | { kind: "already_requested"; turn: TurnRecord; flagged: TurnRecord[] }
  | { kind: "already_stopped"; turn: TurnRecord }
  | { kind: "not_active"; turn: TurnRecord }
  | { kind: "stale"; turn: TurnRecord; reason: "sequence_mismatch" }
  | { kind: "unknown" }
  | { kind: "ambiguous"; reason: "multiple_running"; turns: TurnRecord[] };

/**
 * Request Stop on exactly one durable turn.
 *
 * Idempotent: the second call reports `already_requested`, and once the worker
 * has terminalized the turn the third reports `already_stopped` — neither
 * mutates anything. Fenced: a Stop naming a turn that already finished
 * (`not_active`/`already_stopped`) or whose derived sequence disagrees with
 * the caller's view (`stale`) writes nothing, so a delayed Stop cannot cancel
 * a newer turn. `cancelQueuedSuccessors` is opt-in and only flags turns that
 * were already accepted before the Stop (higher seq, still active); it never
 * flips their status, so their own waiter/delivery keeps owning the
 * event-first terminal transition.
 */
export async function stopTurn(
  db: Db,
  input: {
    sessionId: string;
    expectedRunId: string;
    expectedSeq?: number;
    cancelQueuedSuccessors?: boolean;
  },
): Promise<StopTurnResult> {
  return db.transaction(async (tx) => {
    await lockSession(tx, input.sessionId);
    const turns = await loadTurns(tx, input.sessionId, true);
    const running = turns.filter((candidate) => candidate.status === "running");
    if (running.length > 1) {
      return { kind: "ambiguous", reason: "multiple_running", turns };
    }

    const turn = turns.find((candidate) => candidate.runId === input.expectedRunId);
    if (turn === undefined) return { kind: "unknown" };
    if (input.expectedSeq !== undefined && input.expectedSeq !== turn.seq) {
      return { kind: "stale", turn, reason: "sequence_mismatch" };
    }
    if (isTerminal(turn.status)) {
      return turn.status === "cancelled"
        ? { kind: "already_stopped", turn }
        : { kind: "not_active", turn };
    }

    const targets =
      input.cancelQueuedSuccessors === true
        ? turns.filter(
            (candidate) => isActive(candidate.status) && candidate.seq >= turn.seq,
          )
        : [turn];
    const newlyFlagged = targets.filter((candidate) => !candidate.cancelRequested);
    if (newlyFlagged.length > 0) {
      await tx.execute(sql`
        UPDATE runs
           SET cancel_requested = true
         WHERE status IN ('queued', 'running')
           AND id IN (${sql.join(
             newlyFlagged.map((candidate) => sql`${candidate.runId}`),
             sql`, `,
           )})
      `);
    }

    const after = await loadTurns(tx, input.sessionId, false);
    const updated = after.find((candidate) => candidate.runId === turn.runId);
    if (updated === undefined) {
      // Deleted between the flag write and the re-read: nothing truthful to
      // report as stopped, so fail closed instead of returning `undefined`.
      return { kind: "unknown" };
    }
    const flagged = after.filter(
      (candidate) =>
        targets.some((target) => target.runId === candidate.runId) &&
        candidate.cancelRequested,
    );
    return newlyFlagged.length > 0
      ? { kind: "stopped", turn: updated, flagged }
      : { kind: "already_requested", turn: updated, flagged };
  });
}

export type RecoverTurnResult =
  | { kind: "none"; turns: TurnRecord[] }
  | { kind: "in_flight"; turn: TurnRecord; queued: TurnRecord[]; turns: TurnRecord[] }
  | { kind: "pending"; turn: TurnRecord; queued: TurnRecord[]; turns: TurnRecord[] }
  | {
      kind: "ambiguous";
      reason: "multiple_running" | "running_behind_queued" | "missing_prompt";
      turns: TurnRecord[];
    };

/**
 * Re-derive the turn a restarted process must account for, from durable rows
 * only. `in_flight` means one running turn is the session's oldest active
 * turn; `pending` means the oldest active turn is still queued (its delivery
 * was lost). Everything else that cannot be proven (`multiple_running`,
 * `running_behind_queued`, `missing_prompt`) is `ambiguous` — the caller must
 * not pick a winner.
 */
export async function recoverInFlightTurn(
  db: Db,
  sessionId: string,
): Promise<RecoverTurnResult> {
  const turns = await listTurns(db, sessionId);
  const active = turns.filter((turn) => isActive(turn.status));
  if (active.length === 0) return { kind: "none", turns };

  const running = turns.filter((turn) => turn.status === "running");
  if (running.length > 1) return { kind: "ambiguous", reason: "multiple_running", turns };
  if (active.some((turn) => !turn.promptPresent)) {
    return { kind: "ambiguous", reason: "missing_prompt", turns };
  }

  const head = active[0]!;
  if (running.length === 1) {
    if (running[0]!.runId !== head.runId) {
      return { kind: "ambiguous", reason: "running_behind_queued", turns };
    }
    return { kind: "in_flight", turn: head, queued: active.slice(1), turns };
  }
  return { kind: "pending", turn: head, queued: active.slice(1), turns };
}

export type ResumeTurnResult =
  | { kind: "resumed"; turn: TurnRecord }
  | { kind: "not_head"; turn: TurnRecord }
  | { kind: "not_running"; turn: TurnRecord }
  | { kind: "cancelled"; turn: TurnRecord }
  | { kind: "stale"; turn: TurnRecord; reason: "sequence_mismatch" }
  | { kind: "unknown" }
  | { kind: "ambiguous"; reason: "multiple_running" | "missing_prompt"; turns: TurnRecord[] };

/**
 * Adopt an in-flight turn after a crash (the action half of recovery).
 *
 * No row is inserted, so replay cannot duplicate the turn; the turn must still
 * be the unique running head of its session and must not carry a Stop flag.
 * The heartbeat is refreshed so the stale sweeper does not mistake the
 * adopted turn for a corpse. Idempotent: calling it again resumes the same
 * turn.
 */
export async function resumeTurn(
  db: Db,
  input: { sessionId: string; expectedRunId: string; expectedSeq?: number },
): Promise<ResumeTurnResult> {
  return db.transaction(async (tx) => {
    await lockSession(tx, input.sessionId);
    const turns = await loadTurns(tx, input.sessionId, true);
    const turn = turns.find((candidate) => candidate.runId === input.expectedRunId);
    if (turn === undefined) return { kind: "unknown" };
    if (input.expectedSeq !== undefined && input.expectedSeq !== turn.seq) {
      return { kind: "stale", turn, reason: "sequence_mismatch" };
    }
    const running = turns.filter((candidate) => candidate.status === "running");
    if (running.length > 1) {
      return { kind: "ambiguous", reason: "multiple_running", turns };
    }
    const head = turns.find((candidate) => isActive(candidate.status));
    if (head === undefined || head.runId !== turn.runId) return { kind: "not_head", turn };
    if (turn.status !== "running") return { kind: "not_running", turn };
    if (turn.cancelRequested) return { kind: "cancelled", turn };
    if (!turn.promptPresent) return { kind: "ambiguous", reason: "missing_prompt", turns };

    await tx.execute(
      sql`UPDATE runs SET last_active_at = clock_timestamp() WHERE id = ${turn.runId}`,
    );
    const after = await loadTurns(tx, input.sessionId, false);
    const resumed = after.find((candidate) => candidate.runId === turn.runId);
    if (resumed === undefined) {
      // The resumed row vanished between the heartbeat write and the re-read.
      return { kind: "unknown" };
    }
    return { kind: "resumed", turn: resumed };
  });
}

/**
 * Repository-style facade, so a caller that owns the send path can be unit
 * tested at a repository boundary (the same shape as `runs`/`messages`).
 * Behaviour is identical to the standalone functions above.
 */
export const turns = {
  list: listTurns,
  admit: admitTurn,
  claim: claimTurn,
  claimSteer: claimSteerTurn,
  stop: stopTurn,
  recover: recoverInFlightTurn,
  resume: resumeTurn,
};
