import { describe, expect, it, vi } from "vitest";
import { createDeltaCoalescer, deltaCoalesceMsFromEnv } from "./deltaCoalescer.js";

function deferred(): { promise: Promise<void>; resolve(): void } {
  let resolve!: () => void;
  const promise = new Promise<void>((res) => {
    resolve = res;
  });
  return { promise, resolve };
}

const tick = (): Promise<void> => new Promise((r) => setImmediate(r));

describe("createDeltaCoalescer", () => {
  it("emits the first delta immediately and merges the rest per window", async () => {
    vi.useFakeTimers();
    try {
      const emitted: string[] = [];
      const c = createDeltaCoalescer(async (t) => void emitted.push(t), { windowMs: 50 });
      c.push("a");
      expect(emitted).toEqual(["a"]); // first token: synchronous, no window
      await vi.advanceTimersByTimeAsync(0);
      c.push("b");
      c.push("c");
      expect(emitted).toEqual(["a"]);
      await vi.advanceTimersByTimeAsync(50);
      expect(emitted).toEqual(["a", "bc"]);
      c.push("d");
      await c.drain(); // drain bypasses the window
      expect(emitted).toEqual(["a", "bc", "d"]);
    } finally {
      vi.useRealTimers();
    }
  });

  it("preserves order and exact text while an emit is in flight (backpressure merge)", async () => {
    const gates: Array<ReturnType<typeof deferred>> = [];
    const emitted: string[] = [];
    const c = createDeltaCoalescer(
      (t) => {
        emitted.push(t);
        const g = deferred();
        gates.push(g);
        return g.promise;
      },
      { windowMs: 0 },
    );
    c.push("h");
    c.push("e");
    c.push("l");
    expect(emitted).toEqual(["h"]);
    gates[0]!.resolve();
    await tick();
    expect(emitted).toEqual(["h", "el"]);
    c.push("lo");
    const drained = c.drain();
    gates[1]!.resolve();
    await tick();
    gates[2]?.resolve();
    await drained;
    expect(emitted).toEqual(["h", "el", "lo"]);
    expect(emitted.join("")).toBe("hello");
  });

  it("windowMs=0 with a fast sink keeps one event per delta", async () => {
    const emitted: string[] = [];
    const c = createDeltaCoalescer(async (t) => void emitted.push(t), { windowMs: 0 });
    for (const t of ["x", "y", "z"]) {
      c.push(t);
      await tick();
    }
    await c.drain();
    expect(emitted).toEqual(["x", "y", "z"]);
  });

  it("surfaces the first emit failure at drain and stops emitting", async () => {
    const emitted: string[] = [];
    let calls = 0;
    const c = createDeltaCoalescer(
      async (t) => {
        calls += 1;
        if (calls === 1) throw new Error("redis down");
        emitted.push(t);
      },
      { windowMs: 0 },
    );
    c.push("a");
    await tick();
    c.push("b");
    await expect(c.drain()).rejects.toThrow("redis down");
    expect(emitted).toEqual([]);
  });

  it("turns a synchronous emit throw into a drain rejection", async () => {
    const c = createDeltaCoalescer(
      () => {
        throw new Error("sync boom");
      },
      { windowMs: 10 },
    );
    c.push("a");
    await expect(c.drain()).rejects.toThrow("sync boom");
  });

  it("drain on an idle coalescer resolves; empty pushes are ignored", async () => {
    const sink = vi.fn(async () => {});
    const c = createDeltaCoalescer(sink, { windowMs: 50 });
    c.push("");
    await c.drain();
    expect(sink).not.toHaveBeenCalled();
  });

  it("never leaves a stray timer after drain", async () => {
    vi.useFakeTimers();
    try {
      const emitted: string[] = [];
      const c = createDeltaCoalescer(async (t) => void emitted.push(t), { windowMs: 50 });
      c.push("a");
      c.push("b"); // buffered behind the in-flight "a"
      await c.drain();
      expect(emitted).toEqual(["a", "b"]);
      expect(vi.getTimerCount()).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("deltaCoalesceMsFromEnv", () => {
  it("defaults to 50 and validates", () => {
    expect(deltaCoalesceMsFromEnv({})).toBe(50);
    expect(deltaCoalesceMsFromEnv({ OVID_DELTA_COALESCE_MS: "0" })).toBe(0);
    expect(deltaCoalesceMsFromEnv({ OVID_DELTA_COALESCE_MS: "120" })).toBe(120);
    expect(() => deltaCoalesceMsFromEnv({ OVID_DELTA_COALESCE_MS: "-1" })).toThrow(
      /OVID_DELTA_COALESCE_MS/,
    );
    expect(() => deltaCoalesceMsFromEnv({ OVID_DELTA_COALESCE_MS: "abc" })).toThrow(
      /OVID_DELTA_COALESCE_MS/,
    );
  });
});
