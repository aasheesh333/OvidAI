import {
  bigint,
  boolean,
  char,
  check,
  customType,
  doublePrecision,
  index,
  integer,
  jsonb,
  pgTable,
  primaryKey,
  text,
  timestamp,
  uniqueIndex,
} from "drizzle-orm/pg-core";
import { sql } from "drizzle-orm";
import type {
  ScheduleAutonomy,
  ScheduleLastResult,
  ScheduleRunStatus,
  ScheduleStatus,
  ScheduleTrigger,
  UiManifest,
  WorkspaceState,
} from "@ovid/shared";

// All timestamptz columns use precision 3 (milliseconds): JS Dates are ms-precision,
// so stored values round-trip losslessly — which the keyset cursor in sessions.list
// relies on (no sub-ms truncation drift between DB value and cursor).
const timestamptz = (name: string) =>
  timestamp(name, { withTimezone: true, precision: 3 });

// Postgres tsvector has no built-in drizzle column type — a minimal custom
// type (P3 Task 13). The column is GENERATED (never inserted or updated by
// drizzle; only referenced inside SQL expressions), so the JS-side mapping
// is an opaque string.
const tsvector = customType<{ data: string; driverData: string }>({
  dataType() {
    return "tsvector";
  },
});

export const users = pgTable("users", {
  uid: text("uid").primaryKey(),
  email: text("email"),
  tier: text("tier").notNull().default("free"),
  // P9 Task 10 tierSink: paid-tier expiry (users.tier is set there too); the
  // Redis tier key self-expires at expiry+600, this column is the durable copy.
  tierExpiresAt: timestamptz("tier_expires_at"),
  // Per-user sandbox uid from the users_sandbox_uid_seq pool (production block
  // 200000–209999, spec §11). Unique across users; NULL until first allocated.
  sandboxUid: integer("sandbox_uid").unique(),
  bannedAt: timestamptz("banned_at"),
  // P9 Task 7/8: who banned — "admin" | "auto" (recordStrike's auto-ban bug
  // fix distinguishes the path that must also block the LiteLLM keys).
  bannedReason: text("banned_reason"),
  // P9 Task 8 fix I4: mint-owned users. The gateway's `users.ensure` creates
  // a row for EVERY chat user; only rows mint has provisioned (a key was
  // issued, an admin granted entitlements, or the account was imported from
  // ovid:uids) are iterated by reapply-all/reset-all/export/resync. Chat-only
  // rows stay false.
  mintProvisioned: boolean("mint_provisioned").notNull().default(false),
  // Wave 1a (SE-005 / R1): per-user preferences the worker enforces
  // ({memoryEnabled?, shareSessionMemory?}; absent keys = shared defaults).
  preferences: jsonb("preferences").$type<Record<string, unknown>>().notNull().default({}),
  createdAt: timestamptz("created_at").notNull().defaultNow(),
});

// W1 Projects: a user-owned folder of chats with its own private memory.
// Per-project file caps are plan-derived (owner spec §3 Screen 4); the rows
// here carry only identity/name. Name uniqueness is per owner.
export const projects = pgTable(
  "projects",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7
    userId: text("user_id")
      .notNull()
      .references(() => users.uid, { onDelete: "cascade" }),
    name: text("name").notNull(),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex("projects_user_id_name_idx").on(t.userId, t.name),
    index("projects_user_id_idx").on(t.userId),
  ],
);

export const sessions = pgTable(
  "sessions",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7
    userId: text("user_id")
      .notNull()
      .references(() => users.uid),
    title: text("title"),
    mode: text("mode").notNull().default("auto"),
    // W1: the project a chat belongs to. Deleting the project detaches its
    // chats (SET NULL) rather than deleting their history.
    projectId: char("project_id", { length: 36 }).references(() => projects.id, {
      onDelete: "set null",
    }),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
    archivedAt: timestamptz("archived_at"),
    /**
     * Pinned chats sort above the rest in the sidebar and survive the
     * "recent" cut. NULL = not pinned; a timestamp (not a boolean) so the
     * order among pinned chats is stable and meaningful.
     */
    pinnedAt: timestamptz("pinned_at"),
    // Soft delete (DELETE /sessions/:id): the row stays for audit/history but
    // every read path filters `deleted_at IS NULL` — repos.sessions and the
    // ownership joins in runs/searchMessages.
    deletedAt: timestamptz("deleted_at"),
  },
  (t) => [
    index("sessions_user_id_idx").on(t.userId),
    index("sessions_project_id_idx").on(t.projectId),
    // Pinned-first listing reads this per user; a partial index keeps it small.
    index("sessions_pinned_idx").on(t.userId, t.pinnedAt),
  ],
);

// R1 private agent memory: deliberately NOT in the shared sandbox/Studio tree.
// Account removal cascades; session-scoped rows cascade on hard chat deletion.
// Soft-deleted chats cannot read/write memory (repository ownership checks).
// W1: project memory reuses this store under the scope form `project:<uuid>`
// (session_id NULL, project_id set) — no second table, same size/name guards.
export const privateMemoryFiles = pgTable("private_memory_files", {
  userId: text("user_id").notNull().references(() => users.uid, { onDelete: "cascade" }),
  scope: text("scope").notNull(), // "shared", an owned session UUID, or "project:<uuid>"
  sessionId: char("session_id", { length: 36 }).references(() => sessions.id, { onDelete: "cascade" }),
  projectId: char("project_id", { length: 36 }).references(() => projects.id, { onDelete: "cascade" }),
  name: text("name").notNull(),
  content: text("content").notNull(),
  revision: char("revision", { length: 64 }).notNull(),
  updatedAt: timestamptz("updated_at").notNull().defaultNow(),
}, (t) => [
  primaryKey({ columns: [t.userId, t.scope, t.name] }),
  index("private_memory_session_id_idx").on(t.sessionId),
  index("private_memory_project_id_idx").on(t.projectId),
  check("private_memory_scope_check", sql`(${t.scope} = 'shared' AND ${t.sessionId} IS NULL AND ${t.projectId} IS NULL) OR (${t.sessionId} IS NOT NULL AND ${t.projectId} IS NULL AND ${t.scope} = ${t.sessionId}) OR (${t.projectId} IS NOT NULL AND ${t.sessionId} IS NULL AND ${t.scope} = 'project:' || ${t.projectId}::text)`),
  check("private_memory_content_size_check", sql`octet_length(${t.content}) <= 32768`),
  check("private_memory_name_check", sql`length(${t.name}) <= 80 AND ${t.name} ~ '^[A-Za-z0-9][A-Za-z0-9_-]*(\\.[A-Za-z0-9_-]+)*\\.md$' AND (lower(${t.name}) <> 'memory.md' OR ${t.name} = 'MEMORY.md')`),
]);

