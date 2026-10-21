/**
 * Transfers (P6 Task 13; hardened in P3): explicit downloads and workspace
 * uploads through one typed, path-safe API.
 *
 *   - PATHS: every upload source is resolved against the session workspace
 *     jail (`/workspace` in the sandbox) both lexically and via `realpath`, so
 *     `../` and symlinks that point outside are refused (transferPolicy.ts).
 *     Downloads resolve their destination directory the same way, and the
 *     body is written to a fresh temp name then renamed into place, so a
 *     planted symlink is replaced, never followed.
 *   - SIZE: `browser_download` reads with a BOUNDED stream — the declared
 *     Content-Length is checked before any body byte is read, and an
 *     undeclared (chunked) body is aborted as soon as the running count
 *     crosses the cap. Uploads stat the source first. Both default to 50 MB
 *     (`downloadMaxBytes` / `uploadMaxBytes` are test seams; the refusal copy
 *     always states the production policy).
 *   - MIME: downloads must declare an allowed attachment type (images,
 *     documents, text, archives, media — never active content or
 *     executables); uploads are typed by extension against the same policy.
 *   - SSRF: redirects are followed MANUALLY and every hop is re-gated with
 *     `assertPublicHost`, so a 302 to loopback/metadata is never fetched.
 *
 * `browser_download` shares the session's cookie jar (authenticated downloads
 * work without re-login). `browser_upload` hands an absolute, jailed path to
 * Playwright's `setInputFiles`, which fires the page's `change` handler
 * exactly like a user picking the file.
 */

import { rename, rm, stat, writeFile } from "node:fs/promises";
import { basename, join } from "node:path";

import type { BrowserContext } from "playwright-core";
import { z } from "zod";

import type { BrowserEngineConfig } from "../config.js";
import { guardUrl, withSession } from "../sessionOps.js";
import { SsrfError, assertPublicHost, navigableUrlReason } from "../url.js";
import {
  DOWNLOAD_MAX_BYTES,
  TRANSFER_MIME_ALLOWLIST,
  UPLOAD_MAX_BYTES,
  isAllowedTransferFilename,
  isAllowedTransferMime,
  mimeTypeForFilename,
  normalizeMimeType,
  resolveWorkspaceDir,
  resolveWorkspaceEntry,
  sanitizeFilename,
  type WorkspacePathReason,
} from "./transferPolicy.js";
import {
  TOOL_ERROR_PREFIX,
  artifactSessionId,
  defineBrowserTool,
  messageOf,
  randomSuffix,
  type BrowserToolDef,
  type BrowserToolSpec,
  type BrowserToolsDeps,
} from "./types.js";

// The typed transfer policy is part of the package surface (index.ts exports
// this module), so callers and tests share one allowlist / jail implementation.
export {
  DOWNLOAD_MAX_BYTES,
  TRANSFER_MIME_ALLOWLIST,
  UPLOAD_MAX_BYTES,
  isAllowedTransferFilename,
  isAllowedTransferMime,
  mimeTypeForFilename,
  normalizeMimeType,
  resolveWorkspaceDir,
  resolveWorkspaceEntry,
  sanitizeFilename,
};
export type { WorkspacePathReason, WorkspacePathResult } from "./transferPolicy.js";

/** Fetch timeout for explicit downloads. */
const DOWNLOAD_TIMEOUT_MS = 30_000;

/** Redirect hops an explicit download may follow before refusing. */
const DOWNLOAD_MAX_REDIRECTS = 5;

/** Status codes that start a redirect chain (fetch `redirect: "manual"`). */
const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);

/** Model-facing copy for a refused upload path. */
function uploadPathRefusal(reason: WorkspacePathReason, relPath: string): string {
  switch (reason) {
    case "escape":
      return "Upload refused: path escapes the session workspace.";
    case "invalid":
      return `${TOOL_ERROR_PREFIX}invalid path: ${relPath}`;
    case "not-found":
      return `${TOOL_ERROR_PREFIX}file not found: ${relPath}`;
  }
}

