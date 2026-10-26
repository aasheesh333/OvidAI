import {
  bigint,
  bigserial,
  boolean,
  char,
  check,
  customType,
  doublePrecision,
  foreignKey,
  index,
  integer,
  jsonb,
  numeric,
  pgTable,
  primaryKey,
  text,
  timestamp,
  uniqueIndex,
  uuid,
} from "drizzle-orm/pg-core";
import { sql } from "drizzle-orm";
import type {
  ScheduleAutonomy,
  ScheduleLastResult,
  ScheduleRunStatus,
  ScheduleStatus,
  ScheduleTrigger,
  StructuredSubagentReport,
  UiManifest,
  WorkspaceState,
} from "@ovid/shared";
import type {
  StudioPreviewKind,
  StudioPreviewScript,
  StudioPreviewStatus,
} from "./studioPreviewStore.js";

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
  // WS5/WS10: server-side interim-status wait. Existing JSON preferences are
  // deliberately untouched; this additive scalar has its own bounded contract.
  responseWaitSeconds: integer("response_wait_seconds").notNull().default(45),
  createdAt: timestamptz("created_at").notNull().defaultNow(),
}, (t) => [
  check("users_response_wait_seconds_check", sql`${t.responseWaitSeconds} BETWEEN 15 AND 600`),
]);

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
    // Canonical declared type; octet-stream means the client did not declare
    // one. Actual object metadata stays nullable until HEAD proves it.
    contentType: text("content_type").notNull().default("application/octet-stream"),
    // Presence is separate from the sentinel: an explicitly supplied
    // application/octet-stream is declared; an omitted legacy type is unknown.
    contentTypeDeclared: boolean("content_type_declared").notNull().default(false),
    uploadStatus: text("upload_status")
      .notNull()
      .default("pending")
      .$type<"pending" | "ready" | "failed">(),
    actualBytes: bigint("actual_bytes", { mode: "number" }),
    actualContentType: text("actual_content_type"),
    finalizedAt: timestamptz("finalized_at"),
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
    check("attachments_upload_status_check", sql`${t.uploadStatus} IN ('pending','ready','failed')`),
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
    // Verified purchase facts only. NULL means unknown, never a monthly fallback.
    period: text("period").$type<"monthly" | "yearly" | null>(),
    status: text("status").notNull(), // active|pending|expired|revoked|replaced
    expiresAt: bigint("expires_at", { mode: "number" }),
    autoRenewing: boolean("auto_renewing").notNull().default(false),
    linkedToken: text("linked_token"),
    accountHash: text("account_hash"),
    updatedAt: bigint("updated_at", { mode: "number" }).notNull(),
  },
  (t) => [
    index("billing_purchases_uid_idx").on(t.uid),
    check("billing_purchases_period_check", sql`${t.period} IN ('monthly','yearly')`),
  ],
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
    // Stable provider identity is separate from the per-user connection id.
    // NULL on custom/legacy-writer rows; curated backfill comes from curatedId.
    providerId: text("provider_id"),
    agentEnabled: boolean("agent_enabled").notNull().default(false),
    // Legacy auth was never checked under this state machine: unknown, not a
    // fabricated authorized/missing verdict. Health likewise starts unchecked.
    authState: text("auth_state").notNull().default("unknown"),
    healthState: text("health_state")
      .notNull()
      .default("never_checked")
      .$type<"never_checked" | "checking" | "healthy" | "degraded" | "needs_auth" | "refreshing" | "revoked" | "unavailable" | "disabled">(),
    lastCheckedAt: timestamptz("last_checked_at"),
    lastSuccessAt: timestamptz("last_success_at"),
    configVersion: integer("config_version").notNull().default(1),
    disconnectGeneration: integer("disconnect_generation").notNull().default(0),
    approvedSourceId: text("approved_source_id"),
    approvedDigest: text("approved_digest"),
    normalizedConnectionName: text("normalized_connection_name"),
    config: jsonb("config").$type<Record<string, unknown> | null>(),
    secretsSealed: jsonb("secrets_sealed").$type<SealedEnvelope | null>(),
    enabled: boolean("enabled").notNull().default(true),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex("mcp_servers_user_name_idx").on(t.userId, t.name),
    index("mcp_servers_user_id_idx").on(t.userId),
    // Expression fallbacks keep legacy NULL-writing readers/writers inside
    // the same identity invariants during the expand/contract rollout.
    uniqueIndex("mcp_servers_curated_provider_uq")
      .on(t.userId, sql`COALESCE(${t.providerId}, ${t.curatedId})`)
      .where(sql`${t.curatedId} IS NOT NULL`),
    uniqueIndex("mcp_servers_custom_identity_uq")
      .on(
        t.userId,
        sql`COALESCE(${t.normalizedConnectionName}, lower(btrim(${t.name})))`,
        sql`COALESCE(${t.approvedSourceId}, ${t.approvedDigest}, '')`,
      )
      .where(sql`${t.curatedId} IS NULL`),
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
    /**
     * Lease stamp for the in-progress claim (migration 0042). A worker that
     * dies mid-fan-out leaves `in_progress` behind; after the lease another
     * attempt may take the claim over. NULL on pre-0042 rows, which are
     * treated as immediately reclaimable (they cannot have a live owner).
     */
    claimedAt: timestamptz("claimed_at"),
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
    // 0038: the legacy model column remains for old readers. New measured
    // fields are independent and NULL when the provider did not report them.
    quotaReservationId: char("quota_reservation_id", { length: 36 }),
    quotaCallId: text("quota_call_id"),
    attemptId: char("attempt_id", { length: 36 }),
    requestedModel: text("requested_model"),
    providerModel: text("provider_model"),
    costUsd: numeric("cost_usd", { precision: 38, scale: 10 }),
    costSource: text("cost_source").$type<"litellm" | "provider">(),
    billingClass: text("billing_class").notNull().default("ovid_allowance").$type<"ovid_allowance" | "byok">(),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [
    index("run_usage_user_id_created_at_idx").on(t.userId, t.createdAt),
    index("run_usage_run_id_idx").on(t.runId),
    index("run_usage_session_created_idx").on(t.sessionId, t.createdAt),
    uniqueIndex("run_usage_quota_reservation_uq")
      .on(t.quotaReservationId)
      .where(sql`quota_reservation_id IS NOT NULL`),
    uniqueIndex("run_usage_run_quota_call_uq")
      .on(t.runId, t.quotaCallId)
      .where(sql`quota_call_id IS NOT NULL`),
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

// ---------------------------------------------------------------------------
// WS4 durable subagent admission, lineage, reports, and root finalization.
// Messages/runs/session_event_mirror remain the transcript and event authority.
// These rows contain only scheduling metadata and the temporary prompt copy
// needed while a request is deferred and has no canonical child message yet.
// ---------------------------------------------------------------------------

export const subagentSessionAdmission = pgTable("subagent_session_admission", {
  sessionId: char("session_id", { length: 36 })
    .primaryKey()
    .references(() => sessions.id, { onDelete: "cascade" }),
  createdAt: timestamptz("created_at").notNull().defaultNow(),
  updatedAt: timestamptz("updated_at").notNull().defaultNow(),
});

export const subagentBatches = pgTable(
  "subagent_batches",
  {
    id: char("id", { length: 36 }).primaryKey(),
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id, { onDelete: "cascade" }),
    userId: text("user_id").notNull().references(() => users.uid),
    rootTaskRunId: char("root_task_run_id", { length: 36 }).notNull().references(() => runs.id),
    parentRunId: char("parent_run_id", { length: 36 }).notNull().references(() => runs.id),
    requestedAt: timestamptz("requested_at").notNull(),
    requestCount: integer("request_count").notNull(),
    admittedCount: integer("admitted_count").notNull().default(0),
    deferredCount: integer("deferred_count").notNull().default(0),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [
    index("subagent_batches_session_id_idx").on(t.sessionId, t.id),
    index("subagent_batches_root_idx").on(t.rootTaskRunId),
    check("subagent_batches_counts_check", sql`${t.requestCount} >= 0 AND ${t.admittedCount} >= 0 AND ${t.deferredCount} >= 0 AND ${t.admittedCount} + ${t.deferredCount} <= ${t.requestCount}`),
  ],
);

export const subagentDispatches = pgTable(
  "subagent_dispatches",
  {
    id: char("id", { length: 36 }).primaryKey(),
    batchId: char("batch_id", { length: 36 })
      .notNull()
      .references(() => subagentBatches.id, { onDelete: "cascade" }),
    requestIndex: integer("request_index").notNull(),
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id, { onDelete: "cascade" }),
    userId: text("user_id").notNull().references(() => users.uid),
    // The originating root is immutable. A later next-user root is recorded
    // separately when this deferred request is actually admitted.
    rootTaskRunId: char("root_task_run_id", { length: 36 }).notNull().references(() => runs.id),
    admittedRootTaskRunId: char("admitted_root_task_run_id", { length: 36 }).references(() => runs.id),
    parentRunId: char("parent_run_id", { length: 36 }).notNull().references(() => runs.id),
    decisionActorRunId: char("decision_actor_run_id", { length: 36 }).references(() => runs.id),
    // NULL after the first canonical child user message exists.
    prompt: text("prompt"),
    firstMessageId: char("first_message_id", { length: 36 }).references(() => messages.id),
    agentType: text("agent_type").notNull().default("general-purpose"),
    tools: jsonb("tools").$type<string[]>(),
    disallowedTools: jsonb("disallowed_tools").$type<string[]>(),
    provenance: text("provenance").notNull().$type<"web" | "android" | "server">(),
    requestedAt: timestamptz("requested_at").notNull(),
    userPriorityHint: integer("user_priority_hint"),
    requestedModel: text("requested_model"),
    byokKeyId: text("byok_key_id"),
    byokModel: text("byok_model"),
    actorUserId: text("actor_user_id").notNull().references(() => users.uid),
    temperature: doublePrecision("temperature"),
    state: text("state")
      .notNull()
      .$type<"awaiting_next_user_task" | "admitted" | "cancelled">(),
    deferReason: text("defer_reason"),
    schedulingReason: text("scheduling_reason"),
    requestedSequence: bigint("requested_sequence", { mode: "number" }),
    deferredAt: timestamptz("deferred_at"),
    admittedAt: timestamptz("admitted_at"),
    cancelledAt: timestamptz("cancelled_at"),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex("subagent_dispatches_batch_index_uq").on(t.batchId, t.requestIndex),
    index("subagent_dispatches_session_state_idx").on(t.sessionId, t.state, t.requestedAt, t.id),
    index("subagent_dispatches_root_idx").on(t.rootTaskRunId),
    index("subagent_dispatches_parent_child_idx").on(t.parentRunId, t.firstMessageId),
    check("subagent_dispatches_provenance_check", sql`${t.provenance} IN ('web','android','server')`),
    check("subagent_dispatches_state_check", sql`${t.state} IN ('awaiting_next_user_task','admitted','cancelled')`),
    check("subagent_dispatches_index_check", sql`${t.requestIndex} >= 0`),
  ],
);

