import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { chromium, type Browser, type BrowserContext, type Page } from "playwright-core";

import type { ScreencastConfig } from "./config.js";
import { chromiumExecutableExists } from "./pool.js";
import {
  SCREENCAST_LADDER,
  captureScreenshot,
  frameMagicFormat,
  probeWebpSupport,
  startScreencast,
  type ScreencastFrame,
} from "./screencast.js";
import { startTestPageServer, type TestPageServer } from "./test/testServer.js";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ---------------------------------------------------------------------------
// Pure-unit leg — magic-byte sniffing + the research §5 ladder, no chromium.
// ---------------------------------------------------------------------------

describe("frameMagicFormat + SCREENCAST_LADDER (unit — no chromium)", () => {
  it("RIFF....WEBP → \"webp\"", () => {
    const webp = Buffer.from([
      0x52, 0x49, 0x46, 0x46, // "RIFF"
      0x00, 0x00, 0x00, 0x00, // riff length
      0x57, 0x45, 0x42, 0x50, // "WEBP"
      0x00, 0x00,
    ]);
    expect(frameMagicFormat(webp)).toBe("webp");
  });

  it("FFD8 prefix → \"jpeg\"", () => {
    const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46]);
    expect(frameMagicFormat(jpeg)).toBe("jpeg");
  });

  it("89504E47 → \"png\"", () => {
    const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    expect(frameMagicFormat(png)).toBe("png");
  });

  it("garbage, empty, and truncated buffers → null", () => {
    expect(frameMagicFormat(Buffer.from("hello world, definitely an image"))).toBe(null);
    expect(frameMagicFormat(Buffer.alloc(0))).toBe(null);
    // "RIFF" present but the container tag is not WEBP (WAV, AVI, ...).
    expect(
      frameMagicFormat(Buffer.from([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45])),
    ).toBe(null);
    // Truncated RIFF header (< 12 bytes) must not read past the end.
    expect(frameMagicFormat(Buffer.from([0x52, 0x49, 0x46, 0x46]))).toBe(null);
    // Single-byte jpeg/png prefixes must not read past the end either.
    expect(frameMagicFormat(Buffer.from([0xff]))).toBe(null);
    expect(frameMagicFormat(Buffer.from([0x89, 0x50]))).toBe(null);
  });

  it("SCREENCAST_LADDER pins the research §5 knob-2 steps", () => {
    expect(SCREENCAST_LADDER).toEqual([
      { quality: 60, everyNthFrame: 2 },
      { quality: 50, everyNthFrame: 3 },
      { quality: 40, everyNthFrame: 4 },
    ]);
  });
});

// ---------------------------------------------------------------------------
// Failure-path unit leg — stubbed CDP session (no chromium): the start-reject
// leak pin (I-1) and the adjust live-flag pin (M-2).
// ---------------------------------------------------------------------------

/** Minimal CDPSession stub: records on/off/detach, startScreencast fails on demand. */
function stubCdpPage(): {
  page: Page;
  cdp: {
    on: ReturnType<typeof vi.fn>;
    off: ReturnType<typeof vi.fn>;
    send: ReturnType<typeof vi.fn>;
    detach: ReturnType<typeof vi.fn>;
    failNextStart(): void;
  };
} {
  let failStart = false;
  const cdp = {
    on: vi.fn(),
    off: vi.fn(),
    send: vi.fn(async (method: string) => {
      if (method === "Page.startScreencast" && failStart) throw new Error("start rejected by stub");
      return {};
    }),
    detach: vi.fn(async () => {}),
    failNextStart(): void {
      failStart = true;
    },
  };
  const context = { newCDPSession: vi.fn(async () => cdp) };
  const page = { context: () => context } as unknown as Page;
  return { page, cdp };
}

