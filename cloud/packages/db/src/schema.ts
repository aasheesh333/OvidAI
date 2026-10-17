import {
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

// All timestamptz columns use precision 3 (milliseconds): JS Dates are ms-precision,
// so stored values round-trip losslessly — which the keyset cursor in sessions.list
// relies on (no sub-ms truncation drift between DB value and cursor).
const timestamptz = (name: string) =>
  timestamp(name, { withTimezone: true, precision: 3 });

export const users = pgTable("users", {
  uid: text("uid").primaryKey(),
  email: text("email"),
  tier: text("tier").notNull().default("free"),
  // Per-user sandbox uid from the users_sandbox_uid_seq pool (production block
  // 200000–209999, spec §11). Unique across users; NULL until first allocated.
  sandboxUid: integer("sandbox_uid").unique(),
  bannedAt: timestamptz("banned_at"),
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