export const messages = pgTable(
  "messages",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7 (keyset cursor)
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id),
    role: text("role").notNull(), // "user" | "assistant" | "system" | "tool"
    content: text("content").notNull(),
    // The provider's reasoning ("thinking") for an assistant turn, when the
    // model exposed it and the run captured it. NULL on every user/system/tool
    // row and on assistant rows produced by a model that returns none. Kept
    // out of `content` so the answer the user reads never contains it and
    // search/compaction still see only the answer.
    reasoning: text("reasoning"),
    // P8 Task 4: caller-chosen idempotency key for the send-message and
    // history-import paths. NULL for all pre-P8 rows — the unique index below
    // is partial (WHERE client_msg_id IS NOT NULL), so keyed and keyless
    // messages never collide.
    clientMsgId: text("client_msg_id"),
    // P3 Task 13: FTS source for searchMessages (repos.ts). A STORED generated
    // tsvector over the message body — never written directly; queries use
    // `search_vector @@ tsquery` with the messages_search_gin GIN index. The
    // 'simple' dictionary mirrors Dart's unicode61 literal-terms semantics:
    // no stemming, punctuation dropped, case folded.
    searchVector: tsvector("search_vector").generatedAlwaysAs(
      sql`to_tsvector('simple', content)`,
    ),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [
    index("messages_session_id_id_idx").on(t.sessionId, t.id),
    // Full-text search index for searchMessages.
    index("messages_search_gin").using("gin", t.searchVector),
    // Per-session idempotency: one row per (session, clientMsgId); keyless
    // rows are exempt via the partial predicate.
    uniqueIndex("messages_session_client_msg_id_idx")
      .on(t.sessionId, t.clientMsgId)
      .where(sql`client_msg_id IS NOT NULL`),
  ],
);

export const runs = pgTable(
  "runs",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id),
    status: text("status").notNull(), // "queued" | "running" | "completed" | "failed" | "cancelled"
    promptMessageId: char("prompt_message_id", { length: 36 }),
    attempts: integer("attempts").notNull().default(0),
    lastError: text("last_error"),
    // P8 Task 1: cooperative cancel flag — set by the gateway's cancel
    // endpoint, polled (throttled) by the worker between streamed delta
    // batches, which terminalizes the run as 'cancelled'.
    cancelRequested: boolean("cancel_requested").notNull().default(false),
    // Stale-sweep fix: the engine's heartbeat — stamped at most once per
    // RUN_HEARTBEAT_INTERVAL_MS by the loop's emit wrapper, so a long run
    // still making progress never looks stranded. NULL = pre-heartbeat rows
    // (and rows that never emitted); the sweeper falls back to startedAt.
    lastActiveAt: timestamptz("last_active_at"),
    startedAt: timestamptz("started_at"),
    finishedAt: timestamptz("finished_at"),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [index("runs_session_id_idx").on(t.sessionId)],
);

// Durable mirror of the Redis Streams session event ledger (disaster recovery /
// replay beyond the stream's trim window). seq is a Redis stream id "ms-sub";
// ordering comparisons must split on '-' and compare numerically (see repos.ts).
export const sessionEventMirror = pgTable(
  "session_event_mirror",
  {
    sessionId: text("session_id").notNull(),
    seq: text("seq").notNull(),
    type: text("type").notNull(),
    payload: jsonb("payload").notNull().$type<Record<string, unknown>>(),
    ts: timestamptz("ts").notNull(),
  },
  (t) => [primaryKey({ columns: [t.sessionId, t.seq] })],
);

// P8 Task 3: an attachment created by POST /sessions/:id/attachments. The row
// is written at creation time (BEFORE the client uploads the bytes to the
// presigned R2 URL) — it records the intent; object presence is the client's
// side of the contract (the worker fails the run with attachment_unavailable
// when the object never landed). r2Key is
// users/{userId}/sessions/{sessionId}/uploads/{id}; `name` is the raw display
// name (sanitization happens at the workspace-path boundary, never here).
export const attachments = pgTable(
  "attachments",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id),
    userId: text("user_id")
      .notNull()
      .references(() => users.uid),
    // W1 follow-up (0022): the project this upload counts against. Stamped at
    // creation from the owning session's project_id; nullable because rows
    // predate projects and because a standalone chat has none. ON DELETE SET
    // NULL keeps the file row (and its object) when the folder is deleted.
    projectId: char("project_id", { length: 36 }).references(() => projects.id, {
      onDelete: "set null",
    }),
    name: text("name").notNull(),
    size: integer("size").notNull(),
    r2Key: text("r2_key").notNull(),
    // Wave 1b (CH-006): the user message this upload was sent with — set by
    // the send route once the prompt row exists, so history pages can render
    // the attachment chips under the right bubble. NULL = staged but never
    // sent (or sent before the column existed). No FK: a truncated message
    // simply leaves the link dangling, and the reader joins by id.
    messageId: char("message_id", { length: 36 }),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [
    index("attachments_session_id_idx").on(t.sessionId),
    index("attachments_message_id_idx").on(t.messageId),
    index("attachments_project_id_idx").on(t.projectId),
  ],
);

