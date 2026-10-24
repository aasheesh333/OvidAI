import { structuredSubagentReportSchema } from "@ovid/shared";
import { describe, expect, it } from "vitest";

import {
  REPORT_FAILURE_LIMIT,
  REPORT_SUMMARY_LIMIT,
  buildSubagentReport,
} from "./subagentReport.js";

const SIX_KEYS = [
  "artifacts_created",
  "error_if_any",
  "files_modified",
  "key_findings",
  "status",
  "subagent_id",
];

describe("terminal subagent reports", () => {
  it("builds a bounded done report with exactly the six contracted keys", () => {
    const result = buildSubagentReport({
      subagentId: "child-done",
      status: "completed",
      answer: "Implemented and verified the focused change.",
      error: null,
      observedFiles: ["src/example.ts"],
      observedArtifacts: ["artifact-1"],
    });
    expect(result.summary).toBe("Implemented and verified the focused change.");
    expect(Object.keys(result.structuredReport).sort()).toEqual(SIX_KEYS);
    expect(result.structuredReport).toEqual({
      subagent_id: "child-done",
      status: "completed",
      files_modified: ["src/example.ts"],
      artifacts_created: ["artifact-1"],
      key_findings: "Implemented and verified the focused change.",
      error_if_any: null,
    });
    expect(structuredSubagentReportSchema.parse(result.structuredReport)).toEqual(
      result.structuredReport,
    );
    expect(result.checkpoint).toBeNull();
  });

  it("keeps the actual error first and labels a long partial failure tail unverified", () => {
    const result = buildSubagentReport({
      subagentId: "child-error",
      status: "failed",
      answer: "partial-".repeat(700),
      error: "actual storage failure",
      observedFiles: [],
      observedArtifacts: [],
    });
    expect(result.summary.startsWith("Failed: actual storage failure\n\nUnverified partial work:\n")).toBe(true);
    expect(result.summary.indexOf("actual storage failure")).toBeLessThan(
      result.summary.indexOf("partial-"),
    );
    expect(result.summary.length).toBeLessThanOrEqual(REPORT_FAILURE_LIMIT);
    expect(result.structuredReport.key_findings).toContain("Unverified partial work:");
    expect(result.structuredReport.key_findings.length).toBeLessThanOrEqual(REPORT_FAILURE_LIMIT);
    expect(result.structuredReport.error_if_any).toBe("actual storage failure");
    expect(result.structuredReport.status).toBe("failed");
    expect(REPORT_FAILURE_LIMIT).toBe(4_000);
  });

  it("preserves the existing stopped summary shape and never presents it as success", () => {
    const result = buildSubagentReport({
      subagentId: "child-stopped",
      status: "cancelled",
      answer: "partial work before stop",
      error: null,
      observedFiles: [],
      observedArtifacts: [],
    });
    expect(result.summary).toBe(
      "Stopped before finishing.\n\nUnverified partial work:\npartial work before stop",
    );
    expect(result.structuredReport.status).toBe("cancelled");
    expect(result.structuredReport.error_if_any).toBeNull();
  });

  it("reports timeout and missing verified checkpoint honestly", () => {
    const result = buildSubagentReport({
      subagentId: "child-timeout",
      status: "timeout",
      answer: "unfinished tail",
      error: null,
      checkpoint: null,
      observedFiles: [],
      observedArtifacts: [],
    });
    expect(result.summary).toContain("Timed out before finishing.");
    expect(result.summary).toContain("Unverified partial work:\nunfinished tail");
    expect(result.summary).toContain("No verified checkpoint was produced.");
    expect(result.structuredReport.status).toBe("timeout");
    expect(result.structuredReport.error_if_any).toBe("Timed out before finishing.");
    expect(result.checkpoint).toBeNull();
  });

  it("returns only a checkpoint supplied by verified persistence", () => {
    const checkpoint = {
      checkpointId: "checkpoint-real",
      hash: "sha256:verified",
      createdAt: "2026-10-24T07:55:00.000Z",
    };
    const result = buildSubagentReport({
      subagentId: "child-checkpoint",
      status: "timeout",
      answer: null,
      error: null,
      checkpoint,
      observedFiles: [],
      observedArtifacts: [],
    });
    expect(result.checkpoint).toEqual(checkpoint);
    expect(result.summary).not.toContain("No verified checkpoint was produced.");
  });

  it("enforces the 1,200-character success budget including its truncation marker", () => {
    const result = buildSubagentReport({
      subagentId: "child-long",
      status: "completed",
      answer: "x".repeat(2_000),
      error: null,
      observedFiles: [],
      observedArtifacts: [],
    });
    expect(result.summary.length).toBe(REPORT_SUMMARY_LIMIT);
    expect(result.summary.endsWith("…")).toBe(true);
    expect(result.structuredReport.key_findings.length).toBe(REPORT_SUMMARY_LIMIT);
    expect(REPORT_SUMMARY_LIMIT).toBe(1_200);
  });

  it("bounds observed item length, counts, and UTF-8 aggregate with honest omitted counts", () => {
    const files = Array.from({ length: 150 }, (_, index) =>
      index === 0 ? `src/${"f".repeat(1_200)}.ts` : `src/file-${index}-${"ü".repeat(90)}.ts`);
    const artifacts = Array.from({ length: 140 }, (_, index) =>
      index === 0 ? `artifact-${"a".repeat(900)}` : `artifact-${index}-${"x".repeat(100)}`);
    const result = buildSubagentReport({
      subagentId: "child-list-bounds",
      status: "completed",
      answer: "Observed output was bounded.",
      error: null,
      observedFiles: files,
      observedArtifacts: artifacts,
    });
    const report = result.structuredReport;
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
    expect(report.files_modified[0]?.endsWith("…")).toBe(true);
    expect(report.key_findings).toContain(
      `${150 - report.files_modified.length} files and ` +
      `${140 - report.artifacts_created.length} artifacts omitted`,
    );
    expect(report.key_findings).toContain("2 observed entries clipped");
    expect(report.key_findings.length).toBeLessThanOrEqual(REPORT_SUMMARY_LIMIT);
    expect(Object.keys(report).sort()).toEqual(SIX_KEYS);
    expect(structuredSubagentReportSchema.parse(report)).toEqual(report);
  });

  it("uses only observed writes and artifact registrations, never paths guessed from prose", () => {
    const result = buildSubagentReport({
      subagentId: "child-observed",
      status: "completed",
      answer: "I changed imaginary.ts and claimed-artifact was created.",
      error: null,
      observedFiles: ["src/actually-written.ts"],
      observedArtifacts: ["artifact-actually-registered"],
    });
    expect(result.structuredReport.files_modified).toEqual(["src/actually-written.ts"]);
    expect(result.structuredReport.artifacts_created).toEqual(["artifact-actually-registered"]);
    expect(result.structuredReport.files_modified).not.toContain("imaginary.ts");
    expect(result.structuredReport.artifacts_created).not.toContain("claimed-artifact");
  });
});
