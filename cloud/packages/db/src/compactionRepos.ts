import { createHash } from "node:crypto";
import { and, asc, eq, gt, inArray, isNull, or, sql, type SQL } from "drizzle-orm";
import type { Db } from "./client.js";
import { lockCompactionSession, newId } from "./repos.js";
import {
  compactionCheckpoints,
  compactionCursors,
  compactionHistoryItems,
  runs,
  sessionAgentState,
  sessions,
  subagentAttempts,
  subagentDispatches,
  subagentLogicalWorkers,
  systemRequestResponses,
  systemRequests,
  workspaceObjects,
  type CompactionCheckpointRow,
} from "./schema.js";

export interface ModelContextProfile {
  model: string;
  contextLimit: number;
  outputReserveTokens: number;
  providerReserveTokens: number;
}

export interface ContextUsage {
  usageSource: "measured" | "deterministic_fallback";
  beforeTokens: number;
}

export interface CompactionActor {
  sessionId: string;
  rootTaskRunId: string;
  logicalWorkerId: string | null;
  attemptId: string | null;
  kind: "main" | "worker";
}

export interface CompactionToolCall {
  id: string;
  name: string;
  args: Record<string, unknown>;
}

export interface CompactionMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string;
  id?: string;
  images?: readonly { mimeType: string; dataBase64: string }[];
  ephemeral?: boolean;
  toolCallId?: string;
  toolCalls?: CompactionToolCall[];
  volatile?: boolean;
  cacheControl?: { type: "ephemeral"; ttl?: "5m" | "1h" };
}

export interface CompactionInput {
  sessionId: string;
  messages: CompactionMessage[];
  windowTokens: number;
  foldBoundary?: number;
}

export interface CompactionOutcome {
  compacted: boolean;
  messages: CompactionMessage[];
  foldBoundary: number;
  compactionId?: string;
  checkpointId?: string;
  cutoffCursor?: string;
  contextLimit?: number;
  beforeTokens?: number;
  afterTokens?: number;
  usageSource?: ContextUsage["usageSource"];
  continuation?: "continuing_existing_task";
}

export type FoldCheckpointInput = Omit<CompactionInput, "windowTokens" | "sessionId"> & {
  profile: ModelContextProfile;
  usage: ContextUsage;
  actor: CompactionActor;
};

export type HistoryItemKind =
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

export interface ExactHistoryItem {
  stableId: string;
  kind: HistoryItemKind;
  sessionId: string;
  rootTaskRunId: string;
  logicalWorkerId: string | null;
  attemptId: string | null;
  eventCursor: string;
  inlinePayload?: unknown;
  objectRef?: string;
  byteLength: number;
}

export interface StoredExactHistoryItem extends Omit<ExactHistoryItem, "rootTaskRunId"> {
  rootTaskRunId: string | null;
}

export interface HistoryReference {
  kind: HistoryItemKind;
  id: string;
}

export interface ExactHistoryEntry {
  item: StoredExactHistoryItem;
  /** Inline data, or the current exact row behind a canonical postgres: reference. */
  data: unknown;
  position: string;
  createdAt: Date | null;
}

export interface ExactHistoryPage {
  items: ExactHistoryEntry[];
  nextCursor: string | null;
}

/** Runtime-owned exact object reader. Values must come from an authorized
 * canonical or sealed object store; the DB never stores their plaintext. */
export interface CompactionExactObjectReader {
  openReference(reference: string): Promise<unknown>;
}

export class CompactionContractError extends Error {
  readonly name = "CompactionContractError";
  constructor(readonly code: string, message: string) {
    super(message);
  }
}

type Tx = Parameters<Parameters<Db["transaction"]>[0]>[0];
type SqlExecutor = { execute(query: SQL): Promise<unknown> };
type InternalHistoryItem = ExactHistoryItem & {
  occurredAt?: Date;
  /** Compared against a sealed object, never persisted by this repository. */
  expected?: unknown;
};
type ActorContext = {
  parentSessionId: string;
  childSessionId: string;
  childRunId: string | null;
  canonicalActor: CompactionActor;
};

const HISTORY_KINDS = new Set<HistoryItemKind>([
  "message", "tool_call", "approval", "artifact", "file", "logical_worker",
  "attempt", "checkpoint", "compaction", "event", "control",
]);
const COMPACTED_OPEN = "<compacted-summary>";
const COMPACTED_CLOSE = "</compacted-summary>";
const CHECKPOINT_PREAMBLE =
  "This is an automatically generated checkpoint condensing an earlier " +
  "span of the conversation to free up context. Treat the captured " +
  "context as established background and build on it without restating " +
  "it. Continue the task directly from the messages that follow, without " +
  "acknowledging this checkpoint.";

function compactedSystemBlock(summary: string): string {
  return `${CHECKPOINT_PREAMBLE}\n\n${COMPACTED_OPEN}\n${summary}\n${COMPACTED_CLOSE}`;
}

function isCheckpointRow(message: CompactionMessage | undefined): boolean {
  return message?.role === "system" &&
    message.content.includes("automatically generated checkpoint") &&
    message.content.includes(COMPACTED_OPEN) || false;
}

function stableStringify(value: unknown): string {
  const seen = new Set<object>();
  const visit = (current: unknown, inArray = false): string | undefined => {
    if (current === undefined || typeof current === "function" || typeof current === "symbol") {
      return inArray ? "null" : undefined;
    }
    if (current === null || typeof current === "string" || typeof current === "boolean") {
      return JSON.stringify(current);
    }
    if (typeof current === "number") {
      if (!Number.isFinite(current)) throw new CompactionContractError("invalid_json", "History must be finite JSON.");
      return JSON.stringify(current);
    }
    if (typeof current === "bigint") {
      throw new CompactionContractError("invalid_json", "History must not contain bigint values.");
    }
    if (current instanceof Date) return JSON.stringify(current.toISOString());
    if (typeof current !== "object") return JSON.stringify(String(current));
    if (seen.has(current)) throw new CompactionContractError("invalid_json", "History must not be cyclic.");
    seen.add(current);
    try {
      if (Array.isArray(current)) {
        return `[${current.map((entry) => visit(entry, true) ?? "null").join(",")}]`;
      }
      const parts: string[] = [];
      for (const key of Object.keys(current as Record<string, unknown>).sort()) {
        const encoded = visit((current as Record<string, unknown>)[key]);
        if (encoded !== undefined) parts.push(`${JSON.stringify(key)}:${encoded}`);
      }
      return `{${parts.join(",")}}`;
    } finally {
      seen.delete(current);
    }
  };
  return visit(value) ?? "null";
}

function digest(value: unknown): string {
  return createHash("sha256").update(stableStringify(value)).digest("hex");
}

function byteLength(value: unknown): number {
  return Buffer.byteLength(stableStringify(value), "utf8");
}

function safeInteger(value: number, allowZero = true): boolean {
  return Number.isSafeInteger(value) && (allowZero ? value >= 0 : value > 0);
}

function validateFoldInput(input: FoldCheckpointInput): void {
  if (!input.profile.model.trim() || !safeInteger(input.profile.contextLimit, false) ||
      !safeInteger(input.profile.outputReserveTokens) || !safeInteger(input.profile.providerReserveTokens) ||
      !safeInteger(input.usage.beforeTokens)) {
    throw new CompactionContractError("invalid_context", "Model context and usage must be non-negative safe integers.");
  }
  if (!input.actor.sessionId || !input.actor.rootTaskRunId) {
    throw new CompactionContractError("invalid_actor", "Compaction lineage is required.");
  }
  if (input.actor.kind === "main") {
    if (input.actor.logicalWorkerId !== null || input.actor.attemptId !== null) {
      throw new CompactionContractError("invalid_actor", "Main compaction cannot use worker lineage.");
    }
  } else if (!input.actor.logicalWorkerId || !input.actor.attemptId) {
    throw new CompactionContractError("invalid_actor", "Worker compaction requires worker and attempt lineage.");
  }
  if (!Array.isArray(input.messages)) {
    throw new CompactionContractError("invalid_messages", "Compaction messages must be an array.");
  }
}

function actorId(actor: CompactionActor): string {
  return actor.kind === "main" ? "main" : actor.logicalWorkerId!;
}

function itemScope(actor: CompactionActor): SQL[] {
  return actor.kind === "main"
    ? [isNull(compactionHistoryItems.logicalWorkerId), isNull(compactionHistoryItems.attemptId)]
    : [eq(compactionHistoryItems.logicalWorkerId, actor.logicalWorkerId!)];
}

