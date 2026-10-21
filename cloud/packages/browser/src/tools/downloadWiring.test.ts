/**
 * Page-initiated download wiring: the extension allowlist and the
 * page → chat destination key. Uses a stub context/event emitter — no
 * chromium required.
 */

import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { Page } from "playwright-core";

import type { SessionBrowser } from "../sessions.js";
import { wireDownloads } from "./downloadWiring.js";
import type { BrowserToolsDeps } from "./types.js";

interface Harness {
  fireDownload(download: unknown): Promise<void>;
  registers: Array<Record<string, unknown>>;
  root: string;
  session: SessionBrowser;
  pages: Page[];
}

function makeHarness(root: string): Harness {
  let listener: ((download: unknown) => void) | null = null;
  const registers: Array<Record<string, unknown>> = [];

  const page = (label: string): Page =>
    ({
      url: () => `https://example.test/${label}`,
      title: async () => label,
    }) as unknown as Page;
  const pages = [page("one"), page("two")];

  const context = {
    on(event: string, cb: (download: unknown) => void) {
      if (event === "download") listener = cb;
    },
  };

  const session = {
    sessionId: "browser-key",
    userId: "u1",
    handle: { page: pages[0], context, touch() {} },
    tabs: [pages[0]],
    activeIndex: 0,
    takeover: false,
    takeoverViewerId: null,
    lastActivityAt: 0,
    console: [],
    network: [],
    dialogs: [],
    popups: [],
  } as unknown as SessionBrowser;

  const deps = {
    pool: {} as never,
    registry: {} as never,
    persistence: null,
    cfg: {},
    workspaceDir: async () => root,
    artifactVault: {
      async registerFromWorkspace(input: Record<string, unknown>) {
        registers.push({ ...input });
        return { id: "artifact-1" };
      },
      async fetchToWorkspace() {
        return null;
      },
    },
  } as unknown as BrowserToolsDeps;

  // Wire chat-1 for page one, then chat-2 for page two (same context).
  wireDownloads(deps, session, "chat-1");
  session.tabs = [pages[1]];
  session.activeIndex = 0;
  wireDownloads(deps, session, "chat-2");

  return {
    root,
    session,
    pages,
    registers,
    async fireDownload(download: unknown) {
      if (listener === null) throw new Error("download listener was not wired");
      listener(download);
      await new Promise((r) => setTimeout(r, 20));
    },
  };
}

describe("page-initiated download wiring", () => {
  let root: string;

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), "ovid-page-download-"));
  });

  afterEach(async () => {
    await rm(root, { recursive: true, force: true });
  });

  it("lands in the chat that owns the page that triggered it (not the latest tool call)", async () => {
    const h = makeHarness(root);
    const temp = join(root, "tmp-download");
    await writeFile(temp, "page bytes");

    await h.fireDownload({
      url: () => "https://example.test/data.csv",
      suggestedFilename: () => "data.csv",
      page: () => h.pages[0],
      path: async () => temp,
      saveAs: async (dest: string) => writeFile(dest, "page bytes"),
      delete: async () => {},
    });

    expect(await readFile(join(root, "browser/downloads/data.csv"), "utf8")).toBe("page bytes");
    expect(h.registers).toEqual([
      {
        userId: "u1",
        sessionId: "chat-1", // page one's chat, even though chat-2 ran last
        path: "browser/downloads/data.csv",
        mimeType: "text/csv",
      },
    ]);
  });

  it("refuses a page download with a disallowed extension before saveAs", async () => {
    const h = makeHarness(root);
    const saveAs = vi.fn(async () => {});
    const del = vi.fn(async () => {});

    await h.fireDownload({
      url: () => "https://example.test/payload.html",
      suggestedFilename: () => "payload.html",
      page: () => h.pages[0],
      path: async () => {
        throw new Error("path() must not be reached");
      },
      saveAs,
      delete: del,
    });

    expect(del).toHaveBeenCalledTimes(1);
    expect(saveAs).not.toHaveBeenCalled();
    expect(existsSync(join(root, "browser", "downloads", "payload.html"))).toBe(false);
    expect(h.registers).toEqual([]);
    expect(h.session.network.at(-1)?.failure).toBe("download refused: file type not allowed");
  });

  it("refuses .svg and .exe page downloads too", async () => {
    for (const name of ["icon.svg", "setup.exe"]) {
      const h = makeHarness(root);
      const saveAs = vi.fn(async () => {});
      await h.fireDownload({
        url: () => `https://example.test/${name}`,
        suggestedFilename: () => name,
        page: () => h.pages[0],
        path: async () => {
          throw new Error("path() must not be reached");
        },
        saveAs,
        delete: async () => {},
      });
      expect(saveAs).not.toHaveBeenCalled();
      expect(existsSync(join(root, "browser", "downloads", name))).toBe(false);
    }
  });
});
