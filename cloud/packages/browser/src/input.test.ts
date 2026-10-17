import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { chromium, type Browser, type BrowserContext, type Page } from "playwright-core";

import type { BrowserInputEvent } from "@ovid/shared";
import { chromiumExecutableExists } from "./pool.js";
import { startTestPageServer, type TestPageServer } from "./test/testServer.js";

import { applyInputEvent, BrowserInputError } from "./input.js";

// ---------------------------------------------------------------------------
// Chromium-gated leg — every test drives a real page through applyInputEvent.
// Real timers throughout: long_press measures wall-clock hold duration, so
// fake timers are not used anywhere here (the wave guidance's
// {toFake:["setTimeout","clearTimeout"]} workaround only applies when they
// are).
//
// Fixture pins (see testServer.ts /click): #btn at left:20 top:20 100x40 →
// button center (70,40); clicking it sets #out to "CLICKED". #in is a text
// input; a document keydown handler sets #out to "KEY_ENTER" on Enter.
// ---------------------------------------------------------------------------

describe.skipIf(!chromiumExecutableExists())("applyInputEvent (chromium)", () => {
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

  async function newPage(path: string, viewport = { width: 400, height: 300 }): Promise<Page> {
    const context = await browser.newContext({ viewport });
    contexts.push(context);
    const page = await context.newPage();
    await page.goto(server.url(path));
    return page;
  }

  // -- tap / double_tap --------------------------------------------------------

  it("tap at the pinned button center (70,40) clicks it: #out = CLICKED", async () => {
    const page = await newPage("/click");
    await applyInputEvent(page, { type: "tap", x: 70, y: 40 });
    expect(await page.textContent("#out")).toBe("CLICKED");
  }, 15_000);

  it("double_tap on the button fires the click chain (dblclick = two clicks)", async () => {
    const page = await newPage("/click");
    await applyInputEvent(page, { type: "double_tap", x: 70, y: 40 });
    expect(await page.textContent("#out")).toBe("CLICKED");
  }, 15_000);

  // -- key --------------------------------------------------------------------

  it("key {key:\"k\"} with the input focused types into it", async () => {
    const page = await newPage("/click");
    await page.locator("#in").click();
    await applyInputEvent(page, { type: "key", key: "k" });
    expect(await page.inputValue("#in")).toBe("k");
  }, 15_000);

  it("key {key:\"Enter\"} triggers the keydown-Enter handler: #out = KEY_ENTER", async () => {
    const page = await newPage("/click");
    await applyInputEvent(page, { type: "key", key: "Enter" });
    expect(await page.textContent("#out")).toBe("KEY_ENTER");
  }, 15_000);

  it("key with text inserts the unicode text into the focused input", async () => {
    const page = await newPage("/click");
    await page.locator("#in").click();
    await applyInputEvent(page, { type: "key", key: "h", text: "héllo" });
    expect(await page.inputValue("#in")).toBe("héllo");
  }, 15_000);

  // -- scroll -------------------------------------------------------------------

  it("scroll {dx:0,dy:300} scrolls the tall /big page down", async () => {
    const page = await newPage("/big");
    expect(await page.evaluate(() => window.scrollY)).toBe(0);
    await applyInputEvent(page, { type: "scroll", dx: 0, dy: 300 });
    // The wheel dispatch is asynchronous on the browser side; wait for it to land.
    await vi.waitFor(
      async () => {
        expect(await page.evaluate(() => window.scrollY)).toBeGreaterThan(0);
      },
      { timeout: 5_000 },
    );
  }, 15_000);

  // -- swipe --------------------------------------------------------------------

  it("swipe from button center to center+5px still fires the click chain", async () => {
    const page = await newPage("/click");
    await applyInputEvent(page, { type: "swipe", fromX: 70, fromY: 40, toX: 75, toY: 40 });
    expect(await page.textContent("#out")).toBe("CLICKED");
  }, 15_000);

  // -- clamping -----------------------------------------------------------------

  it("tap at (99999,-5) does not throw, stays inside the viewport, and the page stays responsive", async () => {
    const page = await newPage("/click", { width: 400, height: 300 });
    await expect(applyInputEvent(page, { type: "tap", x: 99999, y: -5 })).resolves.toBeUndefined();
    // Page still answers evaluate — no crash from an out-of-range dispatch.
    expect(await page.evaluate(() => document.readyState)).toBe("complete");
    // The clamped tap landed at (399,0) — no button there, so no CLICKED.
    expect(await page.textContent("#out")).toBe("");
  }, 15_000);

  // -- long_press ------------------------------------------------------------------

  it("long_press with durationMs:120 holds ≥100 ms and sets CLICKED on release", async () => {
    const page = await newPage("/click");
    const started = Date.now();
    await applyInputEvent(page, { type: "long_press", x: 70, y: 40, durationMs: 120 });
    const elapsed = Date.now() - started;
    expect(elapsed).toBeGreaterThanOrEqual(100);
    expect(await page.textContent("#out")).toBe("CLICKED");
  }, 15_000);

  // -- malformed events (Review Focus #4) ------------------------------------------

  it("tap with x:NaN rejects with BrowserInputError", async () => {
    const page = await newPage("/click");
    const bad = { type: "tap", x: Number.NaN, y: 0 } as unknown as BrowserInputEvent;
    await expect(applyInputEvent(page, bad)).rejects.toBeInstanceOf(BrowserInputError);
  }, 15_000);

  it("an unknown event type rejects with BrowserInputError and the prefixed message", async () => {
    const page = await newPage("/click");
    const bad = { type: "nope" } as unknown as BrowserInputEvent;
    const err = await applyInputEvent(page, bad).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(BrowserInputError);
    expect((err as Error).message).toMatch(/^Invalid browser input: /);
  }, 15_000);

  it("non-finite scroll deltas reject with BrowserInputError", async () => {
    const page = await newPage("/big");
    const bad = { type: "scroll", dx: 0, dy: Number.POSITIVE_INFINITY } as unknown as BrowserInputEvent;
    await expect(applyInputEvent(page, bad)).rejects.toBeInstanceOf(BrowserInputError);
  }, 15_000);
});
