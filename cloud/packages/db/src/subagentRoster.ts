import { sql } from "drizzle-orm";
import {
  subagentSessionProjectionSchema,
  subagentCompactionMetadataSchema,
  subagentStatusSchema,
  subagentSummarySchema,
  structuredSubagentReportSchema,
  type SubagentCompactionMetadata,
  type SubagentCounts,
  type SubagentSessionProjection,
  type SubagentStatus,
  type SubagentSummary,
} from "@ovid/shared";

import type { Db } from "./client.js";
import { sessionEventMirror } from "./schema.js";

export const SUBAGENT_ROSTER_DEFAULT_LIMIT = 50;
export const SUBAGENT_ROSTER_MAX_LIMIT = 200;
export const SUBAGENT_ROSTER_MAX_CURSOR_CHARS = 4096;
/**
 * `{"v":1,"identity":""}` is 21 ASCII bytes. The wire cursor is base64url of
 * JSON, so 3051 ASCII identity characters occupy the remaining 4075 bytes and
 * encode to exactly 4096 characters.
 */
export const SUBAGENT_ROSTER_MAX_CURSOR_IDENTITY_CHARS = 3051;
/** A bounded read cannot pin the gateway or turn a hostile session into an OOM. */
export const SUBAGENT_ROSTER_MAX_EVENTS = 20_000;
export const SUBAGENT_ROSTER_PROMPT_CHARS = 200;

// Redis IDs are numeric. The same bounded lexical shape used by SQL keeps the
// bigint cast in range; BigInt avoids Number precision loss for valid values.
const SEQ_RE = /^\d{1,18}(?:-\d{1,18})?$/;
const TERMINAL_STATUSES = new Set<SubagentStatus>([
  "completed",
  "failed",
  "cancelled",
  "timeout",
]);
const LIFECYCLE_TYPES = [
  "subagent_requested",
  "subagent_deferred",
  "subagent_admitted",
  "subagent_started",
  "subagent_controlled",
  "subagent_completed",
  "subagent_compacted",
] as const;

interface MirroredRow {
  seq: string;
  type: string;
  payload: Record<string, unknown>;
  ts: Date | string;
}

export interface SubagentRosterQuery {
  sessionId: string;
  limit: number;
  after?: string | null;
}

export class SubagentRosterCursorError extends Error {}
export class SubagentRosterTooLargeError extends Error {}

interface WorkerMerge {
  data: SubagentSummary;
  aliases: Set<string>;
  /** Immutable first lifecycle sequence; stable pagination must not follow activity reordering. */
  orderSeq: string;
}

function splitSeq(value: string): { ms: bigint; sub: bigint } | null {
  if (!SEQ_RE.test(value)) return null;
  const dash = value.indexOf("-");
  const ms = BigInt(dash === -1 ? value : value.slice(0, dash));
  const sub = BigInt(dash === -1 ? "0" : value.slice(dash + 1));
  return ms < 0n || sub < 0n ? null : { ms, sub };
}

function compareSeq(a: string, b: string): number {
  const aa = splitSeq(a);
  const bb = splitSeq(b);
  if (aa === null || bb === null) return a.localeCompare(b);
  if (aa.ms !== bb.ms) return aa.ms < bb.ms ? -1 : 1;
  if (aa.sub !== bb.sub) return aa.sub < bb.sub ? -1 : 1;
  return 0;
}

function cursorForIdentity(identity: string): string | null {
  if (
    identity.length === 0 ||
    identity.length > SUBAGENT_ROSTER_MAX_CURSOR_IDENTITY_CHARS
  ) {
    return null;
  }
  const cursor = Buffer.from(JSON.stringify({ v: 1, identity }), "utf8").toString("base64url");
  // Character bounds alone cannot prove the byte/encoded bound for non-ASCII
  // identities. Never mint a cursor the response contract would reject.
  return cursor.length <= SUBAGENT_ROSTER_MAX_CURSOR_CHARS ? cursor : null;
}

export function encodeSubagentRosterCursor(identity: string): string {
  const cursor = cursorForIdentity(identity);
  if (cursor === null) throw new RangeError("Invalid subagent roster cursor identity");
  return cursor;
}