export type UserRow = typeof users.$inferSelect;
export type ProjectRow = typeof projects.$inferSelect;
export type SessionRow = typeof sessions.$inferSelect;
export type MessageRow = typeof messages.$inferSelect;
export type RunRow = typeof runs.$inferSelect;
export type SessionEventMirrorRow = typeof sessionEventMirror.$inferSelect;
export type AttachmentRow = typeof attachments.$inferSelect;

// ---------------------------------------------------------------------------
// P9 Task 2: money & accounts tables (spec §10).
//
// Conventions carried from the plan:
// - money columns are `text` holding exact decimal strings (decimal.js renders
//   and parses them; SQL numeric arithmetic never touches money);
// - epoch-SECOND columns are `bigint` (mode: number — safe: seconds since
//   epoch is far inside the double/Number safe-integer range);
// - timestamps whose producers/consumers are JS-side use timestamptz(3);
// - jsonb payloads that mirror the Python/Redis wire shapes (deletion records,
//   pools overrides, snapshot content) keep their snake_case field names —
//   a documented exception to the camelCase wire rule (legacy ports).
// ---------------------------------------------------------------------------

// One row per sellable plan (plans-as-data; the mint app is the only writer,
// the Redis db2 projection is derived from these rows). `priceUsd`/`mult` are
// exact decimal strings ("18", "5"); aliases include the tier strings the hook
// and users.tier already hold (go → ["starter", "3x"], pro → ["max", "15x"]).
export const plans = pgTable("plans", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  priceUsd: text("price_usd").notNull(),
  enabled: boolean("enabled").notNull(),
  aliases: jsonb("aliases").notNull().$type<string[]>(),
  windowHours: integer("window_hours").notNull(),
  mult: text("mult").notNull(),
  slowMode: boolean("slow_mode").notNull(),
  autoOss: boolean("auto_oss").notNull(),
  position: integer("position").notNull(),
});

// Singleton row (id = 1) — the durable authority for global mint settings
// (Ruling Q4: Postgres wins disagreements with the db2 projection).
// `scalars` holds the ovid_plans.py SCALARS set (free_monthly_cap_usd,
// est_input/output/image_tokens, slow_/normal_ rpm/tpm/parallel,
// hard_ceiling_mult) as native JSON numbers.
export const mintSettings = pgTable("mint_settings", {
  id: integer("id").primaryKey().default(1),
  baseDailyUsd: text("base_daily_usd").notNull(),
  scalars: jsonb("scalars").notNull().$type<Record<string, number>>(),
  autoOssMembers: jsonb("auto_oss_members").notNull().$type<{ model: string; weight: number }[]>(),
  updatedAt: timestamptz("updated_at").notNull().defaultNow(),
});

// Per-user override of plan-derived allowance. `pools` is stored in the Redis
// user:{uid}:pools shape (snake_case) so the projection can republish it
// verbatim.
export const userPlanOverrides = pgTable("user_plan_overrides", {
  uid: text("uid")
    .primaryKey()
    .references(() => users.uid),
  dailyUsd: text("daily_usd"),
  monthlyCapUsd: text("monthly_cap_usd"),
  pools: jsonb("pools").$type<{
    mult?: number | null;
    window_hours?: number | null;
    slow_mode?: boolean | null;
    auto_oss?: boolean | null;
  } | null>(),
  updatedAt: timestamptz("updated_at").notNull().defaultNow(),
});

// Admin-console audit trail (Task 8 writes via its audit() helper; also
// mirrored to the Redis audit:admin list and a JSONL file).
export const mintAudit = pgTable("mint_audit", {
  id: char("id", { length: 36 }).primaryKey(), // UUIDv7
  at: timestamptz("at").notNull().defaultNow(),
  actor: text("actor").notNull(),
  action: text("action").notNull(),
  target: jsonb("target"),
  before: jsonb("before"),
  after: jsonb("after"),
  ip: text("ip"),
});

// Durable Play-Billing ledger (port of server/billing/store.py play_purchases).
// One row per purchase token; a token binds to one Firebase uid on first
// verify. expiresAt/updatedAt are epoch seconds.
export const billingPurchases = pgTable(
  "billing_purchases",
  {
    token: text("token").primaryKey(),
    uid: text("uid"),
    productId: text("product_id").notNull(),
    tier: text("tier").notNull(),
    status: text("status").notNull(), // active|pending|expired|revoked|replaced
    expiresAt: bigint("expires_at", { mode: "number" }),
    autoRenewing: boolean("auto_renewing").notNull().default(false),
    linkedToken: text("linked_token"),
    accountHash: text("account_hash"),
    updatedAt: bigint("updated_at", { mode: "number" }).notNull(),
  },
  (t) => [index("billing_purchases_uid_idx").on(t.uid)],
);

