import { and, asc, desc, eq, gt, inArray, isNull, lt, or, sql } from "drizzle-orm";
import { uuidv7 } from "uuidv7";
import type { MessageDto, SessionEvent, SessionEventType } from "@ovid/shared";
import type { Db } from "./client.js";
import {
  attachments as attachmentsTable,
  messages as messagesTable,
  mcpOauthFlows as mcpOauthFlowsTable,
  mcpOauthTokens as mcpOauthTokensTable,
  mcpServers as mcpServersTable,
  pluginGrants as pluginGrantsTable,
  plugins as pluginsTable,
  runs as runsTable,
  sessions as sessionsTable,
  sessionEventMirror,
  users as usersTable,
  type AttachmentRow,
  type MessageRow,
  type RunRow,
  type SealedEnvelope,
  type SessionEventMirrorRow,
  type SessionRow,
  type UserRow,
} from "./schema.js";

/** Message role union, sourced from the shared wire protocol (do not redefine). */
export type MessageRole = MessageDto["role"];

/** New UUIDv7 id — time-ordered, so lexicographic order = creation order. */
export function newId(): string {
  return uuidv7();
}

// ---------------------------------------------------------------------------
// users
// ---------------------------------------------------------------------------

export const users = {
  /**
   * Idempotent user provisioning for the gateway's authenticated request path
   * (sessions.userId has an FK here, so the row must exist before any session
   * or message insert). Controller ruling:
   *
   *   INSERT … ON CONFLICT (uid) DO UPDATE SET email = COALESCE(excluded.email, users.email)
   *
   * — a null email never clobbers a stored one, and `tier` is NEVER touched
   * (billing/operator-owned; queue priority reads it). Returns the stored row.
   */
  async ensure(db: Db, uid: string, email: string | null): Promise<UserRow> {
    const [row] = await db
      .insert(usersTable)
      .values({ uid, email })
      .onConflictDoUpdate({
        target: usersTable.uid,
        set: { email: sql`COALESCE(excluded.email, ${usersTable.email})` },
      })
      .returning();
    return row!;
  },

  /**
   * Per-user sandbox uid from the users_sandbox_uid_seq pool — the production
   * block 200000–209999 (spec §11; the sequence is pinned to that block in the
   * migration). Idempotent by construction:
   *
   *   1. nextval once (a value may be burned even when the user already has
   *      one — accepted: correctness over sequence thriftiness),
   *   2. UPDATE … SET sandbox_uid = next WHERE uid = $1 AND sandbox_uid IS NULL
   *      RETURNING — exactly one concurrent caller for a user wins the write,
   *   3. no row → the user already had one (or is unknown): re-read and return
   *      the stored value, so every caller observes the same uid.
   *
   * When the sequence is exhausted (nextval past MAXVALUE), throws
   * Error("sandbox uid pool exhausted") — provisioning must stop there.
   */
  async allocateSandboxUid(db: Db, uid: string): Promise<number> {
    let next: number;
    try {
      // ::int — nextval returns int8, which postgres.js hands back as a string.
      const rows = (await db.execute(
        sql`SELECT nextval('users_sandbox_uid_seq')::int AS v`,
      )) as unknown as { v: number }[];
      next = rows[0]!.v;
    } catch (err) {
      // drizzle wraps driver errors ("Failed query: …", original on .cause);
      // PostgreSQL's exhaustion message is 'nextval: reached maximum value of
      // sequence "users_sandbox_uid_seq" (209999)'.
      let e: unknown = err;
      let exhausted = false;
      for (let depth = 0; e instanceof Error && depth < 5; depth++) {
        if (/reached maximum value of sequence/i.test(e.message)) {
          exhausted = true;
          break;
        }
        e = (e as { cause?: unknown }).cause;
      }
      if (exhausted) throw new Error("sandbox uid pool exhausted");
      throw err;
    }
    const claimed = await db
      .update(usersTable)
      .set({ sandboxUid: next })
      .where(and(eq(usersTable.uid, uid), isNull(usersTable.sandboxUid)))
      .returning({ sandboxUid: usersTable.sandboxUid });
    if (claimed[0] !== undefined) return claimed[0].sandboxUid!;
    const [existing] = await db
      .select({ sandboxUid: usersTable.sandboxUid })
      .from(usersTable)
      .where(eq(usersTable.uid, uid));
    if (existing?.sandboxUid != null) return existing.sandboxUid;
    throw new Error(`users.allocateSandboxUid: unknown user ${uid}`);
  },

  /**
   * The user's tier, defaulting to "free" when the row is missing — a missing
   * user is Free (P5 G9 tier gate's single tier read; also used by the
   * queue priority path). Callers must NOT cache: every gate point re-reads.
   */
  async getTier(db: Db, uid: string): Promise<string> {
    const [row] = await db
      .select({ tier: usersTable.tier })
      .from(usersTable)
      .where(eq(usersTable.uid, uid));
    return row?.tier ?? "free";
  },
};