async function validateActor(
  tx: Tx,
  actor: CompactionActor,
  mode: "read" | "append" | "write" = "write",
): Promise<ActorContext> {
  if (actor.kind === "main") {
    const found = await rows(tx, sql`SELECT r.id, r.status FROM runs r
      WHERE r.id = ${actor.rootTaskRunId} AND r.session_id = ${actor.sessionId}
        AND NOT EXISTS (SELECT 1 FROM subagent_attempts a WHERE a.child_run_id = r.id)
      LIMIT 1`);
    const root = found[0];
    if (!root) throw new CompactionContractError("actor_mismatch", "Main root lineage does not match a canonical main run.");
    if (mode === "write" && root.status !== "running") {
      throw new CompactionContractError("stale_root", "A completed main root cannot advance compaction.");
    }
    return {
      parentSessionId: actor.sessionId,
      childSessionId: actor.sessionId,
      childRunId: null,
      canonicalActor: actor,
    };
  }
  const found = await rows(tx, sql`SELECT
      a.id AS attempt_id, a.session_id AS parent_session_id,
      a.child_session_id, a.child_run_id, a.root_task_run_id,
      a.logical_worker_id, a.status, a.attempt_number, a.execution_epoch,
      w.current_root_task_run_id, w.child_session_id AS worker_child_session_id,
      root.session_id AS root_session_id, child.session_id AS child_run_session_id
    FROM subagent_attempts a
    INNER JOIN subagent_logical_workers w ON w.id = a.logical_worker_id
    INNER JOIN runs root ON root.id = a.root_task_run_id
    INNER JOIN runs child ON child.id = a.child_run_id
    WHERE a.id = ${actor.attemptId!}
      AND a.logical_worker_id = ${actor.logicalWorkerId!}
      AND a.root_task_run_id = ${actor.rootTaskRunId}
      AND root.session_id = a.session_id
      AND child.session_id = a.child_session_id
      AND w.child_session_id = a.child_session_id
      -- Writes require the worker's current root. Historical reads instead
      -- authorize the exact attempt root, which may predate the current root.
      AND (${mode === "read"} OR w.current_root_task_run_id = a.root_task_run_id)
      AND NOT EXISTS (SELECT 1 FROM subagent_attempts other WHERE other.child_run_id = root.id)
    LIMIT 1`);
  const attempt = found[0];
  if (!attempt || ![attempt.parent_session_id, attempt.child_session_id].includes(actor.sessionId)) {
    throw new CompactionContractError("actor_mismatch", "Worker root/run/attempt lineage is not canonical.");
  }
  // Staleness is checked only after the shared session gate in the writer;
  // checking it here would let a truncation-first race return the wrong error.
  return {
    parentSessionId: String(attempt.parent_session_id),
    childSessionId: String(attempt.child_session_id),
    childRunId: String(attempt.child_run_id),
    canonicalActor: { ...actor, sessionId: String(attempt.child_session_id) },
  };
}

/** New writes may use only the latest running attempt. Identical historical
 * reads/replays remain scoped to their original attempt, never moved forward. */
async function assertCurrentAttempt(tx: Tx, actor: CompactionActor): Promise<void> {
  if (actor.kind === "main") {
    const current = await rows(tx, sql`SELECT id FROM runs
      WHERE id = ${actor.rootTaskRunId} AND session_id = ${actor.sessionId} AND status = 'running'
      LIMIT 1 FOR UPDATE`);
    if (current.length === 0) throw new CompactionContractError("stale_root", "The main root is no longer running.");
    return;
  }
  await tx.select({ id: subagentLogicalWorkers.id }).from(subagentLogicalWorkers)
    .where(eq(subagentLogicalWorkers.id, actor.logicalWorkerId!)).for("update").limit(1);
  const current = await rows(tx, sql`SELECT id, status FROM subagent_attempts
    WHERE logical_worker_id = ${actor.logicalWorkerId!}
      AND root_task_run_id = ${actor.rootTaskRunId}
    ORDER BY execution_epoch DESC, attempt_number DESC, created_at DESC, id DESC
    LIMIT 1 FOR UPDATE`);
  if (current[0]?.id !== actor.attemptId || current[0]?.status !== "running") {
    throw new CompactionContractError("stale_attempt", "Only the latest running worker attempt may append or fold.");
  }
}

async function validateReadScope(
  tx: Tx,
  input: {
    sessionId: string;
    rootTaskRunId?: string;
    logicalWorkerId?: string | null;
    attemptId?: string | null;
  },
): Promise<{ sessionId: string; rootTaskRunId?: string; historySessionIds: string[] }> {
  const session = await tx.select({ id: sessions.id }).from(sessions)
    .where(eq(sessions.id, input.sessionId)).limit(1);
  if (session.length === 0) throw new CompactionContractError("history_scope_not_found", "History scope is unavailable.");
  if (input.rootTaskRunId === undefined) {
    if (input.logicalWorkerId || input.attemptId) {
      throw new CompactionContractError("invalid_history_scope", "Worker and attempt recall require an explicit root run.");
    }
    return { sessionId: input.sessionId, historySessionIds: [input.sessionId] };
  }
  if (input.logicalWorkerId !== undefined || input.attemptId !== undefined) {
    if (input.logicalWorkerId === null && (input.attemptId === null || input.attemptId === undefined)) {
      const actor: CompactionActor = {
        sessionId: input.sessionId,
        rootTaskRunId: input.rootTaskRunId,
        logicalWorkerId: null,
        attemptId: null,
        kind: "main",
      };
      await validateActor(tx, actor, "read");
      return { sessionId: input.sessionId, rootTaskRunId: input.rootTaskRunId, historySessionIds: [input.sessionId] };
    }
    if (!input.logicalWorkerId) {
      throw new CompactionContractError("invalid_history_scope", "Attempt recall requires its logical worker.");
    }
    let attemptId = input.attemptId;
    if (!attemptId) {
      const latest = await rows(tx, sql`SELECT id FROM subagent_attempts
        WHERE logical_worker_id = ${input.logicalWorkerId} AND root_task_run_id = ${input.rootTaskRunId}
        ORDER BY execution_epoch DESC, attempt_number DESC, created_at DESC, id DESC LIMIT 1`);
      if (!latest[0]?.id) throw new CompactionContractError("actor_mismatch", "No canonical worker attempt exists for this root.");
      attemptId = String(latest[0].id);
    }
    const actor: CompactionActor = {
      sessionId: input.sessionId,
      rootTaskRunId: input.rootTaskRunId,
      logicalWorkerId: input.logicalWorkerId,
      attemptId,
      kind: "worker",
    };
    const context = await validateActor(tx, actor, "read");
    return {
      sessionId: input.sessionId,
      rootTaskRunId: input.rootTaskRunId,
      // 0039 legacy worker/attempt rows live in the parent; fresh worker
      // history lives in the child. Both are admitted only after the exact
      // alias/root/attempt validation above, never by session-name guessing.
      historySessionIds: [context.parentSessionId, context.childSessionId],
    };
  }
  const root = await rows(tx, sql`SELECT r.id FROM runs r
    WHERE r.id = ${input.rootTaskRunId}
      AND (r.session_id = ${input.sessionId} OR EXISTS (
        SELECT 1 FROM subagent_attempts a
        WHERE a.root_task_run_id = r.id AND a.child_session_id = ${input.sessionId}
      ))
    LIMIT 1`);
  if (root.length === 0) throw new CompactionContractError("actor_mismatch", "Root run does not belong to the requested history scope.");
  return { sessionId: input.sessionId, rootTaskRunId: input.rootTaskRunId, historySessionIds: [input.sessionId] };
}

const SECRET_KEY = /(?:^|_)(?:api_?key|secret|password|passwd|token|authorization|cookie|credential|private_?key|client_?secret|access_?token|refresh_?token)(?:$|_)/i;
const SECRET_VALUE = [
  /-----BEGIN [^-]*PRIVATE KEY-----/i,
  /\bBearer\s+[A-Za-z0-9._~+\/-]+=* /i,
  /\bBearer\s+[A-Za-z0-9._~+\/-]+=*/i,
  /\b(?:sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{8,}|xox[baprs]-[A-Za-z0-9-]{8,})\b/,
  /(?:password|passwd|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|authorization|cookie)\s*[:=]\s*[^\s,;}]+/i,
  /[?&](?:token|api[_-]?key|key|signature|credential|auth|secret|code)=[^&#\s]+/i,
];
const NON_SECRET_KEYS = new Set([
  "secretkind", "secret_kind", "sensitive", "tokencount", "token_count",
  "inputtokens", "outputtokens", "beforetokens", "aftertokens", "cache_read_tokens",
  "cache_write_tokens", "cacheReadTokens", "cacheWriteTokens", "maxTokens", "max_tokens",
]);

function normalizedKey(key: string): string {
  return key.replace(/([a-z0-9])([A-Z])/g, "$1_$2").replace(/[^a-zA-Z0-9]+/g, "_").toLowerCase();
}

function containsSecret(value: unknown, key?: string): boolean {
  if (key && !NON_SECRET_KEYS.has(key) && SECRET_KEY.test(normalizedKey(key))) {
    if (value !== null && value !== undefined) return true;
  }
  if (typeof value === "string") {
    if (SECRET_VALUE.some((pattern) => pattern.test(value))) return true;
    if (/^https?:\/\//i.test(value)) {
      try {
        const url = new URL(value);
        if (url.username || url.password) return true;
      } catch {
        return true;
      }
    }
    return false;
  }
  if (Array.isArray(value)) return value.some((entry) => containsSecret(entry));
  if (value !== null && typeof value === "object") {
    return Object.entries(value as Record<string, unknown>)
      .some(([childKey, entry]) => containsSecret(entry, childKey));
  }
  return false;
}

function assertNoPlaintextSecret(value: unknown): void {
  stableStringify(value);
  if (containsSecret(value)) {
    throw new CompactionContractError(
      "plaintext_secret",
      "Secret-bearing exact data must remain in its canonical or sealed object store; use an object reference.",
    );
  }
}