// Images ledger rows (port of server/images image_jobs; the Task-12 ImageLedger
// wraps these — the raw-row repo surface exists only for the Task-18 import).
// reserved/charged/actual are exact decimal strings; createdAt/replayUntil/
// receiptUntil are epoch seconds. Partial indexes serve the retention sweeps.
export const imageJobs = pgTable(
  "image_jobs",
  {
    account: text("account").notNull(),
    request: text("request").notNull(),
    fingerprint: text("fingerprint").notNull(),
    state: text("state").notNull(), // pending|unknown|done|failed
    reserved: text("reserved").notNull(),
    charged: text("charged").notNull().default("0"),
    actual: text("actual"),
    response: jsonb("response").$type<Record<string, unknown> | null>(),
    servedModel: text("served_model"),
    budgetWindow: text("budget_window").notNull(),
    replayUntil: bigint("replay_until", { mode: "number" }),
    receiptUntil: bigint("receipt_until", { mode: "number" }),
    createdAt: bigint("created_at", { mode: "number" }).notNull(),
  },
  (t) => [
    primaryKey({ columns: [t.account, t.request] }),
    index("image_jobs_replay_until_idx").on(t.replayUntil).where(sql`replay_until IS NOT NULL`),
    index("image_jobs_receipt_until_idx")
      .on(t.receiptUntil)
      .where(sql`receipt_until IS NOT NULL`),
  ],
);

// Tombstone: the account's ledger rows stay (charges are money history) but
// every read path answers image_account_deleted once this row exists.
export const imageDeletedAccounts = pgTable("image_deleted_accounts", {
  account: text("account").primaryKey(),
  deletedAt: bigint("deleted_at", { mode: "number" }).notNull(),
});

// Image capability card (Task 14 cardStore); `card` is the full Card JSON.
export const imageCards = pgTable("image_cards", {
  model: text("model").primaryKey(),
  fingerprint: text("fingerprint").notNull(),
  state: text("state").notNull(),
  card: jsonb("card").notNull().$type<Record<string, unknown>>(),
  priced: boolean("priced"),
  editTransport: text("edit_transport"),
  updatedAt: bigint("updated_at", { mode: "number" }).notNull(),
  probedAt: bigint("probed_at", { mode: "number" }),
});

export const imageCardHistory = pgTable(
  "image_card_history",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7
    model: text("model").notNull(),
    fingerprint: text("fingerprint").notNull(),
    state: text("state").notNull(),
    card: jsonb("card").notNull().$type<Record<string, unknown>>(),
    at: bigint("at", { mode: "number" }).notNull(),
  },
  (t) => [index("image_card_history_model_at_idx").on(t.model, t.at)],
);

export const imageProbeLog = pgTable(
  "image_probe_log",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7
    model: text("model").notNull(),
    probe: text("probe").notNull(),
    ok: boolean("ok").notNull(),
    errorClass: text("error_class"),
    latencyMs: integer("latency_ms"),
    costUsd: text("cost_usd").notNull(),
    at: bigint("at", { mode: "number" }).notNull(),
  },
  (t) => [index("image_probe_log_at_idx").on(t.at)],
);

export const imageProbeState = pgTable("image_probe_state", {
  model: text("model").primaryKey(),
  attempts: integer("attempts").notNull().default(0),
  nextAttemptAt: bigint("next_attempt_at", { mode: "number" }).notNull(),
  lastError: text("last_error"),
});

// Conversation snapshots with idempotent receipts (port of server/shares).
// token = 43-char base64url of 32 random bytes. Receipt rows are kept forever
// (dedup history): revoked/purged rows keep the token but null content.
export const shares = pgTable(
  "shares",
  {
    token: char("token", { length: 43 }).primaryKey(),
    ownerUid: text("owner_uid").notNull(),
    sessionId: text("session_id").notNull(),
    requestId: text("request_id").notNull(),
    content: jsonb("content").$type<{ messages: { role: string; content: string }[] } | null>(),
    messageCount: integer("message_count").notNull().default(0),
    createdAt: timestamptz("created_at").notNull(),
    expiresAt: timestamptz("expires_at").notNull(),
    revokedAt: timestamptz("revoked_at"),
    purgedAt: timestamptz("purged_at"),
    forkOfToken: char("fork_of_token", { length: 43 }),
  },
  (t) => [
    uniqueIndex("shares_owner_request_idx").on(t.ownerUid, t.requestId),
    index("shares_owner_idx").on(t.ownerUid),
    // Retention sweep scan (purgeExpired) — only rows still holding content.
    index("shares_expiry_idx").on(t.expiresAt).where(sql`content IS NOT NULL`),
  ],
);

export const shareForks = pgTable(
  "share_forks",
  {
    token: char("token", { length: 43 }).notNull(),
    recipientUid: text("recipient_uid").notNull(),
    requestId: text("request_id").notNull(),
    sessionId: text("session_id").notNull(),
    createdAt: timestamptz("created_at").notNull(),
  },
  (t) => [primaryKey({ columns: [t.token, t.recipientUid, t.requestId] })],
);

// Moderation queue (port of server/reports). Unique (reporter, requestId)
// makes duplicate submissions return the original id.
export const reports = pgTable(
  "reports",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7
    reporterUid: text("reporter_uid").notNull(),
    requestId: text("request_id").notNull(),
    kind: text("kind").notNull(),
    reason: text("reason").notNull(),
    details: text("details").notNull(),
    excerpt: text("excerpt").notNull(),
    targetId: text("target_id"),
    model: text("model"),
    status: text("status").notNull().default("open"),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex("reports_reporter_request_idx").on(t.reporterUid, t.requestId),
    index("reports_status_created_idx").on(t.status, t.createdAt),
  ],
);

// Account-deletion lifecycle records (port of server/account). Retry fields
// (next_attempt, attempts, fence_owned, …) live inside `record` jsonb in the
// Python shape; deleteAfter is epoch seconds.
//
// Python parity: server/account/schema.sql declares
// `delete_after double precision` and the lifecycle clock is `time.time()`
// (fractional). A bigint column rejects those values with SQLSTATE 22P02, so
// this MUST stay double precision (P9 final review C1).
export const accountDeletions = pgTable("account_deletions", {
  uid: text("uid").primaryKey(),
  state: text("state").notNull(),
  deleteAfter: doublePrecision("delete_after").notNull(),
  record: jsonb("record").notNull().$type<Record<string, unknown>>(),
  updatedAt: timestamptz("updated_at").notNull().defaultNow(),
});

