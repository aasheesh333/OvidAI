/**
 * ScreencastService — CDP `Page.startScreencast` streaming with ack flow
 * control, a runtime WebP probe with JPEG fallback, and one-shot screenshots.
 *
 * Pinned by research §3/§5 and the plan's Task-6 rulings:
 *  - JPEG quality 60, everyNthFrame 2 is the spec-of-record default (§7.2);
 *    WebP is only ever used via an explicit `format` AFTER a successful
 *    `probeWebpSupport` (the pinned chromium build supports it, but the
 *    probe keeps a future build bump honest).
 *  - Every frame is acked AFTER the handoff to `onFrame`
 *    (`Page.screencastFrameAck`), with `maxFramesInFlight` bounding how far
 *    chromium runs ahead of a slow consumer (§3.4) — this is the entire
 *    backpressure path.
 *  - `stop()` sends `Page.stopScreencast`, removes the listener and detaches
 *    the CDP session (Review Focus #2: no dangling sessions); it is
 *    idempotent and safe to call after the page/target is already gone.
 */

import type { BrowserFrameFormat } from "@ovid/shared";
import type { CDPSession, Page } from "playwright-core";

import type { ScreencastConfig } from "./config.js";

export interface ScreencastFrame {
  format: BrowserFrameFormat;
  data: Buffer;
}

export interface LadderStep {
  quality: number;
  everyNthFrame: number;
}

/** Research §5 knob 2 — step-down ladder for overloaded workers (Task 8). */
export const SCREENCAST_LADDER: readonly LadderStep[] = [
  { quality: 60, everyNthFrame: 2 },
  { quality: 50, everyNthFrame: 3 },
  { quality: 40, everyNthFrame: 4 },
];

export interface ScreencastHandle {
  format(): BrowserFrameFormat;
  framesSent(): number;
  /** Stop + restart the cast with new quality/everyNthFrame (same format). */
  adjust(step: LadderStep): Promise<void>;
  /** Page.stopScreencast + detach the CDP session; idempotent. */
  stop(): Promise<void>;
}

/**
 * Sniff an image buffer's magic bytes. Widened past `BrowserFrameFormat` with
 * `"png"` — the wire only ever carries jpeg/webp, but `captureScreenshot`
 * can produce PNG and callers (tests included) sniff those bytes with the
 * same helper.
 */
export type FrameMagicFormat = BrowserFrameFormat | "png";

export function frameMagicFormat(data: Buffer): FrameMagicFormat | null {
  if (data.length >= 12 && data[0] === 0x52 && data[1] === 0x49 && data[2] === 0x46 && data[3] === 0x46) {
    // "RIFF" — the container tag at bytes 8..11 decides (WEBP vs WAV/AVI/...).
    if (data[8] === 0x57 && data[9] === 0x45 && data[10] === 0x42 && data[11] === 0x50) return "webp";
    return null;
  }
  if (data.length >= 2 && data[0] === 0xff && data[1] === 0xd8) return "jpeg";
  if (data.length >= 4 && data[0] === 0x89 && data[1] === 0x50 && data[2] === 0x4e && data[3] === 0x47) return "png";
  return null;
}

/** The `Page.screencastFrame` payload shape this module consumes. */
interface ScreencastFrameEvent {
  data: string; // base64-encoded compressed image
  sessionId: number;
}

/** `Page.startScreencast` parameters, structurally identical to the protocol type. */
interface StartScreencastParams {
  format?: "jpeg" | "png";
  quality?: number;
  maxWidth?: number;
  maxHeight?: number;
  everyNthFrame?: number;
  maxFramesInFlight?: number;
}

/**
 * playwright 1.64's bundled protocol typings predate "webp" in the
 * `Page.startScreencast` format enum; the RUNTIME accepts it — which is
 * exactly what `probeWebpSupport` verifies before anyone relies on it.
 */
function startScreencastParams(format: BrowserFrameFormat, step: LadderStep, cfg: ScreencastConfig): StartScreencastParams {
  return {
    format: format as "jpeg" | "png",
    quality: step.quality,
    maxWidth: cfg.width,
    maxHeight: cfg.height,
    everyNthFrame: step.everyNthFrame,
    maxFramesInFlight: cfg.maxFramesInFlight,
  };
}