// ---------------------------------------------------------------------------
// sessions
// ---------------------------------------------------------------------------

// Cursors are client-controlled (Task 7 passes them through opaquely), so
// decode must never yield a value that throws downstream. postgres.js
// serializes Date params via toISOString and PG's timestamptz parser only
// accepts 4-digit years; outside years 0001–9999 (or beyond JS Date's own
// ±8.64e15 ms range → Invalid Date) binding throws. Real updatedAt values are
// epoch ms, so anything outside these bounds is a crafted/garbage cursor and
// degrades to "no cursor" (first page) instead of a 500.
const CURSOR_MS_MIN = -62_135_596_800_000; // 0001-01-01T00:00:00.000Z
const CURSOR_MS_MAX = 253_402_300_799_999; // 9999-12-31T23:59:59.999Z

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
  // Number.isSafeInteger rejects NaN/Infinity/non-integers/out-of-range magnitudes
  // (e.g. 1e20, which would decode to Invalid Date); the bounds check rejects
  // values JS can represent but PG cannot bind (years outside 0001–9999).
  if (
    !Number.isSafeInteger(ms) ||
    ms < CURSOR_MS_MIN ||
    ms > CURSOR_MS_MAX ||
    id.length === 0
  ) {
    return null;
  }
  return { updatedAt: new Date(ms), id };
}

