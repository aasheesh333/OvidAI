import { and, desc, eq, ilike, lt, or, sql } from "drizzle-orm";
import type { Db } from "./client.js";
import {
  attachments as attachmentsTable,
  sessions as sessionsTable,
  workspaceObjects as workspaceObjectsTable,
  type WorkspaceObjectRow,
} from "./schema.js";

/**
 * The account Artifact Vault (FE-004/005/022): one inventory over EVERY file
 * the account owns — Ovid-generated artifacts (workspace_objects kind=artifact
 * status=active) UNION ALL user uploads (attachments) — scoped by the
 * authenticated uid AND session ownership (the session join is the guard: a
 * workspace-object row whose userId was tampered to point at another owner's
 * session never lists).
 *
 * The inventory NEVER touches object storage: rows are intent, availability
 * stays "unverified" until the mint route's single HEAD. The origin is
 * derived from which canonical table the row came from — never guessed from a
 * URL. No r2Key, presigned URL or storage layout detail ever leaves this
 * module; the DTO surface (see the gateway route) is id/name/size/type only.
 *
 * Soft-deleted chats keep their files in the account Vault (retention), so
 * the session join deliberately does NOT filter deleted_at — only ownership.
 */

export type ArtifactVaultOrigin = "generated" | "uploaded";
export type ArtifactVaultCategory = "image" | "html" | "code" | "document" | "other";
export type ArtifactVaultAvailability = "unverified";

export interface ArtifactVaultCursor {
  id: string;
  origin: ArtifactVaultOrigin;
}

export interface ArtifactVaultFilter {
  origin?: ArtifactVaultOrigin;
  category?: ArtifactVaultCategory;
  search?: string;
  sessionId?: string;
  limit: number;
  cursor?: ArtifactVaultCursor | null;
}

export interface ArtifactVaultRow {
  id: string;
  origin: ArtifactVaultOrigin;
  category: ArtifactVaultCategory;
  availability: ArtifactVaultAvailability;
  sessionId: string;
  sessionTitle: string | null;
  name: string;
  sizeBytes: number;
  contentType: string;
  createdAt: Date;
  /** NEVER serialized to clients — the mint route's HEAD input only. */
  r2Key: string;
}

export interface ArtifactVaultPage {
  rows: ArtifactVaultRow[];
  nextCursor: ArtifactVaultCursor | null;
}

/** Deterministic full order: createdAt desc, then provenance (uploaded before
 * generated on a tie), then id desc (newest UUIDv7 first). */
const ORIGIN_RANK: Record<ArtifactVaultOrigin, number> = { generated: 0, uploaded: 1 };

function compareRows(a: ArtifactVaultRow, b: ArtifactVaultRow): number {
  const time = b.createdAt.getTime() - a.createdAt.getTime();
  if (time !== 0) return time;
  const provenance = ORIGIN_RANK[b.origin] - ORIGIN_RANK[a.origin];
  if (provenance !== 0) return provenance;
  return b.id < a.id ? 1 : b.id > a.id ? -1 : 0;
}

export function encodeArtifactVaultCursor(cursor: ArtifactVaultCursor): string {
  return Buffer.from(JSON.stringify(cursor), "utf8").toString("base64url");
}

export function decodeArtifactVaultCursor(value: string): ArtifactVaultCursor | null {
  try {
    const parsed = JSON.parse(Buffer.from(value, "base64url").toString("utf8")) as {
      id?: unknown;
      origin?: unknown;
    };
    return typeof parsed.id === "string" &&
      (parsed.origin === "generated" || parsed.origin === "uploaded")
      ? { id: parsed.id, origin: parsed.origin }
      : null;
  } catch (_) {
    return null;
  }
}

function escapeLike(value: string): string {
  return value.replace(/[\\%_]/g, (c) => `\\${c}`);
}

const GENERATED_NAME = sql<string>`coalesce(${workspaceObjectsTable.meta}->>'name', ${workspaceObjectsTable.r2Key})`;
const GENERATED_LOWER_NAME = sql<string>`lower(${GENERATED_NAME})`;
const ATTACHMENT_LOWER_NAME = sql`lower(${attachmentsTable.name})`;

const IMAGE_EXTS = "'png','jpg','jpeg','gif','webp','bmp','svg','heic'";
const HTML_EXTS = "'html','htm'";
const CODE_EXTS =
  "'dart','js','mjs','ts','tsx','jsx','py','java','kt','c','h','cpp','rs','go','rb','php','swift','sh','css','scss','sql','json','yaml','yml','toml','xml'";
const DOC_EXTS =
  "'md','markdown','txt','log','pdf','doc','docx','odt','rtf','csv','tsv','xls','xlsx','ppt','pptx'";