export async function startScreencast(
  page: Page,
  cfg: ScreencastConfig,
  onFrame: (f: ScreencastFrame) => void,
  opts?: { format?: BrowserFrameFormat },
): Promise<ScreencastHandle> {
  const format: BrowserFrameFormat = opts?.format ?? "jpeg";
  const cdp: CDPSession = await page.context().newCDPSession(page);

  let frames = 0;
  let stopped = false;
  let stopPromise: Promise<void> | null = null;

  const onFrameEvent = (ev: ScreencastFrameEvent): void => {
    if (stopped) return;
    frames++;
    onFrame({ format, data: Buffer.from(ev.data, "base64") });
    // Ack AFTER the handoff — chromium holds the next frame (up to
    // maxFramesInFlight) until this lands. Never awaited: the listener must
    // not go async, and a dead session must not produce unhandled rejects.
    void cdp.send("Page.screencastFrameAck", { sessionId: ev.sessionId }).catch(() => {});
  };
  cdp.on("Page.screencastFrame", onFrameEvent);

  await cdp.send(
    "Page.startScreencast",
    startScreencastParams(format, { quality: cfg.quality, everyNthFrame: cfg.everyNthFrame }, cfg),
  );

  async function stop(): Promise<void> {
    if (stopPromise) return stopPromise;
    stopPromise = (async () => {
      stopped = true;
      cdp.off("Page.screencastFrame", onFrameEvent);
      // Both steps are best-effort: the page/target may already be gone
      // (navigation crash, context close) — teardown must never throw.
      try {
        await cdp.send("Page.stopScreencast");
      } catch {
        /* target already gone */
      }
      try {
        await cdp.detach();
      } catch {
        /* session already detached/closed */
      }
    })();
    return stopPromise;
  }

  return {
    format: () => format,
    framesSent: () => frames,
    async adjust(next: LadderStep): Promise<void> {
      if (stopped) throw new Error("Cannot adjust a stopped screencast.");
      await cdp.send("Page.stopScreencast");
      await cdp.send("Page.startScreencast", startScreencastParams(format, next, cfg));
    },
    stop,
  };
}

/**
 * The probe's own damage source: a data: URL with the same 100 ms
 * background-color cycle as the test server's /animated fixture, so the
 * probe works in production without any fixture server (screencast frames
 * are damage-driven — a static page emits none by design). NOTE: this
 * navigates the page; the engine runs the probe at session start-up, before
 * any user navigation, and re-navigates afterwards.
 */
const PROBE_ANIMATED_URL =
  "data:text/html," +
  encodeURIComponent(
    '<!doctype html><html><head><title>webp-probe</title></head><body>' +
      '<div id="anim" style="position:fixed;left:0;top:0;width:100vw;height:100vh;background-color:red"></div>' +
      "<script>let hue=0;setInterval(()=>{hue=(hue+30)%360;" +
      'document.getElementById("anim").style.backgroundColor="hsl("+hue+",100%,50%)"},100)</script>' +
      "</body></html>",
  );

/** How long the probe waits for the first frame before declaring no-WebP. */
const PROBE_TIMEOUT_MS = 3_000;

/**
 * Runtime WebP capability probe. Starts a webp screencast on the animated
 * fixture: first frame within 3 s with WEBP magic ⇒ true; timeout, a
 * non-webp first frame (silent JPEG fallback) or a rejected start ⇒ false.
 * ALWAYS stops the probe screencast (and awaits the stop) before resolving,
 * so the page is left cast-free either way.
 */
export async function probeWebpSupport(page: Page, cfg: ScreencastConfig): Promise<boolean> {
  await page.goto(PROBE_ANIMATED_URL);
  return new Promise<boolean>((resolve) => {
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    let handle: ScreencastHandle | undefined;
    const finish = (result: boolean): void => {
      if (settled) return;
      settled = true;
      if (timer !== null) clearTimeout(timer);
      // Resolve only once the cast is fully torn down — a caller asserting
      // "no screencast left running" right after must not race the cleanup.
      void (async () => {
        try {
          await handle?.stop();
        } catch {
          /* stop is best-effort by contract */
        } finally {
          resolve(result);
        }
      })();
    };

    void startScreencast(
      page,
      cfg,
      (f) => {
        finish(frameMagicFormat(f.data) === "webp");
      },
      { format: "webp" },
    ).then(
      (h) => {
        handle = h;
        timer = setTimeout(() => finish(false), PROBE_TIMEOUT_MS);
      },
      () => {
        // Page.startScreencast with format "webp" was rejected outright.
        finish(false);
      },
    );
  });
}

/**
 * One-shot screenshot. Defaults to JPEG quality 70 (research §3.3: ~99 KB /
 * ~139 ms at 1280×800 — cheap enough for thumbnails, sharp enough to read).
 */
export async function captureScreenshot(
  page: Page,
  opts?: { type?: "jpeg" | "png"; quality?: number },
): Promise<Buffer> {
  const type = opts?.type ?? "jpeg";
  const buf =
    type === "jpeg"
      ? await page.screenshot({ type: "jpeg", quality: opts?.quality ?? 70 })
      : await page.screenshot({ type: "png" });
  return buf as Buffer;
}
