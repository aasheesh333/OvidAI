import { and, eq, isNull, sql } from "drizzle-orm";
import type { Db } from "./client.js";
import { projectFileCap } from "./projectRepos.js";
import { projects, sessions } from "./schema.js";

/**
 * W1 follow-up (0022): project-scoped file accounting.
 *
 * One project's file budget covers EVERYTHING the project owns:
 *   - project memory files (`private_memory_files.project_id`),
 *   - uploads (`attachments.project_id`),
 *   - active generated artifacts (`workspace_objects.project_id`,
 *     kind='artifact', status='active').
 *
 * Storage model (deliberate):
 *   - `project_id` is stamped at creation from the owning session's current
 *     project (see `attachments.create` and `workspaceObjects.registerArtifact`),
 *     and migration 0022 backfills every pre-existing row from its session.
 *   - Reads still fall back to the session join (`COALESCE(row.project_id,
 *     session.project_id)`) so a legacy/raw-inserted NULL is attributed
 *     correctly instead of vanishing from the count. A non-NULL stamp is
 *     authoritative; `projectsRepo.moveSession` restamps a chat's files when
 *     it moves, which keeps the stamp and the join in agreement.
 *   - Deleting a project sets these columns NULL (FK SET NULL) — the objects
 *     stay in the account vault, they just stop belonging to a project.
 *
 * Enforcement is fail-closed at the write boundary: the caller is refused
 * BEFORE the object is stored or a row is written. `lockProjectFiles` takes a
 * transaction-scoped advisory lock so concurrent uploads/registrations for the
 * same project serialize; the row insert then re-checks the count under that
 * lock (the pre-flight check exists so bytes are not uploaded first).
 */

/** Stable wire code for a refused project-scoped write. */
export const PROJECT_FILE_LIMIT_CODE = "project_file_limit";

export interface ProjectFileUsage {
  projectId: string;
  /** Total used slots (memory + attachments + active artifacts). */
  used: number;
  /** Plan-derived cap (80/100/150/250). */
  cap: number;
  /** Total bytes across the three buckets. */
  bytes: number;
  memoryFiles: number;
  attachments: number;
  artifacts: number;
  memoryBytes: number;
  attachmentBytes: number;
  artifactBytes: number;
}

/** Typed refusal; routes map it to a 4xx and never write a row. */
export class ProjectFileLimitError extends Error {
  readonly code = PROJECT_FILE_LIMIT_CODE;
  readonly projectId: string;
  readonly used: number;
  readonly cap: number;

  constructor(usage: ProjectFileUsage) {
    super(
      `This project is limited to ${usage.cap} files on your plan. Delete a file to free a slot.`,
    );
    this.name = "ProjectFileLimitError";
    this.projectId = usage.projectId;
    this.used = usage.used;
    this.cap = usage.cap;
  }
}

/** The transaction handle drizzle hands to `db.transaction(cb)`. */
type Tx = Parameters<Parameters<Db["transaction"]>[0]>[0];
type DbOrTx = Db | Tx;

/** Tx exposes the same query surface these helpers use; widen like scheduleRepos. */
function q(db: DbOrTx): Db {
  return db as Db;
}

/**
 * Serialize every project-file mutation for one (user, project). Transaction
 * scoped: released on commit/rollback. Uses the same key shape as the memory
 * store's project lock so a memory save and an upload cannot both pass the
 * last-slot check.
 */
export async function lockProjectFiles(db: DbOrTx, uid: string, projectId: string): Promise<void> {
  await q(db).execute(
    sql`select pg_advisory_xact_lock(hashtextextended(${`${uid}:project-files:${projectId}`}, 0))`,
  );
}

/**
 * Exact project file usage. `cap` may be supplied by the caller (already
 * computed for the request) to avoid a second plan read.
 */
