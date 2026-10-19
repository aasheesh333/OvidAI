import { describe, expect, it } from "vitest";
import { LatencyHistogram } from "./hdr.js";
import { windowOf, nextSendAt, recordCapacityEvent } from "./capacity.js";
import { parseMemMiB, redactConnectionUrl } from "./capacityCli.js";
import { startMockLlmServer } from "./mockServer.js";

describe("LatencyHistogram", () => {
  it("reports exact percentiles at 1 ms resolution", () => {
    const h = new LatencyHistogram(1_000);
    for (let i = 1; i <= 100; i += 1) h.record(i - 0.5);
    expect(h.total).toBe(100);
    expect(h.percentile(50)).toBe(50);
    expect(h.percentile(95)).toBe(95);
    expect(h.percentile(99)).toBe(99);
    expect(h.summary()).toMatchObject({ samples: 100, p50: 50, p95: 95, p99: 99, max: 100 });
    expect(h.summary().percentileResolutionMs).toBe(1);
    expect(h.summary().percentilesAreUpperBounds).toBe(true);
  });

  it("keeps rounded max consistent with upper-bound percentile buckets", () => {
    const h = new LatencyHistogram(100);
    h.record(12.1);
    h.record(12.9);
    expect(h.summary().p99).toBe(13);
    expect(h.summary().max).toBe(13);
  });

  it("clamps negatives to 0 and puts overflow in the tail bucket", () => {
    const h = new LatencyHistogram(10);
    h.record(-5);
    h.record(5_000);
    expect(h.percentile(1)).toBe(1);
    expect(h.percentile(100)).toBe(5_000);
  });

  it("merges serialized shards losslessly", () => {
    const a = new LatencyHistogram(500);
    const b = new LatencyHistogram(500);
    for (let i = 0; i < 50; i += 1) a.record(10);
    for (let i = 0; i < 50; i += 1) b.record(300);
    const merged = LatencyHistogram.from(a.serialize());
    merged.merge(b.serialize());
    expect(merged.total).toBe(100);
    expect(merged.percentile(50)).toBe(11);
    expect(merged.percentile(51)).toBe(301);
    expect(() => merged.merge(new LatencyHistogram(10))).toThrow(/layout/);
  });

  it("is empty-safe", () => {
    expect(new LatencyHistogram().summary()).toEqual({
      samples: 0,
      p50: 0,
      p95: 0,
      p99: 0,
      max: 0,
      mean: 0,
      percentileResolutionMs: 1,
      percentilesAreUpperBounds: true,
    });
  });
});

describe("capacity timeline", () => {
  it("schedules the next send from the previous START, not stream completion", () => {
    expect(nextSendAt(1_000, 20_000, 60_000, 0)).toBe(21_000);
    expect(nextSendAt(1_000, 20_000, 60_000, 0.5)).toBe(41_000);
    expect(nextSendAt(1_000, 20_000, 60_000, 1)).toBe(61_000);
  });
  it("starts the measurement window after ramp + settle", () => {
    expect(windowOf({ rampMs: 120_000, settleMs: 30_000, measureMs: 900_000 })).toEqual({
      startMs: 150_000,
      endMs: 1_050_000,
    });
  });
});

describe("capacity evidence", () => {
  it("counts actual tool events, not requested sandbox markers", () => {
    const counters: Record<string, number> = {};
    recordCapacityEvent(counters, "tool_started", {});
    recordCapacityEvent(counters, "tool_completed", { ok: true });
    recordCapacityEvent(counters, "tool_completed", { isError: true });
    recordCapacityEvent(counters, "run_started", {});
    recordCapacityEvent(counters, "run_merged", {});
    expect(counters).toEqual({ toolsStarted: 1, toolsCompleted: 2, toolErrors: 1, runsStarted: 1, runsMerged: 1 });
  });
  it("never writes connection credentials into reports", () => {
    expect(redactConnectionUrl("postgres://postgres:secret@127.0.0.1:5433/cap"))
      .toBe("postgres://postgres:REDACTED@127.0.0.1:5433/cap");
    expect(redactConnectionUrl("redis://:private@127.0.0.1:6390/12"))
      .not.toContain("private");
    expect(redactConnectionUrl("malformed-private-value")).toBe("[invalid URL]");
  });

  it("reports live stub streams separately from completed requests", async () => {
    const server = await startMockLlmServer({ deltas: ["a", "b", "c"], chunkDelayMs: 50, toolCall: null });
    try {
      const response = await fetch(`${server.baseUrl}/v1/chat/completions`, {
        method: "POST", body: JSON.stringify({messages: [{role: "user", content: "hello"}]}),
      });
      const status = await (await fetch(`${server.baseUrl}/_control/status`)).json() as Record<string, number>;
      expect(status.activeStreams).toBe(1);
      expect(status.peakActiveStreams).toBe(1);
      await response.text();
      const after = await (await fetch(`${server.baseUrl}/_control/status`)).json() as Record<string, number>;
      expect(after.activeStreams).toBe(0);
      expect(after.completedStreams).toBe(1);
    } finally { await server.close(); }
  });
});

describe("parseMemMiB", () => {
  it("parses docker stats usage figures", () => {
    expect(parseMemMiB("512MiB / 1GiB")).toBe(512);
    expect(parseMemMiB("1.5GiB / 2GiB")).toBe(1536);
    expect(parseMemMiB("2048KiB / 1GiB")).toBe(2);
    expect(parseMemMiB("n/a")).toBeNull();
  });
});
