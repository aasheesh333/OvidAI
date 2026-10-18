/**
 * Durable PostgreSQL checkpoints — the TypeScript port of
 * `server/account/postgres.py`.
 *
 * The per-UID advisory lock is the SAME lock the rest of the cloud uses
 * (`@ovid/db`'s `withUidLock`, seed 714031), and it holds a DEDICATED pooled
 * connection for the whole critical section: returning a still-locked
 * connection to the pool could let unrelated requests share ownership.
 */

import { accountDeletions, withUidLock, type Db } from "@ovid/db";
import type {
  DeletionRow,
  DeletionSession,
  DeletionStore,
} from "./domain.js";

// Re-exported for consumers that reach the row shape through the store
// (store.test.ts imports it from here).
export type { DeletionRow } from "./domain.js";

export function createPostgresDeletionStore(db: Db): DeletionStore {
  return {
    locked<T>(uid: string, fn: (session: DeletionSession) => Promise<T>): Promise<T> {
      return withUidLock(db, uid, async (locked) => {
        const session: DeletionSession = {
          async get(id: string): Promise<DeletionRow | null> {
            const row = await accountDeletions.get(locked, id);
            if (row === null) return null;
            // The Python record jsonb contains the whole row (uid included).
            return { ...(row.record as unknown as DeletionRow), uid: row.uid };
          },
          async save(row: DeletionRow): Promise<void> {
            await accountDeletions.save(locked, {
              uid: row.uid,
              state: row.state,
              deleteAfter: row.delete_after,
              record: row as unknown as Record<string, unknown>,
            });
          },
        };
        return fn(session);
      });
    },

    due(now: number): Promise<string[]> {
      return accountDeletions.due(db, now);
    },
  };
}
