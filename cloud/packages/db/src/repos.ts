import { and, asc, desc, eq, inArray, lt, or, sql } from "drizzle-orm";
import { uuidv7 } from "uuidv7";
import type { MessageDto, SessionEvent, SessionEventType } from "@ovid/shared";
import type { Db } from "./client.js";
import {
  messages as messagesTable,
  runs as runsTable,
  sessions as sessionsTable,
  sessionEventMirror,
  type MessageRow,
  type RunRow,
  type SessionEventMirrorRow,
  type SessionRow,
} from "./schema.js";

/** Message role union, sourced from the shared wire protocol (do not redefine). */
export type MessageRole = MessageDto["role"];

/** New UUIDv7 id — time-ordered, so lexicographic order = creation order. */
export function newId(): string {
  return uuidv7();
}

// ---------------------------------------------------------------------------
// sessions
// ---------------------------------------------------------------------------

// Opaque keyset cursor for sessions.list: "<updatedAt epoch ms>~<session id>".
function encodeSessionCursor(row: SessionRow): string {
  return `${row.updatedAt.getTime()}~${row.id}`;
}

function decodeSessionCursor(
  cursor: string | null | undefined,
): { updatedAt: Date; id: string } | null {
  if (!cursor) return null;
  const sep = cursor.indexOf("~");
  if (sep <= 0) return null;
  const ms = Number(cursor.slice(0, sep));
  const id = cursor.slice(sep + 1);
  if (!Number.isInteger(ms) || id.length === 0) return null;
  return { updatedAt: new Date(ms), id };
}

export const sessions = {
  async create(db: Db, userId: string, title?: string | null): Promise<SessionRow> {
    const [row] = await db
      .insert(sessionsTable)
      .values({ id: newId(), userId, title: title ?? null })
      .returning();
    return row!;
  },

  /** Ownership-scoped fetch: null on unknown id OR wrong owner (gateway maps to 404). */
  async get(db: Db, sessionId: string, userId: string): Promise<SessionRow | null> {
    const rows = await db
      .select()
      .from(sessionsTable)
      .where(and(eq(sessionsTable.id, sessionId), eq(sessionsTable.userId, userId)))
      .limit(1);
    return rows[0] ?? null;
  },

  /** Most recent activity first; keyset cursor over (updatedAt, id). Invalid cursors restart from the beginning. */
  async list(
    db: Db,
    userId: string,
    limit: number,
    cursor?: string | null,
  ): Promise<{ rows: SessionRow[]; nextCursor: string | null }> {
    const key = decodeSessionCursor(cursor);
    const where = key
      ? and(
          eq(sessionsTable.userId, userId),
          or(
            lt(sessionsTable.updatedAt, key.updatedAt),
            and(eq(sessionsTable.updatedAt, key.updatedAt), lt(sessionsTable.id, key.id)),
          ),
        )
      : eq(sessionsTable.userId, userId);
    const found = await db
      .select()
      .from(sessionsTable)
      .where(where)
      .orderBy(desc(sessionsTable.updatedAt), desc(sessionsTable.id))
      .limit(limit + 1);
    const hasMore = found.length > limit;
    const rows = hasMore ? found.slice(0, limit) : found;
    const last = rows[rows.length - 1];
    return { rows, nextCursor: hasMore && last ? encodeSessionCursor(last) : null };
  },

  async touch(db: Db, sessionId: string): Promise<void> {
    await db
      .update(sessionsTable)
      .set({ updatedAt: new Date() })
      .where(eq(sessionsTable.id, sessionId));
  },
};

// ---------------------------------------------------------------------------
// messages
// ---------------------------------------------------------------------------

export const messages = {
  async append(
    db: Db,
    m: { sessionId: string; role: MessageRole; content: string },
  ): Promise<MessageRow> {
    const [row] = await db
      .insert(messagesTable)
      .values({ id: newId(), sessionId: m.sessionId, role: m.role, content: m.content })
      .returning();
    return row!;
  },

  /**
   * Newest-first keyset page by id (UUIDv7 ⇒ id order = insertion order).
   * `beforeId` excludes itself; nextCursor is the oldest id on the page.
   */
  async page(
    db: Db,
    sessionId: string,
    opts: { limit: number; beforeId?: string | null },
  ): Promise<{ rows: MessageRow[]; nextCursor: string | null }> {
    const where = opts.beforeId
      ? and(eq(messagesTable.sessionId, sessionId), lt(messagesTable.id, opts.beforeId))
      : eq(messagesTable.sessionId, sessionId);
    const found = await db
      .select()
      .from(messagesTable)
      .where(where)
      .orderBy(desc(messagesTable.id))
      .limit(opts.limit + 1);
    const hasMore = found.length > opts.limit;
    const rows = hasMore ? found.slice(0, opts.limit) : found;
    const last = rows[rows.length - 1];
    return { rows, nextCursor: hasMore && last ? last.id : null };
  },
};

