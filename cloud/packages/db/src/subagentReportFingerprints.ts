import { createHash } from "node:crypto";

import {
  structuredSubagentReportSchema,
  type StructuredSubagentReport,
} from "@ovid/shared";

export interface SubagentReportTerminalIdentity {
  logicalWorkerId: string;
  childSessionId: string;
  /** Immutable initial child run identity; settlement-turn CAS is owned elsewhere. */
  childRunId: string;
  agentType: string;
  status: StructuredSubagentReport["status"];
  rootTaskRunId: string;
  executionEpoch: number;
}

export interface SubagentReportFingerprintInput {
  attemptId: string;
  terminal: SubagentReportTerminalIdentity;
  summary: string;
  /** Already normalized by the shared six-key builder/normalizer; null = unknown. */
  structuredReport: StructuredSubagentReport | null;
}

function requiredString(value: unknown, field: string): asserts value is string {
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`Subagent report fingerprint ${field} is required`);
  }
}

function canonicalStructured(
  value: StructuredSubagentReport,
  terminal: SubagentReportTerminalIdentity,
): StructuredSubagentReport {
  const parsed = structuredSubagentReportSchema.parse(value);
  if (parsed.subagent_id !== terminal.childSessionId) {
    throw new Error("Structured report subagent_id does not match terminal child identity");
  }
  if (parsed.status !== terminal.status) {
    throw new Error("Structured report status does not match canonical terminal status");
  }
  // Fixed key order is canonicalization only. Observed arrays retain their
  // normalized order; this helper never invents bounds, entries, or metadata.
  return {
    subagent_id: parsed.subagent_id,
    status: parsed.status,
    files_modified: parsed.files_modified,
    artifacts_created: parsed.artifacts_created,
    key_findings: parsed.key_findings,
    error_if_any: parsed.error_if_any,
  };
}

/**
 * Deterministic canonical content for root-CAS/outbox comparisons. No schema,
 * migration, timestamp, task text, or local pre-settlement outcome is added.
 */
export function canonicalSubagentReportContent(
  input: SubagentReportFingerprintInput,
): string {
  requiredString(input.attemptId, "attemptId");
  requiredString(input.terminal.logicalWorkerId, "logicalWorkerId");
  requiredString(input.terminal.childSessionId, "childSessionId");
  requiredString(input.terminal.childRunId, "childRunId");
  requiredString(input.terminal.agentType, "agentType");
  requiredString(input.terminal.rootTaskRunId, "rootTaskRunId");
  if (!["completed", "failed", "cancelled", "timeout"].includes(input.terminal.status)) {
    throw new Error("Subagent report fingerprint terminal status is invalid");
  }
  if (!Number.isInteger(input.terminal.executionEpoch) || input.terminal.executionEpoch < 1) {
    throw new Error("Subagent report fingerprint executionEpoch must be positive");
  }
  if (typeof input.summary !== "string") {
    throw new Error("Subagent report fingerprint summary must be a string");
  }
  const structuredReport = input.structuredReport === null
    ? null
    : canonicalStructured(input.structuredReport, input.terminal);
  return JSON.stringify({
    version: 1,
    attemptId: input.attemptId,
    terminal: {
      logicalWorkerId: input.terminal.logicalWorkerId,
      childSessionId: input.terminal.childSessionId,
      childRunId: input.terminal.childRunId,
      agentType: input.terminal.agentType,
      status: input.terminal.status,
      rootTaskRunId: input.terminal.rootTaskRunId,
      executionEpoch: input.terminal.executionEpoch,
    },
    summary: input.summary,
    structuredReport,
  });
}

/** Domain-separated SHA-256 over the exact canonical content above. */
export function subagentReportContentFingerprint(
  input: SubagentReportFingerprintInput,
): string {
  const digest = createHash("sha256")
    .update("ovid:subagent-report-content:v1\u0000", "utf8")
    .update(canonicalSubagentReportContent(input), "utf8")
    .digest("hex");
  return `sha256:${digest}`;
}
