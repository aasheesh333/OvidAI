import { describe, expect, it } from "vitest";
import { createCachedDiskUsage, DISK_USAGE_CACHE_MS } from "./manager.js";

describe("createCachedDiskUsage (capacity wave: no full-tree walk per attach)", () => {
  it("shares one in-flight walk between concurrent callers", async () => {
    let calls = 0;
    let release!: () => void;
    const gate = new Promise<void>((r) => {
      release = r;
    });
    const usage = createCachedDiskUsage(async () => {
      calls += 1;
      await gate;
      return { freeGb: 50, warmGb: 1 };
    });
    const all = Promise.all(Array.from({ length: 100 }, () => usage()));
    release();
    const results = await all;
    expect(calls).toBe(1);
    expect(results.every((r) => r.freeGb === 50 && r.warmGb === 1)).toBe(true);
  });

  it("serves the cached value inside the TTL and recomputes after it", async () => {
    let t = 0;
    let free = 50;
    let calls = 0;
    const usage = createCachedDiskUsage(
      async () => {
        calls += 1;
        return { freeGb: free, warmGb: 0 };
      },
      1_000,
      () => t,
    );
    expect((await usage()).freeGb).toBe(50);
    free = 1;
    t = 999;
    expect((await usage()).freeGb).toBe(50);
    expect(calls).toBe(1);
    t = 1_000;
    expect((await usage()).freeGb).toBe(1); // pressure becomes visible after ≤ TTL
    expect(calls).toBe(2);
  });

  it("does not cache a failed walk", async () => {
    let calls = 0;
    const usage = createCachedDiskUsage(async () => {
      calls += 1;
      if (calls === 1) throw new Error("EIO");
      return { freeGb: 10, warmGb: 0 };
    });
    await expect(usage()).rejects.toThrow("EIO");
    await expect(usage()).resolves.toEqual({ freeGb: 10, warmGb: 0 });
    expect(calls).toBe(2);
  });

  it("defaults to a 30 s TTL", () => {
    expect(DISK_USAGE_CACHE_MS).toBe(30_000);
  });
});
