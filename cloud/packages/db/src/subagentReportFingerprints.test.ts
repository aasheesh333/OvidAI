import { createHash } from "node:crypto";
import type { StructuredSubagentReport } from "@ovid/shared";
import { describe, expect, it } from "vitest";

import {
  canonicalSubagentReportContent,
  subagentReportContentFingerprint,
  type SubagentReportFingerprintInput,
} from "./subagentReportFingerprints.js";
import {
  fingerprintRootFinalizationReports,
  fingerprintSubagentReport,
  type DurableSubagentReportRecord,
} from "./subagentReportSnapshots.js";

function structured(): StructuredSubagentReport {
  return {
    subagent_id: "child-1",
    status: "failed",
    files_modified: ["src/a.ts", "src/b.ts"],
    artifacts_created: ["artifact-1"],
    key_findings: "Unverified partial work:\nactual answer",
    error_if_any: "actual error",
  };
}

function input(
  overrides: Partial<SubagentReportFingerprintInput> = {},
): SubagentReportFingerprintInput {
  return {
    attemptId: "attempt-1",
    terminal: {
      logicalWorkerId: "worker-1",
      childSessionId: "child-1",
      childRunId: "run-initial",
      agentType: "general-purpose",
      status: "failed",
      rootTaskRunId: "root-1",
      executionEpoch: 1,
    },
    summary: "Failed: actual error\n\nUnverified partial work:\nactual answer",
    structuredReport: structured(),
    ...overrides,
  };
}

// Authored RED before production fingerprint code. UNEXECUTED under pause.
describe("subagent report content fingerprints (UNEXECUTED under pause)", () => {
  it("canonicalizes fixed field order and the exact six-key value without sorting observations", () => {
    const reordered = JSON.parse(`{
      "error_if_any":"actual error",
      "key_findings":"Unverified partial work:\\nactual answer",
      "artifacts_created":["artifact-1"],
      "files_modified":["src/a.ts","src/b.ts"],
      "status":"failed",
      "subagent_id":"child-1"
    }`) as StructuredSubagentReport;
    const canonical = canonicalSubagentReportContent(input({ structuredReport: reordered }));
    expect(canonical).toBe(
      '{"version":1,"attemptId":"attempt-1","terminal":{' +
      '"logicalWorkerId":"worker-1","childSessionId":"child-1",' +
      '"childRunId":"run-initial","agentType":"general-purpose",' +
      '"status":"failed","rootTaskRunId":"root-1","executionEpoch":1},' +
      '"summary":"Failed: actual error\\n\\nUnverified partial work:\\nactual answer",' +
      '"structuredReport":{"subagent_id":"child-1","status":"failed",' +
      '"files_modified":["src/a.ts","src/b.ts"],"artifacts_created":["artifact-1"],' +
      '"key_findings":"Unverified partial work:\\nactual answer",' +
      '"error_if_any":"actual error"}}',
    );
    expect(canonicalSubagentReportContent(input())).toBe(canonical);
    expect(subagentReportContentFingerprint(input()))
      .toMatch(/^sha256:[0-9a-f]{64}$/);
    expect(subagentReportContentFingerprint(input()))
      .toBe(subagentReportContentFingerprint(input({ structuredReport: reordered })));
  });

  it("changes for attempt ID, terminal identity, summary, and normalized structured content", () => {
    const original = subagentReportContentFingerprint(input());
    expect(subagentReportContentFingerprint(input({ attemptId: "attempt-2" })))
      .not.toBe(original);
    expect(subagentReportContentFingerprint(input({
      terminal: { ...input().terminal, childRunId: "run-follow-up" },
    }))).not.toBe(original);
    expect(subagentReportContentFingerprint(input({
      terminal: { ...input().terminal, status: "cancelled" },
      structuredReport: { ...structured(), status: "cancelled" },
    }))).not.toBe(original);
    expect(subagentReportContentFingerprint(input({ summary: `${input().summary} ` })))
      .not.toBe(original);
    expect(subagentReportContentFingerprint(input({
      structuredReport: { ...structured(), files_modified: ["src/b.ts", "src/a.ts"] },
    }))).not.toBe(original);
  });

  it("keeps unknown null distinct from real empty observations and preserves summary whitespace", () => {
    const unknown = input({ summary: " canonical base ", structuredReport: null });
    const empty = input({
      summary: " canonical base ",
      structuredReport: { ...structured(), files_modified: [], artifacts_created: [] },
    });
    expect(canonicalSubagentReportContent(unknown))
      .toContain('"summary":" canonical base "');
    expect(canonicalSubagentReportContent(unknown))
      .toContain('"structuredReport":null');
    expect(canonicalSubagentReportContent(empty))
      .toContain('"files_modified":[],"artifacts_created":[]');
    expect(subagentReportContentFingerprint(unknown))
      .not.toBe(subagentReportContentFingerprint(empty));
  });

  it("uses the reviewed bare-hex aggregate over code-unit-ordered full per-report values", () => {
    const base = input();
    const reports: DurableSubagentReportRecord[] = [
      {
        logicalWorkerId: base.terminal.logicalWorkerId,
        attemptId: "attempt-2",
        childSessionId: base.terminal.childSessionId,
        childRunId: base.terminal.childRunId,
        agentType: base.terminal.agentType,
        status: "failed",
        summary: base.summary,
        task: "full task",
        at: 1,
        rootTaskRunId: base.terminal.rootTaskRunId,
        executionEpoch: 1,
        structuredReport: structured(),
      },
      {
        logicalWorkerId: base.terminal.logicalWorkerId,
        attemptId: "attempt-1",
        childSessionId: base.terminal.childSessionId,
        childRunId: base.terminal.childRunId,
        agentType: base.terminal.agentType,
        status: "failed",
        summary: base.summary,
        task: "full task",
        at: 2,
        rootTaskRunId: base.terminal.rootTaskRunId,
        executionEpoch: 2,
        structuredReport: null,
      },
    ];
    const ordered = [...reports].sort((a, b) =>
      a.attemptId < b.attemptId ? -1 : a.attemptId > b.attemptId ? 1 : 0
    );
    const expected = createHash("sha256")
      .update(JSON.stringify(ordered.map(fingerprintSubagentReport)), "utf8")
      .digest("hex");
    expect(fingerprintRootFinalizationReports(reports)).toBe(expected);
    expect(fingerprintSubagentReport(reports[0]!)).toMatch(/^sha256:/);
  });

  it("rejects non-six-key or canonically inconsistent structured values", () => {
    expect(() => canonicalSubagentReportContent(input({
      structuredReport: { ...structured(), private_thoughts: "not wire data" } as never,
    }))).toThrow();
    expect(() => canonicalSubagentReportContent(input({
      structuredReport: { ...structured(), status: "completed" },
    }))).toThrow(/status/i);
    expect(() => canonicalSubagentReportContent(input({
      terminal: { ...input().terminal, childSessionId: "child-other" },
    }))).toThrow(/subagent|child/i);
  });
});