describe("screencast failure paths (unit — stubbed CDP)", () => {
  const cfg: ScreencastConfig = {
    width: 400,
    height: 300,
    quality: 60,
    everyNthFrame: 2,
    maxFramesInFlight: 2,
  };

  it("startScreencast start-reject: listener removed + CDP session detached, original error rethrown (I-1)", async () => {
    const { page, cdp } = stubCdpPage();
    cdp.failNextStart();
    await expect(startScreencast(page, cfg, () => {})).rejects.toThrow("start rejected by stub");
    expect(cdp.off).toHaveBeenCalledWith("Page.screencastFrame", expect.any(Function));
    expect(cdp.detach).toHaveBeenCalledTimes(1);
  });

  it("drops credential-period frames and refresh captures without replaying them later", async () => {
    const { page, cdp } = stubCdpPage();
    let credentialActive = true;
    const forwarded: Buffer[] = [];
    cdp.send.mockImplementation(async (method: string) => {
      if (method === "Page.captureScreenshot") return { data: Buffer.from([0xff, 0xd8, 9]).toString("base64") };
      return {};
    });
    const handle = await startScreencast(page, cfg, (frame) => forwarded.push(frame.data), {
      isCredentialOperationActive: () => credentialActive,
    } as never);
    const listener = cdp.on.mock.calls.find((call) => call[0] === "Page.screencastFrame")![1] as (event: {
      data: string;
      sessionId: number;
    }) => void;
    listener({ data: Buffer.from([0xff, 0xd8, 1]).toString("base64"), sessionId: 1 });
    await handle.refresh();
    expect(forwarded).toEqual([]);
    expect(cdp.send).toHaveBeenCalledWith("Page.screencastFrameAck", { sessionId: 1 });
    expect(cdp.send).not.toHaveBeenCalledWith("Page.captureScreenshot", expect.anything());
    credentialActive = false;
    await handle.refresh();
    listener({ data: Buffer.from([0xff, 0xd8, 2]).toString("base64"), sessionId: 2 });
    expect(forwarded.map((frame) => frame[2])).toEqual([9, 2]);
    await handle.stop();
  });

  it("UNEXECUTED review C2: an old cast epoch cannot forward a delayed frame after unlock", async () => {
    const { page, cdp } = stubCdpPage();
    let epoch = 0;
    let credentialActive = false;
    const forwarded: Buffer[] = [];
    const gate = {
      credentialEpoch: () => epoch,
      isCredentialOperationActive: () => credentialActive,
    };
    const oldHandle = await startScreencast(page, cfg, (frame) => forwarded.push(frame.data), gate as never);
    const oldListener = cdp.on.mock.calls.find((call) => call[0] === "Page.screencastFrame")![1] as (event: {
      data: string;
      sessionId: number;
    }) => void;
    credentialActive = true;
    epoch += 1;
    credentialActive = false;
    oldListener({ data: Buffer.from([0xff, 0xd8, 1]).toString("base64"), sessionId: 1 });
    expect(forwarded).toEqual([]);
    await oldHandle.stop();

    const freshHandle = await startScreencast(page, cfg, (frame) => forwarded.push(frame.data), gate as never);
    const freshListener = cdp.on.mock.calls.filter((call) => call[0] === "Page.screencastFrame").at(-1)![1] as (event: {
      data: string;
      sessionId: number;
    }) => void;
    freshListener({ data: Buffer.from([0xff, 0xd8, 2]).toString("base64"), sessionId: 2 });
    expect(forwarded.map((frame) => frame[2])).toEqual([2]);
    await freshHandle.stop();
  });

  it("UNEXECUTED review C2: a delayed refresh captured in an old epoch is discarded after unlock", async () => {
    const { page, cdp } = stubCdpPage();
    let epoch = 0;
    let credentialActive = false;
    let markCaptureStarted!: () => void;
    const captureStarted = new Promise<void>((resolve) => {
      markCaptureStarted = resolve;
    });
    let finishCapture!: () => void;
    const capture = new Promise<void>((resolve) => {
      finishCapture = resolve;
    });
    const forwarded: Buffer[] = [];
    cdp.send.mockImplementation(async (method: string) => {
      if (method === "Page.captureScreenshot") {
        markCaptureStarted();
        await capture;
        return { data: Buffer.from([0xff, 0xd8, 9]).toString("base64") };
      }
      return {};
    });
    const handle = await startScreencast(page, cfg, (frame) => forwarded.push(frame.data), {
      credentialEpoch: () => epoch,
      isCredentialOperationActive: () => credentialActive,
    } as never);
    const refreshing = handle.refresh();
    await captureStarted;
    credentialActive = true;
    epoch += 1;
    credentialActive = false;
    finishCapture();
    await refreshing;
    expect(forwarded).toEqual([]);
    await handle.stop();
  });

  it("refuses a direct screenshot before calling page.screenshot during credential work", async () => {
    const screenshot = vi.fn(async () => Buffer.from("ordinary"));
    const page = { screenshot } as unknown as Page;
    await expect(
      captureScreenshot(page, {
        type: "png",
        isCredentialOperationActive: () => true,
      } as never),
    ).rejects.toMatchObject({ code: "credential_operation_in_progress" });
    expect(screenshot).not.toHaveBeenCalled();
  });

  it("adjust() restart failure marks the handle stopped before rethrowing — no live-flagged dead cast (M-2)", async () => {
    const { page, cdp } = stubCdpPage();
    const handle = await startScreencast(page, cfg, () => {});
    cdp.failNextStart();
    await expect(handle.adjust({ quality: 40, everyNthFrame: 4 })).rejects.toThrow("start rejected by stub");
    // The handle is dead: any further adjust is the stopped-handle error.
    await expect(handle.adjust({ quality: 50, everyNthFrame: 3 })).rejects.toThrow(
      "Cannot adjust a stopped screencast.",
    );
    // stop() still releases the session cleanly afterwards.
    await expect(handle.stop()).resolves.toBeUndefined();
    expect(cdp.detach).toHaveBeenCalledTimes(1);
  });
});

