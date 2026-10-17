/**
 * Browser navigation + tab tools (P6 Task 12).
 *
 * `browser_open` and `browser_navigate` are intentionally identical (Dart
 * keeps both for model familiarity). Both gate the URL BEFORE touching the
 * pool, so a refused scheme/SSRF target never creates a context.
 *
 * Notification discipline: tools that mutate session-visible state (open,
 * navigate, back/forward/reload, tab ops) publish state exactly once, after
 * the operation succeeded. When they create the session themselves they
 * suppress `ensureSession`'s creation notification so the published state
 * carries the post-navigation URL/title rather than the blank initial page.
 */

import type { Page } from "playwright-core";
import { z } from "zod";

import { ensureSession, guardUrl, withSession } from "../sessionOps.js";
import { extractReadable } from "../staticExtract.js";
import {
  TOOL_ERROR_PREFIX,
  TEXT_OUTPUT_CAP,
  capText,
  defineBrowserTool,
  messageOf,
  pageInnerText,
  type BrowserToolDef,
  type BrowserToolSpec,
  type BrowserToolsDeps,
} from "./types.js";

const GOTO = { waitUntil: "domcontentloaded" as const, timeout: 30_000 };

const URL_PARAMETERS = {
  type: "object",
  properties: {
    url: {
      type: "string",
      description: "Absolute http(s) URL to open (file:, javascript:, data: and private hosts are refused).",
    },
  },
  required: ["url"],
};

function openSpec(name: "browser_open" | "browser_navigate"): BrowserToolSpec {
  return {
    name,
    description:
      name === "browser_open"
        ? "Open a URL in the browser and return the page title, final URL, and extracted page text so you can read or act on it (research, docs, APIs)."
        : "Navigate the browser to a URL. Returns the page title, final URL, and the first chunk of page text. Same as browser_open; use either.",
    parameters: URL_PARAMETERS,
    inputSchema: z.object({ url: z.string().min(1) }),
    async execute(input, ctx, deps) {
      const url: string = input.url;
      const refusal = await guardUrl(url, name, deps.cfg);
      if (refusal !== null) return { content: refusal };

      // Publish once, after the navigation (see the file header).
      const session = await ensureSession({ ...deps, notifyState: undefined }, ctx);
      deps.registry.touch(ctx.sessionId);
      const page = session.tabs[session.activeIndex] ?? session.handle.page;

      try {
        await page.goto(url, GOTO);
      } catch (err) {
        return { content: `${TOOL_ERROR_PREFIX}navigation failed: ${messageOf(err)}` };
      }

      const title = await page.title();
      const finalUrl = page.url();
      const extracted = extractReadable(await page.content(), finalUrl);
      const text = extracted?.markdown ?? (await pageInnerText(page));
      deps.notifyState?.(ctx.sessionId);

      if (text.trim() === "") {
        // Exact Dart fallback copy (browser_open's empty-render branch).
        return {
          content: `Loaded ${url} (no readable text extracted from the rendered page; try browser_read or browser_outline).`,
        };
      }
      return { content: `${title}\n${finalUrl}\n\n${capText(text, TEXT_OUTPUT_CAP)}` };
    },
  };
}

function historySpec(
  name: "browser_back" | "browser_forward" | "browser_reload",
  description: string,
  run: (page: Page) => Promise<unknown>,
  noHistory: boolean,
): BrowserToolSpec {
  return {
    name,
    description,
    parameters: { type: "object", properties: {} },
    inputSchema: z.object({}),
    async execute(_input, ctx, deps) {
      return withSession(deps, ctx, async (_session, page) => {
        const result = await run(page);
        if (noHistory && result === null) {
          return { content: `${TOOL_ERROR_PREFIX}no history entry` };
        }
        deps.notifyState?.(ctx.sessionId);
        return { content: `${await page.title()}\n${page.url()}` };
      });
    },
  };
}

function tabRangeError(index: number, count: number): string {
  return `${TOOL_ERROR_PREFIX}tab index ${index} out of range (0..${count - 1})`;
}

