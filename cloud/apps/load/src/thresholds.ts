import type { LoadProfile, LoadReport } from "./scenario.js";

/**
 * Declarative threshold table (Task 5's acceptance table, values pinned here
 * so Task 5 can reuse them unchanged). `checkThresholds` returns the metric
 * paths that FAIL — an empty array is the only PASS.
 */

export type ThresholdOp = "lte" | "gte" | "lt" | "gt" | "eq";

export interface LoadThreshold {
  /** Dotted path into LoadReport, e.g. "eventDelivery.p95Ms". */
  metric: string;
  op: ThresholdOp;
  value: number;
  /** Human-readable rationale for the report table. */
  rationale: string;
  /**
   * Evaluate this gate only when the profile's numeric field is > 0. Used by
   * positive-data gates that cannot apply to a profile which never exercises
   * the tier. A profile-less call evaluates the gate, so missing context can
   * never hide a dead measurement.
   */
  whenProfileFieldPositive?: "sandboxDutyCycle";
}

/**
 * Smoke (Task 5 dry validation): the same correctness and harness-headroom
 * gates as the full run, minus the spike/precondition and memory-envelope
 * rows that only make sense for full100.
 */
export const SMOKE_THRESHOLDS: LoadThreshold[] = [
  {
    metric: "eventDelivery.p95Ms",
    op: "lte",
    value: 250,
    rationale: "loopback + mock-LLM pacing excluded (append-ts → client receipt)",
  },
  {
    metric: "eventDelivery.p99Ms",
    op: "lte",
    value: 1000,
    rationale: "steady-state window only",
  },
  {
    metric: "integrity.lostEvents",
    op: "eq",
    value: 0,
    rationale: "ground-truth readSince diff",
  },
  {
    metric: "integrity.duplicateEvents",
    op: "eq",
    value: 0,
    rationale: "ground-truth readSince diff",
  },
  {
    metric: "integrity.gapsVsMirror",
    op: "eq",
    value: 0,
    rationale: "session_event_mirror diff",
  },
  {
    metric: "admission.rejectedAtCap",
    op: "eq",
    value: 0,
    rationale: "admission queues, never rejects (§9)",
  },
  {
    metric: "runsFailed",
    op: "eq",
    value: 0,
    rationale: "G1/AG1 — no expected failures in a clean run",
  },
  {
    metric: "harness.maxPendingFrames",
    op: "lte",
    value: 64,
    rationale: "Review Focus #2 — client event queues drain",
  },
  {
    metric: "harness.latencyFloorP95Ms",
    op: "lte",
    value: 50,
    rationale: "Review Focus #2 — the harness is not the bottleneck",
  },
  // ---- Positive-data gates (T6 review) ------------------------------------
  // These are not performance limits: they prove the run produced the data
  // the limits above are evaluated against. A dead, unconnected or
  // misconfigured run reports zeros, and zeros must never read as PASS.
  {
    metric: "eventDelivery.samples",
    op: "gt",
    value: 0,
    rationale: "positive data: at least one delivered event was measured",
  },
  {
    metric: "runsStarted",
    op: "gt",
    value: 0,
    rationale: "positive data: the scenario actually started runs",
  },
  {
    metric: "runsCompleted",
    op: "gt",
    value: 0,
    rationale: "positive data: runs reached a terminal completed event",
  },
  {
    metric: "harness.invalidFrames",
    op: "eq",
    value: 0,
    rationale: "positive data: no off-contract server frames were accepted",
  },
];