// BYOK escrow rows (Task 11): the API key is AES-256-GCM envelope-encrypted;
// ciphertext/iv/tag/wrappedDek never leave the DB unprojected.
export const byokKeys = pgTable(
  "byok_keys",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7
    userId: text("user_id")
      .notNull()
      .references(() => users.uid),
    providerId: text("provider_id").notNull(),
    endpoint: text("endpoint").notNull(),
    label: text("label"),
    wrappedDek: text("wrapped_dek").notNull(),
    iv: text("iv").notNull(),
    ciphertext: text("ciphertext").notNull(),
    tag: text("tag").notNull(),
    status: text("status").notNull().default("active"),
    lastTestAt: timestamptz("last_test_at"),
    lastTestOk: boolean("last_test_ok"),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [index("byok_keys_user_id_idx").on(t.userId)],
);

// ---------------------------------------------------------------------------
// Wave 6 W4: browser Credentials Vault.
//
// Owner-scoped login entries for the cloud browser. The password/token and
// the optional notes are AES-256-GCM envelopes (same four-field shape as
// BYOK/MCP secrets; recordId `browser_credentials:{id}`). `site` binds the
// credential to a host: the worker refuses to inject it anywhere else.
// Nothing secret is ever projected by the list route.
// ---------------------------------------------------------------------------

export const browserCredentials = pgTable(
  "browser_credentials",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7
    userId: text("user_id")
      .notNull()
      .references(() => users.uid, { onDelete: "cascade" }),
    label: text("label").notNull(),
    /** URL or bare host the credential is valid for. */
    site: text("site").notNull(),
    username: text("username").notNull().default(""),
    /** "password" | "token" */
    secretKind: text("secret_kind").notNull().default("password"),
    secretSealed: jsonb("secret_sealed").$type<SealedEnvelope>().notNull(),
    notesSealed: jsonb("notes_sealed").$type<SealedEnvelope | null>(),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex("browser_credentials_user_label_idx").on(t.userId, t.label),
    index("browser_credentials_user_id_idx").on(t.userId),
    check("browser_credentials_label_len_check", sql`length(${t.label}) BETWEEN 1 AND 120`),
    check("browser_credentials_site_len_check", sql`length(${t.site}) BETWEEN 1 AND 2048`),
    check("browser_credentials_kind_check", sql`${t.secretKind} IN ('password','token')`),
  ],
);

// ---------------------------------------------------------------------------
// P5 Task 8: MCP servers, OAuth (tokens + PKCE flows), plugins, grants.
//
// Sealed columns hold a structured envelope produced by @ovid/mcp's
// EnvelopeCrypto shim (P9-aligned; @ovid/escrow will consolidate). The
// dependency direction is @ovid/mcp → @ovid/db, so the envelope is typed
// STRUCTURALLY here — SealedEnvelope is field-for-field EncryptedEnvelope.
// recordId conventions (pinned, see the P5 plan):
//   mcp_servers:{row.id} · mcp_oauth_tokens:{server_id} ·
//   mcp_oauth_flows:{state} · plugins:{row.id}
// ---------------------------------------------------------------------------

/** Structural EncryptedEnvelope (@ovid/mcp crypto.ts) — all fields base64. */
export type SealedEnvelope = {
  wrappedDek: string;
  iv: string;
  ciphertext: string;
  tag: string;
};

// A user-registered MCP server (custom, pasted-.mcp.json, or a curated entry
// with user credentials). `config` is NON-secret ({url?, command?, args?,
// cwd?, type?}); everything secret (env, headers, oauth credentials) lives in
// `secrets_sealed` and is only ever decrypted by the runtime, never projected.
export const mcpServers = pgTable(
  "mcp_servers",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7
    userId: text("user_id")
      .notNull()
      .references(() => users.uid),
    name: text("name").notNull(),
    transport: text("transport").notNull(), // "http" | "sse" | "stdio" | "native"
    curatedId: text("curated_id"),
    config: jsonb("config").$type<Record<string, unknown> | null>(),
    secretsSealed: jsonb("secrets_sealed").$type<SealedEnvelope | null>(),
    enabled: boolean("enabled").notNull().default(true),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex("mcp_servers_user_name_idx").on(t.userId, t.name),
    index("mcp_servers_user_id_idx").on(t.userId),
  ],
);