export const subagentLogicalWorkers = pgTable(
  "subagent_logical_workers",
  {
    id: char("id", { length: 36 }).primaryKey(),
    requestId: char("request_id", { length: 36 })
      .notNull()
      .unique()
      .references(() => subagentDispatches.id),
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id, { onDelete: "cascade" }),
    userId: text("user_id").notNull().references(() => users.uid),
    currentRootTaskRunId: char("current_root_task_run_id", { length: 36 }).notNull().references(() => runs.id),
    childSessionId: char("child_session_id", { length: 36 })
      .notNull()
      .unique()
      .references(() => sessions.id),
    agentType: text("agent_type").notNull(),
    status: text("status")
      .notNull()
      .$type<"running" | "completed" | "failed" | "cancelled" | "timeout">(),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [
    index("subagent_workers_session_status_idx").on(t.sessionId, t.status),
    index("subagent_workers_root_idx").on(t.currentRootTaskRunId),
    check("subagent_workers_status_check", sql`${t.status} IN ('running','completed','failed','cancelled','timeout')`),
  ],
);

export const subagentAttempts = pgTable(
  "subagent_attempts",
  {
    id: char("id", { length: 36 }).primaryKey(),
    logicalWorkerId: char("logical_worker_id", { length: 36 })
      .notNull()
      .references(() => subagentLogicalWorkers.id),
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id, { onDelete: "cascade" }),
    rootTaskRunId: char("root_task_run_id", { length: 36 }).notNull().references(() => runs.id),
    executionEpoch: integer("execution_epoch").notNull(),
    attemptNumber: integer("attempt_number").notNull(),
    childSessionId: char("child_session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id),
    childRunId: char("child_run_id", { length: 36 })
      .notNull()
      .unique()
      .references(() => runs.id),
    promptMessageId: char("prompt_message_id", { length: 36 })
      .notNull()
      .references(() => messages.id),
    status: text("status")
      .notNull()
      .$type<"running" | "completed" | "failed" | "cancelled" | "timeout">(),
    admittedAt: timestamptz("admitted_at").notNull(),
    startedAt: timestamptz("started_at").notNull(),
    endedAt: timestamptz("ended_at"),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex("subagent_attempts_worker_number_uq").on(t.logicalWorkerId, t.attemptNumber),
    uniqueIndex("subagent_attempts_one_active_worker_uq")
      .on(t.logicalWorkerId)
      .where(sql`${t.status} = 'running'`),
    index("subagent_attempts_session_active_idx")
      .on(t.sessionId, t.rootTaskRunId, t.id)
      .where(sql`${t.status} = 'running'`),
    index("subagent_attempts_root_epoch_idx").on(t.rootTaskRunId, t.executionEpoch, t.status),
    check("subagent_attempts_status_check", sql`${t.status} IN ('running','completed','failed','cancelled','timeout')`),
    check("subagent_attempts_number_check", sql`${t.attemptNumber} > 0 AND ${t.executionEpoch} > 0`),
    check("subagent_attempts_times_check", sql`${t.startedAt} >= ${t.admittedAt} AND (${t.endedAt} IS NULL OR ${t.endedAt} >= ${t.startedAt})`),
  ],
);

export const subagentReports = pgTable(
  "subagent_reports",
  {
    id: char("id", { length: 36 }).primaryKey(),
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id, { onDelete: "cascade" }),
    logicalWorkerId: char("logical_worker_id", { length: 36 })
      .notNull()
      .references(() => subagentLogicalWorkers.id),
    attemptId: char("attempt_id", { length: 36 })
      .notNull()
      .unique()
      .references(() => subagentAttempts.id),
    childSessionId: char("child_session_id", { length: 36 }).notNull().references(() => sessions.id),
    childRunId: char("child_run_id", { length: 36 }).notNull().references(() => runs.id),
    agentType: text("agent_type").notNull(),
    status: text("status")
      .notNull()
      .$type<"completed" | "failed" | "cancelled" | "timeout">(),
    summary: text("summary").notNull(),
    structuredReport: jsonb("structured_report").$type<StructuredSubagentReport>(),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [
    index("subagent_reports_session_cursor_idx").on(t.sessionId, t.id),
    check("subagent_reports_status_check", sql`${t.status} IN ('completed','failed','cancelled','timeout')`),
    check("subagent_reports_summary_bound_check", sql`length(${t.summary}) <= 4000`),
  ],
);