/** Full 100-user acceptance (Task 5 table, all mandatory). */
export const FULL_THRESHOLDS: LoadThreshold[] = [
  ...SMOKE_THRESHOLDS.filter(
    (t) => t.metric !== "harness.latencyFloorP95Ms" && t.metric !== "harness.maxPendingFrames",
  ),
  {
    metric: "replay.p95Ms",
    op: "lte",
    value: 2000,
    rationale: "§6.2 reconnect contract (subscribe → last missed event, ≤1000 missed)",
  },
  {
    metric: "admission.queuedAtCap",
    op: "gt",
    value: 0,
    rationale: "the spike must actually hit the cap (precondition, not just a limit)",
  },
  {
    metric: "admission.spikeDrainMs",
    op: "lte",
    value: 600_000,
    rationale: "all queued runs started after the spike ends (§9)",
  },
  {
    metric: "memory.gatewayMaxRssMb",
    op: "lte",
    value: 921,
    rationale: "90% of the 1g gateway limit (revised §9)",
  },
  {
    metric: "memory.workerMaxRssMb",
    op: "lte",
    value: 2048,
    rationale: "worker proper ~2 GB share of the 4096M unit (revised §9)",
  },
  {
    metric: "memory.hostMemAvailableMinMb",
    op: "gte",
    value: 2048,
    rationale: "host envelope for the whole run (revised §9)",
  },
  {
    metric: "scheduleRuns.duplicated",
    op: "eq",
    value: 0,
    rationale: "§8 claim ledger — no duplicate (schedule_id, scheduled_for)",
  },
  {
    metric: "scheduleRuns.missed",
    op: "eq",
    value: 0,
    rationale: "§8 claim ledger (±1 catch-up tolerance)",
  },
  {
    metric: "harness.maxPendingFrames",
    op: "lte",
    value: 64,
    rationale: "Review Focus #2 — client event queues drain at 100 users",
  },
  {
    metric: "harness.latencyFloorP95Ms",
    op: "lte",
    value: 50,
    rationale: "Review Focus #2 — the harness is not the bottleneck at 100 users",
  },
  // ---- Positive-data gates specific to the full profile (T6 review) -------
  // `replay.p95Ms`, `admission.spikeDrainMs`, the schedule counters and the
  // memory metrics all default to 0. Without these gates a run that never
  // reconnected, never spiked, never scheduled, or never sampled a container
  // would satisfy every limit above vacuously.
  {
    metric: "replay.samples",
    op: "gt",
    value: 0,
    rationale: "positive data: reconnect+replay produced measured samples",
  },
  {
    metric: "admission.spikeRuns",
    op: "gt",
    value: 0,
    rationale: "positive data: the spike burst actually fired",
  },
  {
    metric: "admission.maxObservedActiveSandboxes",
    op: "gt",
    value: 0,
    whenProfileFieldPositive: "sandboxDutyCycle",
    rationale:
      "positive data: sandboxDutyCycle>0 must execute a sandbox-backed tool (tool_started observed)",
  },
  {
    metric: "scheduleRuns.fired",
    op: "gt",
    value: 0,
    rationale: "positive data: schedules fired and the claim ledger was read",
  },
  {
    metric: "runsFailedUnattributed",
    op: "eq",
    value: 0,
    rationale: "every run_failed carried a payload.runId (no dropped failures)",
  },
  {
    metric: "memory.gatewayMaxRssMb",
    op: "gt",
    value: 0,
    rationale: "positive data: the gateway RSS sampler observed the container",
  },
  {
    metric: "memory.workerMaxRssMb",
    op: "gt",
    value: 0,
    rationale: "positive data: the worker RSS sampler observed the process",
  },
  {
    metric: "memory.hostMemAvailableMinMb",
    op: "gt",
    value: 0,
    rationale: "positive data: /proc/meminfo was sampled",
  },
];

/** Resolve a dotted metric path against a report. */
export function readMetric(report: LoadReport, path: string): number | undefined {
  let cursor: unknown = report;
  for (const part of path.split(".")) {
    if (cursor === null || typeof cursor !== "object") return undefined;
    cursor = (cursor as Record<string, unknown>)[part];
  }
  return typeof cursor === "number" && Number.isFinite(cursor) ? cursor : undefined;
}

function passes(measured: number, op: ThresholdOp, expected: number): boolean {
  switch (op) {
    case "lte":
      return measured <= expected;
    case "gte":
      return measured >= expected;
    case "lt":
      return measured < expected;
    case "gt":
      return measured > expected;
    case "eq":
      return measured === expected;
  }
}

/**
 * Returns the metric paths that failed. A missing metric is a failure: a
 * silently absent measurement must never read as a pass.
 */
export function checkThresholds(
  report: LoadReport,
  thresholds: LoadThreshold[],
  profile?: LoadProfile,
): string[] {
  const failures: string[] = [];
  for (const threshold of thresholds) {
    if (threshold.whenProfileFieldPositive !== undefined && profile !== undefined) {
      const profileValue = profile[threshold.whenProfileFieldPositive];
      if (typeof profileValue === "number" && profileValue <= 0) continue;
    }
    const measured = readMetric(report, threshold.metric);
    if (measured === undefined || !passes(measured, threshold.op, threshold.value)) {
      failures.push(threshold.metric);
    }
  }
  return failures;
}
