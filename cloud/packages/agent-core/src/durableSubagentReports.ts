import { createHash } from "node:crypto";

import {
  drainReports,
  readDurableSubagentReportSnapshot as readDbSubagentReportSnapshot,
  readDurableSubagentReportSnapshotWithin as readDbSubagentReportSnapshotWithin,
  zeroSessionAgentState,
  type Db,
  type DurableSubagentReportReadInput,
  type DurableSubagentReportRecord,
  type DurableSubagentReportTransaction,
} from "@ovid/db";
import {
  structuredSubagentReportSchema,
  type StructuredSubagentReport,
} from "@ovid/shared";

import {
  formatSubagentReports,
  type SubagentReport,
} from "./subagents.js";

/**
 * Delivery evidence lives in session_agent_state under this separate key, not
 * the legacy pendingSubagentReports queue. One stable system-history message is
 * refreshed in place; loop composition replaces that row by its exported ID.
 */
export const DURABLE_SUBAGENT_REPORT_CONTEXT_KEY = "durableSubagentReportContextV1";
export const DURABLE_SUBAGENT_REPORT_MESSAGE_CLIENT_ID = "subagent-report-context/v1";

/** Stable history-row identity used by loop composition to replace, never duplicate. */
export function durableSubagentReportMessageId(sessionId: string): string {
  const hex = createHash("sha256")
    .update(`subagent-report-message/v1/${sessionId}`, "utf8")
    .digest("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-7${hex.slice(13, 16)}-` +
    `a${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
}

export type {
  DurableSubagentReportReadInput,
  DurableSubagentReportTransaction,
} from "@ovid/db";

export type DurableSubagentReport = DurableSubagentReportRecord;

export interface DurableSubagentReportInjection {
  sessionId: string;
  idempotencyKey: string;
  /** One formatSubagentReports call for the complete batch, not per-report text. */
  content: string;
  reports: readonly DurableSubagentReport[];
}

export type DurableSubagentReportInjectionOutcome =
  | "injected"
  | "refreshed"
  | "replayed";

export interface DurableSubagentReportInjectionResult {
  outcome: DurableSubagentReportInjectionOutcome;
  content: string;
  reports: DurableSubagentReport[];
}

export interface DurableSubagentReportAck {
  sessionId: string;
  idempotencyKey: string;
  content: string;
  reports: readonly DurableSubagentReport[];
}

export interface DurableSubagentReportStore {
  readSnapshot(input: {
    sessionId: string;
    pageSize?: number;
  }): Promise<DurableSubagentReport[]>;
  inject(input: DurableSubagentReportInjection): Promise<DurableSubagentReportInjectionResult>;
  acknowledge(input: DurableSubagentReportAck): Promise<void>;
}

export interface DurableSubagentReportDrainInput {
  sessionId: string;
}

export interface DurableSubagentReportDrainResult {
  reports: DurableSubagentReport[];
  /** Null only for an empty drain; otherwise the exact legacy batch block. */
  content: string | null;
  /** Batch context outcomes, not a count of model calls or autonomous runs. */
  injected: number;
  refreshed: number;
  replayed: number;
}

export interface DurableSubagentReportDrain {
  drain(input: DurableSubagentReportDrainInput): Promise<DurableSubagentReportDrainResult>;
}

export interface DurableSubagentReportDrainOptions {
  pageSize?: number;
}

interface PersistedContextV1 {
  version: 1;
  sessionId: string;
  idempotencyKey: string;
  content: string;
  reports: DurableSubagentReport[];
  messageId: string;
  acknowledged: boolean;
}

function checkedPageSize(value: number | undefined): number {
  const pageSize = value ?? 50;
  if (!Number.isInteger(pageSize) || pageSize < 1 || pageSize > 50) {
    throw new RangeError("Report page size must be an integer from 1 to 50");
  }
  return pageSize;
}

function contextKey(sessionId: string): string {
  return `subagent-report-context/v1/${sessionId}`;
}

function canonicalReport(report: DurableSubagentReport): DurableSubagentReport {
  return {
    logicalWorkerId: report.logicalWorkerId,
    attemptId: report.attemptId,
    childSessionId: report.childSessionId,
    childRunId: report.childRunId,
    agentType: report.agentType,
    status: report.status,
    summary: report.summary,
    task: report.task,
    at: report.at,
    rootTaskRunId: report.rootTaskRunId,
    executionEpoch: report.executionEpoch,
    ...(report.structuredReport !== undefined
      ? { structuredReport: report.structuredReport }
      : {}),
  };
}

function parseReport(value: unknown): DurableSubagentReport {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("Invalid durable subagent report payload");
  }
  const candidate = value as Record<string, unknown>;
  const stringFields = [
    "logicalWorkerId",
    "attemptId",
    "childSessionId",
    "childRunId",
    "agentType",
    "summary",
    "task",
    "rootTaskRunId",
  ] as const;
  for (const field of stringFields) {
    if (typeof candidate[field] !== "string") {
      throw new Error(`Invalid durable subagent report ${field}`);
    }
  }
  if (!["completed", "failed", "cancelled", "timeout"].includes(String(candidate.status))) {
    throw new Error("Invalid durable subagent terminal outcome");
  }
  if (typeof candidate.at !== "number" || !Number.isFinite(candidate.at)) {
    throw new Error("Invalid durable subagent report timestamp");
  }
  if (
    typeof candidate.executionEpoch !== "number" ||
    !Number.isInteger(candidate.executionEpoch) ||
    candidate.executionEpoch < 1
  ) {
    throw new Error("Invalid durable subagent execution epoch");
  }
  const structured = candidate.structuredReport === undefined
    ? undefined
    : structuredSubagentReportSchema.parse(candidate.structuredReport);
  const report = canonicalReport({
    ...candidate,
    status: candidate.status,
    ...(structured !== undefined ? { structuredReport: structured } : {}),
  } as DurableSubagentReport);
  if (
    report.rootTaskRunId.trim() === "" ||
    (structured !== undefined &&
      (structured.subagent_id !== report.childSessionId || structured.status !== report.status))
  ) {
    throw new Error("Structured report identity does not match canonical terminal identity");
  }
  return report;
}

function reportFingerprint(report: DurableSubagentReport): string {
  return JSON.stringify(canonicalReport(report));
}

function contextFingerprint(
  content: string,
  reports: readonly DurableSubagentReport[],
): string {
  return JSON.stringify({ content, reports: reports.map(canonicalReport) });
}

function assertSameTerminalIdentity(
  previous: DurableSubagentReport,
  current: DurableSubagentReport,
): void {
  if (previous.status !== current.status) {
    throw new Error(`Conflicting durable terminal outcome for attempt ${current.attemptId}`);
  }
  const fields = [
    "logicalWorkerId",
    "attemptId",
    "childSessionId",
    "childRunId",
    "agentType",
    "task",
    "at",
    "rootTaskRunId",
    "executionEpoch",
  ] as const;
  for (const field of fields) {
    if (previous[field] !== current[field]) {
      throw new Error(`Conflicting durable report identity for attempt ${current.attemptId}`);
    }
  }
}

function additiveList(previous: readonly string[], current: readonly string[]): boolean {
  const available = new Set(current);
  return previous.every((item) => available.has(item));
}

function structuredEnrichment(
  previous: StructuredSubagentReport | undefined,
  current: StructuredSubagentReport | undefined,
): "same" | "additive" | "conflict" {
  if (JSON.stringify(previous) === JSON.stringify(current)) return "same";
  if (previous === undefined) return current === undefined ? "same" : "additive";
  if (current === undefined) return "conflict";
  if (previous.subagent_id !== current.subagent_id || previous.status !== current.status) {
    return "conflict";
  }
  const findingsAdditive = current.key_findings === previous.key_findings ||
    current.key_findings.startsWith(previous.key_findings);
  const errorAdditive = current.error_if_any === previous.error_if_any ||
    (previous.error_if_any === null && current.error_if_any !== null);
  return additiveList(previous.files_modified, current.files_modified) &&
      additiveList(previous.artifacts_created, current.artifacts_created) &&
      findingsAdditive && errorAdditive
    ? "additive"
    : "conflict";
}

function isAdditiveEnrichment(
  previous: DurableSubagentReport,
  current: DurableSubagentReport,
): boolean {
  const structured = structuredEnrichment(previous.structuredReport, current.structuredReport);
  if (structured === "conflict") return false;
  // The real lifecycle first inserts canonical summary/null structure, then
  // enriches both. Initial/additive structure authorizes that summary refresh.
  // With unchanged structure, only non-regressive summary extension is valid.
  const initialStructuredEnrichment = previous.structuredReport === undefined &&
    current.structuredReport !== undefined && structured === "additive";
  return current.summary === previous.summary ||
    current.summary.startsWith(previous.summary) ||
    initialStructuredEnrichment;
}

function mergeReportEnrichment(
  previousValue: DurableSubagentReport,
  currentValue: DurableSubagentReport,
): DurableSubagentReport {
  const previous = parseReport(previousValue);
  const current = parseReport(currentValue);
  assertSameTerminalIdentity(previous, current);
  if (reportFingerprint(previous) === reportFingerprint(current)) return current;
  if (isAdditiveEnrichment(previous, current)) return current;
  // A concurrent drainer can hold an older repeatable-read snapshot. Preserve
  // the already enriched version rather than failing forever or regressing it.
  if (isAdditiveEnrichment(current, previous)) return previous;
  throw new Error(`Conflicting durable report enrichment for attempt ${current.attemptId}`);
}

/**
 * Union by attempt/root/epoch while retaining every distinct terminal attempt.
 * Only additive summary/six-key enrichment may replace an earlier payload.
 */
export function mergeDurableSubagentReports(
  previous: readonly DurableSubagentReport[],
  current: readonly DurableSubagentReport[],
): DurableSubagentReport[] {
  const previousByAttempt = new Map<string, DurableSubagentReport>();
  for (const raw of previous) {
    const report = parseReport(raw);
    const existing = previousByAttempt.get(report.attemptId);
    previousByAttempt.set(
      report.attemptId,
      existing === undefined ? report : mergeReportEnrichment(existing, report),
    );
  }

  const merged: DurableSubagentReport[] = [];
  const indexes = new Map<string, number>();
  for (const raw of current) {
    const report = parseReport(raw);
    const existing = indexes.get(report.attemptId);
    if (existing !== undefined) {
      merged[existing] = mergeReportEnrichment(merged[existing]!, report);
      continue;
    }
    const prior = previousByAttempt.get(report.attemptId);
    indexes.set(report.attemptId, merged.length);
    merged.push(prior === undefined ? report : mergeReportEnrichment(prior, report));
  }
  // A concurrent snapshot can legitimately lack a just-committed row. Retain
  // prior deliveries missing from it rather than treating a stale read as delete.
  for (const [attemptId, report] of previousByAttempt) {
    if (!indexes.has(attemptId)) {
      indexes.set(attemptId, merged.length);
      merged.push(report);
    }
  }
  return merged.map(canonicalReport);
}

/** Exactly one legacy formatter invocation for the entire multi-report batch. */
export function formatDurableSubagentReports(
  reports: readonly DurableSubagentReport[],
): string {
  const compatible: SubagentReport[] = reports.map((report) => ({
    childSessionId: report.childSessionId,
    childRunId: report.childRunId,
    agentType: report.agentType,
    // Task 5 adds timeout; the legacy formatter prints status without branching.
    status: report.status as SubagentReport["status"],
    summary: report.summary,
    task: report.task,
    at: report.at,
  }));
  return formatSubagentReports(compatible);
}

/** Agent-core's binding to the complete DB-local repeatable-read/backfill reader. */
export async function readDurableSubagentReportSnapshotWithin(
  tx: DurableSubagentReportTransaction,
  input: DurableSubagentReportReadInput,
): Promise<DurableSubagentReport[]> {
  return readDbSubagentReportSnapshotWithin(tx, input, drainReports);
}

/** Complete, transactionally visible Task 5 backfill for production/finalization. */
export async function readDurableSubagentReportSnapshot(
  db: Db,
  input: DurableSubagentReportReadInput,
): Promise<DurableSubagentReport[]> {
  return readDbSubagentReportSnapshot(db, input, drainReports);
}

function parseContext(value: unknown, sessionId: string): PersistedContextV1 | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Invalid durable subagent report context");
  }
  const candidate = value as Record<string, unknown>;
  if (
    candidate.version !== 1 ||
    candidate.sessionId !== sessionId ||
    candidate.idempotencyKey !== contextKey(sessionId) ||
    candidate.messageId !== durableSubagentReportMessageId(sessionId) ||
    typeof candidate.content !== "string" ||
    typeof candidate.acknowledged !== "boolean" ||
    !Array.isArray(candidate.reports)
  ) {
    throw new Error("Invalid durable subagent report context metadata");
  }
  const reports = mergeDurableSubagentReports(
    [],
    candidate.reports as DurableSubagentReport[],
  );
  const content = formatDurableSubagentReports(reports);
  if (candidate.content !== content) {
    throw new Error("Durable subagent report context content is inconsistent");
  }
  return {
    version: 1,
    sessionId,
    idempotencyKey: contextKey(sessionId),
    content,
    reports,
    messageId: durableSubagentReportMessageId(sessionId),
    acknowledged: candidate.acknowledged,
  };
}

type RawClient = Db["$client"];

async function lockContext(client: RawClient, sessionId: string): Promise<void> {
  await client`
    SELECT pg_advisory_xact_lock(hashtextextended(${`durable-subagent-reports:${sessionId}`}, 0))`;
}

async function readContext(
  client: RawClient,
  sessionId: string,
): Promise<PersistedContextV1 | null> {
  const rows = await client<[{ state: Record<string, unknown> }?]>`
    SELECT state FROM session_agent_state WHERE session_id = ${sessionId}
    LIMIT 1 FOR UPDATE`;
  return parseContext(rows[0]?.state[DURABLE_SUBAGENT_REPORT_CONTEXT_KEY], sessionId);
}

async function messageMatches(
  client: RawClient,
  context: PersistedContextV1,
): Promise<boolean> {
  const rows = await client<[{
    role: string;
    clientMsgId: string | null;
    content: string;
  }?]>`
    SELECT role, client_msg_id AS "clientMsgId", content FROM messages
    WHERE id = ${context.messageId} AND session_id = ${context.sessionId}
    LIMIT 1 FOR UPDATE`;
  const message = rows[0];
  if (message === undefined) return false;
  if (message.role !== "system" || message.clientMsgId !== DURABLE_SUBAGENT_REPORT_MESSAGE_CLIENT_ID) {
    throw new Error("Durable report message identity collision");
  }
  return message.content === context.content;
}

async function writeMessage(client: RawClient, context: PersistedContextV1): Promise<void> {
  const existing = await client<[{ id: string; role: string; content: string }?]>`
    SELECT id, role, content FROM messages
    WHERE session_id = ${context.sessionId}
      AND client_msg_id = ${DURABLE_SUBAGENT_REPORT_MESSAGE_CLIENT_ID}
    LIMIT 1 FOR UPDATE`;
  if (existing[0] !== undefined) {
    if (existing[0].id !== context.messageId || existing[0].role !== "system") {
      throw new Error("Durable report message identity collision");
    }
    if (existing[0].content !== context.content) {
      await client`
        UPDATE messages SET content = ${context.content} WHERE id = ${context.messageId}`;
    }
    return;
  }
  await client`
    INSERT INTO messages (id, session_id, role, content, client_msg_id)
    VALUES (
      ${context.messageId}, ${context.sessionId}, 'system', ${context.content},
      ${DURABLE_SUBAGENT_REPORT_MESSAGE_CLIENT_ID}
    )`;
}

async function writeContext(client: RawClient, context: PersistedContextV1): Promise<void> {
  const patch = { [DURABLE_SUBAGENT_REPORT_CONTEXT_KEY]: context };
  const initial = JSON.stringify({ ...zeroSessionAgentState(), ...patch });
  const patchJson = JSON.stringify(patch);
  await client`
    INSERT INTO session_agent_state (session_id, state)
    VALUES (${context.sessionId}, ${initial}::jsonb)
    ON CONFLICT (session_id) DO UPDATE
    SET state = COALESCE(session_agent_state.state, '{}'::jsonb) || ${patchJson}::jsonb`;
}

/**
 * Actual Postgres store. It calls the real @ovid/db drainReports reader above;
 * no fake, worker import, migration, or lossy in-memory queue is involved.
 * session_agent_state's primary key, messages'(session,client_msg_id) unique
 * index, and the per-session transaction lock provide one durable context and
 * one stable history message with atomic idempotent injection/ack evidence.
 */
export function createPostgresDurableSubagentReportStore(
  db: Db,
  options: DurableSubagentReportDrainOptions = {},
): DurableSubagentReportStore {
  const defaultPageSize = checkedPageSize(options.pageSize);
  return {
    readSnapshot(input) {
      return readDurableSubagentReportSnapshot(db, {
        sessionId: input.sessionId,
        pageSize: input.pageSize ?? defaultPageSize,
      });
    },

    async inject(input) {
      if (input.reports.length === 0) throw new Error("Cannot inject an empty report context");
      if (input.idempotencyKey !== contextKey(input.sessionId)) {
        throw new Error("Durable report injection key does not match its session");
      }
      const inputReports = mergeDurableSubagentReports([], input.reports);
      if (input.content !== formatDurableSubagentReports(inputReports)) {
        throw new Error("Durable report injection content is not the exact legacy batch");
      }
      return db.$client.begin(async (tx): Promise<DurableSubagentReportInjectionResult> => {
        const client = tx as unknown as RawClient;
        await lockContext(client, input.sessionId);
        const previous = await readContext(client, input.sessionId);
        const reports = mergeDurableSubagentReports(previous?.reports ?? [], inputReports);
        const content = formatDurableSubagentReports(reports);
        let outcome: DurableSubagentReportInjectionOutcome = previous === null
          ? "injected"
          : contextFingerprint(previous.content, previous.reports) ===
              contextFingerprint(content, reports)
            ? "replayed"
            : "refreshed";
        const context: PersistedContextV1 = {
          version: 1,
          sessionId: input.sessionId,
          idempotencyKey: input.idempotencyKey,
          content,
          reports,
          messageId: durableSubagentReportMessageId(input.sessionId),
          acknowledged: outcome === "replayed" ? previous?.acknowledged ?? false : false,
        };
        const messageReady = await messageMatches(client, context);
        if (outcome === "replayed" && !messageReady) outcome = "refreshed";
        if (outcome !== "replayed") {
          context.acknowledged = false;
          await writeMessage(client, context);
          await writeContext(client, context);
        }
        return { outcome, content, reports };
      });
    },

    async acknowledge(input) {
      if (input.idempotencyKey !== contextKey(input.sessionId)) {
        throw new Error("Durable report acknowledgement key does not match its session");
      }
      await db.$client.begin(async (tx) => {
        const client = tx as unknown as RawClient;
        await lockContext(client, input.sessionId);
        const current = await readContext(client, input.sessionId);
        if (
          current === null ||
          contextFingerprint(current.content, current.reports) !==
            contextFingerprint(input.content, input.reports) ||
          !(await messageMatches(client, current))
        ) {
          throw new Error("Durable report acknowledgement has no matching injected context");
        }
        if (!current.acknowledged) await writeContext(client, { ...current, acknowledged: true });
      });
    },
  };
}

/**
 * durableSubagentReportLoop.ts composes this service over the production DB
 * store. Its projection removes the stable history copy and supplies exactly
 * one refreshed volatile batch; the stable persisted message makes restart
 * injection durable. No legacy fallback, final synthesis, wake, deferred start,
 * or resume is performed by this drain.
 */
export function createDurableSubagentReportDrain(
  store: DurableSubagentReportStore,
  options: DurableSubagentReportDrainOptions = {},
): DurableSubagentReportDrain {
  const pageSize = checkedPageSize(options.pageSize);
  return {
    async drain({ sessionId }) {
      const snapshot = await store.readSnapshot({ sessionId, pageSize });
      if (snapshot.length === 0) {
        return { reports: [], content: null, injected: 0, refreshed: 0, replayed: 0 };
      }
      const reports = mergeDurableSubagentReports([], snapshot);
      const idempotencyKey = contextKey(sessionId);
      const injection = await store.inject({
        sessionId,
        idempotencyKey,
        content: formatDurableSubagentReports(reports),
        reports,
      });
      await store.acknowledge({
        sessionId,
        idempotencyKey,
        content: injection.content,
        reports: injection.reports,
      });
      return {
        reports: injection.reports,
        content: injection.content,
        injected: injection.outcome === "injected" ? 1 : 0,
        refreshed: injection.outcome === "refreshed" ? 1 : 0,
        replayed: injection.outcome === "replayed" ? 1 : 0,
      };
    },
  };
}