export const subagentCheckpoints = pgTable(
  "subagent_checkpoints",
  {
    id: char("id", { length: 36 }).primaryKey(),
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id, { onDelete: "cascade" }),
    logicalWorkerId: char("logical_worker_id", { length: 36 })
      .notNull()
      .references(() => subagentLogicalWorkers.id),
    attemptId: char("attempt_id", { length: 36 }).notNull().references(() => subagentAttempts.id),
    rootTaskRunId: char("root_task_run_id", { length: 36 }).notNull().references(() => runs.id),
    hash: text("hash").notNull(),
    objectRef: text("object_ref"),
    provenance: jsonb("provenance").$type<Record<string, unknown>>(),
    verifiedAt: timestamptz("verified_at").notNull(),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [
    index("subagent_checkpoints_worker_created_idx").on(t.logicalWorkerId, t.createdAt, t.id),
    index("subagent_checkpoints_attempt_idx").on(t.attemptId),
  ],
);

export const subagentControlAudit = pgTable(
  "subagent_control_audit",
  {
    id: char("id", { length: 36 }).primaryKey(),
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id, { onDelete: "cascade" }),
    actorRunId: char("actor_run_id", { length: 36 }).notNull().references(() => runs.id),
    rootTaskRunId: char("root_task_run_id", { length: 36 }).references(() => runs.id),
    logicalWorkerId: char("logical_worker_id", { length: 36 }).references(() => subagentLogicalWorkers.id),
    sourceAttemptId: char("source_attempt_id", { length: 36 }).references(() => subagentAttempts.id),
    targetLogicalWorkerId: char("target_logical_worker_id", { length: 36 }).references(() => subagentLogicalWorkers.id),
    checkpointId: char("checkpoint_id", { length: 36 }).references(() => subagentCheckpoints.id),
    deferredRequestId: char("deferred_request_id", { length: 36 }).references(() => subagentDispatches.id),
    action: text("action").notNull(),
    userInstruction: text("user_instruction"),
    decision: text("decision").notNull(),
    reason: text("reason"),
    requestedTransition: text("requested_transition"),
    performedTransition: text("performed_transition"),
    outcome: text("outcome"),
    checkpointFreshness: text("checkpoint_freshness"),
    metadata: jsonb("metadata").$type<Record<string, unknown>>(),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [
    index("subagent_control_audit_session_created_idx").on(t.sessionId, t.createdAt, t.id),
    index("subagent_control_audit_worker_idx").on(t.logicalWorkerId, t.createdAt),
  ],
);

export const subagentRoots = pgTable(
  "subagent_roots",
  {
    rootTaskRunId: char("root_task_run_id", { length: 36 })
      .primaryKey()
      .references(() => runs.id),
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id, { onDelete: "cascade" }),
    executionEpoch: integer("execution_epoch").notNull().default(1),
    activeWorkerCount: integer("active_worker_count").notNull().default(0),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [
    index("subagent_roots_session_idx").on(t.sessionId),
    check("subagent_roots_state_check", sql`${t.executionEpoch} > 0 AND ${t.activeWorkerCount} >= 0`),
  ],
);

export const subagentRootFinalizations = pgTable(
  "subagent_root_finalizations",
  {
    id: char("id", { length: 36 }).primaryKey(),
    rootTaskRunId: char("root_task_run_id", { length: 36 })
      .notNull()
      .references(() => subagentRoots.rootTaskRunId),
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id, { onDelete: "cascade" }),
    executionEpoch: integer("execution_epoch").notNull(),
    activeAttemptIds: jsonb("active_attempt_ids")
      .notNull()
      .default(sql`'[]'::jsonb`)
      .$type<string[]>(),
    wakeRequestedAt: timestamptz("wake_requested_at"),
    finalizedAt: timestamptz("finalized_at"),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex("subagent_root_finalizations_epoch_uq").on(t.rootTaskRunId, t.executionEpoch),
    index("subagent_root_finalizations_session_idx").on(t.sessionId, t.createdAt),
    check("subagent_root_finalizations_epoch_check", sql`${t.executionEpoch} > 0`),
  ],
);

export type SubagentSessionAdmissionRow = typeof subagentSessionAdmission.$inferSelect;
export type SubagentBatchRow = typeof subagentBatches.$inferSelect;
export type SubagentDispatchRow = typeof subagentDispatches.$inferSelect;
export type SubagentLogicalWorkerRow = typeof subagentLogicalWorkers.$inferSelect;
export type SubagentAttemptRow = typeof subagentAttempts.$inferSelect;
export type SubagentReportRow = typeof subagentReports.$inferSelect;
export type SubagentCheckpointRow = typeof subagentCheckpoints.$inferSelect;
export type SubagentControlAuditRow = typeof subagentControlAudit.$inferSelect;
export type SubagentRootRow = typeof subagentRoots.$inferSelect;
export type SubagentRootFinalizationRow = typeof subagentRootFinalizations.$inferSelect;

// ---------------------------------------------------------------------------
// WS5 durable system requests and generic run admission outbox (0033).
// Safe JSON columns never carry credentials. Sensitive response values are not
// stored here: system_request_responses keeps only their SHA-256 digest.
// ---------------------------------------------------------------------------

export const systemRequests = pgTable(
  "system_requests",
  {
    requestId: text("request_id").primaryKey(),
    userId: text("user_id")
      .notNull()
      .references(() => users.uid, { onDelete: "cascade" }),
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id, { onDelete: "cascade" }),
    runId: char("run_id", { length: 36 })
      .notNull()
      .references(() => runs.id),
    kind: text("kind")
      .notNull()
      .$type<"approval" | "sampling" | "elicitation">(),
    safePayload: jsonb("safe_payload").notNull().$type<Record<string, unknown>>(),
    sensitive: boolean("sensitive").notNull(),
    status: text("status")
      .notNull()
      .default("pending")
      .$type<"pending" | "resolved" | "expired" | "cancelled">(),
    expiresAt: timestamptz("expires_at").notNull(),
    version: integer("version").notNull().default(1),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [
    index("system_requests_user_status_idx")
      .on(t.userId, t.status, t.expiresAt, t.createdAt, t.requestId),
    index("system_requests_session_status_idx")
      .on(t.sessionId, t.status, t.expiresAt, t.createdAt, t.requestId),
    index("system_requests_run_idx").on(t.runId),
    check("system_requests_kind_check", sql`${t.kind} IN ('approval','sampling','elicitation')`),
    check("system_requests_status_check", sql`${t.status} IN ('pending','resolved','expired','cancelled')`),
    check("system_requests_version_check", sql`${t.version} > 0`),
  ],
);

export const systemRequestResponses = pgTable(
  "system_request_responses",
  {
    responseId: char("response_id", { length: 36 }).primaryKey(),
    requestId: text("request_id")
      .notNull()
      .references(() => systemRequests.requestId, { onDelete: "cascade" }),
    userId: text("user_id")
      .notNull()
      .references(() => users.uid, { onDelete: "cascade" }),
    requestVersion: integer("request_version").notNull(),
    clientResponseId: text("client_response_id").notNull(),
    // NULL for every sensitive response. The digest proves exact replay versus
    // conflict without retaining the elicited secret in plaintext.
    response: jsonb("response").$type<Record<string, unknown> | null>(),
    responseDigest: text("response_digest").notNull(),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex("system_request_responses_request_version_uq").on(t.requestId, t.requestVersion),
    uniqueIndex("system_request_responses_client_response_uq").on(t.userId, t.clientResponseId),
    check("system_request_responses_version_check", sql`${t.requestVersion} > 0`),
    check("system_request_responses_digest_check", sql`${t.responseDigest} ~ '^[0-9a-f]{64}$'`),
  ],
);

