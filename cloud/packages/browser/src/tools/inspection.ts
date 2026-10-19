/**
 * Page inspection tools (P6 Task 12): read, outline, accessibility snapshot,
 * find, wait_for, evaluate, screenshot.
 *
 * Readability extraction is the primary reader (`browser_read`, and the text
 * body of `browser_open`/`browser_navigate`); when Readability finds no
 * article the tools fall back to `document.body.innerText` so script-rendered
 * pages are still readable.
 *
 * Screenshots are written under the session workspace and returned as
 * workspace-relative artifact refs — the P3 loop attaches them to the next
 * model request, and P7's artifact pipeline resolves the same path.
 */

import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

import { z } from "zod";

import { captureScreenshot } from "../screencast.js";
import { extractReadable } from "../staticExtract.js";
import { withSession } from "../sessionOps.js";
import {
  READ_MARKDOWN_CAP,
  SNAPSHOT_CAP,
  TEXT_OUTPUT_CAP,
  TOOL_ERROR_PREFIX,
  artifactSessionId,
  capText,
  defineBrowserTool,
  pageInnerText,
  randomSuffix,
  type BrowserToolDef,
  type BrowserToolSpec,
  type BrowserToolsDeps,
} from "./types.js";

const EMPTY_PARAMETERS = { type: "object", properties: {} };

function isTimeout(err: unknown): boolean {
  return err instanceof Error && (err.name === "TimeoutError" || /timeout/i.test(err.name));
}

