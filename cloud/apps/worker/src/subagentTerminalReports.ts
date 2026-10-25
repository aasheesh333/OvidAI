import type { StructuredSubagentReport } from "@ovid/shared";

import type { SubagentObservationFinal } from "./subagentObservations.js";
import type { VerifiedCheckpoint } from "./subagentResources.js";

export interface SubagentTerminalIdentity {
  attemptId: string;
  logicalWorkerId: string;
  childSessionId: string;
  /** Immutable initial child run, not the settlement/follow-up turn. */
  childRunId: string;
  agentType: string;
  rootTaskRunId: string;
  executionEpoch: number;
}

export type SubagentTerminalStatus = StructuredSubagentReport["status"];

export interface SubagentCanonicalTerminalReport extends SubagentTerminalIdentity {
  status: SubagentTerminalStatus;
  summary: string;
  /** Unknown coverage stays null; no synthetic empty-observation report. */
  structuredReport: StructuredSubagentReport | null;
}

export interface SubagentTerminalReportInput {
  /** Already-fenced canonical attempt identity supplied by the settlement seam. */
  identity: SubagentTerminalIdentity;
  /** The already-selected canonical turn; never rediscovered by this composer. */
  settlementTurnRunId: string;
  status: SubagentTerminalStatus;
  /** Authoritative latest-turn error, not a local/summary-derived error. */
  error: string | null;
  /** The just-created canonical base row, before root/wake/final work. */
  baseReport: SubagentCanonicalTerminalReport;
}

export interface SubagentTerminalObservationPort {
  /** Bound to the settlement transaction's close/read; no producer execution. */
  close(input: {
    attemptId: string;
    settlementTurnRunId: string;
  }): Promise<SubagentObservationFinal>;
}

export interface SubagentTerminalReportStore {
  /** Transaction-scoped final write; no settlement, outbox, wake, or SQL is done here. */
  putFinal(report: SubagentCanonicalTerminalReport): Promise<void>;
  /** Exact-attempt readback in that same transaction. */
  readFinal(attemptId: string): Promise<SubagentCanonicalTerminalReport | null>;
}

export interface SubagentTerminalCheckpointPort {
  /** Same-transaction shared latest persisted/verified checkpoint lookup. Null is verified absence. */
  latestVerified(attemptId: string): Promise<VerifiedCheckpoint | null>;
}

export interface SubagentTerminalBuilderInput {
  subagentId: string;
  status: SubagentTerminalStatus;
  answer: string | null;
  error: string | null;
  observedFiles: readonly string[];
  observedArtifacts: readonly string[];
  checkpoint?: VerifiedCheckpoint | null;
}

export interface SubagentTerminalBuiltReport {
  summary: string;
  structuredReport: StructuredSubagentReport;
  checkpoint: VerifiedCheckpoint | null;
}

export interface SubagentTerminalReportDeps {
  observations: SubagentTerminalObservationPort;
  reports: SubagentTerminalReportStore;
  checkpoints: SubagentTerminalCheckpointPort;
  /** The real agent-core buildSubagentReport, supplied by composition. */
  buildReport(input: SubagentTerminalBuilderInput): SubagentTerminalBuiltReport;
  /** The same agent-core content normalization used by the builder. */
  normalizeReport(input: {
    summary: string;
    status: SubagentTerminalStatus;
    structuredReport: StructuredSubagentReport | null;
  }): {
    summary: string;
    structuredReport: StructuredSubagentReport | null;
  };
  normalizeSummary(input: {
    summary: string;
    status: SubagentTerminalStatus;
    checkpoint: VerifiedCheckpoint | null;
  }): string;
}

export interface SubagentTerminalReportComposition {
  coverage: "ready" | "unknown_final";
  /** The validated committed readback, not an unpersisted candidate. */
  report: SubagentCanonicalTerminalReport;
  /** Undefined outside timeout; null only after lookup proves absence. */
  checkpoint: VerifiedCheckpoint | null | undefined;
}

