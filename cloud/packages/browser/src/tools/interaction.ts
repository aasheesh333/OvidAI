/**
 * Interaction + form + cookie + buffer tools (P6 Task 13).
 *
 * Pointer/keyboard injection for AGENT actions goes through the humanizer
 * (interpolated jittered moves + per-key typing delays, spec §8); viewer input
 * still reuses Task 7's `applyInputEvent` directly — a real finger is already
 * human. Coordinates share one validation/refusal shape (`clampToViewport`).
 * Form selects/presses use Playwright's native actions — those dispatch
 * `input`/`change` events exactly like a user edit.
 *
 * Cookies are context-scoped (not page-scoped): `get`/`set`/`delete`/`clear`
 * operate on the session's persistent context so logins survive tab changes.
 * Dialogs are the Task-5 HELD entries (`session.dialogs[0]`) — reading never
 * resolves them; accept/dismiss does. Console/network/popups read the Task-5
 * per-session rings; buffers are capped at 50 lines in tool output (Dart
 * parity) even though the rings themselves hold 200.
 */

import { z } from "zod";

import { createHumanizer, type Humanizer, type Point } from "../humanInput.js";
import { BrowserInputError, clampToViewport } from "../input.js";
import { guardUrl, withSession } from "../sessionOps.js";
import type { SessionBrowser } from "../sessions.js";
import { cookieDomainMatchesOrigin, formatCookieForModel } from "./cookiePolicy.js";
import {
  TOOL_ERROR_PREFIX,
  defineBrowserTool,
  messageOf,
  type BrowserToolDef,
  type BrowserToolSpec,
  type BrowserToolsDeps,
} from "./types.js";

const CLICK_TIMEOUT_MS = 10_000;
const OUTPUT_LINES = 50;

function notFound(selector: string): string {
  return `${TOOL_ERROR_PREFIX}selector not found: ${selector}`;
}

async function requireSelector(page: import("playwright-core").Page, selector: string): Promise<boolean> {
  return (await page.locator(selector).count()) > 0;
}

/** The shared humanizer (definitions.ts injects one; direct callers get a default). */
function humanFor(deps: BrowserToolsDeps): Humanizer {
  return deps.humanizer ?? createHumanizer();
}

/**
 * Scroll the element into view and return its center in CSS pixels — the
 * landing point for a human-like pointer path. null when the element has no
 * layout box (hidden / detached).
 */
async function centerOf(page: import("playwright-core").Page, selector: string): Promise<Point | null> {
  const loc = page.locator(selector).first();
  await loc.scrollIntoViewIfNeeded({ timeout: CLICK_TIMEOUT_MS }).catch(() => {
    // Not scrollable/visible enough — boundingBox() below is the honest test.
  });
  const box = await loc.boundingBox();
  if (box === null || box.width <= 0 || box.height <= 0) return null;
  return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
}

/** Focus the field, clear it, then type character-by-character with delays. */
async function typeInto(
  page: import("playwright-core").Page,
  human: Humanizer,
  selector: string,
  text: string,
): Promise<void> {
  await page.locator(selector).first().focus();
  // Replacing the value is still an explicit clear; the ENTRY is human-like.
  await page.fill(selector, "");
  await human.type(page, text);
}

/** BrowserInputError is malformed input, not a browser failure — same prefix, clean copy. */
function inputError(err: unknown): { content: string } {
  if (err instanceof BrowserInputError) return { content: TOOL_ERROR_PREFIX + err.message };
  throw err;
}

function safeOrigin(url: string): string | null {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return null;
    return parsed.origin;
  } catch {
    return null;
  }
}

interface ParsedCookie {
  name: string;
  value: string;
  path?: string;
  domain?: string;
}

