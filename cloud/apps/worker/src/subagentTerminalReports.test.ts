import type { StructuredSubagentReport } from "@ovid/shared";
import { describe, expect, it, vi } from "vitest";

import { buildSubagentReport } from "../../../packages/agent-core/src/subagentReport.js";
import {
  normalizeCanonicalSubagentSummary,
  normalizeSubagentReportContent,
} from "../../../packages/agent-core/src/subagentReportNormalization.js";
import type { SubagentObservationFinal } from "./subagentObservations.js";
import {
  composeSubagentTerminalReport,
  type SubagentCanonicalTerminalReport,
  type SubagentTerminalIdentity,
} from "./subagentTerminalReports.js";

const SIX_KEYS = [
  "artifacts_created",
  "error_if_any",
  "files_modified",
  "key_findings",
  "status",
  "subagent_id",
];

function identity(): SubagentTerminalIdentity {
  return {
    attemptId: "attempt-admitted",
    logicalWorkerId: "worker-1",
    childSessionId: "child-1",
    childRunId: "run-initial-immutable",
    agentType: "general-purpose",
    rootTaskRunId: "root-1",
    executionEpoch: 1,
  };
}

function baseReport(
  status: StructuredSubagentReport["status"] = "failed",
  summary = "Failed: canonical base error",
): SubagentCanonicalTerminalReport {
  return {
    ...identity(),
    status,
    summary,
    structuredReport: null,
  };
}

function readyObservation(
  overrides: Partial<Extract<SubagentObservationFinal, { status: "ready" }>> = {},
): SubagentObservationFinal {
  return {
    status: "ready",
    attemptId: "attempt-admitted",
    settlementTurnRunId: "run-settlement-follow-up",
    answer: {
      messageId: "answer-settlement-turn",
      content: "actual settlement-turn partial answer",
    },
    observedFiles: ["src/actually-written.ts"],
    observedArtifacts: ["artifact-actually-registered"],
    ...overrides,
  };
}

function composerHarness(options: {
  observation?: SubagentObservationFinal | Error;
  checkpoint?: { checkpointId: string; hash: string; createdAt: string } | null | Error;
  base?: SubagentCanonicalTerminalReport;
  status?: StructuredSubagentReport["status"];
  error?: string | null;
} = {}) {
  const writes: SubagentCanonicalTerminalReport[] = [];
  const closes: Array<{ attemptId: string; settlementTurnRunId: string }> = [];
  const build = vi.fn(buildSubagentReport);
  const latestVerified = vi.fn(async (_attemptId: string) => {
    if (options.checkpoint instanceof Error) throw options.checkpoint;
    return options.checkpoint ?? null;
  });
  let stored: SubagentCanonicalTerminalReport | null = null;
  let readback: SubagentCanonicalTerminalReport | null | undefined;
  const deps = {
    observations: {
      async close(input: { attemptId: string; settlementTurnRunId: string }) {
        closes.push(input);
        if (options.observation instanceof Error) throw options.observation;
        return options.observation ?? readyObservation();
      },
    },
    checkpoints: { latestVerified },
    reports: {
      async putFinal(report: SubagentCanonicalTerminalReport) {
        writes.push(structuredClone(report));
        stored = structuredClone(report);
      },
      async readFinal(_attemptId: string) {
        return readback === undefined ? structuredClone(stored) : structuredClone(readback);
      },
    },
    buildReport: build,
    normalizeReport: normalizeSubagentReportContent,
    normalizeSummary: normalizeCanonicalSubagentSummary,
  };
  const input = {
    identity: identity(),
    settlementTurnRunId: "run-settlement-follow-up",
    status: options.status ?? ("failed" as const),
    error: options.error === undefined ? "actual latest-turn error" : options.error,
    baseReport: options.base ?? baseReport(options.status ?? "failed"),
  };
  return {
    closes,
    deps,
    input,
    latestVerified,
    writes,
    setReadback(report: SubagentCanonicalTerminalReport | null) { readback = report; },
  };
}