function redacted(value: unknown): unknown {
  if (typeof value === "string") return containsSecret(value) ? "[redacted: exact recall required]" : value;
  if (Array.isArray(value)) return value.map(redacted);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(Object.entries(value as Record<string, unknown>).map(([key, entry]) => [
      key,
      !NON_SECRET_KEYS.has(key) && SECRET_KEY.test(normalizedKey(key)) ? "[redacted]" : redacted(entry),
    ]));
  }
  return value;
}

async function rows(executor: SqlExecutor, query: SQL): Promise<Array<Record<string, unknown>>> {
  return await executor.execute(query) as unknown as Array<Record<string, unknown>>;
}

function jsonData(value: unknown): unknown {
  if (typeof value !== "string") return value;
  try {
    return JSON.parse(value);
  } catch {
    return value;
  }
}

function decoded(row: Record<string, unknown>, fields: readonly string[]): Record<string, unknown> {
  return Object.fromEntries(Object.entries(row).map(([key, value]) => [
    key,
    fields.includes(key) ? jsonData(value) : value,
  ]));
}

function numeric(row: Record<string, unknown>, fields: readonly string[]): Record<string, unknown> {
  return Object.fromEntries(Object.entries(row).map(([key, value]) => [
    key,
    fields.includes(key) && typeof value === "string" && /^\d+$/.test(value) ? Number(value) : value,
  ]));
}

async function referenceSessions(
  executor: SqlExecutor,
  item: StoredExactHistoryItem,
): Promise<{ parent: string; child: string; childRunId: string | null } | null> {
  if (item.logicalWorkerId === null) {
    return { parent: item.sessionId, child: item.sessionId, childRunId: null };
  }
  const found = await rows(executor, sql`SELECT
      w.session_id AS parent_session_id, w.child_session_id,
      w.current_root_task_run_id,
      a.root_task_run_id AS attempt_root_id, a.child_run_id AS attempt_child_run_id
    FROM subagent_logical_workers w
    LEFT JOIN subagent_attempts a ON a.id = ${item.attemptId}
      AND a.logical_worker_id = w.id AND a.child_session_id = w.child_session_id
    WHERE w.id = ${item.logicalWorkerId}
      -- Fresh worker history is child-stored; legacy 0039 worker/attempt/
      -- checkpoint/control rows are parent-stored. Both require this exact
      -- worker relationship and the root/attempt predicate below.
      AND (w.child_session_id = ${item.sessionId} OR w.session_id = ${item.sessionId})
      AND (${item.attemptId}::text IS NULL OR a.id IS NOT NULL)
      AND (
        ${item.rootTaskRunId}::text IS NULL OR
        (${item.attemptId}::text IS NOT NULL AND a.root_task_run_id::text = ${item.rootTaskRunId}) OR
        (${item.attemptId}::text IS NULL AND EXISTS (
          SELECT 1 FROM subagent_attempts lineage_attempt
          WHERE lineage_attempt.logical_worker_id = w.id
            AND lineage_attempt.root_task_run_id::text = ${item.rootTaskRunId}
        ))
      )
    LIMIT 1`);
  const row = found[0];
  if (!row) return null;
  return {
    parent: String(row.parent_session_id),
    child: String(row.child_session_id),
    childRunId: row.attempt_child_run_id === null || row.attempt_child_run_id === undefined
      ? null : String(row.attempt_child_run_id),
  };
}

function canonicalRunMatches(
  item: Pick<StoredExactHistoryItem, "rootTaskRunId" | "logicalWorkerId">,
  lineage: { childRunId: string | null },
  runId: unknown,
): boolean {
  if (runId === null || runId === undefined || item.rootTaskRunId === null) return true;
  return runId === item.rootTaskRunId ||
    (item.logicalWorkerId !== null && runId === lineage.childRunId);
}

async function resolveCanonical(
  executor: SqlExecutor,
  item: StoredExactHistoryItem,
  objects?: CompactionExactObjectReader,
): Promise<unknown> {
  const ref = item.objectRef;
  if (!ref) return item.inlinePayload;
  if (ref.startsWith("sealed:")) {
    if (!objects) {
      throw new CompactionContractError("history_reference_unavailable", "A sealed-object reader is required for exact recall.");
    }
    const exact = await objects.openReference(ref);
    if (exact === null || exact === undefined) {
      throw new CompactionContractError("history_reference_unavailable", "The sealed exact object is unavailable.");
    }
    return exact;
  }
  if (!ref.startsWith("postgres:")) {
    throw new CompactionContractError("history_reference_unavailable", "The exact object reference cannot be resolved safely.");
  }
  const lineage = await referenceSessions(executor, item);
  if (!lineage) return null;
  const body = ref.slice("postgres:".length);
  const slash = body.indexOf("/");
  const table = slash < 0 ? body : body.slice(0, slash);
  const id = slash < 0 ? "" : body.slice(slash + 1);
  let result: Array<Record<string, unknown>>;
  switch (table) {
    case "messages":
      result = await rows(executor, sql`SELECT id, session_id, role, content, reasoning, client_msg_id, created_at
        FROM messages WHERE id = ${id} AND session_id = ${lineage.child} LIMIT 1`);
      return result[0] ?? null;
    case "session_event_mirror": {
      const separator = id.indexOf("/");
      const sessionId = separator < 0 ? "" : id.slice(0, separator);
      const seq = separator < 0 ? "" : id.slice(separator + 1);
      result = await rows(executor, sql`SELECT session_id, seq, type, payload, ts FROM session_event_mirror
        WHERE session_id = ${sessionId} AND seq = ${seq} AND session_id = ${lineage.parent} LIMIT 1`);
      if (!result[0] || !canonicalRunMatches(item, lineage, (result[0].payload as Record<string, unknown> | null)?.runId)) return null;
      return decoded(result[0], ["payload"]);
    }
    case "system_requests":
      result = await rows(executor, sql`SELECT q.*, r.request_version AS response_version,
          r.response, r.response_digest, r.client_response_id, r.created_at AS response_created_at
        FROM system_requests q LEFT JOIN system_request_responses r
          ON r.request_id = q.request_id AND r.request_version = q.version
        WHERE q.request_id = ${id} AND q.session_id = ${lineage.parent} LIMIT 1`);
      if (!result[0] || !canonicalRunMatches(item, lineage, result[0].run_id)) return null;
      return decoded(result[0], ["safe_payload", "response"]);
    case "system_request_responses":
      result = await rows(executor, sql`SELECT r.*, q.run_id, q.version AS current_request_version
        FROM system_request_responses r
        INNER JOIN system_requests q ON q.request_id = r.request_id
        WHERE r.response_id = ${id} AND q.session_id = ${lineage.parent} LIMIT 1`);
      if (!result[0] || !canonicalRunMatches(item, lineage, result[0].run_id)) return null;
      return decoded(result[0], ["response"]);
    case "workspace_objects":
      result = await rows(executor, sql`SELECT * FROM workspace_objects
        WHERE id = ${id} AND session_id = ${lineage.child} LIMIT 1`);
      return result[0] ? numeric(decoded(result[0], ["meta"]), ["bytes"]) : null;
    case "attachments":
      result = await rows(executor, sql`SELECT * FROM attachments
        WHERE id = ${id} AND session_id = ${lineage.child} LIMIT 1`);
      return result[0] ? numeric(result[0], ["actual_bytes"]) : null;
    case "subagent_logical_workers":
      result = await rows(executor, sql`SELECT * FROM subagent_logical_workers
        WHERE id = ${id} AND session_id = ${lineage.parent} LIMIT 1`);
      return result[0] ?? null;
    case "subagent_attempts":
      result = await rows(executor, sql`SELECT * FROM subagent_attempts
        WHERE id = ${id} AND session_id = ${lineage.parent} LIMIT 1`);
      if (!result[0] || (item.rootTaskRunId !== null && result[0].root_task_run_id !== item.rootTaskRunId)) return null;
      return result[0];
    case "subagent_checkpoints":
      result = await rows(executor, sql`SELECT * FROM subagent_checkpoints
        WHERE id = ${id} AND session_id = ${lineage.parent} LIMIT 1`);
      return result[0] ? decoded(result[0], ["provenance"]) : null;
    case "subagent_control_audit":
      result = await rows(executor, sql`SELECT * FROM subagent_control_audit
        WHERE id = ${id} AND session_id = ${lineage.parent} LIMIT 1`);
      return result[0] ? decoded(result[0], ["metadata"]) : null;
    case "subagent_dispatches":
      result = await rows(executor, sql`SELECT * FROM subagent_dispatches
        WHERE id = ${id} AND session_id = ${lineage.parent} LIMIT 1`);
      return result[0] ? numeric(decoded(result[0], ["tools", "disallowed_tools"]), ["requested_sequence"]) : null;
    case "session_agent_state": {
      const field = id.endsWith("#goal") ? "goal" : id.endsWith("#todos") ? "todos" :
        id.endsWith("#activeSkillScopes") ? "activeSkillScopes" :
          id.endsWith("#compaction") ? "compaction" : null;
      const sessionId = field === null ? "" : id.slice(0, -(field.length + 1));
      if (field === null) return null;
      result = await rows(executor, sql`SELECT state->${field} AS value FROM session_agent_state
        WHERE session_id = ${sessionId} AND session_id = ${lineage.child} LIMIT 1`);
      return result[0] ? jsonData(result[0].value) : null;
    }
    case "compaction_checkpoints":
      result = await rows(executor, sql`SELECT * FROM compaction_checkpoints
        WHERE checkpoint_id = ${id} AND session_id = ${lineage.child} LIMIT 1`);
      return result[0] ? numeric(decoded(result[0], ["ledger", "active_state"]), [
        "context_limit", "output_reserve_tokens", "provider_reserve_tokens", "before_tokens", "after_tokens",
      ]) : null;
    default:
      return null;
  }
}