// ---------------------------------------------------------------------------
// Frame-rate cap (Wave 5 R3) — stubbed CDP + fake timers: chromium may emit
// at 20+ fps on an animated page, but the viewer sees 3–5 fps and chromium is
// held (unacked) between slots so it never encodes frames nobody will see.
// ---------------------------------------------------------------------------

describe("screencast frame-rate cap (unit — stubbed CDP)", () => {
  const cfg: ScreencastConfig = {
    width: 400,
    height: 300,
    quality: 60,
    everyNthFrame: 2,
    maxFramesInFlight: 1,
    maxFps: 4,
  };

  afterEach(() => {
    vi.useRealTimers();
  });

  function frameEmitter(cdp: ReturnType<typeof stubCdpPage>["cdp"]): (id: number) => void {
    const listener = cdp.on.mock.calls.find((c) => c[0] === "Page.screencastFrame")![1] as (ev: {
      data: string;
      sessionId: number;
    }) => void;
    return (id: number) => listener({ data: Buffer.from([0xff, 0xd8, id]).toString("base64"), sessionId: id });
  }

  function acked(cdp: ReturnType<typeof stubCdpPage>["cdp"]): number[] {
    return cdp.send.mock.calls
      .filter((c) => c[0] === "Page.screencastFrameAck")
      .map((c) => (c[1] as { sessionId: number }).sessionId);
  }

  it("a 20 fps source is forwarded at <= 4 fps over 2 s, and the LAST frame always lands (trailing edge)", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    const { page, cdp } = stubCdpPage();
    const forwarded: number[] = [];
    await startScreencast(page, cfg, (f) => forwarded.push(f.data[2]));
    const emit = frameEmitter(cdp);
    for (let i = 1; i <= 40; i++) {
      emit(i);
      await vi.advanceTimersByTimeAsync(50);
    }
    await vi.advanceTimersByTimeAsync(500);
    // 2 s at 4 fps ⇒ 8 slots (+1 for the immediate first frame).
    expect(forwarded.length).toBeGreaterThanOrEqual(6);
    expect(forwarded.length).toBeLessThanOrEqual(10);
    expect(forwarded[0]).toBe(1);
    expect(forwarded[forwarded.length - 1]).toBe(40);
  });

  it("a held frame stays UNACKED until its slot — chromium is paced, not just the wire", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    const { page, cdp } = stubCdpPage();
    await startScreencast(page, cfg, () => {});
    const emit = frameEmitter(cdp);
    emit(1); // forwarded + acked at once
    await vi.advanceTimersByTimeAsync(0);
    expect(acked(cdp)).toEqual([1]);
    emit(2); // too early: held, NOT acked
    await vi.advanceTimersByTimeAsync(100);
    expect(acked(cdp)).toEqual([1]);
    await vi.advanceTimersByTimeAsync(200); // the 250 ms slot passed
    expect(acked(cdp)).toEqual([1, 2]);
  });

  it("refresh() captures and forwards one fresh frame in the cast's format (a static page emits no damage frames)", async () => {
    const { page, cdp } = stubCdpPage();
    const forwarded: Buffer[] = [];
    const handle = await startScreencast(page, cfg, (f) => forwarded.push(f.data), { format: "webp" });
    cdp.send.mockImplementation(async (method: string) =>
      method === "Page.captureScreenshot" ? { data: Buffer.from([0xff, 0xd8, 0x07]).toString("base64") } : {},
    );
    cdp.send.mockClear();
    await handle.refresh();
    expect(cdp.send).toHaveBeenCalledWith("Page.captureScreenshot", { format: "webp", quality: 60 });
    expect(forwarded.map((b) => b[2])).toEqual([7]);
    expect(handle.framesSent()).toBe(1);
  });

  it("refresh() on a stopped cast is a no-op", async () => {
    const { page, cdp } = stubCdpPage();
    const handle = await startScreencast(page, cfg, () => {});
    await handle.stop();
    cdp.send.mockClear();
    await handle.refresh();
    expect(cdp.send).not.toHaveBeenCalled();
  });

  it("no maxFps ⇒ every frame is forwarded (legacy behaviour)", async () => {
    const { page, cdp } = stubCdpPage();
    const forwarded: number[] = [];
    await startScreencast(page, { ...cfg, maxFps: undefined }, (f) => forwarded.push(f.data[2]));
    const emit = frameEmitter(cdp);
    for (let i = 1; i <= 5; i++) emit(i);
    expect(forwarded).toEqual([1, 2, 3, 4, 5]);
  });
});

