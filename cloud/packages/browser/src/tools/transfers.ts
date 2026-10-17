/**
 * Transfers (P6 Task 13): explicit downloads and workspace uploads.
 *
 * `browser_download` shares the session's cookie jar (authenticated downloads
 * work without re-login) and reads the body with a BOUNDED stream: the
 * declared Content-Length is checked before any body byte is read, and an
 * undeclared (chunked) body is aborted as soon as the running count crosses
 * the cap. Nothing past the cap is ever buffered — a multi-GB URL cannot OOM
 * the worker. `BrowserToolsDeps.downloadMaxBytes` is a test seam (production
 * defaults to 50 MB). Filenames are single-component only — a server-supplied
 * basename or a caller-supplied `../` can never escape `browser/downloads/`.
 *
 * `browser_upload` resolves the caller's path against the P2 workspace jail
 * and refuses anything outside it (Review Focus #4), then hands the absolute
 * path to Playwright's `setInputFiles` (which fires the page's `change`
 * handler exactly like a user picking the file).
 */

import { mkdir, stat, writeFile } from "node:fs/promises";
import { isAbsolute, join, relative, resolve, sep } from "node:path";

import type { BrowserContext } from "playwright-core";
import { z } from "zod";

import { guardUrl, withSession } from "../sessionOps.js";
import { DOWNLOAD_MAX_BYTES, sanitizeFilename } from "./downloadWiring.js";
import {
  TOOL_ERROR_PREFIX,
  defineBrowserTool,
  messageOf,
  type BrowserToolDef,
  type BrowserToolSpec,
  type BrowserToolsDeps,
} from "./types.js";

export { DOWNLOAD_MAX_BYTES };

/** Fetch timeout for explicit downloads. */
const DOWNLOAD_TIMEOUT_MS = 30_000;

interface BoundedResponse {
  status: number;
  ok: boolean;
  contentType: string | null;
  body: Buffer | null;
  tooLarge: boolean;
}

/**
 * GET `url` with the context's cookies, reading at most `maxBytes` of body.
 * `tooLarge` short-circuits before the body is touched when Content-Length
 * declares more than the cap, and aborts mid-stream when it does not.
 */
async function boundedGet(
  context: BrowserContext,
  url: string,
  maxBytes: number,
): Promise<BoundedResponse> {
  const cookies = await context.cookies(url);
  const cookieHeader = cookies.map((cookie) => `${cookie.name}=${cookie.value}`).join("; ");
  const controller = new AbortController();

  let response: Response;
  try {
    response = await fetch(url, {
      headers: cookieHeader !== "" ? { cookie: cookieHeader } : {},
      // Redirects keep the pre-existing T12 behavior (guardUrl gates the
      // initial URL only; Task 16's nftables egress rules are the backstop).
      redirect: "follow",
      signal: AbortSignal.any([controller.signal, AbortSignal.timeout(DOWNLOAD_TIMEOUT_MS)]),
    });
  } catch (err) {
    throw new Error(`download failed: ${messageOf(err)}`);
  }

  const base = {
    status: response.status,
    ok: response.ok,
    contentType: response.headers.get("content-type"),
  };
  if (!response.ok) return { ...base, body: null, tooLarge: false };

  const declared = Number(response.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) {
    controller.abort();
    return { ...base, body: null, tooLarge: true };
  }

  if (response.body === null) return { ...base, body: Buffer.alloc(0), tooLarge: false };

  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        // Stop the transfer at the boundary — never buffer the remainder.
        controller.abort();
        await reader.cancel().catch(() => {});
        return { ...base, body: null, tooLarge: true };
      }
      chunks.push(value);
    }
  } catch (err) {
    controller.abort();
    throw new Error(`download failed: ${messageOf(err)}`);
  }

  return { ...base, body: Buffer.concat(chunks.map((chunk) => Buffer.from(chunk))), tooLarge: false };
}

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
        const limit = deps.downloadMaxBytes ?? DOWNLOAD_MAX_BYTES;
        const response = await boundedGet(session.handle.context, url, limit);
        if (!response.ok) {
          return { content: `${TOOL_ERROR_PREFIX}download failed: HTTP ${response.status} ${url}` };
        }
        if (response.tooLarge || response.body === null) {
          return { content: "Download refused: file exceeds the 50 MB limit." };
        }
        const body = response.body;

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

        return {
          content: `saved ${body.length} bytes to ${relDir}/${name}`,
          artifacts: [
            {
              kind: "download",
              path: `${relDir}/${name}`,
              mimeType: response.contentType ?? "application/octet-stream",
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
      if (rel === ".." || rel.startsWith(".." + sep) || isAbsolute(rel)) {
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