function validateHistoryItem(item: ExactHistoryItem): void {
  if (!HISTORY_KINDS.has(item.kind) || !item.stableId || !item.sessionId ||
      !item.rootTaskRunId || !item.eventCursor || !safeInteger(item.byteLength)) {
    throw new CompactionContractError("invalid_history_item", "Exact history identity, lineage and byte length are required.");
  }
  if (item.inlinePayload !== undefined) {
    throw new CompactionContractError(
      "unsafe_inline_payload",
      "New exact history is reference-only; persist plaintext only in its canonical store or a sealed object store.",
    );
  }
  if (!item.objectRef || !/^(?:postgres|sealed):/.test(item.objectRef)) {
    throw new CompactionContractError("invalid_history_payload", "A canonical postgres: or sealed: object reference is required.");
  }
  if (item.attemptId !== null && item.logicalWorkerId === null) {
    throw new CompactionContractError("invalid_history_item", "Attempt lineage requires a logical worker.");
  }
  assertNoPlaintextSecret(item.objectRef);
}

async function appendHistoryInternal(
  tx: Tx,
  item: InternalHistoryItem,
  objects?: CompactionExactObjectReader,
  currentActor?: CompactionActor,
): Promise<void> {
  validateHistoryItem(item);
  const existing = await tx.select().from(compactionHistoryItems).where(and(
    eq(compactionHistoryItems.sessionId, item.sessionId),
    eq(compactionHistoryItems.kind, item.kind),
    eq(compactionHistoryItems.stableId, item.stableId),
    eq(compactionHistoryItems.eventCursor, item.eventCursor),
  )).limit(1);
  const prior = existing[0];
  if (currentActor && !prior) await assertCurrentAttempt(tx, currentActor);
  let exact: unknown;
  if (item.objectRef!.startsWith("postgres:")) {
    exact = await resolveCanonical(tx, { ...item, rootTaskRunId: item.rootTaskRunId });
    if (exact === null) {
      throw new CompactionContractError("history_reference_not_found", "Canonical exact-history reference is not readable in this session.");
    }
  } else {
    if (!objects) {
      throw new CompactionContractError("sealed_object_unavailable", "An authorized sealed-object reader is required.");
    }
    exact = await objects.openReference(item.objectRef!);
    if (exact === null || exact === undefined) {
      throw new CompactionContractError("history_reference_unavailable", "The sealed exact object is unavailable.");
    }
  }
  if (item.expected !== undefined && stableStringify(exact) !== stableStringify(item.expected)) {
    throw new CompactionContractError("history_reference_mismatch", "The referenced exact object does not match the folded content.");
  }
  if (item.objectRef!.startsWith("sealed:") && item.expected === undefined && byteLength(exact) !== item.byteLength) {
    throw new CompactionContractError("history_reference_mismatch", "The exact object byte length does not match its reference.");
  }
  if (prior) {
    if (prior.rootTaskRunId !== item.rootTaskRunId ||
        prior.logicalWorkerId !== item.logicalWorkerId ||
        prior.byteLength !== item.byteLength || prior.objectRef !== item.objectRef ||
        prior.inlinePayload !== null) {
      throw new CompactionContractError("history_conflict", "Exact history identity already has different durable content.");
    }
    return;
  }
  await tx.insert(compactionHistoryItems).values({
    sessionId: item.sessionId,
    rootTaskRunId: item.rootTaskRunId,
    logicalWorkerId: item.logicalWorkerId,
    attemptId: item.attemptId,
    kind: item.kind,
    stableId: item.stableId,
    eventCursor: item.eventCursor,
    objectRef: item.objectRef!,
    byteLength: item.byteLength,
    ...(item.occurredAt !== undefined ? { occurredAt: item.occurredAt } : {}),
  });
}

function canonicalReferenceOwnerSession(
  item: ExactHistoryItem,
  context: ActorContext,
): string {
  const ref = item.objectRef;
  if (!ref || ref.startsWith("sealed:")) return context.childSessionId;
  if (ref.startsWith("postgres:session_event_mirror/")) {
    const owner = ref.slice("postgres:session_event_mirror/".length).split("/")[0];
    if (owner !== context.parentSessionId) {
      throw new CompactionContractError("actor_mismatch", "The referenced event belongs to a different parent session.");
    }
    return context.parentSessionId;
  }
  if (/^postgres:(?:system_requests|system_request_responses|subagent_(?:logical_workers|attempts|checkpoints|control_audit|dispatches))\//.test(ref)) {
    return context.parentSessionId;
  }
  return context.childSessionId;
}

/** Parent-owned events/approvals and child history share one serialization
 * point with parent truncation. Always lock parent before child. */
async function lockExactWriterSessions(
  tx: Tx,
  context: ActorContext,
  item?: ExactHistoryItem,
): Promise<void> {
  const owner = item ? canonicalReferenceOwnerSession(item, context) : context.parentSessionId;
  if (owner !== context.childSessionId) {
    await lockCompactionSession(tx, owner, { mode: "shared" });
  }
  await lockCompactionSession(tx, context.childSessionId, { mode: "shared" });
}

export async function appendExactItem(
  db: Db,
  item: ExactHistoryItem,
  objects?: CompactionExactObjectReader,
): Promise<void> {
  await db.transaction(async (tx) => {
    validateHistoryItem(item);
    const actor: CompactionActor = {
      sessionId: item.sessionId,
      rootTaskRunId: item.rootTaskRunId,
      logicalWorkerId: item.logicalWorkerId,
      attemptId: item.attemptId,
      kind: item.logicalWorkerId === null ? "main" : "worker",
    };
    const context = await validateActor(tx, actor, "append");
    await lockExactWriterSessions(tx, context, item);
    await appendHistoryInternal(
      tx,
      { ...item, sessionId: context.childSessionId },
      objects,
      context.canonicalActor,
    );
  });
}

export async function readExactHistory(db: Db, input: {
  sessionId: string;
  rootTaskRunId?: string;
  logicalWorkerId?: string | null;
  attemptId?: string | null;
  reference?: HistoryReference;
  cursor?: string;
  limit?: number;
}, objects?: CompactionExactObjectReader): Promise<ExactHistoryPage> {
  return db.transaction(async (tx) => {
    const scope = await validateReadScope(tx, input);
    const scoped = { ...input, ...scope };
    const limit = Math.min(100, Math.max(1, scoped.limit ?? 50));
    let after = 0;
    if (scoped.cursor !== undefined) {
      if (!/^\d+$/.test(scoped.cursor)) throw new CompactionContractError("invalid_cursor", "History cursor is invalid.");
      after = Number(scoped.cursor);
      if (!safeInteger(after)) throw new CompactionContractError("invalid_cursor", "History cursor is invalid.");
    }
    const predicates = [
      inArray(compactionHistoryItems.sessionId, scoped.historySessionIds),
      gt(compactionHistoryItems.position, after),
    ];
    if (scoped.rootTaskRunId !== undefined) predicates.push(eq(compactionHistoryItems.rootTaskRunId, scoped.rootTaskRunId));
    if (scoped.logicalWorkerId !== undefined) {
      predicates.push(scoped.logicalWorkerId === null
        ? isNull(compactionHistoryItems.logicalWorkerId)
        : eq(compactionHistoryItems.logicalWorkerId, scoped.logicalWorkerId));
    }
    if (scoped.attemptId !== undefined) {
      predicates.push(scoped.attemptId === null
        ? isNull(compactionHistoryItems.attemptId)
        : eq(compactionHistoryItems.attemptId, scoped.attemptId));
    }
    if (scoped.reference !== undefined) {
      predicates.push(eq(compactionHistoryItems.kind, scoped.reference.kind));
      predicates.push(eq(compactionHistoryItems.stableId, scoped.reference.id));
    }
    const found = await tx.select().from(compactionHistoryItems)
      .where(and(...predicates)).orderBy(asc(compactionHistoryItems.position)).limit(limit + 1);
    const page = found.slice(0, limit);
    const items: ExactHistoryEntry[] = [];
    for (const row of page) {
      const item: StoredExactHistoryItem = {
        stableId: row.stableId,
        kind: row.kind,
        sessionId: row.sessionId,
        rootTaskRunId: row.rootTaskRunId,
        logicalWorkerId: row.logicalWorkerId,
        attemptId: row.attemptId,
        eventCursor: row.eventCursor,
        ...(row.inlinePayload !== null ? { inlinePayload: row.inlinePayload } : { objectRef: row.objectRef! }),
        byteLength: row.byteLength,
      };
      const data = row.inlinePayload !== null ? row.inlinePayload : await resolveCanonical(tx, item, objects);
      if (data === null || data === undefined) {
        throw new CompactionContractError(
          "history_reference_unavailable",
          "Exact history reference is stale or its canonical object is unavailable; no exact data can be returned.",
        );
      }
      items.push({ item, data, position: String(row.position), createdAt: row.occurredAt });
    }
    const last = items[items.length - 1];
    return { items, nextCursor: found.length > limit && last ? last.position : null };
  });
}

