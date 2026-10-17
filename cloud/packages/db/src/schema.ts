import {
  bigint,
  boolean,
  char,
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
import type { UiManifest, WorkspaceState } from "@ovid/shared";

// All timestamptz columns use precision 3 (milliseconds): JS Dates are ms-precision,
// so stored values round-trip losslessly — which the keyset cursor in sessions.list
// relies on (no sub-ms truncation drift between DB value and cursor).
const timestamptz = (name: string) =>
  timestamp(name, { withTimezone: true, precision: 3 });

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
  createdAt: timestamptz("created_at").notNull().defaultNow(),
});

export const sessions = pgTable(
  "sessions",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7
    userId: text("user_id")
      .notNull()
      .references(() => users.uid),
    title: text("title"),
    mode: text("mode").notNull().default("auto"),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
    updatedAt: timestamptz("updated_at").notNull().defaultNow(),
    archivedAt: timestamptz("archived_at"),
  },
  (t) => [index("sessions_user_id_idx").on(t.userId)],
);

export const messages = pgTable(
  "messages",
  {
    id: char("id", { length: 36 }).primaryKey(), // UUIDv7 (keyset cursor)
    sessionId: char("session_id", { length: 36 })
      .notNull()
      .references(() => sessions.id),
    role: text("role").notNull(), // "user" | "assistant" | "system" | "tool"
    content: text("content").notNull(),
    // P8 Task 4: caller-chosen idempotency key for the send-message and
    // history-import paths. NULL for all pre-P8 rows — the unique index below
    // is partial (WHERE client_msg_id IS NOT NULL), so keyed and keyless
    // messages never collide.
    clientMsgId: text("client_msg_id"),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [
    index("messages_session_id_id_idx").on(t.sessionId, t.id),
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
    name: text("name").notNull(),
    size: integer("size").notNull(),
    r2Key: text("r2_key").notNull(),
    createdAt: timestamptz("created_at").notNull().defaultNow(),
  },
  (t) => [index("attachments_session_id_idx").on(t.sessionId)],
);

export type UserRow = typeof users.$inferSelect;
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
// exact decimal strings ("5", "23"); aliases include the tier the hook stores
// (e.g. pro → ["7x"]).
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
export const accountDeletions = pgTable("account_deletions", {
  uid: text("uid").primaryKey(),
  state: text("state").notNull(),
  deleteAfter: bigint("delete_after", { mode: "number" }).notNull(),
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
  ],
);

export type FileManifestRow = typeof fileManifests.$inferSelect;
export type WorkspaceObjectRow = typeof workspaceObjects.$inferSelect;