function inspectionSpecs(deps: BrowserToolsDeps): BrowserToolSpec[] {
  const read: BrowserToolSpec = {
    name: "browser_read",
    description:
      "Read the current page content as clean markdown text (readability extraction with a plain-text fallback). Use after navigate/click to see what the page shows now.",
    parameters: EMPTY_PARAMETERS,
    inputSchema: z.object({}),
    async execute(_input, ctx) {
      return withSession(deps, ctx, async (_session, page) => {
        const url = page.url();
        const extracted = extractReadable(await page.content(), url);
        const markdown = extracted?.markdown ?? "";
        const text = markdown.trim() !== "" ? markdown : await pageInnerText(page);
        if (text.trim() === "") {
          return { content: "The page has no readable text content." };
        }
        return { content: capText(text, READ_MARKDOWN_CAP) };
      });
    },
  };

  const outline: BrowserToolSpec = {
    name: "browser_outline",
    description:
      "Cheap text skeleton of the page — headings, links, buttons, and form fields with their labels. Use browser_screenshot when you need to actually see the page (layout, visual login state).",
    parameters: EMPTY_PARAMETERS,
    inputSchema: z.object({}),
    async execute(_input, ctx) {
      return withSession(deps, ctx, async (_session, page) => {
        const lines = await page.evaluate(() => {
          const doc = (globalThis as any).document;
          const out: string[] = [];
          const clean = (value: string | null | undefined): string =>
            (value ?? "").replace(/\s+/g, " ").trim();

          for (const el of Array.from(doc.querySelectorAll("h1,h2,h3,h4,h5,h6")) as any[]) {
            const text = clean(el.textContent).slice(0, 120);
            if (text) out.push(`${el.tagName.toLowerCase()}: ${text}`);
          }

          let links = 0;
          for (const el of Array.from(doc.querySelectorAll("a[href]")) as any[]) {
            if (links >= 100) break;
            const text = clean(el.textContent).slice(0, 80);
            if (!text) continue;
            out.push(`link: ${text} → ${el.getAttribute("href") ?? ""}`);
            links++;
          }

          for (const el of Array.from(doc.querySelectorAll('button,[role="button"]')) as any[]) {
            const text = clean(el.textContent || el.getAttribute("aria-label")).slice(0, 80);
            if (text) out.push(`button: ${text}`);
          }

          for (const el of Array.from(doc.querySelectorAll("input,select,textarea")) as any[]) {
            const parts = [el.tagName.toLowerCase()];
            if (el.id) parts.push(`id=${el.id}`);
            if (el.name) parts.push(`name=${el.name}`);
            if (el.type) parts.push(`type=${el.type}`);
            if (el.placeholder) parts.push(`placeholder=${el.placeholder}`);
            out.push(`field: ${parts.join(" ")}`);
          }
          return out;
        });
        return { content: `Page outline:\n${lines.join("\n")}` };
      });
    },
  };

  const snapshot: BrowserToolSpec = {
    name: "browser_snapshot",
    description:
      "Return an accessibility-style snapshot of the page: interactive elements (links, buttons, inputs) with their roles and accessible names. Use this to decide what to target instead of guessing selectors.",
    parameters: EMPTY_PARAMETERS,
    inputSchema: z.object({}),
    async execute(_input, ctx) {
      return withSession(deps, ctx, async (_session, page) => {
        const tree = await page.locator("body").ariaSnapshot();
        return { content: capText(tree, SNAPSHOT_CAP) };
      });
    },
  };

  const find: BrowserToolSpec = {
    name: "browser_find",
    description:
      "Count occurrences of text on the page and report the first match's surrounding snippet.",
    parameters: {
      type: "object",
      properties: { text: { type: "string", description: "Text to search for (case-insensitive)." } },
      required: ["text"],
    },
    inputSchema: z.object({ text: z.string().min(1) }),
    async execute(input, ctx) {
      const text: string = input.text;
      return withSession(deps, ctx, async (_session, page) => {
        const result = await page.evaluate((needle: string) => {
          const doc = (globalThis as any).document;
          const body: string = doc?.body ? String(doc.body.innerText ?? "") : "";
          const lower = body.toLowerCase();
          const target = needle.toLowerCase();
          let count = 0;
          let idx = 0;
          while ((idx = lower.indexOf(target, idx)) !== -1) {
            count++;
            idx += target.length || 1;
          }
          if (count === 0) return `0 matches for "${needle}"`;
          const at = lower.indexOf(target);
          const from = Math.max(0, at - 80);
          const snippet = body
            .substring(from, Math.min(body.length, at + target.length + 80))
            .replace(/\s+/g, " ");
          return `${count} match(es) for "${needle}" — first: …${snippet}…`;
        }, text);
        return { content: String(result) };
      });
    },
  };

  const waitFor: BrowserToolSpec = {
    name: "browser_wait_for",
    description:
      'Wait until text appears on the page or an element matches a state (visible|hidden|text, or timeout ms elapses). Use after an action that loads content asynchronously. Returns the matched condition or "timeout".',
    parameters: {
      type: "object",
      properties: {
        text: { type: "string" },
        selector: { type: "string" },
        state: { type: "string", enum: ["visible", "hidden", "text"] },
        timeoutMs: { type: "integer" },
      },
    },
    inputSchema: z
      .object({
        text: z.string().optional(),
        selector: z.string().optional(),
        state: z.enum(["visible", "hidden", "text"]).optional(),
        // Non-positive values are accepted but clamped to the default below:
        // Playwright treats `timeout: 0` as "disable the timeout", which would
        // hang the tool (and the run awaiting it) forever.
        timeoutMs: z.number().int().optional(),
      })
      .refine((value) => value.text !== undefined || value.selector !== undefined, {
        message: "provide text or selector",
      }),
    async execute(input, ctx) {
      const selector: string | undefined = input.selector?.trim() || undefined;
      const text: string = input.text ?? "";
      const state: "visible" | "hidden" | "text" =
        input.state ?? (selector !== undefined && input.text === undefined ? "visible" : "text");
      const requested = input.timeoutMs;
      // NEVER pass 0/negative through: Playwright's 0 disables the timeout.
      // Non-positive ⇒ the 10 s default; otherwise clamp to the 30 s cap.
      const timeout =
        requested === undefined || requested <= 0
          ? 10_000
          : Math.min(30_000, Math.max(1, Math.round(requested)));

      return withSession(deps, ctx, async (_session, page) => {
        try {
          if (selector !== undefined && state !== "text") {
            await page.locator(selector).waitFor({ state, timeout });
            return { content: `matched: ${selector} ${state}` };
          }
          if (selector !== undefined) {
            await page.waitForFunction(
              ({ sel, needle }: { sel: string; needle: string }) => {
                const doc = (globalThis as any).document;
                const el = doc?.querySelector(sel);
                if (!el) return false;
                return String(el.innerText ?? el.textContent ?? "").includes(needle);
              },
              { sel: selector, needle: text },
              { timeout },
            );
            return { content: `matched: ${selector} text` };
          }
          await page.waitForFunction(
            (needle: string) => {
              const doc = (globalThis as any).document;
              return doc?.body ? String(doc.body.innerText ?? "").includes(needle) : false;
            },
            text,
            { timeout },
          );
          return { content: `matched: text "${text}"` };
        } catch (err) {
          // A timeout is a RESULT for the model (Dart parity), never an error.
          if (isTimeout(err)) return { content: "timeout" };
          throw err;
        }
      });
    },
  };

  const evaluate: BrowserToolSpec = {
    name: "browser_evaluate",
    description:
      "Run JavaScript on the current page and return the JSON result. Use for reading values, extracting data, or interacting with the page.",
    parameters: {
      type: "object",
      properties: { expression: { type: "string" } },
      required: ["expression"],
    },
    inputSchema: z.object({ expression: z.string().min(1) }),
    async execute(input, ctx) {
      const expression: string = input.expression;
      return withSession(deps, ctx, async (_session, page) => {
        // Evaluation errors propagate to the execute wrapper (error: …).
        const result = await page.evaluate(expression, undefined);
        const json = JSON.stringify(result);
        return { content: capText(json === undefined ? "undefined" : json, TEXT_OUTPUT_CAP) };
      });
    },
  };

  const screenshot: BrowserToolSpec = {
    name: "browser_screenshot",
    description:
      "Capture the real pixels of the active tab and attach them to the next model request. Use this to visually verify layout, a chart, or whether a login/redirect happened. browser_read/browser_outline are cheaper — use this when the answer is visual.",
    parameters: {
      type: "object",
      properties: {
        type: {
          type: "string",
          enum: ["jpeg", "png"],
          description: "Image format (default jpeg).",
        },
        quality: {
          type: "integer",
          description: "JPEG quality 1-100 (ignored for png; default 70).",
        },
      },
    },
    inputSchema: z.object({
      type: z.enum(["jpeg", "png"]).optional(),
      quality: z.number().int().min(1).max(100).optional(),
    }),
    async execute(input, ctx) {
      const type: "jpeg" | "png" = input.type ?? "jpeg";
      const quality: number | undefined = input.quality;
      return withSession(deps, ctx, async (_session, page) => {
        const bytes = await captureScreenshot(page, { type, quality });
        const root = await deps.workspaceDir(ctx.userId, artifactSessionId(ctx));
        const relDir = "browser/screenshots";
        const dir = join(root, relDir);
        await mkdir(dir, { recursive: true });

        const stamp = new Date(deps.now?.() ?? Date.now()).toISOString().replace(/[:.]/g, "-");
        const name = `${stamp}-${randomSuffix()}.${type === "png" ? "png" : "jpg"}`;
        await writeFile(join(dir, name), bytes);

        const relPath = `${relDir}/${name}`;
        const kb = (bytes.length / 1024).toFixed(1);
        return {
          content: `screenshot saved: ${relPath} (${kb} KB)`,
          artifacts: [
            {
              kind: "screenshot",
              path: relPath,
              mimeType: type === "png" ? "image/png" : "image/jpeg",
              bytes: bytes.length,
            },
          ],
        };
      });
    },
  };

  return [read, outline, snapshot, find, waitFor, evaluate, screenshot];
}

export function inspectionTools(deps: BrowserToolsDeps): BrowserToolDef[] {
  return inspectionSpecs(deps).map((spec) => defineBrowserTool(deps, spec));
}