export const runOutbox = pgTable(
  "run_outbox",
  {
    outboxId: char("outbox_id", { length: 36 }).primaryKey(),
    actorUserId: text("actor_user_id")
      .notNull()
      .references(() => users.uid, { onDelete: "cascade" }),
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id, { onDelete: "cascade" }),
    runId: char("run_id", { length: 36 })
      .notNull()
      .references(() => runs.id),
    userMessageId: char("user_message_id", { length: 36 })
      .notNull()
      .references(() => messages.id),
    idempotencyKey: text("idempotency_key").notNull(),
    status: text("status")
      .notNull()
      .default("queued")
      .$type<"queued" | "published" | "settled" | "failed">(),
    requestPayload: jsonb("request_payload").notNull().$type<Record<string, unknown>>(),
    bodyPayload: jsonb("body_payload").notNull().$type<Record<string, unknown>>(),
    jobId: text("job_id").notNull(),
    attempts: integer("attempts").notNull().default(0),
    publishedAt: timestamptz("published_at"),
    lastAttemptAt: timestamptz("last_attempt_at"),
    settledAt: timestamptz("settled_at"),
    lastError: text("last_error"),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex("run_outbox_actor_idempotency_uq").on(t.actorUserId, t.idempotencyKey),
    uniqueIndex("run_outbox_job_uq").on(t.jobId),
    uniqueIndex("run_outbox_run_uq").on(t.runId),
    uniqueIndex("run_outbox_message_uq").on(t.userMessageId),
    index("run_outbox_status_idx").on(t.status, t.createdAt, t.outboxId),
    index("run_outbox_status_attempt_idx").on(t.status, t.lastAttemptAt, t.createdAt, t.outboxId),
    check("run_outbox_status_check", sql`${t.status} IN ('queued','published','settled','failed')`),
    check("run_outbox_attempts_check", sql`${t.attempts} >= 0`),
  ],
);

/**
 * Crash-safe final-response delivery outbox (migration 0042).
 *
 * `run_outbox` above is the Collab *request publication* ledger; this table is
 * the ordinary root-run completion ledger and must not be confused with it.
 *
 * One row per root run, inserted in the SAME transaction as the final
 * assistant message (`message_id`). That transaction is the durable intent:
 * after it commits the answer exists and delivery will be replayed; before it
 * commits neither row exists (no phantom answer). Delivery is at-least-once:
 * `pending` rows are retried by `recoverRunFinalDeliveries` on worker boot and
 * on every scheduler tick, keyed by the unique `run_id`. `delivered` is only
 * written after the message + both terminal events + (when configured) the
 * completion push are confirmed. `failed` is a truthful terminal verdict for
 * an item that can never be delivered (missing message, run already
 * terminalized non-completed); it is never used for an unknown outcome.
 */
export const runDeliveryOutbox = pgTable(
  "run_delivery_outbox",
  {
    outboxId: char("outbox_id", { length: 36 }).primaryKey(),
    runId: char("run_id", { length: 36 })
      .notNull()
      .references(() => runs.id, { onDelete: "cascade" }),
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id, { onDelete: "cascade" }),
    userId: text("user_id")
      .notNull()
      .references(() => users.uid, { onDelete: "cascade" }),
    messageId: char("message_id", { length: 36 })
      .notNull()
      .references(() => messages.id, { onDelete: "cascade" }),
    /** Scheduled runs use notifyScheduleSucceeded, never agentFinished. */
    scheduled: boolean("scheduled").notNull().default(false),
    /** Exact `run_completed` payload (runId + optional usage) for replay. */
    completionPayload: jsonb("completion_payload").notNull().$type<Record<string, unknown>>(),
    status: text("status")
      .notNull()
      .default("pending")
      .$type<"pending" | "delivering" | "delivered" | "failed">(),
    attempts: integer("attempts").notNull().default(0),
    lastAttemptAt: timestamptz("last_attempt_at"),
    deliveredAt: timestamptz("delivered_at"),
    lastError: text("last_error"),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex("run_delivery_outbox_run_uq").on(t.runId),
    index("run_delivery_outbox_status_idx").on(t.status, t.lastAttemptAt, t.createdAt),
    check(
      "run_delivery_outbox_status_check",
      sql`${t.status} IN ('pending','delivering','delivered','failed')`,
    ),
    check("run_delivery_outbox_attempts_check", sql`${t.attempts} >= 0`),
  ],
);

export type RunDeliveryOutboxRow = typeof runDeliveryOutbox.$inferSelect;

// RevenueCat/verified entitlement facts and webhook replay dedupe. No raw
// webhook payload or purchase token is retained here. Unknown product/tier,
// period, expiry, or event time stays NULL rather than gaining a default.
export const billingEntitlementEvents = pgTable(
  "billing_entitlement_events",
  {
    eventId: text("event_id").primaryKey(),
    userId: text("user_id"),
    productId: text("product_id"),
    tier: text("tier"),
    period: text("period").$type<"monthly" | "yearly" | null>(),
    purchaseState: text("purchase_state").notNull(),
    eventType: text("event_type").notNull(),
    expiresAt: timestamptz("expires_at"),
    occurredAt: timestamptz("occurred_at"),
    receivedAt: timestamptz("received_at").notNull().defaultNow(),
  },
  (t) => [
    index("billing_entitlement_events_user_received_idx").on(t.userId, t.receivedAt, t.eventId),
    check("billing_entitlement_events_period_check", sql`${t.period} IN ('monthly','yearly')`),
  ],
);

export type SystemRequestRow = typeof systemRequests.$inferSelect;
export type SystemRequestResponseRow = typeof systemRequestResponses.$inferSelect;
export type RunOutboxRow = typeof runOutbox.$inferSelect;
export type BillingEntitlementEventRow = typeof billingEntitlementEvents.$inferSelect;

// ---------------------------------------------------------------------------
// 0038 universal model-call quota and rolling upload/storage reservations.
// UTC day/month counters include actual run_usage facts plus unsettled model
// allowances. Reservation identity, not a process-local map, is authoritative.
// Image facts are additive satellites: old image_jobs SELECT * readers retain
// their exact row shape, and missing lineage/count/cost facts stay unknown.
// ---------------------------------------------------------------------------

export const imageUsageFacts = pgTable(
  "image_usage_facts",
  {
    account: text("account").notNull(),
    request: text("request").notNull(),
    sessionId: char("session_id", { length: 36 }),
    runId: char("run_id", { length: 36 }),
    generateCount: integer("generate_count"),
    editCount: integer("edit_count"),
    costUsd: numeric("cost_usd", { precision: 38, scale: 10 }),
  },
  (t) => [
    primaryKey({ columns: [t.account, t.request] }),
    foreignKey({
      columns: [t.account, t.request],
      foreignColumns: [imageJobs.account, imageJobs.request],
      name: "image_usage_facts_account_request_image_jobs_account_request_fk",
    }).onDelete("cascade"),
    index("image_usage_facts_session_idx").on(t.sessionId),
    index("image_usage_facts_run_idx").on(t.runId),
    check("image_usage_facts_counts_check", sql`(${t.generateCount} IS NULL OR ${t.generateCount} >= 0) AND (${t.editCount} IS NULL OR ${t.editCount} >= 0)`),
    check("image_usage_facts_cost_check", sql`${t.costUsd} IS NULL OR ${t.costUsd} >= 0`),
  ],
);

