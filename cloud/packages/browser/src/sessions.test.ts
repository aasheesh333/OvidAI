import { afterAll, afterEach, beforeAll, describe, expect, it, vi, type Mock } from "vitest";
import type { Page } from "playwright-core";

import type { BrowserEngineConfig } from "./config.js";
import {
  CONSOLE_BUFFER_CAP,
  DIALOG_HOLD_MS,
  NETWORK_BUFFER_CAP,
  TAKEOVER_REFUSAL,
  createBrowserSessionRegistry,
  instrumentPage,
  type BrowserSessionRegistry,
  type ConsoleEntry,
  type DialogEntry,
  type NetworkEntry,
  type PopupEntry,
  type SessionBrowser,
} from "./sessions.js";
import { chromiumExecutableExists, createBrowserPool, type BrowserPool } from "./pool.js";
import type { LiveContextHandle } from "./pool.js";
import { startTestPageServer, type TestPageServer } from "./test/testServer.js";

// ---------------------------------------------------------------------------
// Pure-unit leg — no chromium anywhere. Stub pages capture instrumentPage's
// event registrations so the buffers/timers can be driven synchronously.
// ---------------------------------------------------------------------------

interface StubPage {
  handlers: Record<string, Array<(arg: never) => void>>;
  on(ev: string, cb: (arg: never) => void): void;
  close: Mock<() => Promise<void>>;
}

function stubPage(): StubPage {
  const handlers: StubPage["handlers"] = {};
  return {
    handlers,
    on(ev, cb) {
      (handlers[ev] ??= []).push(cb);
    },
    close: vi.fn(async () => {}),
  };
}

function stubHandle(page: StubPage): LiveContextHandle {
  return {
    sessionId: "u1",
    // The POOL owns the context; the registry must never close it.
    context: { close: vi.fn(async () => {}) } as unknown as LiveContextHandle["context"],
    page: page as unknown as Page,
    createdAt: 0,
    touch: vi.fn(),
  };
}

/** Fire every handler registered for `ev` with the given playwright stub. */
function fire(page: StubPage, ev: string, arg: unknown): void {
  for (const cb of page.handlers[ev] ?? []) cb(arg as never);
}

function fakeDialog(overrides: Partial<Record<"type" | "message" | "defaultValue", () => string>> = {}) {
  return {
    type: overrides.type ?? (() => "confirm"),
    message: overrides.message ?? (() => "sure?"),
    defaultValue: overrides.defaultValue ?? (() => ""),
    accept: vi.fn(async () => {}),
    dismiss: vi.fn(async () => {}),
  };
}

