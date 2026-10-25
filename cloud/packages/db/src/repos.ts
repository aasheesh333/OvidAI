import { and, asc, desc, eq, gt, gte, inArray, isNull, lt, lte, ne, or, sql } from "drizzle-orm";
import { uuidv7 } from "uuidv7";
import type { MessageDto, SessionEvent, SessionEventType, UiManifest } from "@ovid/shared";
import type { Db } from "./client.js";
import { lockProjectFiles, projectFileUsage, ProjectFileLimitError } from "./projectFiles.js";
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
// user preferences (Wave 1a — SE-005 / R1)
// ---------------------------------------------------------------------------

/** Structural copy of @ovid/shared's UserPreferences (kept in sync). */
export interface UserPreferencesJson {
  memoryEnabled: boolean;
  shareSessionMemory: boolean;
  showReasoning: boolean;
}

function preferencesFrom(raw: unknown): UserPreferencesJson {
  const o = (raw ?? {}) as Record<string, unknown>;
  return {
    memoryEnabled: typeof o.memoryEnabled === "boolean" ? o.memoryEnabled : true,
    shareSessionMemory: typeof o.shareSessionMemory === "boolean" ? o.shareSessionMemory : false,
    showReasoning: typeof o.showReasoning === "boolean" ? o.showReasoning : true,
  };
}

