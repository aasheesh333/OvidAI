/**
 * P6 Task 13 — browser tools II (interaction, forms, cookies, dialogs,
 * transfers). Every leg runs against the real pool + registry + local fixture
 * server; the whole suite is chromium-gated.
 */

import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
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
import { startTestPageServer, type TestPageServer } from "../test/testServer.js";
import { BROWSER_TOOL_NAMES, createBrowserTools } from "./definitions.js";
import {
  TOOL_ERROR_PREFIX,
  type BrowserToolContext,
  type BrowserToolDef,
  type BrowserToolsDeps,
} from "./types.js";

const CTX: BrowserToolContext = { sessionId: "s1", userId: "u1" };

function makeCfg(): BrowserEngineConfig {
  return {
    maxLiveBrowsers: 2,
    tier1FallbackContexts: 1,
    idleEvictMs: 180_000,
    maxTier1Processes: 8,
    tier1TimeoutMs: 20_000,
    maxActiveScreencasts: 3,
    screencastDetachGraceMs: 0,
    screencastLoadMax: 6.0,
    screencast: { width: 1280, height: 800, quality: 60, everyNthFrame: 2, maxFramesInFlight: 2 },
    stateDir: null,
    lightpandaBin: null,
    allowHosts: ["127.0.0.1", "localhost"],
    ownPublicIp: null,
    blockHeavyResources: false,
  chromiumArgs: ["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"],
  };
}

async function until(check: () => boolean | Promise<boolean>, timeoutMs = 4_000): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (await check()) return;
    await new Promise((r) => setTimeout(r, 25));
  }
  throw new Error("condition not satisfied in time");
}

