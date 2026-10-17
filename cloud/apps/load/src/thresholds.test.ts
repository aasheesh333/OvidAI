import { describe, expect, it } from "vitest";
import type { LoadReport } from "./scenario.js";
import { FULL_THRESHOLDS, SMOKE_THRESHOLDS, checkThresholds } from "./thresholds.js";

/**
 * Positive-data gates (T6 review): a run that never connected, never started a
 * run, never reconnected, never spiked or never sampled a container reports
 * zeros — and zeros must fail, not pass. These tests pin that contract.
 */

function healthyReport(): LoadReport {
  return {
    startedAt: "2026-10-17T00:00:00.000Z",
    durationMs: 1_800_000,
    users: 100,
    runsStarted: 500,
    runsCompleted: 500,
    runsFailed: 0,
    runsFailedUnattributed: 0,
    eventDelivery: { p50Ms: 20, p95Ms: 100, p99Ms: 300, samples: 5_000 },
    replay: { p95Ms: 100, maxMs: 300, reconnects: 2_000, samples: 500 },
    integrity: { lostEvents: 0, duplicateEvents: 0, gapsVsMirror: 0 },
    admission: {
      maxObservedActiveSandboxes: 30,
      queuedAtCap: 5,
      rejectedAtCap: 0,
      spikeDrainMs: 1_000,
      spikeRuns: 16,
    },
    memory: { gatewayMaxRssMb: 500, hostMemAvailableMinMb: 5_000, workerMaxRssMb: 1_000 },
    harness: { maxPendingFrames: 10, latencyFloorP95Ms: 5, invalidFrames: 0 },
    scheduleRuns: { fired: 40, duplicated: 0, missed: 0 },
    thresholdFailures: [],
    notes: [],
  };
}

/** Every measurement the harness could plausibly leave at its zero default. */
function deadReport(): LoadReport {
  return {
    ...healthyReport(),
    runsStarted: 0,
    runsCompleted: 0,
    eventDelivery: { p50Ms: 0, p95Ms: 0, p99Ms: 0, samples: 0 },
    replay: { p95Ms: 0, maxMs: 0, reconnects: 0, samples: 0 },
    admission: {
      maxObservedActiveSandboxes: 0,
      queuedAtCap: 0,
      rejectedAtCap: 0,
      spikeDrainMs: 0,
      spikeRuns: 0,
    },
    memory: { gatewayMaxRssMb: 0, hostMemAvailableMinMb: 0, workerMaxRssMb: 0 },
    harness: { maxPendingFrames: 0, latencyFloorP95Ms: 0, invalidFrames: 0 },
    scheduleRuns: { fired: 0, duplicated: 0, missed: 0 },
  };
}

describe("FULL_THRESHOLDS positive-data gates", () => {
  it("a healthy report passes every threshold", () => {
    expect(checkThresholds(healthyReport(), FULL_THRESHOLDS)).toEqual([]);
  });

  it("a dead run cannot pass: zero samples/runs/replay/spike/schedule/memory all fail", () => {
    const failures = checkThresholds(deadReport(), FULL_THRESHOLDS);
    expect(failures).toEqual(
      expect.arrayContaining([
        "eventDelivery.samples",
        "runsStarted",
        "runsCompleted",
        "replay.samples",
        "admission.spikeRuns",
        "scheduleRuns.fired",
        "memory.gatewayMaxRssMb",
        "memory.workerMaxRssMb",
        "memory.hostMemAvailableMinMb",
        "admission.queuedAtCap",
      ]),
    );
  });

  it("an off-contract frame count fails the harness-honesty gate", () => {
    const report = healthyReport();
    report.harness.invalidFrames = 1;
    expect(checkThresholds(report, FULL_THRESHOLDS)).toContain("harness.invalidFrames");
  });

  it("an unattributed run_failed fails instead of silently reading as zero failures", () => {
    const report = healthyReport();
    report.runsFailedUnattributed = 1;
    expect(checkThresholds(report, FULL_THRESHOLDS)).toContain("runsFailedUnattributed");
  });

  it("keeps the brief's spike-drain threshold (T4 M1): ≤600 s", () => {
    expect(FULL_THRESHOLDS).toContainEqual(
      expect.objectContaining({
        metric: "admission.spikeDrainMs",
        op: "lte",
        value: 600_000,
      }),
    );
  });
});

describe("SMOKE_THRESHOLDS positive-data gates", () => {
  it("a dead smoke run cannot pass", () => {
    const failures = checkThresholds(deadReport(), SMOKE_THRESHOLDS);
    expect(failures).toEqual(
      expect.arrayContaining(["eventDelivery.samples", "runsStarted", "runsCompleted"]),
    );
  });
});