// ---------------------------------------------------------------------------
// Chromium-gated leg — real chromium against the fixture server. Screencast
// is damage-driven, so every frame-producing test navigates to /animated
// (the fixture that repaints every 100 ms; a static page yields 0 frames by
// design). Real timers throughout: frame arrival is event-driven, and the
// wave guidance's {toFake:["setTimeout","clearTimeout"]} workaround is only
// needed when fake timers are used at all — none of these tests are.
// ---------------------------------------------------------------------------

describe.skipIf(!chromiumExecutableExists())("screencast (chromium)", () => {
  const cfg: ScreencastConfig = {
    width: 400,
    height: 300,
    quality: 60,
    everyNthFrame: 2,
    maxFramesInFlight: 2,
  };

  let browser: Browser;
  let server: TestPageServer;
  const contexts: BrowserContext[] = [];

  beforeAll(async () => {
    server = await startTestPageServer();
    browser = await chromium.launch({ headless: true, args: ["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"] });
  }, 30_000);

  afterAll(async () => {
    await browser.close();
    await server.close();
  });

  afterEach(async () => {
    for (const context of contexts.splice(0)) await context.close();
  });

  async function newPage(path: string): Promise<Page> {
    const context = await browser.newContext({ viewport: { width: cfg.width, height: cfg.height } });
    contexts.push(context);
    const page = await context.newPage();
    await page.goto(server.url(path));
    return page;
  }

  it("startScreencast(jpeg) on /animated: ≥3 frames in ≤10 s, every frame jpeg-magic, framesSent() matches", async () => {
    const page = await newPage("/animated");
    const frames: ScreencastFrame[] = [];
    const handle = await startScreencast(page, cfg, (f) => {
      frames.push(f);
    });

    const deadline = Date.now() + 10_000;
    while (frames.length < 3 && Date.now() < deadline) await sleep(50);

    expect(frames.length).toBeGreaterThanOrEqual(3);
    expect(handle.framesSent()).toBe(frames.length);
    expect(handle.format()).toBe("jpeg");
    for (const f of frames) {
      expect(frameMagicFormat(f.data)).toBe("jpeg");
      expect(f.format).toBe("jpeg");
      expect(f.data.length).toBeGreaterThan(0);
    }
    await handle.stop();
  }, 15_000);

  it("stop(): no further frames for 500 ms, and a second stop() resolves without throwing", async () => {
    const page = await newPage("/animated");
    const frames: ScreencastFrame[] = [];
    const handle = await startScreencast(page, cfg, (f) => {
      frames.push(f);
    });
    await vi.waitFor(() => expect(frames.length).toBeGreaterThan(0), { timeout: 10_000 });

    await handle.stop();
    const count = frames.length;
    await sleep(500);
    expect(frames.length).toBe(count); // page still animating — silence proves the stop

    await expect(handle.stop()).resolves.toBeUndefined();
  }, 15_000);

  it("adjust({quality:40,everyNthFrame:4}) keeps delivering frames afterwards (stop+restart, same format)", async () => {
    const page = await newPage("/animated");
    const frames: ScreencastFrame[] = [];
    const handle = await startScreencast(page, cfg, (f) => {
      frames.push(f);
    });
    await vi.waitFor(() => expect(frames.length).toBeGreaterThan(0), { timeout: 10_000 });

    await handle.adjust({ quality: 40, everyNthFrame: 4 });
    const atAdjust = frames.length;
    await vi.waitFor(() => expect(frames.length).toBeGreaterThan(atAdjust), { timeout: 10_000 });

    for (const f of frames) expect(frameMagicFormat(f.data)).toBe("jpeg");
    expect(handle.format()).toBe("jpeg"); // adjust never changes the format
    expect(handle.framesSent()).toBe(frames.length);
    await handle.stop();
  }, 20_000);

  it("probeWebpSupport returns a boolean and leaves no screencast running (fresh CDP session casts fine)", async () => {
    const page = await newPage("/animated");
    const result = await probeWebpSupport(page, cfg);
    expect(typeof result).toBe("boolean");

    // Cleanup proof: a FRESH CDP session can start a screencast on the same
    // page and frames actually flow — no leaked session, no stuck cast.
    const cdp = await page.context().newCDPSession(page);
    const got: Buffer[] = [];
    const onFrame = (ev: { data: string; sessionId: number }) => {
      got.push(Buffer.from(ev.data, "base64"));
      void cdp.send("Page.screencastFrameAck", { sessionId: ev.sessionId }).catch(() => {});
    };
    cdp.on("Page.screencastFrame", onFrame);
    await cdp.send("Page.startScreencast", {
      format: "jpeg",
      quality: cfg.quality,
      maxWidth: cfg.width,
      maxHeight: cfg.height,
      everyNthFrame: 1,
      maxFramesInFlight: cfg.maxFramesInFlight,
    });
    await vi.waitFor(() => expect(got.length).toBeGreaterThan(0), { timeout: 10_000 });
    expect(frameMagicFormat(got[0])).toBe("jpeg");
    await cdp.send("Page.stopScreencast");
    cdp.off("Page.screencastFrame", onFrame);
    await cdp.detach();
  }, 20_000);

  // CI asserts boolean-ness only (whether webp lands depends on the pinned
  // chromium build); the dev box additionally pins `true` so a future
  // chromium bump fails loudly here, not flakily in CI (research §3.2).
  it.skipIf(process.env.CI)("probeWebpSupport returns true on the pinned chromium build (dev-box guard)", async () => {
    const page = await newPage("/animated");
    await expect(probeWebpSupport(page, cfg)).resolves.toBe(true);
  }, 20_000);

  it("captureScreenshot: default jpeg q70 → FFD8 magic and >1 KB; explicit png → PNG magic", async () => {
    const page = await newPage("/big");
    const jpeg = await captureScreenshot(page);
    expect(frameMagicFormat(jpeg)).toBe("jpeg");
    expect(jpeg.length).toBeGreaterThan(1024);

    const jpeg40 = await captureScreenshot(page, { type: "jpeg", quality: 40 });
    expect(frameMagicFormat(jpeg40)).toBe("jpeg");

    const png = await captureScreenshot(page, { type: "png" });
    expect(frameMagicFormat(png)).toBe("png");
  }, 15_000);
});
