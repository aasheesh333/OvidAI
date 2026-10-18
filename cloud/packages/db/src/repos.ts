import { and, asc, desc, eq, gt, inArray, isNull, lt, or, sql } from "drizzle-orm";
import { uuidv7 } from "uuidv7";
import type { MessageDto, SessionEvent, SessionEventType, UiManifest } from "@ovid/shared";
import type { Db } from "./client.js";
import {
  attachments as attachmentsTable,
  fileManifests as fileManifestsTable,
  grants as grantsTable,
  messages as messagesTable,
  mcpOauthFlows as mcpOauthFlowsTable,
  mcpOauthTokens as mcpOauthTokensTable,
  mcpServers as mcpServersTable,
  pluginGrants as pluginGrantsTable,
  plugins as pluginsTable,
  runs as runsTable,
  sessionAgentState as sessionAgentStateTable,
  sessions as sessionsTable,
  sessionEventMirror,
  users as usersTable,
  workspaceObjects as workspaceObjectsTable,
  type AttachmentRow,
  type FileManifestRow,
  type GrantRow,
  type MessageRow,
  type RunRow,
  type SealedEnvelope,
  type SessionEventMirrorRow,
  type SessionRow,
  type UserRow,
  type WorkspaceObjectRow,
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
   * P3 Task 14 (steering drain): a message row by id — the prompt row behind
   * a run's promptMessageId. Single pk read (the id is a globally-unique
   * UUIDv7; the gateway persists the user row BEFORE creating the run, so a
   * claimed run's prompt always resolves). No session scoping for the same
   * reason as runs.getByPromptMessageId.
   */
  async get(db: Db, messageId: string): Promise<MessageRow | null> {
    const rows = await db
      .select()
      .from(messagesTable)
      .where(eq(messagesTable.id, messageId))
      .limit(1);
    return rows[0] ?? null;
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
   * P3 Task 14 (steering drain): the session's QUEUED runs, oldest-first —
   * (createdAt, id), the same determinism as activeForSession. The steering
   * drain claims and merges these into the active run; the activeRunId
   * exclusion itself lives in the caller (the drain), because this signature
   * is session-scoped per the plan.
   */
  async listQueuedForSession(db: Db, sessionId: string): Promise<RunRow[]> {
    return db
      .select()
      .from(runsTable)
      .where(
        and(eq(runsTable.sessionId, sessionId), eq(runsTable.status, "queued")),
      )
      .orderBy(asc(runsTable.createdAt), asc(runsTable.id));
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
  /** Explicit row id (the gateway's installId); generated when absent. */
  id?: string;
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
      id: input.id ?? newId(),
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

  /**
   * Every `active`/`degraded` row across users — the worker-boot rehydration
   * scan (MEDIUM-2). The contribution registry is in-memory, so a restart
   * must rebuild it from these rows.
   */
  async listActive(db: Db): Promise<PluginRow[]> {
    return db
      .select()
      .from(pluginsTable)
      .where(inArray(pluginsTable.status, ["active", "degraded"]))
      .orderBy(asc(pluginsTable.installedAt), asc(pluginsTable.id));
  },

  /**
   * HIGH-3: re-key a gateway-created provisional `pending/<installId>` row to
   * the canonical `publisher/name` the WORKER derived from the source.
   *
   * Fresh install: the provisional row is updated in place, preserving the
   * id the client received as `installId`.
   *
   * Reinstall/upgrade: a canonical row already exists, and it MUST stay (its
   * id is the AAD recordId for `config_sealed`, so moving the sealed envelope
   * to a new id would make it undecryptable). The provisional row is removed
   * and the canonical row returned; the worker installs against it. The
   * response's ephemeral `installId` then points at a removed row — clients
   * should read the plugin from `GET /plugins` after an upgrade.
   *
   * Returns null when the provisional row does not exist (stale job).
   */
  async adopt(
    db: Db,
    input: { id: string; userId: string; pluginId: string },
  ): Promise<PluginRow | null> {
    return db.transaction(async (tx) => {
      const [provisional] = await tx
        .select()
        .from(pluginsTable)
        .where(
          and(
            eq(pluginsTable.id, input.id),
            eq(pluginsTable.userId, input.userId),
          ),
        )
        .limit(1);
      if (provisional === undefined) return null;
      if (provisional.pluginId === input.pluginId) return provisional;

      const [existing] = await tx
        .select()
        .from(pluginsTable)
        .where(
          and(
            eq(pluginsTable.userId, input.userId),
            eq(pluginsTable.pluginId, input.pluginId),
          ),
        )
        .limit(1);

      if (existing !== undefined && existing.id !== provisional.id) {
        // Reinstall: keep the canonical row (sealed-config AAD is its id).
        await tx
          .delete(pluginsTable)
          .where(eq(pluginsTable.id, provisional.id));
        return existing;
      }

      const [adopted] = await tx
        .update(pluginsTable)
        .set({ pluginId: input.pluginId, updatedAt: new Date() })
        .where(eq(pluginsTable.id, provisional.id))
        .returning();
      return adopted ?? null;
    });
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

// ---------------------------------------------------------------------------
// fileManifests / workspaceObjects (P7 Task 6 — workspace state-hydrator).
//
// fileManifests is the per-session hibernate/hydrate state machine; every
// transition is ONE conditional UPDATE so concurrent workers can never
// clobber each other (the same claim discipline as runs.claimNext). All
// transitions bump updated_at: the sweeper's stuck-row detection (T10) and
// the warm LRU order both read it as "when this state was entered / last
// refreshed".
//
// workspaceObjects is the R2 object ledger. Digests are supplied by the
// CALLER (the hibernator computes them from the bytes it just uploaded —
// R2's HEAD never returns a sha256, the T2 carry); this layer stores the
// exact strings, never re-derives or compares them numerically.
// ---------------------------------------------------------------------------

/** Global Constraints exact-arithmetic rule, enforced at the repo boundary. */
function assertBytes(field: string, value: number): void {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error(`${field} must be a safe integer >= 0 (got ${String(value)})`);
  }
}

/** assertBytes for nullable byte columns (du unknown → null is legal). */
function assertOptionalBytes(field: string, value: number | null): void {
  if (value !== null) assertBytes(field, value);
}

/** The tree a fresh warm row carries until the first markCold replaces it. */
function emptyUiTree(): UiManifest {
  return {
    version: 1,
    generatedAt: new Date().toISOString(),
    truncated: false,
    totals: { files: 0, dirs: 0, bytes: 0 },
    roots: [],
  };
}

/** contentType packToStorage puts on workspace archives (keys.ts layout). */
const ARCHIVE_CONTENT_TYPE = "application/x-ovid-ws+grouped";

export const fileManifests = {
  /** The session's manifest row, or null (warm-never-registered sessions have no row). */
  async get(db: Db, sessionId: string): Promise<FileManifestRow | null> {
    const [row] = await db
      .select()
      .from(fileManifestsTable)
      .where(eq(fileManifestsTable.sessionId, sessionId))
      .limit(1);
    return row ?? null;
  },

  /**
   * Register/refresh a warm row:
   *
   *   INSERT (state 'warm', generation 0, EMPTY uiTree) ON CONFLICT (session_id)
   *   DO UPDATE SET state='warm', workspace_bytes, updated_at
   *
   * The conflict arm NEVER touches generation, the archive_* fields, entryCount
   * or uiTree — re-warming after a cold cycle must preserve the last hibernate
   * ledger (a re-hibernate bumps generation in place on it). The sweeper calls
   * this both to register never-hibernated sessions and to refresh warm du's.
   */
  async upsertWarm(
    db: Db,
    i: { sessionId: string; userId: string; workspaceBytes: number | null },
  ): Promise<FileManifestRow> {
    assertOptionalBytes("workspaceBytes", i.workspaceBytes);
    const [row] = await db
      .insert(fileManifestsTable)
      .values({
        sessionId: i.sessionId,
        userId: i.userId,
        state: "warm",
        uiTree: emptyUiTree(),
        workspaceBytes: i.workspaceBytes,
      })
      .onConflictDoUpdate({
        target: fileManifestsTable.sessionId,
        set: {
          state: "warm",
          workspaceBytes: sql`excluded.workspace_bytes`,
          updatedAt: sql`now()`,
        },
      })
      .returning();
    return row!;
  },

  /**
   * Race-safe hibernate claim:
   *   UPDATE … SET state='hibernating' WHERE session_id AND state='warm'
   * Exactly one concurrent caller wins; the loser (already-claimed, cold, or
   * unknown session) gets false. updated_at is bumped WITH the claim — the
   * stuck-hibernation reconcile measures "time in this state" from it.
   */
  async beginHibernation(db: Db, sessionId: string): Promise<boolean> {
    const claimed = await db
      .update(fileManifestsTable)
      .set({ state: "hibernating", updatedAt: new Date() })
      .where(
        and(eq(fileManifestsTable.sessionId, sessionId), eq(fileManifestsTable.state, "warm")),
      )
      .returning({ sessionId: fileManifestsTable.sessionId });
    return claimed.length > 0;
  },

  /**
   * Terminal hibernate write — ONE unconditional UPDATE by session id (the
   * caller holds the beginHibernation claim): state 'cold', the full archive
   * ledger (generation, key, bytes, sha, entryCount, uiTree) and
   * workspace_bytes NULLed (the warm dir is gone).
   */
  async markCold(
    db: Db,
    i: {
      sessionId: string;
      generation: number;
      archiveKey: string;
      archiveBytes: number;
      archiveSha256: string;
      entryCount: number;
      uiTree: UiManifest;
    },
  ): Promise<void> {
    assertBytes("archiveBytes", i.archiveBytes);
    await db
      .update(fileManifestsTable)
      .set({
        state: "cold",
        generation: i.generation,
        archiveKey: i.archiveKey,
        archiveBytes: i.archiveBytes,
        archiveSha256: i.archiveSha256,
        entryCount: i.entryCount,
        uiTree: i.uiTree,
        workspaceBytes: null,
        updatedAt: new Date(),
      })
      .where(eq(fileManifestsTable.sessionId, i.sessionId));
  },

  /**
   * Race-safe hydration claim (beginHibernation's mirror): cold → hydrating,
   * exactly one winner; warm/hibernating/hydrating/unknown → false.
   */
  async beginHydration(db: Db, sessionId: string): Promise<boolean> {
    const claimed = await db
      .update(fileManifestsTable)
      .set({ state: "hydrating", updatedAt: new Date() })
      .where(
        and(eq(fileManifestsTable.sessionId, sessionId), eq(fileManifestsTable.state, "cold")),
      )
      .returning({ sessionId: fileManifestsTable.sessionId });
    return claimed.length > 0;
  },

  /**
   * Terminal hydrate write: state 'warm' + the fresh du. The archive ledger is
   * deliberately left in place (the R2 objects persist; the next hibernate
   * bumps generation over them) — only state, workspaceBytes and updated_at
   * move.
   */
  async markWarm(
    db: Db,
    i: { sessionId: string; workspaceBytes: number | null },
  ): Promise<void> {
    assertOptionalBytes("workspaceBytes", i.workspaceBytes);
    await db
      .update(fileManifestsTable)
      .set({ state: "warm", workspaceBytes: i.workspaceBytes, updatedAt: new Date() })
      .where(eq(fileManifestsTable.sessionId, i.sessionId));
  },

  /**
   * Failure restore for a hydrate attempt: hydrating → cold, and ONLY from
   * hydrating (the state re-check is the race guard — a concurrent transition
   * that already moved the row is never stomped). The T6 carry; the wiring
   * layer injects this into hydrateWorkspace's structural repo mirror.
   */
  async markColdRetry(db: Db, sessionId: string): Promise<void> {
    await db
      .update(fileManifestsTable)
      .set({ state: "cold", updatedAt: new Date() })
      .where(
        and(
          eq(fileManifestsTable.sessionId, sessionId),
          eq(fileManifestsTable.state, "hydrating"),
        ),
      )
      .returning({ sessionId: fileManifestsTable.sessionId });
  },

  /**
   * Eviction-candidate scan for the warm-cap LRU: every warm row, oldest
   * updated_at first (least-recently-refreshed = first to hibernate), capped
   * at one sweeper batch.
   */
  async listWarmForLru(
    db: Db,
  ): Promise<
    Array<{
      sessionId: string;
      userId: string;
      generation: number;
      workspaceBytes: number | null;
      updatedAt: Date;
    }>
  > {
    return db
      .select({
        sessionId: fileManifestsTable.sessionId,
        userId: fileManifestsTable.userId,
        generation: fileManifestsTable.generation,
        workspaceBytes: fileManifestsTable.workspaceBytes,
        updatedAt: fileManifestsTable.updatedAt,
      })
      .from(fileManifestsTable)
      .where(eq(fileManifestsTable.state, "warm"))
      .orderBy(asc(fileManifestsTable.updatedAt))
      .limit(1000);
  },

  /** Delete the row (reconcile's workspace_lost path). Idempotent. */
  async remove(db: Db, sessionId: string): Promise<void> {
    await db.delete(fileManifestsTable).where(eq(fileManifestsTable.sessionId, sessionId));
  },
};

export interface WorkspaceArchivePut {
  userId: string;
  sessionId: string;
  generation: number;
  /** Stable per session: users/{uid}/workspaces/{sid}.tar.zst */
  archiveKey: string;
  /** Stable per session: users/{uid}/workspaces/{sid}.manifest.json */
  manifestKey: string;
  /** Archive object size + digest (PackReport.bytes / PackReport.sha256Hex). */
  bytes: number;
  sha256: string;
  entryCount: number;
  /**
   * Sidecar object size + digest. The brief pins the manifest row to hold
   * "sha256 of sidecar bytes, bytes" — the hibernator computes both from the
   * encodeIndexWire bytes it just uploaded (T2 carry: R2 HEAD never returns
   * a digest, so the uploader is the only source). NOT the archive's values.
   */
  manifestBytes: number;
  manifestSha256: string;
}

export const workspaceObjects = {
  /**
   * Record a completed hibernate upload: upserts BOTH the archive row
   * (kind workspace_archive, meta {entryCount, zstdLevel: 9}) and the sidecar
   * row (kind workspace_manifest, the SIDECAR's own bytes/digest) on
   * ON CONFLICT (r2_key) — the keys are stable per session, so re-hibernates
   * bump generation in place and never duplicate rows. createdAt keeps the
   * first write; status is never touched here.
   */
  async putArchive(db: Db, i: WorkspaceArchivePut): Promise<void> {
    assertBytes("bytes", i.bytes);
    assertBytes("manifestBytes", i.manifestBytes);
    const archiveMeta = { entryCount: i.entryCount, zstdLevel: 9 };
    await db
      .insert(workspaceObjectsTable)
      .values({
        id: newId(),
        userId: i.userId,
        sessionId: i.sessionId,
        kind: "workspace_archive",
        r2Key: i.archiveKey,
        bytes: i.bytes,
        sha256: i.sha256,
        contentType: ARCHIVE_CONTENT_TYPE,
        generation: i.generation,
        meta: archiveMeta,
      })
      .onConflictDoUpdate({
        target: workspaceObjectsTable.r2Key,
        set: {
          userId: i.userId,
          sessionId: i.sessionId,
          bytes: i.bytes,
          sha256: i.sha256,
          contentType: ARCHIVE_CONTENT_TYPE,
          generation: i.generation,
          meta: archiveMeta,
        },
      });
    await db
      .insert(workspaceObjectsTable)
      .values({
        id: newId(),
        userId: i.userId,
        sessionId: i.sessionId,
        kind: "workspace_manifest",
        r2Key: i.manifestKey,
        bytes: i.manifestBytes,
        sha256: i.manifestSha256,
        contentType: "application/json",
      })
      .onConflictDoUpdate({
        target: workspaceObjectsTable.r2Key,
        set: {
          userId: i.userId,
          sessionId: i.sessionId,
          bytes: i.manifestBytes,
          sha256: i.manifestSha256,
          contentType: "application/json",
        },
      });
  },

  /**
   * Insert an artifact row (the artifacts pipeline's registerArtifact, T9):
   * id/r2Key are caller-generated (the id IS the keyset cursor), meta carries
   * the display name. Not an upsert — a duplicate r2Key raises the UNIQUE
   * violation, which the caller surfaces.
   */
  async registerArtifact(
    db: Db,
    i: {
      id: string;
      userId: string;
      sessionId: string;
      r2Key: string;
      bytes: number;
      sha256: string;
      contentType: string;
      meta: { name: string };
    },
  ): Promise<WorkspaceObjectRow> {
    assertBytes("bytes", i.bytes);
    const [row] = await db
      .insert(workspaceObjectsTable)
      .values({
        id: i.id,
        userId: i.userId,
        sessionId: i.sessionId,
        kind: "artifact",
        r2Key: i.r2Key,
        bytes: i.bytes,
        sha256: i.sha256,
        contentType: i.contentType,
        meta: i.meta,
      })
      .returning();
    return row!;
  },

  /**
   * The session's active artifacts, newest-first keyset page by id (UUIDv7 ⇒
   * id order = insertion order; messages.page convention). `beforeId`
   * excludes itself; nextCursor is the oldest id on the page. Deleted rows
   * never list.
   */
  async listArtifacts(
    db: Db,
    sessionId: string,
    opts: { limit: number; beforeId?: string | null },
  ): Promise<{ rows: WorkspaceObjectRow[]; nextCursor: string | null }> {
    const where = opts.beforeId
      ? and(
          eq(workspaceObjectsTable.sessionId, sessionId),
          eq(workspaceObjectsTable.kind, "artifact"),
          eq(workspaceObjectsTable.status, "active"),
          lt(workspaceObjectsTable.id, opts.beforeId),
        )
      : and(
          eq(workspaceObjectsTable.sessionId, sessionId),
          eq(workspaceObjectsTable.kind, "artifact"),
          eq(workspaceObjectsTable.status, "active"),
        );
    const found = await db
      .select()
      .from(workspaceObjectsTable)
      .where(where)
      .orderBy(desc(workspaceObjectsTable.id))
      .limit(opts.limit + 1);
    const hasMore = found.length > opts.limit;
    const rows = hasMore ? found.slice(0, opts.limit) : found;
    const last = rows[rows.length - 1];
    return { rows, nextCursor: hasMore && last ? last.id : null };
  },

  /** Ownership-scoped fetch: null on unknown id OR wrong owner (404 rule). */
  async getArtifact(
    db: Db,
    artifactId: string,
    userId: string,
  ): Promise<WorkspaceObjectRow | null> {
    const [row] = await db
      .select()
      .from(workspaceObjectsTable)
      .where(and(eq(workspaceObjectsTable.id, artifactId), eq(workspaceObjectsTable.userId, userId)))
      .limit(1);
    return row ?? null;
  },
};

// ---------------------------------------------------------------------------
// grants (P3 Task 12 — hierarchical permission grants, session-scoped).
//
// The matching/normalization core lives in @ovid/agent-core's grants.ts;
// this layer only persists and reads rows. Rows are written by the
// approval gate (decision "always" + targets) and read on every approve()
// call — listForSession is the gate's single read per request.
// ---------------------------------------------------------------------------

export interface GrantAdd {
  userId: string;
  sessionId: string;
  /** "path" | "host" */
  kind: string;
  /** Normalized by kind (the gate normalizes before writing). */
  pattern: string;
  /** "allow" | "always" | "deny" */
  decision: string;
  /** Audit metadata only — decisions apply across modes. */
  mode?: string | null;
}

export const grantsRepo = {
  /**
   * The session's grants, insertion order (createdAt then id — the
   * messages-page convention; UUIDv7 ids make id order = insertion order).
   * Scoped by BOTH userId and sessionId: no cross-user, no cross-session
   * leakage.
   */
  async listForSession(db: Db, userId: string, sessionId: string): Promise<GrantRow[]> {
    return db
      .select()
      .from(grantsTable)
      .where(and(eq(grantsTable.userId, userId), eq(grantsTable.sessionId, sessionId)))
      .orderBy(asc(grantsTable.createdAt), asc(grantsTable.id));
  },

  /** Plain insert — callers normalize patterns by kind before writing. */
  async add(db: Db, g: GrantAdd): Promise<GrantRow> {
    const [row] = await db
      .insert(grantsTable)
      .values({
        id: newId(),
        userId: g.userId,
        sessionId: g.sessionId,
        kind: g.kind,
        pattern: g.pattern,
        decision: g.decision,
        mode: g.mode ?? null,
      })
      .returning();
    return row!;
  },

  /** true iff the row existed AND was owned by userId. */
  async remove(db: Db, grantId: string, userId: string): Promise<boolean> {
    const removed = await db
      .delete(grantsTable)
      .where(and(eq(grantsTable.id, grantId), eq(grantsTable.userId, userId)))
      .returning({ id: grantsTable.id });
    return removed.length > 0;
  },
};

// ---------------------------------------------------------------------------
// session state (P3 Task 13 — the Postgres SessionStateStore backing store).
//
// GET-VS-PATCH SEMANTICS (the pinned ruling replacing T1's fake):
//   get():   a PURE READ. A missing row answers the Task-1 zero state
//            computed in memory — NO row is materialized (T1's fake
//            materializes-and-caches; the Postgres store never writes on
//            read, so a read can never fail on a locked row or create
//            state for a session that has none).
//   patch(): an ATOMIC UPSERT. The stored JSON is the merge of the existing
//            state and the patch — jsonb `||`, i.e. the Object.assign
//            semantics of T1's fake (top-level keys replace wholesale;
//            arrays replace wholesale). The insert seeds the zero state, so
//            every row stores the WHOLE SessionAgentState. A patch for an
//            unknown session raises the sessions FK violation (23503) —
//            loud, never a silent zero row.
// ---------------------------------------------------------------------------

/** SessionMode mirrored from @ovid/agent-core types.ts (db cannot import it). */
type SessionModeJson = "safe" | "auto" | "drive" | "studio";

/**
 * Structural port of @ovid/agent-core's SessionAgentState (ports.ts — the
 * parity reference). agent-core's stateStore.ts assigns this type to the
 * canonical interface, so any drift between the two shapes fails compilation
 * there — the seam IS the drift alarm.
 */
export interface SessionAgentStateJson {
  todos: Array<{ content: string; status: "pending" | "in_progress" | "completed" }>;
  goal: { objective: string; notes: string } | null;
  presetId: string | null;
  planMode: boolean;
  planPreMode: SessionModeJson | null;
  pendingPlanMode: boolean | null;
  compaction: { ledger: unknown; summary: string | null; cutoffMessageId: string | null; compactedAtCount: number } | null;
  mode: SessionModeJson;
  modelPin: string | null;
  activeSkillScopes: string[];
}

/** The Task-1 zero state (mode "auto" per Dart state.dart:1611). */
export function zeroSessionAgentState(): SessionAgentStateJson {
  return {
    todos: [],
    goal: null,
    presetId: null,
    planMode: false,
    planPreMode: null,
    pendingPlanMode: null,
    compaction: null,
    mode: "auto",
    modelPin: null,
    activeSkillScopes: [],
  };
}

export const sessionState = {
  /**
   * The session's agent state; a missing row folds to the zero state WITHOUT
   * writing anything (see the get-vs-patch note above).
   */
  async get(db: Db, sessionId: string): Promise<SessionAgentStateJson> {
    const [row] = await db
      .select({ state: sessionAgentStateTable.state })
      .from(sessionAgentStateTable)
      .where(eq(sessionAgentStateTable.sessionId, sessionId));
    // patch() always stores the complete merged state; the zero-fold is
    // defensive for rows written by any other hand.
    return { ...zeroSessionAgentState(), ...(row?.state ?? {}) };
  },

  /**
   * Atomic shallow-merge upsert of the whole-state JSON. ONE statement:
   *   INSERT (sessionId, zero || patch)
   *   ON CONFLICT (session_id) DO UPDATE SET state = state || patch
   * so concurrent patches can never lose one another's keys (last writer
   * wins per key — same observable outcome as the T1 fake).
   */
  async patch(db: Db, sessionId: string, p: Partial<SessionAgentStateJson>): Promise<void> {
    await db
      .insert(sessionAgentStateTable)
      .values({ sessionId, state: { ...zeroSessionAgentState(), ...p } })
      .onConflictDoUpdate({
        target: sessionAgentStateTable.sessionId,
        set: {
          // The table-qualified column in DO UPDATE SET is the EXISTING row.
          state: sql`COALESCE(${sessionAgentStateTable.state}, '{}'::jsonb) || ${JSON.stringify(p)}::jsonb`,
        },
      });
  },
};

// ---------------------------------------------------------------------------
// messages FTS search (P3 Task 13 — searchMessages over the generated
// search_vector column; the cloud port of Dart's SessionSearch).
//
// Dart parity carried over: literal-term AND (plainto_tsquery), quoted
// phrases match the literal phrase (websearch_to_tsquery, session_search.dart
// _literalQuery), cover-density ranking (ts_rank_cd ≈ bm25's role), snippet
// excerpts with Dart's →/← highlight markers, limit clamp at 100
// (maxLimit), offset clamp at 100000 (maxCursor), query clamp at 4096 UTF-16
// units (maxQueryLength) with NULs replaced. Ownership is enforced by the
// sessions join: a cross-user query returns ZERO ROWS, never an error.
// ---------------------------------------------------------------------------

/** Dart SessionSearch.maxLimit parity. */
export const MESSAGES_SEARCH_MAX_LIMIT = 100;
/** Dart SessionSearch.maxCursor parity (0-based offset bound). */
export const MESSAGES_SEARCH_MAX_OFFSET = 100_000;
/** Dart SessionSearch.maxQueryLength parity (UTF-16 code units). */
export const MESSAGES_SEARCH_MAX_QUERY_UTF16 = 4096;

export interface SearchMessagesOptions {
  limit?: number;
  offset?: number;
  /** Restrict to one session (still ownership-checked via the join). */
  sessionId?: string;
}

export interface SearchMessagesRow {
  messageId: string;
  sessionId: string;
  role: string;
  rank: number;
  snippet: string;
}

/**
 * Full-text search over message bodies, scoped to `userId`. Returns the
 * ranked page (ts_rank_cd DESC, then session id and message id for stable
 * ties — Dart's ORDER BY rank, sessionId, …, rowid) plus `total` = the count
 * over the same filter (paging math without a second search).
 */
export async function searchMessages(
  db: Db,
  userId: string,
  query: string,
  o: SearchMessagesOptions = {},
): Promise<{ rows: SearchMessagesRow[]; total: number }> {
  // Clamps first — a query that clamps to nothing answers empty without
  // touching Postgres (Dart's empty-matchQuery early return).
  const q = query
    .slice(0, MESSAGES_SEARCH_MAX_QUERY_UTF16)
    .replace(/\u0000/g, " ")
    .trim();
  if (q === "") return { rows: [], total: 0 };
  const limit = Math.min(Math.max(o.limit ?? 20, 0), MESSAGES_SEARCH_MAX_LIMIT);
  const offset = Math.min(Math.max(o.offset ?? 0, 0), MESSAGES_SEARCH_MAX_OFFSET);

  // Literal-phrase parity: a double-quoted run switches the whole query to
  // websearch grammar ("…" = literal adjacent phrase, other terms still AND);
  // otherwise plainto ANDs every term with no operator interpretation. An
  // unterminated quote fails the regex and degrades to plainto — Dart's
  // '"red' case (three bare-term hits).
  const tsQuery = /"[^"]+"/.test(q)
    ? sql`websearch_to_tsquery('simple', ${q})`
    : sql`plainto_tsquery('simple', ${q})`;

  const where = and(
    eq(sessionsTable.userId, userId),
    sql`${messagesTable.searchVector} @@ ${tsQuery}`,
    o.sessionId !== undefined ? eq(messagesTable.sessionId, o.sessionId) : undefined,
  );

  const rank = sql<number>`ts_rank_cd(${messagesTable.searchVector}, ${tsQuery})::float8`;
  const rows = await db
    .select({
      messageId: messagesTable.id,
      sessionId: messagesTable.sessionId,
      role: messagesTable.role,
      rank,
      snippet: sql<string>`ts_headline('simple', ${messagesTable.content}, ${tsQuery}, 'StartSel=→, StopSel=←, MaxFragments=2, MaxWords=12, MinWords=3')`,
    })
    .from(messagesTable)
    .innerJoin(sessionsTable, eq(messagesTable.sessionId, sessionsTable.id))
    .where(where)
    .orderBy(desc(rank), asc(messagesTable.sessionId), asc(messagesTable.id))
    .limit(limit)
    .offset(offset);

  const [countRow] = await db
    .select({ total: sql<number>`count(*)::int` })
    .from(messagesTable)
    .innerJoin(sessionsTable, eq(messagesTable.sessionId, sessionsTable.id))
    .where(where);

  return { rows, total: countRow?.total ?? 0 };
}

