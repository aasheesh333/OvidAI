/**
 * P6 Task 12 — browser tools I (session ops, navigation, inspection, reading,
 * screenshot, tabs). Every leg runs against the real pool + registry + a
 * local fixture server; the whole suite is chromium-gated.
 */

import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

import type { BrowserEngineConfig } from "../config.js";
import { chromiumExecutableExists, createBrowserPool, type BrowserPool } from "../pool.js";
import {
  TAKEOVER_REFUSAL,
  createBrowserSessionRegistry,
  type BrowserSessionRegistry,
} from "../sessions.js";
import { releaseSession } from "../sessionOps.js";
import type { StorageState, StorageStatePersistence } from "../stateStore.js";
import { startTestPageServer, type TestPageServer } from "../test/testServer.js";
import { BROWSER_TOOL_NAMES, createBrowserTools } from "./definitions.js";
import { TOOL_ERROR_PREFIX, type BrowserToolContext, type BrowserToolDef, type BrowserToolsDeps } from "./types.js";

const CTX: BrowserToolContext = { sessionId: "s1", userId: "u1" };

function makeCfg(): BrowserEngineConfig {
  return {
    maxLiveBrowsers: 2,
    tier1FallbackContexts: 1,
    idleEvictMs: 180_000,
    maxTier1Processes: 8,
    tier1TimeoutMs: 20_000,
    maxActiveScreencasts: 3,
    screencastLoadMax: 6.0,
    screencast: { width: 1280, height: 800, quality: 60, everyNthFrame: 2, maxFramesInFlight: 2 },
    stateDir: null,
    lightpandaBin: null,
    allowHosts: ["127.0.0.1", "localhost"],
    ownPublicIp: null,
    chromiumArgs: ["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"],
  };
}

