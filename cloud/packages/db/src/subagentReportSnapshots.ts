import { createHash } from "node:crypto";
import { inArray } from "drizzle-orm";

import type { Db } from "./client.js";
import { subagentAttempts } from "./schema.js";
import { subagentReportContentFingerprint } from "./subagentReportFingerprints.js";
import type { SubagentReportRecord } from "./subagentAdmission.js";

export { subagentReportContentFingerprint } from "./subagentReportFingerprints.js";

export type DurableSubagentReportTransaction =
  Parameters<Parameters<Db["transaction"]>[0]>[0];

export type SubagentReportFingerprintRecord = Omit<
  DurableSubagentReportRecord,
  "task" | "at"
>;

/** Canonical per-report content; this exact value is also the outbox input. */
export function fingerprintSubagentReport(
  report: SubagentReportFingerprintRecord,
): string {
  return subagentReportContentFingerprint({
    attemptId: report.attemptId,
    terminal: {
      logicalWorkerId: report.logicalWorkerId,
      childSessionId: report.childSessionId,
      childRunId: report.childRunId,
      agentType: report.agentType,
      status: report.status,
      rootTaskRunId: report.rootTaskRunId,
      executionEpoch: report.executionEpoch,
    },
    summary: report.summary,
    structuredReport: report.structuredReport ?? null,
  });
}

/** Separate aggregate semantics over ordered canonical per-report hashes. */
export function fingerprintRootFinalizationReports(
  reports: readonly SubagentReportFingerprintRecord[],
): string {
  return createHash("sha256")
    .update(JSON.stringify([...reports]
      .sort((a, b) => a.attemptId < b.attemptId ? -1 : a.attemptId > b.attemptId ? 1 : 0)
      .map(fingerprintSubagentReport)))
    .digest("hex");
}

export interface DurableSubagentReportRecord extends SubagentReportRecord {
  rootTaskRunId: string;
  executionEpoch: number;
}

export interface DurableSubagentReportReadInput {
  sessionId: string;
  rootTaskRunId?: string;
  executionEpoch?: number;
  /** Task 5 drainReports page bound, 1..50 (default 50). */
  pageSize?: number;
}

export type DurableSubagentReportPageReader = (
  db: Db,
  input: { sessionId: string; afterId?: string; limit: number },
) => Promise<{ items: SubagentReportRecord[]; nextCursor: string | null }>;

function checkedPageSize(value: number | undefined): number {
  const pageSize = value ?? 50;
  if (!Number.isInteger(pageSize) || pageSize < 1 || pageSize > 50) {
    throw new RangeError("Report page size must be an integer from 1 to 50");
  }
  return pageSize;
}

/**
 * Read every visible report from the beginning inside the caller's transaction.
 * The cursor is local to this complete scan and is never persisted as delivery
 * authority, so the next scan revisits late commits below any earlier UUIDv7.
 *
 * `readPage` is the real Task 5 drainReports at both production call sites. It
 * is injected to keep this shared DB reader independent of subagentAdmission's
 * finalization consumer; there is no subagentAdmission -> reader -> admission
 * runtime cycle and no @ovid/db -> @ovid/agent-core dependency.
 */
export async function readDurableSubagentReportSnapshotWithin(
  tx: DurableSubagentReportTransaction,
  input: DurableSubagentReportReadInput,
  readPage: DurableSubagentReportPageReader,
): Promise<DurableSubagentReportRecord[]> {
  const pageSize = checkedPageSize(input.pageSize);
  const records: SubagentReportRecord[] = [];
  let afterId: string | undefined;
  for (;;) {
    const page = await readPage(tx as unknown as Db, {
      sessionId: input.sessionId,
      ...(afterId !== undefined ? { afterId } : {}),
      limit: pageSize,
    });
    records.push(...page.items);
    if (page.nextCursor === null) break;
    if (page.items.length === 0 || (afterId !== undefined && page.nextCursor <= afterId)) {
      throw new Error("Durable report cursor did not advance within its read snapshot");
    }
    afterId = page.nextCursor;
  }
  if (records.length === 0) return [];

  const attemptIds = [...new Set(records.map((report) => report.attemptId))];
  const attempts = await tx
    .select({
      id: subagentAttempts.id,
      rootTaskRunId: subagentAttempts.rootTaskRunId,
      executionEpoch: subagentAttempts.executionEpoch,
      status: subagentAttempts.status,
    })
    .from(subagentAttempts)
    .where(inArray(subagentAttempts.id, attemptIds));
  const lineage = new Map(attempts.map((attempt) => [attempt.id, attempt]));
  const reports: DurableSubagentReportRecord[] = [];
  for (const record of records) {
    const attempt = lineage.get(record.attemptId);
    if (attempt === undefined) {
      throw new Error(`Missing durable lineage for attempt ${record.attemptId}`);
    }
    if (input.rootTaskRunId !== undefined && attempt.rootTaskRunId !== input.rootTaskRunId) {
      continue;
    }
    if (input.executionEpoch !== undefined && attempt.executionEpoch !== input.executionEpoch) {
      continue;
    }
    if (attempt.status !== record.status) {
      throw new Error(`Canonical terminal outcome mismatch for attempt ${record.attemptId}`);
    }
    reports.push({
      ...record,
      rootTaskRunId: attempt.rootTaskRunId,
      executionEpoch: attempt.executionEpoch,
    });
  }
  return reports;
}

/** Complete report backfill under one standalone repeatable-read snapshot. */
export async function readDurableSubagentReportSnapshot(
  db: Db,
  input: DurableSubagentReportReadInput,
  readPage: DurableSubagentReportPageReader,
): Promise<DurableSubagentReportRecord[]> {
  return db.transaction(
    async (tx) => readDurableSubagentReportSnapshotWithin(tx, input, readPage),
    { isolationLevel: "repeatable read" },
  );
}
