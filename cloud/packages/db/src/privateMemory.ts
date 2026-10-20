import { createHash } from "node:crypto";
import { and, eq, isNull, sql } from "drizzle-orm";
import { isValidMemoryName, PrivateMemoryError, type MemoryFileDto, type PrivateMemoryNamespace, type PrivateMemoryStore } from "@ovid/shared";
import type { Db } from "./client.js";
import { privateMemoryFiles as files, projects, sessions, users } from "./schema.js";

type Tx = Parameters<Parameters<Db["transaction"]>[0]>[0];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
/** Session memory keeps its historical 32-file ceiling. */
const SESSION_MAX_FILES = 32;
/**
 * Project caps come from the plan (80/100/150/250). The store clamps the
 * caller-provided cap to that range; a caller that omits it gets Free's 80
 * rather than silently shrinking the project to the session ceiling.
 */
const PROJECT_MAX_FILES_FLOOR = 80;
const PROJECT_MAX_FILES_CEILING = 250;
const hash = (text: string) => createHash("sha256").update(text, "utf8").digest("hex");

function projectMaxFiles(ns: { maxFiles?: number }): number {
  const n = ns.maxFiles ?? PROJECT_MAX_FILES_FLOOR;
  return Math.max(PROJECT_MAX_FILES_FLOOR, Math.min(PROJECT_MAX_FILES_CEILING, Math.trunc(n)));
}

function validateName(name: string): void {
  if (!isValidMemoryName(name)) throw new PrivateMemoryError("bad_request", "Use a plain .md filename (max 80 characters); the entrypoint is MEMORY.md.");
}
function validateContent(content: string): void {
  if (Buffer.byteLength(content, "utf8") > 32768 || content.includes("\u0000")) throw new PrivateMemoryError("bad_request", "Memory must be UTF-8 text, at most 32 KiB, without NUL bytes.");
}

/** Never relay a driver exception: it can contain SQL bind values (private facts). */
async function safe<T>(work: () => Promise<T>): Promise<T> {
  try { return await work(); }
  catch (e) {
    if (e instanceof PrivateMemoryError) throw e;
    throw new PrivateMemoryError("unavailable", "Private memory is temporarily unavailable. Try again.");
  }
}

/**
 * A namespace is authorized by a LIVE, owned chat (or an owned project for
 * `project:<uuid>` scope). Transaction locks keep ownership stable through
 * each operation and serialize name/count/revision guards per namespace. No
 * user/session/project provisioning here.
 */
interface AuthorizedScope {
  scope: string;
  /** Non-null only for chat-scoped rows (never for shared/project rows). */
  sessionId: string | null;
  /** Non-null only for project-scoped rows. */
  projectId: string | null;
}
async function authorize(tx: Tx, uid: string, ns: PrivateMemoryNamespace): Promise<AuthorizedScope> {
  if (!uid) throw new PrivateMemoryError("not_found", "Memory file not found.");
  if (ns.projectId !== undefined) {
    if (!UUID.test(ns.projectId)) throw new PrivateMemoryError("not_found", "Memory file not found.");
    const scope = `project:${ns.projectId}`;
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`${uid}:private-memory:${scope}`}, 0))`);
    const [owner] = await tx.select({ uid: users.uid }).from(users).where(eq(users.uid, uid)).for("key share");
    if (!owner) throw new PrivateMemoryError("not_found", "Memory file not found.");
    // Foreign projects are indistinguishable from unknown ones (404 upstream).
    const [project] = await tx
      .select({ id: projects.id })
      .from(projects)
      .where(and(eq(projects.id, ns.projectId), eq(projects.userId, uid)))
      .for("share");
    if (!project) throw new PrivateMemoryError("not_found", "Memory file not found.");
    return { scope, sessionId: null, projectId: ns.projectId };
  }
  if (!UUID.test(ns.sessionId) || typeof ns.shared !== "boolean") throw new PrivateMemoryError("not_found", "Memory file not found.");
  const scope = ns.shared ? "shared" : ns.sessionId;
  await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`${uid}:private-memory:${scope}`}, 0))`);
  const [owner] = await tx.select({ uid: users.uid }).from(users).where(eq(users.uid, uid)).for("key share");
  if (!owner) throw new PrivateMemoryError("not_found", "Memory file not found.");
  const [session] = await tx.select({ id: sessions.id }).from(sessions).where(and(eq(sessions.id, ns.sessionId), eq(sessions.userId, uid), isNull(sessions.deletedAt))).for("share");
  if (!session) throw new PrivateMemoryError("not_found", "Memory file not found.");
  return { scope, sessionId: ns.shared ? null : ns.sessionId, projectId: null };
}
const at = (uid: string, scope: string, name?: string) => and(eq(files.userId, uid), eq(files.scope, scope), ...(name === undefined ? [] : [eq(files.name, name)]));