/** Extension of the last dot-segment of a lower-cased name expression. */
function extExpr(lowerName: ReturnType<typeof sql>) {
  return sql`regexp_replace(${lowerName}, '^.*\\.', '')`;
}

/**
 * Category predicate evaluated IN SQL (the route's ?type= filter never
 * post-filters in JS, so pages stay honest under the limit). The TS twin is
 * [categoryOf] — the two MUST stay in sync (same ext lists, same rules).
 */
function categoryPredicate(
  table: typeof workspaceObjectsTable | typeof attachmentsTable,
  category: ArtifactVaultCategory,
) {
  const contentType =
    table === workspaceObjectsTable
      ? sql`lower(coalesce(${workspaceObjectsTable.contentType}, ''))`
      : sql`''`;
  const lowerName =
    table === workspaceObjectsTable ? GENERATED_LOWER_NAME : ATTACHMENT_LOWER_NAME;
  const ext = extExpr(lowerName);
  const image = or(sql`${contentType} like 'image/%'`, sql`${ext} in (${sql.raw(IMAGE_EXTS)})`)!;
  const html = or(sql`${contentType} = 'text/html'`, sql`${ext} in (${sql.raw(HTML_EXTS)})`)!;
  const code = sql`${ext} in (${sql.raw(CODE_EXTS)})`;
  const document = or(
    sql`${ext} in (${sql.raw(DOC_EXTS)})`,
    sql`${contentType} like 'text/%'`,
    sql`${contentType} = 'application/pdf'`,
  )!;
  return category === "image"
    ? image
    : category === "html"
      ? html
      : category === "code"
        ? code
        : category === "document"
          ? document
          : sql`not (${image} or ${html} or ${code} or ${document})`;
}

/** TS twin of [categoryPredicate] for the row the mint route fetched. */
function categoryOf(name: string, contentType: string): ArtifactVaultCategory {
  const ext = name.toLowerCase().split(".").pop() ?? "";
  const ct = contentType.toLowerCase();
  if (ct.startsWith("image/") || IMAGE_EXTS.includes(`'${ext}'`)) return "image";
  if (ct === "text/html" || HTML_EXTS.includes(`'${ext}'`)) return "html";
  if (CODE_EXTS.includes(`'${ext}'`)) return "code";
  if (DOC_EXTS.includes(`'${ext}'`) || ct.startsWith("text/") || ct === "application/pdf") {
    return "document";
  }
  return "other";
}

function toRow(
  origin: ArtifactVaultOrigin,
  found: {
    id: string;
    sessionId: string | null;
    name: string | null;
    sizeBytes: number | null;
    contentType: string | null;
    createdAt: Date;
    r2Key: string;
    sessionTitle: string | null;
  },
): ArtifactVaultRow | null {
  if (found.sessionId === null || found.name === null || found.sizeBytes === null) return null;
  const contentType = found.contentType ?? "application/octet-stream";
  return {
    id: found.id,
    origin,
    category: categoryOf(found.name, contentType),
    availability: "unverified",
    sessionId: found.sessionId,
    sessionTitle: found.sessionTitle,
    name: found.name,
    sizeBytes: found.sizeBytes,
    contentType,
    createdAt: found.createdAt,
    r2Key: found.r2Key,
  };
}

const GENERATED_FIELDS = {
  id: workspaceObjectsTable.id,
  sessionId: workspaceObjectsTable.sessionId,
  name: GENERATED_NAME,
  sizeBytes: workspaceObjectsTable.bytes,
  contentType: workspaceObjectsTable.contentType,
  createdAt: workspaceObjectsTable.createdAt,
  r2Key: workspaceObjectsTable.r2Key,
  sessionTitle: sessionsTable.title,
};

const ATTACHMENT_FIELDS = {
  id: attachmentsTable.id,
  sessionId: attachmentsTable.sessionId,
  name: attachmentsTable.name,
  sizeBytes: attachmentsTable.size,
  // The attachments table carries no content type column; the mint route's
  // HEAD never checks it either (size is the integrity check for uploads).
  contentType: sql<string>`null`,
  createdAt: attachmentsTable.createdAt,
  r2Key: attachmentsTable.r2Key,
  sessionTitle: sessionsTable.title,
};

/** The ownership join: the row's session must belong to THIS uid. */
function ownedSessionJoin(
  table: typeof workspaceObjectsTable | typeof attachmentsTable,
  userId: string,
) {
  const sessionIdCol =
    table === workspaceObjectsTable ? workspaceObjectsTable.sessionId : attachmentsTable.sessionId;
  return and(eq(sessionIdCol, sessionsTable.id), eq(sessionsTable.userId, userId))!;
}

