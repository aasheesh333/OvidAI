import { describe, expect, it } from "vitest";
import type { SessionEvent } from "@ovid/shared";
import {
  deliveryLatencies,
  diffIntegrity,
  eventDeliveryStats,
  percentile,
} from "./metrics.js";

/** Minimal synthetic SessionEvent — metrics only read `ts`/`seq`. */
function ev(seq: string, ts: string): SessionEvent {
  return { sessionId: "s", seq, type: "system_note", payload: {}, ts };
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
