import {
  normalizeSubagentReport,
  type NormalizeSubagentReportInput,
  type NormalizedSubagentReport,
} from "./subagentReportNormalization.js";

export { REPORT_FAILURE_LIMIT, REPORT_SUMMARY_LIMIT } from "./subagents.js";
export {
  SUBAGENT_REPORT_OBSERVED_AGGREGATE_MAX_BYTES,
  SUBAGENT_REPORT_OBSERVED_ITEM_MAX_CHARS,
  SUBAGENT_REPORT_OBSERVED_LIST_MAX_BYTES,
  SUBAGENT_REPORT_OBSERVED_MAX_ITEMS,
} from "./subagentReportNormalization.js";
export type { SubagentReportStatus } from "./subagentReportNormalization.js";

/** Existing builder input retained as an alias of the shared normalization input. */
export type BuildSubagentReportInput = NormalizeSubagentReportInput;
export type BuiltSubagentReport = NormalizedSubagentReport;

/**
 * Existing public builder semantics, now backed by the single six-key/list/
 * summary normalization implementation used by terminal-report composition.
 */
export function buildSubagentReport(
  input: BuildSubagentReportInput,
): BuiltSubagentReport {
  return normalizeSubagentReport(input);
}