function terminalStatus(result: string): "completed" | "error" | "cancelled" {
  if (/^(?:cancelled|canceled)\b/i.test(result.trim())) return "cancelled";
  const exitPattern = /exit(?:ed with)? code (-?\d+)|\[exit (-?\d+)\]/g;
  let exitCode: number | null = null;
  for (let match = exitPattern.exec(result); match !== null; match = exitPattern.exec(result)) {
    exitCode = Number.parseInt(match[1] ?? match[2]!, 10);
  }
  return /^(?:tool error:|error\b|exception\b|denied by user\b)/i.test(result.trim()) ||
    (exitCode !== null && exitCode !== 0) ? "error" : "completed";
}

function validateTerminalTools(messages: readonly CompactionMessage[]): {
  calls: Map<string, CompactionToolCall & { message: CompactionMessage }>;
  results: Map<string, string>;
} {
  const calls = new Map<string, CompactionToolCall & { message: CompactionMessage }>();
  const results = new Map<string, string>();
  for (const message of messages) {
    if (message.ephemeral === true || isCheckpointRow(message)) continue;
    if (message.role === "tool" && message.toolCallId) {
      const prior = results.get(message.toolCallId);
      if (prior !== undefined && prior !== message.content) {
        throw new CompactionContractError("tool_call_conflict", "A tool call has conflicting terminal results.");
      }
      results.set(message.toolCallId, message.content);
    }
    for (const call of message.toolCalls ?? []) {
      if (!call.id || !call.name) throw new CompactionContractError("invalid_tool_call", "Tool call identity is required.");
      const prior = calls.get(call.id);
      if (prior && stableStringify({ name: prior.name, args: prior.args }) !== stableStringify({ name: call.name, args: call.args })) {
        throw new CompactionContractError("tool_call_conflict", "A tool call ID has conflicting arguments.");
      }
      calls.set(call.id, { ...call, message });
    }
  }
  for (const id of calls.keys()) {
    if (!results.has(id)) throw new CompactionContractError("tool_call_not_terminal", `Tool call ${id} has no terminal result.`);
  }
  return { calls, results };
}

async function assertApprovalsTerminal(tx: Tx, actor: CompactionActor, context: ActorContext): Promise<void> {
  const runIds = [actor.rootTaskRunId, ...(context.childRunId ? [context.childRunId] : [])];
  const pending = await tx.select({ requestId: systemRequests.requestId }).from(systemRequests)
    .where(and(
      eq(systemRequests.sessionId, context.parentSessionId),
      or(...runIds.map((id) => eq(systemRequests.runId, id))),
      eq(systemRequests.status, "pending"),
    )).limit(1);
  if (pending.length > 0) throw new CompactionContractError("approval_not_terminal", "A pending approval must be settled before folding.");
  const history = await tx.select({
    stableId: compactionHistoryItems.stableId,
    payload: compactionHistoryItems.inlinePayload,
  }).from(compactionHistoryItems).where(and(
    eq(compactionHistoryItems.sessionId, actor.sessionId),
    eq(compactionHistoryItems.rootTaskRunId, actor.rootTaskRunId),
    eq(compactionHistoryItems.kind, "approval"),
    ...itemScope(actor),
  )).orderBy(asc(compactionHistoryItems.position));
  const status = new Map<string, string>();
  for (const row of history) {
    if (!row.payload || typeof row.payload !== "object") continue;
    const value = row.payload as Record<string, unknown>;
    const next = typeof value.status === "string" ? value.status :
      typeof value.decision === "string" ? "resolved" : undefined;
    if (next) status.set(row.stableId, next);
  }
  if ([...status.values()].some((value) => !["resolved", "expired", "cancelled"].includes(value))) {
    throw new CompactionContractError("approval_not_terminal", "A pending approval must be settled before folding.");
  }
}

function boundaryOf(messages: readonly CompactionMessage[], requested: number | undefined): number {
  const leading = isCheckpointRow(messages[0]) ? 1 : 0;
  const value = requested ?? leading;
  if (!Number.isInteger(value)) throw new CompactionContractError("invalid_boundary", "Fold boundary must be an integer.");
  return Math.min(messages.length, Math.max(leading, value));
}

function estimateMessageTokens(content: string): number {
  return Math.floor(content.length / 4) + 4;
}

function safeAt(messages: readonly CompactionMessage[], cutoff: number): boolean {
  return cutoff <= 0 || cutoff >= messages.length || messages[cutoff]?.role !== "tool";
}

function snapCutoff(messages: readonly CompactionMessage[], from: number, proposed: number): number {
  const minFold = 4;
  if (proposed >= messages.length) return messages.length;
  if (proposed - from < minFold) return proposed;
  const intended = proposed - from;
  const floor = from + Math.min(intended, Math.max(minFold, Math.ceil(intended / 2)));
  for (let cutoff = proposed; cutoff >= floor; cutoff -= 1) {
    if (messages[cutoff]?.role === "user" && safeAt(messages, cutoff)) return cutoff;
  }
  for (let cutoff = proposed; cutoff >= from + minFold; cutoff -= 1) {
    if (safeAt(messages, cutoff)) return cutoff;
  }
  for (let cutoff = proposed + 1; cutoff < messages.length; cutoff += 1) {
    if (safeAt(messages, cutoff)) return cutoff;
  }
  return from;
}

function chooseCutoff(input: FoldCheckpointInput, from: number): number {
  let retain = Math.floor(input.profile.contextLimit * 0.16);
  retain = Math.min(retain, Math.floor(input.usage.beforeTokens * 0.25));
  let tail = 0;
  let cutoff = input.messages.length;
  while (cutoff > from) {
    if (tail >= retain && input.messages.length - cutoff >= 6 && cutoff - from >= 4) break;
    tail += estimateMessageTokens(input.messages[cutoff - 1]?.content ?? "");
    cutoff -= 1;
  }
  return snapCutoff(input.messages, from, cutoff);
}

function messageCanUseCanonicalRef(message: CompactionMessage): boolean {
  return !!message.id && message.images === undefined && message.toolCalls === undefined &&
    message.cacheControl === undefined && message.volatile === undefined;
}

export interface ToolCallHistoryPayload {
  id: string;
  name: string;
  args: Record<string, unknown>;
  status: "completed" | "error" | "cancelled";
  result: string;
  error: string | null;
  idempotencyKey: string;
  assistant: Omit<CompactionMessage, "toolCalls">;
}

export function toolCallHistoryPayload(
  call: CompactionToolCall,
  message: CompactionMessage,
  result: string,
): ToolCallHistoryPayload {
  const status = terminalStatus(result);
  const omitToolCalls = (value: CompactionMessage): Omit<CompactionMessage, "toolCalls"> => {
    const { toolCalls: _omitted, ...rest } = value;
    return rest;
  };
  return {
    id: call.id,
    name: call.name,
    args: call.args,
    status,
    result,
    error: status === "error" ? result : null,
    idempotencyKey: call.id,
    // The payload's assistant copy deliberately omits toolCalls; spreading it
    // back as `undefined` would re-add an omitted key.
    assistant: omitToolCalls(message),
  };
}

/** Stable across attempts of one logical worker; attempt lineage stays on the
 * history row and is never rewritten when a verified resume occurs. */
export function compactionMessageStableId(actor: CompactionActor, message: CompactionMessage): string {
  return message.id ?? `message:${digest({
    sessionId: actor.sessionId,
    rootTaskRunId: actor.rootTaskRunId,
    logicalWorkerId: actor.logicalWorkerId,
    message,
  })}`;
}

async function sealedReferenceFor(
  tx: Tx,
  actor: CompactionActor,
  kind: HistoryItemKind,
  stableId: string,
  expected: unknown,
  objects: CompactionExactObjectReader | undefined,
): Promise<{ objectRef: string; eventCursor: string; byteLength: number }> {
  if (!objects) {
    throw new CompactionContractError("exact_object_required", "Noncanonical content requires an authorized sealed exact object before folding.");
  }
  const candidates = await tx.select({
    eventCursor: compactionHistoryItems.eventCursor,
    objectRef: compactionHistoryItems.objectRef,
    byteLength: compactionHistoryItems.byteLength,
  }).from(compactionHistoryItems).where(and(
    eq(compactionHistoryItems.sessionId, actor.sessionId),
    eq(compactionHistoryItems.rootTaskRunId, actor.rootTaskRunId),
    actor.kind === "main"
      ? isNull(compactionHistoryItems.logicalWorkerId)
      : eq(compactionHistoryItems.logicalWorkerId, actor.logicalWorkerId!),
    eq(compactionHistoryItems.kind, kind),
    eq(compactionHistoryItems.stableId, stableId),
  )).orderBy(asc(compactionHistoryItems.position));
  for (const candidate of candidates) {
    if (!candidate.objectRef?.startsWith("sealed:")) continue;
    const exact = await objects.openReference(candidate.objectRef);
    if (exact !== null && exact !== undefined && stableStringify(exact) === stableStringify(expected)) {
      return {
        objectRef: candidate.objectRef,
        eventCursor: candidate.eventCursor,
        byteLength: candidate.byteLength,
      };
    }
  }
  throw new CompactionContractError(
    "exact_object_required",
    `No sealed exact ${kind} object matches stable ID ${stableId}; append it before folding.`,
  );
}

