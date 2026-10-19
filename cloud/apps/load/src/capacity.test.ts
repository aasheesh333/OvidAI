import { describe, expect, it } from "vitest";
import { LatencyHistogram } from "./hdr.js";
import { windowOf } from "./capacity.js";
import { parseMemMiB } from "./capacityCli.js";

describe("LatencyHistogram", () => {
  it("reports exact percentiles at 1 ms resolution", () => {
    const h = new LatencyHistogram(1_000);
    for (let i = 1; i <= 100; i += 1) h.record(i - 0.5);
    expect(h.total).toBe(100);
    expect(h.percentile(50)).toBe(50);
    expect(h.percentile(95)).toBe(95);
    expect(h.percentile(99)).toBe(99);
    expect(h.summary().max).toBe(100);
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
    });
  });
});

describe("capacity timeline", () => {
  it("starts the measurement window after ramp + settle", () => {
    expect(windowOf({ rampMs: 120_000, settleMs: 30_000, measureMs: 900_000 })).toEqual({
      startMs: 150_000,
      endMs: 1_050_000,
    });
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