/** Extension shown in the MIME refusal (never a path). */
function extensionOf(filename: string): string {
  const dot = filename.lastIndexOf(".");
  return dot > 0 ? filename.slice(dot).toLowerCase() : "no extension";
}

interface BoundedResponse {
  status: number;
  ok: boolean;
  /** Normalized MIME (parameters stripped); octet-stream when absent. */
  contentType: string;
  body: Buffer | null;
  tooLarge: boolean;
  /** Non-null when the declared type is outside TRANSFER_MIME_ALLOWLIST. */
  refusedMime: string | null;
  /** The last URL in the redirect chain (the one whose body was read). */
  finalUrl: string;
}

/** Read at most `maxBytes` from an already-gated response. */
async function readBoundedBody(
  response: Response,
  base: { status: number; ok: boolean; contentType: string },
  maxBytes: number,
  controller: AbortController,
): Promise<BoundedResponse> {
  const declared = Number(response.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) {
    controller.abort();
    return { ...base, body: null, tooLarge: true, refusedMime: null, finalUrl: response.url };
  }

  if (response.body === null) {
    return { ...base, body: Buffer.alloc(0), tooLarge: false, refusedMime: null, finalUrl: response.url };
  }

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
        return { ...base, body: null, tooLarge: true, refusedMime: null, finalUrl: response.url };
      }
      chunks.push(value);
    }
  } catch (err) {
    controller.abort();
    throw new Error(`download failed: ${messageOf(err)}`);
  }

  return {
    ...base,
    body: Buffer.concat(chunks.map((chunk) => Buffer.from(chunk))),
    tooLarge: false,
    refusedMime: null,
    finalUrl: response.url,
  };
}

/**
 * GET `url` with the context's cookies, reading at most `maxBytes` of body.
 * Redirects are followed MANUALLY so every hop is re-gated with
 * `assertPublicHost`: `redirect: "follow"` would validate only the first URL
 * and happily fetch a 302 to loopback/the metadata service. Cookies are
 * recomputed per hop, so the original site's cookies never follow a redirect
 * to a different host. Disallowed content types are refused before the body
 * is read; oversized bodies are aborted at the cap.
 */
async function boundedGet(
  context: BrowserContext,
  url: string,
  maxBytes: number,
  cfg: BrowserEngineConfig,
): Promise<BoundedResponse> {
  let current = url;
  for (let hop = 0; hop <= DOWNLOAD_MAX_REDIRECTS; hop++) {
    // Scheme + SSRF gate for THIS hop (including the first, so a caller that
    // bypassed guardUrl still cannot reach a private address).
    const schemeReason = navigableUrlReason(current, "browser_download");
    if (schemeReason !== null) throw new SsrfError(schemeReason);
    await assertPublicHost(current, cfg);

    const cookies = await context.cookies(current);
    const cookieHeader = cookies.map((cookie) => `${cookie.name}=${cookie.value}`).join("; ");
    const controller = new AbortController();

    let response: Response;
    try {
      response = await fetch(current, {
        headers: cookieHeader !== "" ? { cookie: cookieHeader } : {},
        redirect: "manual",
        signal: AbortSignal.any([controller.signal, AbortSignal.timeout(DOWNLOAD_TIMEOUT_MS)]),
      });
    } catch (err) {
      throw new Error(`download failed: ${messageOf(err)}`);
    }

    const base = {
      status: response.status,
      ok: response.ok,
      contentType: normalizeMimeType(response.headers.get("content-type")),
    };

    if (REDIRECT_STATUSES.has(response.status)) {
      const location = response.headers.get("location");
      controller.abort();
      await response.body?.cancel().catch(() => {});
      if (location === null || location === "") {
        return { ...base, body: null, tooLarge: false, refusedMime: null, finalUrl: current };
      }
      let next: string;
      try {
        next = new URL(location, current).toString();
      } catch {
        throw new Error(`download failed: invalid redirect location from ${current}`);
      }
      current = next;
      continue;
    }

    if (!response.ok) {
      return { ...base, body: null, tooLarge: false, refusedMime: null, finalUrl: current };
    }

    if (!isAllowedTransferMime(base.contentType)) {
      controller.abort();
      await response.body?.cancel().catch(() => {});
      return { ...base, body: null, tooLarge: false, refusedMime: base.contentType, finalUrl: current };
    }

    return readBoundedBody(response, base, maxBytes, controller);
  }
  throw new SsrfError(`download refused: more than ${DOWNLOAD_MAX_REDIRECTS} redirects`);
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

/** Types for the two transfer tools (also usable by callers of this package). */
export const browserDownloadInputSchema = z.object({
  url: z.string().min(1),
  filename: z.string().min(1).optional(),
});
export type BrowserDownloadInput = z.infer<typeof browserDownloadInputSchema>;

export const browserUploadInputSchema = z
  .object({
    selector: z.string().min(1),
    path: z.string().min(1).optional(),
    artifactId: z.string().min(1).optional(),
  })
  .strict()
  .superRefine((v, ctx) => {
    if ((v.path === undefined) === (v.artifactId === undefined)) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: "exactly one of path or artifactId is required",
      });
    }
  });