/**
 * Keyset condition for one branch of the union, given the page cursor's
 * anchor. Branch order is (createdAt desc, originRank desc, id desc): rows
 * strictly AFTER the anchor are (created earlier) OR (same instant, a
 * lower-ranked origin) OR (same instant and origin, a smaller id).
 */
function afterAnchor(
  createdAtCol: typeof workspaceObjectsTable.createdAt | typeof attachmentsTable.createdAt,
  idCol: typeof workspaceObjectsTable.id | typeof attachmentsTable.id,
  branch: ArtifactVaultOrigin,
  anchor: { createdAt: Date; id: string; origin: ArtifactVaultOrigin },
) {
  const earlier = lt(createdAtCol, anchor.createdAt);
  const sameInstant = eq(createdAtCol, anchor.createdAt);
  if (branch === anchor.origin) {
    // Same branch: only smaller ids at the same instant remain.
    return or(earlier, and(sameInstant, lt(idCol, anchor.id)))!;
  }
  if (ORIGIN_RANK[branch] < ORIGIN_RANK[anchor.origin]) {
    // This branch ranks after the anchor's branch: everything at or before
    // the anchor instant is still ahead of it.
    return or(earlier, sameInstant)!;
  }
  // This branch ranks before the anchor's branch: at the anchor instant its
  // rows already passed; only earlier instants remain.
  return earlier;
}

