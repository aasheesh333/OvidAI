import { afterEach, describe, expect, it, vi } from "vitest";

import { createDetachGrace } from "./detachGrace.js";

/**
 * Wave 6 W4 — the 45 s grace window. Fake timers make the boundary exact:
 * 44,999 ms still renders, the next millisecond converts to headless.
 */
describe("detach grace window", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("keeps the renderer for exactly 45 s, then expires", () => {
    vi.useFakeTimers();
    const onExpire = vi.fn();
    const grace = createDetachGrace({ graceMs: 45_000 });

    grace.schedule("user-u1", onExpire);
    expect(grace.pending("user-u1")).toBe(true);

    vi.advanceTimersByTime(44_999);
    expect(onExpire).not.toHaveBeenCalled();
    expect(grace.pending("user-u1")).toBe(true);

    vi.advanceTimersByTime(1);
    expect(onExpire).toHaveBeenCalledTimes(1);
    expect(grace.pending("user-u1")).toBe(false);
    expect(grace.size()).toBe(0);
  });

  it("a re-open cancels the pending conversion and keeps the cast", () => {
    vi.useFakeTimers();
    const onExpire = vi.fn();
    const grace = createDetachGrace({ graceMs: 45_000 });

    grace.schedule("user-u1", onExpire);
    vi.advanceTimersByTime(30_000);
    grace.cancel("user-u1"); // viewer_join
    vi.advanceTimersByTime(60_000);
    expect(onExpire).not.toHaveBeenCalled();
    expect(grace.pending("user-u1")).toBe(false);
  });

  it("a second leave re-arms the full window", () => {
    vi.useFakeTimers();
    const onExpire = vi.fn();
    const grace = createDetachGrace({ graceMs: 45_000 });

    grace.schedule("user-u1", onExpire);
    vi.advanceTimersByTime(40_000);
    grace.schedule("user-u1", onExpire);
    vi.advanceTimersByTime(40_000);
    expect(onExpire).not.toHaveBeenCalled();
    vi.advanceTimersByTime(5_000);
    expect(onExpire).toHaveBeenCalledTimes(1);
  });

  it("grace 0 preserves the pre-W4 immediate conversion", () => {
    const onExpire = vi.fn();
    const grace = createDetachGrace({ graceMs: 0 });
    grace.schedule("user-u1", onExpire);
    expect(onExpire).toHaveBeenCalledTimes(1);
    expect(grace.pending("user-u1")).toBe(false);
  });

  it("clear cancels every session (engine close)", () => {
    vi.useFakeTimers();
    const onExpire = vi.fn();
    const grace = createDetachGrace({ graceMs: 45_000 });
    grace.schedule("a", onExpire);
    grace.schedule("b", onExpire);
    expect(grace.size()).toBe(2);
    grace.clear();
    vi.advanceTimersByTime(60_000);
    expect(onExpire).not.toHaveBeenCalled();
    expect(grace.size()).toBe(0);
  });
});