export const userPreferences = {
  /**
   * The user's preferences with defaults applied (memory on, cross-session
   * sharing OFF). An unknown user reads the defaults — fail-closed for R1.
   */
  async get(db: Db, uid: string): Promise<UserPreferencesJson> {
    const [row] = await db
      .select({ preferences: usersTable.preferences })
      .from(usersTable)
      .where(eq(usersTable.uid, uid));
    return preferencesFrom(row?.preferences);
  },

  /**
   * Merges [patch] into the stored preferences (provisioning the users row
   * when absent) and returns the full effective preferences.
   */
  async patch(
    db: Db,
    uid: string,
    patch: Partial<UserPreferencesJson>,
  ): Promise<UserPreferencesJson> {
    const clean: Record<string, boolean> = {};
    if (typeof patch.memoryEnabled === "boolean") clean.memoryEnabled = patch.memoryEnabled;
    if (typeof patch.shareSessionMemory === "boolean") {
      clean.shareSessionMemory = patch.shareSessionMemory;
    }
    if (typeof patch.showReasoning === "boolean") clean.showReasoning = patch.showReasoning;
    const [row] = await db
      .insert(usersTable)
      .values({ uid, preferences: clean })
      .onConflictDoUpdate({
        target: usersTable.uid,
        set: {
          preferences: sql`COALESCE(${usersTable.preferences}, '{}'::jsonb) || ${JSON.stringify(clean)}::jsonb`,
        },
      })
      .returning({ preferences: usersTable.preferences });
    return preferencesFrom(row?.preferences);
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

// Opaque keyset cursor for sessions.list: "<activity-or-created epoch ms>~<session id>".
function encodeSessionCursor(row: SessionRow, immutable = false): string {
  return `${(immutable ? row.createdAt : row.updatedAt).getTime()}~${row.id}`;
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
      .where(
        and(
          eq(sessionsTable.id, sessionId),
          eq(sessionsTable.userId, userId),
          isNull(sessionsTable.deletedAt),
        ),
      )
      .limit(1);
    return rows[0] ?? null;
  },

  /**
   * Wave 1a (R1 @-mentions): the caller's live sessions whose title matches
   * one of [titles] case-insensitively (trimmed). Ownership-scoped and
   * deleted-filtered; returns {id, title} for every match (the caller decides
   * what an ambiguous title means). Bounded: at most 20 titles are looked up.
   */
  async findByTitles(
    db: Db,
    userId: string,
    titles: readonly string[],
  ): Promise<Array<{ id: string; title: string }>> {
    const wanted = [...new Set(titles.map((t) => t.trim().toLowerCase()).filter((t) => t !== ""))].slice(0, 20);
    if (wanted.length === 0) return [];
    const rows = await db
      .select({ id: sessionsTable.id, title: sessionsTable.title })
      .from(sessionsTable)
      .where(
        and(
          eq(sessionsTable.userId, userId),
          isNull(sessionsTable.deletedAt),
          inArray(sql`lower(btrim(${sessionsTable.title}))`, wanted),
        ),
      )
      .limit(200);
    return rows
      .filter((r): r is { id: string; title: string } => r.title !== null)
      .map((r) => ({ id: r.id.trim(), title: r.title }));
  },

  /** Most recent activity first; keyset cursor over (updatedAt, id). Invalid cursors restart from the beginning. */
  async list(
    db: Db,
    userId: string,
    limit: number,
    cursor?: string | null,
    immutable = false,
    snapshotMs?: number,
  ): Promise<{ rows: SessionRow[]; nextCursor: string | null }> {
    const key = decodeSessionCursor(cursor);
    // deleted_at IS NULL: soft-deleted sessions never appear in the list —
    // the client's refresh must not resurrect a deleted chat.
    const alive = isNull(sessionsTable.deletedAt);
    const activity = immutable ? sessionsTable.createdAt : sessionsTable.updatedAt;
    const where = key
      ? and(
          eq(sessionsTable.userId, userId),
          alive,
          or(
            lt(activity, key.updatedAt),
            and(eq(activity, key.updatedAt), lt(sessionsTable.id, key.id)),
          ),
        )
      : and(
          eq(sessionsTable.userId, userId),
          alive,
          ...(immutable ? [lte(sessionsTable.createdAt, new Date(snapshotMs!))] : []),
        );
    const found = await db
      .select()
      .from(sessionsTable)
      .where(where)
      .orderBy(desc(activity), desc(sessionsTable.id))
      .limit(limit + 1);
    const hasMore = found.length > limit;
    const rows = hasMore ? found.slice(0, limit) : found;
    const last = rows[rows.length - 1];
    return {
      rows,
      nextCursor: hasMore && last ? encodeSessionCursor(last, immutable) : null,
    };
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
    fields: { title?: string | null; mode?: string; pinned?: boolean },
  ): Promise<SessionRow | null> {
    const set: {
      title?: string | null;
      mode?: string;
      pinnedAt?: Date | null;
      updatedAt: Date;
    } = {
      updatedAt: new Date(),
    };
    if (fields.title !== undefined) set.title = fields.title;
    if (fields.mode !== undefined) set.mode = fields.mode;
    // Pinning is a timestamp, not a flag: unpinning clears it, and the value
    // gives a stable order among pinned chats. Re-pinning an already pinned
    // chat keeps the original instant so the row does not jump.
    if (fields.pinned !== undefined) {
      set.pinnedAt = fields.pinned ? new Date() : null;
    }
    const rows = await db
      .update(sessionsTable)
      .set(set)
      .where(
        and(
          eq(sessionsTable.id, sessionId),
          eq(sessionsTable.userId, userId),
          isNull(sessionsTable.deletedAt),
        ),
      )
      .returning();
    return rows[0] ?? null;
  },

  /**
   * Ownership-scoped soft delete (DELETE /sessions/:id): UPDATE … SET
   * deleted_at = now WHERE id AND userId AND deleted_at IS NULL RETURNING
   * row. null = unknown id, wrong owner, OR already deleted (the gateway
   * maps all three to the same 404 — no existence leaks, same as get).
   * The row itself stays (messages/runs are history); every read path
   * filters deleted_at IS NULL. `updatedAt` deliberately stays untouched:
   * the row is invisible to ordering once deleted.
   */
  async softDelete(db: Db, sessionId: string, userId: string): Promise<SessionRow | null> {
    const rows = await db
      .update(sessionsTable)
      .set({ deletedAt: new Date() })
      .where(
        and(
          eq(sessionsTable.id, sessionId),
          eq(sessionsTable.userId, userId),
          isNull(sessionsTable.deletedAt),
        ),
      )
      .returning();
    return rows[0] ?? null;
  },
};

// ---------------------------------------------------------------------------
// messages
// ---------------------------------------------------------------------------

/**
 * Edit/regenerate would invalidate lossless-compaction replay or exact recall.
 * The transaction performs no destructive write when this is thrown.
 */
export class CompactedHistoryTruncationError extends Error {
  readonly name = "CompactedHistoryTruncationError";
  readonly code = "compacted_history_truncation";

  constructor(readonly sessionId: string, readonly fromId: string) {
    super("Truncation is fenced while the session has compaction replay state or the deleted span is referenced by exact recall.");
  }
}

export class StaleCompactionInputError extends Error {
  readonly name = "StaleCompactionInputError";
  readonly code = "stale_compaction_input";

  constructor(readonly sessionId: string, readonly messageId: string) {
    super("Compaction input no longer matches its canonical message; rebuild it before folding or replaying.");
  }
}

type RepoTx = Parameters<Parameters<Db["transaction"]>[0]>[0];

export interface CompactionCanonicalInputMessage {
  readonly id?: string;
  readonly role: string;
  readonly content: string;
}

/**
 * Session-scoped serialization shared by truncation and 0039 writers.
 * truncateFrom takes it before any anchor read. After canonical actor
 * validation, foldCheckpoint/appendExactItem take it before any canonical or
 * history resolution, cursor insertion, replay lookup or outcome construction.
 *
 * - truncateFrom uses `exclusive`, serializing same-session truncations.
 * - foldCheckpoint and appendExactItem use `shared`, allowing independent
 *   actors while excluding truncation for the duration of the transaction.
 * - Worker parent-owned event/approval writers lock parent then child in
 *   that order; parent truncation takes the same parent gate and sees
 *   child-scoped references before deleting the event.
 *
 * Fold supplies its COMPLETE input, not merely the folded prefix. Every input
 * message with a canonical ID is locked FOR SHARE and compared by session,
 * role and content before any cursor/replay/outcome work. Thus a tail deleted
 * before the first fold produces stale_compaction_input and rolls back,
 * instead of creating or replaying an outcome containing missing history.
 * Noncanonical/sealed messages have no message-row check here; their exact
 * object validation remains owned by the compaction repository.
 *
 * These are row locks only: no table lock is acquired and unrelated sessions
 * retain normal reads/writes. A missing session is left to the caller's actor
 * or anchor validation, preserving their established error behavior.
 */
export async function lockCompactionSession(
  tx: RepoTx,
  sessionId: string,
  options: {
    mode: "shared" | "exclusive";
    messages?: readonly CompactionCanonicalInputMessage[];
  },
): Promise<void> {
  const sessionRows = options.mode === "shared"
    ? await tx.select({ id: sessionsTable.id }).from(sessionsTable)
      .where(eq(sessionsTable.id, sessionId)).for("share").limit(1)
    : await tx.select({ id: sessionsTable.id }).from(sessionsTable)
      .where(eq(sessionsTable.id, sessionId)).for("update").limit(1);
  if (sessionRows[0] === undefined || options.messages === undefined) return;

  const expected = options.messages.filter(
    (message): message is CompactionCanonicalInputMessage & { readonly id: string } =>
      typeof message.id === "string" && message.id.length > 0,
  );
  if (expected.length === 0) return;
  const ids = [...new Set(expected.map((message) => message.id))];
  const canonical = await tx.select({
    id: messagesTable.id,
    role: messagesTable.role,
    content: messagesTable.content,
  }).from(messagesTable)
    .where(and(eq(messagesTable.sessionId, sessionId), inArray(messagesTable.id, ids)))
    .orderBy(asc(messagesTable.id))
    .for("share");
  const byId = new Map(canonical.map((row) => [row.id, row]));
  for (const message of expected) {
    const row = byId.get(message.id);
    if (row === undefined || row.role !== message.role || row.content !== message.content) {
      throw new StaleCompactionInputError(sessionId, message.id);
    }
  }
}

export const messages = {
  async append(
    db: Db,
    m: {
      sessionId: string;
      role: MessageRole;
      content: string;
      clientMsgId?: string;
      /**
       * The provider's thinking for an assistant turn, when captured. Omitted
       * → NULL (the common case: user/system/tool rows and models that expose
       * no reasoning). Never folded into `content`.
       */
      reasoning?: string | null;
    },
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
        ...(m.reasoning !== undefined ? { reasoning: m.reasoning } : {}),
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

  /** Wave 1b: one message of THIS session (session-scoped), or null. */
  async getInSession(db: Db, sessionId: string, messageId: string): Promise<MessageRow | null> {
    const rows = await db
      .select()
      .from(messagesTable)
      .where(and(eq(messagesTable.sessionId, sessionId), eq(messagesTable.id, messageId)))
      .limit(1);
    return rows[0] ?? null;
  },

  /**
   * Wave 1b (regenerate): the newest USER row strictly before [beforeId] in
   * id order — the prompt an assistant answer replied to — or null.
   */
  async latestUserBefore(db: Db, sessionId: string, beforeId: string): Promise<MessageRow | null> {
    const rows = await db
      .select()
      .from(messagesTable)
      .where(
        and(
          eq(messagesTable.sessionId, sessionId),
          eq(messagesTable.role, "user"),
          lt(messagesTable.id, beforeId),
        ),
      )
      .orderBy(desc(messagesTable.id))
      .limit(1);
    return rows[0] ?? null;
  },

  /**
   * Wave 1b (CT-004 delete / edit / regenerate): removes [fromId] and every
   * later row of the session (id order), plus the durable event-mirror rows
   * recorded at or after `opts.eventsFrom` (default: the anchor's createdAt;
   * an answer's own tool events precede it, so callers removing an answer
   * pass its prompt's createdAt) — so a rich history page can
   * never resurrect the tool rows of a deleted turn. One transaction. A
   * compaction checkpoint whose fold boundary sits inside the deleted span
   * would summarize rows that no longer exist: the session's compaction
   * state is reset in that case (the next long run re-compacts). Returns the
   * number of message rows removed (0 when the anchor is not in the session).
   */
  async truncateFrom(
    db: Db,
    sessionId: string,
    fromId: string,
    opts: { eventsFrom?: Date; keepAnchor?: boolean } = {},
  ): Promise<number> {
    return db.transaction(async (tx) => {
      // Acquire the same target-session gate used by 0039 writers before any
      // anchor/cursor reads. Same-session truncations therefore serialize on
      // one row; no compatible table lock is upgraded behind another reader.
      await lockCompactionSession(tx, sessionId, { mode: "exclusive" });
      const anchorRows = await tx
        .select()
        .from(messagesTable)
        .where(and(eq(messagesTable.sessionId, sessionId), eq(messagesTable.id, fromId)))
        .limit(1);
      const anchor = anchorRows[0];
      if (anchor === undefined) return 0;

      const stateRows = await tx
        .select()
        .from(sessionAgentStateTable)
        .where(eq(sessionAgentStateTable.sessionId, sessionId))
        .limit(1);
      const stateRow = stateRows[0];
      const json = stateRow?.state as { compaction?: { cutoffMessageId?: string | null } | null } | undefined;
      const cutoff = json?.compaction?.cutoffMessageId ?? null;
      const removed = cutoff !== null && (opts.keepAnchor === true ? cutoff > fromId : cutoff >= fromId);
      const resetLegacyCompaction = json?.compaction != null && (cutoff === null || removed);
      const messageCut = opts.keepAnchor === true ? sql`m.id > ${fromId}` : sql`m.id >= ${fromId}`;
      const eventsFrom = opts.eventsFrom ?? anchor.createdAt;
      const legacyStateRef = `postgres:session_agent_state/${sessionId}#compaction`;
      const fencedRows = await tx.execute(sql`
        SELECT (
          -- Persisted runtime replay is session-wide: truncateFrom has no actor
          -- argument and its message/event cut can cross every actor's input.
          EXISTS (
            SELECT 1 FROM compaction_cursors c
             WHERE c.session_id = ${sessionId}
          )
          OR EXISTS (
            SELECT 1 FROM compaction_checkpoints c
             WHERE c.session_id = ${sessionId} AND c.actor_kind IS NOT NULL
          )
          -- Migration-backfilled and manually appended exact history can exist
          -- without a runtime cursor. Fence only the destructive span there.
          OR EXISTS (
            SELECT 1
              FROM messages m
             WHERE m.session_id = ${sessionId}
               AND ${messageCut}
               AND (
                 EXISTS (
                   SELECT 1 FROM compaction_history_items h
                    WHERE h.session_id = m.session_id
                      AND h.object_ref = 'postgres:messages/' || m.id
                 )
                 OR EXISTS (
                   SELECT 1 FROM compaction_checkpoints c
                    WHERE c.session_id = m.session_id AND c.cutoff_message_id = m.id
                 )
               )
          )
          OR EXISTS (
            SELECT 1
              FROM session_event_mirror e
             WHERE e.session_id = ${sessionId}
               AND e.ts >= ${eventsFrom}
               AND EXISTS (
                 SELECT 1 FROM compaction_history_items h
                  -- Child-scoped worker history may reference this parent
                  -- event; match the owner reference, not h.session_id.
                  WHERE h.object_ref = 'postgres:session_event_mirror/' || e.session_id || '/' || e.seq
               )
          )
          OR (
            ${resetLegacyCompaction}
            AND EXISTS (
              SELECT 1 FROM compaction_history_items h
               WHERE h.session_id = ${sessionId} AND h.object_ref = ${legacyStateRef}
            )
          )
        ) AS blocked
      `) as unknown as Array<{ blocked: boolean }>;
      if (fencedRows[0]?.blocked === true) {
        throw new CompactedHistoryTruncationError(sessionId, fromId);
      }

      // keepAnchor: everything AFTER the anchor goes, the anchor stays (a
      // prompt re-run keeps its own row).
      const deleted = await tx
        .delete(messagesTable)
        .where(
          and(
            eq(messagesTable.sessionId, sessionId),
            opts.keepAnchor === true ? gt(messagesTable.id, fromId) : gte(messagesTable.id, fromId),
          ),
        )
        .returning({ id: messagesTable.id });
      await tx
        .delete(sessionEventMirror)
        .where(
          and(
            eq(sessionEventMirror.sessionId, sessionId),
            gte(sessionEventMirror.ts, eventsFrom),
          ),
        );
      if (stateRow !== undefined && resetLegacyCompaction) {
        await tx
          .update(sessionAgentStateTable)
          .set({ state: { ...stateRow.state, compaction: null } })
          .where(eq(sessionAgentStateTable.sessionId, sessionId));
      }
      return deleted.length;
    });
  },

  /**
   * Wave 1b (branch): copies [rows] (oldest-first) into [targetSessionId]
   * with fresh time-ordered ids, keeping each row's role, content and
   * createdAt. One statement; returns the number inserted.
   */
  async copyInto(
    db: Db,
    targetSessionId: string,
    rows: ReadonlyArray<Pick<MessageRow, "role" | "content" | "createdAt">>,
  ): Promise<number> {
    if (rows.length === 0) return 0;
    const inserted = await db
      .insert(messagesTable)
      .values(
        rows.map((r) => ({
          id: newId(),
          sessionId: targetSessionId,
          role: r.role,
          content: r.content,
          createdAt: r.createdAt,
        })),
      )
      .returning({ id: messagesTable.id });
    return inserted.length;
  },

  /**
   * Wave 1b (branch): the session's rows up to and including [throughId],
   * oldest-first, keeping at most the [limit] newest of them.
   */
  async upTo(db: Db, sessionId: string, throughId: string, limit: number): Promise<MessageRow[]> {
    const rows = await db
      .select()
      .from(messagesTable)
      .where(and(eq(messagesTable.sessionId, sessionId), lte(messagesTable.id, throughId)))
      .orderBy(desc(messagesTable.id))
      .limit(limit);
    return rows.reverse();
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
   * Cross-session liveness guard, the runs half: the user's oldest
   * still-active (queued|running) run on any session OTHER than
   * `exceptSessionId`, or null. runs has no user_id, so user scoping rides
   * the sessions join (the same shape as runs.get). P2's agent workspace is
   * PER-USER (`{workspacesRoot}/{uid}/workspace`, shared by every session of
   * the user), so a hydrate/hibernate keyed by one session must refuse to
   * destroy that dir while a sibling session's run is still reading and
   * writing it — the same hazard warmLru.reclaimColdResidue documents
   * ("another session of the same user may still be warm and using that
   * dir … removing it would destroy a live workspace"). Used by
   * @ovid/storage's liveSessionGuard through the structural-mirror pattern
   * (this package is never imported there; see hydrate.ts's header).
   */
  async activeForUserExcept(
    db: Db,
    userId: string,
    exceptSessionId: string,
  ): Promise<RunRow | null> {
    const rows = await db
      .select({ run: runsTable })
      .from(runsTable)
      .innerJoin(sessionsTable, eq(runsTable.sessionId, sessionsTable.id))
      .where(
        and(
          eq(sessionsTable.userId, userId),
          ne(runsTable.sessionId, exceptSessionId),
          inArray(runsTable.status, [...ACTIVE_RUN_STATUSES]),
        ),
      )
      .orderBy(asc(runsTable.createdAt), asc(runsTable.id))
      .limit(1);
    return rows[0]?.run ?? null;
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
   * Heartbeat stamp (stale-sweep fix round): marks the run as still-live.
   * The engine's per-run emit wrapper throttles this to at most one write
   * per RUN_HEARTBEAT_INTERVAL_MS, so a long run that keeps emitting never
   * looks stranded to the sweeper. An unknown id (a child run with no row)
   * updates nothing and throws nothing.
   */
  async bumpLastActive(db: Db, runId: string): Promise<void> {
    await db
      .update(runsTable)
      .set({ lastActiveAt: new Date() })
      .where(eq(runsTable.id, runId));
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
      .where(
        and(
          eq(runsTable.id, runId),
          eq(sessionsTable.userId, userId),
          isNull(sessionsTable.deletedAt),
        ),
      )
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
      .where(and(eq(sessionsTable.userId, userId), isNull(sessionsTable.deletedAt)));
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
   * Runs stuck in 'running' whose LAST ACTIVITY is older than the cutoff,
   * oldest first, capped at 100 per call (one sweeper batch). Activity is
   * last_active_at — the engine's per-emit heartbeat — falling back to
   * started_at for rows that predate the column (or never emitted): a long
   * run still streaming deltas keeps its heartbeat fresh and stays invisible
   * here, while a crashed worker's row goes quiet. With BullMQ attempts:1
   * a failed or crashed job is NEVER redelivered, so a quiet row would strand
   * in 'running' forever; the worker's stale-run sweeper (apps/worker
   * staleRuns.ts) uses this to terminalize them. NULLs in BOTH columns
   * (queued rows; cannot exist for 'running' with a heartbeat-less engine,
   * but SQL semantics hold) are excluded by the `<`.
   */
  async listStaleRunning(db: Db, staleBefore: Date): Promise<RunRow[]> {
    // ISO string, not the Date: with a raw-SQL left side drizzle cannot apply
    // the timestamptz driver mapping, and postgres.js refuses a Date param
    // under the declared timestamptz OID (the column-typed lt() calls map it;
    // this expression-typed one must map it by hand).
    const lastActive = sql`COALESCE(${runsTable.lastActiveAt}, ${runsTable.startedAt})`;
    return db
      .select()
      .from(runsTable)
      .where(and(eq(runsTable.status, "running"), lt(lastActive, staleBefore.toISOString())))
      .orderBy(asc(lastActive))
      .limit(100);
  },

  /**
   * Runs stranded in 'queued' whose last activity is older than the cutoff —
   * the worker-death-mid-C1-wait pathology. With BullMQ attempts:1 a job that
   * dies while its run waits for the session turn is NEVER redelivered, so
   * the row strands 'queued' forever while remaining the session's oldest
   * active run (runs.activeForSession): every later run of that session then
   * burns a full queue-wait plus a concurrency slot behind it. Queued rows
   * have no started_at (only claimNext sets it) and never ran the engine's
   * emit heartbeat, so age is COALESCE(last_active_at, created_at). Oldest
   * first, capped at 100 per call — the same one-sweeper-batch bound as
   * listStaleRunning. The sweeper terminalizes these with the SAME code the
   * processor's own wait cap uses (run_queue_wait_timeout), so the client
   * folds them identically.
   */
  async listStaleQueued(db: Db, staleBefore: Date): Promise<RunRow[]> {
    // ISO string for the same driver-mapping reason as listStaleRunning.
    const lastActive = sql`COALESCE(${runsTable.lastActiveAt}, ${runsTable.createdAt})`;
    return db
      .select()
      .from(runsTable)
      .where(and(eq(runsTable.status, "queued"), lt(lastActive, staleBefore.toISOString())))
      .orderBy(asc(lastActive))
      .limit(100);
  },

  /**
   * The run's status + cancel flag in ONE pk-indexed read — the C1 wait loop's
   * per-tick self check (runProcessor waitForSessionTurn): a waiter whose row
   * was terminalized out from under it (gateway queued-cancel, stale-run
   * sweeper) or whose cancel flag was set must exit its wait on the NEXT tick,
   * not after the full 10-minute cap. null = unknown id (defensive; the row
   * always exists while a worker waits on it — same stance as
   * isCancelRequested).
   */
  async statusAndCancel(
    db: Db,
    runId: string,
  ): Promise<{ status: string; cancelRequested: boolean } | null> {
    const rows = await db
      .select({ status: runsTable.status, cancelRequested: runsTable.cancelRequested })
      .from(runsTable)
      .where(eq(runsTable.id, runId))
      .limit(1);
    return rows[0] ?? null;
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

export type AttachmentFinalizeErrorCode =
  | "not_found"
  | "size_mismatch"
  | "type_mismatch"
  | "object_changed"
  | "reservation_required"
  | "attachment_failed";

export function attachmentDeclarationMismatch(
  current: Pick<AttachmentRow, "uploadStatus" | "actualBytes" | "actualContentType" | "size" | "contentTypeDeclared" | "contentType">,
  input: { actualBytes: number; actualContentType: string | null },
): Exclude<AttachmentFinalizeErrorCode, "not_found" | "reservation_required" | "attachment_failed"> | null {
  if (current.uploadStatus === "ready" && current.actualBytes !== null) {
    return current.actualBytes === input.actualBytes &&
      current.actualContentType === input.actualContentType
      ? null
      : "object_changed";
  }
  if (current.size !== input.actualBytes) return "size_mismatch";
  if (current.contentTypeDeclared && current.contentType !== input.actualContentType) {
    return "type_mismatch";
  }
  return null;
}

/** A typed finalization refusal; the transaction has already preserved a safe row state. */
export class AttachmentFinalizeError extends Error {
  constructor(readonly code: AttachmentFinalizeErrorCode, message: string) {
    super(message);
    this.name = "AttachmentFinalizeError";
  }
}

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
      /** Canonical declared type; omitted uses the database's unknown fallback. */
      contentType?: string;
      /** Explicit presence evidence; legacy repo callers default to contentType presence. */
      contentTypeDeclared?: boolean;
      /**
       * W1 follow-up (0022): optional explicit project attribution. The
       * SESSION is authoritative when it has one — new writes always stamp
       * the chat's current project; this is only a fallback for callers that
       * create a row without a readable session (and for tests).
       */
      projectId?: string | null;
    },
  ): Promise<AttachmentRow> {
    const { projectId: explicitProjectId, contentTypeDeclared, ...values } = a;
    return db.transaction(async (tx) => {
      const [session] = await tx
        .select({ projectId: sessionsTable.projectId })
        .from(sessionsTable)
        .where(eq(sessionsTable.id, a.sessionId))
        .limit(1);
      const projectId = session?.projectId ?? explicitProjectId ?? null;
      if (projectId !== null) {
        // Serialize the last-slot check with every other project-file write,
        // then re-count inside the lock. Refuse BEFORE the row exists (the
        // gateway presigns only after its own pre-flight check, so no bytes
        // have moved yet either).
        await lockProjectFiles(tx, a.userId, projectId);
        const usage = await projectFileUsage(tx, a.userId, projectId);
        if (usage.used >= usage.cap) throw new ProjectFileLimitError(usage);
      }
      const [row] = await tx
        .insert(attachmentsTable)
        .values({
          ...values,
          contentTypeDeclared: contentTypeDeclared ?? (a.contentType !== undefined),
          projectId,
        })
        .returning();
      return row!;
    });
  },

  /**
   * Finalize one uploaded object from actual storage HEAD metadata. The row is
   * locked so duplicate requests share one ready transition. Repeating the
   * same HEAD is a no-op; a changed object or declaration mismatch is recorded
   * as failed, never left with a stale ready claim. contentTypeDeclared keeps
   * omitted legacy input distinct from an explicitly supplied octet-stream:
   * unknown uploads record actual metadata without inventing a declaration;
   * every supplied type, including octet-stream, requires exact HEAD equality.
   */
  async finalizeUpload(
    db: Db,
    input: {
      id: string;
      sessionId: string;
      userId: string;
      actualBytes: number;
      actualContentType: string | null;
    },
  ): Promise<AttachmentRow> {
    const outcome = await db.transaction(async (tx): Promise<{
      row: AttachmentRow;
      error?: AttachmentFinalizeError;
    }> => {
      const [current] = await tx
        .select()
        .from(attachmentsTable)
        .where(and(
          eq(attachmentsTable.id, input.id),
          eq(attachmentsTable.sessionId, input.sessionId),
          eq(attachmentsTable.userId, input.userId),
        ))
        .for("update")
        .limit(1);
      if (current === undefined) {
        throw new AttachmentFinalizeError("not_found", "Attachment not found.");
      }
      if (current.uploadStatus === "failed") {
        // Failed is terminal. A finalized reservation from a separate settle
        // transaction can never resurrect it to ready from stale HEAD.
        throw new AttachmentFinalizeError(
          "attachment_failed",
          "The attachment upload is no longer active.",
        );
      }

      const code = attachmentDeclarationMismatch(current, input);

      if (code !== null) {
        const [failed] = await tx
          .update(attachmentsTable)
          .set({
            uploadStatus: "failed",
            actualBytes: input.actualBytes,
            actualContentType: input.actualContentType,
            finalizedAt: null,
          })
          .where(eq(attachmentsTable.id, current.id))
          .returning();
        const message = code === "object_changed"
          ? "The uploaded object changed after finalization."
          : code === "size_mismatch"
            ? "The uploaded object size does not match the attachment declaration."
            : "The uploaded object Content-Type does not match the attachment declaration.";
        return { row: failed!, error: new AttachmentFinalizeError(code, message) };
      }

      const [ready] = await tx
        .update(attachmentsTable)
        .set({
          uploadStatus: "ready",
          actualBytes: input.actualBytes,
          actualContentType: input.actualContentType,
          finalizedAt: new Date(),
      // A matching declaration is necessary but not sufficient: the shared
      // 0038 reservation must already carry the same actual HEAD bytes. This
      // fence applies to gateway, worker, and direct repository callers alike.
      const reservation = (await tx.execute(sql`
        SELECT state, actual_bytes FROM storage_reservations
         WHERE id = ${current.id} AND object_id = ${current.id}
           AND owner_user_id = ${input.userId}
         FOR UPDATE`)) as unknown as Array<{ state: string; actual_bytes: number | string | null }>;
      const reservationRow = reservation[0];
      if (reservationRow === undefined || reservationRow.state !== "finalized" ||
          Number(reservationRow.actual_bytes) !== input.actualBytes) {
        throw new AttachmentFinalizeError(
          "reservation_required",
          "The attachment storage reservation is not finalized for these actual bytes.",
        );
      }
      if (
        current.uploadStatus === "ready" &&
        current.actualBytes === input.actualBytes &&
        current.actualContentType === input.actualContentType
      ) {
        return { row: current };
      }

        })
        .where(eq(attachmentsTable.id, current.id))
        .returning();
      return { row: ready! };
    });
    if (outcome.error !== undefined) throw outcome.error;
    return outcome.row;
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

  /** Wave 1b (CH-006): records which user message carried these uploads. */
  async linkToMessage(
    db: Db,
    sessionId: string,
    ids: readonly string[],
    messageId: string,
  ): Promise<void> {
    if (ids.length === 0) return;
    await db
      .update(attachmentsTable)
      .set({ messageId })
      .where(and(eq(attachmentsTable.sessionId, sessionId), inArray(attachmentsTable.id, [...ids])));
  },

  /** Wave 1b (CH-006): the attachments sent with any of [messageIds], oldest-first. */
  async forMessages(
    db: Db,
    sessionId: string,
    messageIds: readonly string[],
  ): Promise<AttachmentRow[]> {
    if (messageIds.length === 0) return [];
    return db
      .select()
      .from(attachmentsTable)
      .where(
        and(
          eq(attachmentsTable.sessionId, sessionId),
          inArray(attachmentsTable.messageId, [...messageIds]),
        ),
      )
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

export function toSessionEvent(row: SessionEventMirrorRow): SessionEvent {
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

  /**
   * Events with seq STRICTLY before beforeSeq, in ASCENDING seq order so the
   * caller can prepend the page. A null (or malformed) bound means "the newest
   * page". Both modes take the page NEAREST the bound — ORDER BY seq DESC
   * LIMIT, then reverse — so successive `before=<first seq of the previous
   * page>` calls walk backwards contiguously (a plain ASC LIMIT would return
   * the oldest rows instead and skip the middle of the history).
   *
   * The comparison mirrors readSince's split_seq expression with the
   * comparison inverted (strictly less on ms, or equal ms and less on sub).
   */
  async readBefore(
    db: Db,
    sessionId: string,
    beforeSeq: string | null,
    limit: number,
  ): Promise<SessionEvent[]> {
    const key = beforeSeq === null ? null : splitSeq(beforeSeq);
    const where = key
      ? and(
          eq(sessionEventMirror.sessionId, sessionId),
          or(sql`${seqMs} < ${key.ms}`, and(sql`${seqMs} = ${key.ms}`, sql`${seqSub} < ${key.sub}`)),
        )
      : eq(sessionEventMirror.sessionId, sessionId);
    const rows = await db
      .select()
      .from(sessionEventMirror)
      .where(where)
      .orderBy(desc(seqMs), desc(seqSub))
      .limit(limit);
    return rows.reverse().map(toSessionEvent);
  },

  /** Wave 1b (CH-003): the session's newest mirrored seq, or null when none. */
  async maxSeq(db: Db, sessionId: string): Promise<string | null> {
    const rows = await db
      .select({ seq: sessionEventMirror.seq })
      .from(sessionEventMirror)
      .where(eq(sessionEventMirror.sessionId, sessionId))
      .orderBy(desc(seqMs), desc(seqSub))
      .limit(1);
    return rows[0]?.seq ?? null;
  },

  /**
   * Wave 1b (CH-006 rich history): the session's events whose ts falls in
   * [fromTs, toTs) (either bound optional) and whose seq is at most
   * [maxSeq], in seq order, EXCLUDING streaming deltas (`message_delta` —
   * settled text rides message_completed / message_segment). At most
   * [limit] rows: the NEWEST ones of the window when it overflows.
   */
  async readWindow(
    db: Db,
    sessionId: string,
    o: { fromTs: Date | null; toTs: Date | null; maxSeq: string | null; limit: number },
  ): Promise<SessionEvent[]> {
    const conds = [
      eq(sessionEventMirror.sessionId, sessionId),
      ne(sessionEventMirror.type, "message_delta"),
    ];
    if (o.fromTs !== null) conds.push(gte(sessionEventMirror.ts, o.fromTs));
    if (o.toTs !== null) conds.push(lt(sessionEventMirror.ts, o.toTs));
    const max = seqAtMost(o.maxSeq);
    if (max !== undefined) conds.push(max);
    const rows = await db
      .select()
      .from(sessionEventMirror)
      .where(and(...conds))
      .orderBy(desc(seqMs), desc(seqSub))
      .limit(o.limit);
    return rows.reverse().map(toSessionEvent);
  },

  /**
   * Wave 1b (CH-002): the `message_delta` rows of [runId] with seq strictly
   * after [afterSeq] (null ⇒ all) and at most [maxSeq], in seq order — the
   * live answer's text so far, for a chat reopened mid-run.
   */
  async deltasForRun(
    db: Db,
    sessionId: string,
    runId: string,
    o: { afterSeq: string | null; maxSeq: string | null; limit: number },
  ): Promise<SessionEvent[]> {
    const conds = [
      eq(sessionEventMirror.sessionId, sessionId),
      eq(sessionEventMirror.type, "message_delta"),
      sql`${sessionEventMirror.payload}->>'runId' = ${runId}`,
    ];
    const after = o.afterSeq === null ? null : splitSeq(o.afterSeq);
    if (after !== null) {
      conds.push(
        or(sql`${seqMs} > ${after.ms}`, and(sql`${seqMs} = ${after.ms}`, sql`${seqSub} > ${after.sub}`))!,
      );
    }
    const max = seqAtMost(o.maxSeq);
    if (max !== undefined) conds.push(max);
    const rows = await db
      .select()
      .from(sessionEventMirror)
      .where(and(...conds))
      .orderBy(asc(seqMs), asc(seqSub))
      .limit(o.limit);
    return rows.map(toSessionEvent);
  },
};

/** `seq <= maxSeq` (numeric on both parts); undefined for a null/malformed bound. */
function seqAtMost(maxSeq: string | null) {
  const max = maxSeq === null ? null : splitSeq(maxSeq);
  if (max === null) return undefined;
  return or(sql`${seqMs} < ${max.ms}`, and(sql`${seqMs} = ${max.ms}`, sql`${seqSub} <= ${max.sub}`));
}

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

/** Serialize custom connector creation for one user inside this transaction. */
export async function lockCustomConnectorCreates(db: Db, uid: string): Promise<void> {
  await db.execute(
    sql`select pg_advisory_xact_lock(hashtextextended(${`custom-connectors:${uid}`}, 0))`,
  );
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

  /**
   * Retention sweep: DELETE every flow whose expires_at predates the cutoff
   * (the worker's daily pass passes now() - 1 day, keeping a grace window
   * for late callbacks). consume() only marks rows `used` — nothing else ever
   * deletes them, so this pass is what keeps abandoned flows from
   * accumulating. Served by mcp_oauth_flows_expires_at_idx. Returns the
   * number of rows deleted.
   */
  async deleteExpired(db: Db, cutoff: Date): Promise<number> {
    const rows = await db
      .delete(mcpOauthFlowsTable)
      .where(lt(mcpOauthFlowsTable.expiresAt, cutoff))
      .returning({ state: mcpOauthFlowsTable.state });
    return rows.length;
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

  /**
   * Cross-session liveness guard, the file_manifests half: true iff any
   * OTHER session of the same user holds a row in state 'warm'. A warm row
   * means some sibling session believes the per-user agent workspace
   * (`{workspacesRoot}/{uid}/workspace`, shared by EVERY session of the user
   * — see workspacePaths.ts) is its live data, so a hydrate/hibernate keyed
   * by one session must refuse to wipe/evict the dir. The same hazard
   * warmLru.reclaimColdResidue already guards for its own rm ("another
   * session of the same user may still be warm and using that dir … removing
   * it would destroy a live workspace"); the primary engines read this for
   * the same rule. Rides the file_manifests_user_id_idx; LIMIT 1 — existence
   * only, never the rows.
   */
  async hasOtherWarmSession(
    db: Db,
    userId: string,
    exceptSessionId: string,
  ): Promise<boolean> {
    const rows = await db
      .select({ sessionId: fileManifestsTable.sessionId })
      .from(fileManifestsTable)
      .where(
        and(
          eq(fileManifestsTable.userId, userId),
          ne(fileManifestsTable.sessionId, exceptSessionId),
          eq(fileManifestsTable.state, "warm"),
        ),
      )
      .limit(1);
    return rows.length > 0;
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
    return db.transaction(async (tx) => {
      // W1 follow-up (0022): stamp the owning session's project at creation
      // and enforce that project's cap under the shared project-file lock.
      // The caller's pre-flight check runs BEFORE storage.put; this second
      // check is the atomic backstop that guarantees no over-cap ROW is
      // written by a concurrent registration.
      const [session] = await tx
        .select({ projectId: sessionsTable.projectId })
        .from(sessionsTable)
        .where(eq(sessionsTable.id, i.sessionId))
        .limit(1);
      const projectId = session?.projectId ?? null;
      if (projectId !== null) {
        await lockProjectFiles(tx, i.userId, projectId);
        const usage = await projectFileUsage(tx, i.userId, projectId);
        if (usage.used >= usage.cap) throw new ProjectFileLimitError(usage);
      }
      const [row] = await tx
        .insert(workspaceObjectsTable)
        .values({
          id: i.id,
          userId: i.userId,
          sessionId: i.sessionId,
          projectId,
          kind: "artifact",
          r2Key: i.r2Key,
          bytes: i.bytes,
          sha256: i.sha256,
          contentType: i.contentType,
          meta: i.meta,
        })
        .returning();
      return row!;
    });
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
    isNull(sessionsTable.deletedAt),
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

