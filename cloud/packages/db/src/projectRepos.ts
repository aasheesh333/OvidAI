import { and, asc, eq, isNull, sql } from "drizzle-orm";
import { uuidv7 } from "uuidv7";
import type { Db } from "./client.js";
import {
  plans as plansTable,
  projects as projectsTable,
  sessions as sessionsTable,
  users as usersTable,
  type ProjectRow,
  type SessionRow,
} from "./schema.js";

/** Typed project failures; routes map them to the standard error envelope. */
export class ProjectError extends Error {
  constructor(
    readonly code: "not_found" | "name_taken" | "bad_request",
    message: string,
  ) {
    super(message);
    this.name = "ProjectError";
  }
}

export interface ProjectSummary extends ProjectRow {
  sessionCount: number;
  fileCount: number;
  /** Plan-derived per-project memory-file cap (owner spec §3 Screen 4). */
  fileCap: number;
}

/**
 * Per-project memory-file caps by plan. The VALUES are the owner spec's
 * (Free 80 / Go 100 / Plus 150 / Pro 250); the PLAN LIST is not duplicated —
 * plans are read live from the server plan table and ordered by `position`,
 * so W5's Free/Go/Plus/Pro rows map correctly without touching this file.
 */
export const PROJECT_FILE_CAPS = [80, 100, 150, 250] as const;
export const MAX_PROJECT_NAME_LENGTH = 80;

function cleanName(name: string): string {
  const trimmed = name.trim();
  if (trimmed === "" || trimmed.length > MAX_PROJECT_NAME_LENGTH) {
    throw new ProjectError("bad_request", `Project names must be 1–${MAX_PROJECT_NAME_LENGTH} characters.`);
  }
  return trimmed;
}

function isUniqueViolation(err: unknown): boolean {
  if (typeof err !== "object" || err === null) return false;
  const e = err as { code?: unknown; cause?: unknown };
  // Drizzle wraps driver errors (`DrizzleQueryError.cause` holds the
  // PostgresError); check both levels.
  if (e.code === "23505") return true;
  return e.cause !== undefined && isUniqueViolation(e.cause);
}

