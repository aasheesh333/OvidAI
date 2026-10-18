import { describe, expect, it } from "vitest";
import type { LoadProfile, LoadReport } from "./scenario.js";
import { FULL_THRESHOLDS, SMOKE_THRESHOLDS, checkThresholds } from "./thresholds.js";

/**
 * Positive-data gates (T6 review): a run that never connected, never started a
 * run, never reconnected, never spiked or never sampled a container reports
 * zeros — and zeros must fail, not pass. These tests pin that contract.
 */

/** The full100 shape for profile-conditional gates. */
const PROFILE: LoadProfile = {
  users: 100,
  durationMs: 1_800_000,
  rampMs: 300_000,
  runsPerUserEveryMs: 90_000,
  sandboxDutyCycle: 0.35,
  browserUsers: 4,
  schedules: 10,
  reconnectEveryMs: 60_000,
  spike: { atMs: 900_000, extraConcurrentRuns: 16, durationMs: 300_000 },
};

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
      queuedAtCapBasis: "accepted-not-started-peak",
      rejectedAtCap: 0,
      rejectedAtCapBasis: "run_failed",
      ptySandboxBusy: 0,
      ptySandboxUnavailable: 0,
      acceptedNotTerminal: 0,
      spikeDrainMs: 1_000,
      spikeRuns: 16,
      spikeHeldRequests: 16,
    },
    memory: { gatewayMaxRssMb: 500, hostMemAvailableMinMb: 5_000, workerMaxRssMb: 1_000 },
    harness: { maxPendingFrames: 10, latencyFloorP95Ms: 5, invalidFrames: 0 },
    scheduleRuns: { created: 10, fired: 40, duplicated: 0, missed: 0 },
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
      queuedAtCapBasis: "not-measured",
      rejectedAtCap: 0,
      rejectedAtCapBasis: "run_failed",
      ptySandboxBusy: 0,
      ptySandboxUnavailable: 0,
      acceptedNotTerminal: 0,
      spikeDrainMs: 0,
      spikeRuns: 0,
      spikeHeldRequests: 0,
    },
    memory: { gatewayMaxRssMb: 0, hostMemAvailableMinMb: 0, workerMaxRssMb: 0 },
    harness: { maxPendingFrames: 0, latencyFloorP95Ms: 0, invalidFrames: 0 },
    scheduleRuns: { created: 0, fired: 0, duplicated: 0, missed: 0 },
  };
}

describe("FULL_THRESHOLDS positive-data gates", () => {
  it("a healthy report passes every threshold", () => {
    expect(checkThresholds(healthyReport(), FULL_THRESHOLDS, PROFILE)).toEqual([]);
  });

  it("a dead run cannot pass: zero samples/runs/replay/spike/schedule/memory all fail", () => {
    const failures = checkThresholds(deadReport(), FULL_THRESHOLDS, PROFILE);
    expect(failures).toEqual(
      expect.arrayContaining([
        "eventDelivery.samples",
        "runsStarted",
        "runsCompleted",
        "replay.samples",
        "admission.spikeRuns",
        "admission.spikeHeldRequests",
        "admission.maxObservedActiveSandboxes",
        "scheduleRuns.created",
        "scheduleRuns.fired",
        "memory.gatewayMaxRssMb",
        "memory.workerMaxRssMb",
        "memory.hostMemAvailableMinMb",
        "admission.queuedAtCap",
      ]),
    );
  });

  it("sandboxDutyCycle>0 with maxObservedActiveSandboxes==0 FAILS (GAP B self-detecting)", () => {
    const report = healthyReport();
    report.admission.maxObservedActiveSandboxes = 0;
    expect(checkThresholds(report, FULL_THRESHOLDS, PROFILE)).toContain(
      "admission.maxObservedActiveSandboxes",
    );
  });

  it("the sandbox gate does not apply when the profile declares no sandbox work", () => {
    const report = healthyReport();
    report.admission.maxObservedActiveSandboxes = 0;
    expect(
      checkThresholds(report, FULL_THRESHOLDS, { ...PROFILE, sandboxDutyCycle: 0 }),
    ).not.toContain("admission.maxObservedActiveSandboxes");
  });

  it("an off-contract frame count fails the harness-honesty gate", () => {
    const report = healthyReport();
    report.harness.invalidFrames = 1;
    expect(checkThresholds(report, FULL_THRESHOLDS, PROFILE)).toContain(
      "harness.invalidFrames",
    );
  });

  it("an unattributed run_failed fails instead of silently reading as zero failures", () => {
    const report = healthyReport();
    report.runsFailedUnattributed = 1;
    expect(checkThresholds(report, FULL_THRESHOLDS, PROFILE)).toContain(
      "runsFailedUnattributed",
    );
  });

  it("schedules>0 with zero created FAILS even when the ledger counters are 0/0/0", () => {
    const report = healthyReport();
    report.scheduleRuns = { created: 0, fired: 0, duplicated: 0, missed: 0 };
    const failures = checkThresholds(report, FULL_THRESHOLDS, PROFILE);
    expect(failures).toContain("scheduleRuns.created");
    expect(failures).toContain("scheduleRuns.fired");
  });

  it("the schedule-created gate does not apply when the profile creates none", () => {
    const report = healthyReport();
    report.scheduleRuns = { created: 0, fired: 0, duplicated: 0, missed: 0 };
    expect(
      checkThresholds(report, FULL_THRESHOLDS, { ...PROFILE, schedules: 0 }),
    ).not.toContain("scheduleRuns.created");
  });

  it("a spike with zero held requests FAILS (the hold is not silently 0)", () => {
    const report = healthyReport();
    report.admission.spikeHeldRequests = 0;
    expect(checkThresholds(report, FULL_THRESHOLDS, PROFILE)).toContain(
      "admission.spikeHeldRequests",
    );
  });

  it("the spike-hold gate does not apply to a profile with no spike", () => {
    const report = healthyReport();
    report.admission.spikeHeldRequests = 0;
    expect(
      checkThresholds(report, FULL_THRESHOLDS, { ...PROFILE, spike: undefined }),
    ).not.toContain("admission.spikeHeldRequests");
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
