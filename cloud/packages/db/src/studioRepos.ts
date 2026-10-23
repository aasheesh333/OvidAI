import { and, eq } from "drizzle-orm";

import type { Db } from "./client.js";
import { studioRepos as studioReposTable } from "./schema.js";

/**
 * The Studio session → repository binding.
 *
 * One row per session. `repo` is the canonical `owner/name`; `repoDir` is
 * the workspace-relative folder the clone created; `branch` is the branch
 * the session is currently on. The row is the reason "change branch any
 * time" and "sync latest" can work after a reload — the client is not the
 * only place that remembers the clone.
 *
 * Every read is owner-scoped: a session id alone is not authority. Wrong
 * owner and unknown session are indistinguishable (null).
 */
export interface StudioRepoBinding {
  sessionId: string;
  userId: string;
  repo: string;
  repoDir: string;
  branch: string;
  createdAt: Date;
  updatedAt: Date;
}

export interface StudioRepoUpsert {
  sessionId: string;
  userId: string;
  repo: string;
  repoDir: string;
  branch: string;
}

function project(row: typeof studioReposTable.$inferSelect): StudioRepoBinding {
  return {
    sessionId: row.sessionId,
    userId: row.userId,
    repo: row.repo,
    repoDir: row.repoDir,
    branch: row.branch,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  };
}

export const studioRepos = {
  /** The caller's binding for a session, or null (unknown OR not theirs). */
  async get(db: Db, userId: string, sessionId: string): Promise<StudioRepoBinding | null> {
    const [row] = await db
      .select()
      .from(studioReposTable)
      .where(
        and(eq(studioReposTable.userId, userId), eq(studioReposTable.sessionId, sessionId)),
      )
      .limit(1);
    return row === undefined ? null : project(row);
  },

  /**
   * Insert or replace the session's binding. A session has at most one repo,
   * so a second clone onto the same session replaces the binding rather than
   * accumulating rows.
   *
   * The update arm is owner-scoped: a conflicting row owned by somebody else
   * is left untouched and the call answers null, which the route treats as a
   * failure. (The route also checks session ownership first — this is the
   * second lock, not the only one.)
   */
  async upsert(db: Db, input: StudioRepoUpsert): Promise<StudioRepoBinding | null> {
    const [row] = await db
      .insert(studioReposTable)
      .values({
        sessionId: input.sessionId,
        userId: input.userId,
        repo: input.repo,
        repoDir: input.repoDir,
        branch: input.branch,
      })
      .onConflictDoUpdate({
        target: studioReposTable.sessionId,
        set: {
          repo: input.repo,
          repoDir: input.repoDir,
          branch: input.branch,
          updatedAt: new Date(),
        },
        setWhere: eq(studioReposTable.userId, input.userId),
      })
      .returning();
    return row === undefined ? null : project(row);
  },

  /** True iff a binding existed for this owner + session. */
  async remove(db: Db, userId: string, sessionId: string): Promise<boolean> {
    const rows = await db
      .delete(studioReposTable)
      .where(
        and(eq(studioReposTable.userId, userId), eq(studioReposTable.sessionId, sessionId)),
      )
      .returning({ sessionId: studioReposTable.sessionId });
    return rows.length > 0;
  },
};
