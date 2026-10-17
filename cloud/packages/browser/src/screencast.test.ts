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