describe.skipIf(!chromiumExecutableExists())("browser tools I", () => {
  let server: TestPageServer;
  let pool: BrowserPool;
  let registry: BrowserSessionRegistry;
  let deps: BrowserToolsDeps;
  let tools: Map<string, BrowserToolDef>;
  let wsRoot: string;
  let notify: ReturnType<typeof vi.fn>;
  let flush: ReturnType<typeof vi.fn>;
  let restore: ReturnType<typeof vi.fn>;

  beforeAll(async () => {
    server = await startTestPageServer();
  });

  afterAll(async () => {
    await server.close();
  });

  beforeEach(async () => {
    wsRoot = await mkdtemp(join(tmpdir(), "ovid-browser-tools-"));
    const cfg = makeCfg();
    pool = createBrowserPool(cfg);
    registry = createBrowserSessionRegistry();
    notify = vi.fn();
    flush = vi.fn(async () => {});
    restore = vi.fn(async () => null);
    const persistence = { flush, restore } as unknown as StorageStatePersistence;
    deps = {
      pool,
      registry,
      persistence,
      cfg,
      workspaceDir: async () => wsRoot,
      notifyState: notify,
    };
    tools = new Map(createBrowserTools(deps).map((t) => [t.name, t]));
  });

  afterEach(async () => {
    await pool.close();
    await rm(wsRoot, { recursive: true, force: true });
  });

  function tool(name: string): BrowserToolDef {
    const def = tools.get(name);
    if (!def) throw new Error(`missing tool ${name}`);
    return def;
  }

  function exec(name: string, input: unknown) {
    return tool(name).execute(input, CTX);
  }

  // -------------------------------------------------------------------------
  // Navigation
  // -------------------------------------------------------------------------

  it("browser_open returns title + final URL + article markdown and notifies once", async () => {
    const result = await exec("browser_open", { url: server.url("/") });
    expect(result.content).toContain("Static article");
    expect(result.content).toContain(server.url("/"));
    expect(result.content.length).toBeGreaterThanOrEqual(600);
    expect(pool.liveCount()).toBe(1);
    expect(notify).toHaveBeenCalledTimes(1);
    expect(notify).toHaveBeenCalledWith("s1");
  });

  it("browser_navigate is the same implementation as browser_open", async () => {
    const result = await exec("browser_navigate", { url: server.url("/click") });
    expect(result.content).toContain("Click");
    expect(pool.liveCount()).toBe(1);
  });

  it("refuses file:// before creating any context", async () => {
    const result = await exec("browser_open", { url: "file:///etc/passwd" });
    expect(result.content).toContain("file:");
    expect(result.content).toContain("browser_open");
    expect(pool.liveCount()).toBe(0);
    expect(registry.get("s1")).toBeNull();
  });

  it("refuses SSRF hosts before creating any context", async () => {
    const result = await exec("browser_open", { url: "http://169.254.169.254/" });
    expect(result.content).toMatch(/refused/i);
    expect(result.content).toMatch(/non-public|169\.254/);
    expect(pool.liveCount()).toBe(0);
  });

  it("opens the same session twice on one live context", async () => {
    await exec("browser_open", { url: server.url("/") });
    await exec("browser_open", { url: server.url("/click") });
    expect(pool.liveCount()).toBe(1);
    expect(registry.get("s1")?.tabs).toHaveLength(1);
  });

  it("browser_back / forward / reload report title + url", async () => {
    await exec("browser_open", { url: server.url("/") });
    await exec("browser_open", { url: server.url("/click") });
    const back = await exec("browser_back", {});
    expect(back.content).toContain("Static article");
    expect(back.content).toContain(server.url("/"));
    const forward = await exec("browser_forward", {});
    expect(forward.content).toContain("Click");
    const reload = await exec("browser_reload", {});
    expect(reload.content).toContain("Click");
  });

  // -------------------------------------------------------------------------
  // Inspection / reading
  // -------------------------------------------------------------------------

  it("browser_read extracts markdown and caps it with a truncation note", async () => {
    await exec("browser_open", { url: server.url("/big") });
    const result = await exec("browser_read", {});
    expect(result.content).toMatch(/truncated \d+ chars/);
    expect(result.content.length).toBeLessThanOrEqual(8000 + 60);
  });

  it("browser_outline lists the fixture button and form field", async () => {
    await exec("browser_open", { url: server.url("/click") });
    const result = await exec("browser_outline", {});
    expect(result.content).toContain("button: Click me");
    expect(result.content).toContain("id=in");
  });

  it("browser_snapshot returns an accessibility tree containing the button", async () => {
    await exec("browser_open", { url: server.url("/click") });
    const result = await exec("browser_snapshot", {});
    expect(result.content.toLowerCase()).toContain("button");
    expect(result.content).toContain("Click me");
  });

  it("browser_find counts matches and snippets the first one", async () => {
    await exec("browser_open", { url: server.url("/click") });
    const before = await exec("browser_find", { text: "CLICKED" });
    expect(before.content).toContain("0 matches");

    await deps.registry.activePage("s1")!.evaluate('document.getElementById("btn").click()', undefined);

    const after = await exec("browser_find", { text: "CLICKED" });
    expect(after.content).toMatch(/^(\d+) match/);
    const count = Number(/^(\d+) match/.exec(after.content)![1]);
    expect(count).toBeGreaterThanOrEqual(1);
    expect(after.content).toContain("CLICKED");
  });

  it("browser_evaluate returns JSON and prefixes evaluation errors", async () => {
    await exec("browser_open", { url: server.url("/") });
    const ok = await exec("browser_evaluate", { expression: "1+1" });
    expect(ok.content).toBe("2");

    const bad = await exec("browser_evaluate", { expression: "1 +" });
    expect(bad.content.startsWith(TOOL_ERROR_PREFIX)).toBe(true);
  });

  it("browser_wait_for returns timeout as a result, never an error", async () => {
    await exec("browser_open", { url: server.url("/click") });
    const result = await exec("browser_wait_for", { text: "nope", timeoutMs: 200 });
    expect(result.content).toBe("timeout");
  });

  it("browser_screenshot writes a workspace-relative jpeg artifact", async () => {
    await exec("browser_open", { url: server.url("/click") });
    const result = await exec("browser_screenshot", {});
    expect(result.content).toContain("screenshot saved: browser/screenshots/");
    expect(result.artifacts).toHaveLength(1);
    const ref = result.artifacts![0];
    expect(ref.kind).toBe("screenshot");
    expect(ref.path).toMatch(/^browser\/screenshots\/.+\.jpg$/);
    expect(ref.mimeType).toBe("image/jpeg");

    const abs = join(wsRoot, ref.path);
    const info = await stat(abs);
    expect(ref.bytes).toBe(info.size);
    const bytes = await readFile(abs);
    expect(bytes[0]).toBe(0xff);
    expect(bytes[1]).toBe(0xd8);
  });

  it("browser_resize clamps and applies the viewport", async () => {
    await exec("browser_open", { url: server.url("/") });
    const result = await exec("browser_resize", { width: 10_000, height: 10 });
    expect(result.content).toBe("viewport 3840x240");
    expect(deps.registry.activePage("s1")!.viewportSize()).toEqual({ width: 3840, height: 240 });
  });

  // -------------------------------------------------------------------------
  // Tabs
  // -------------------------------------------------------------------------

  it("tab tools round-trip: new, list, switch, close, range error", async () => {
    await exec("browser_open", { url: server.url("/") });
    const opened = await exec("browser_new_tab", { url: server.url("/click") });
    expect(opened.content).toContain("(tab 1 of 2)");
    expect(registry.get("s1")?.tabs).toHaveLength(2);
    expect(registry.get("s1")?.activeIndex).toBe(1);

    const listed = await exec("browser_list_tabs", {});
    const lines = listed.content.split("\n");
    expect(lines).toHaveLength(2);
    expect(lines.some((l) => /^\* 1: Click/.test(l))).toBe(true);
    expect(lines.some((l) => /^\s+0: Static article/.test(l))).toBe(true);

    const switched = await exec("browser_switch_tab", { index: 0 });
    expect(switched.content).toContain("active tab 0");
    expect(registry.get("s1")?.activeIndex).toBe(0);
    expect((await exec("browser_list_tabs", {})).content).toMatch(/^\* 0:/m);

    const closed = await exec("browser_close_tab", { index: 1 });
    expect(closed.content).toContain("closed tab 1");
    expect(registry.get("s1")?.tabs).toHaveLength(1);

    const bad = await exec("browser_close_tab", { index: 9 });
    expect(bad.content.startsWith(TOOL_ERROR_PREFIX)).toBe(true);
    expect(bad.content).toContain("out of range (0..0)");
  });

  // -------------------------------------------------------------------------
  // Guards
  // -------------------------------------------------------------------------

  it("takeover pauses driving tools with the exact refusal", async () => {
    await exec("browser_open", { url: server.url("/") });
    registry.setTakeover("s1", true);

    expect((await exec("browser_open", { url: server.url("/click") })).content).toBe(TAKEOVER_REFUSAL);
    expect((await exec("browser_read", {})).content).toBe(TAKEOVER_REFUSAL);
  });

  it("invalid arguments are reported as an error result, not a throw", async () => {
    const result = await exec("browser_find", {});
    expect(result.content.startsWith(TOOL_ERROR_PREFIX)).toBe(true);
    expect(result.content).toContain("invalid arguments");
  });

  // -------------------------------------------------------------------------
  // sessionOps
  // -------------------------------------------------------------------------

  it("releaseSession flushes cookies, closes the context, and notifies", async () => {
    await exec("browser_open", { url: server.url("/setcookie") });
    expect(pool.liveCount()).toBe(1);
    notify.mockClear();

    await releaseSession(deps, "s1");

    expect(flush).toHaveBeenCalledTimes(1);
    const [userId, captured] = flush.mock.calls[0] as [string, StorageState];
    expect(userId).toBe("u1");
    expect(captured.cookies.some((c) => c.name === "login_tok" && c.value === "abc123")).toBe(true);
    expect(pool.liveCount()).toBe(0);
    expect(registry.get("s1")).toBeNull();
    expect(notify).toHaveBeenCalledWith("s1");
  });

  it("releaseSession on an unknown session is a no-op", async () => {
    await expect(releaseSession(deps, "missing")).resolves.toBeUndefined();
    expect(flush).not.toHaveBeenCalled();
  });

  it("ensureSession restores persisted cookies into the new context", async () => {
    const stored: StorageState = {
      cookies: [
        {
          name: "login_tok",
          value: "restored",
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
    restore.mockResolvedValue(stored);

    await exec("browser_open", { url: server.url("/") });

    expect(restore).toHaveBeenCalledWith("u1");
    const session = registry.get("s1");
    expect(session).not.toBeNull();
    const cookies = await session!.handle.context.cookies();
    expect(cookies.some((c) => c.name === "login_tok" && c.value === "restored")).toBe(true);
  });

  // -------------------------------------------------------------------------
  // Roster pin
  // -------------------------------------------------------------------------

  it("exposes the final sorted 36-tool roster with model-facing schemas", () => {
    const expected = [
      "browser_back",
      "browser_click",
      "browser_close_tab",
      "browser_console",
      "browser_cookies",
      "browser_dialog",
      "browser_double_click",
      "browser_download",
      "browser_drag",
      "browser_evaluate",
      "browser_fill",
      "browser_find",
      "browser_forward",
      "browser_hover",
      "browser_list_tabs",
      "browser_long_press",
      "browser_navigate",
      "browser_network",
      "browser_new_tab",
      "browser_open",
      "browser_outline",
      "browser_popups",
      "browser_press_key",
      "browser_read",
      "browser_reload",
      "browser_resize",
      "browser_screenshot",
      "browser_scroll",
      "browser_select",
      "browser_snapshot",
      "browser_swipe",
      "browser_switch_tab",
      "browser_tap_at",
      "browser_type",
      "browser_upload",
      "browser_wait_for",
    ];
    const defs = createBrowserTools(deps);
    expect(defs.map((d) => d.name)).toEqual(expected);
    expect([...BROWSER_TOOL_NAMES]).toEqual(expected);
    for (const def of defs) {
      expect(def.description.trim().length).toBeGreaterThan(0);
      expect(def.parameters.type).toBe("object");
      expect(typeof def.execute).toBe("function");
    }
  });
});