async function historyForSpan(
  tx: Tx,
  span: readonly CompactionMessage[],
  actor: CompactionActor,
  calls: Map<string, CompactionToolCall & { message: CompactionMessage }>,
  results: Map<string, string>,
  objects?: CompactionExactObjectReader,
): Promise<InternalHistoryItem[]> {
  const output: InternalHistoryItem[] = [];
  for (const message of span) {
    if (message.ephemeral === true || isCheckpointRow(message)) continue;
    const lineage = {
      sessionId: actor.sessionId,
      rootTaskRunId: actor.rootTaskRunId,
      logicalWorkerId: actor.logicalWorkerId,
      attemptId: actor.attemptId,
    } as const;
    if (message.role === "tool" && message.toolCallId && calls.has(message.toolCallId) && !message.id) {
      // The sealed tool_call item contains the complete call and result.
      continue;
    }
    for (const call of message.toolCalls ?? []) {
      const result = results.get(call.id)!;
      const payload = toolCallHistoryPayload(call, message, result);
      const reference = await sealedReferenceFor(tx, actor, "tool_call", call.id, payload, objects);
      output.push({
        ...lineage,
        stableId: call.id,
        kind: "tool_call",
        eventCursor: reference.eventCursor,
        objectRef: reference.objectRef,
        byteLength: reference.byteLength,
        expected: payload,
      });
    }
    if (message.toolCalls && message.toolCalls.length > 0 && !message.id && !message.content) continue;
    if (messageCanUseCanonicalRef(message)) {
      output.push({
        ...lineage,
        stableId: message.id!,
        kind: "message",
        eventCursor: message.id!,
        objectRef: `postgres:messages/${message.id}`,
        byteLength: Buffer.byteLength(message.content, "utf8"),
      });
    } else {
      const stableId = compactionMessageStableId(actor, message);
      const reference = await sealedReferenceFor(tx, actor, "message", stableId, message, objects);
      output.push({
        ...lineage,
        stableId,
        kind: "message",
        eventCursor: reference.eventCursor,
        objectRef: reference.objectRef,
        byteLength: reference.byteLength,
        expected: message,
      });
    }
  }
  return output;
}

async function canonicalHistoryForActor(
  tx: Tx,
  actor: CompactionActor,
  context: ActorContext,
): Promise<InternalHistoryItem[]> {
  const runIds = [actor.rootTaskRunId, ...(context.childRunId ? [context.childRunId] : [])];
  const lineage = {
    sessionId: actor.sessionId,
    rootTaskRunId: actor.rootTaskRunId,
    logicalWorkerId: actor.logicalWorkerId,
    attemptId: actor.attemptId,
  } as const;
  const approvals = await tx.select().from(systemRequests).where(and(
    eq(systemRequests.sessionId, context.parentSessionId),
    or(...runIds.map((id) => eq(systemRequests.runId, id))),
  )).orderBy(asc(systemRequests.createdAt), asc(systemRequests.requestId));
  const responses = await tx.select({
    response: systemRequestResponses,
    runId: systemRequests.runId,
  }).from(systemRequestResponses)
    .innerJoin(systemRequests, eq(systemRequestResponses.requestId, systemRequests.requestId))
    .where(and(
      eq(systemRequests.sessionId, context.parentSessionId),
      or(...runIds.map((id) => eq(systemRequests.runId, id))),
    )).orderBy(asc(systemRequestResponses.createdAt), asc(systemRequestResponses.responseId));
  const artifacts = await tx.select().from(workspaceObjects)
    .where(eq(workspaceObjects.sessionId, actor.sessionId)).orderBy(asc(workspaceObjects.id));
  const output: InternalHistoryItem[] = [];
  for (const approval of approvals) {
    output.push({
      ...lineage,
      stableId: approval.requestId,
      kind: "approval",
      eventCursor: approval.requestId,
      objectRef: `postgres:system_requests/${approval.requestId}`,
      byteLength: byteLength(approval.safePayload),
      occurredAt: approval.createdAt,
    });
  }
  for (const { response, runId } of responses) {
    if (!canonicalRunMatches({ ...lineage }, { childRunId: context.childRunId }, runId)) continue;
    output.push({
      ...lineage,
      stableId: response.responseId,
      kind: "approval",
      eventCursor: response.responseId,
      objectRef: `postgres:system_request_responses/${response.responseId}`,
      byteLength: byteLength(response.response ?? response.responseDigest),
      occurredAt: response.createdAt,
    });
  }
  for (const artifact of artifacts) {
    output.push({
      ...lineage,
      stableId: artifact.id,
      kind: artifact.kind === "artifact" ? "artifact" : "file",
      eventCursor: artifact.id,
      objectRef: `postgres:workspace_objects/${artifact.id}`,
      byteLength: artifact.bytes,
      occurredAt: artifact.createdAt,
    });
  }
  return output;
}

async function buildActiveState(
  tx: Tx,
  actor: CompactionActor,
  context: ActorContext,
  previousCheckpointId: string | null,
  cutoffCursor: string,
  pendingRecallCursor: string | null,
  objects?: CompactionExactObjectReader,
): Promise<Record<string, unknown>> {
  const stateRows = await tx.select({ state: sessionAgentState.state }).from(sessionAgentState)
    .where(eq(sessionAgentState.sessionId, actor.sessionId)).limit(1);
  const state = stateRows[0]?.state ?? {};
  const deferred = await tx.select({
    id: subagentDispatches.id,
    state: subagentDispatches.state,
    rootTaskRunId: subagentDispatches.rootTaskRunId,
    admittedRootTaskRunId: subagentDispatches.admittedRootTaskRunId,
    parentRunId: subagentDispatches.parentRunId,
    provenance: subagentDispatches.provenance,
    requestIndex: subagentDispatches.requestIndex,
  }).from(subagentDispatches).where(and(
    eq(subagentDispatches.sessionId, context.parentSessionId),
    or(
      eq(subagentDispatches.rootTaskRunId, actor.rootTaskRunId),
      eq(subagentDispatches.admittedRootTaskRunId, actor.rootTaskRunId),
    ),
  )).orderBy(asc(subagentDispatches.id));
  const workers = await tx.select({
    id: subagentLogicalWorkers.id,
    status: subagentLogicalWorkers.status,
    currentRootTaskRunId: subagentLogicalWorkers.currentRootTaskRunId,
    childSessionId: subagentLogicalWorkers.childSessionId,
  }).from(subagentLogicalWorkers).where(and(
    eq(subagentLogicalWorkers.sessionId, context.parentSessionId),
    eq(subagentLogicalWorkers.currentRootTaskRunId, actor.rootTaskRunId),
  )).orderBy(asc(subagentLogicalWorkers.id));
  const errors = await tx.select({
    stableId: compactionHistoryItems.stableId,
    eventCursor: compactionHistoryItems.eventCursor,
    payload: compactionHistoryItems.inlinePayload,
    objectRef: compactionHistoryItems.objectRef,
  }).from(compactionHistoryItems).where(and(
    eq(compactionHistoryItems.sessionId, actor.sessionId),
    eq(compactionHistoryItems.rootTaskRunId, actor.rootTaskRunId),
    eq(compactionHistoryItems.kind, "tool_call"),
    ...itemScope(actor),
  )).orderBy(asc(compactionHistoryItems.position));
  const latestToolStatus = new Map<string, unknown>();
  for (const row of errors) {
    let payload = row.payload as Record<string, unknown> | null;
    if (!payload && row.objectRef?.startsWith("sealed:")) {
      if (!objects) throw new CompactionContractError("sealed_object_unavailable", "Active tool state requires its sealed exact object.");
      const opened = await objects.openReference(row.objectRef);
      if (!opened || typeof opened !== "object") {
        throw new CompactionContractError("history_reference_unavailable", "A tool's sealed terminal object is unavailable.");
      }
      payload = opened as Record<string, unknown>;
    } else if (!payload && row.objectRef) {
      const exact = await resolveCanonical(tx, {
        stableId: row.stableId,
        kind: "tool_call",
        sessionId: actor.sessionId,
        rootTaskRunId: actor.rootTaskRunId,
        logicalWorkerId: actor.logicalWorkerId,
        attemptId: null,
        eventCursor: row.eventCursor,
        objectRef: row.objectRef,
        byteLength: 0,
      }, objects);
      if (!exact || typeof exact !== "object") {
        throw new CompactionContractError("history_reference_unavailable", "A tool's canonical terminal object is unavailable.");
      }
      payload = exact as Record<string, unknown>;
    }
    latestToolStatus.set(row.stableId, payload?.status);
  }
  const files = await tx.select({
    id: workspaceObjects.id,
    kind: workspaceObjects.kind,
    status: workspaceObjects.status,
  }).from(workspaceObjects).where(eq(workspaceObjects.sessionId, actor.sessionId))
    .orderBy(asc(workspaceObjects.id));
  const runIds = [actor.rootTaskRunId, ...(context.childRunId ? [context.childRunId] : [])];
  const approvals = await tx.select({
    requestId: systemRequests.requestId,
    runId: systemRequests.runId,
    kind: systemRequests.kind,
    status: systemRequests.status,
    expiresAt: systemRequests.expiresAt,
    version: systemRequests.version,
  }).from(systemRequests).where(and(
    eq(systemRequests.sessionId, context.parentSessionId),
    or(...runIds.map((id) => eq(systemRequests.runId, id))),
  )).orderBy(asc(systemRequests.createdAt), asc(systemRequests.requestId));
  const instructionRefs = await tx.select({
    stableId: compactionHistoryItems.stableId,
    eventCursor: compactionHistoryItems.eventCursor,
  }).from(compactionHistoryItems).where(and(
    eq(compactionHistoryItems.sessionId, actor.sessionId),
    eq(compactionHistoryItems.rootTaskRunId, actor.rootTaskRunId),
    eq(compactionHistoryItems.kind, "message"),
    ...itemScope(actor),
  )).orderBy(asc(compactionHistoryItems.position));
  const rawState = state as Record<string, unknown>;
  const stateRef = (field: string): string =>
    `postgres:session_agent_state/${actor.sessionId}#${field}`;
  const fileRefs = files.map((file) => ({
    ...file,
    objectRef: `postgres:workspace_objects/${file.id}`,
  }));
  return redacted({
    goal: { stateRef: stateRef("goal"), present: rawState.goal !== null && rawState.goal !== undefined },
    todos: {
      stateRef: stateRef("todos"),
      count: Array.isArray(rawState.todos) ? rawState.todos.length : 0,
    },
    planMode: rawState.planMode === true,
    mode: ["safe", "auto", "drive", "studio"].includes(String(rawState.mode)) ? rawState.mode : "auto",
    modelPinSet: typeof rawState.modelPin === "string" && rawState.modelPin.length > 0,
    activeSkillScopes: {
      stateRef: stateRef("activeSkillScopes"),
      count: Array.isArray(rawState.activeSkillScopes) ? rawState.activeSkillScopes.length : 0,
    },
    decisionsAndInstructionRefs: instructionRefs,
    deferred: deferred.map((item) => ({
      ...item,
      objectRef: `postgres:subagent_dispatches/${item.id}`,
    })),
    workers,
    unresolvedErrorRefs: errors
      .filter((row) => latestToolStatus.get(row.stableId) === "error")
      .map(({ stableId, eventCursor }) => ({ stableId, eventCursor })),
    files: fileRefs.filter((file) => file.kind !== "artifact"),
    artifacts: fileRefs.filter((file) => file.kind === "artifact"),
    approvals,
    lineage: { ...actor, parentSessionId: context.parentSessionId, childRunId: context.childRunId, previousCheckpointId },
    recall: { cutoffCursor, pendingRecallCursor },
    continuation: "continuing_existing_task",
  }) as Record<string, unknown>;
}