export type SubagentTerminalReportErrorCode =
  | "canonical_mismatch"
  | "readback_mismatch";

export class SubagentTerminalReportError extends Error {
  readonly name = "SubagentTerminalReportError";
  constructor(
    readonly code: SubagentTerminalReportErrorCode,
    message: string,
  ) {
    super(message);
  }
}

const STATUSES = new Set<SubagentTerminalStatus>([
  "completed",
  "failed",
  "cancelled",
  "timeout",
]);
const SIX_KEYS = [
  "artifacts_created",
  "error_if_any",
  "files_modified",
  "key_findings",
  "status",
  "subagent_id",
];
const IDENTITY_FIELDS = [
  "attemptId",
  "logicalWorkerId",
  "childSessionId",
  "childRunId",
  "agentType",
  "rootTaskRunId",
  "executionEpoch",
] as const;

function canonicalMismatch(message: string): never {
  throw new SubagentTerminalReportError("canonical_mismatch", message);
}

function readbackMismatch(message: string): never {
  throw new SubagentTerminalReportError("readback_mismatch", message);
}

function assertIdentity(identity: SubagentTerminalIdentity): void {
  for (const field of IDENTITY_FIELDS) {
    const value = identity[field];
    if (field === "executionEpoch") {
      if (!Number.isInteger(value as number) || (value as number) < 1) {
        canonicalMismatch("Canonical execution epoch must be a positive integer");
      }
    } else if (typeof value !== "string" || value.trim() === "") {
      canonicalMismatch(`Canonical ${field} is required`);
    }
  }
}

function sameIdentity(
  left: SubagentTerminalIdentity,
  right: SubagentTerminalIdentity,
): boolean {
  return IDENTITY_FIELDS.every((field) => left[field] === right[field]);
}

function validateInput(input: SubagentTerminalReportInput): void {
  assertIdentity(input.identity);
  if (typeof input.settlementTurnRunId !== "string" || input.settlementTurnRunId.trim() === "") {
    canonicalMismatch("Exact settlement turn is required");
  }
  if (!STATUSES.has(input.status)) canonicalMismatch("Unknown canonical terminal status");
  if (input.error !== null && typeof input.error !== "string") {
    canonicalMismatch("Canonical error must be a string or null");
  }
  if (!sameIdentity(input.identity, input.baseReport)) {
    canonicalMismatch("Base report identity does not match canonical attempt identity");
  }
  if (input.baseReport.status !== input.status) {
    canonicalMismatch("Base report status does not match canonical latest-turn status");
  }
  if (typeof input.baseReport.summary !== "string") {
    canonicalMismatch("Canonical base summary must be a string");
  }
  if (input.baseReport.structuredReport !== null) {
    canonicalMismatch("Terminal composition requires the canonical pre-enrichment base report");
  }
}

function validateObservation(
  observation: SubagentObservationFinal,
  input: SubagentTerminalReportInput,
): void {
  if (observation.attemptId !== input.identity.attemptId ||
    observation.settlementTurnRunId !== input.settlementTurnRunId) {
    canonicalMismatch("Observation identity does not match the canonical settlement turn");
  }
  if (observation.status === "ready") {
    if (!Array.isArray(observation.observedFiles) ||
      !observation.observedFiles.every((item) => typeof item === "string") ||
      !Array.isArray(observation.observedArtifacts) ||
      !observation.observedArtifacts.every((item) => typeof item === "string")) {
      canonicalMismatch("Ready observation has malformed observed evidence");
    }
    if (observation.answer !== null &&
      (typeof observation.answer !== "object" ||
        typeof observation.answer.messageId !== "string" ||
        observation.answer.messageId.trim() === "" ||
        typeof observation.answer.content !== "string")) {
      canonicalMismatch("Ready observation has no exact assistant answer reference");
    }
  } else if (observation.status !== "unknown_final") {
    canonicalMismatch("Unknown observation coverage state");
  }
}