// Authored RED before production composer code. UNEXECUTED under pause.
describe("canonical subagent terminal reports (UNEXECUTED under pause)", () => {
  it("builds from the exact settlement-turn answer and canonical latest-turn error/status", async () => {
    const h = composerHarness();
    const result = await composeSubagentTerminalReport(h.input, h.deps);

    expect(h.closes).toEqual([{
      attemptId: "attempt-admitted",
      settlementTurnRunId: "run-settlement-follow-up",
    }]);
    expect(result.coverage).toBe("ready");
    expect(result.report).toEqual({
      ...identity(),
      status: "failed",
      summary: "Failed: actual latest-turn error\n\nUnverified partial work:\nactual settlement-turn partial answer",
      structuredReport: {
        subagent_id: "child-1",
        status: "failed",
        files_modified: ["src/actually-written.ts"],
        artifacts_created: ["artifact-actually-registered"],
        key_findings: "Unverified partial work:\nactual settlement-turn partial answer",
        error_if_any: "actual latest-turn error",
      },
    });
    expect(Object.keys(result.report.structuredReport!).sort()).toEqual(SIX_KEYS);
    expect(h.writes).toEqual([result.report]);
    expect(h.deps.buildReport).toHaveBeenCalledWith({
      subagentId: "child-1",
      status: "failed",
      answer: "actual settlement-turn partial answer",
      error: "actual latest-turn error",
      observedFiles: ["src/actually-written.ts"],
      observedArtifacts: ["artifact-actually-registered"],
      checkpoint: undefined,
    });
  });

  it("keeps unknown_final as a canonical base report with structuredReport null, never empty arrays", async () => {
    const h = composerHarness({
      observation: {
        status: "unknown_final",
        attemptId: "attempt-admitted",
        settlementTurnRunId: "run-settlement-follow-up",
        reasons: ["open_operation"],
      },
    });
    const result = await composeSubagentTerminalReport(h.input, h.deps);

    expect(result.coverage).toBe("unknown_final");
    expect(result.report).toEqual(baseReport());
    expect(result.report.structuredReport).toBeNull();
    expect(h.deps.buildReport).not.toHaveBeenCalled();
    expect(h.writes).toEqual([result.report]);
  });

  it("treats observation I/O as infrastructure failure and never falls back to invented coverage", async () => {
    const h = composerHarness({ observation: new Error("journal unavailable") });
    await expect(composeSubagentTerminalReport(h.input, h.deps))
      .rejects.toThrow("journal unavailable");
    expect(h.writes).toEqual([]);
    expect(h.deps.buildReport).not.toHaveBeenCalled();
  });

  it("rejects a local/base canonical mismatch before writing or observing", async () => {
    const h = composerHarness({
      status: "failed",
      base: baseReport("completed", "stale local completed summary"),
    });
    await expect(composeSubagentTerminalReport(h.input, h.deps))
      .rejects.toMatchObject({ code: "canonical_mismatch" });
    expect(h.closes).toEqual([]);
    expect(h.writes).toEqual([]);
  });

  it("rejects an observation returned for the wrong settlement turn", async () => {
    const h = composerHarness({
      observation: readyObservation({ settlementTurnRunId: "run-initial-immutable" }),
    });
    await expect(composeSubagentTerminalReport(h.input, h.deps))
      .rejects.toMatchObject({ code: "canonical_mismatch" });
    expect(h.writes).toEqual([]);
  });

  it("validates the committed readback instead of returning an unpersisted structured value", async () => {
    const h = composerHarness();
    h.setReadback({
      ...baseReport("completed", "stale local completion"),
      structuredReport: {
        subagent_id: "child-1",
        status: "completed",
        files_modified: [],
        artifacts_created: [],
        key_findings: "stale",
        error_if_any: null,
      },
    });
    await expect(composeSubagentTerminalReport(h.input, h.deps))
      .rejects.toMatchObject({ code: "readback_mismatch" });
    expect(h.writes).toHaveLength(1);
  });

  it("rejects a missing committed report readback as infrastructure failure", async () => {
    const h = composerHarness();
    h.setReadback(null);
    await expect(composeSubagentTerminalReport(h.input, h.deps))
      .rejects.toMatchObject({ code: "readback_mismatch" });
  });

  it("uses the shared persisted-checkpoint lookup for timeout instead of an omitted local value", async () => {
    const checkpoint = {
      checkpointId: "checkpoint-persisted",
      hash: "sha256:verified",
      createdAt: "2026-10-25T07:55:00.000Z",
    };
    const h = composerHarness({
      status: "timeout",
      error: null,
      base: baseReport("timeout", "Timed out before finishing."),
      checkpoint,
      observation: readyObservation({
        answer: { messageId: "answer-timeout", content: "unfinished tail" },
        observedFiles: [],
        observedArtifacts: [],
      }),
    });
    const result = await composeSubagentTerminalReport(h.input, h.deps);

    expect(h.latestVerified).toHaveBeenCalledTimes(1);
    expect(h.latestVerified).toHaveBeenCalledWith("attempt-admitted");
    expect(result.checkpoint).toEqual(checkpoint);
    expect(result.report.summary).toBe(
      "Timed out before finishing.\n\nUnverified partial work:\nunfinished tail",
    );
    expect(result.report.summary).not.toContain("No verified checkpoint was produced.");
    expect(Object.keys(result.report.structuredReport!).sort()).toEqual(SIX_KEYS);
  });

  it("uses lookup null as the only verified-absence source and keeps unknown observations null", async () => {
    const h = composerHarness({
      status: "timeout",
      error: null,
      base: baseReport("timeout", "Timed out before finishing."),
      checkpoint: null,
      observation: {
        status: "unknown_final",
        attemptId: "attempt-admitted",
        settlementTurnRunId: "run-settlement-follow-up",
        reasons: ["open_operation"],
      },
    });
    const result = await composeSubagentTerminalReport(h.input, h.deps);

    expect(result.coverage).toBe("unknown_final");
    expect(result.checkpoint).toBeNull();
    expect(result.report.summary).toBe(
      "Timed out before finishing.\n\nNo verified checkpoint was produced.",
    );
    expect(result.report.structuredReport).toBeNull();
    expect(h.deps.buildReport).not.toHaveBeenCalled();
  });

  it("fails timeout composition when checkpoint lookup fails and never guesses absence", async () => {
    const h = composerHarness({
      status: "timeout",
      base: baseReport("timeout"),
      checkpoint: new Error("checkpoint store unavailable"),
    });
    await expect(composeSubagentTerminalReport(h.input, h.deps))
      .rejects.toThrow("checkpoint store unavailable");
    expect(h.writes).toEqual([]);
  });

  it("does not perform a checkpoint lookup for non-timeout outcomes", async () => {
    const h = composerHarness({ status: "completed", base: baseReport("completed", "base") });
    await composeSubagentTerminalReport(h.input, h.deps);
    expect(h.latestVerified).not.toHaveBeenCalled();
  });
});
