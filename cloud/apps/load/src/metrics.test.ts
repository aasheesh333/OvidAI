import { describe, expect, it } from "vitest";
import type { SessionEvent } from "@ovid/shared";
import {
  deliveryLatencies,
  deriveAdmissionMetrics,
  diffIntegrity,
  eventDeliveryStats,
  percentile,
  type AcceptedRun,
  type ReceivedEvent,
} from "./metrics.js";

/** Minimal synthetic SessionEvent — metrics only read `ts`/`seq`. */
function ev(seq: string, ts: string): SessionEvent {
  return { sessionId: "s", seq, type: "system_note", payload: {}, ts };
}

/** A received event for admission derivation (type/payload/session matter). */
function received(
  seq: string,
  sessionId: string,
  type: SessionEvent["type"],
  payload: Record<string, unknown>,
  receivedAtMs: number,
): ReceivedEvent {
  return {
    event: { sessionId, seq, type, payload, ts: new Date(receivedAtMs).toISOString() },
    receivedAtMs,
  };
}

function accepted(runId: string, sessionId: string, acceptedAtMs: number): AcceptedRun {
  return { runId, sessionId, acceptedAtMs };
}

describe("percentile (nearest-rank, sorted copy)", () => {
  it("percentile([1..100], 95) === 95", () => {
    const values = Array.from({ length: 100 }, (_, i) => i + 1);
    expect(percentile(values, 95)).toBe(95);
  });

  it("percentile of an empty sample throws", () => {
    expect(() => percentile([], 95)).toThrow(/empty/i);
  });

  it("p50/p99 use nearest-rank and do not mutate the input", () => {
    const values = [5, 1, 4, 2, 3];
    expect(percentile(values, 50)).toBe(3);
    expect(percentile(values, 99)).toBe(5);
    expect(values).toEqual([5, 1, 4, 2, 3]);
  });

  it("rejects an out-of-range p", () => {
    expect(() => percentile([1], 101)).toThrow(/percentile/i);
  });
});

describe("diffIntegrity", () => {
  it("clean delivery: no loss, no duplicates, no mirror gap", () => {
    const truth = ["1-1", "1-2", "1-3"];
    expect(diffIntegrity(truth, truth, truth)).toEqual({
      lostEvents: 0,
      duplicateEvents: 0,
      gapsVsMirror: 0,
    });
  });

  it("one lost tail: the undelivered ground-truth seq is counted exactly once", () => {
    const delivered = ["1-1", "1-2"];
    const truth = ["1-1", "1-2", "1-3"];
    expect(diffIntegrity(delivered, truth, truth)).toEqual({
      lostEvents: 1,
      duplicateEvents: 0,
      gapsVsMirror: 0,
    });
  });

  it("replay-overlap duplicate: a re-delivered seq counts as one duplicate, not a loss", () => {
    const delivered = ["1-1", "1-2", "1-3", "1-3", "1-4"];
    const truth = ["1-1", "1-2", "1-3", "1-4"];
    expect(diffIntegrity(delivered, truth, truth)).toEqual({
      lostEvents: 0,
      duplicateEvents: 1,
      gapsVsMirror: 0,
    });
  });

  it("mirror gap: an event in the stream but not the Postgres mirror", () => {
    const truth = ["1-1", "1-2", "1-3"];
    expect(diffIntegrity(truth, truth, ["1-1", "1-3"])).toEqual({
      lostEvents: 0,
      duplicateEvents: 0,
      gapsVsMirror: 1,
    });
  });

  it("counts repeated losses once per ground-truth seq", () => {
    expect(diffIntegrity(["1-1"], ["1-1", "1-2", "1-3"], ["1-1", "1-2", "1-3"])).toEqual({
      lostEvents: 2,
      duplicateEvents: 0,
      gapsVsMirror: 0,
    });
  });
});

describe("latency floor math", () => {
  it("synthetic ts → receivedAtMs deltas yield the exact p95", () => {
    const base = Date.parse("2026-01-01T00:00:00.000Z");
    const received = Array.from({ length: 100 }, (_, i) => ({
      event: ev(`${i + 1}-1`, new Date(base + i).toISOString()),
      receivedAtMs: base + i + (i + 1),
    }));
    // deltas are exactly 1..100 ms
    expect(deliveryLatencies(received).slice(0, 3)).toEqual([1, 2, 3]);
    expect(deliveryLatencies(received).at(-1)).toBe(100);
    expect(eventDeliveryStats(received)).toEqual({
      p50Ms: 50,
      p95Ms: 95,
      p99Ms: 99,
      samples: 100,
    });
  });

  it("negative deltas (clock skew between client and server) clamp to 0", () => {
    const ts = "2026-01-01T00:00:01.000Z";
    const received = [{ event: ev("1-1", ts), receivedAtMs: Date.parse(ts) - 50 }];
    expect(deliveryLatencies(received)).toEqual([0]);
  });

  it("empty received yields a zeroed sample set", () => {
    expect(eventDeliveryStats([])).toEqual({ p50Ms: 0, p95Ms: 0, p99Ms: 0, samples: 0 });
  });
});