function clip(value: unknown, max = 1_200): string {
  const text = typeof value === "string" ? value : stableStringify(value);
  return text.length <= max ? text : `${text.slice(0, max - 1)}…`;
}

function checkpointSummary(options: {
  compactionId: string;
  checkpointId: string;
  ledgerVersion: number;
  cutoffCursor: string;
  activeState: Record<string, unknown>;
  profile: ModelContextProfile;
  beforeTokens: number;
  usageSource: ContextUsage["usageSource"];
}): string {
  const state = options.activeState as Record<string, unknown>;
  const refs = (key: string): unknown[] => Array.isArray(state[key]) ? state[key] as unknown[] : [];
  const ids = (key: string, field: string): string => refs(key).slice(-12)
    .map((entry) => String((entry as Record<string, unknown>)[field] ?? "")).filter(Boolean).join(", ") || "(none)";
  return [
    "# Lossless compaction checkpoint",
    `Compaction: ${options.compactionId}`,
    `Checkpoint: ${options.checkpointId}`,
    "Continuation: continuing_existing_task",
    `Ledger version: ${options.ledgerVersion}; cutoff cursor: ${options.cutoffCursor}`,
    `Model: ${clip(options.profile.model, 200)}; context limit: ${options.profile.contextLimit}; trigger usage: ${options.beforeTokens} (${options.usageSource}); rebuilt-projection usage is stored with this checkpoint`,
    "",
    "## Goal and active state",
    `- goal: ${clip(state.goal ?? "(none)")}`,
    `- todos: ${clip(state.todos ?? [])}`,
    `- plan mode: ${clip(state.planMode)}; mode: ${clip(state.mode)}`,
    "",
    "## User decisions and instructions",
    `- exact message references (${refs("decisionsAndInstructionRefs").length}): ${ids("decisionsAndInstructionRefs", "stableId")}`,
    "",
    "## Pending and deferred work",
    `- deferred (${refs("deferred").length}): ${ids("deferred", "id")}`,
    `- pending recall cursor: ${clip((state.recall as Record<string, unknown> | undefined)?.pendingRecallCursor ?? null)}`,
    "",
    "## Workers",
    `- workers (${refs("workers").length}): ${ids("workers", "id")}`,
    "",
    "## Errors",
    `- unresolved exact error references (${refs("unresolvedErrorRefs").length}): ${ids("unresolvedErrorRefs", "stableId")}`,
    "",
    "## Files and artifacts",
    `- files (${refs("files").length}): ${ids("files", "id")}`,
    `- artifacts (${refs("artifacts").length}): ${ids("artifacts", "id")}`,
    "",
    "## Approvals",
    `- approvals (${refs("approvals").length}): ${ids("approvals", "requestId")}`,
    "",
    "## Lineage",
    `- ${clip(state.lineage)}`,
    "",
    "Exact original messages, calls, approvals and objects remain in durable history; use authorized bounded exact recall by stable reference or cursor. This checkpoint never replaces that history.",
  ].join("\n");
}

function projectionUsage(messages: readonly CompactionMessage[]): number {
  const serialized = Buffer.byteLength(stableStringify(messages), "utf8");
  return Math.min(Number.MAX_SAFE_INTEGER, serialized + 4 + messages.length * 4);
}

function outcomeFromCheckpoint(
  checkpoint: CompactionCheckpointRow,
  messages: CompactionMessage[],
  cutoff: number,
  rawSpan: readonly CompactionMessage[],
): CompactionOutcome {
  const keptEphemeral = rawSpan.filter((message) => message.ephemeral === true);
  return {
    compacted: true,
    messages: [
      { role: "system", content: compactedSystemBlock(checkpoint.summary!), volatile: false },
      ...keptEphemeral,
      ...messages.slice(cutoff),
    ],
    foldBoundary: 1,
    compactionId: checkpoint.compactionId,
    checkpointId: checkpoint.checkpointId,
    cutoffCursor: checkpoint.cutoffCursor!,
    contextLimit: checkpoint.contextLimit!,
    beforeTokens: checkpoint.beforeTokens!,
    afterTokens: checkpoint.afterTokens!,
    usageSource: checkpoint.usageSource!,
    continuation: "continuing_existing_task",
  };
}

async function assertCursorHistoryUsable(
  tx: Tx,
  actor: CompactionActor,
  cursor: { cutoffCursor: string | null; cutoffMessageId: string | null },
  objects?: CompactionExactObjectReader,
): Promise<void> {
  if (cursor.cutoffMessageId) {
    const canonical = await rows(tx, sql`SELECT id FROM messages
      WHERE id = ${cursor.cutoffMessageId} AND session_id = ${actor.sessionId} LIMIT 1`);
    if (canonical.length === 0) {
      throw new CompactionContractError("history_reference_unavailable", "The persisted cutoff message no longer exists.");
    }
  }
  if (!cursor.cutoffCursor) return;
  const found = await tx.select().from(compactionHistoryItems).where(and(
    eq(compactionHistoryItems.sessionId, actor.sessionId),
    eq(compactionHistoryItems.rootTaskRunId, actor.rootTaskRunId),
    eq(compactionHistoryItems.eventCursor, cursor.cutoffCursor),
  )).orderBy(asc(compactionHistoryItems.position)).limit(1);
  const row = found[0];
  if (!row) {
    throw new CompactionContractError("history_reference_unavailable", "The persisted cutoff cursor no longer has exact history.");
  }
  if (row.objectRef) {
    const item: StoredExactHistoryItem = {
      stableId: row.stableId,
      kind: row.kind,
      sessionId: row.sessionId,
      rootTaskRunId: row.rootTaskRunId,
      logicalWorkerId: row.logicalWorkerId,
      attemptId: row.attemptId,
      eventCursor: row.eventCursor,
      objectRef: row.objectRef,
      byteLength: row.byteLength,
    };
    const exact = await resolveCanonical(tx, item, objects);
    if (exact === null || exact === undefined) {
      throw new CompactionContractError("history_reference_unavailable", "The persisted cutoff object is unavailable.");
    }
  } else if (row.inlinePayload === null) {
    throw new CompactionContractError("history_reference_unavailable", "The persisted cutoff has no exact payload.");
  }
}

