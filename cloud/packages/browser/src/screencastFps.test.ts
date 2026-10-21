import { afterEach, describe, expect, it, vi } from "vitest";
import type { Page } from "playwright-core";

import type { ScreencastConfig } from "./config.js";
import { SCREENCAST_FPS_MAX, SCREENCAST_FPS_MIN, clampScreencastFps, startScreencast } from "./screencast.js";

/**
 * Product spec §8: the live view streams at 3–5 fps (default 4), dropping
 * stale frames instead of queueing them, and exposes the ACTUAL fps in the
 * stream metadata. Stubbed CDP + fake timers keep the boundary exact.
 */

interface StubCdp {
  on: ReturnType<typeof vi.fn>;
  off: ReturnType<typeof vi.fn>;
  send: ReturnType<typeof vi.fn>;
  detach: ReturnType<typeof vi.fn>;
}

function stubCdpPage(): { page: Page; cdp: StubCdp } {
  const cdp: StubCdp = {
    on: vi.fn(),
    off: vi.fn(),
    send: vi.fn(async () => ({})),
    detach: vi.fn(async () => {}),
  };
  const context = { newCDPSession: vi.fn(async () => cdp) };
  return { page: { context: () => context } as unknown as Page, cdp };
}

function frameEmitter(cdp: StubCdp): (id: number) => void {
  const listener = cdp.on.mock.calls.find((c) => c[0] === "Page.screencastFrame")![1] as (ev: {
    data: string;
    sessionId: number;
  }) => void;
  return (id: number) => listener({ data: Buffer.from([0xff, 0xd8, id]).toString("base64"), sessionId: id });
}

const cfg: ScreencastConfig = {
  width: 400,
  height: 300,
  quality: 60,
  everyNthFrame: 2,
  maxFramesInFlight: 1,
  maxFps: 4,
};

describe("screencast fps metadata + stale-frame dropping", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("clampScreencastFps pins the 3–5 band with a 4 fps default", () => {
    expect(clampScreencastFps(undefined)).toBe(4);
    expect(clampScreencastFps(1)).toBe(SCREENCAST_FPS_MIN);
    expect(clampScreencastFps(3)).toBe(3);
    expect(clampScreencastFps(4)).toBe(4);
    expect(clampScreencastFps(5)).toBe(5);
    expect(clampScreencastFps(30)).toBe(SCREENCAST_FPS_MAX);
  });

  it("a 20 fps source is delivered at 3–5 fps; stale frames are dropped, not queued", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    const { page, cdp } = stubCdpPage();
    const frames: Array<{ fps?: number; sequence?: number; id: number }> = [];
    const handle = await startScreencast(page, cfg, (f) => {
      frames.push({ fps: f.fps, sequence: f.sequence, id: f.data[2] });
    });
    const emit = frameEmitter(cdp);
    for (let i = 1; i <= 40; i++) {
      emit(i);
      await vi.advanceTimersByTimeAsync(50);
    }

    const meta = handle.metadata();
    expect(meta.targetFps).toBe(4);
    expect(meta.format).toBe("jpeg");
    expect(meta.sampleWindowMs).toBe(1_000);
    expect(meta.framesDelivered).toBe(handle.framesSent());
    expect(meta.framesDelivered).toBeLessThanOrEqual(10); // 2 s at ~4 fps
    expect(meta.framesDropped).toBeGreaterThan(20); // 40 emitted, ~9 delivered
    expect(meta.framesDelivered + meta.framesDropped).toBeLessThanOrEqual(40);
    // Actual fps is measured, not the configured cap; every reported value
    // is inside the spec band once the window is warm.
    expect(meta.actualFps).toBeGreaterThanOrEqual(SCREENCAST_FPS_MIN);
    expect(meta.actualFps).toBeLessThanOrEqual(SCREENCAST_FPS_MAX);
    expect(meta.fps).toBe(meta.actualFps);
    expect(Math.max(...frames.map((f) => f.fps ?? 0))).toBeLessThanOrEqual(SCREENCAST_FPS_MAX);
    expect(frames.some((f) => (f.fps ?? 0) >= SCREENCAST_FPS_MIN)).toBe(true);
    // Sequence is monotonic; the last emitted frame always lands (trailing edge).
    expect(frames.map((f) => f.sequence)).toEqual(frames.map((_, i) => i + 1));
    expect(frames[frames.length - 1]!.id).toBe(40);
  });

  it("no target fps ⇒ uncapped legacy mode, nothing dropped, targetFps 0", async () => {
    const { page, cdp } = stubCdpPage();
    const frames: Array<{ fps?: number }> = [];
    const handle = await startScreencast(page, { ...cfg, maxFps: undefined }, (f) => frames.push({ fps: f.fps }));
    const emit = frameEmitter(cdp);
    for (let i = 1; i <= 5; i++) emit(i);
    expect(handle.framesSent()).toBe(5);
    expect(handle.droppedFrames()).toBe(0);
    expect(handle.metadata().targetFps).toBe(0);
    expect(handle.metadata().actualFps).toBe(5);
    expect(frames).toHaveLength(5);
  });

  it("stop() drops a pending stale frame and reports the counters", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    const { page, cdp } = stubCdpPage();
    const handle = await startScreencast(page, cfg, () => {});
    const emit = frameEmitter(cdp);
    emit(1); // delivered
    emit(2); // held for the next slot
    expect(handle.droppedFrames()).toBe(0);
    await handle.stop();
    expect(handle.droppedFrames()).toBe(1);
    expect(handle.metadata().framesDelivered).toBe(1);
  });
});