export async function projectFileUsage(
  db: DbOrTx,
  uid: string,
  projectId: string,
  cap?: number,
): Promise<ProjectFileUsage> {
  const rows = (await q(db).execute(sql`
    select
      (select count(*)::int
         from private_memory_files m
        where m.project_id = ${projectId}) as memory_files,
      (select coalesce(sum(octet_length(m.content)), 0)::double precision
         from private_memory_files m
        where m.project_id = ${projectId}) as memory_bytes,
      (select count(*)::int
         from attachments a
         left join sessions s on s.id = a.session_id
        where coalesce(a.project_id, s.project_id) = ${projectId}
          and s.deleted_at is null) as attachments,
      (select coalesce(sum(a.size), 0)::double precision
         from attachments a
         left join sessions s on s.id = a.session_id
        where coalesce(a.project_id, s.project_id) = ${projectId}
          and s.deleted_at is null) as attachment_bytes,
      (select count(*)::int
         from workspace_objects w
         left join sessions s on s.id = w.session_id
        where coalesce(w.project_id, s.project_id) = ${projectId}
          and w.kind = 'artifact'
          and w.status = 'active') as artifacts,
      (select coalesce(sum(w.bytes), 0)::double precision
         from workspace_objects w
         left join sessions s on s.id = w.session_id
        where coalesce(w.project_id, s.project_id) = ${projectId}
          and w.kind = 'artifact'
          and w.status = 'active') as artifact_bytes
  `)) as unknown as Array<{
    memory_files: number;
    memory_bytes: number;
    attachments: number;
    attachment_bytes: number;
    artifacts: number;
    artifact_bytes: number;
  }>;

  const row = rows[0];
  const memoryFiles = Number(row?.memory_files ?? 0);
  const attachments = Number(row?.attachments ?? 0);
  const artifacts = Number(row?.artifacts ?? 0);
  const memoryBytes = Math.trunc(Number(row?.memory_bytes ?? 0));
  const attachmentBytes = Math.trunc(Number(row?.attachment_bytes ?? 0));
  const artifactBytes = Math.trunc(Number(row?.artifact_bytes ?? 0));
  return {
    projectId,
    used: memoryFiles + attachments + artifacts,
    cap: cap ?? (await projectFileCap(q(db), uid)),
    bytes: memoryBytes + attachmentBytes + artifactBytes,
    memoryFiles,
    attachments,
    artifacts,
    memoryBytes,
    attachmentBytes,
    artifactBytes,
  };
}

/**
 * Refuse when [additional] more files would exceed the project cap. Returns
 * the current usage otherwise. The caller holds `lockProjectFiles` when this
 * guards a write inside a transaction.
 */
export async function assertProjectFileCapacity(
  db: DbOrTx,
  uid: string,
  projectId: string,
  additional = 1,
  cap?: number,
): Promise<ProjectFileUsage> {
  const usage = await projectFileUsage(db, uid, projectId, cap);
  if (usage.used + additional > usage.cap) throw new ProjectFileLimitError(usage);
  return usage;
}

/**
 * Session-scoped convenience: resolves the chat's project (owner-scoped, live
 * chats only) and enforces its cap. Returns null for a standalone chat, an
 * unknown/foreign session, or a soft-deleted chat — the caller then behaves
 * exactly as before (no project accounting).
 */
export async function assertSessionFileCapacity(
  db: DbOrTx,
  uid: string,
  sessionId: string,
  additional = 1,
): Promise<ProjectFileUsage | null> {
  const [session] = await q(db)
    .select({ projectId: sessions.projectId })
    .from(sessions)
    .where(
      and(
        eq(sessions.id, sessionId),
        eq(sessions.userId, uid),
        isNull(sessions.deletedAt),
      ),
    )
    .limit(1);
  if (session === undefined || session.projectId === null) return null;
  return assertProjectFileCapacity(db, uid, session.projectId, additional);
}

/** True when [projectId] is an owned project (unknown and foreign both false). */
export async function ownsProject(
  db: DbOrTx,
  uid: string,
  projectId: string,
): Promise<boolean> {
  const [row] = await q(db)
    .select({ id: projects.id })
    .from(projects)
    .where(and(eq(projects.id, projectId), eq(projects.userId, uid)))
    .limit(1);
  return row !== undefined;
}
