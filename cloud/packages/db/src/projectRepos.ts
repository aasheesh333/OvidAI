import { and, asc, eq, isNull, sql } from "drizzle-orm";
import { PLANS, PLAN_TIERS, planFor } from "@ovid/shared";
import { uuidv7 } from "uuidv7";
import type { Db } from "./client.js";
import {
  attachments as attachmentsTable,
  projects as projectsTable,
  sessions as sessionsTable,
  users as usersTable,
  workspaceObjects as workspaceObjectsTable,
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
  /** Total used slots: project memory + attachments + active artifacts. */
  fileCount: number;
  /** Plan-derived per-project file cap (owner spec §3 Screen 4). */
  fileCap: number;
  /** Total bytes across memory, attachments and active artifacts. */
  fileBytes: number;
  /** Per-bucket counts, so the sidebar/W13 can show a breakdown. */
  fileBreakdown: {
    memory: number;
    attachments: number;
    artifacts: number;
  };
}

/**
 * Per-project file caps by plan, DERIVED from the one plan table.
 *
 * These used to be a literal `[80, 100, 150, 250]` indexed by the user's
 * ordinal among the LIVE enabled `plans` rows. Two ways that enforced a
 * number `plans.ts` never advertised: a fresh install has no plan rows at all
 * (every tier fell back to Free's 80), and disabling or reordering a plan in
 * /admin shifted every paid tier onto its neighbour's cap. Deriving the list
 * from `PLANS` keeps a single source for the number; `projectFileCap` reads
 * the tier directly and never depends on row order.
 */
export const PROJECT_FILE_CAPS: readonly number[] = PLAN_TIERS.map(
  (tier) => PLANS[tier].projectFiles,
);
export const MAX_PROJECT_NAME_LENGTH = 80;

/** Fold the three counted buckets into the public summary shape. */
function toSummary(
  row: {
    id: string;
    userId: string;
    name: string;
    createdAt: Date;
    updatedAt: Date;
    sessionCount: number;
    memoryFiles: number;
    memoryBytes: number;
    attachmentCount: number;
    attachmentBytes: number;
    artifactCount: number;
    artifactBytes: number;
  },
  cap: number,
): ProjectSummary {
  return {
    id: row.id,
    userId: row.userId,
    name: row.name,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    sessionCount: row.sessionCount,
    fileCount: row.memoryFiles + row.attachmentCount + row.artifactCount,
    fileCap: cap,
    fileBytes: Math.trunc(row.memoryBytes + row.attachmentBytes + row.artifactBytes),
    fileBreakdown: {
      memory: row.memoryFiles,
      attachments: row.attachmentCount,
      artifacts: row.artifactCount,
    },
  };
}

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

/**
 * W1 follow-up (0022): stamp every file row of a chat with its project (or
 * NULL when it leaves). Runs inside `moveSession`'s transaction so a chat's
 * uploads and artifacts follow the chat. Existing files are never deleted or
 * refused here: a move may take a project over its cap, after which new
 * writes fail closed until a file is deleted.
 */
async function stampSessionFiles(
  db: Db | Parameters<Parameters<Db["transaction"]>[0]>[0],
  sessionId: string,
  projectId: string | null,
): Promise<void> {
  const q = db as Db;
  await q
    .update(attachmentsTable)
    .set({ projectId })
    .where(eq(attachmentsTable.sessionId, sessionId));
  await q
    .update(workspaceObjectsTable)
    .set({ projectId })
    .where(eq(workspaceObjectsTable.sessionId, sessionId));
}