export const sessions = {
  async create(
    db: Db,
    userId: string,
    title?: string | null,
    createdAt?: Date,
  ): Promise<SessionRow> {
    const [row] = await db
      .insert(sessionsTable)
      .values({
        id: newId(),
        userId,
        title: title ?? null,
        // P8 Task 4 (history import): a client-supplied createdAt preserves
        // the original transcript's creation time (spec §13.3 timestamp
        // fidelity); omitted → column default (now), untouched.
        ...(createdAt !== undefined ? { createdAt } : {}),
      })
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

  /**
   * Ownership-scoped partial update (P8 session PATCH): UPDATE … SET <fields>,
   * updatedAt = now WHERE id AND userId RETURNING row. null = unknown id OR
   * wrong owner (the gateway maps both to the same 404 — no existence leaks).
   * Only keys present in `fields` are written; a key set to undefined is left
   * untouched. The caller (gateway route) validates mode against the enum —
   * this layer stores whatever it is given.
   */
  async update(
    db: Db,
    sessionId: string,
    userId: string,
    fields: { title?: string | null; mode?: string },
  ): Promise<SessionRow | null> {
    const set: { title?: string | null; mode?: string; updatedAt: Date } = {
      updatedAt: new Date(),
    };
    if (fields.title !== undefined) set.title = fields.title;
    if (fields.mode !== undefined) set.mode = fields.mode;
    const rows = await db
      .update(sessionsTable)
      .set(set)
      .where(and(eq(sessionsTable.id, sessionId), eq(sessionsTable.userId, userId)))
      .returning();
    return rows[0] ?? null;
  },
};

// ---------------------------------------------------------------------------
// messages
// ---------------------------------------------------------------------------

export const messages = {
  async append(
    db: Db,
    m: { sessionId: string; role: MessageRole; content: string; clientMsgId?: string },
  ): Promise<MessageRow> {
    const [row] = await db
      .insert(messagesTable)
      .values({
        id: newId(),
        sessionId: m.sessionId,
        role: m.role,
        content: m.content,
        // Omitted → NULL (exempt from the per-session unique index; the
        // key present → a duplicate (session, clientMsgId) raises 23505,
        // which the send-message route resolves into a replay/409.
        ...(m.clientMsgId !== undefined ? { clientMsgId: m.clientMsgId } : {}),
      })
      .returning();
    return row!;
  },

  /**
   * P8 Task 4: the message holding (sessionId, clientMsgId), or null. The
   * lookup behind the send-message route's idempotent-replay branch — the
   * partial unique index guarantees at most one match.
   */
  async findByClientMsgId(
    db: Db,
    sessionId: string,
    clientMsgId: string,
  ): Promise<MessageRow | null> {
    const rows = await db
      .select()
      .from(messagesTable)
      .where(
        and(eq(messagesTable.sessionId, sessionId), eq(messagesTable.clientMsgId, clientMsgId)),
      )
      .limit(1);
    return rows[0] ?? null;
  },

  /**
   * P8 Task 4: bulk history-import insert — ONE statement,
   * INSERT … ON CONFLICT (session_id, client_msg_id) DO NOTHING RETURNING id,
   * so re-sent clientMsgIds are skipped, never duplicated (and never raise).
   * `imported` = rows that landed; `skipped` = rows already present. Rows
   * carry the CLIENT's createdAt (timestamp fidelity, spec §13.3); ids are
   * fresh UUIDv7s. In-batch duplicate clientMsgIds are handled by the same
   * ON CONFLICT skip (only the first lands).
   */
  async importBulk(
    db: Db,
    sessionId: string,
    rows: ReadonlyArray<{
      clientMsgId: string;
      role: MessageRole;
      content: string;
      createdAt: Date;
    }>,
  ): Promise<{ imported: number; skipped: number }> {
    if (rows.length === 0) return { imported: 0, skipped: 0 };
    const inserted = await db
      .insert(messagesTable)
      .values(
        rows.map((r) => ({
          id: newId(),
          sessionId,
          role: r.role,
          content: r.content,
          clientMsgId: r.clientMsgId,
          createdAt: r.createdAt,
        })),
      )
      .onConflictDoNothing({
        target: [messagesTable.sessionId, messagesTable.clientMsgId],
        // The arbiter is the PARTIAL unique index; inference needs the same
        // predicate the index declares (drizzle's `where` on a DO NOTHING
        // conflict is the target's index predicate).
        where: sql`${messagesTable.clientMsgId} IS NOT NULL`,
      })
      .returning({ id: messagesTable.id });
    return { imported: inserted.length, skipped: rows.length - inserted.length };
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

  /**
   * P8 Task 4: the run prompted by this message, or null. The send-message
   * route's idempotent-replay branch uses it to distinguish "retry of a send
   * that already produced a run" (202 replay) from "clientMsgId held by a
   * run-less message" (409 run_conflict). promptMessageId is globally unique
   * (it references a freshly appended message), so no session scoping needed.
   */
  async getByPromptMessageId(db: Db, promptMessageId: string): Promise<RunRow | null> {
    const rows = await db
      .select()
      .from(runsTable)
      .where(eq(runsTable.promptMessageId, promptMessageId))
      .orderBy(asc(runsTable.createdAt))
      .limit(1);
    return rows[0] ?? null;
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

  /**
   * CONDITIONAL terminal transition (I4b): UPDATE … WHERE id AND
   * status IN ('queued','running') — a run already terminalized by the
   * processor or the stale-run sweeper is never overwritten, so the two can
   * never clobber each other's verdicts. true = this call terminalized the
   * run (from 'queued' — the C1 queue-wait timeout path — or 'running');
   * false = already terminal (or unknown id), nothing written.
   */
  async finish(
    db: Db,
    runId: string,
    status: "completed" | "failed" | "cancelled",
    lastError?: string | null,
  ): Promise<boolean> {
    const finished = await db
      .update(runsTable)
      .set({ status, lastError: lastError ?? null, finishedAt: new Date() })
      .where(and(eq(runsTable.id, runId), inArray(runsTable.status, [...ACTIVE_RUN_STATUSES])))
      .returning({ id: runsTable.id });
    return finished.length > 0;
  },

  /**
   * Ownership-scoped fetch (owner = the run's session owner): null on unknown
   * id OR wrong owner, so the gateway maps both to the same 404 (the runs
   * cancel route's existence-leak rule, same as sessions.get).
   */
  async get(db: Db, runId: string, userId: string): Promise<RunRow | null> {
    const rows = await db
      .select({ run: runsTable })
      .from(runsTable)
      .innerJoin(sessionsTable, eq(runsTable.sessionId, sessionsTable.id))
      .where(and(eq(runsTable.id, runId), eq(sessionsTable.userId, userId)))
      .limit(1);
    return rows[0]?.run ?? null;
  },

  /**
   * P8 Task 1: ownership-scoped conditional request-cancel —
   * UPDATE … SET cancel_requested = true WHERE id AND session-owner AND
   * status IN ('queued','running') RETURNING row. null = unknown id, wrong
   * owner, OR the run went terminal in the race window between the caller's
   * terminal check and this write (the route re-checks and answers 409).
   */
  async requestCancel(db: Db, runId: string, userId: string): Promise<RunRow | null> {
    const ownedSessions = db
      .select({ id: sessionsTable.id })
      .from(sessionsTable)
      .where(eq(sessionsTable.userId, userId));
    const rows = await db
      .update(runsTable)
      .set({ cancelRequested: true })
      .where(
        and(
          eq(runsTable.id, runId),
          inArray(runsTable.sessionId, ownedSessions),
          inArray(runsTable.status, [...ACTIVE_RUN_STATUSES]),
        ),
      )
      .returning();
    return rows[0] ?? null;
  },

  /**
   * P8 Task 1: the worker's throttled cancel poll — one indexed pk read, no
   * ownership scoping (the worker already owns the job). Unknown id → false
   * (defensive; a cancelled run's row always exists).
   */
  async isCancelRequested(db: Db, runId: string): Promise<boolean> {
    const rows = await db
      .select({ cancelRequested: runsTable.cancelRequested })
      .from(runsTable)
      .where(eq(runsTable.id, runId))
      .limit(1);
    return rows[0]?.cancelRequested ?? false;
  },

  /**
   * Runs stuck in 'running' whose startedAt is older than the cutoff, oldest
   * first, capped at 100 per call (one sweeper batch). With BullMQ attempts:1
   * a failed or crashed job is NEVER redelivered, so its run row would strand
   * in 'running' forever; the worker's stale-run sweeper (apps/worker
   * staleRuns.ts) uses this to terminalize them. NULL startedAt rows (cannot
   * exist for 'running', but SQL semantics hold) are excluded by the `<`.
   */
  async listStaleRunning(db: Db, staleBefore: Date): Promise<RunRow[]> {
    return db
      .select()
      .from(runsTable)
      .where(and(eq(runsTable.status, "running"), lt(runsTable.startedAt, staleBefore)))
      .orderBy(asc(runsTable.startedAt))
      .limit(100);
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
// attachments (P8 Task 3)
// ---------------------------------------------------------------------------

export const attachments = {
  /**
   * Insert an attachment row. The id (and r2Key built around it) are
   * caller-generated: the gateway presigns the PUT URL for that exact key
   * BEFORE inserting, so a presign failure leaves no row behind.
   */
  async create(
    db: Db,
    a: {
      id: string;
      sessionId: string;
      userId: string;
      name: string;
      size: number;
      r2Key: string;
    },
  ): Promise<AttachmentRow> {
    const [row] = await db.insert(attachmentsTable).values(a).returning();
    return row!;
  },

  /**
   * The session's attachments, oldest-first (id order). With `ids`, only rows
   * whose id is in the list — SESSION-scoped: an id that exists under another
   * session is simply absent from the answer, which is how the gateway's
   * sendMessage validation (unknown id → 400) also catches cross-session id
   * reuse. An empty `ids` list matches nothing.
   */
  async getForSession(
    db: Db,
    sessionId: string,
    ids?: readonly string[],
  ): Promise<AttachmentRow[]> {
    if (ids !== undefined && ids.length === 0) return [];
    const where =
      ids !== undefined
        ? and(eq(attachmentsTable.sessionId, sessionId), inArray(attachmentsTable.id, [...ids]))
        : eq(attachmentsTable.sessionId, sessionId);
    return db
      .select()
      .from(attachmentsTable)
      .where(where)
      .orderBy(asc(attachmentsTable.id));
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

// ---------------------------------------------------------------------------
// MCP servers, OAuth tokens/flows, plugins, grants (P5 Task 8).
//
// Every read/write here is ownership-scoped (uid); a wrong owner is
// indistinguishable from a missing row (null / false) — the gateway maps both
// to the same 404, no existence leaks. Sealed columns pass through opaque
// (this layer never encrypts or decrypts — that is EnvelopeCrypto's job at
// the call site, with the pinned recordId conventions).
// ---------------------------------------------------------------------------

export type McpServerRow = typeof mcpServersTable.$inferSelect;
export type McpOauthTokenRow = typeof mcpOauthTokensTable.$inferSelect;
export type McpOauthFlowRow = typeof mcpOauthFlowsTable.$inferSelect;
export type PluginRow = typeof pluginsTable.$inferSelect;
export type PluginGrantRow = typeof pluginGrantsTable.$inferSelect;

export interface McpServerCreate {
  userId: string;
  name: string;
  transport: string;
  curatedId?: string | null;
  config?: Record<string, unknown> | null;
  secretsSealed?: SealedEnvelope | null;
  enabled?: boolean;
}

export interface McpServerPatch {
  name?: string;
  transport?: string;
  curatedId?: string | null;
  config?: Record<string, unknown> | null;
  secretsSealed?: SealedEnvelope | null;
  enabled?: boolean;
}

export const mcpServers = {
  /**
   * Insert a new server row. A duplicate (userId, name) raises the DB's
   * UNIQUE violation (23505) — deliberately surfaced so the route can map it
   * to 409 server_exists; this is NOT an upsert.
   */
  async create(db: Db, input: McpServerCreate): Promise<McpServerRow> {
    const [row] = await db
      .insert(mcpServersTable)
      .values({
        id: newId(),
        userId: input.userId,
        name: input.name,
        transport: input.transport,
        curatedId: input.curatedId ?? null,
        config: input.config ?? null,
        secretsSealed: input.secretsSealed ?? null,
        ...(input.enabled !== undefined ? { enabled: input.enabled } : {}),
      })
      .returning();
    return row!;
  },

  /** The user's servers, insertion order (createdAt, id — both UUIDv7-time). */
  async list(db: Db, uid: string): Promise<McpServerRow[]> {
    return db
      .select()
      .from(mcpServersTable)
      .where(eq(mcpServersTable.userId, uid))
      .orderBy(asc(mcpServersTable.createdAt), asc(mcpServersTable.id));
  },

  /** Null on unknown id OR wrong owner. */
  async get(db: Db, id: string, uid: string): Promise<McpServerRow | null> {
    const [row] = await db
      .select()
      .from(mcpServersTable)
      .where(and(eq(mcpServersTable.id, id), eq(mcpServersTable.userId, uid)))
      .limit(1);
    return row ?? null;
  },

  /** Ownership-scoped partial update; only keys present are written. Null = not found. */
  async update(db: Db, id: string, uid: string, patch: McpServerPatch): Promise<McpServerRow | null> {
    const set: McpServerPatch & { updatedAt: Date } = { updatedAt: new Date() };
    if (patch.name !== undefined) set.name = patch.name;
    if (patch.transport !== undefined) set.transport = patch.transport;
    if (patch.curatedId !== undefined) set.curatedId = patch.curatedId;
    if (patch.config !== undefined) set.config = patch.config;
    if (patch.secretsSealed !== undefined) set.secretsSealed = patch.secretsSealed;
    if (patch.enabled !== undefined) set.enabled = patch.enabled;
    const rows = await db
      .update(mcpServersTable)
      .set(set)
      .where(and(eq(mcpServersTable.id, id), eq(mcpServersTable.userId, uid)))
      .returning();
    return rows[0] ?? null;
  },

  /** true iff the row existed AND was owned by uid. */
  async remove(db: Db, id: string, uid: string): Promise<boolean> {
    const removed = await db
      .delete(mcpServersTable)
      .where(and(eq(mcpServersTable.id, id), eq(mcpServersTable.userId, uid)))
      .returning({ id: mcpServersTable.id });
    return removed.length > 0;
  },

  /** The user's server by (unique) display name, or null. */
  async findByName(db: Db, uid: string, name: string): Promise<McpServerRow | null> {
    const [row] = await db
      .select()
      .from(mcpServersTable)
      .where(and(eq(mcpServersTable.userId, uid), eq(mcpServersTable.name, name)))
      .limit(1);
    return row ?? null;
  },
};

export interface McpOauthTokenPut {
  userId: string;
  serverId: string;
  tokensSealed: SealedEnvelope;
}

export const mcpOauthTokens = {
  /**
   * Upsert the live token set for a server (UNIQUE(server_id)): a refresh
   * replaces the sealed tokens and bumps updatedAt; never a second row.
   */
  async put(db: Db, input: McpOauthTokenPut): Promise<void> {
    await db
      .insert(mcpOauthTokensTable)
      .values({
        id: newId(),
        userId: input.userId,
        serverId: input.serverId,
        tokensSealed: input.tokensSealed,
      })
      .onConflictDoUpdate({
        target: mcpOauthTokensTable.serverId,
        set: {
          userId: input.userId,
          tokensSealed: input.tokensSealed,
          updatedAt: new Date(),
        },
      });
  },

  /** Null on unknown server OR wrong owner. */
  async get(db: Db, serverId: string, uid: string): Promise<McpOauthTokenRow | null> {
    const [row] = await db
      .select()
      .from(mcpOauthTokensTable)
      .where(and(eq(mcpOauthTokensTable.serverId, serverId), eq(mcpOauthTokensTable.userId, uid)))
      .limit(1);
    return row ?? null;
  },

  /** Ownership-scoped delete; unknown/wrong-owner is a silent no-op. */
  async remove(db: Db, serverId: string, uid: string): Promise<void> {
    await db
      .delete(mcpOauthTokensTable)
      .where(and(eq(mcpOauthTokensTable.serverId, serverId), eq(mcpOauthTokensTable.userId, uid)));
  },
};

export interface McpOauthFlowCreate {
  state: string;
  userId: string;
  serverId: string;
  verifierSealed?: SealedEnvelope | null;
  config?: Record<string, unknown> | null;
  expiresAt: Date;
}

export const mcpOauthFlows = {
  async create(db: Db, input: McpOauthFlowCreate): Promise<void> {
    await db.insert(mcpOauthFlowsTable).values({
      state: input.state,
      userId: input.userId,
      serverId: input.serverId,
      verifierSealed: input.verifierSealed ?? null,
      config: input.config ?? null,
      expiresAt: input.expiresAt,
    });
  },

  /**
   * ATOMIC one-use consume:
   *   UPDATE … SET used = true WHERE state = $1 AND used = false
   *     AND expires_at > now() RETURNING *
   * Exactly one concurrent caller can win a state; the loser (and any later
   * replay, and any expired flow) gets null. No ownership scoping — the
   * callback route validates the state itself (it is the bearer).
   */
  async consume(db: Db, state: string): Promise<McpOauthFlowRow | null> {
    const rows = await db
      .update(mcpOauthFlowsTable)
      .set({ used: true })
      .where(
        and(
          eq(mcpOauthFlowsTable.state, state),
          eq(mcpOauthFlowsTable.used, false),
          gt(mcpOauthFlowsTable.expiresAt, new Date()),
        ),
      )
      .returning();
    return rows[0] ?? null;
  },
};

export interface PluginUpsert {
  userId: string;
  pluginId: string;
  version: string;
  source: Record<string, unknown>;
  status?: string;
  contentDir?: string | null;
  manifest?: Record<string, unknown> | null;
  probeFailures?: Record<string, unknown>[] | null;
  configSealed?: SealedEnvelope | null;
}

export interface PluginStatusExtra {
  contentDir?: string | null;
  manifest?: Record<string, unknown> | null;
  probeFailures?: Record<string, unknown>[] | null;
  configSealed?: SealedEnvelope | null;
}

export const plugins = {
  /**
   * Insert or advance a plugin install on (userId, pluginId) conflict. The
   * installer job is the only writer and owns every field it passes: keys
   * present in `input` overwrite the stored row, absent keys are left
   * untouched (a re-upsert never clobbers configSealed with null).
   * installedAt keeps the FIRST install time across upserts.
   */
  async upsert(db: Db, input: PluginUpsert): Promise<PluginRow> {
    const values = {
      id: newId(),
      userId: input.userId,
      pluginId: input.pluginId,
      version: input.version,
      source: input.source,
      status: input.status ?? "installing",
      contentDir: input.contentDir ?? null,
      manifest: input.manifest ?? null,
      probeFailures: input.probeFailures ?? null,
      configSealed: input.configSealed ?? null,
    };
    const set: Record<string, unknown> = {
      version: input.version,
      source: input.source,
      status: input.status ?? "installing",
      updatedAt: new Date(),
    };
    for (const key of ["contentDir", "manifest", "probeFailures", "configSealed"] as const) {
      if (input[key] !== undefined) set[key] = input[key];
    }
    const [row] = await db
      .insert(pluginsTable)
      .values(values)
      .onConflictDoUpdate({
        target: [pluginsTable.userId, pluginsTable.pluginId],
        set,
      })
      .returning();
    return row!;
  },

  /** The user's installs, insertion order. */
  async list(db: Db, uid: string): Promise<PluginRow[]> {
    return db
      .select()
      .from(pluginsTable)
      .where(eq(pluginsTable.userId, uid))
      .orderBy(asc(pluginsTable.installedAt), asc(pluginsTable.id));
  },

  /** Null on unknown id OR wrong owner. */
  async get(db: Db, id: string, uid: string): Promise<PluginRow | null> {
    const [row] = await db
      .select()
      .from(pluginsTable)
      .where(and(eq(pluginsTable.id, id), eq(pluginsTable.userId, uid)))
      .limit(1);
    return row ?? null;
  },

  /** Null on unknown (uid, pluginId). */
  async getByPluginId(db: Db, uid: string, pluginId: string): Promise<PluginRow | null> {
    const [row] = await db
      .select()
      .from(pluginsTable)
      .where(and(eq(pluginsTable.userId, uid), eq(pluginsTable.pluginId, pluginId)))
      .limit(1);
    return row ?? null;
  },

  /** Ownership-scoped status transition (installer/prober write path). */
  async setStatus(
    db: Db,
    id: string,
    uid: string,
    status: string,
    extra?: PluginStatusExtra,
  ): Promise<void> {
    const set: { status: string; updatedAt: Date } & PluginStatusExtra = {
      status,
      updatedAt: new Date(),
    };
    if (extra?.contentDir !== undefined) set.contentDir = extra.contentDir;
    if (extra?.manifest !== undefined) set.manifest = extra.manifest;
    if (extra?.probeFailures !== undefined) set.probeFailures = extra.probeFailures;
    if (extra?.configSealed !== undefined) set.configSealed = extra.configSealed;
    await db
      .update(pluginsTable)
      .set(set)
      .where(and(eq(pluginsTable.id, id), eq(pluginsTable.userId, uid)));
  },

  /** true iff the row existed AND was owned by uid. */
  async remove(db: Db, id: string, uid: string): Promise<boolean> {
    const removed = await db
      .delete(pluginsTable)
      .where(and(eq(pluginsTable.id, id), eq(pluginsTable.userId, uid)))
      .returning({ id: pluginsTable.id });
    return removed.length > 0;
  },
};

export interface PluginGrantPut {
  userId: string;
  pluginId: string;
  capabilities: string[];
  envNames: string[];
  manifestDigest: string;
  allowDependencyScripts?: boolean;
}

export const pluginGrants = {
  /**
   * Record or re-record the user's consent (UNIQUE(userId, pluginId)): a
   * re-grant replaces capabilities/env/digest and refreshes grantedAt.
   */
  async put(db: Db, input: PluginGrantPut): Promise<void> {
    await db
      .insert(pluginGrantsTable)
      .values({
        id: newId(),
        userId: input.userId,
        pluginId: input.pluginId,
        capabilities: input.capabilities,
        envNames: input.envNames,
        manifestDigest: input.manifestDigest,
        allowDependencyScripts: input.allowDependencyScripts ?? false,
      })
      .onConflictDoUpdate({
        target: [pluginGrantsTable.userId, pluginGrantsTable.pluginId],
        set: {
          capabilities: input.capabilities,
          envNames: input.envNames,
          manifestDigest: input.manifestDigest,
          allowDependencyScripts: input.allowDependencyScripts ?? false,
          grantedAt: new Date(),
        },
      });
  },

  /** Null on unknown (uid, pluginId). */
  async get(db: Db, uid: string, pluginId: string): Promise<PluginGrantRow | null> {
    const [row] = await db
      .select()
      .from(pluginGrantsTable)
      .where(and(eq(pluginGrantsTable.userId, uid), eq(pluginGrantsTable.pluginId, pluginId)))
      .limit(1);
    return row ?? null;
  },

  /** Ownership-scoped delete (uninstall/revoke); unknown is a silent no-op. */
  async remove(db: Db, uid: string, pluginId: string): Promise<void> {
    await db
      .delete(pluginGrantsTable)
      .where(and(eq(pluginGrantsTable.userId, uid), eq(pluginGrantsTable.pluginId, pluginId)));
  },
};