export type BrowserUploadInput = z.infer<typeof browserUploadInputSchema>;

function transferSpecs(deps: BrowserToolsDeps): BrowserToolSpec[] {
  const download: BrowserToolSpec = {
    name: "browser_download",
    description:
      "Download a URL to the session workspace (browser/downloads/) using the session's cookies. Returns a workspace-relative artifact reference. Files over 50 MB and non-attachment content types (active content, executables) are refused.",
    parameters: {
      type: "object",
      properties: {
        url: { type: "string", description: "Absolute http(s) URL to download." },
        filename: { type: "string", description: "Optional plain filename (no path components)." },
      },
      required: ["url"],
    },
    inputSchema: browserDownloadInputSchema,
    async execute(input, ctx) {
      const url: string = input.url;
      const refusal = await guardUrl(url, "browser_download", deps.cfg);
      if (refusal !== null) return { content: refusal };

      return withSession(deps, ctx, async (session) => {
        const limit = deps.downloadMaxBytes ?? DOWNLOAD_MAX_BYTES;
        let response: BoundedResponse;
        try {
          response = await boundedGet(session.handle.context, url, limit, deps.cfg);
        } catch (err) {
          if (err instanceof SsrfError) return { content: `Download refused: ${err.message}` };
          throw err;
        }
        if (!response.ok) {
          return { content: `${TOOL_ERROR_PREFIX}download failed: HTTP ${response.status} ${url}` };
        }
        if (response.refusedMime !== null) {
          return {
            content: `Download refused: content type ${response.refusedMime} is not allowed.`,
          };
        }
        if (response.tooLarge || response.body === null) {
          return { content: "Download refused: file exceeds the 50 MB limit." };
        }
        const body = response.body;

        const requested = input.filename as string | undefined;
        const name =
          requested !== undefined
            ? sanitizeFilename(requested)
            : (defaultFilename(response.finalUrl !== "" ? response.finalUrl : url) ??
              `download-${deps.now?.() ?? Date.now()}`);
        if (name === null) return { content: "Download refused: invalid filename." };

        const root = await deps.workspaceDir(ctx.userId, artifactSessionId(ctx));
        const relDir = "browser/downloads";
        const dir = await resolveWorkspaceDir(root, relDir);
        if (dir === null) {
          return { content: "Download refused: destination escapes the session workspace." };
        }

        // Write-then-rename: `rename` REPLACES a pre-existing symlink rather
        // than following it outside the jail.
        const dest = join(dir, name);
        const temp = join(dir, `.part-${randomSuffix()}`);
        try {
          await writeFile(temp, body, { flag: "wx", mode: 0o600 });
          await rename(temp, dest);
        } catch (err) {
          await rm(temp, { force: true }).catch(() => {});
          throw err;
        }

        // Wave 6 W4: mirror the file into the account Artifact Vault. The
        // workspace copy is authoritative; a vault failure never fails the
        // download (the model still gets the bytes/path).
        let vaulted = false;
        if (deps.artifactVault !== undefined) {
          try {
            const rec = await deps.artifactVault.registerFromWorkspace({
              userId: ctx.userId,
              sessionId: artifactSessionId(ctx),
              path: `${relDir}/${name}`,
              mimeType: response.contentType,
            });
            vaulted = rec !== null;
          } catch (err) {
            deps.log?.("browser_download: artifact vault registration failed", err);
          }
        }

        return {
          content: `saved ${body.length} bytes to ${relDir}/${name}${
            vaulted ? " (also in the Artifact Vault)" : ""
          }`,
          artifacts: [
            {
              kind: "download",
              path: `${relDir}/${name}`,
              mimeType: response.contentType,
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
      "Upload a file to a file input matching a CSS selector. Source is either a workspace-relative path or an Artifact Vault id (artifactId). Paths outside the workspace, files over 50 MB, and file types outside the attachment allowlist (images, documents, text, ZIP, audio/video) are refused.",
    parameters: {
      type: "object",
      properties: {
        selector: { type: "string", description: "CSS selector of the <input type=file>." },
        path: { type: "string", description: "Workspace-relative path of the file to upload." },
        artifactId: {
          type: "string",
          description: "Artifact Vault id to upload instead of a workspace path.",
        },
      },
      required: ["selector"],
    },
    inputSchema: browserUploadInputSchema,
    async execute(input, ctx) {
      const root = await deps.workspaceDir(ctx.userId, artifactSessionId(ctx));
      let relPath: string;
      if (input.artifactId !== undefined) {
        if (deps.artifactVault === undefined) {
          return { content: `${TOOL_ERROR_PREFIX}the Artifact Vault bridge is not configured` };
        }
        const fetched = await deps.artifactVault.fetchToWorkspace({
          userId: ctx.userId,
          sessionId: artifactSessionId(ctx),
          artifactId: input.artifactId,
          destDir: "browser/uploads",
        });
        if (fetched === null) {
          return { content: `${TOOL_ERROR_PREFIX}artifact not found: ${input.artifactId}` };
        }
        relPath = fetched.path;
      } else {
        relPath = input.path as string;
      }

      // Review Focus #4: lexical + realpath jail check BEFORE any file work —
      // this also validates a vault port's returned path.
      const resolved = await resolveWorkspaceEntry(root, relPath);
      if (!resolved.ok) return { content: uploadPathRefusal(resolved.reason, relPath) };

      let info;
      try {
        info = await stat(resolved.abs);
      } catch {
        return { content: `${TOOL_ERROR_PREFIX}file not found: ${relPath}` };
      }
      if (!info.isFile()) {
        return { content: `${TOOL_ERROR_PREFIX}file not found: ${relPath}` };
      }

      if (info.size > (deps.uploadMaxBytes ?? UPLOAD_MAX_BYTES)) {
        return { content: "Upload refused: file exceeds the 50 MB limit." };
      }

      const name = basename(resolved.abs);
      if (mimeTypeForFilename(name) === null) {
        return {
          content: `Upload refused: file type not allowed (${extensionOf(name)}).`,
        };
      }

      return withSession(deps, ctx, async (_session, page) => {
        await page.setInputFiles(input.selector, resolved.abs);
        return { content: `uploaded ${relPath} to ${input.selector}` };
      });
    },
  };

  return [download, upload];
}

export function transferTools(deps: BrowserToolsDeps): BrowserToolDef[] {
  return transferSpecs(deps).map((spec) => defineBrowserTool(deps, spec));
}