export const projectsRepo = {
  /** Owner-scoped list, oldest first, with live session and file counts. */
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
        memoryFiles: sql<number>`(select count(*)::int from private_memory_files m where m.project_id = projects.id)`,
        memoryBytes: sql<number>`(select coalesce(sum(octet_length(m.content)), 0)::double precision from private_memory_files m where m.project_id = projects.id)`,
        attachmentCount: sql<number>`(select count(*)::int from attachments a left join sessions sa on sa.id = a.session_id where coalesce(a.project_id, sa.project_id) = projects.id and sa.deleted_at is null)`,
        attachmentBytes: sql<number>`(select coalesce(sum(a.size), 0)::double precision from attachments a left join sessions sa on sa.id = a.session_id where coalesce(a.project_id, sa.project_id) = projects.id and sa.deleted_at is null)`,
        artifactCount: sql<number>`(select count(*)::int from workspace_objects w left join sessions wa on wa.id = w.session_id where coalesce(w.project_id, wa.project_id) = projects.id and w.kind = 'artifact' and w.status = 'active')`,
        artifactBytes: sql<number>`(select coalesce(sum(w.bytes), 0)::double precision from workspace_objects w left join sessions wa on wa.id = w.session_id where coalesce(w.project_id, wa.project_id) = projects.id and w.kind = 'artifact' and w.status = 'active')`,
      })
      .from(projectsTable)
      .where(eq(projectsTable.userId, uid))
      .orderBy(asc(projectsTable.createdAt), asc(projectsTable.id));
    const cap = await projectFileCap(db, uid);
    return rows.map((row) => toSummary(row, cap));
  },

  /** Owner-scoped single-project summary (the detail API). */
  async getSummary(db: Db, uid: string, projectId: string): Promise<ProjectSummary | null> {
    const rows = await db
      .select({
        id: projectsTable.id,
        userId: projectsTable.userId,
        name: projectsTable.name,
        createdAt: projectsTable.createdAt,
        updatedAt: projectsTable.updatedAt,
        sessionCount: sql<number>`(select count(*)::int from sessions s where s.project_id = projects.id and s.deleted_at is null)`,
        memoryFiles: sql<number>`(select count(*)::int from private_memory_files m where m.project_id = projects.id)`,
        memoryBytes: sql<number>`(select coalesce(sum(octet_length(m.content)), 0)::double precision from private_memory_files m where m.project_id = projects.id)`,
        attachmentCount: sql<number>`(select count(*)::int from attachments a left join sessions sa on sa.id = a.session_id where coalesce(a.project_id, sa.project_id) = projects.id and sa.deleted_at is null)`,
        attachmentBytes: sql<number>`(select coalesce(sum(a.size), 0)::double precision from attachments a left join sessions sa on sa.id = a.session_id where coalesce(a.project_id, sa.project_id) = projects.id and sa.deleted_at is null)`,
        artifactCount: sql<number>`(select count(*)::int from workspace_objects w left join sessions wa on wa.id = w.session_id where coalesce(w.project_id, wa.project_id) = projects.id and w.kind = 'artifact' and w.status = 'active')`,
        artifactBytes: sql<number>`(select coalesce(sum(w.bytes), 0)::double precision from workspace_objects w left join sessions wa on wa.id = w.session_id where coalesce(w.project_id, wa.project_id) = projects.id and w.kind = 'artifact' and w.status = 'active')`,
      })
      .from(projectsTable)
      .where(and(eq(projectsTable.id, projectId), eq(projectsTable.userId, uid)))
      .limit(1);
    const row = rows[0];
    return row === undefined ? null : toSummary(row, await projectFileCap(db, uid));
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
      if (row !== undefined) {
        // W1 follow-up (0022): the chat's uploads/artifacts follow the chat.
        // Files are never deleted here; a move may put a project over its cap,
        // after which new writes fail closed until a file is deleted.
        await stampSessionFiles(tx, sessionId, projectId);
      }
      return row ?? null;
    });
  },
};

/**
 * The caller's plan-derived project file cap.
 *
 * The stored tier (`users.tier`, a plan id or a legacy alias) resolves through
 * the canonical `plans.ts` table — the same table `/plans` and the account
 * screen describe — so a paying account can never be held to a neighbour's
 * cap because of row order, a disabled plan, or an unseeded install.
 * Unknown/missing users and tiers fail closed to Free.
 */
export async function projectFileCap(db: Db, uid: string): Promise<number> {
  const [user] = await db
    .select({ tier: usersTable.tier })
    .from(usersTable)
    .where(eq(usersTable.uid, uid))
    .limit(1);
  return planFor(user?.tier ?? "free").projectFiles;
}
