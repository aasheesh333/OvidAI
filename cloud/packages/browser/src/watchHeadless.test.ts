import { afterEach, describe, expect, it, vi } from "vitest";

import { WATCH_IDLE_HEADLESS_MS, createWatchHeadless } from "./watchHeadless.js";

/**
 * Product spec §8: 45 s with no human input while watched → headless (frames
 * stop, the session stays alive); "Take control" resumes streaming. Fake
 * timers make the boundary exact.
 */
describe("watch inactivity → headless", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  function controller() {
    const onHeadless = vi.fn();
    const onResume = vi.fn();
    const watch = createWatchHeadless({ idleMs: WATCH_IDLE_HEADLESS_MS, onHeadless, onResume });
    return { watch, onHeadless, onResume };
  }

  it("defaults to 45 s", () => {
    expect(WATCH_IDLE_HEADLESS_MS).toBe(45_000);
  });

  it("a watching session goes headless at exactly 45 s without input", () => {
    vi.useFakeTimers();
    const { watch, onHeadless } = controller();
    watch.viewerJoined("user-u1");
    expect(watch.pending("user-u1")).toBe(true);
    expect(watch.isHeadless("user-u1")).toBe(false);

    vi.advanceTimersByTime(44_999);
    expect(watch.isHeadless("user-u1")).toBe(false);
    expect(onHeadless).not.toHaveBeenCalled();

    vi.advanceTimersByTime(1);
    expect(watch.isHeadless("user-u1")).toBe(true);
    expect(onHeadless).toHaveBeenCalledTimes(1);
    expect(onHeadless).toHaveBeenCalledWith("user-u1");
    expect(watch.pending("user-u1")).toBe(false);
    expect(watch.headlessSessions()).toEqual(["user-u1"]);
  });

  it("human activity resets the window (it never fires mid-interaction)", () => {
    vi.useFakeTimers();
    const { watch, onHeadless } = controller();
    watch.viewerJoined("s1");

    vi.advanceTimersByTime(30_000);
    watch.humanActivity("s1"); // pointer/key event at t=30 s
    vi.advanceTimersByTime(30_000); // t=60 s — only 30 s since activity
    expect(onHeadless).not.toHaveBeenCalled();

    vi.advanceTimersByTime(15_000); // t=75 s — 45 s since activity
    expect(onHeadless).toHaveBeenCalledTimes(1);
  });

  it("Take control on a headless page resumes streaming immediately", () => {
    vi.useFakeTimers();
    const { watch, onHeadless, onResume } = controller();
    watch.viewerJoined("s1");
    vi.advanceTimersByTime(45_000);
    expect(watch.isHeadless("s1")).toBe(true);

    watch.takeControl("s1");
    expect(watch.isHeadless("s1")).toBe(false);
    expect(onResume).toHaveBeenCalledTimes(1);
    expect(onResume).toHaveBeenCalledWith("s1");
    expect(watch.pending("s1")).toBe(true); // a fresh 45 s window
    expect(onHeadless).toHaveBeenCalledTimes(1); // no duplicate headless event
  });

  it("a viewer re-join on a headless page resumes the stream", () => {
    vi.useFakeTimers();
    const { watch, onResume } = controller();
    watch.viewerJoined("s1");
    vi.advanceTimersByTime(45_000);
    expect(watch.isHeadless("s1")).toBe(true);

    watch.viewerJoined("s1"); // the app re-opened the Browser screen
    expect(watch.isHeadless("s1")).toBe(false);
    expect(onResume).toHaveBeenCalledTimes(1);
  });

  it("any input on a headless page resumes it (Take control is not the only path)", () => {
    vi.useFakeTimers();
    const { watch, onResume } = controller();
    watch.viewerJoined("s1");
    vi.advanceTimersByTime(45_000);
    watch.humanActivity("s1");
    expect(watch.isHeadless("s1")).toBe(false);
    expect(onResume).toHaveBeenCalledTimes(1);
  });

  it("the last viewer leaving cancels the clock (detach grace owns that path)", () => {
    vi.useFakeTimers();
    const { watch, onHeadless } = controller();
    watch.viewerJoined("s1");
    vi.advanceTimersByTime(40_000);
    watch.viewerLeft("s1");
    expect(watch.pending("s1")).toBe(false);
    vi.advanceTimersByTime(60_000);
    expect(onHeadless).not.toHaveBeenCalled();
  });

  it("idleMs <= 0 disables the conversion", () => {
    vi.useFakeTimers();
    const onHeadless = vi.fn();
    const watch = createWatchHeadless({ idleMs: 0, onHeadless });
    watch.viewerJoined("s1");
    vi.advanceTimersByTime(120_000);
    expect(onHeadless).not.toHaveBeenCalled();
    expect(watch.isHeadless("s1")).toBe(false);
  });

  it("forget/clear drop state and pending timers", () => {
    vi.useFakeTimers();
    const { watch, onHeadless } = controller();
    watch.viewerJoined("a");
    watch.viewerJoined("b");
    watch.forget("a");
    expect(watch.pending("a")).toBe(false);
    watch.clear();
    expect(watch.pending("b")).toBe(false);
    vi.advanceTimersByTime(60_000);
    expect(onHeadless).not.toHaveBeenCalled();
  });
});
