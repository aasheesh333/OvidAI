import type { Db } from "./client.js";

/**
 * The SQL behind the two destructive settings actions.
 *
 * Both are bulk deletes, so this module is deliberately explicit rather than
 * clever:
 *
 *   - EVERY statement is scoped by `user_id = uid` (or by a sub-select that
 *     is). There is no table-wide delete in this file, and there must never
 *     be one: the caller is an ordinary signed-in account, not an operator.
 *   - `deleteAllData` runs in ONE transaction and removes session-owned rows
 *     before the sessions themselves, so foreign keys can never block a
 *     half-finished run.
 *   - `resetAllMemory` touches `private_memory_files` only. It is one
 *     statement and is naturally idempotent.
 *
 * The route (not this module) owns confirmation, byte deletion and the HTTP
 * contract. Keeping the SQL here makes the uid predicate auditable in one
 * place.
 */

export interface DeleteAllDataCounts {
  /** Chat rows removed. */
  sessions: number;
  /** Uploaded files removed (their bytes are deleted by the route). */
  attachments: number;
  /** Ovid-generated artifacts removed (`workspace_objects.kind = 'artifact'`). */
  artifacts: number;
  /** Workspace archive + manifest rows removed (their bytes too). */
  workspaceFiles: number;
}

type Row = Record<string, unknown>;

function rows<T extends Row>(result: unknown): T[] {
  return result as T[];
}

export const dataControlRepo = {
  /**
   * The account's registered email, read from the row the server wrote — NOT
   * from a client-supplied field. Null means there is nothing to confirm
   * against (the route refuses rather than guessing).
   */
  async registeredEmail(db: Db, uid: string): Promise<string | null> {
    const found = rows<{ email: string | null }>(
      await db.$client`SELECT email FROM users WHERE uid = ${uid}`,
    );
    const email = found[0]?.email;
    return typeof email === "string" && email.trim() !== "" ? email : null;
  },

  /**
   * Every object-storage key this account's rows reference — uploads and
   * generated artifacts/workspace archives alike. Only rows are read here;
   * nothing is deleted.
   *
   * Deduplicated because an artifact's key is globally unique per row, but a
   * defensive set keeps the route from deleting the same object twice.
   */
  async ownedStorageKeys(db: Db, uid: string): Promise<string[]> {
    const found = rows<{ key: string }>(await db.$client`
      SELECT r2_key AS key FROM attachments WHERE user_id = ${uid}
      UNION
      SELECT r2_key AS key FROM workspace_objects WHERE user_id = ${uid}
    `);
    return [
      ...new Set(
        found
          .map((row) => row.key)
          .filter((key): key is string => typeof key === "string" && key !== ""),
      ),
    ];
  },

  /**
   * Remove every chat the account owns and everything that belongs to a chat.
   *
   * FK-safe order: schedule occurrences, schedules, grants, uploads, event
   * mirrors, agent state, compaction rows, messages, runs, workspace manifests
   * and objects, session-scoped memory, then the sessions themselves.
   *
   * Projects are NOT deleted: a project is a folder, not a chat, and its
   * memory survives here — that is what "Reset all memory" is for. The shared
   * (global) memory file also survives for the same reason.
   */
  async deleteAllData(db: Db, uid: string): Promise<DeleteAllDataCounts> {
    return db.$client.begin(async (tx) => {
      // schedule_runs.schedule_id cascades, but delete explicitly so the
      // result never depends on the migration that added the constraint.
      await tx`DELETE FROM schedule_runs WHERE schedule_id IN (SELECT id FROM schedules WHERE user_id = ${uid})`;
      await tx`DELETE FROM schedules WHERE user_id = ${uid}`;
      await tx`DELETE FROM grants WHERE user_id = ${uid}`;
      const attachments = rows<{ id: string }>(
        await tx`DELETE FROM attachments WHERE user_id = ${uid} RETURNING id`,
      );
      await tx`DELETE FROM session_event_mirror WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
      await tx`DELETE FROM session_agent_state WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
      // 0039 rows reference canonical runs and 0034 workers/attempts with NO
      // ACTION. Cursors also reference checkpoints, so they must go first.
      // Exact history is removed only through this account's owned sessions.
      await tx`DELETE FROM compaction_cursors WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
      await tx`DELETE FROM compaction_history_items WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
      await tx`DELETE FROM compaction_checkpoints WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
      // 0034 leaves reference other lineage rows as well as canonical runs and
      // messages. Remove the whole descendant graph before either authority.
      await tx`DELETE FROM subagent_control_audit WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
      await tx`DELETE FROM subagent_reports WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
      await tx`DELETE FROM subagent_checkpoints WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
      await tx`DELETE FROM subagent_root_finalizations WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
      await tx`DELETE FROM subagent_attempts WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
      await tx`DELETE FROM subagent_logical_workers WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
      await tx`DELETE FROM subagent_dispatches WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
      await tx`DELETE FROM subagent_batches WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
      await tx`DELETE FROM subagent_roots WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
      await tx`DELETE FROM subagent_session_admission WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
      // 0033 response/version CAS rows precede their request; outbox precedes
      // the canonical message/run it links. All predicates remain uid-scoped.
      await tx`DELETE FROM system_request_responses WHERE request_id IN (SELECT request_id FROM system_requests WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid}))`;
      await tx`DELETE FROM system_requests WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
      await tx`DELETE FROM run_outbox WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
      await tx`DELETE FROM messages WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
      await tx`DELETE FROM runs WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ${uid})`;
      await tx`DELETE FROM file_manifests WHERE user_id = ${uid}`;
      const objects = rows<{ kind: string }>(
        await tx`DELETE FROM workspace_objects WHERE user_id = ${uid} RETURNING kind`,
      );
      // Session-scoped memory only. `project:<uuid>` and `shared` rows are
      // left for resetAllMemory, so "delete all data" cannot quietly wipe a
      // project's memory the user did not ask to clear.
      await tx`DELETE FROM private_memory_files WHERE user_id = ${uid} AND session_id IS NOT NULL`;
      const sessions = rows<{ id: string }>(
        await tx`DELETE FROM sessions WHERE user_id = ${uid} RETURNING id`,
      );

      const artifacts = objects.filter((row) => row.kind === "artifact").length;
      return {
        sessions: sessions.length,
        attachments: attachments.length,
        artifacts,
        workspaceFiles: objects.length - artifacts,
      } satisfies DeleteAllDataCounts;
    });
  },

  /**
   * Remove every memory file the account owns: chat scopes, project scopes
   * and the shared (global) scope. Returns the number of files removed, so a
   * second call honestly reports 0.
   */
  async resetAllMemory(db: Db, uid: string): Promise<number> {
    const removed = rows<{ name: string }>(
      await db.$client`DELETE FROM private_memory_files WHERE user_id = ${uid} RETURNING name`,
    );
    return removed.length;
  },
};
