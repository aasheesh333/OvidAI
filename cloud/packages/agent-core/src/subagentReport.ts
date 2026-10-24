import type { StructuredSubagentReport } from "@ovid/shared";

import type { VerifiedCheckpoint } from "./subagentLifecycle.js";
import {
  REPORT_FAILURE_LIMIT,
  REPORT_SUMMARY_LIMIT,
} from "./subagents.js";

export { REPORT_FAILURE_LIMIT, REPORT_SUMMARY_LIMIT };

export const SUBAGENT_REPORT_OBSERVED_MAX_ITEMS = 100;
export const SUBAGENT_REPORT_OBSERVED_ITEM_MAX_CHARS = 512;
export const SUBAGENT_REPORT_OBSERVED_LIST_MAX_BYTES = 8_192;
export const SUBAGENT_REPORT_OBSERVED_AGGREGATE_MAX_BYTES = 16_384;

export type SubagentReportStatus = StructuredSubagentReport["status"];

export interface BuildSubagentReportInput {
  /** Supervisor-owned child session ID, never a model-supplied log path. */
  subagentId: string;
  status: SubagentReportStatus;
  answer: string | null;
  error: string | null;
  /** Actual observed writes/registrations only; prose is never searched for paths. */
  observedFiles: readonly string[];
  observedArtifacts: readonly string[];
  checkpoint?: VerifiedCheckpoint | null;
}

export interface BuiltSubagentReport {
  summary: string;
  structuredReport: StructuredSubagentReport;
  checkpoint: VerifiedCheckpoint | null;
}

function clip(text: string, maximum: number): string {
  const flat = text.trim();
  if (maximum <= 0) return "";
  if (flat.length <= maximum) return flat;
  if (maximum === 1) return "…";
  return `${flat.slice(0, maximum - 1)}…`;
}

interface ObservedEntry {
  value: string;
  clipped: boolean;
}

interface BoundedObserved {
  entries: ObservedEntry[];
  omitted: number;
}

function clipObservedItem(value: string): ObservedEntry {
  const normalized = value.trim();
  const characters = Array.from(normalized);
  if (characters.length <= SUBAGENT_REPORT_OBSERVED_ITEM_MAX_CHARS) {
    return { value: normalized, clipped: false };
  }
  return {
    value: `${characters.slice(0, SUBAGENT_REPORT_OBSERVED_ITEM_MAX_CHARS - 1).join("")}…`,
    clipped: true,
  };
}

function boundObserved(values: readonly string[]): BoundedObserved {
  const entries: ObservedEntry[] = [];
  const seen = new Set<string>();
  let omitted = 0;
  for (const raw of values) {
    const normalized = raw.trim();
    if (normalized === "" || seen.has(normalized)) continue;
    seen.add(normalized);
    const entry = clipObservedItem(normalized);
    if (entries.length >= SUBAGENT_REPORT_OBSERVED_MAX_ITEMS) {
      omitted += 1;
      continue;
    }
    const candidate = [...entries, entry];
    if (Buffer.byteLength(JSON.stringify(candidate.map((item) => item.value)), "utf8") >
      SUBAGENT_REPORT_OBSERVED_LIST_MAX_BYTES) {
      omitted += 1;
      continue;
    }
    entries.push(entry);
  }
  return { entries, omitted };
}

function boundObservedLists(input: BuildSubagentReportInput): {
  files: string[];
  artifacts: string[];
  omittedFiles: number;
  omittedArtifacts: number;
  clipped: number;
} {
  const files = boundObserved(input.observedFiles);
  const artifacts = boundObserved(input.observedArtifacts);
  const byteLength = () => Buffer.byteLength(JSON.stringify({
    files_modified: files.entries.map((entry) => entry.value),
    artifacts_created: artifacts.entries.map((entry) => entry.value),
  }), "utf8");
  // Keep deterministic prefixes while enforcing the aggregate as well as each
  // list's independent cap. Every removal is counted for the findings note.
  while (byteLength() > SUBAGENT_REPORT_OBSERVED_AGGREGATE_MAX_BYTES) {
    if (artifacts.entries.length >= files.entries.length && artifacts.entries.length > 0) {
      artifacts.entries.pop();
      artifacts.omitted += 1;
    } else if (files.entries.length > 0) {
      files.entries.pop();
      files.omitted += 1;
    } else {
      break;
    }
  }
  return {
    files: files.entries.map((entry) => entry.value),
    artifacts: artifacts.entries.map((entry) => entry.value),
    omittedFiles: files.omitted,
    omittedArtifacts: artifacts.omitted,
    clipped: [...files.entries, ...artifacts.entries].filter((entry) => entry.clipped).length,
  };
}

