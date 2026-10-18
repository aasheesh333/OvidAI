import { chromium } from "playwright-core";
import type { Browser } from "playwright-core";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import type { BrowserEngineConfig } from "./config.js";
import {
  BrowserPoolBusyError,
  chromiumExecutableExists,
  createBrowserPool,
  type BrowserPool,
  type ChromiumLaunchOptions,
} from "./pool.js";
import type { StorageState } from "./storageState.js";
import { startTestPageServer, type TestPageServer } from "./test/testServer.js";
import type { BrowserUidDrop } from "./uidDrop.js";

// Real-browser tests: every one is gated on the playwright-core registry
// having a chromium executable (PLAYWRIGHT_BROWSERS_PATH override proves the
// skip path exits 0 with no browser).
describe.skipIf(!chromiumExecutableExists())("BrowserPool", () => {
  let server: TestPageServer;

  beforeAll(async () => {
    server = await startTestPageServer();
  });

  afterAll(async () => {
    await server.close();
  });

  function makeCfg(overrides: Partial<BrowserEngineConfig> = {}): BrowserEngineConfig {
    return {
      maxLiveBrowsers: 2,
      tier1FallbackContexts: 1,
      idleEvictMs: 500,
      maxTier1Processes: 8,
      tier1TimeoutMs: 20_000,
      maxActiveScreencasts: 3,
      screencastLoadMax: 6.0,
      screencast: { width: 400, height: 300, quality: 60, everyNthFrame: 2, maxFramesInFlight: 2 },
      stateDir: null,
      lightpandaBin: null,
      allowHosts: ["127.0.0.1", "localhost"],
      ownPublicIp: null,
      blockHeavyResources: false,
      chromiumArgs: ["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"],
      ...overrides,
    };
  }

  // Every pool is registered here so afterEach can close it even when a test
  // asserts on close() itself (close() is idempotent).
  const pools: BrowserPool[] = [];
  function makePool(cfg: BrowserEngineConfig, opts?: Parameters<typeof createBrowserPool>[1]): BrowserPool {
    const pool = createBrowserPool(cfg, opts);
    pools.push(pool);
    return pool;
  }
  afterEach(async () => {
    for (const pool of pools) await pool.close();
    pools.length = 0;
  });

  it("acquireLive lazily launches chromium and returns a handle whose page navigates to the fixture", async () => {
    const pool = makePool(makeCfg());
    expect(pool.stats()).toEqual({ browserAlive: false, live: 0, tier1: 0, queued: 0 });
    const handle = await pool.acquireLive("s1");
    await handle.page.goto(server.url("/"));
    expect(await handle.page.title()).toBe("Static article");
    expect(pool.liveCount()).toBe(1);
    expect(pool.tier1Count()).toBe(0);
    expect(pool.stats()).toEqual({ browserAlive: true, live: 1, tier1: 0, queued: 0 });
  });

  it("without a dedicated uid the launch options carry no uid-drop wiring (dev default)", async () => {
    const cfg = makeCfg();
    let captured: ChromiumLaunchOptions | undefined;
    const pool = makePool(cfg, {
      launch: async (options) => {
        captured = options;
        return chromium.launch({ headless: true, args: cfg.chromiumArgs });
      },
    });
    await pool.acquireLive("s1");
    expect(captured).toBeDefined();
    expect(captured!.executablePath).toBeUndefined();
    expect(captured!.env).toBeUndefined();
    expect(captured!.downloadsPath).toBeUndefined();
  });

  it("wires the prepared uid-drop shim into chromium.launch (executablePath/env/downloadsPath)", async () => {
    const cfg = makeCfg({ egressUid: 230_000, sandboxUidRange: [200_000, 209_999] });
    const uidDrop: BrowserUidDrop = {
      uid: 230_000,
      gid: 230_000,
      wrapperPath: "/tmp/ovid-test-chromium-uid-shim.sh",
      downloadsDir: "/tmp/ovid-test-downloads",
      env: { ...process.env, HOME: "/tmp/ovid-test-home" },
      cleanup: async () => {},
    };
    let captured: ChromiumLaunchOptions | undefined;
    const pool = makePool(cfg, {
      uidDrop,
      launch: async (options) => {
        captured = options;
        // The seam asserts the wiring, then launches a normal browser so the
        // rest of the pool lifecycle is exercised end to end.
        return chromium.launch({ headless: true, args: cfg.chromiumArgs });
      },
    });
    const handle = await pool.acquireLive("s1");
    await handle.page.goto(server.url("/"));
    expect(await handle.page.title()).toBe("Static article");
    expect(captured).toBeDefined();
    expect(captured!.executablePath).toBe(uidDrop.wrapperPath);
    expect(captured!.env).toBe(uidDrop.env);
    expect(captured!.downloadsPath).toBe(uidDrop.downloadsDir);
    expect(captured!.args).toEqual(cfg.chromiumArgs);
  });

  it("re-acquiring the same sessionId returns the SAME handle object (touch, no new context)", async () => {
    const pool = makePool(makeCfg());
    const h1 = await pool.acquireLive("s1");
    const h2 = await pool.acquireLive("s1");
    expect(h2).toBe(h1);
    expect(pool.liveCount()).toBe(1);
  });

  it("queues a 3rd distinct live session and admits waiters in FIFO enqueue order", async () => {
    const pool = makePool(makeCfg());
    const h1 = await pool.acquireLive("s1");
    const h2 = await pool.acquireLive("s2");
    expect(pool.queueDepth()).toBe(0);

    const s3 = pool.acquireLive("s3");
    const s4 = pool.acquireLive("s4");
    expect(pool.queueDepth()).toBe(2);

    // Free one slot: s3 (enqueued first) must be admitted, s4 must stay queued.
    await pool.releaseLive("s1");
    const h3 = await s3;
    expect(h3.sessionId).toBe("s3");
    let s4Resolved = false;
    void s4.then(() => {
      s4Resolved = true;
    });
    await new Promise((r) => setTimeout(r, 50));
    expect(s4Resolved).toBe(false);
    expect(pool.queueDepth()).toBe(1);

    // Free the second slot: s4 admitted next — enqueue order pinned.
    await pool.releaseLive("s2");
    const h4 = await s4;
    expect(h4.sessionId).toBe("s4");
    expect(pool.queueDepth()).toBe(0);
    expect(pool.liveCount()).toBe(2);
    expect(h1).toBeTruthy();
  });

  it("rejects a live waiter that exceeds queueTimeoutMs with BrowserPoolBusyError", async () => {
    const pool = makePool(makeCfg(), { queueTimeoutMs: 100 });
    await pool.acquireLive("s1");
    await pool.acquireLive("s2");
    const e = await pool.acquireLive("s3").then(
      () => null,
      (err: unknown) => err,
    );
    expect(e).toBeInstanceOf(BrowserPoolBusyError);
    expect((e as Error).message).toContain("queued and timed out");
    expect(pool.queueDepth()).toBe(0); // the timed-out waiter left the queue
    expect(pool.liveCount()).toBe(2); // the live handles were untouched
  });

  it("tier-1 leases queue beyond tier1FallbackContexts and release() frees the slot", async () => {
    const pool = makePool(makeCfg(), { queueTimeoutMs: 5_000 });
    const l1 = await pool.acquireTier1();
    await l1.page.goto(server.url("/"));
    expect(await l1.page.title()).toBe("Static article");
    expect(pool.tier1Count()).toBe(1);

    const l2p = pool.acquireTier1();
    expect(pool.queueDepth()).toBe(1);

    await l1.release();
    const l2 = await l2p;
    expect(pool.tier1Count()).toBe(1); // l2 took the freed slot
    expect(pool.queueDepth()).toBe(0);

    await l2.release();
    expect(pool.tier1Count()).toBe(0);
  });

  it("isolation pin: cookies set in session s1's context are invisible to session s2 (Review Focus #1)", async () => {
    const pool = makePool(makeCfg());
    const h1 = await pool.acquireLive("s1");
    await h1.page.goto(server.url("/"));
    await h1.page.evaluate(() => {
      document.cookie = "sess_a=isolation-pin; path=/";
    });

    const h2 = await pool.acquireLive("s2");
    await h2.page.goto(server.url("/"));
    const cookie = await h2.page.evaluate(() => document.cookie);
    expect(cookie).toBe("");
  });

  it("seeds a context from a storageState with a login_tok cookie", async () => {
    const pool = makePool(makeCfg());
    const state: StorageState = {
      cookies: [
        {
          name: "login_tok",
          value: "abc123",
          domain: "127.0.0.1",
          path: "/",
          expires: -1,
          httpOnly: false,
          secure: false,
          sameSite: "Lax",
        },
      ],
      origins: [],
    };
    const handle = await pool.acquireLive("s3", { storageState: state });
    const cookies = await handle.context.cookies();
    expect(cookies.some((c) => c.name === "login_tok" && c.value === "abc123")).toBe(true);
  });

  it("evictIdle evicts only untouched handles, calls onIdleEvict BEFORE close, and clears the map", async () => {
    let fakeNow = 100_000;
    const evicted: string[] = [];
    const pool = makePool(makeCfg(), {
      now: () => fakeNow,
      sweepIntervalMs: 0, // manual sweep in this test — no background timer racing it
      onIdleEvict: async (sessionId, context) => {
        evicted.push(sessionId);
        // Pinned: onIdleEvict runs BEFORE context.close — the context must
        // still be usable here (cookies() throws on a closed context).
        await context.cookies();
      },
    });
    await pool.acquireLive("s1");
    const h2 = await pool.acquireLive("s2");

    fakeNow += 600; // > idleEvictMs (500)
    h2.touch(); // s2 is fresh again

    const evictedIds = await pool.evictIdle();
    expect(evictedIds).toEqual(["s1"]);
    expect(evicted).toEqual(["s1"]);
    expect(pool.peekLive("s1")).toBe(null);
    expect(pool.peekLive("s2")).not.toBe(null);
    expect(pool.liveCount()).toBe(1);
  });

  it("the sweep timer evicts idle contexts in the background (unref'd)", async () => {
    let fakeNow = 50_000;
    const pool = makePool(makeCfg(), { now: () => fakeNow, sweepIntervalMs: 100 });
    await pool.acquireLive("s1");
    fakeNow += 600;
    await vi.waitFor(() => {
      expect(pool.peekLive("s1")).toBe(null);
    });
    expect(pool.liveCount()).toBe(0);
  });

  it("close() rejects queued waiters, zeroes stats, and kills the browser process (Review Focus #2)", async () => {
    let browser: Browser | null = null;
    const cfg = makeCfg();
    const pool = makePool(cfg, {
      launch: async () => {
        browser ??= await chromium.launch({ headless: true, args: cfg.chromiumArgs });
        return browser;
      },
    });
    await pool.acquireLive("s1");
    await pool.acquireLive("s2");
    // Handler attached at creation — the rejection may land before we await it.
    const queued = pool.acquireLive("s3").then(
      (h) => ({ ok: true as const, h }),
      (e: unknown) => ({ ok: false as const, e }),
    );
    expect(pool.queueDepth()).toBe(1);

    await pool.close();
    const outcome = await queued;
    expect(outcome.ok).toBe(false);
    if (outcome.ok) throw new Error("expected acquireLive to reject");
    expect(outcome.e).toBeInstanceOf(BrowserPoolBusyError);
    expect(pool.stats()).toEqual({ browserAlive: false, live: 0, tier1: 0, queued: 0 });

    // playwright-core 1.64 Browser exposes no process() (that is
    // BrowserServer/Electron-only) — isConnected() is the public liveness
    // pin: false once the process is gone.
    expect(browser!.isConnected()).toBe(false);
  });

  it("health: browser death rejects all waiters, clears maps, and the next acquire relaunches", async () => {
    let launches = 0;
    let firstBrowser: Browser | null = null;
    const cfg = makeCfg();
    const pool = makePool(cfg, {
      queueTimeoutMs: 10_000,
      launch: async () => {
        launches += 1;
        const b = await chromium.launch({ headless: true, args: cfg.chromiumArgs });
        if (launches === 1) firstBrowser = b;
        return b;
      },
    });
    await pool.acquireLive("s1");
    await pool.acquireLive("s2");
    // Handler attached at creation — the rejection lands during waitFor below.
    const queued = pool.acquireLive("s3").then(
      (h) => ({ ok: true as const, h }),
      (e: unknown) => ({ ok: false as const, e }),
    );
    expect(pool.queueDepth()).toBe(1);

    // Kill the browser out from under the pool — "disconnected" must fire.
    await firstBrowser!.close();
    await vi.waitFor(() => {
      expect(pool.stats().browserAlive).toBe(false);
    });

    const outcome = await queued;
    expect(outcome.ok).toBe(false);
    if (outcome.ok) throw new Error("expected acquireLive to reject");
    expect(outcome.e).toBeInstanceOf(BrowserPoolBusyError);
    expect((outcome.e as Error).message).toContain("browser process died");
    expect(pool.stats()).toEqual({ browserAlive: false, live: 0, tier1: 0, queued: 0 });

    // The next acquire relaunches chromium.
    const h = await pool.acquireLive("s4");
    await h.page.goto(server.url("/"));
    expect(await h.page.title()).toBe("Static article");
    expect(launches).toBe(2);
    expect(pool.stats()).toEqual({ browserAlive: true, live: 1, tier1: 0, queued: 0 });
  });
});