function navigationSpecs(deps: BrowserToolsDeps): BrowserToolSpec[] {
  const newTab: BrowserToolSpec = {
    name: "browser_new_tab",
    description: "Open a NEW browser tab with a URL and make it active.",
    parameters: URL_PARAMETERS,
    inputSchema: z.object({ url: z.string().min(1) }),
    async execute(input, ctx) {
      const url: string = input.url;
      const refusal = await guardUrl(url, "browser_new_tab", deps.cfg);
      if (refusal !== null) return { content: refusal };

      const session = await ensureSession({ ...deps, notifyState: undefined }, ctx);
      deps.registry.touch(ctx.sessionId);
      const page = await session.handle.context.newPage();
      try {
        await page.goto(url, GOTO);
      } catch (err) {
        await page.close().catch(() => {});
        return { content: `${TOOL_ERROR_PREFIX}navigation failed: ${messageOf(err)}` };
      }
      const index = deps.registry.addTab(ctx.sessionId, page);
      deps.notifyState?.(ctx.sessionId);
      return {
        content: `${await page.title()}\n${page.url()} (tab ${index} of ${session.tabs.length})`,
      };
    },
  };

  const switchTab: BrowserToolSpec = {
    name: "browser_switch_tab",
    description: "Switch the active browser tab by 0-based index (use browser_list_tabs to see them).",
    parameters: {
      type: "object",
      properties: { index: { type: "integer", description: "0-based tab index." } },
      required: ["index"],
    },
    inputSchema: z.object({ index: z.number().int() }),
    async execute(input, ctx) {
      const index: number = input.index;
      const session = await ensureSession({ ...deps, notifyState: undefined }, ctx);
      if (index < 0 || index >= session.tabs.length) {
        return { content: tabRangeError(index, session.tabs.length) };
      }
      deps.registry.switchTab(ctx.sessionId, index);
      deps.registry.touch(ctx.sessionId);
      deps.notifyState?.(ctx.sessionId);
      const page = deps.registry.activePage(ctx.sessionId);
      return { content: `active tab ${index}: ${page ? page.url() : ""}` };
    },
  };

  const closeTab: BrowserToolSpec = {
    name: "browser_close_tab",
    description: "Close a browser tab by 0-based index.",
    parameters: {
      type: "object",
      properties: { index: { type: "integer", description: "0-based tab index." } },
      required: ["index"],
    },
    inputSchema: z.object({ index: z.number().int() }),
    async execute(input, ctx) {
      const index: number = input.index;
      const session = await ensureSession({ ...deps, notifyState: undefined }, ctx);
      if (index < 0 || index >= session.tabs.length) {
        return { content: tabRangeError(index, session.tabs.length) };
      }
      if (session.tabs.length <= 1) {
        return { content: `${TOOL_ERROR_PREFIX}cannot close the last tab` };
      }
      const closing = session.tabs[index];
      let url = "";
      try {
        url = closing.url();
      } catch {
        /* already gone */
      }
      deps.registry.closeTab(ctx.sessionId, index);
      deps.registry.touch(ctx.sessionId);
      deps.notifyState?.(ctx.sessionId);
      return { content: `closed tab ${index}${url ? ` (${url})` : ""}` };
    },
  };

  const listTabs: BrowserToolSpec = {
    name: "browser_list_tabs",
    description: "List all open browser tabs with index, title, and URL; the active tab is marked with *.",
    parameters: { type: "object", properties: {} },
    inputSchema: z.object({}),
    async execute(_input, ctx) {
      const session = deps.registry.get(ctx.sessionId);
      if (!session) return { content: "No tabs open." };
      const lines: string[] = [];
      for (let i = 0; i < session.tabs.length; i++) {
        const page = session.tabs[i];
        let title = "";
        let url = "";
        try {
          title = await page.title();
        } catch {
          /* page closing */
        }
        try {
          url = page.url();
        } catch {
          /* page closing */
        }
        lines.push(`${i === session.activeIndex ? "*" : " "} ${i}: ${title || "(untitled)"} — ${url}`);
      }
      return { content: lines.join("\n") };
    },
  };

  const resize: BrowserToolSpec = {
    name: "browser_resize",
    description:
      "Set the browser viewport for responsive testing. width/height define the logical viewport (e.g. 1280x800 desktop, 390x844 phone); values are clamped to 320-3840 x 240-2160. Applies to the active tab.",
    parameters: {
      type: "object",
      properties: {
        width: { type: "integer" },
        height: { type: "integer" },
      },
      required: ["width", "height"],
    },
    inputSchema: z.object({ width: z.number().int(), height: z.number().int() }),
    async execute(input, ctx) {
      const width = Math.min(3840, Math.max(320, Math.round(input.width)));
      const height = Math.min(2160, Math.max(240, Math.round(input.height)));
      return withSession(deps, ctx, async (_session, page) => {
        // The screencast's maxWidth/maxHeight stay at cfg values: a resize
        // changes the page's layout viewport, not the cast's downscale bound.
        await page.setViewportSize({ width, height });
        deps.notifyState?.(ctx.sessionId);
        return { content: `viewport ${width}x${height}` };
      });
    },
  };

  return [
    openSpec("browser_open"),
    openSpec("browser_navigate"),
    historySpec("browser_back", "Go back one step in the active tab's history.", (page) => page.goBack(GOTO), true),
    historySpec("browser_forward", "Go forward one step in the active tab's history.", (page) => page.goForward(GOTO), true),
    historySpec("browser_reload", "Reload the active tab.", (page) => page.reload(GOTO), false),
    newTab,
    switchTab,
    closeTab,
    listTabs,
    resize,
  ];
}

export function navigationTools(deps: BrowserToolsDeps): BrowserToolDef[] {
  return navigationSpecs(deps).map((spec) => defineBrowserTool(deps, spec));
}