export function createCompactionRepository(
  db: Db,
  objects?: CompactionExactObjectReader,
): {
  foldCheckpoint(input: FoldCheckpointInput): Promise<CompactionOutcome>;
} {
  return {
    async foldCheckpoint(input: FoldCheckpointInput): Promise<CompactionOutcome> {
      validateFoldInput(input);
      const from = boundaryOf(input.messages, input.foldBoundary);
      if (BigInt(input.usage.beforeTokens) * 100n < BigInt(input.profile.contextLimit) * 80n) {
        return { compacted: false, messages: input.messages, foldBoundary: from };
      }
      const { calls, results } = validateTerminalTools(input.messages);
      const cutoff = chooseCutoff(input, from);
      if (cutoff - from < 4) return { compacted: false, messages: input.messages, foldBoundary: from };
      const rawSpan = input.messages.slice(from, cutoff);
      const span = rawSpan.filter((message) => message.ephemeral !== true && !isCheckpointRow(message));

      return db.transaction(async (tx) => {
        const context = await validateActor(tx, input.actor, "write");
        const actor = context.canonicalActor;
        // Required truncation-fence integration: validate the COMPLETE fold
        // input (prefix and retained tail) before any cursor/replay/outcome.
        // Worker parent-owned approvals/events use the same parent gate as
        // appendExactItem; parent always precedes child in the lock order.
        if (context.parentSessionId !== actor.sessionId) {
          await lockCompactionSession(tx, context.parentSessionId, { mode: "shared" });
        }
        await lockCompactionSession(tx, actor.sessionId, {
          mode: "shared",
          messages: input.messages,
        });
        await assertCurrentAttempt(tx, actor);
        await assertApprovalsTerminal(tx, actor, context);
        const spanHistory = await historyForSpan(tx, span, actor, calls, results, objects);
        if (spanHistory.length === 0) return { compacted: false, messages: input.messages, foldBoundary: from };
        const canonicalHistory = await canonicalHistoryForActor(tx, actor, context);
        const requestDigest = digest({
          messages: input.messages,
          from,
          cutoff,
          profile: input.profile,
          usage: input.usage,
          actor,
        });
        const scope = {
          sessionId: actor.sessionId,
          rootTaskRunId: actor.rootTaskRunId,
          actorKind: actor.kind,
          actorId: actorId(actor),
        };
        await tx.insert(compactionCursors).values({
          ...scope,
          logicalWorkerId: actor.logicalWorkerId,
          attemptId: actor.attemptId,
        }).onConflictDoNothing({
          target: [
            compactionCursors.sessionId,
            compactionCursors.rootTaskRunId,
            compactionCursors.actorKind,
            compactionCursors.actorId,
          ],
        });
        const cursorRows = await tx.select().from(compactionCursors).where(and(
          eq(compactionCursors.sessionId, scope.sessionId),
          eq(compactionCursors.rootTaskRunId, scope.rootTaskRunId),
          eq(compactionCursors.actorKind, scope.actorKind),
          eq(compactionCursors.actorId, scope.actorId),
        )).for("update").limit(1);
        const cursor = cursorRows[0]!;
        // Fence again after cursor acquisition: a resume between lineage
        // validation and this lock can never advance or replay the old attempt.
        await assertCurrentAttempt(tx, actor);
        await assertCursorHistoryUsable(tx, actor, cursor, objects);
        const replayRows = await tx.select().from(compactionCheckpoints).where(and(
          eq(compactionCheckpoints.sessionId, scope.sessionId),
          eq(compactionCheckpoints.rootTaskRunId, scope.rootTaskRunId),
          eq(compactionCheckpoints.actorKind, scope.actorKind),
          eq(compactionCheckpoints.actorId, scope.actorId),
          eq(compactionCheckpoints.requestDigest, requestDigest),
        )).limit(1);
        const replay = replayRows[0];
        if (replay) return outcomeFromCheckpoint(replay, input.messages, cutoff, rawSpan);
        if (cursor.checkpointId) {
          const currentRows = await tx.select().from(compactionCheckpoints)
            .where(eq(compactionCheckpoints.checkpointId, cursor.checkpointId)).limit(1);
          const current = currentRows[0];
          if (!current || from === 0 || input.messages[0]?.content !== compactedSystemBlock(current.summary!)) {
            throw new CompactionContractError("stale_compaction_input", "The input does not continue the actor's current checkpoint.");
          }
        }

        for (const item of [...spanHistory, ...canonicalHistory]) {
          await appendHistoryInternal(tx, item, objects);
        }
        const scopedHistory = itemScope(actor);
        const historyRows = await tx.select({
          eventCursor: compactionHistoryItems.eventCursor,
        }).from(compactionHistoryItems).where(and(
          eq(compactionHistoryItems.sessionId, actor.sessionId),
          eq(compactionHistoryItems.rootTaskRunId, actor.rootTaskRunId),
          ...scopedHistory,
          eq(compactionHistoryItems.kind, "message"),
        )).orderBy(asc(compactionHistoryItems.position));
        const cutoffCursor = historyRows[historyRows.length - 1]?.eventCursor ?? cursor.cutoffCursor;
        if (!cutoffCursor) throw new CompactionContractError("missing_cutoff", "Compaction requires a durable message or exact-history cursor.");
        const cutoffMessageId = [...span].reverse().find((message) => !!message.id)?.id ?? cursor.cutoffMessageId;
        const ledgerVersion = cursor.ledgerVersion + 1;
        const compactionId = newId();
        const checkpointId = newId();
        const activeState = await buildActiveState(
          tx,
          actor,
          context,
          cursor.checkpointId,
          cutoffCursor,
          cursor.pendingRecallCursor,
          objects,
        );
        const summary = checkpointSummary({
          compactionId,
          checkpointId,
          ledgerVersion,
          cutoffCursor,
          activeState,
          profile: input.profile,
          beforeTokens: input.usage.beforeTokens,
          usageSource: input.usage.usageSource,
        });
        const afterMessages = [
          { role: "system", content: compactedSystemBlock(summary), volatile: false },
          ...rawSpan.filter((message) => message.ephemeral === true),
          ...input.messages.slice(cutoff),
        ] as CompactionMessage[];
        const afterTokens = projectionUsage(afterMessages);
        assertNoPlaintextSecret(summary);
        assertNoPlaintextSecret(activeState);
        const previousLedger = cursor.ledgerVersion > 0
          ? (await tx.select({ ledger: compactionCheckpoints.ledger }).from(compactionCheckpoints)
            .where(eq(compactionCheckpoints.checkpointId, cursor.checkpointId!)).limit(1))[0]?.ledger
          : null;
        const priorFolded = typeof previousLedger?.foldedMessages === "number" ? previousLedger.foldedMessages : 0;
        const ledger = {
          v: 1,
          version: ledgerVersion,
          compactions: ledgerVersion,
          foldedMessages: priorFolded + span.length,
          previousCheckpointId: cursor.checkpointId,
          cutoffCursor,
        };
        const createdAt = new Date();
        const inserted = await tx.insert(compactionCheckpoints).values({
          checkpointId,
          compactionId,
          ...scope,
          logicalWorkerId: actor.logicalWorkerId,
          attemptId: actor.attemptId,
          previousCheckpointId: cursor.checkpointId,
          requestDigest,
          model: input.profile.model,
          contextLimit: input.profile.contextLimit,
          outputReserveTokens: input.profile.outputReserveTokens,
          providerReserveTokens: input.profile.providerReserveTokens,
          beforeTokens: input.usage.beforeTokens,
          afterTokens,
          usageSource: input.usage.usageSource,
          cutoffCursor,
          cutoffMessageId,
          ledgerVersion,
          ledger,
          summary,
          activeState,
          continuation: "continuing_existing_task",
          createdAt,
        }).returning();
        const checkpoint = inserted[0]!;
        const checkpointRef = `postgres:compaction_checkpoints/${checkpointId}`;
        for (const item of [
          {
            stableId: checkpointId,
            kind: "checkpoint" as const,
            eventCursor: checkpointId,
          },
          {
            stableId: compactionId,
            kind: "compaction" as const,
            eventCursor: compactionId,
          },
        ]) {
          await appendHistoryInternal(tx, {
            ...item,
            sessionId: actor.sessionId,
            rootTaskRunId: actor.rootTaskRunId,
            logicalWorkerId: actor.logicalWorkerId,
            attemptId: actor.attemptId,
            objectRef: checkpointRef,
            byteLength: Buffer.byteLength(summary, "utf8"),
            occurredAt: createdAt,
          }, objects);
        }
        await tx.update(compactionCursors).set({
          checkpointId,
          compactionId,
          cutoffCursor,
          cutoffMessageId,
          ledgerVersion,
          attemptId: actor.attemptId,
          continuation: "continuing_existing_task",
          updatedAt: createdAt,
        }).where(and(
          eq(compactionCursors.sessionId, scope.sessionId),
          eq(compactionCursors.rootTaskRunId, scope.rootTaskRunId),
          eq(compactionCursors.actorKind, scope.actorKind),
          eq(compactionCursors.actorId, scope.actorId),
        ));
        return outcomeFromCheckpoint(checkpoint, input.messages, cutoff, rawSpan);
      });
    },
  };
}