/** Strict opaque cursor decoder. Missing, malformed and oversized values are null. */
export function decodeSubagentRosterCursor(value: string): string | null {
  if (value.length === 0 || value.length > SUBAGENT_ROSTER_MAX_CURSOR_CHARS) return null;
  try {
    const parsed = JSON.parse(Buffer.from(value, "base64url").toString("utf8")) as {
      v?: unknown;
      identity?: unknown;
    };
    if (parsed.v !== 1 || typeof parsed.identity !== "string") return null;
    const identity = parsed.identity;
    // Reject non-canonical encodings and identities whose UTF-8 expansion would
    // exceed the same wire bound enforced by the encoder.
    return cursorForIdentity(identity) === value ? identity : null;
  } catch {
    return null;
  }
}

function nonEmpty(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function numberOf(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function positiveInteger(value: unknown): number | null {
  const parsed = numberOf(value);
  return parsed !== null && Number.isInteger(parsed) && parsed > 0 ? parsed : null;
}

function statusOf(value: unknown): SubagentStatus | null {
  const parsed = subagentStatusSchema.safeParse(value);
  return parsed.success ? parsed.data : null;
}

/** Validate the lifecycle facts needed to fold, before allocating a worker. */
function validLifecycleRow(row: MirroredRow): boolean {
  const p = row.payload;
  switch (row.type) {
    case "subagent_requested":
      return nonEmpty(p.requestId) !== null;
    case "subagent_deferred":
      return nonEmpty(p.deferredRequestId ?? p.requestId) !== null &&
        p.status === "awaiting_next_user_task";
    case "subagent_admitted":
      return nonEmpty(p.childSessionId) !== null && nonEmpty(p.childRunId) !== null;
    case "subagent_started":
      return nonEmpty(p.childSessionId) !== null &&
        nonEmpty(p.childRunId) !== null &&
        nonEmpty(p.agentType) !== null &&
        (p.status === undefined || p.status === "running");
    case "subagent_controlled": {
      const status = statusOf(p.status);
      return nonEmpty(p.childSessionId) !== null &&
        nonEmpty(p.childRunId) !== null &&
        status !== null &&
        nonEmpty(p.controlledAt) !== null;
    }
    case "subagent_completed": {
      const status = statusOf(p.status);
      return nonEmpty(p.childSessionId) !== null &&
        nonEmpty(p.childRunId) !== null &&
        nonEmpty(p.agentType) !== null &&
        status !== null && TERMINAL_STATUSES.has(status);
    }
    case "subagent_compacted":
      return compactionOf(row, nonEmpty(p.workerId) ?? "") !== null;
    default:
      return false;
  }
}

function workerAliases(payload: Record<string, unknown>): Set<string> {
  const out = new Set<string>();
  const add = (kind: string, raw: unknown): void => {
    const value = nonEmpty(raw);
    if (value !== null) out.add(`${kind}:${value}`);
  };
  add("request", payload.requestId);
  add("request", payload.deferredRequestId);
  add("logical", payload.logicalWorkerId);
  add("logical", payload.workerId);
  add("childSession", payload.childSessionId);
  add("childRun", payload.childRunId);
  return out;
}

export function subagentRosterIdentity(worker: SubagentSummary): string {
  return worker.requestId ?? worker.deferredRequestId ?? worker.logicalWorkerId ??
    worker.childRunId ?? worker.childSessionId ?? `orphan:${worker.attemptId ?? "unknown"}`;
}

function emptyWorker(payload: Record<string, unknown>, orderSeq: string): WorkerMerge {
  const prompt = nonEmpty(payload.prompt);
  const data: SubagentSummary = {
    requestId: nonEmpty(payload.requestId),
    deferredRequestId: nonEmpty(payload.deferredRequestId),
    logicalWorkerId: nonEmpty(payload.logicalWorkerId) ?? nonEmpty(payload.workerId),
    childSessionId: nonEmpty(payload.childSessionId),
    childRunId: nonEmpty(payload.childRunId),
    attemptId: nonEmpty(payload.attemptId),
    attemptNumber: positiveInteger(payload.attemptNumber),
    rootTaskRunId: nonEmpty(payload.rootTaskRunId) ?? nonEmpty(payload.runId),
    parentRunId: nonEmpty(payload.parentRunId) ?? nonEmpty(payload.runId),
    batchId: nonEmpty(payload.batchId),
    agentType: nonEmpty(payload.agentType),
    launchReason: nonEmpty(payload.launchReason),
    schedulingReason: nonEmpty(payload.schedulingReason),
    prompt: prompt?.slice(0, SUBAGENT_ROSTER_PROMPT_CHARS) ?? null,
    promptTruncated: (prompt?.length ?? 0) > SUBAGENT_ROSTER_PROMPT_CHARS,
    summary: null,
    error: null,
    requestedAt: null,
    deferredAt: null,
    admittedAt: null,
    startedAt: null,
    endedAt: null,
    startKnown: false,
    status: "running",
    lastActivity: null,
    lastActivityAt: null,
    // Parent lifecycle sequence IDs are not child-stream cursors. Child
    // expansion starts at null and advances on the child's own event stream.
    lastCursor: null,
    structuredReport: null,
    logAvailable: typeof payload.logAvailable === "boolean" ? payload.logAvailable : null,
    compaction: null,
    steps: [],
  };
  return { data, aliases: workerAliases(payload), orderSeq };
}

function cloneWorker(worker: WorkerMerge): WorkerMerge {
  return {
    data: { ...worker.data, steps: [...worker.data.steps] },
    aliases: new Set(worker.aliases),
    orderSeq: worker.orderSeq,
  };
}

function copyIds(worker: WorkerMerge, payload: Record<string, unknown>): void {
  worker.data.requestId ??= nonEmpty(payload.requestId);
  worker.data.deferredRequestId ??= nonEmpty(payload.deferredRequestId);
  worker.data.logicalWorkerId ??= nonEmpty(payload.logicalWorkerId) ?? nonEmpty(payload.workerId);
  worker.data.childSessionId ??= nonEmpty(payload.childSessionId);
  worker.data.childRunId ??= nonEmpty(payload.childRunId);
  worker.data.attemptId ??= nonEmpty(payload.attemptId);
  worker.data.attemptNumber ??= positiveInteger(payload.attemptNumber);
  worker.data.rootTaskRunId ??= nonEmpty(payload.rootTaskRunId) ?? nonEmpty(payload.runId);
  worker.data.parentRunId ??= nonEmpty(payload.parentRunId) ?? nonEmpty(payload.runId);
  worker.data.batchId ??= nonEmpty(payload.batchId);
  worker.data.agentType ??= nonEmpty(payload.agentType);
  worker.data.launchReason ??= nonEmpty(payload.launchReason);
  worker.data.schedulingReason ??= nonEmpty(payload.schedulingReason);
  if (worker.data.prompt === null) {
    const prompt = nonEmpty(payload.prompt);
    worker.data.prompt = prompt?.slice(0, SUBAGENT_ROSTER_PROMPT_CHARS) ?? null;
    worker.data.promptTruncated = (prompt?.length ?? 0) > SUBAGENT_ROSTER_PROMPT_CHARS;
  }
  if (typeof payload.logAvailable === "boolean") worker.data.logAvailable = payload.logAvailable;
  for (const alias of workerAliases(payload)) worker.aliases.add(alias);
}

function eventTimestamp(row: MirroredRow): string {
  return row.ts instanceof Date ? row.ts.toISOString() : new Date(row.ts).toISOString();
}

function compactionOf(
  row: MirroredRow,
  workerId: string,
): SubagentCompactionMetadata | null {
  const p = row.payload;
  const sessionId = nonEmpty(p.sessionId);
  const runId = nonEmpty(p.runId);
  const compactionId = nonEmpty(p.compactionId);
  const checkpointId = nonEmpty(p.checkpointId);
  const ts = nonEmpty(p.ts);
  const model = nonEmpty(p.model);
  const contextLimit = positiveInteger(p.contextLimit);
  const beforeTokens = numberOf(p.beforeTokens);
  const afterTokens = numberOf(p.afterTokens);
  const usageSource = p.usageSource;
  if (
    sessionId === null || runId === null || compactionId === null ||
    checkpointId === null || ts === null || model === null ||
    contextLimit === null || beforeTokens === null || !Number.isInteger(beforeTokens) || beforeTokens < 0 ||
    afterTokens === null || !Number.isInteger(afterTokens) || afterTokens < 0 ||
    (usageSource !== "measured" && usageSource !== "deterministic_fallback") ||
    p.continuation !== "continuing_existing_task"
  ) {
    return null;
  }
  const candidate: SubagentCompactionMetadata = {
    type: "subagent_compacted",
    workerId,
    sessionId,
    runId,
    compactionId,
    checkpointId,
    ts,
    model,
    contextLimit,
    beforeTokens,
    afterTokens,
    usageSource,
    continuation: "continuing_existing_task",
  };
  return subagentCompactionMetadataSchema.safeParse(candidate).success ? candidate : null;
}

/**
 * Fold parent lifecycle events into the shipped client projection. Projection
 * happens before filtering and pagination, so malformed rows cannot consume a
 * page window or cause a valid worker to be skipped.
 */
export function projectSubagentLifecycle(rows: readonly MirroredRow[]): SubagentSummary[] {
  const workers: WorkerMerge[] = [];
  const pendingRequests = new Map<string, { payload: Record<string, unknown>; at: string }>();

  const find = (payload: Record<string, unknown>): WorkerMerge | null => {
    const eventAliases = workerAliases(payload);
    for (const worker of workers) {
      for (const alias of eventAliases) {
        if (worker.aliases.has(alias)) return worker;
      }
    }
    return null;
  };
  const ensure = (row: MirroredRow): WorkerMerge => {
    const existing = find(row.payload);
    if (existing !== null) return existing;
    const worker = emptyWorker(row.payload, row.seq);
    const requestId = nonEmpty(row.payload.requestId ?? row.payload.deferredRequestId);
    const pending = requestId === null ? undefined : pendingRequests.get(requestId);
    if (pending !== undefined) {
      copyIds(worker, pending.payload);
      worker.data.requestedAt = pending.at;
    }
    workers.push(worker);
    return worker;
  };
  const activity = (worker: WorkerMerge, row: MirroredRow): void => {
    worker.data.lastActivity = (nonEmpty(row.payload.name) ?? row.type).slice(0, 4096);
    worker.data.lastActivityAt = eventTimestamp(row);
  };

  for (const row of [...rows].sort((a, b) => compareSeq(a.seq, b.seq))) {
    const p = row.payload;
    if (!validLifecycleRow(row)) continue;
    if (row.type === "subagent_requested") {
      const requestId = nonEmpty(p.requestId);
      const at = nonEmpty(p.requestedAt) ?? eventTimestamp(row);
      if (requestId !== null) pendingRequests.set(requestId, { payload: p, at });
      const worker = find(p);
      if (worker !== null) {
        copyIds(worker, p);
        worker.data.requestedAt = at;
        activity(worker, row);
      }
      continue;
    }

    if (row.type === "subagent_compacted") {
      const worker = find(p);
      if (worker !== null) {
        const compaction = compactionOf(row, nonEmpty(p.workerId) ?? worker.data.logicalWorkerId ?? "");
        if (compaction !== null) worker.data.compaction = compaction;
        activity(worker, row);
      }
      continue;
    }

    if (row.type !== "subagent_deferred" && row.type !== "subagent_admitted" &&
        row.type !== "subagent_started" && row.type !== "subagent_controlled" &&
        row.type !== "subagent_completed") {
      continue;
    }

    const worker = ensure(row);
    copyIds(worker, p);
    activity(worker, row);

    switch (row.type) {
      case "subagent_deferred":
        worker.data.status = "awaiting_next_user_task";
        worker.data.deferredRequestId = nonEmpty(p.deferredRequestId ?? p.requestId);
        worker.data.requestedAt = nonEmpty(p.requestedAt) ?? worker.data.requestedAt;
        worker.data.deferredAt = nonEmpty(p.deferredAt) ?? eventTimestamp(row);
        worker.data.admittedAt = null;
        worker.data.startedAt = null;
        worker.data.endedAt = null;
        worker.data.startKnown = false;
        worker.data.childSessionId = null;
        worker.data.childRunId = null;
        worker.data.logAvailable = false;
        break;
      case "subagent_admitted":
        worker.data.status = "running";
        worker.data.requestedAt = nonEmpty(p.requestedAt) ?? worker.data.requestedAt;
        worker.data.admittedAt = nonEmpty(p.admittedAt) ?? eventTimestamp(row);
        worker.data.startedAt = nonEmpty(p.startedAt) ?? worker.data.startedAt;
        worker.data.startKnown = worker.data.startedAt !== null;
        break;
      case "subagent_started":
        worker.data.status = "running";
        worker.data.requestedAt = nonEmpty(p.requestedAt) ?? worker.data.requestedAt;
        worker.data.admittedAt = nonEmpty(p.admittedAt) ?? worker.data.admittedAt;
        worker.data.startedAt = nonEmpty(p.startedAt) ?? eventTimestamp(row);
        worker.data.startKnown = true;
        break;
      case "subagent_controlled": {
        const status = statusOf(p.status);
        if (status !== null) worker.data.status = status;
        // continue/resume may report "running"; those live controls must not
        // fabricate an end. Only a terminal control proves endedAt.
        worker.data.endedAt = status !== null && TERMINAL_STATUSES.has(status)
          ? nonEmpty(p.controlledAt) ?? eventTimestamp(row)
          : null;
        break;
      }
      case "subagent_completed": {
        const status = statusOf(p.status);
        if (status === null || !TERMINAL_STATUSES.has(status)) break;
        worker.data.status = status;
        worker.data.endedAt = nonEmpty(p.endedAt) ?? eventTimestamp(row);
        worker.data.summary = typeof p.summary === "string" ? p.summary.slice(0, 4000) : null;
        const report = structuredSubagentReportSchema.safeParse(p.structuredReport);
        worker.data.structuredReport = report.success ? report.data : null;
        worker.data.error = report.success ? report.data.error_if_any : null;
        break;
      }
      default:
        break;
    }
  }

  // Project first, then reject incomplete workers. This preserves a valid
  // worker wherever malformed rows occur in the same ordered scan.
  const projected = workers
    .filter((worker) => subagentRosterIdentity(worker.data).startsWith("orphan:") === false)
    .filter((worker) => worker.data.status === "awaiting_next_user_task"
      ? worker.data.deferredRequestId !== null
      : worker.data.childSessionId !== null &&
        worker.data.childRunId !== null &&
        worker.data.agentType !== null)
    // The public schema is the final projection boundary. A malformed field is
    // dropped here, before filtering/pagination, rather than failing siblings.
    .filter((worker) => subagentSummarySchema.safeParse(worker.data).success);

  return projected.sort((a, b) => {
    return compareSeq(b.orderSeq, a.orderSeq) ||
      subagentRosterIdentity(a.data).localeCompare(subagentRosterIdentity(b.data));
  }).map((worker) => worker.data);
}

export function subagentCounts(items: readonly SubagentSummary[]): SubagentCounts {
  const counts: SubagentCounts = {
    total: items.length,
    running: 0,
    awaiting_next_user_task: 0,
    completed: 0,
    failed: 0,
    cancelled: 0,
    timeout: 0,
  };
  for (const item of items) counts[item.status] += 1;
  return counts;
}

export function paginateSubagentRoster(
  all: readonly SubagentSummary[],
  input: { limit: number; after?: string | null },
): SubagentSessionProjection {
  if (
    !Number.isInteger(input.limit) || input.limit < 1 ||
    input.limit > SUBAGENT_ROSTER_MAX_LIMIT
  ) {
    throw new RangeError("Subagent roster limit must be an integer from 1 to 200");
  }
  let start = 0;
  if (input.after !== null && input.after !== undefined) {
    const identity = decodeSubagentRosterCursor(input.after);
    if (identity === null) {
      throw new SubagentRosterCursorError("Invalid subagent roster cursor");
    }
    const index = all.findIndex((item) => subagentRosterIdentity(item) === identity);
    if (index < 0) {
      throw new SubagentRosterCursorError("Subagent roster cursor is outside this session");
    }
    start = index + 1;
  }

  const items = all.slice(start, start + input.limit);
  const last = items[items.length - 1];
  const hasMore = start + items.length < all.length;
  return subagentSessionProjectionSchema.parse({
    counts: subagentCounts(all),
    items,
    nextCursor: hasMore && last !== undefined
      ? encodeSubagentRosterCursor(subagentRosterIdentity(last))
      : null,
  });
}

async function readLifecycleRows(db: Db, sessionId: string): Promise<MirroredRow[]> {
  const rows = (await db.execute(sql`
    SELECT seq, type, payload, ts
    FROM ${sessionEventMirror}
    WHERE session_id = ${sessionId}
      AND type IN (${sql.join(LIFECYCLE_TYPES.map((type) => sql`${type}`), sql`, `)})
      AND seq ~ ${SEQ_RE.source}
    ORDER BY
      split_part(seq, '-', 1)::bigint ASC,
      COALESCE(NULLIF(split_part(seq, '-', 2), '')::bigint, 0) ASC
    LIMIT ${SUBAGENT_ROSTER_MAX_EVENTS + 1}
  `)) as unknown as MirroredRow[];
  if (rows.length > SUBAGENT_ROSTER_MAX_EVENTS) {
    throw new SubagentRosterTooLargeError("Subagent roster exceeds its bounded event scan");
  }
  return rows;
}

/** Owner authorization is the caller's responsibility; this read is side-effect free. */
export async function readSubagentRosterSession(
  db: Db,
  input: SubagentRosterQuery,
): Promise<SubagentSessionProjection> {
  const all = projectSubagentLifecycle(await readLifecycleRows(db, input.sessionId));
  return paginateSubagentRoster(all, input);
}