describe("BrowserSessionRegistry (unit — no chromium)", () => {
  it("open() returns a one-tab entry and get/activePage bookkeeping works", () => {
    const registry = createBrowserSessionRegistry();
    const page = stubPage();
    const handle = stubHandle(page);
    const s = registry.open({ sessionId: "s1", userId: "u1", handle });
    expect(s.sessionId).toBe("s1");
    expect(s.userId).toBe("u1");
    expect(s.handle).toBe(handle);
    expect(s.tabs).toHaveLength(1);
    expect(s.tabs[0]).toBe(page as unknown as Page);
    expect(s.activeIndex).toBe(0);
    expect(s.takeover).toBe(false);
    expect(s.lastActivityAt).toBeGreaterThan(0);
    expect(s.console).toEqual([]);
    expect(s.network).toEqual([]);
    expect(s.dialogs).toEqual([]);
    expect(s.popups).toEqual([]);
    expect(registry.get("s1")).toBe(s);
    expect(registry.activePage("s1")).toBe(page as unknown as Page);
    expect(registry.get("missing")).toBe(null);
  });

  it("close() removes the entry only — the POOL owns context closing (pool-ownership boundary)", () => {
    const registry = createBrowserSessionRegistry();
    const page = stubPage();
    const handle = stubHandle(page);
    const s = registry.open({ sessionId: "s1", userId: "u1", handle });
    const closed = registry.close("s1");
    expect(closed).toBe(s);
    expect(registry.get("s1")).toBe(null);
    expect(registry.activePage("s1")).toBe(null);
    expect(handle.context.close).not.toHaveBeenCalled();
    expect(page.close).not.toHaveBeenCalled();
    expect(registry.close("s1")).toBe(null); // second close: gone already
  });

  it("closeTab refuses the last tab, otherwise closes the page and fixes activeIndex", () => {
    const registry = createBrowserSessionRegistry();
    const p0 = stubPage();
    const p1 = stubPage();
    const handle = stubHandle(p0);
    const s = registry.open({ sessionId: "s1", userId: "u1", handle });
    registry.addTab("s1", p1 as unknown as Page);
    expect(s.activeIndex).toBe(1);

    // Invalid index.
    expect(registry.closeTab("s1", -1)).toBe(false);
    expect(registry.closeTab("s1", 2)).toBe(false);

    // Close tab 0 (inactive): active stays pointed at p1.
    expect(registry.closeTab("s1", 0)).toBe(true);
    expect(p0.close).toHaveBeenCalledTimes(1);
    expect(s.tabs).toHaveLength(1);
    expect(s.tabs[0]).toBe(p1 as unknown as Page);
    expect(s.activeIndex).toBe(0);

    // Closing the ACTIVE tab with others left clamps to the last remaining.
    const p2 = stubPage();
    registry.addTab("s1", p2 as unknown as Page); // tabs [p1, p2], active 1
    expect(registry.closeTab("s1", 1)).toBe(true); // close active p2
    expect(s.activeIndex).toBe(0);
    expect(s.tabs[0]).toBe(p1 as unknown as Page);

    // Last tab is refused — a session must always keep one page.
    expect(registry.closeTab("s1", 0)).toBe(false);
    expect(p1.close).not.toHaveBeenCalled();
    expect(registry.closeTab("missing", 0)).toBe(false);
  });

  it("switchTab bounds-checks and moves activePage", () => {
    const registry = createBrowserSessionRegistry();
    const p0 = stubPage();
    const handle = stubHandle(p0);
    registry.open({ sessionId: "s1", userId: "u1", handle });
    const p1 = stubPage();
    registry.addTab("s1", p1 as unknown as Page);
    expect(registry.switchTab("s1", 5)).toBe(false);
    expect(registry.switchTab("s1", -1)).toBe(false);
    expect(registry.switchTab("missing", 0)).toBe(false);
    expect(registry.switchTab("s1", 0)).toBe(true);
    expect(registry.activePage("s1")).toBe(p0 as unknown as Page);
  });

  it("takeover flag drives refuseReasonIfTakeover with the exact refusal string", () => {
    const registry = createBrowserSessionRegistry();
    const handle = stubHandle(stubPage());
    registry.open({ sessionId: "s1", userId: "u1", handle });
    expect(registry.refuseReasonIfTakeover("s1")).toBe(null);
    expect(registry.setTakeover("s1", true)).toBe(true);
    expect(registry.refuseReasonIfTakeover("s1")).toBe(TAKEOVER_REFUSAL);
    expect(registry.setTakeover("s1", false)).toBe(true);
    expect(registry.refuseReasonIfTakeover("s1")).toBe(null);
    // Unknown session: setTakeover false, reason null.
    expect(registry.setTakeover("missing", true)).toBe(false);
    expect(registry.refuseReasonIfTakeover("missing")).toBe(null);
  });

  it("touch() advances lastActivityAt (injected now) and calls handle.touch()", () => {
    let fakeNow = 1_000;
    const registry = createBrowserSessionRegistry({ now: () => fakeNow });
    const handle = stubHandle(stubPage());
    const s = registry.open({ sessionId: "s1", userId: "u1", handle });
    const openedAt = s.lastActivityAt;
    fakeNow += 500;
    registry.touch("s1");
    expect(s.lastActivityAt).toBe(openedAt + 500);
    expect(handle.touch).toHaveBeenCalledTimes(1);
    registry.touch("missing"); // no throw
  });

  it("console ring: caps at CONSOLE_BUFFER_CAP, newest kept, oldest dropped", () => {
    const registry = createBrowserSessionRegistry();
    const page = stubPage();
    const handle = stubHandle(page);
    const s = registry.open({ sessionId: "s1", userId: "u1", handle });
    for (let i = 0; i < CONSOLE_BUFFER_CAP + 50; i++) {
      fire(page, "console", {
        type: () => "log",
        text: () => `cap-${i}`,
        location: () => ({ url: "http://x/y.js", lineNumber: 7 }),
      });
    }
    expect(s.console).toHaveLength(CONSOLE_BUFFER_CAP);
    expect(s.console[s.console.length - 1].text).toBe(`cap-${CONSOLE_BUFFER_CAP + 49}`);
    expect(s.console[0].text).toBe(`cap-${CONSOLE_BUFFER_CAP + 50 - CONSOLE_BUFFER_CAP}`);
    expect(s.console.some((e) => e.text === "cap-0")).toBe(false);
    const first: ConsoleEntry = s.console[0];
    expect(first.type).toBe("log");
    expect(first.location).toBe("http://x/y.js:7");
    expect(first.ts).toBeGreaterThan(0);
  });

  it("network ring: response and requestfailed entries, capped at NETWORK_BUFFER_CAP", () => {
    const registry = createBrowserSessionRegistry();
    const page = stubPage();
    const handle = stubHandle(page);
    const s = registry.open({ sessionId: "s1", userId: "u1", handle });
    fire(page, "response", {
      url: () => "http://x/a",
      status: () => 200,
      request: () => ({ method: () => "GET" }),
    });
    fire(page, "requestfailed", {
      url: () => "http://x/b",
      method: () => "POST",
      failure: () => ({ errorText: "net::ERR_FAILED" }),
    });
    const ok: NetworkEntry = s.network[0];
    expect(ok).toMatchObject({ url: "http://x/a", method: "GET", status: 200, failure: null });
    const bad: NetworkEntry = s.network[1];
    expect(bad).toMatchObject({ url: "http://x/b", method: "POST", status: null, failure: "net::ERR_FAILED" });
    expect(bad.ts).toBeGreaterThan(0);

    for (let i = 0; i < NETWORK_BUFFER_CAP + 10; i++) {
      fire(page, "response", {
        url: () => `http://x/r${i}`,
        status: () => 200,
        request: () => ({ method: () => "GET" }),
      });
    }
    expect(s.network).toHaveLength(NETWORK_BUFFER_CAP);
    expect(s.network[s.network.length - 1].url).toBe(`http://x/r${NETWORK_BUFFER_CAP + 9}`);
    expect(s.network.some((e) => e.url === "http://x/a")).toBe(false);
  });

  it("dialog: held without auto-resolve; resolve('accept') wraps dialog.accept and removes the entry", () => {
    vi.useFakeTimers();
    try {
      const registry = createBrowserSessionRegistry();
      const page = stubPage();
      const handle = stubHandle(page);
      const s = registry.open({ sessionId: "s1", userId: "u1", handle });
      const dialog = fakeDialog({ message: () => "sure?", defaultValue: () => "df" });
      fire(page, "dialog", dialog);
      expect(dialog.accept).not.toHaveBeenCalled();
      expect(dialog.dismiss).not.toHaveBeenCalled();
      expect(s.dialogs).toHaveLength(1);
      const d: DialogEntry = s.dialogs[0];
      expect(d.type).toBe("confirm");
      expect(d.message).toBe("sure?");
      expect(d.defaultValue).toBe("df");
      expect(d.heldAt).toBeGreaterThan(0);
      expect(typeof d.id).toBe("string");

      d.resolve("accept", "typed");
      expect(dialog.accept).toHaveBeenCalledTimes(1);
      expect(dialog.accept).toHaveBeenCalledWith("typed");
      expect(s.dialogs).toHaveLength(0);

      // Resolving twice must not re-fire (timer already cleared).
      d.resolve("dismiss");
      expect(dialog.dismiss).not.toHaveBeenCalled();

      // The hold timer is gone — advancing past DIALOG_HOLD_MS is a no-op.
      vi.advanceTimersByTime(DIALOG_HOLD_MS + 1);
      expect(dialog.dismiss).not.toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
    }
  });

  it("dialog: resolve('dismiss') wraps dialog.dismiss", () => {
    vi.useFakeTimers();
    try {
      const registry = createBrowserSessionRegistry();
      const page = stubPage();
      const handle = stubHandle(page);
      const s = registry.open({ sessionId: "s1", userId: "u1", handle });
      const dialog = fakeDialog({ type: () => "prompt", defaultValue: () => "" });
      fire(page, "dialog", dialog);
      s.dialogs[0].resolve("dismiss");
      expect(dialog.dismiss).toHaveBeenCalledTimes(1);
      expect(dialog.accept).not.toHaveBeenCalled();
      expect(s.dialogs).toHaveLength(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it("dialog timeout: auto-dismiss after DIALOG_HOLD_MS, onDialogTimeout fired, entry removed", () => {
    vi.useFakeTimers();
    try {
      const timedOut: DialogEntry[] = [];
      const registry = createBrowserSessionRegistry({ onDialogTimeout: (d) => timedOut.push(d) });
      const page = stubPage();
      const handle = stubHandle(page);
      const s = registry.open({ sessionId: "s1", userId: "u1", handle });
      const dialog = fakeDialog({ message: () => "hold?" });
      fire(page, "dialog", dialog);
      expect(s.dialogs).toHaveLength(1);

      vi.advanceTimersByTime(DIALOG_HOLD_MS - 1);
      expect(s.dialogs).toHaveLength(1); // still held just before the deadline
      expect(dialog.dismiss).not.toHaveBeenCalled();

      vi.advanceTimersByTime(1);
      expect(s.dialogs).toHaveLength(0);
      expect(dialog.dismiss).toHaveBeenCalledTimes(1);
      expect(timedOut).toHaveLength(1);
      expect(timedOut[0].message).toBe("hold?");
    } finally {
      vi.useRealTimers();
    }
  });

  it("close() clears pending dialog hold timers (no late onDialogTimeout)", () => {
    vi.useFakeTimers();
    try {
      const timedOut: DialogEntry[] = [];
      const registry = createBrowserSessionRegistry({ onDialogTimeout: (d) => timedOut.push(d) });
      const page = stubPage();
      const handle = stubHandle(page);
      const s = registry.open({ sessionId: "s1", userId: "u1", handle });
      fire(page, "dialog", fakeDialog());
      expect(s.dialogs).toHaveLength(1);
      registry.close("s1");
      vi.advanceTimersByTime(DIALOG_HOLD_MS + 1);
      expect(timedOut).toHaveLength(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it("popup: url recorded and the popup page is closed (server-side popups never render)", () => {
    const registry = createBrowserSessionRegistry();
    const page = stubPage();
    const handle = stubHandle(page);
    const s = registry.open({ sessionId: "s1", userId: "u1", handle });
    const popup = { url: () => "http://x/opened", close: vi.fn(async () => {}) };
    fire(page, "popup", popup);
    expect(s.popups).toHaveLength(1);
    const p: PopupEntry = s.popups[0];
    expect(p.url).toBe("http://x/opened");
    expect(p.openedAt).toBeGreaterThan(0);
    expect(popup.close).toHaveBeenCalledTimes(1);
  });

  it("buffers are per-SESSION: a second instrumented tab shares the same rings", () => {
    const registry = createBrowserSessionRegistry();
    const p0 = stubPage();
    const handle = stubHandle(p0);
    const s = registry.open({ sessionId: "s1", userId: "u1", handle });
    const p1 = stubPage();
    registry.addTab("s1", p1 as unknown as Page);
    fire(p0, "console", { type: () => "log", text: () => "from-tab-0", location: () => null });
    fire(p1, "console", { type: () => "log", text: () => "from-tab-1", location: () => null });
    expect(s.console.map((e) => e.text)).toEqual(["from-tab-0", "from-tab-1"]);
    expect(s.activeIndex).toBe(1);
  });

  it("instrumentPage is exported and instruments any page against an existing session", () => {
    const registry = createBrowserSessionRegistry();
    const page = stubPage();
    const s = registry.open({ sessionId: "s1", userId: "u1", handle: stubHandle(page) });
    const extra = stubPage();
    instrumentPage(s as SessionBrowser, extra as unknown as Page);
    fire(extra, "console", { type: () => "warning", text: () => "extra", location: () => null });
    expect(s.console.map((e) => e.text)).toEqual(["extra"]);
  });
});

// ---------------------------------------------------------------------------
// Chromium-gated leg — real pool (Task 4) at maxLiveBrowsers:2 + fixture server.
// ---------------------------------------------------------------------------

describe.skipIf(!chromiumExecutableExists())("BrowserSessionRegistry (chromium)", () => {
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
      chromiumArgs: ["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"],
      ...overrides,
    };
  }

  const pools: BrowserPool[] = [];
  afterEach(async () => {
    for (const pool of pools) await pool.close();
    pools.length = 0;
  });

  function makePool(): BrowserPool {
    const pool = createBrowserPool(makeCfg());
    pools.push(pool);
    return pool;
  }

  async function openSession(
    registry: BrowserSessionRegistry,
    sessionId: string,
  ): Promise<{ handle: LiveContextHandle; s: SessionBrowser }> {
    const handle = await makePool().acquireLive(sessionId);
    const s = registry.open({ sessionId, userId: `user-${sessionId}`, handle });
    return { handle, s };
  }

  it("open() returns an entry with tabs.length===1, activeIndex===0, instrumented page", async () => {
    const registry = createBrowserSessionRegistry();
    const { handle, s } = await openSession(registry, "s1");
    expect(s.sessionId).toBe("s1");
    expect(s.userId).toBe("user-s1");
    expect(s.handle).toBe(handle);
    expect(s.tabs).toHaveLength(1);
    expect(s.activeIndex).toBe(0);
    expect(s.takeover).toBe(false);
    expect(registry.get("s1")).toBe(s);
    expect(registry.activePage("s1")).toBe(handle.page);
  });

  it("console.log from the page appears in the console buffer with type/text", async () => {
    const registry = createBrowserSessionRegistry();
    const { handle, s } = await openSession(registry, "s1");
    await handle.page.goto(server.url("/"));
    await handle.page.evaluate(() => console.log("hello-from-page"));
    await vi.waitFor(() => {
      expect(s.console.some((e) => e.type === "log" && e.text === "hello-from-page")).toBe(true);
    });
    const entry = s.console.find((e) => e.text === "hello-from-page")!;
    expect(entry.ts).toBeGreaterThan(0);
  });

  it("console buffer cap: 250 logs → length 200, newest present, oldest gone", async () => {
    const registry = createBrowserSessionRegistry();
    const { handle, s } = await openSession(registry, "s1");
    await handle.page.goto(server.url("/"));
    await handle.page.evaluate(() => {
      for (let i = 0; i < 250; i++) console.log(`cap-${i}`);
    });
    await vi.waitFor(() => {
      expect(s.console).toHaveLength(CONSOLE_BUFFER_CAP);
    });
    expect(s.console[s.console.length - 1].text).toBe("cap-249");
    expect(s.console.some((e) => e.text === "cap-0")).toBe(false);
    expect(s.console.some((e) => e.text === "cap-49")).toBe(false);
    expect(s.console.some((e) => e.text === "cap-50")).toBe(true);
  });

  it("a navigation records a network entry with status 200", async () => {
    const registry = createBrowserSessionRegistry();
    const { handle, s } = await openSession(registry, "s1");
    await handle.page.goto(server.url("/spa"));
    await vi.waitFor(() => {
      expect(s.network.some((n) => n.url === server.url("/spa") && n.status === 200)).toBe(true);
    });
    const nav = s.network.find((n) => n.url === server.url("/spa"))!;
    expect(nav.method).toBe("GET");
    expect(nav.failure).toBe(null);
    expect(nav.ts).toBeGreaterThan(0);
  });

  it("addTab: 2 tabs, active switched, new tab instrumented into the SHARED buffer", async () => {
    const registry = createBrowserSessionRegistry();
    const { handle, s } = await openSession(registry, "s1");
    await handle.page.goto(server.url("/"));
    const page2 = await handle.context.newPage();
    const idx = registry.addTab("s1", page2);
    expect(idx).toBe(1);
    expect(s.tabs).toHaveLength(2);
    expect(s.activeIndex).toBe(1);
    expect(registry.activePage("s1")).toBe(page2);
    await page2.goto(server.url("/click"));
    await page2.evaluate(() => console.log("from-tab-2"));
    await vi.waitFor(() => {
      expect(s.console.some((e) => e.text === "from-tab-2")).toBe(true);
    });
  });

  it("closeTab(0) with two tabs: page closed, remaining tab active; last tab refused", async () => {
    const registry = createBrowserSessionRegistry();
    const { handle, s } = await openSession(registry, "s1");
    const original = handle.page;
    const page2 = await handle.context.newPage();
    registry.addTab("s1", page2);

    expect(registry.closeTab("s1", 0)).toBe(true);
    await vi.waitFor(() => {
      expect(original.isClosed()).toBe(true);
    });
    expect(s.tabs).toHaveLength(1);
    expect(s.tabs[0]).toBe(page2);
    expect(s.activeIndex).toBe(0);
    expect(registry.activePage("s1")).toBe(page2);

    expect(registry.switchTab("s1", 5)).toBe(false);
    // Last tab is refused.
    expect(registry.closeTab("s1", 0)).toBe(false);
    expect(s.tabs).toHaveLength(1);
    expect(page2.isClosed()).toBe(false);
  });

  it("dialog: confirm() held (page JS blocked), resolve('accept') lets the page proceed", async () => {
    const registry = createBrowserSessionRegistry();
    const { handle, s } = await openSession(registry, "s1");
    await handle.page.goto(server.url("/"));
    const evaled = handle.page.evaluate(() => window.confirm("q?"));
    await vi.waitFor(() => {
      expect(s.dialogs).toHaveLength(1);
    });
    const d = s.dialogs[0];
    expect(d.type).toBe("confirm");
    expect(d.message).toBe("q?");
    expect(d.heldAt).toBeGreaterThan(0);

    d.resolve("accept");
    await expect(evaled).resolves.toBe(true);
    expect(s.dialogs).toHaveLength(0);
  });

  it("dialog timeout: onDialogTimeout fires at the real DIALOG_HOLD_MS via fake timers; dialog auto-dismissed", async () => {
    // Setup runs on REAL timers (launch/goto are event-driven anyway); only
    // the dialog hold itself lives under the fake clock. toFake is limited
    // to setTimeout/clearTimeout: vitest's default set also fakes
    // setImmediate, which Node streams (playwright's protocol transport)
    // need — faking it stalls every page event. Waits are event-driven
    // (page.once("dialog") / awaiting the blocked evaluate), since timer
    // polling never advances under a fake clock.
    const timedOut: DialogEntry[] = [];
    const registry = createBrowserSessionRegistry({ onDialogTimeout: (d) => timedOut.push(d) });
    const { handle, s } = await openSession(registry, "s1");
    await handle.page.goto(server.url("/"));
    const dialogArrived = new Promise<void>((r) => handle.page.once("dialog", () => r()));

    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    try {
      const evaled = handle.page.evaluate(() => window.confirm("hold?"));
      await dialogArrived;
      expect(s.dialogs).toHaveLength(1);
      expect(handle.page.isClosed()).toBe(false);

      vi.advanceTimersByTime(DIALOG_HOLD_MS);
      expect(s.dialogs).toHaveLength(0);
      expect(timedOut).toHaveLength(1);
      expect(timedOut[0].message).toBe("hold?");
      // Auto-dismiss → confirm() returns false.
      await expect(evaled).resolves.toBe(false);
    } finally {
      vi.useRealTimers();
    }
  }, 15_000);

  it("popup: window.open records the URL and closes the popup page", async () => {
    const registry = createBrowserSessionRegistry();
    const { handle, s } = await openSession(registry, "s1");
    await handle.page.goto(server.url("/"));
    const target = server.url("/click");
    await handle.page.evaluate((url) => {
      window.open(url, "_blank");
    }, target);
    await vi.waitFor(() => {
      expect(s.popups).toHaveLength(1);
    });
    expect(s.popups[0].url).toBe(target);
    expect(s.popups[0].openedAt).toBeGreaterThan(0);
    // The popup page was closed — only the original tab remains in the context.
    await vi.waitFor(() => {
      expect(handle.context.pages()).toHaveLength(1);
    });
  });

  it("takeover: refusal string toggles with setTakeover; unknown session is null/false", async () => {
    const registry = createBrowserSessionRegistry();
    await openSession(registry, "s1");
    expect(registry.refuseReasonIfTakeover("s1")).toBe(null);
    expect(registry.setTakeover("s1", true)).toBe(true);
    expect(registry.refuseReasonIfTakeover("s1")).toBe(TAKEOVER_REFUSAL);
    expect(registry.setTakeover("s1", false)).toBe(true);
    expect(registry.refuseReasonIfTakeover("s1")).toBe(null);
    expect(registry.setTakeover("missing", true)).toBe(false);
    expect(registry.refuseReasonIfTakeover("missing")).toBe(null);
  });
});