describe.skipIf(!chromiumExecutableExists())("browser tools II", () => {
  let server: TestPageServer;
  let pool: BrowserPool;
  let registry: BrowserSessionRegistry;
  let deps: BrowserToolsDeps;
  let tools: Map<string, BrowserToolDef>;
  let wsRoot: string;

  beforeAll(async () => {
    server = await startTestPageServer();
  });

  afterAll(async () => {
    await server.close();
  });

  beforeEach(async () => {
    wsRoot = await mkdtemp(join(tmpdir(), "ovid-browser-tools2-"));
    await mkdir(join(wsRoot, "uploads"), { recursive: true });
    await writeFile(join(wsRoot, "uploads", "hello.txt"), "hello upload");
    const cfg = makeCfg();
    pool = createBrowserPool(cfg, { sweepIntervalMs: 0 });
    registry = createBrowserSessionRegistry();
    deps = {
      pool,
      registry,
      persistence: null,
      cfg,
      workspaceDir: async () => wsRoot,
      notifyState: vi.fn(),
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

  async function open(pathname: string): Promise<void> {
    const result = await exec("browser_open", { url: server.url(pathname) });
    expect(result.content.startsWith(TOOL_ERROR_PREFIX)).toBe(false);
  }

  function page() {
    return registry.activePage("s1")!;
  }

  // -------------------------------------------------------------------------
  // Click / pointer family
  // -------------------------------------------------------------------------

  it("browser_click clicks the fixture button", async () => {
    await open("/click");
    const result = await exec("browser_click", { selector: "#btn" });
    expect(result.content).toBe("clicked #btn");
    expect(await page().evaluate('document.getElementById("out").textContent')).toBe("CLICKED");
  });

  it("browser_click reports a missing selector without throwing", async () => {
    await open("/click");
    const result = await exec("browser_click", { selector: "#nope" });
    expect(result.content.startsWith(TOOL_ERROR_PREFIX)).toBe(true);
    expect(result.content).toContain("selector not found: #nope");
  });

  it("browser_double_click and browser_hover reach the fixture", async () => {
    await open("/click");
    expect((await exec("browser_double_click", { selector: "#btn" })).content).toBe("double-clicked #btn");
    expect((await exec("browser_hover", { selector: "#btn" })).content).toBe("hovered #btn");
  });

  it("browser_tap_at maps through applyInputEvent", async () => {
    await open("/click");
    const result = await exec("browser_tap_at", { x: 70, y: 40 });
    expect(result.content).toBe("tapped at 70,40");
    expect(await page().evaluate('document.getElementById("out").textContent')).toBe("CLICKED");
  });

  it("browser_swipe maps through applyInputEvent and clicks", async () => {
    await open("/click");
    const result = await exec("browser_swipe", { fromX: 70, fromY: 40, toX: 70, toY: 40, steps: 2 });
    expect(result.content).toContain("swiped");
    expect(await page().evaluate('document.getElementById("out").textContent')).toBe("CLICKED");
  });

  it("browser_long_press holds for the requested duration", async () => {
    await open("/click");
    const started = Date.now();
    const result = await exec("browser_long_press", { x: 70, y: 40, durationMs: 120 });
    const elapsed = Date.now() - started;
    expect(result.content).toContain("long-pressed");
    expect(elapsed).toBeGreaterThanOrEqual(100);
  });

  it("browser_long_press resolves a selector to its box center", async () => {
    await open("/click");
    const result = await exec("browser_long_press", { selector: "#btn", durationMs: 60 });
    expect(result.content).toBe("long-pressed #btn");
  });

  it("browser_drag drops between the fixture drop zones", async () => {
    await open("/click");
    const result = await exec("browser_drag", { from: "#drop1", to: "#drop2" });
    expect(result.content).toBe("dragged #drop1 → #drop2");
    expect(await page().evaluate('document.getElementById("out").textContent')).toBe("DROPPED:one");
  });

  // -------------------------------------------------------------------------
  // Forms
  // -------------------------------------------------------------------------

  it("browser_type fills and submits through the fixture form handler", async () => {
    await open("/click");
    const result = await exec("browser_type", { selector: "#in", text: "hello", submit: true });
    expect(result.content).toBe("typed 5 chars into #in");
    const found = await exec("browser_find", { text: "SUBMITTED:hello" });
    expect(found.content).toContain("match");
    expect(found.content).not.toContain("0 matches");
  });

  it("browser_fill fills every field in order", async () => {
    await open("/click");
    const result = await exec("browser_fill", { fields: { "#in": "one", "#in2": "two" } });
    expect(result.content.split("\n")).toHaveLength(2);
    expect(result.content).toContain("#in");
    expect(result.content).toContain("#in2");
    expect(await page().evaluate('document.getElementById("in").value')).toBe("one");
    expect(await page().evaluate('document.getElementById("in2").value')).toBe("two");
  });

  it("browser_fill reports MISSING and continues (Dart parity)", async () => {
    await open("/click");
    const result = await exec("browser_fill", { fields: { "#in": "one", "#nope": "x", "#in2": "two" } });
    const lines = result.content.split("\n");
    expect(lines).toHaveLength(3);
    expect(lines).toContain("MISSING #nope");
    expect(await page().evaluate('document.getElementById("in").value')).toBe("one");
    expect(await page().evaluate('document.getElementById("in2").value')).toBe("two");
  });

  it("browser_select applies the option value", async () => {
    await open("/click");
    const result = await exec("browser_select", { selector: "#sel", value: "b" });
    expect(result.content).toBe("selected b");
    expect(await page().evaluate('document.getElementById("sel").value')).toBe("b");
  });

  it("browser_press_key dispatches the fixture key handler", async () => {
    await open("/click");
    const result = await exec("browser_press_key", { key: "Enter" });
    expect(result.content).toBe("pressed Enter");
    expect(await page().evaluate('document.getElementById("out").textContent')).toBe("KEY_ENTER");
  });

  it("browser_scroll scrolls the page down and reports the new position", async () => {
    await open("/big");
    const result = await exec("browser_scroll", { direction: "down", amount: 300 });
    const match = /scrollY: (\d+)/.exec(result.content);
    expect(match).not.toBeNull();
    expect(Number(match![1])).toBeGreaterThanOrEqual(250);
    expect(result.content).toContain("scrolled down");
  });

  // -------------------------------------------------------------------------
  // Cookies
  // -------------------------------------------------------------------------

  it("browser_cookies get/set/delete/clear round-trips", async () => {
    await open("/setcookie");
    expect((await exec("browser_cookies", { get: "login_tok" })).content).toBe("login_tok=abc123");

    expect((await exec("browser_cookies", { set: "x=1; path=/" })).content).toBe("cookie set");
    expect((await exec("browser_cookies", { get: "x" })).content).toBe("x=1");

    expect((await exec("browser_cookies", { delete: "x" })).content).toBe("cookie deleted");
    expect((await exec("browser_cookies", { get: "x" })).content).toBe("no cookie named x");

    expect((await exec("browser_cookies", { clear: true })).content).toBe("all cookies cleared");
    expect((await exec("browser_cookies", { get: "login_tok" })).content).toBe("no cookie named login_tok");
  });

  // -------------------------------------------------------------------------
  // Dialogs / console / network / popups
  // -------------------------------------------------------------------------

  it("browser_dialog reads and accepts the held prompt", async () => {
    await open("/click");
    await exec("browser_click", { selector: "#prompt-btn" });
    await until(() => (registry.get("s1")?.dialogs.length ?? 0) > 0);

    expect((await exec("browser_dialog", { action: "read" })).content).toBe("prompt: p?");
    expect((await exec("browser_dialog", { action: "accept", text: "yes" })).content).toBe("dialog accepted");

    await until(async () => (await page().evaluate('document.getElementById("out").textContent')) === "PROMPT:yes");
    expect((await exec("browser_dialog", { action: "read" })).content).toBe("no pending dialog");
  });

  it("browser_console reads and clears the console buffer", async () => {
    await open("/click");
    const read = await exec("browser_console", { action: "read" });
    expect(read.content).toContain("click-fixture-ready");

    expect((await exec("browser_console", { action: "clear" })).content).toBe("console cleared");
    expect((await exec("browser_console", { action: "read" })).content).toBe("no console entries");
  });

  it("browser_network lists responses and clears the buffer", async () => {
    await open("/click");
    await until(() => (registry.get("s1")?.network.length ?? 0) > 0);
    const listed = await exec("browser_network", { action: "list" });
    expect(listed.content).toMatch(/GET 200 .*\/click/);

    expect((await exec("browser_network", { action: "clear" })).content).toBe("network log cleared");
    expect((await exec("browser_network", { action: "list" })).content).toBe("no network entries");
  });

  it("browser_popups lists, re-opens, and clears recorded popups", async () => {
    await open("/click");
    await exec("browser_click", { selector: "#popup-btn" });
    await until(() => (registry.get("s1")?.popups.length ?? 0) > 0);

    const listed = await exec("browser_popups", { action: "list" });
    expect(listed.content).toContain("/spa");

    const opened = await exec("browser_popups", { action: "open", url: server.url("/click") });
    expect(opened.content).toContain("opened");
    expect(registry.get("s1")?.tabs).toHaveLength(2);

    expect((await exec("browser_popups", { action: "clear" })).content).toBe("popups cleared");
    expect(registry.get("s1")?.popups).toHaveLength(0);
  });

  // -------------------------------------------------------------------------
  // Transfers
  // -------------------------------------------------------------------------

  it("browser_download saves the response under browser/downloads with an artifact ref", async () => {
    const result = await exec("browser_download", { url: server.url("/attachment") });
    expect(result.content).toBe("saved 10 bytes to browser/downloads/attachment");
    expect(result.artifacts).toHaveLength(1);
    const ref = result.artifacts![0];
    expect(ref.kind).toBe("download");
    expect(ref.path).toBe("browser/downloads/attachment");
    expect(ref.mimeType).toContain("application/octet-stream");
    expect(ref.bytes).toBe(10);

    const abs = join(wsRoot, ref.path);
    expect((await stat(abs)).size).toBe(10);
    expect((await readFile(abs)).toString()).toBe("file-bytes");
  });

  it("browser_download refuses oversized bodies (dep-injected limit seam)", async () => {
    deps.downloadMaxBytes = 1;
    const result = await exec("browser_download", { url: server.url("/attachment") });
    expect(result.content).toBe("Download refused: file exceeds the 50 MB limit.");
    expect(existsSync(join(wsRoot, "browser", "downloads", "attachment"))).toBe(false);
  });

  it("browser_download refuses a declared-oversize body before reading it", async () => {
    deps.downloadMaxBytes = 100;
    const started = Date.now();
    const result = await exec("browser_download", { url: server.url("/attachment-slow") });
    const elapsed = Date.now() - started;
    expect(result.content).toBe("Download refused: file exceeds the 50 MB limit.");
    // The fixture delays its body by 1.5 s; a Content-Length pre-check
    // returns without waiting for (or buffering) a single body byte.
    expect(elapsed).toBeLessThan(1_000);
    expect(existsSync(join(wsRoot, "browser", "downloads", "attachment-slow"))).toBe(false);
  });

  it("browser_download aborts an undeclared stream at the cap", async () => {
    deps.downloadMaxBytes = 50;
    const result = await exec("browser_download", { url: server.url("/attachment-chunked") });
    expect(result.content).toBe("Download refused: file exceeds the 50 MB limit.");
    expect(existsSync(join(wsRoot, "browser", "downloads", "attachment-chunked"))).toBe(false);
  });

  it("browser_download refuses an escaping filename", async () => {
    const result = await exec("browser_download", { url: server.url("/attachment"), filename: "../evil" });
    expect(result.content).toBe("Download refused: invalid filename.");
  });

  it("page-initiated downloads auto-save and appear in the network buffer", async () => {
    await open("/click");
    // The click itself may abort the navigation with net::ERR_ABORTED — the
    // download event is what we are pinning. Wait for the network entry (it is
    // pushed after saveAs completes) before reading the file.
    await exec("browser_click", { selector: "#dl" });
    const abs = join(wsRoot, "browser", "downloads", "attachment");
    // Wait for the COMPLETE file (saveAs resolves before the network entry is
    // pushed, but the file can appear mid-write) then assert the log entry.
    await until(async () => {
      try {
        return (await stat(abs)).size === 10;
      } catch {
        return false;
      }
    });
    expect((await readFile(abs)).toString()).toBe("file-bytes");
    await until(() => (registry.get("s1")?.network.some((e) => e.url.endsWith("/attachment")) ?? false));
  });

  it("page-initiated downloads over the cap are refused, not saved", async () => {
    deps.downloadMaxBytes = 1;
    await open("/click");
    await exec("browser_click", { selector: "#dl" });
    await until(() =>
      (registry.get("s1")?.network.some((e) => e.url.endsWith("/attachment") && e.failure !== null) ?? false),
    );
    expect(existsSync(join(wsRoot, "browser", "downloads", "attachment"))).toBe(false);
  });

  it("browser_upload uploads a workspace file and the fixture echoes its name", async () => {
    await open("/click");
    const result = await exec("browser_upload", { selector: "#file", path: "uploads/hello.txt" });
    expect(result.content).toBe("uploaded uploads/hello.txt to #file");
    expect(await page().evaluate('document.getElementById("out").textContent')).toBe("FILE:hello.txt");
  });

  it("browser_upload refuses a path that escapes the workspace", async () => {
    await open("/click");
    const result = await exec("browser_upload", { selector: "#file", path: "../../etc/passwd" });
    expect(result.content).toBe("Upload refused: path escapes the session workspace.");
  });

  // -------------------------------------------------------------------------
  // Guards / roster
  // -------------------------------------------------------------------------

  it("takeover refuses interaction and cookie tools with the exact copy", async () => {
    await open("/click");
    registry.setTakeover("s1", true);
    expect((await exec("browser_click", { selector: "#btn" })).content).toBe(TAKEOVER_REFUSAL);
    expect((await exec("browser_cookies", { get: "x" })).content).toBe(TAKEOVER_REFUSAL);
  });

  it("invalid arguments are reported as an error result, not a throw", async () => {
    const result = await exec("browser_cookies", {});
    expect(result.content.startsWith(TOOL_ERROR_PREFIX)).toBe(true);
    expect(result.content).toContain("invalid arguments");
  });

  it("exposes the final sorted 37-tool roster with no duplicates", () => {
    const names = createBrowserTools(deps).map((t) => t.name);
    expect(names).toHaveLength(37);
    expect(new Set(names).size).toBe(37);
    expect([...names].sort()).toEqual(names);
    for (const name of names) expect(name.startsWith("browser_")).toBe(true);
    expect([...BROWSER_TOOL_NAMES]).toEqual(names);
  });
});