// OAuth tokens for an MCP server (one live set per server — a refresh
// replaces the row via UNIQUE(server_id)). `tokensSealed` is the envelope of
// {accessToken, refreshToken?, expiresAt?, registration?}; recordId is
// mcp_oauth_tokens:{server_id}.
export const mcpOauthTokens = pgTable(
  "mcp_oauth_tokens",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7
    userId: text("user_id").notNull(),
    serverId: char("server_id", { length: 36 })
      .notNull()
      .references(() => mcpServers.id, { onDelete: "cascade" }),
    tokensSealed: jsonb("tokens_sealed").notNull().$type<SealedEnvelope>(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [uniqueIndex("mcp_oauth_tokens_server_id_idx").on(t.serverId)],
);

// In-flight OAuth authorization-code + PKCE flows. `state` is the CSRF/PKCE
// state param; the PKCE verifier is sealed (recordId mcp_oauth_flows:{state}).
// Rows are consumed atomically (repos.mcpOauthFlows.consume) or age out via
// expires_at.
export const mcpOauthFlows = pgTable(
  "mcp_oauth_flows",
  {
    state: text("state").primaryKey(),
    userId: text("user_id").notNull(),
    serverId: char("server_id", { length: 36 }).notNull(),
    verifierSealed: jsonb("verifier_sealed").$type<SealedEnvelope | null>(),
    config: jsonb("config").$type<Record<string, unknown> | null>(),
    expiresAt: timestamptz("expires_at").notNull(),
    used: boolean("used").notNull().default(false),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [index("mcp_oauth_flows_expires_at_idx").on(t.expiresAt)],
);

// An installed plugin for a user. `pluginId` is the canonical
// "publisher/name"; status is the install state machine
// (installing|pending_grant|active|degraded|failed|uninstalling). User-supplied
// plugin config values are sealed in `configSealed` (recordId plugins:{id});
// `probeFailures` is the degraded-health log the prober appends to.
export const plugins = pgTable(
  "plugins",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7
    userId: text("user_id").notNull(),
    pluginId: text("plugin_id").notNull(), // "publisher/name"
    version: text("version").notNull(),
    source: jsonb("source").notNull().$type<Record<string, unknown>>(),
    status: text("status").notNull(),
    contentDir: text("content_dir"),
    manifest: jsonb("manifest").$type<Record<string, unknown> | null>(),
    probeFailures: jsonb("probe_failures").$type<Record<string, unknown>[] | null>(),
    configSealed: jsonb("config_sealed").$type<SealedEnvelope | null>(),
    installedAt: timestamptz("installed_at").notNull().defaultNow(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex("plugins_user_plugin_id_idx").on(t.userId, t.pluginId),
    index("plugins_user_id_idx").on(t.userId),
  ],
);

// The user's recorded consent for a plugin install: capability list, env var
// names, manifest digest (re-verified on every activation), and the
// dependency-scripts switch. One row per (user, plugin).
export const pluginGrants = pgTable(
  "plugin_grants",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7
    userId: text("user_id").notNull(),
    pluginId: text("plugin_id").notNull(),
    capabilities: jsonb("capabilities").notNull().$type<string[]>(),
    envNames: jsonb("env_names").notNull().$type<string[]>(),
    manifestDigest: text("manifest_digest").notNull(),
    allowDependencyScripts: boolean("allow_dependency_scripts").notNull().default(false),
    grantedAt: timestamptz("granted_at").notNull().defaultNow(),
  },
  (t) => [uniqueIndex("plugin_grants_user_plugin_id_idx").on(t.userId, t.pluginId)],
);

// ---------------------------------------------------------------------------
// P7 Task 6: workspace state-hydrator persistence.
//
// file_manifests is the per-session state machine row (warm → hibernating →
// cold → hydrating → warm) plus the manifest-first tree the gateway serves
// for cold/hydrating sessions (the <100 ms SLA path — zero worker calls).
// workspace_objects is the R2 object index (ledger) for archives, their
// manifest sidecars, and registered artifacts.
//
// sha256 columns hold lowercase hex, compared by exact string match ONLY —
// never re-hashed or arithmetic'd (Global Constraints exact-arithmetic rule);
// every bytes-typed value is a JS safe integer, asserted at the repo boundary.
// ---------------------------------------------------------------------------

// One row per session that has ever been warm (the P10 sweeper registers
// never-hibernated sessions via upsertWarm). generation increments per
// hibernate cycle; archive_* columns are null until the first hibernate.
// workspaceBytes is the last du of the warm dir (LRU accounting), cleared
// when cold. state follows WorkspaceState exactly.
export const fileManifests = pgTable(
  "file_manifests",
  {
    sessionId: char("session_id", { length: 36 })
      .primaryKey()
      .references(() => sessions.id),
    userId: text("user_id")
      .notNull()
      .references(() => users.uid),
    generation: integer("generation").notNull().default(0),
    state: text("state").notNull().$type<WorkspaceState>(),
    // Pruned UI tree the gateway serves while cold/hydrating; starts as the
    // EMPTY tree literal (repos.fileManifests.upsertWarm) and is replaced by
    // the packer's uiTree at every markCold.
    uiTree: jsonb("ui_tree").notNull().$type<UiManifest>(),
    archiveKey: text("archive_key"),
    archiveBytes: bigint("archive_bytes", { mode: "number" }),
    archiveSha256: text("archive_sha256"), // 64-char lowercase hex
    entryCount: integer("entry_count"),
    workspaceBytes: bigint("workspace_bytes", { mode: "number" }),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [
    index("file_manifests_user_id_idx").on(t.userId),
    index("file_manifests_state_idx").on(t.state),
  ],
);

// R2 object ledger. r2Key is globally unique (stable per session for the
// archive/sidecar pair — upserts bump generation in place); kind separates
// the three shapes. `sha256` is the digest OF THE STORED OBJECT at that key
// (the archive's digest on archive rows, the SIDECAR's digest on manifest
// rows — callers compute both before upload; R2's HEAD never returns one).
// generation is archives only. status is the soft-delete marker (artifacts).
export const workspaceObjects = pgTable(
  "workspace_objects",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7
    userId: text("user_id")
      .notNull()
      .references(() => users.uid),
    sessionId: char("session_id", { length: 36 }).references(() => sessions.id),
    // W1 follow-up (0022): project attribution for artifact rows (the file
    // cap counts kind='artifact' AND status='active' only). Stamped at
    // registration from the session; SET NULL on project deletion.
    projectId: char("project_id", { length: 36 }).references(() => projects.id, {
      onDelete: "set null",
    }),
    kind: text("kind").notNull(), // "workspace_archive" | "workspace_manifest" | "artifact"
    r2Key: text("r2_key").notNull().unique(),
    bytes: bigint("bytes", { mode: "number" }).notNull(),
    sha256: text("sha256").notNull(), // lowercase hex — exact string comparisons only
    contentType: text("content_type"),
    generation: integer("generation"), // archives only
    status: text("status").notNull().default("active"), // "active" | "deleted"
    meta: jsonb("meta").$type<Record<string, unknown>>(),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [
    index("workspace_objects_session_id_idx").on(t.sessionId),
    index("workspace_objects_user_id_kind_idx").on(t.userId, t.kind),
    index("workspace_objects_project_id_idx").on(t.projectId),
  ],
);

export type FileManifestRow = typeof fileManifests.$inferSelect;
export type WorkspaceObjectRow = typeof workspaceObjects.$inferSelect;

// ---------------------------------------------------------------------------
// P3 Task 12: hierarchical permission grants (port of grant_store.dart's
// persistence, session-scoped only).
//
// A "path" pattern covers the folder itself + every child (never siblings);
// a "host" pattern covers the host + child domains + every port/path. The
// Dart GLOBAL scope is NOT ported ("the agent never consults them" — the
// session's rows are the only authority). `mode` is audit metadata only:
// decisions apply across modes (a Control grant carries into General).
// ---------------------------------------------------------------------------

export const grants = pgTable(
  "grants",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7
    userId: text("user_id")
      .notNull()
      .references(() => users.uid),
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id),
    kind: text("kind").notNull(), // "path" | "host"
    pattern: text("pattern").notNull(), // normalized by kind (grants.ts)
    decision: text("decision").notNull(), // "allow" | "always" | "deny"
    mode: text("mode"), // audit metadata only — decisions apply across modes
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [index("grants_user_id_session_id_idx").on(t.userId, t.sessionId)],
);

export type GrantRow = typeof grants.$inferSelect;

// ---------------------------------------------------------------------------
// P3 Task 13: session agent state (todos / goal / preset / plan-mode /
// compaction / mode pinning / skill scopes).
//
// The row stores the WHOLE SessionAgentState JSON (agent-core ports.ts is the
// parity reference). @ovid/db cannot import @ovid/agent-core (dependency
// direction: agent-core → db), so the typed shape lives with the repo
// (sessionState in repos.ts) and this column stays structurally typed; the
// typed seam is createPostgresSessionStateStore in agent-core's stateStore.ts.
// One row per session, created by the first sessionState.patch; the FK to
// sessions keeps state from existing without its session.
// ---------------------------------------------------------------------------

export const sessionAgentState = pgTable("session_agent_state", {
  sessionId: char("session_id", { length: 36 })
    .primaryKey()
    .references(() => sessions.id),
  // '{}' until the first patch; reads fold it over the zero state (repos.ts).
  state: jsonb("state").notNull().default({}).$type<Record<string, unknown>>(),
});

export type SessionAgentStateRow = typeof sessionAgentState.$inferSelect;

// ---------------------------------------------------------------------------
// P4 Task 3: scheduler persistence (schedules / schedule_runs / devices /
// notifications).
//
// The claim ledger is schedule_runs' UNIQUE(schedule_id, scheduled_for): a
// worker claims an occurrence by INSERTing its row — exactly one concurrent
// claimer wins, the rest take the 23505 (spec §8 idempotency key). schedule_id
// cascades so deleting a schedule never leaves orphan occurrences behind;
// run_id deliberately does NOT cascade (runs are the transcript's own
// lifecycle — the scheduler only references them).
//
// Wire shapes ($type<>): trigger/last_result/status/autonomy come from
// @ovid/shared (P4 Task 1/2), so the JSONB and text columns are typed at the
// same seam the gateway and scheduler use.
// ---------------------------------------------------------------------------

export const schedules = pgTable(
  "schedules",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7
    userId: text("user_id")
      .notNull()
      .references(() => users.uid),
    // Bound or dedicated session — ALWAYS materialized at creation.
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id),
    title: text("title").notNull(),
    description: text("description").notNull(),
    trigger: jsonb("trigger").notNull().$type<ScheduleTrigger>(),
    autonomy: text("autonomy").notNull().default("safe").$type<ScheduleAutonomy>(),
    status: text("status").notNull().default("pending").$type<ScheduleStatus>(),
    pausedReason: text("paused_reason"),
    maxRetries: integer("max_retries").notNull().default(0),
    nextRunAt: timestamptz("next_run_at"),
    lastResult: jsonb("last_result").$type<ScheduleLastResult | null>(),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [
    index("schedules_user_id_idx").on(t.userId),
    // Due-scan for the scheduler tick.
    index("schedules_status_next_run_at_idx").on(t.status, t.nextRunAt),
  ],
);