/** Parse the Dart `browser_cookies set` syntax: "name=value; path=/; domain=…". */
function parseSetCookie(raw: string): ParsedCookie | null {
  const parts = raw
    .split(";")
    .map((part) => part.trim())
    .filter((part) => part !== "");
  const first = parts.shift();
  if (first === undefined) return null;
  const eq = first.indexOf("=");
  if (eq <= 0) return null;
  const name = first.slice(0, eq).trim();
  const value = first.slice(eq + 1).trim();
  if (name === "") return null;

  let path: string | undefined;
  let domain: string | undefined;
  for (const attr of parts) {
    const i = attr.indexOf("=");
    const key = (i === -1 ? attr : attr.slice(0, i)).trim().toLowerCase();
    const val = i === -1 ? "" : attr.slice(i + 1).trim();
    if (key === "path") path = val;
    else if (key === "domain") domain = val;
  }
  return { name, value, path, domain };
}

function interactionSpecs(deps: BrowserToolsDeps): BrowserToolSpec[] {
  const click: BrowserToolSpec = {
    name: "browser_click",
    description:
      "Click an element matching a CSS selector in the active tab. Use browser_outline/browser_snapshot first when you are unsure of the selector.",
    parameters: {
      type: "object",
      properties: { selector: { type: "string", description: "CSS selector of the element to click." } },
      required: ["selector"],
    },
    inputSchema: z.object({ selector: z.string().min(1) }),
    async execute(input, ctx) {
      const selector: string = input.selector;
      return withSession(deps, ctx, async (_session, page) => {
        if (!(await requireSelector(page, selector))) return { content: notFound(selector) };
        const point = await centerOf(page, selector);
        if (point === null) return { content: notFound(selector) };
        // Human-like: jittered, interpolated move → pause → press → release.
        await humanFor(deps).click(page, point);
        return { content: `clicked ${selector}` };
      });
    },
  };

  const doubleClick: BrowserToolSpec = {
    name: "browser_double_click",
    description:
      "Double-click (or triple-click with count:3) an element matching a CSS selector in the active tab.",
    parameters: {
      type: "object",
      properties: {
        selector: { type: "string" },
        count: { type: "integer", enum: [2, 3], description: "Click count (default 2)." },
      },
      required: ["selector"],
    },
    inputSchema: z.object({ selector: z.string().min(1), count: z.union([z.literal(2), z.literal(3)]).optional() }),
    async execute(input, ctx) {
      const selector: string = input.selector;
      const count: 2 | 3 = input.count ?? 2;
      return withSession(deps, ctx, async (_session, page) => {
        if (!(await requireSelector(page, selector))) return { content: notFound(selector) };
        const point = await centerOf(page, selector);
        if (point === null) return { content: notFound(selector) };
        const human = humanFor(deps);
        if (count === 3) {
          await human.click(page, point);
          await human.click(page, point);
          await human.click(page, point);
        } else {
          await human.doubleClick(page, point);
        }
        return { content: `double-clicked ${selector}` };
      });
    },
  };

  const hover: BrowserToolSpec = {
    name: "browser_hover",
    description: "Move the mouse over an element matching a CSS selector (hover menus, tooltips).",
    parameters: {
      type: "object",
      properties: { selector: { type: "string" } },
      required: ["selector"],
    },
    inputSchema: z.object({ selector: z.string().min(1) }),
    async execute(input, ctx) {
      const selector: string = input.selector;
      return withSession(deps, ctx, async (_session, page) => {
        if (!(await requireSelector(page, selector))) return { content: notFound(selector) };
        const point = await centerOf(page, selector);
        if (point === null) return { content: notFound(selector) };
        await humanFor(deps).moveMouse(page, point);
        return { content: `hovered ${selector}` };
      });
    },
  };

  const tapAt: BrowserToolSpec = {
    name: "browser_tap_at",
    description:
      "Tap at page CSS-pixel coordinates (viewport of the active tab). Useful when an element has no usable selector.",
    parameters: {
      type: "object",
      properties: {
        x: { type: "number" },
        y: { type: "number" },
      },
      required: ["x", "y"],
    },
    inputSchema: z.object({ x: z.number(), y: z.number() }),
    async execute(input, ctx) {
      const x: number = input.x;
      const y: number = input.y;
      return withSession(deps, ctx, async (_session, page) => {
        try {
          const point = await clampToViewport(page, x, y);
          await humanFor(deps).click(page, point);
        } catch (err) {
          return inputError(err);
        }
        return { content: `tapped at ${x},${y}` };
      });
    },
  };

  const swipe: BrowserToolSpec = {
    name: "browser_swipe",
    description:
      "Swipe/drag the pointer from one CSS-pixel point to another. Use for carousels, sliders, and pull gestures.",
    parameters: {
      type: "object",
      properties: {
        fromX: { type: "number" },
        fromY: { type: "number" },
        toX: { type: "number" },
        toY: { type: "number" },
        steps: { type: "integer", description: "Interpolation steps (default 8)." },
      },
      required: ["fromX", "fromY", "toX", "toY"],
    },
    inputSchema: z.object({
      fromX: z.number(),
      fromY: z.number(),
      toX: z.number(),
      toY: z.number(),
      steps: z.number().int().positive().optional(),
    }),
    async execute(input, ctx) {
      const event = {
        type: "swipe" as const,
        fromX: input.fromX,
        fromY: input.fromY,
        toX: input.toX,
        toY: input.toY,
        ...(input.steps !== undefined ? { steps: input.steps } : {}),
      };
      return withSession(deps, ctx, async (_session, page) => {
        try {
          const from = await clampToViewport(page, event.fromX, event.fromY);
          const to = await clampToViewport(page, event.toX, event.toY);
          // Human-like drag: press, interpolated/jittered path, release.
          await humanFor(deps).drag(page, from, to, event.steps !== undefined ? { steps: event.steps } : {});
        } catch (err) {
          return inputError(err);
        }
        return { content: `swiped ${event.fromX},${event.fromY} → ${event.toX},${event.toY}` };
      });
    },
  };

  const longPress: BrowserToolSpec = {
    name: "browser_long_press",
    description:
      "Press and hold at a selector's center (or explicit x,y) for durationMs. Opens context menus and long-press actions.",
    parameters: {
      type: "object",
      properties: {
        selector: { type: "string" },
        x: { type: "number" },
        y: { type: "number" },
        durationMs: { type: "integer", description: "Hold duration in ms (default 600)." },
      },
    },
    inputSchema: z
      .object({
        selector: z.string().min(1).optional(),
        x: z.number().optional(),
        y: z.number().optional(),
        durationMs: z.number().int().positive().optional(),
      })
      .refine((value) => value.selector !== undefined || (value.x !== undefined && value.y !== undefined), {
        message: "provide selector or x and y",
      }),
    async execute(input, ctx) {
      const selector: string | undefined = input.selector;
      return withSession(deps, ctx, async (_session, page) => {
        let x: number = input.x;
        let y: number = input.y;
        if (selector !== undefined) {
          const box = await page.locator(selector).first().boundingBox();
          if (box === null) return { content: notFound(selector) };
          x = box.x + box.width / 2;
          y = box.y + box.height / 2;
        }
        try {
          const point = await clampToViewport(page, x, y);
          await humanFor(deps).longPress(page, point, input.durationMs ?? 600);
        } catch (err) {
          return inputError(err);
        }
        return { content: `long-pressed ${selector ?? `${x},${y}`}` };
      });
    },
  };

  const drag: BrowserToolSpec = {
    name: "browser_drag",
    description: "Drag from one element/selector to another (HTML5 drag-and-drop and mouse-drag UIs).",
    parameters: {
      type: "object",
      properties: {
        from: { type: "string", description: "CSS selector to drag from." },
        to: { type: "string", description: "CSS selector to drop onto." },
        steps: { type: "integer" },
      },
      required: ["from", "to"],
    },
    inputSchema: z.object({ from: z.string().min(1), to: z.string().min(1), steps: z.number().int().positive().optional() }),
    async execute(input, ctx) {
      const from: string = input.from;
      const to: string = input.to;
      const steps: number | undefined = input.steps;
      return withSession(deps, ctx, async (_session, page) => {
        if (!(await requireSelector(page, from))) return { content: notFound(from) };
        if (!(await requireSelector(page, to))) return { content: notFound(to) };
        await page.dragAndDrop(from, to, {
          timeout: CLICK_TIMEOUT_MS,
          ...(steps !== undefined ? { steps } : {}),
        });
        return { content: `dragged ${from} → ${to}` };
      });
    },
  };

  const type: BrowserToolSpec = {
    name: "browser_type",
    description:
      "Type text into an input/textarea/contenteditable, replacing its current value. Set submit:true to press Enter afterward (forms, search boxes).",
    parameters: {
      type: "object",
      properties: {
        selector: { type: "string" },
        text: { type: "string" },
        submit: { type: "boolean", description: "Press Enter after typing." },
      },
      required: ["selector", "text"],
    },
    inputSchema: z.object({ selector: z.string().min(1), text: z.string(), submit: z.boolean().optional() }),
    async execute(input, ctx) {
      const selector: string = input.selector;
      const text: string = input.text;
      const submit: boolean = input.submit === true;
      return withSession(deps, ctx, async (_session, page) => {
        // Spec §8: per-key delays, not a programmatic fill.
        await typeInto(page, humanFor(deps), selector, text);
        if (submit) await page.press(selector, "Enter");
        return { content: `typed ${text.length} chars into ${selector}` };
      });
    },
  };

  const fill: BrowserToolSpec = {
    name: "browser_fill",
    description:
      "Fill several fields in one call. `fields` maps a CSS selector to the text to enter; fields are filled sequentially and each result line names the field.",
    parameters: {
      type: "object",
      properties: {
        fields: {
          type: "object",
          additionalProperties: { type: "string" },
          description: "Map of CSS selector → text.",
        },
      },
      required: ["fields"],
    },
    inputSchema: z.object({ fields: z.record(z.string(), z.string()) }),
    async execute(input, ctx) {
      const fields = input.fields as Record<string, string>;
      return withSession(deps, ctx, async (_session, page) => {
        const lines: string[] = [];
        for (const [selector, text] of Object.entries(fields)) {
          // Dart parity: a missing selector is reported and the batch
          // continues rather than aborting after Playwright's timeout.
          if ((await page.locator(selector).count()) === 0) {
            lines.push(`MISSING ${selector}`);
            continue;
          }
          await typeInto(page, humanFor(deps), selector, text);
          lines.push(`filled ${selector} with ${text.length} chars`);
        }
        return { content: lines.length > 0 ? lines.join("\n") : "no fields to fill" };
      });
    },
  };

  const select: BrowserToolSpec = {
    name: "browser_select",
    description: "Choose an option in a <select> by its value (not its label).",
    parameters: {
      type: "object",
      properties: {
        selector: { type: "string" },
        value: { type: "string" },
      },
      required: ["selector", "value"],
    },
    inputSchema: z.object({ selector: z.string().min(1), value: z.string() }),
    async execute(input, ctx) {
      const selector: string = input.selector;
      const value: string = input.value;
      return withSession(deps, ctx, async (_session, page) => {
        await page.selectOption(selector, value);
        return { content: `selected ${value}` };
      });
    },
  };

  const pressKey: BrowserToolSpec = {
    name: "browser_press_key",
    description:
      "Press a keyboard key on the active page (e.g. Enter, Escape, Tab, ArrowDown, PageDown). Modifier combos like Control+A are accepted.",
    parameters: {
      type: "object",
      properties: { key: { type: "string" } },
      required: ["key"],
    },
    inputSchema: z.object({ key: z.string().min(1) }),
    async execute(input, ctx) {
      const key: string = input.key;
      return withSession(deps, ctx, async (_session, page) => {
        await page.keyboard.press(key);
        return { content: `pressed ${key}` };
      });
    },
  };

  const scroll: BrowserToolSpec = {
    name: "browser_scroll",
    description:
      "Scroll the page (or an element with `selector`) up/down by `amount` pixels, or to the top/bottom. Returns the new scroll position.",
    parameters: {
      type: "object",
      properties: {
        direction: { type: "string", enum: ["up", "down", "top", "bottom"] },
        amount: { type: "integer", description: "Pixels for up/down (default 600)." },
        selector: { type: "string", description: "Scroll this element instead of the window." },
      },
      required: ["direction"],
    },
    inputSchema: z.object({
      direction: z.enum(["up", "down", "top", "bottom"]),
      amount: z.number().int().positive().optional(),
      selector: z.string().min(1).optional(),
    }),
    async execute(input, ctx) {
      const direction: "up" | "down" | "top" | "bottom" = input.direction;
      const amount: number = input.amount ?? 600;
      const selector: string | undefined = input.selector;
      return withSession(deps, ctx, async (_session, page) => {
        const before = selector
          ? await page.evaluate((sel: string) => {
              const doc = (globalThis as {
                document?: { querySelector(selector: string): { scrollTop: number } | null };
              }).document;
              return doc?.querySelector(sel)?.scrollTop ?? -1;
            }, selector)
          : await page.evaluate(() => (globalThis as { window?: { scrollY?: number } }).window?.scrollY ?? 0);
        if (selector !== undefined && before < 0) return { content: notFound(selector) };

        if (selector !== undefined) {
          const result = await page.evaluate(
            ({ sel, dir, px }: { sel: string; dir: string; px: number }) => {
              const doc = (globalThis as {
                document?: {
                  querySelector(selector: string): { scrollTop: number; scrollHeight: number } | null;
                };
              }).document;
              const el = doc?.querySelector(sel);
              if (!el) return -1;
              if (dir === "down") el.scrollTop += px;
              else if (dir === "up") el.scrollTop -= px;
              else if (dir === "top") el.scrollTop = 0;
              else el.scrollTop = el.scrollHeight;
              return el.scrollTop;
            },
            { sel: selector, dir: direction, px: amount },
          );
          const moved = Math.abs(result - before);
          return { content: `scrolled ${direction} ${moved}px\nscrollY: ${result}` };
        }

        if (direction === "top" || direction === "bottom") {
          await page.evaluate((toBottom: boolean) => {
            const win = (globalThis as { window?: { scrollTo(x: number, y: number): void } }).window;
            win?.scrollTo(0, toBottom ? Number.MAX_SAFE_INTEGER : 0);
          }, direction === "bottom");
        } else {
          await page.mouse.wheel(0, direction === "down" ? amount : -amount);
        }
        // The compositor applies wheel deltas on the next frame; wait for two
        // frames so the reported position is the settled one.
        await page.evaluate(
          () =>
            new Promise<void>((resolve) => {
              const win = (globalThis as {
                window?: { requestAnimationFrame(cb: () => void): void };
              }).window;
              if (!win) return resolve();
              win.requestAnimationFrame(() => win.requestAnimationFrame(() => resolve()));
            }),
        );
        const after = await page.evaluate(
          () => (globalThis as { window?: { scrollY?: number } }).window?.scrollY ?? 0,
        );
        const moved = Math.abs(after - before);
        return { content: `scrolled ${direction} ${moved}px\nscrollY: ${after}` };
      });
    },
  };

  const cookies: BrowserToolSpec = {
    name: "browser_cookies",
    description:
      'Read or modify the session cookies. Provide exactly one of: get:"name", set:"name=value; path=/", delete:"name", clear:true. get returns the cookie name with its value redacted; set is bound to the active origin.',
    parameters: {
      type: "object",
      properties: {
        get: { type: "string", description: "Cookie name to read." },
        set: { type: "string", description: "Cookie string: name=value; path=/; domain=…" },
        delete: { type: "string", description: "Cookie name to delete." },
        clear: { type: "boolean", description: "Delete all cookies." },
      },
    },
    inputSchema: z
      .object({
        get: z.string().min(1).optional(),
        set: z.string().min(1).optional(),
        delete: z.string().min(1).optional(),
        clear: z.boolean().optional(),
      })
      .refine(
        (value) =>
          [value.get, value.set, value.delete].filter((item) => item !== undefined).length +
            (value.clear === true ? 1 : 0) ===
          1,
        { message: "provide exactly one of get, set, delete, clear" },
      ),
    async execute(input, ctx) {
      return withSession(deps, ctx, async (session, page) => {
        const context = session.handle.context;
        if (input.clear === true) {
          await context.clearCookies();
          return { content: "all cookies cleared" };
        }

        const all = await context.cookies();
        if (input.get !== undefined) {
          const found = all.find((cookie) => cookie.name === input.get);
          return { content: found ? formatCookieForModel(found.name, found.value) : `no cookie named ${input.get}` };
        }

        const origin = safeOrigin(page.url());
        if (origin === null) {
          return { content: `${TOOL_ERROR_PREFIX}no active http(s) page for cookie operations` };
        }

        if (input.set !== undefined) {
          const parsed = parseSetCookie(input.set);
          if (parsed === null) return { content: `${TOOL_ERROR_PREFIX}invalid cookie: ${input.set}` };
          // Bind the write to the ACTIVE origin: a `domain=` for any other
          // host is cookie tossing from the page the agent is on.
          if (parsed.domain !== undefined && !cookieDomainMatchesOrigin(origin, parsed.domain)) {
            return {
              content: `${TOOL_ERROR_PREFIX}cookie domain ${parsed.domain} does not match the active origin`,
            };
          }
          await context.addCookies([
            { name: parsed.name, value: parsed.value, url: origin + (parsed.path ?? "/") },
          ]);
          return { content: "cookie set" };
        }

        // delete — expire the existing cookie in place; fall back to an
        // expired host-only cookie when it is not present in this context.
        const name = input.delete as string;
        const existing = all.find((cookie) => cookie.name === name);
        if (existing !== undefined) {
          await context.addCookies([
            { name, value: existing.value, domain: existing.domain, path: existing.path, expires: 1 },
          ]);
        } else {
          await context.addCookies([{ name, value: "", url: origin, expires: 1 }]);
        }
        return { content: "cookie deleted" };
      });
    },
  };

  const dialog: BrowserToolSpec = {
    name: "browser_dialog",
    description:
      'Read or resolve the pending JavaScript dialog (alert/confirm/prompt). action:"read" returns "{type}: {message}"; accept/dismiss resolves it, with optional text for prompts.',
    parameters: {
      type: "object",
      properties: {
        action: { type: "string", enum: ["read", "accept", "dismiss"] },
        text: { type: "string", description: "Text to enter for a prompt." },
      },
      required: ["action"],
    },
    inputSchema: z.object({
      action: z.enum(["read", "accept", "dismiss"]),
      text: z.string().optional(),
    }),
    async execute(input, ctx) {
      const action: "read" | "accept" | "dismiss" = input.action;
      const session: SessionBrowser | null = deps.registry.getOwned(ctx.sessionId, ctx.userId);
      const entry = session?.dialogs[0];
      if (entry === undefined) return { content: "no pending dialog" };
      if (action === "read") return { content: `${entry.type}: ${entry.message}` };
      entry.resolve(action, input.text);
      return { content: action === "accept" ? "dialog accepted" : "dialog dismissed" };
    },
  };

  const console: BrowserToolSpec = {
    name: "browser_console",
    description:
      "Read the recent console messages (type + text, last 50) or clear the buffer. Useful for diagnosing script errors on the page.",
    parameters: {
      type: "object",
      properties: { action: { type: "string", enum: ["read", "clear"] } },
      required: ["action"],
    },
    inputSchema: z.object({ action: z.enum(["read", "clear"]) }),
    async execute(input, ctx) {
      const session = deps.registry.getOwned(ctx.sessionId, ctx.userId);
      if (input.action === "clear") {
        if (session) session.console.length = 0;
        return { content: "console cleared" };
      }
      const lines = (session?.console ?? []).slice(-OUTPUT_LINES).map((entry) => `${entry.type} ${entry.text}`);
      return { content: lines.length > 0 ? lines.join("\n") : "no console entries" };
    },
  };

  const network: BrowserToolSpec = {
    name: "browser_network",
    description:
      "List recent network responses/failures (method status url, last 50) or clear the buffer. Use to diagnose failed API calls and assets.",
    parameters: {
      type: "object",
      properties: { action: { type: "string", enum: ["list", "clear"] } },
      required: ["action"],
    },
    inputSchema: z.object({ action: z.enum(["list", "clear"]) }),
    async execute(input, ctx) {
      const session = deps.registry.getOwned(ctx.sessionId, ctx.userId);
      if (input.action === "clear") {
        if (session) session.network.length = 0;
        return { content: "network log cleared" };
      }
      const lines = (session?.network ?? [])
        .slice(-OUTPUT_LINES)
        .map((entry) => `${entry.method} ${entry.status ?? entry.failure ?? "failed"} ${entry.url}`);
      return { content: lines.length > 0 ? lines.join("\n") : "no network entries" };
    },
  };

  const popups: BrowserToolSpec = {
    name: "browser_popups",
    description:
      'List popups the page tried to open, re-open one as a real tab (action:"open", url), or clear the list. Server-side popups are recorded and closed until explicitly opened.',
    parameters: {
      type: "object",
      properties: {
        action: { type: "string", enum: ["list", "open", "clear"] },
        url: { type: "string", description: "URL to open as a tab (required for action:open)." },
      },
      required: ["action"],
    },
    inputSchema: z
      .object({
        action: z.enum(["list", "open", "clear"]),
        url: z.string().min(1).optional(),
      })
      .refine((value) => value.action !== "open" || value.url !== undefined, {
        message: "url is required for action:open",
      }),
    async execute(input, ctx) {
      const session = deps.registry.getOwned(ctx.sessionId, ctx.userId);
      if (input.action === "clear") {
        if (session) session.popups.length = 0;
        return { content: "popups cleared" };
      }
      if (input.action === "list") {
        const lines = (session?.popups ?? []).slice(-OUTPUT_LINES).map((entry, i) => `${i}: ${entry.url}`);
        return { content: lines.length > 0 ? lines.join("\n") : "no popups" };
      }

      const url = input.url as string;
      const refusal = await guardUrl(url, "browser_popups", deps.cfg);
      if (refusal !== null) return { content: refusal };
      return withSession(deps, ctx, async (s) => {
        const page = await s.handle.context.newPage();
        try {
          await page.goto(url, { waitUntil: "domcontentloaded", timeout: 30_000 });
        } catch (err) {
          await page.close().catch(() => {});
          return { content: `${TOOL_ERROR_PREFIX}navigation failed: ${messageOf(err)}` };
        }
        deps.registry.addTabForAgent(ctx.sessionId, page);
        deps.notifyState?.(ctx.sessionId);
        return { content: `opened ${url}` };
      });
    },
  };

  return [
    click,
    doubleClick,
    hover,
    tapAt,
    swipe,
    longPress,
    drag,
    type,
    fill,
    select,
    pressKey,
    scroll,
    cookies,
    dialog,
    console,
    network,
    popups,
  ];
}

export function interactionTools(deps: BrowserToolsDeps): BrowserToolDef[] {
  return interactionSpecs(deps).map((spec) => defineBrowserTool(deps, spec));
}