function findingsWithObservedTruncation(
  findings: string,
  truncation: { omittedFiles: number; omittedArtifacts: number; clipped: number },
  maximum: number,
): string {
  const { omittedFiles, omittedArtifacts, clipped } = truncation;
  if (omittedFiles === 0 && omittedArtifacts === 0 && clipped === 0) {
    return clip(findings, maximum);
  }
  const note = `Observed list truncation: ${omittedFiles} files and ` +
    `${omittedArtifacts} artifacts omitted; ${clipped} observed entries clipped.`;
  const suffix = findings.trim() === "" ? note : `\n\n${note}`;
  return `${clip(findings, Math.max(0, maximum - suffix.length))}${suffix}`;
}

function failureHead(input: BuildSubagentReportInput): string {
  if (input.status === "failed") {
    const error = input.error?.trim();
    return error ? `Failed: ${error}` : "Failed without an error message.";
  }
  if (input.status === "cancelled") return "Stopped before finishing.";
  return "Timed out before finishing.";
}

/** Preserve the head and checkpoint honesty while only the unverified tail yields. */
function failureSummary(input: BuildSubagentReportInput): string {
  const checkpointNote = input.status === "timeout" && (input.checkpoint ?? null) === null
    ? "No verified checkpoint was produced."
    : "";
  const reservedForNote = checkpointNote === "" ? 0 : checkpointNote.length + 2;
  const head = clip(failureHead(input), REPORT_FAILURE_LIMIT - reservedForNote);
  const fixedLength = head.length + reservedForNote;
  const label = "Unverified partial work:";
  const answer = input.answer?.trim() ?? "";
  // Two newlines join the sections and one separates the label from its tail.
  const tailBudget = REPORT_FAILURE_LIMIT - fixedLength - (answer === "" ? 0 : label.length + 3);
  const tail = clip(answer, tailBudget);
  return [
    head,
    tail === "" ? "" : `${label}\n${tail}`,
    checkpointNote,
  ].filter((part) => part !== "").join("\n\n");
}

function structuredError(input: BuildSubagentReportInput): string | null {
  if (input.status === "completed" || input.status === "cancelled") {
    return input.error === null || input.error.trim() === ""
      ? null
      : clip(input.error, REPORT_FAILURE_LIMIT);
  }
  if (input.status === "failed") {
    return input.error === null || input.error.trim() === ""
      ? "Failed without an error message."
      : clip(input.error, REPORT_FAILURE_LIMIT);
  }
  return input.error === null || input.error.trim() === ""
    ? "Timed out before finishing."
    : clip(input.error, REPORT_FAILURE_LIMIT);
}

export function buildSubagentReport(input: BuildSubagentReportInput): BuiltSubagentReport {
  const checkpoint = input.checkpoint ?? null;
  const completed = input.status === "completed";
  const answer = input.answer?.trim() ?? "";
  const summary = completed
    ? clip(answer, REPORT_SUMMARY_LIMIT)
    : failureSummary({ ...input, checkpoint });
  const observed = boundObservedLists(input);
  const findings = completed
    ? summary
    : answer === ""
      ? ""
      : `Unverified partial work:\n${answer}`;
  const keyFindings = findingsWithObservedTruncation(
    findings,
    observed,
    completed ? REPORT_SUMMARY_LIMIT : REPORT_FAILURE_LIMIT,
  );
  return {
    summary,
    structuredReport: {
      subagent_id: input.subagentId,
      status: input.status,
      files_modified: observed.files,
      artifacts_created: observed.artifacts,
      key_findings: keyFindings,
      error_if_any: structuredError(input),
    },
    checkpoint,
  };
}
