/**
 * browser_screenshot destination jail: a symlinked `browser/` component must
 * not redirect the screenshot outside the session workspace. Stub page/context
 * — no chromium required.
 */

import { existsSync } from "node:fs";
import { mkdtemp, readdir, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

import type { SessionBrowser } from "../sessions.js";
import { inspectionTools } from "./inspection.js";
import type { BrowserToolContext, BrowserToolsDeps } from "./types.js";

const CTX: BrowserToolContext = { sessionId: "s1", userId: "u1", workspaceSessionId: "chat-1" };

function depsFor(root: string): BrowserToolsDeps {
  const page = {
    url: () => "https://example.test/",
    title: async () => "fixture",
    screenshot: async () => Buffer.from("png-bytes"),
  };
  const context = {
    on() {},
  };
  const session = {
    sessionId: "s1",
    userId: "u1",
    handle: { page, context, touch() {} },
    tabs: [page],
    activeIndex: 0,
    takeover: false,
    takeoverViewerId: null,
    lastActivityAt: 0,
    console: [],
    network: [],
    dialogs: [],
    popups: [],
  } as unknown as SessionBrowser;

  return {
    pool: {} as never,
    registry: {
      get: () => session,
      getOwned: () => session,
      touch: () => {},
      refuseReasonIfTakeover: () => null,
    } as never,
    persistence: null,
    cfg: {} as never,
    workspaceDir: async () => root,
  };
}

describe("browser_screenshot workspace jail", () => {
  let root: string;
  let outside: string;

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), "ovid-shot-root-"));
    outside = await mkdtemp(join(tmpdir(), "ovid-shot-outside-"));
  });

  afterEach(async () => {
    await rm(root, { recursive: true, force: true });
    await rm(outside, { recursive: true, force: true });
  });

  it("writes a screenshot inside the workspace", async () => {
    const tool = new Map(inspectionTools(depsFor(root)).map((t) => [t.name, t])).get("browser_screenshot")!;
    const result = await tool.execute({ type: "png" }, CTX);
    expect(result.content).toContain("screenshot saved: browser/screenshots/");
    const entries = await readdir(join(root, "browser", "screenshots"));
    expect(entries).toHaveLength(1);
  });

  it("refuses to create the directory through a symlink that leaves the workspace", async () => {
    await symlink(outside, join(root, "browser"), "dir");
    const tool = new Map(inspectionTools(depsFor(root)).map((t) => [t.name, t])).get("browser_screenshot")!;
    const result = await tool.execute({ type: "png" }, CTX);

    expect(result.content).toBe("Screenshot refused: destination escapes the session workspace.");
    expect(existsSync(join(outside, "screenshots"))).toBe(false);
  });
});
