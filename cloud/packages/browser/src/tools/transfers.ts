/**
 * Transfers (P6 Task 13): explicit downloads and workspace uploads.
 *
 * `browser_download` uses `context.request` so the fetch shares the session's
 * cookie jar (authenticated downloads work without re-login). The byte cap is
 * checked BEFORE writing; `BrowserToolsDeps.downloadMaxBytes` is a test seam
 * (production defaults to 50 MB). Filenames are single-component only — a
 * server-supplied basename or a caller-supplied `../` can never escape
 * `browser/downloads/`.
 *
 * `browser_upload` resolves the caller's path against the P2 workspace jail
 * and refuses anything outside it (Review Focus #4), then hands the absolute
 * path to Playwright's `setInputFiles` (which fires the page's `change`
 * handler exactly like a user picking the file).
 */

import { mkdir, stat, writeFile } from "node:fs/promises";
import { isAbsolute, join, relative, resolve } from "node:path";

import { z } from "zod";

import { guardUrl, withSession } from "../sessionOps.js";
import { sanitizeFilename } from "./downloadWiring.js";
import {
  TOOL_ERROR_PREFIX,
  defineBrowserTool,
  type BrowserToolDef,
  type BrowserToolSpec,
  type BrowserToolsDeps,
} from "./types.js";

/** Hard download ceiling (Dart parity). */
export const DOWNLOAD_MAX_BYTES = 50 * 1024 * 1024;

/** Default filename from a URL's last path segment, or null when absent/invalid. */
function defaultFilename(url: string): string | null {
  try {
    const pathname = new URL(url).pathname;
    const last = pathname.split("/").filter((part) => part !== "").pop();
    if (last === undefined) return null;
    return sanitizeFilename(decodeURIComponent(last));
  } catch {
    return null;
  }
}

function transferSpecs(deps: BrowserToolsDeps): BrowserToolSpec[] {
  const download: BrowserToolSpec = {
    name: "browser_download",
    description:
      "Download a URL to the session workspace (browser/downloads/) using the session's cookies. Returns a workspace-relative artifact reference. Files over 50 MB are refused.",
    parameters: {
      type: "object",
      properties: {
        url: { type: "string", description: "Absolute http(s) URL to download." },
        filename: { type: "string", description: "Optional plain filename (no path components)." },
      },
      required: ["url"],
    },
    inputSchema: z.object({ url: z.string().min(1), filename: z.string().min(1).optional() }),
    async execute(input, ctx) {
      const url: string = input.url;
      const refusal = await guardUrl(url, "browser_download", deps.cfg);
      if (refusal !== null) return { content: refusal };

      return withSession(deps, ctx, async (session) => {
        const response = await session.handle.context.request.get(url, { timeout: 30_000 });
        if (!response.ok()) {
          return { content: `${TOOL_ERROR_PREFIX}download failed: HTTP ${response.status()} ${url}` };
        }

        const body = await response.body();
        const limit = deps.downloadMaxBytes ?? DOWNLOAD_MAX_BYTES;
        if (body.length > limit) {
          return { content: "Download refused: file exceeds the 50 MB limit." };
        }

        const requested = input.filename as string | undefined;
        const name =
          requested !== undefined
            ? sanitizeFilename(requested)
            : (defaultFilename(url) ?? `download-${deps.now?.() ?? Date.now()}`);
        if (name === null) return { content: "Download refused: invalid filename." };

        const root = await deps.workspaceDir(ctx.userId, ctx.sessionId);
        const relDir = "browser/downloads";
        const dir = join(root, relDir);
        await mkdir(dir, { recursive: true });
        await writeFile(join(dir, name), body);

        const headers = response.headers();
        return {
          content: `saved ${body.length} bytes to ${relDir}/${name}`,
          artifacts: [
            {
              kind: "download",
              path: `${relDir}/${name}`,
              mimeType: headers["content-type"] ?? "application/octet-stream",
              bytes: body.length,
            },
          ],
        };
      });
    },
  };

  const upload: BrowserToolSpec = {
    name: "browser_upload",
    description:
      "Upload a file from the session workspace to a file input matching a CSS selector. The path is workspace-relative; paths outside the workspace are refused.",
    parameters: {
      type: "object",
      properties: {
        selector: { type: "string", description: "CSS selector of the <input type=file>." },
        path: { type: "string", description: "Workspace-relative path of the file to upload." },
      },
      required: ["selector", "path"],
    },
    inputSchema: z.object({ selector: z.string().min(1), path: z.string().min(1) }),
    async execute(input, ctx) {
      const root = await deps.workspaceDir(ctx.userId, ctx.sessionId);
      const abs = resolve(root, input.path);
      const rel = relative(root, abs);
      // Review Focus #4: the jail check is path-level, before any file work.
      if (rel.startsWith("..") || isAbsolute(rel)) {
        return { content: "Upload refused: path escapes the session workspace." };
      }

      let info;
      try {
        info = await stat(abs);
      } catch {
        return { content: `${TOOL_ERROR_PREFIX}file not found: ${input.path}` };
      }
      if (!info.isFile()) {
        return { content: `${TOOL_ERROR_PREFIX}file not found: ${input.path}` };
      }

      return withSession(deps, ctx, async (_session, page) => {
        await page.setInputFiles(input.selector, abs);
        return { content: `uploaded ${input.path} to ${input.selector}` };
      });
    },
  };

  return [download, upload];
}

export function transferTools(deps: BrowserToolsDeps): BrowserToolDef[] {
  return transferSpecs(deps).map((spec) => defineBrowserTool(deps, spec));
}