export const scheduleRuns = pgTable(
  "schedule_runs",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7
    scheduleId: char("schedule_id", { length: 36 })
      .notNull()
      .references(() => schedules.id, { onDelete: "cascade" }),
    // The occurrence this row claims — half of the idempotency key.
    scheduledFor: timestamptz("scheduled_for").notNull(),
    // P4 final review M1: the routing context is PINNED at claim time. Settle
    // must report into the session (and apply the trigger semantics) the run
    // actually executed with, even if the schedule was rebound mid-run.
    // No FK: sessions have no DELETE route today (L3); a plain snapshot keeps
    // the occurrence readable even if one is added later.
    sessionId: char("session_id", { length: 36 }).notNull(),
    triggerKind: text("trigger_kind").notNull().$type<ScheduleTrigger["kind"]>(),
    runId: char("run_id", { length: 36 }).references(() => runs.id),
    status: text("status").notNull().$type<ScheduleRunStatus>(),
    attempt: integer("attempt").notNull().default(1),
    ranLate: boolean("ran_late").notNull().default(false),
    retryAt: timestamptz("retry_at"),
    error: text("error"),
    autoDenied: jsonb("auto_denied")
      .notNull()
      .default(sql`'[]'::jsonb`)
      .$type<Array<{ toolName: string; summary: string; ts: string }>>(),
    startedAt: timestamptz("started_at"),
    finishedAt: timestamptz("finished_at"),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [
    // THE claim ledger (spec §8): one row per (schedule, occurrence).
    uniqueIndex("schedule_runs_claim_uq").on(t.scheduleId, t.scheduledFor),
    index("schedule_runs_schedule_id_id_idx").on(t.scheduleId, t.id),
    index("schedule_runs_status_retry_at_idx").on(t.status, t.retryAt),
    index("schedule_runs_run_id_idx").on(t.runId),
  ],
);