/** Required production adapter for memory tools/API. No workspace-file fallback. */
export function createPrivateMemoryStore(db: Db): PrivateMemoryStore {
  return {
    list: (uid, ns) => safe(() => db.transaction(async tx => {
      const { scope } = await authorize(tx, uid, ns);
      const limit = ns.projectId !== undefined ? projectMaxFiles(ns) : SESSION_MAX_FILES;
      return tx.select({ name: files.name, sizeBytes: sql<number>`octet_length(${files.content})` }).from(files).where(at(uid, scope)).orderBy(files.name).limit(limit);
    })),
    read: (uid, ns, name) => safe(() => db.transaction(async tx => {
      validateName(name);
      const { scope } = await authorize(tx, uid, ns);
      const [row] = await tx.select({ name: files.name, content: files.content, revision: files.revision }).from(files).where(at(uid, scope, name));
      return row ?? null;
    })),
    save: (uid, ns, name, content, ifRevision) => safe(() => db.transaction(async tx => {
      validateName(name);
      validateContent(content);
      const target = await authorize(tx, uid, ns);
      const isProject = ns.projectId !== undefined;
      const maxFiles = isProject ? projectMaxFiles(ns) : SESSION_MAX_FILES;
      const rows = await tx.select({ name: files.name, revision: files.revision }).from(files).where(at(uid, target.scope)).limit(maxFiles + 1);
      const current = rows.find(r => r.name === name);
      const conflict = rows.find(r => r.name.toLowerCase() === name.toLowerCase() && r.name !== name);
      if (conflict) throw new PrivateMemoryError("bad_request", `Filename conflicts with ${conflict.name}.`);
      if (current && ifRevision === undefined) throw new PrivateMemoryError("baseline_mismatch", "Read the current memory file before replacing it.");
      const revisionBefore = current?.revision ?? hash("");
      if (ifRevision !== undefined && ifRevision !== revisionBefore) throw new PrivateMemoryError("baseline_mismatch", "This memory changed since you opened it. Reload it and try again.");
      // Projects enforce the owner-spec cap EXACTLY (80/100/150/250 files).
      // Chat memory keeps its historical reserve-one-slot semantics for
      // MEMORY.md (the pre-0019 behavior, pinned by privateMemory.test.ts).
      if (!current) {
        const full = isProject
          ? rows.length >= maxFiles
          : new Set(["MEMORY.md", ...rows.map(r => r.name)]).size >= maxFiles;
        if (full) throw new PrivateMemoryError("limit_reached", isProject ? `This project is limited to ${maxFiles} memory files on your plan.` : `Memory is limited to ${maxFiles} files.`);
      }
      const revision = hash(content);
      await tx.insert(files).values({ userId: uid, scope: target.scope, sessionId: target.sessionId, projectId: target.projectId, name, content, revision }).onConflictDoUpdate({
        target: [files.userId, files.scope, files.name], set: { content, revision, updatedAt: new Date() },
      });
      return { name, content, revision } satisfies MemoryFileDto;
    })),
    remove: (uid, ns, name) => safe(() => db.transaction(async tx => {
      validateName(name);
      const { scope } = await authorize(tx, uid, ns);
      const removed = await tx.delete(files).where(at(uid, scope, name)).returning({ name: files.name });
      return removed.length > 0;
    })),
  };
}