// ---------------------------------------------------------------------------
// runs
// ---------------------------------------------------------------------------

const ACTIVE_RUN_STATUSES = ["queued", "running"] as const;

export const runs = {
  async create(
    db: Db,
    r: { sessionId: string; promptMessageId: string },
  ): Promise<RunRow> {
    const [row] = await db
      .insert(runsTable)
      .values({
        id: newId(),
        sessionId: r.sessionId,
        status: "queued",
        promptMessageId: r.promptMessageId,
      })
      .returning();
    return row!;
  },

  /** Oldest still-active (queued|running) run for the session, or null. */
  async activeForSession(db: Db, sessionId: string): Promise<RunRow | null> {
    const rows = await db
      .select()
      .from(runsTable)
      .where(
        and(
          eq(runsTable.sessionId, sessionId),
          inArray(runsTable.status, [...ACTIVE_RUN_STATUSES]),
        ),
      )
      .orderBy(asc(runsTable.createdAt), asc(runsTable.id))
      .limit(1);
    return rows[0] ?? null;
  },

  /**
   * Single conditional UPDATE … WHERE id = $1 AND status = 'queued' — race-safe:
   * exactly one concurrent caller sees the row still queued. false = lost race
   * (or unknown/already-claimed id).
   */
  async claimNext(db: Db, runId: string): Promise<boolean> {
    const claimed = await db
      .update(runsTable)
      .set({ status: "running", startedAt: new Date() })
      .where(and(eq(runsTable.id, runId), eq(runsTable.status, "queued")))
      .returning({ id: runsTable.id });
    return claimed.length > 0;
  },

  async finish(
    db: Db,
    runId: string,
    status: "completed" | "failed" | "cancelled",
    lastError?: string | null,
  ): Promise<void> {
    await db
      .update(runsTable)
      .set({ status, lastError: lastError ?? null, finishedAt: new Date() })
      .where(eq(runsTable.id, runId));
  },

  /** Atomically increments attempts and returns the new value (0 if run unknown). */
  async bumpAttempt(db: Db, runId: string): Promise<number> {
    const rows = await db
      .update(runsTable)
      .set({ attempts: sql`${runsTable.attempts} + 1` })
      .where(eq(runsTable.id, runId))
      .returning({ attempts: runsTable.attempts });
    return rows[0]?.attempts ?? 0;
  },
};

// ---------------------------------------------------------------------------
// eventMirror (durable copy of the Redis Streams session ledger)
// ---------------------------------------------------------------------------

// seq is a Redis stream id "ms-sub". Order/compare numerically on both parts —
// lexicographic text order is wrong across digit-width changes ("999…" > "1700…").
const seqMs = sql<number>`split_part(${sessionEventMirror.seq}, '-', 1)::bigint`;
const seqSub = sql<number>`split_part(${sessionEventMirror.seq}, '-', 2)::integer`;

function splitSeq(seq: string): { ms: number; sub: number } | null {
  const sep = seq.indexOf("-");
  const ms = Number(sep === -1 ? seq : seq.slice(0, sep));
  const sub = Number(sep === -1 ? "0" : seq.slice(sep + 1));
  if (!Number.isFinite(ms) || !Number.isFinite(sub)) return null;
  return { ms, sub };
}

function toSessionEvent(row: SessionEventMirrorRow): SessionEvent {
  return {
    sessionId: row.sessionId,
    seq: row.seq,
    type: row.type as SessionEventType,
    payload: row.payload,
    ts: row.ts.toISOString(),
  };
}

export const eventMirror = {
  /** Idempotent: conflicting (sessionId, seq) keeps the stored row. */
  async put(db: Db, e: SessionEvent): Promise<void> {
    await db
      .insert(sessionEventMirror)
      .values({
        sessionId: e.sessionId,
        seq: e.seq,
        type: e.type,
        payload: e.payload,
        ts: new Date(e.ts),
      })
      .onConflictDoNothing({
        target: [sessionEventMirror.sessionId, sessionEventMirror.seq],
      });
  },

  /** Events with seq strictly after lastSeq (null/invalid ⇒ from the beginning), in seq order. */
  async readSince(
    db: Db,
    sessionId: string,
    lastSeq: string | null,
    limit: number,
  ): Promise<SessionEvent[]> {
    const key = lastSeq === null ? null : splitSeq(lastSeq);
    const where = key
      ? and(
          eq(sessionEventMirror.sessionId, sessionId),
          or(sql`${seqMs} > ${key.ms}`, and(sql`${seqMs} = ${key.ms}`, sql`${seqSub} > ${key.sub}`)),
        )
      : eq(sessionEventMirror.sessionId, sessionId);
    const rows = await db
      .select()
      .from(sessionEventMirror)
      .where(where)
      .orderBy(asc(seqMs), asc(seqSub))
      .limit(limit);
    return rows.map(toSessionEvent);
  },
};