export const devices = pgTable(
  "devices",
  {
    // FCM registration token — the natural primary key (re-registration is an
    // upsert, never a duplicate row).
    token: text("token").primaryKey(),
    userId: text("user_id")
      .notNull()
      .references(() => users.uid),
    platform: text("platform").notNull().default("android"),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [index("devices_user_id_idx").on(t.userId)],
);

export const notifications = pgTable(
  "notifications",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7
    userId: text("user_id")
      .notNull()
      .references(() => users.uid),
    // NULL = the no-device record (delivery was skipped; kept for the inbox).
    deviceToken: text("device_token"),
    kind: text("kind").notNull(),
    channel: text("channel").notNull(),
    title: text("title").notNull(),
    body: text("body").notNull(),
    route: text("route").notNull(),
    data: jsonb("data").notNull().$type<Record<string, string>>(),
    status: text("status").notNull().default("sent"), // sent|failed|skipped_no_devices|skipped_disabled (Wave 4: push off)
    error: text("error"),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [index("notifications_user_id_idx").on(t.userId)],
);

export const notificationDeliveryClaims = pgTable(
  "notification_delivery_claims",
  {
    userId: text("user_id")
      .notNull()
      .references(() => users.uid, { onDelete: "cascade" }),
    kind: text("kind").notNull(),
    runId: char("run_id", { length: 36 }).notNull(),
    state: text("state").notNull().default("pending"),
    claimant: text("claimant"),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [primaryKey({ columns: [t.userId, t.kind, t.runId] })],
);

export const pushSubscriptions = pgTable(
  "push_subscriptions",
  {
    endpoint: text("endpoint").primaryKey(),
    userId: text("user_id")
      .notNull()
      .references(() => users.uid, { onDelete: "cascade" }),
    p256dh: text("p256dh").notNull(),
    auth: text("auth").notNull(),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [index("push_subscriptions_user_id_idx").on(t.userId)],
);

export type ScheduleRow = typeof schedules.$inferSelect;
export type ScheduleRunRow = typeof scheduleRuns.$inferSelect;
export type DeviceRow = typeof devices.$inferSelect;
export type NotificationRow = typeof notifications.$inferSelect;
export type PushSubscriptionRow = typeof pushSubscriptions.$inferSelect;

// Wave 3: per-model-call token ledger. The worker records one row per
// LiteLLM call (AgentResponse.usage) best-effort; the gateway aggregates it
// for GET /cloud/v1/usage/history. Deliberately NO foreign keys: recording
// must never fail a run over a racing session delete, and account deletion
// purges rows by user_id (packages/account adapters "sql" stage). `model` is
// the model id the worker REQUESTED from LiteLLM (e.g. "auto"), not the
// served member.
export const runUsage = pgTable(
  "run_usage",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7
    userId: text("user_id").notNull(),
    sessionId: char("session_id", { length: 36 }).notNull(),
    runId: char("run_id", { length: 36 }).notNull(),
    model: text("model").notNull(),
    inputTokens: integer("input_tokens").notNull().default(0),
    outputTokens: integer("output_tokens").notNull().default(0),
    cacheReadTokens: integer("cache_read_tokens").notNull().default(0),
    cacheWriteTokens: integer("cache_write_tokens").notNull().default(0),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [
    index("run_usage_user_id_created_at_idx").on(t.userId, t.createdAt),
    index("run_usage_run_id_idx").on(t.runId),
  ],
);

export type RunUsageRow = typeof runUsage.$inferSelect;

// ---------------------------------------------------------------------------
// Studio repo binding (gateway route layer).
//
// A Studio session is bound to ONE repository and ONE branch. The binding is
// server-side because the two operations that follow a clone — "switch
// branch" and "sync latest" — need to know which directory in the workspace
// to act on, and the client must not be the only memory of it (a reload would
// otherwise orphan the clone). `repo_dir` is workspace-relative and validated
// by the worker before any git command runs.
//
// The GitHub credential is deliberately NOT here: it stays in the user's
// curated `github` MCP integration, sealed with the master key, and the
// worker resolves it per job. Nothing in this table is a secret.
// ---------------------------------------------------------------------------
export const studioRepos = pgTable(
  "studio_repos",
  {
    // One repo per session: the primary key is the session.
    sessionId: char("session_id", { length: 36 })
      .primaryKey()
      .references(() => sessions.id, { onDelete: "cascade" }),
    userId: text("user_id")
      .notNull()
      .references(() => users.uid, { onDelete: "cascade" }),
    /** Canonical `owner/name` (never a URL, never a credential). */
    repo: text("repo").notNull(),
    /** Workspace-relative clone directory (one folder, no nesting). */
    repoDir: text("repo_dir").notNull(),
    branch: text("branch").notNull(),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [
    index("studio_repos_user_id_idx").on(t.userId),
    check("studio_repos_repo_len_check", sql`length(${t.repo}) BETWEEN 1 AND 2048`),
    check("studio_repos_dir_len_check", sql`length(${t.repoDir}) BETWEEN 1 AND 255`),
    check("studio_repos_branch_len_check", sql`length(${t.branch}) BETWEEN 1 AND 255`),
  ],
);

export type StudioRepoRow = typeof studioRepos.$inferSelect;
