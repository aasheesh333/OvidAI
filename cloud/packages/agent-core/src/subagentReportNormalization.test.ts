import { structuredSubagentReportSchema } from "@ovid/shared";
import { describe, expect, it } from "vitest";

import { buildSubagentReport } from "./subagentReport.js";
import {
  normalizeCanonicalSubagentSummary,
  normalizeSubagentReport,
  normalizeSubagentReportContent,
} from "./subagentReportNormalization.js";

const SIX_KEYS = [
  "artifacts_created",
  "error_if_any",
  "files_modified",
  "key_findings",
  "status",
  "subagent_id",
];

// Authored RED before production normalization code. UNEXECUTED under the
// heavy-command pause; no red/green execution is claimed.
describe("subagent report normalization (UNEXECUTED under pause)", () => {
  it("uses one builder path with exactly six keys and unchanged completed semantics", () => {
    const input = {
      subagentId: "child-1",
      status: "completed" as const,
      answer: "Actual child answer",
      error: null,
      observedFiles: ["src/actual.ts"],
      observedArtifacts: ["artifact-actual"],
    };
    const expected = {
      summary: "Actual child answer",
      structuredReport: {
        subagent_id: "child-1",
        status: "completed",
        files_modified: ["src/actual.ts"],
        artifacts_created: ["artifact-actual"],
        key_findings: "Actual child answer",
        error_if_any: null,
      },
      checkpoint: null,
    };
    expect(normalizeSubagentReport(input)).toEqual(expected);
    expect(buildSubagentReport(input)).toEqual(expected);
    expect(Object.keys(expected.structuredReport).sort()).toEqual(SIX_KEYS);
    expect(structuredSubagentReportSchema.parse(expected.structuredReport))
      .toEqual(expected.structuredReport);
  });

  it("preserves actual-error-first failure and unverified partial tails", () => {
    const report = normalizeSubagentReport({
      subagentId: "child-failed",
      status: "failed",
      answer: "partial answer",
      error: "actual latest-turn error",
      observedFiles: [],
      observedArtifacts: [],
    });
    expect(report.summary).toBe(
      "Failed: actual latest-turn error\n\nUnverified partial work:\npartial answer",
    );
    expect(report.structuredReport).toEqual({
      subagent_id: "child-failed",
      status: "failed",
      files_modified: [],
      artifacts_created: [],
      key_findings: "Unverified partial work:\npartial answer",
      error_if_any: "actual latest-turn error",
    });
  });

  it("normalizes an existing report through the same observed-list and summary bounds", () => {
    const longFiles = [
      `src/${"ü".repeat(700)}.ts`,
      ...Array.from({ length: 130 }, (_, index) => `src/${index}-${"x".repeat(100)}.ts`),
    ];
    const longArtifacts = Array.from(
      { length: 125 },
      (_, index) => `artifact-${index}-${"y".repeat(100)}`,
    );
    const normalized = normalizeSubagentReportContent({
      summary: "  completed summary  ",
      status: "completed",
      structuredReport: {
        subagent_id: "child-bounds",
        status: "completed",
        files_modified: longFiles,
        artifacts_created: longArtifacts,
        key_findings: " findings ",
        error_if_any: null,
      },
    });
    expect(normalized.summary).toBe("completed summary");
    const report = normalized.structuredReport!;
    expect(Object.keys(report).sort()).toEqual(SIX_KEYS);
    expect(report.files_modified.length).toBeLessThanOrEqual(100);
    expect(report.artifacts_created.length).toBeLessThanOrEqual(100);
    expect([...report.files_modified, ...report.artifacts_created].every((item) =>
      Array.from(item).length <= 512)).toBe(true);
    expect(Buffer.byteLength(JSON.stringify(report.files_modified), "utf8"))
      .toBeLessThanOrEqual(8_192);
    expect(Buffer.byteLength(JSON.stringify(report.artifacts_created), "utf8"))
      .toBeLessThanOrEqual(8_192);
    expect(Buffer.byteLength(JSON.stringify({
      files_modified: report.files_modified,
      artifacts_created: report.artifacts_created,
    }), "utf8")).toBeLessThanOrEqual(16_384);
    expect(report.key_findings).toContain("Observed list truncation:");
    expect(report.key_findings.length).toBeLessThanOrEqual(1_200);
    expect(Object.keys(normalized).sort()).toEqual(["structuredReport", "summary"]);
    expect(normalized).not.toHaveProperty("status");
    expect(structuredSubagentReportSchema.parse(report)).toEqual(report);
  });

  it("does not manufacture a structured value or empty observations from unknown coverage", () => {
    expect(normalizeSubagentReportContent({
      summary: " canonical base summary ",
      status: "failed",
      structuredReport: null,
    })).toEqual({
      summary: "canonical base summary",
      structuredReport: null,
    });
  });

  it("adds timeout absence disclosure only after the caller supplies a resolved null checkpoint", () => {
    expect(normalizeCanonicalSubagentSummary({
      summary: "Timed out before finishing.",
      status: "timeout",
      checkpoint: null,
    })).toBe("Timed out before finishing.\n\nNo verified checkpoint was produced.");
    const checkpoint = {
      checkpointId: "checkpoint-persisted",
      hash: "sha256:persisted",
      createdAt: "2026-10-25T07:55:00.000Z",
    };
    expect(normalizeCanonicalSubagentSummary({
      summary: "Timed out before finishing.",
      status: "timeout",
      checkpoint,
    })).toBe("Timed out before finishing.");
  });

  it("rejects a structured status that diverges from canonical status", () => {
    expect(() => normalizeSubagentReportContent({
      summary: "stale local completion",
      status: "failed",
      structuredReport: {
        subagent_id: "child-mismatch",
        status: "completed",
        files_modified: [],
        artifacts_created: [],
        key_findings: "stale",
        error_if_any: null,
      },
    })).toThrow(/status/i);
  });
});