export const usageQuotaCounters = pgTable(
  "usage_quota_counters",
  {
    actorUserId: text("actor_user_id")
      .notNull()
      .references(() => users.uid, { onDelete: "cascade" }),
    windowKind: text("window_kind").notNull().$type<"day" | "month">(),
    windowStart: timestamptz("window_start").notNull(),
    windowEnd: timestamptz("window_end").notNull(),
    usedTokens: bigint("used_tokens", { mode: "number" }).notNull().default(0),
    reservedTokens: bigint("reserved_tokens", { mode: "number" }).notNull().default(0),
    usedUsd: numeric("used_usd", { precision: 38, scale: 10 }).notNull().default("0"),
    reservedUsd: numeric("reserved_usd", { precision: 38, scale: 10 }).notNull().default("0"),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [
    primaryKey({ columns: [t.actorUserId, t.windowKind, t.windowStart] }),
    check("usage_quota_counters_window_check", sql`${t.windowKind} IN ('day','month') AND ${t.windowEnd} > ${t.windowStart}`),
    check("usage_quota_counters_tokens_check", sql`${t.usedTokens} >= 0 AND ${t.reservedTokens} >= 0`),
    check("usage_quota_counters_usd_check", sql`${t.usedUsd} >= 0 AND ${t.reservedUsd} >= 0`),
  ],
);

export const usageRunAdmissions = pgTable(
  "usage_run_admissions",
  {
    id: char("id", { length: 36 }).primaryKey(),
    actorUserId: text("actor_user_id")
      .notNull()
      .references(() => users.uid, { onDelete: "cascade" }),
    source: text("source").notNull(),
    runId: char("run_id", { length: 36 }).notNull(),
    idempotencyKey: text("idempotency_key").notNull(),
    billingClass: text("billing_class").notNull().default("ovid_allowance").$type<"ovid_allowance" | "byok">(),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex("usage_run_admissions_actor_key_uq").on(t.actorUserId, t.idempotencyKey),
    index("usage_run_admissions_run_idx").on(t.actorUserId, t.runId),
    check("usage_run_admissions_source_check", sql`${t.source} IN ('interactive','schedule_create','schedule_run_now','schedule_tick','schedule_retry','parent_wake','subagent','collab')`),
  ],
);

export const usageQuotaReservations = pgTable(
  "usage_quota_reservations",
  {
    id: char("id", { length: 36 }).primaryKey(),
    actorUserId: text("actor_user_id")
      .notNull()
      .references(() => users.uid, { onDelete: "cascade" }),
    runId: char("run_id", { length: 36 }).notNull(),
    attemptId: char("attempt_id", { length: 36 }),
    sessionId: char("session_id", { length: 36 }),
    runSource: text("run_source"),
    reservationKey: text("reservation_key").notNull(),
    state: text("state")
      .notNull()
      .default("reserved")
      .$type<"reserved" | "settled" | "released">(),
    inputTokens: bigint("input_tokens", { mode: "number" }).notNull(),
    maxOutputTokens: bigint("max_output_tokens", { mode: "number" }).notNull(),
    reservedCostUsd: numeric("reserved_cost_usd", { precision: 38, scale: 10 })
      .notNull()
      .default("0"),
    requestedModel: text("requested_model"),
    providerModel: text("provider_model"),
    actualInputTokens: bigint("actual_input_tokens", { mode: "number" }),
    actualOutputTokens: bigint("actual_output_tokens", { mode: "number" }),
    actualCacheReadTokens: bigint("actual_cache_read_tokens", { mode: "number" }),
    actualCacheWriteTokens: bigint("actual_cache_write_tokens", { mode: "number" }),
    costUsd: numeric("cost_usd", { precision: 38, scale: 10 }),
    costSource: text("cost_source").$type<"litellm" | "provider">(),
    billingClass: text("billing_class").notNull().default("ovid_allowance").$type<"ovid_allowance" | "byok">(),
    dayWindowStart: timestamptz("day_window_start").notNull(),
    monthWindowStart: timestamptz("month_window_start").notNull(),
    runUsageId: char("run_usage_id", { length: 36 }),
    reservedAt: timestamptz("reserved_at").notNull().defaultNow(),
    settledAt: timestamptz("settled_at"),
    releasedAt: timestamptz("released_at"),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex("usage_quota_reservations_actor_key_uq").on(t.actorUserId, t.reservationKey),
    index("usage_quota_reservations_actor_window_idx")
      .on(t.actorUserId, t.state, t.dayWindowStart, t.monthWindowStart),
    index("usage_quota_reservations_run_attempt_idx").on(t.runId, t.attemptId),
    check("usage_quota_reservations_state_check", sql`${t.state} IN ('reserved','settled','released')`),
    check("usage_quota_reservations_tokens_check", sql`${t.inputTokens} >= 0 AND ${t.maxOutputTokens} >= 0 AND (${t.actualInputTokens} IS NULL OR ${t.actualInputTokens} >= 0) AND (${t.actualOutputTokens} IS NULL OR ${t.actualOutputTokens} >= 0)`),
    check("usage_quota_reservations_usd_check", sql`${t.reservedCostUsd} >= 0 AND (${t.costUsd} IS NULL OR ${t.costUsd} >= 0)`),
  ],
);

export const uploadWindowCounters = pgTable(
  "upload_window_counters",
  {
    actorUserId: text("actor_user_id")
      .notNull()
      .references(() => users.uid, { onDelete: "cascade" }),
    windowHours: integer("window_hours").notNull(),
    windowStart: timestamptz("window_start").notNull(),
    windowEnd: timestamptz("window_end").notNull(),
    usedUploads: integer("used_uploads").notNull().default(0),
    reservedUploads: integer("reserved_uploads").notNull().default(0),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [
    primaryKey({ columns: [t.actorUserId, t.windowHours] }),
    index("upload_window_counters_actor_window_idx").on(t.actorUserId, t.windowStart, t.windowEnd),
    check("upload_window_counters_window_check", sql`${t.windowHours} > 0 AND ${t.windowEnd} > ${t.windowStart}`),
    check("upload_window_counters_counts_check", sql`${t.usedUploads} >= 0 AND ${t.reservedUploads} >= 0`),
  ],
);

export const storageUsageCounters = pgTable("storage_usage_counters", {
  ownerUserId: text("owner_user_id")
    .primaryKey()
    .references(() => users.uid, { onDelete: "cascade" }),
  usedBytes: bigint("used_bytes", { mode: "number" }).notNull().default(0),
  reservedBytes: bigint("reserved_bytes", { mode: "number" }).notNull().default(0),
  updatedAt: timestamptz("updated_at").notNull().defaultNow(),
}, (t) => [
  check("storage_usage_counters_bytes_check", sql`${t.usedBytes} >= 0 AND ${t.reservedBytes} >= 0`),
]);

export const storageReservations = pgTable(
  "storage_reservations",
  {
    id: text("id").primaryKey(),
    actorUserId: text("actor_user_id")
      .notNull()
      .references(() => users.uid, { onDelete: "cascade" }),
    ownerUserId: text("owner_user_id")
      .notNull()
      .references(() => users.uid, { onDelete: "cascade" }),
    sessionId: char("session_id", { length: 36 }).notNull(),
    objectId: text("object_id"),
    state: text("state")
      .notNull()
      .default("reserved")
      .$type<"reserved" | "finalized" | "released">(),
    declaredBytes: bigint("declared_bytes", { mode: "number" }).notNull(),
    actualBytes: bigint("actual_bytes", { mode: "number" }),
    actualContentType: text("actual_content_type"),
    etag: text("etag"),
    reservedAt: timestamptz("reserved_at").notNull().defaultNow(),
    finalizedAt: timestamptz("finalized_at"),
    releasedAt: timestamptz("released_at"),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [
    index("storage_reservations_actor_state_window_idx").on(t.actorUserId, t.state, t.reservedAt),
    index("storage_reservations_owner_state_idx").on(t.ownerUserId, t.state),
    index("storage_reservations_session_idx").on(t.sessionId),
    index("storage_reservations_object_idx").on(t.objectId),
    check("storage_reservations_state_check", sql`${t.state} IN ('reserved','finalized','released')`),
    check("storage_reservations_bytes_check", sql`${t.declaredBytes} >= 0 AND (${t.actualBytes} IS NULL OR ${t.actualBytes} >= 0)`),
    check("storage_reservations_state_fields_check", sql`(${t.state} = 'reserved' AND ${t.actualBytes} IS NULL AND ${t.finalizedAt} IS NULL AND ${t.releasedAt} IS NULL) OR (${t.state} = 'finalized' AND ${t.actualBytes} IS NOT NULL AND ${t.finalizedAt} IS NOT NULL AND ${t.releasedAt} IS NULL) OR (${t.state} = 'released' AND ${t.actualBytes} IS NULL AND ${t.finalizedAt} IS NULL AND ${t.releasedAt} IS NOT NULL)`),
  ],
);

export type ImageUsageFactRow = typeof imageUsageFacts.$inferSelect;
export type UsageQuotaCounterRow = typeof usageQuotaCounters.$inferSelect;
export type UsageRunAdmissionRow = typeof usageRunAdmissions.$inferSelect;
export type UsageQuotaReservationRow = typeof usageQuotaReservations.$inferSelect;
export type UploadWindowCounterRow = typeof uploadWindowCounters.$inferSelect;
export type StorageUsageCounterRow = typeof storageUsageCounters.$inferSelect;
export type StorageReservationRow = typeof storageReservations.$inferSelect;

// ---------------------------------------------------------------------------
// 0039 lossless compaction: append-only exact-history references, immutable
// checkpoints, and independently locked main/worker cursors. Existing canonical
// rows remain authoritative. NULL means that legacy lineage or usage was not
// evidenced; it never means zero measured tokens.
// ---------------------------------------------------------------------------

export type CompactionHistoryItemKind =
  | "message"
  | "tool_call"
  | "approval"
  | "artifact"
  | "file"
  | "logical_worker"
  | "attempt"
  | "checkpoint"
  | "compaction"
  | "event"
  | "control";

export const compactionHistoryItems = pgTable(
  "compaction_history_items",
  {
    position: bigserial("position", { mode: "number" }).primaryKey(),
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id, { onDelete: "cascade" }),
    rootTaskRunId: char("root_task_run_id", { length: 36 }).references(() => runs.id),
    logicalWorkerId: char("logical_worker_id", { length: 36 })
      .references(() => subagentLogicalWorkers.id),
    attemptId: char("attempt_id", { length: 36 }).references(() => subagentAttempts.id),
    kind: text("kind").notNull().$type<CompactionHistoryItemKind>(),
    stableId: text("stable_id").notNull(),
    eventCursor: text("event_cursor").notNull(),
    // Legacy-compatible payload column only. The 0039 repository never writes
    // new inline plaintext: exact content lives in canonical/sealed objects and
    // every new row uses objectRef. Raw legacy reads are fenced explicitly.
    inlinePayload: jsonb("inline_payload"),
    objectRef: text("object_ref"),
    byteLength: bigint("byte_length", { mode: "number" }).notNull(),
    occurredAt: timestamptz("occurred_at"),
    recordedAt: timestamptz("recorded_at").notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex("compaction_history_identity_uq")
      .on(t.sessionId, t.kind, t.stableId, t.eventCursor),
    index("compaction_history_scope_position_idx")
      .on(t.sessionId, t.rootTaskRunId, t.logicalWorkerId, t.attemptId, t.position),
    index("compaction_history_reference_idx")
      .on(t.sessionId, t.kind, t.stableId, t.position),
    index("compaction_history_event_cursor_idx")
      .on(t.sessionId, t.eventCursor, t.position),
    check("compaction_history_kind_check", sql`${t.kind} IN ('message','tool_call','approval','artifact','file','logical_worker','attempt','checkpoint','compaction','event','control')`),
    check("compaction_history_payload_check", sql`(${t.inlinePayload} IS NOT NULL AND ${t.objectRef} IS NULL) OR (${t.inlinePayload} IS NULL AND ${t.objectRef} IS NOT NULL)`),
    check("compaction_history_bytes_check", sql`${t.byteLength} >= 0`),
    check("compaction_history_lineage_check", sql`${t.attemptId} IS NULL OR ${t.logicalWorkerId} IS NOT NULL`),
  ],
);

export const compactionCheckpoints = pgTable(
  "compaction_checkpoints",
  {
    checkpointId: char("checkpoint_id", { length: 36 }).primaryKey(),
    compactionId: char("compaction_id", { length: 36 }).notNull(),
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id, { onDelete: "cascade" }),
    rootTaskRunId: char("root_task_run_id", { length: 36 }).references(() => runs.id),
    logicalWorkerId: char("logical_worker_id", { length: 36 })
      .references(() => subagentLogicalWorkers.id),
    attemptId: char("attempt_id", { length: 36 }).references(() => subagentAttempts.id),
    actorId: text("actor_id"),
    actorKind: text("actor_kind").$type<"main" | "worker">(),
    previousCheckpointId: char("previous_checkpoint_id", { length: 36 }),
    requestDigest: char("request_digest", { length: 64 }),
    model: text("model"),
    contextLimit: bigint("context_limit", { mode: "number" }),
    outputReserveTokens: bigint("output_reserve_tokens", { mode: "number" }),
    providerReserveTokens: bigint("provider_reserve_tokens", { mode: "number" }),
    beforeTokens: bigint("before_tokens", { mode: "number" }),
    afterTokens: bigint("after_tokens", { mode: "number" }),
    usageSource: text("usage_source").$type<"measured" | "deterministic_fallback">(),
    cutoffCursor: text("cutoff_cursor"),
    cutoffMessageId: char("cutoff_message_id", { length: 36 }),
    ledgerVersion: integer("ledger_version"),
    ledger: jsonb("ledger").$type<Record<string, unknown>>(),
    summary: text("summary"),
    activeState: jsonb("active_state").notNull().$type<Record<string, unknown>>(),
    continuation: text("continuation").$type<"continuing_existing_task">(),
    createdAt: timestamptz("created_at"),
    recordedAt: timestamptz("recorded_at").notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex("compaction_checkpoints_compaction_uq").on(t.compactionId),
    uniqueIndex("compaction_checkpoints_request_uq")
      .on(t.sessionId, t.rootTaskRunId, t.actorKind, t.actorId, t.requestDigest),
    index("compaction_checkpoints_scope_idx")
      .on(t.sessionId, t.rootTaskRunId, t.actorKind, t.actorId, t.createdAt, t.checkpointId),
    check("compaction_checkpoints_actor_kind_check", sql`${t.actorKind} IS NULL OR ${t.actorKind} IN ('main','worker')`),
    check("compaction_checkpoints_usage_source_check", sql`${t.usageSource} IS NULL OR ${t.usageSource} IN ('measured','deterministic_fallback')`),
    check("compaction_checkpoints_tokens_check", sql`(${t.contextLimit} IS NULL OR ${t.contextLimit} > 0) AND (${t.outputReserveTokens} IS NULL OR ${t.outputReserveTokens} >= 0) AND (${t.providerReserveTokens} IS NULL OR ${t.providerReserveTokens} >= 0) AND (${t.beforeTokens} IS NULL OR ${t.beforeTokens} >= 0) AND (${t.afterTokens} IS NULL OR ${t.afterTokens} >= 0)`),
    check("compaction_checkpoints_ledger_check", sql`${t.ledgerVersion} IS NULL OR ${t.ledgerVersion} > 0`),
    check("compaction_checkpoints_digest_check", sql`${t.requestDigest} IS NULL OR ${t.requestDigest} ~ '^[0-9a-f]{64}$'`),
    check("compaction_checkpoints_continuation_check", sql`${t.continuation} IS NULL OR ${t.continuation} = 'continuing_existing_task'`),
    check("compaction_checkpoints_shape_check", sql`
      (${t.actorKind} IS NULL AND ${t.actorId} IS NULL AND ${t.rootTaskRunId} IS NULL AND ${t.logicalWorkerId} IS NULL AND ${t.attemptId} IS NULL AND ${t.requestDigest} IS NULL AND ${t.model} IS NULL AND ${t.contextLimit} IS NULL AND ${t.outputReserveTokens} IS NULL AND ${t.providerReserveTokens} IS NULL AND ${t.beforeTokens} IS NULL AND ${t.afterTokens} IS NULL AND ${t.usageSource} IS NULL AND ${t.ledgerVersion} IS NULL AND ${t.ledger} IS NULL AND ${t.summary} IS NULL AND ${t.continuation} IS NULL AND ${t.createdAt} IS NULL)
      OR
      (${t.rootTaskRunId} IS NOT NULL AND ${t.actorId} IS NOT NULL AND ${t.requestDigest} IS NOT NULL AND ${t.model} IS NOT NULL AND ${t.contextLimit} IS NOT NULL AND ${t.outputReserveTokens} IS NOT NULL AND ${t.providerReserveTokens} IS NOT NULL AND ${t.beforeTokens} IS NOT NULL AND ${t.afterTokens} IS NOT NULL AND ${t.usageSource} IS NOT NULL AND ${t.ledgerVersion} IS NOT NULL AND ${t.ledger} IS NOT NULL AND ${t.summary} IS NOT NULL AND ${t.continuation} IS NOT NULL AND ${t.createdAt} IS NOT NULL AND
        ((${t.actorKind} = 'main' AND ${t.actorId} = 'main' AND ${t.logicalWorkerId} IS NULL AND ${t.attemptId} IS NULL) OR
         (${t.actorKind} = 'worker' AND ${t.logicalWorkerId} IS NOT NULL AND ${t.attemptId} IS NOT NULL AND ${t.actorId} = ${t.logicalWorkerId}::text)))`),
  ],
);

export const compactionCursors = pgTable(
  "compaction_cursors",
  {
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id, { onDelete: "cascade" }),
    rootTaskRunId: char("root_task_run_id", { length: 36 })
      .notNull()
      .references(() => runs.id),
    actorKind: text("actor_kind").notNull().$type<"main" | "worker">(),
    actorId: text("actor_id").notNull(),
    logicalWorkerId: char("logical_worker_id", { length: 36 })
      .references(() => subagentLogicalWorkers.id),
    attemptId: char("attempt_id", { length: 36 }).references(() => subagentAttempts.id),
    checkpointId: char("checkpoint_id", { length: 36 })
      .references(() => compactionCheckpoints.checkpointId),
    compactionId: char("compaction_id", { length: 36 }),
    cutoffCursor: text("cutoff_cursor"),
    cutoffMessageId: char("cutoff_message_id", { length: 36 }),
    ledgerVersion: integer("ledger_version").notNull().default(0),
    pendingRecallCursor: text("pending_recall_cursor"),
    continuation: text("continuation")
      .notNull()
      .default("continuing_existing_task")
      .$type<"continuing_existing_task">(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [
    primaryKey({ columns: [t.sessionId, t.rootTaskRunId, t.actorKind, t.actorId] }),
    index("compaction_cursors_worker_idx")
      .on(t.sessionId, t.logicalWorkerId, t.rootTaskRunId),
    index("compaction_cursors_checkpoint_idx").on(t.checkpointId),
    check("compaction_cursors_actor_check", sql`(${t.actorKind} = 'main' AND ${t.actorId} = 'main' AND ${t.logicalWorkerId} IS NULL AND ${t.attemptId} IS NULL) OR (${t.actorKind} = 'worker' AND ${t.logicalWorkerId} IS NOT NULL AND ${t.attemptId} IS NOT NULL AND ${t.actorId} = ${t.logicalWorkerId}::text)`),
    check("compaction_cursors_ledger_check", sql`${t.ledgerVersion} >= 0`),
    check("compaction_cursors_continuation_check", sql`${t.continuation} = 'continuing_existing_task'`),
  ],
);

export type CompactionHistoryItemRow = typeof compactionHistoryItems.$inferSelect;
export type CompactionCheckpointRow = typeof compactionCheckpoints.$inferSelect;
export type CompactionCursorRow = typeof compactionCursors.$inferSelect;

// ---------------------------------------------------------------------------
// 0040 collaboration metadata. Bearer material is SHA-256 hashed at rest; the
// canonical sessions/messages/runs/session_event_mirror tables remain the only
// transcript/history. Generations are durable fencing inputs for Task 4's run
// admission/writer, never client-supplied authority.
// ---------------------------------------------------------------------------

export const collabRooms = pgTable(
  "collab_rooms",
  {
    id: char("id", { length: 36 }).primaryKey(),
    tokenHash: char("token_hash", { length: 64 }).notNull(),
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id, { onDelete: "cascade" }),
    ownerUserId: text("owner_user_id")
      .notNull()
      .references(() => users.uid, { onDelete: "cascade" }),
    requestId: text("request_id").notNull(),
    lifecycle: text("lifecycle").notNull().default("active").$type<"active" | "closing" | "closed">(),
    generation: bigint("generation", { mode: "number" }).notNull().default(1),
    closeRequestId: text("close_request_id"),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex("collab_rooms_token_hash_uq").on(t.tokenHash),
    uniqueIndex("collab_rooms_session_uq").on(t.sessionId),
    uniqueIndex("collab_rooms_owner_request_uq").on(t.ownerUserId, t.requestId),
    index("collab_rooms_owner_lifecycle_idx").on(t.ownerUserId, t.lifecycle),
    check("collab_rooms_token_hash_check", sql`${t.tokenHash} ~ '^[0-9a-f]{64}$'`),
    check("collab_rooms_lifecycle_check", sql`${t.lifecycle} IN ('active','closing','closed')`),
    check("collab_rooms_generation_check", sql`${t.generation} >= 1`),
  ],
);

export const collabMembers = pgTable(
  "collab_members",
  {
    roomId: char("room_id", { length: 36 })
      .notNull()
      .references(() => collabRooms.id, { onDelete: "cascade" }),
    userId: text("user_id")
      .notNull()
      .references(() => users.uid, { onDelete: "cascade" }),
    participantId: text("participant_id").notNull(),
    role: text("role").notNull().$type<"owner" | "participant">(),
    status: text("status").notNull().default("active").$type<"active" | "left" | "revoked">(),
    displayName: text("display_name"),
    generation: bigint("generation", { mode: "number" }).notNull().default(1),
    joinRequestId: text("join_request_id"),
    joinInviteHash: char("join_invite_hash", { length: 64 }),
    joinedAt: timestamptz("joined_at").notNull().defaultNow(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
    revokedAt: timestamptz("revoked_at"),
  },
  (t) => [
    primaryKey({ columns: [t.roomId, t.userId] }),
    uniqueIndex("collab_members_room_participant_uq").on(t.roomId, t.participantId),
    uniqueIndex("collab_members_room_active_owner_uq").on(t.roomId).where(sql`${t.role} = 'owner' AND ${t.status} = 'active'`),
    index("collab_members_room_status_idx").on(t.roomId, t.status, t.joinedAt, t.participantId),
    index("collab_members_user_status_idx").on(t.userId, t.status),
    check("collab_members_role_check", sql`${t.role} IN ('owner','participant')`),
    check("collab_members_status_check", sql`${t.status} IN ('active','left','revoked')`),
    check("collab_members_generation_check", sql`${t.generation} >= 1`),
    check("collab_members_join_invite_hash_check", sql`${t.joinInviteHash} IS NULL OR ${t.joinInviteHash} ~ '^[0-9a-f]{64}$'`),
  ],
);

export const collabInvites = pgTable(
  "collab_invites",
  {
    id: text("id").primaryKey(),
    roomId: char("room_id", { length: 36 })
      .notNull()
      .references(() => collabRooms.id, { onDelete: "cascade" }),
    codeHash: char("code_hash", { length: 64 }).notNull(),
    issuedByUserId: text("issued_by_user_id")
      .notNull()
      .references(() => users.uid, { onDelete: "cascade" }),
    idempotencyKey: text("idempotency_key").notNull(),
    issuedGeneration: bigint("issued_generation", { mode: "number" }).notNull().default(1),
    maxUses: integer("max_uses").notNull(),
    uses: integer("uses").notNull().default(0),
    expiresAt: timestamptz("expires_at").notNull(),
    revokedAt: timestamptz("revoked_at"),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex("collab_invites_code_hash_uq").on(t.codeHash),
    uniqueIndex("collab_invites_room_request_uq").on(t.roomId, t.issuedByUserId, t.idempotencyKey),
    index("collab_invites_room_active_idx").on(t.roomId, t.revokedAt, t.expiresAt),
    index("collab_invites_issuer_idx").on(t.issuedByUserId, t.revokedAt),
    check("collab_invites_code_hash_check", sql`${t.codeHash} ~ '^[0-9a-f]{64}$'`),
    check("collab_invites_uses_check", sql`${t.maxUses} BETWEEN 1 AND 50 AND ${t.uses} >= 0 AND ${t.uses} <= ${t.maxUses}`),
    check("collab_invites_generation_check", sql`${t.issuedGeneration} >= 1`),
  ],
);

export const collabTurns = pgTable(
  "collab_turns",
  {
    id: char("id", { length: 36 }).primaryKey(),
    roomId: char("room_id", { length: 36 })
      .notNull()
      .references(() => collabRooms.id, { onDelete: "cascade" }),
    participantId: text("participant_id").notNull(),
    actorUserId: text("actor_user_id")
      .notNull()
      .references(() => users.uid, { onDelete: "cascade" }),
    runId: char("run_id", { length: 36 })
      .notNull()
      .references(() => runs.id, { onDelete: "cascade" }),
    userMessageId: char("user_message_id", { length: 36 })
      .notNull()
      .references(() => messages.id, { onDelete: "cascade" }),
    idempotencyKey: text("idempotency_key").notNull(),
    model: text("model"),
    status: text("status").notNull().default("queued").$type<"queued" | "running" | "completed" | "failed" | "cancelled" | "interrupted">(),
    cancelRequestedAt: timestamptz("cancel_requested_at"),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex("collab_turns_room_idempotency_uq").on(t.roomId, t.idempotencyKey),
    uniqueIndex("collab_turns_run_uq").on(t.runId),
    index("collab_turns_actor_status_idx").on(t.actorUserId, t.status),
    index("collab_turns_room_participant_idx").on(t.roomId, t.participantId),
    check("collab_turns_status_check", sql`${t.status} IN ('queued','running','completed','failed','cancelled','interrupted')`),
  ],
);

export const collabSenderLeases = pgTable(
  "collab_sender_leases",
  {
    id: char("id", { length: 36 }).primaryKey(),
    roomId: char("room_id", { length: 36 })
      .notNull()
      .references(() => collabRooms.id, { onDelete: "cascade" }),
    holderParticipantId: text("holder_participant_id").notNull(),
    holderUserId: text("holder_user_id")
      .notNull()
      .references(() => users.uid, { onDelete: "cascade" }),
    runId: char("run_id", { length: 36 })
      .notNull()
      .references(() => runs.id, { onDelete: "cascade" }),
    generation: bigint("generation", { mode: "number" }).notNull().default(1),
    roomGeneration: bigint("room_generation", { mode: "number" }).notNull().default(1),
    membershipGeneration: bigint("membership_generation", { mode: "number" }).notNull().default(1),
    startedAt: timestamptz("started_at").notNull().defaultNow(),
    heartbeatAt: timestamptz("heartbeat_at").notNull().defaultNow(),
    releasedAt: timestamptz("released_at"),
    cancelRequestedAt: timestamptz("cancel_requested_at"),
  },
  (t) => [
    uniqueIndex("collab_sender_leases_run_uq").on(t.runId),
    uniqueIndex("collab_sender_leases_room_active_uq").on(t.roomId).where(sql`${t.releasedAt} IS NULL`),
    index("collab_sender_leases_heartbeat_idx").on(t.heartbeatAt).where(sql`${t.releasedAt} IS NULL`),
    index("collab_sender_leases_holder_idx").on(t.holderUserId, t.releasedAt),
    check("collab_sender_leases_generations_check", sql`${t.generation} >= 1 AND ${t.roomGeneration} >= 1 AND ${t.membershipGeneration} >= 1`),
  ],
);

export type CollabRoomRow = typeof collabRooms.$inferSelect;
export type CollabMemberRow = typeof collabMembers.$inferSelect;
export type CollabInviteRow = typeof collabInvites.$inferSelect;
export type CollabTurnRow = typeof collabTurns.$inferSelect;
export type CollabSenderLeaseRow = typeof collabSenderLeases.$inferSelect;

// ---------------------------------------------------------------------------
// 0041 Studio preview process registration. Launch identity/definition are
// immutable through studioPreviewPostgres; no argv, URL, grant, cookie, ticket,
// credential or other secret material is stored here. Both parent FKs are
// deliberately NO ACTION: session/account deletion must first stop previews and
// then explicitly remove terminal evidence, never cascade away live recovery.
// ---------------------------------------------------------------------------

export const studioPreviews = pgTable(
  "studio_previews",
  {
    id: uuid("id").primaryKey(),
    // Match the canonical sessions.id char(36) parent exactly; a native UUID
    // here could not form a PostgreSQL FK to that legacy-compatible column.
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id, { onDelete: "no action" }),
    userId: text("user_id")
      .notNull()
      .references(() => users.uid, { onDelete: "no action" }),
    generation: bigint("generation", { mode: "number" }).notNull().default(1),
    kind: text("kind").notNull().$type<StudioPreviewKind>(),
    workspacePath: text("workspace_path").notNull(),
    projectDir: text("project_dir"),
    startScript: text("start_script").$type<StudioPreviewScript>(),
    processId: integer("process_id"),
    processGroupId: text("process_group_id"),
    workerEpoch: text("worker_epoch"),
    bindHost: text("bind_host"),
    port: integer("port"),
    status: text("status").notNull().$type<StudioPreviewStatus>(),
    createdAt: timestamptz("created_at").notNull(),
    lastAccessAt: timestamptz("last_access_at"),
    expiresAt: timestamptz("expires_at").notNull(),
    endedAt: timestamptz("ended_at"),
    exitCode: integer("exit_code"),
    failureCode: text("failure_code"),
    logBytes: bigint("log_bytes", { mode: "number" }),
  },
  (t) => [
    uniqueIndex("studio_previews_id_generation_uq").on(t.id, t.generation),
    index("studio_previews_user_status_idx").on(t.userId, t.status, t.kind),
    index("studio_previews_session_status_idx").on(t.sessionId, t.status),
    index("studio_previews_expiry_sweep_idx")
      .on(t.expiresAt, t.id)
      .where(sql`${t.status} IN ('starting','running','stopping')`),
    check("studio_previews_kind_check", sql`${t.kind} IN ('static','dev_server')`),
    check("studio_previews_script_check", sql`${t.startScript} IS NULL OR ${t.startScript} IN ('dev','start','preview')`),
    check("studio_previews_status_check", sql`${t.status} IN ('starting','running','stopping','stopped','failed','expired')`),
    check("studio_previews_generation_check", sql`${t.generation} >= 1`),
    check("studio_previews_port_check", sql`${t.port} IS NULL OR ${t.port} BETWEEN 20000 AND 29999`),
    check("studio_previews_log_bytes_check", sql`${t.logBytes} IS NULL OR ${t.logBytes} >= 0`),
    check("studio_previews_launch_definition_check", sql`(${t.kind} = 'dev_server' AND ${t.projectDir} IS NOT NULL AND ${t.startScript} IS NOT NULL) OR (${t.kind} = 'static' AND ${t.projectDir} IS NULL AND ${t.startScript} IS NULL)`),
  ],
);

export type StudioPreviewRow = typeof studioPreviews.$inferSelect;