export const artifactVault = {
  /**
   * One page of the account inventory. Each canonical source is read with
   * the filters AND the keyset condition pushed into SQL (limit+1 rows per
   * source), then merged with the deterministic comparator — equivalent to a
   * UNION ALL with a global ORDER BY, bounded by (limit+1) per source.
   *
   * The cursor is opaque but self-describing {id, origin}; the anchor's
   * createdAt is recovered with one indexed lookup (status-blind, so a row
   * that was soft-deleted between two pages still pages correctly). A decoded
   * cursor whose anchor cannot be found yields an empty page — a tampered
   * cursor can neither enumerate another account's rows (everything stays
   * uid-scoped) nor loop forever.
   */
  async page(db: Db, userId: string, f: ArtifactVaultFilter): Promise<ArtifactVaultPage> {
    const limit = Math.min(Math.max(Math.floor(f.limit), 1), 100);
    const branches: ArtifactVaultOrigin[] = f.origin ? [f.origin] : ["generated", "uploaded"];

    let anchor: { createdAt: Date; id: string; origin: ArtifactVaultOrigin } | null = null;
    if (f.cursor !== null && f.cursor !== undefined) {
      anchor = await this.anchor(db, userId, f.cursor);
      if (anchor === null) return { rows: [], nextCursor: null };
    }

    const merged: ArtifactVaultRow[] = [];
    for (const branch of branches) {
      const keyset =
        anchor === null ? undefined : afterAnchor(branch === "generated" ? workspaceObjectsTable.createdAt : attachmentsTable.createdAt, branch === "generated" ? workspaceObjectsTable.id : attachmentsTable.id, branch, anchor);
      if (branch === "generated") {
        const where = and(
          eq(workspaceObjectsTable.userId, userId),
          eq(workspaceObjectsTable.kind, "artifact"),
          eq(workspaceObjectsTable.status, "active"),
          f.sessionId ? eq(workspaceObjectsTable.sessionId, f.sessionId) : undefined,
          f.search
            ? ilike(GENERATED_NAME, `%${escapeLike(f.search)}%`)
            : undefined,
          f.category ? categoryPredicate(workspaceObjectsTable, f.category) : undefined,
          keyset,
        );
        const found = await db
          .select(GENERATED_FIELDS)
          .from(workspaceObjectsTable)
          .innerJoin(sessionsTable, ownedSessionJoin(workspaceObjectsTable, userId))
          .where(where)
          .orderBy(desc(workspaceObjectsTable.createdAt), desc(workspaceObjectsTable.id))
          .limit(limit + 1);
        for (const row of found) {
          const mapped = toRow(branch, row);
          if (mapped !== null) merged.push(mapped);
        }
      } else {
        const where = and(
          eq(attachmentsTable.userId, userId),
          f.sessionId ? eq(attachmentsTable.sessionId, f.sessionId) : undefined,
          f.search ? ilike(attachmentsTable.name, `%${escapeLike(f.search)}%`) : undefined,
          f.category ? categoryPredicate(attachmentsTable, f.category) : undefined,
          keyset,
        );
        const found = await db
          .select(ATTACHMENT_FIELDS)
          .from(attachmentsTable)
          .innerJoin(sessionsTable, ownedSessionJoin(attachmentsTable, userId))
          .where(where)
          .orderBy(desc(attachmentsTable.createdAt), desc(attachmentsTable.id))
          .limit(limit + 1);
        for (const row of found) {
          const mapped = toRow(branch, row);
          if (mapped !== null) merged.push(mapped);
        }
      }
    }

    merged.sort(compareRows);
    const rows = merged.slice(0, limit);
    const last = rows[rows.length - 1];
    return {
      rows,
      nextCursor: merged.length > limit && last ? { id: last.id, origin: last.origin } : null,
    };
  },

  /**
   * The cursor anchor's createdAt: one indexed read by id in the cursor's own
   * source table, uid-scoped but status-blind (a row soft-deleted between
   * pages must not break paging past it). Null when the anchor is gone or
   * belongs to someone else.
   */
  async anchor(
    db: Db,
    userId: string,
    cursor: ArtifactVaultCursor,
  ): Promise<{ createdAt: Date; id: string; origin: ArtifactVaultOrigin } | null> {
    const col =
      cursor.origin === "generated"
        ? { createdAt: workspaceObjectsTable.createdAt, id: workspaceObjectsTable.id, userId: workspaceObjectsTable.userId }
        : { createdAt: attachmentsTable.createdAt, id: attachmentsTable.id, userId: attachmentsTable.userId };
    const [row] = await db
      .select({ createdAt: col.createdAt })
      .from(cursor.origin === "generated" ? workspaceObjectsTable : attachmentsTable)
      .where(and(eq(col.id, cursor.id), eq(col.userId, userId)))
      .limit(1);
    return row ? { createdAt: row.createdAt, id: cursor.id, origin: cursor.origin } : null;
  },

  /**
   * Single row for the mint route: uid + session-ownership scoped, active
   * artifacts only (uploads have no status column — the HEAD is their only
   * proof). The origin MUST match the caller's ?source= or the row is
   * "not found": a generated id asked at as an upload is a 404, never a
   * cross-source mint.
   */
  async get(
    db: Db,
    userId: string,
    id: string,
    origin: ArtifactVaultOrigin,
  ): Promise<ArtifactVaultRow | null> {
    const [row] =
      origin === "generated"
        ? await db
            .select(GENERATED_FIELDS)
            .from(workspaceObjectsTable)
            .innerJoin(sessionsTable, ownedSessionJoin(workspaceObjectsTable, userId))
            .where(
              and(
                eq(workspaceObjectsTable.id, id),
                eq(workspaceObjectsTable.userId, userId),
                eq(workspaceObjectsTable.kind, "artifact"),
                eq(workspaceObjectsTable.status, "active"),
              ),
            )
            .limit(1)
        : await db
            .select(ATTACHMENT_FIELDS)
            .from(attachmentsTable)
            .innerJoin(sessionsTable, ownedSessionJoin(attachmentsTable, userId))
            .where(and(eq(attachmentsTable.id, id), eq(attachmentsTable.userId, userId)))
            .limit(1);
    return row ? toRow(origin, row) : null;
  },

  /**
   * Remove one artifact from the account.
   *
   * Returns the row that was removed (so the caller can delete its bytes and
   * report the freed size), or null when it is not the caller's.
   *
   * Generated rows are soft-deleted (`status = 'deleted'`) because every
   * quota and listing query filters `status = 'active'` — that is what frees
   * the space — while the row survives for audit. Uploads have no soft-delete
   * column, so the row is removed outright; the file's owner asked for it to
   * be gone and nothing else references it by id.
   *
   * The database write is deliberately FIRST. A failed storage delete leaves
   * orphaned bytes (recoverable by a sweep, invisible to the user), whereas
   * the reverse order would leave a row pointing at bytes that no longer
   * exist — a broken entry in the library.
   */
  async remove(
    db: Db,
    userId: string,
    id: string,
    origin: ArtifactVaultOrigin,
  ): Promise<ArtifactVaultRow | null> {
    const row = await this.get(db, userId, id, origin);
    if (row === null) return null;
    if (origin === "generated") {
      await db
        .update(workspaceObjectsTable)
        .set({ status: "deleted" })
        .where(
          and(
            eq(workspaceObjectsTable.id, id),
            eq(workspaceObjectsTable.userId, userId),
            eq(workspaceObjectsTable.kind, "artifact"),
          ),
        );
    } else {
      await db
        .delete(attachmentsTable)
        .where(and(eq(attachmentsTable.id, id), eq(attachmentsTable.userId, userId)));
    }
    return row;
  },
};

export type { WorkspaceObjectRow };