export const projectsRepo = {
  /** Owner-scoped list, oldest first, with live session and memory-file counts. */
  async list(db: Db, uid: string): Promise<ProjectSummary[]> {
    const rows = await db
      .select({
        id: projectsTable.id,
        userId: projectsTable.userId,
        name: projectsTable.name,
        createdAt: projectsTable.createdAt,
        updatedAt: projectsTable.updatedAt,
        // Raw correlated subqueries: drizzle renders an interpolated
        // `${projectsTable.id}` as bare "id", which would resolve to the
        // SUBQUERY's sessions.id. The literal outer table name is required.
        sessionCount: sql<number>`(select count(*)::int from sessions s where s.project_id = projects.id and s.deleted_at is null)`,
        fileCount: sql<number>`(select count(*)::int from private_memory_files m where m.project_id = projects.id)`,
      })
      .from(projectsTable)
      .where(eq(projectsTable.userId, uid))
      .orderBy(asc(projectsTable.createdAt), asc(projectsTable.id));
    const cap = await projectFileCap(db, uid);
    return rows.map((row) => ({ ...row, fileCap: cap }));
  },

  /** Ownership-scoped fetch: null on unknown id OR wrong owner (never 403). */
  async get(db: Db, uid: string, projectId: string): Promise<ProjectRow | null> {
    const [row] = await db
      .select()
      .from(projectsTable)
      .where(and(eq(projectsTable.id, projectId), eq(projectsTable.userId, uid)))
      .limit(1);
    return row ?? null;
  },

  /** Create; null when the owner already has a project with that name. */
  async create(db: Db, uid: string, name: string): Promise<ProjectRow | null> {
    const clean = cleanName(name);
    const [row] = await db
      .insert(projectsTable)
      .values({ id: uuidv7(), userId: uid, name: clean })
      .onConflictDoNothing({ target: [projectsTable.userId, projectsTable.name] })
      .returning();
    return row ?? null;
  },

  /** Rename; null when unknown/foreign, ProjectError("name_taken") on a duplicate. */
  async rename(db: Db, uid: string, projectId: string, name: string): Promise<ProjectRow | null> {
    const clean = cleanName(name);
    try {
      const [row] = await db
        .update(projectsTable)
        .set({ name: clean, updatedAt: new Date() })
        .where(and(eq(projectsTable.id, projectId), eq(projectsTable.userId, uid)))
        .returning();
      return row ?? null;
    } catch (err) {
      if (isUniqueViolation(err)) {
        throw new ProjectError("name_taken", "You already have a project with that name.");
      }
      throw err;
    }
  },

  /**
   * Delete an owned project. The FK cascade removes its memory files and
   * SET NULL detaches its chats (history is never deleted with the folder).
   * Returns false for unknown/foreign ids (same 404 as every other route).
   */
  async delete(db: Db, uid: string, projectId: string): Promise<boolean> {
    const removed = await db
      .delete(projectsTable)
      .where(and(eq(projectsTable.id, projectId), eq(projectsTable.userId, uid)))
      .returning({ id: projectsTable.id });
    return removed.length > 0;
  },

  /**
   * Move an owned live chat into an owned project (or out of every project
   * with `null`). Both ownership checks run in one transaction so a racing
   * project delete cannot strand the chat.
   */
  async moveSession(
    db: Db,
    uid: string,
    sessionId: string,
    projectId: string | null,
  ): Promise<SessionRow | null> {
    return db.transaction(async (tx) => {
      const [session] = await tx
        .select({ id: sessionsTable.id })
        .from(sessionsTable)
        .where(
          and(
            eq(sessionsTable.id, sessionId),
            eq(sessionsTable.userId, uid),
            isNull(sessionsTable.deletedAt),
          ),
        )
        .for("update");
      if (!session) return null;
      if (projectId !== null) {
        const [project] = await tx
          .select({ id: projectsTable.id })
          .from(projectsTable)
          .where(and(eq(projectsTable.id, projectId), eq(projectsTable.userId, uid)))
          .for("share");
        if (!project) throw new ProjectError("not_found", "Project not found.");
      }
      const [row] = await tx
        .update(sessionsTable)
        .set({ projectId, updatedAt: new Date() })
        .where(and(eq(sessionsTable.id, sessionId), eq(sessionsTable.userId, uid)))
        .returning();
      return row ?? null;
    });
  },
};

/**
 * The caller's plan-derived project file cap. Reads the user's stored tier
 * (users.tier, which holds a plan id or legacy alias) and the LIVE plan table
 * ordered by `position`; no second plan list lives here. Unknown/missing
 * users and plans fail closed to the Free cap.
 */
export async function projectFileCap(db: Db, uid: string): Promise<number> {
  const [user] = await db
    .select({ tier: usersTable.tier })
    .from(usersTable)
    .where(eq(usersTable.uid, uid))
    .limit(1);
  const plans = await db
    .select({ id: plansTable.id, aliases: plansTable.aliases })
    .from(plansTable)
    .where(eq(plansTable.enabled, true))
    .orderBy(asc(plansTable.position), asc(plansTable.id));
  if (plans.length === 0) return PROJECT_FILE_CAPS[0];
  const tier = (user?.tier ?? "free").trim().toLowerCase();
  const index = plans.findIndex(
    (plan) =>
      plan.id.toLowerCase() === tier ||
      (Array.isArray(plan.aliases) ? plan.aliases : []).some(
        (alias) => typeof alias === "string" && alias.toLowerCase() === tier,
      ),
  );
  const position = index >= 0 ? index : 0;
  return PROJECT_FILE_CAPS[Math.min(position, PROJECT_FILE_CAPS.length - 1)]!;
}