describe("deriveAdmissionMetrics (the REAL admission surfaces)", () => {
  it("a run_failed {code:'sandbox_unavailable'} event yields rejectedAtCap > 0", () => {
    const events = [
      received("1-1", "s1", "run_started", { runId: "r1" }, 1_000),
      received("1-2", "s1", "run_failed", { runId: "r1", code: "sandbox_unavailable" }, 1_100),
    ];
    const result = deriveAdmissionMetrics(events, [accepted("r1", "s1", 900)], 2_000);
    expect(result.rejectedAtCap).toBeGreaterThan(0);
    expect(result.rejectedCodes).toEqual({ sandbox_unavailable: 1 });
  });

  it("counts sandbox_busy too (forward-compatible spelling)", () => {
    const events = [
      received("1-1", "s1", "run_failed", { runId: "r1", code: "sandbox_busy" }, 1_000),
    ];
    const result = deriveAdmissionMetrics(events, [accepted("r1", "s1", 900)], 2_000);
    expect(result.rejectedAtCap).toBe(1);
    expect(result.rejectedCodes).toEqual({ sandbox_busy: 1 });
  });

  it("does NOT treat a model/tool failure as an admission rejection", () => {
    const events = [
      received("1-1", "s1", "run_failed", { runId: "r1", code: "model_terminal" }, 1_000),
      received("1-2", "s1", "run_failed", { runId: "r2", code: "key_not_minted" }, 1_100),
    ];
    const result = deriveAdmissionMetrics(
      events,
      [accepted("r1", "s1", 900), accepted("r2", "s1", 950)],
      2_000,
    );
    expect(result.rejectedAtCap).toBe(0);
    expect(result.rejectedCodes).toEqual({});
  });

  it("attributes an unattributed admission failure to the oldest pending accepted run", () => {
    // The worker's sandbox admission path emits run_failed WITHOUT a runId.
    const events = [
      received("1-1", "s1", "run_started", { runId: "r1" }, 1_000),
      received("1-2", "s1", "run_failed", { code: "sandbox_unavailable" }, 1_500),
    ];
    const result = deriveAdmissionMetrics(
      events,
      [accepted("r1", "s1", 900), accepted("r2", "s1", 1_200)],
      2_000,
    );
    expect(result.rejectedAtCap).toBe(1);
    // r2 is attributed and therefore no longer counts as permanently queued.
    expect(result.acceptedNotTerminal).toBe(0);
  });

  it("queuedAtCap is the peak accepted-but-not-started window", () => {
    // r1 and r2 are both accepted before either starts.
    const events = [
      received("1-1", "s1", "run_started", { runId: "r1" }, 1_000),
      received("1-2", "s2", "run_started", { runId: "r2" }, 1_100),
      received("1-3", "s1", "run_completed", { runId: "r1" }, 1_200),
      received("1-4", "s2", "run_completed", { runId: "r2" }, 1_300),
    ];
    const result = deriveAdmissionMetrics(
      events,
      [accepted("r1", "s1", 900), accepted("r2", "s2", 950)],
      2_000,
    );
    expect(result.queuedAtCap).toBe(2);
    expect(result.acceptedNotTerminal).toBe(0);
  });

  it("maxObservedActiveSandboxes is global across sessions and ignores replay duplicates", () => {
    const started1 = received("1-1", "s1", "tool_started", { runId: "r1", callId: "c1" }, 1_000);
    const started2 = received("1-2", "s2", "tool_started", { runId: "r2", callId: "c2" }, 1_010);
    const completed1 = received("1-3", "s1", "tool_completed", { runId: "r1", callId: "c1" }, 1_020);
    const completed2 = received("1-4", "s2", "tool_completed", { runId: "r2", callId: "c2" }, 1_030);
    // A reconnect replays seq 1-1; dedupe must not inflate the count.
    const result = deriveAdmissionMetrics(
      [started1, started2, completed1, completed2, started1],
      [],
      2_000,
    );
    expect(result.maxObservedActiveSandboxes).toBe(2);
  });

  it("a run that never starts or terminates counts as queued through the end", () => {
    const result = deriveAdmissionMetrics([], [accepted("r1", "s1", 900)], 2_000);
    expect(result.queuedAtCap).toBe(1);
    expect(result.acceptedNotTerminal).toBe(1);
  });
});