function comparable(report: SubagentCanonicalTerminalReport) {
  const structured = report.structuredReport;
  return {
    ...Object.fromEntries(IDENTITY_FIELDS.map((field) => [field, report[field]])),
    status: report.status,
    summary: report.summary,
    structuredReport: structured === null ? null : {
      subagent_id: structured.subagent_id,
      status: structured.status,
      files_modified: structured.files_modified,
      artifacts_created: structured.artifacts_created,
      key_findings: structured.key_findings,
      error_if_any: structured.error_if_any,
    },
  };
}

function validateReadback(
  expected: SubagentCanonicalTerminalReport,
  actual: SubagentCanonicalTerminalReport | null,
): asserts actual is SubagentCanonicalTerminalReport {
  if (actual === null || typeof actual !== "object") {
    readbackMismatch("Committed terminal report readback is missing");
  }
  if (!sameIdentity(expected, actual) || actual.status !== expected.status) {
    readbackMismatch("Committed terminal report identity or canonical status diverged");
  }
  const structured = actual.structuredReport;
  if (structured !== null && (typeof structured !== "object" || Array.isArray(structured))) {
    readbackMismatch("Committed structured report is malformed");
  }
  if (structured !== null) {
    if (Object.keys(structured).sort().join(",") !== SIX_KEYS.join(",")) {
      readbackMismatch("Committed structured report does not have exactly six keys");
    }
    if (structured.subagent_id !== actual.childSessionId ||
      structured.status !== actual.status) {
      readbackMismatch("Committed structured report identity diverged from its terminal report");
    }
  }
  if (JSON.stringify(comparable(expected)) !== JSON.stringify(comparable(actual))) {
    readbackMismatch("Committed terminal report content diverged from the normalized candidate");
  }
}

/**
 * Pure deterministic composition for the future in-settlement, pre-wake seam.
 * It performs no settlement/release/wake/scheduler/EventLog/outbox work. Every
 * port error is infrastructure failure and propagates so the caller can roll
 * back the entire settlement transaction; it is never converted to []/[].
 */
export async function composeSubagentTerminalReport(
  input: SubagentTerminalReportInput,
  deps: SubagentTerminalReportDeps,
): Promise<SubagentTerminalReportComposition> {
  validateInput(input);
  const observation = await deps.observations.close({
    attemptId: input.identity.attemptId,
    settlementTurnRunId: input.settlementTurnRunId,
  });
  validateObservation(observation, input);

  // An omitted local checkpoint never reaches the builder. Only this lookup
  // resolves a real checkpoint or verified absence for timeout composition.
  const checkpoint = input.status === "timeout"
    ? await deps.checkpoints.latestVerified(input.identity.attemptId)
    : undefined;

  let candidate: SubagentCanonicalTerminalReport;
  if (observation.status === "ready") {
    const built = deps.buildReport({
      subagentId: input.identity.childSessionId,
      status: input.status,
      answer: observation.answer?.content ?? null,
      error: input.error,
      observedFiles: observation.observedFiles,
      observedArtifacts: observation.observedArtifacts,
      checkpoint,
    });
    const normalized = deps.normalizeReport({
      summary: built.summary,
      status: input.status,
      structuredReport: built.structuredReport,
    });
    if (normalized.structuredReport === null) {
      canonicalMismatch("Ready observation did not produce a structured report");
    }
    candidate = {
      ...input.identity,
      status: input.status,
      summary: normalized.summary,
      structuredReport: normalized.structuredReport,
    };
  } else {
    candidate = {
      ...input.baseReport,
      summary: deps.normalizeSummary({
        summary: input.baseReport.summary,
        status: input.status,
        checkpoint: checkpoint ?? null,
      }),
      structuredReport: null,
    };
  }

  await deps.reports.putFinal(candidate);
  const committed = await deps.reports.readFinal(input.identity.attemptId);
  validateReadback(candidate, committed);
  return {
    coverage: observation.status,
    report: committed,
    checkpoint,
  };
}
