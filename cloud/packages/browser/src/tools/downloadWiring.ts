/**
 * Page-initiated download wiring (P6 Task 13, transfers half).
 *
 * `browser_download` covers explicit URL fetches; pages also start downloads
 * themselves (a link to a PDF, a generated CSV). Those are auto-saved to the
 * same `browser/downloads/` directory and recorded in the session's network
 * ring so the model can find them without an extra round-trip.
 *
 * Hardened (P3):
 *   - a page download is held to the SAME extension allowlist as the upload
 *     path (`isAllowedTransferFilename`), so a hostile page cannot drop
 *     `.html`, `.svg` or `.exe` into the workspace;
 *   - the destination chat is keyed by the PAGE that triggered the download,
 *     not by "the latest tool call" — one browser is shared across a user's
 *     chats, and a page download must land in the chat that owns that page.
 *
 * Kept in its own module (rather than transfers.ts) because the shared
 * execute wrapper in types.ts owns the "wire when a session exists" hook —
 * importing transfers.ts from there would create a runtime cycle.
 */

import { randomBytes } from "node:crypto";
import { rename, rm, stat } from "node:fs/promises";
import { join } from "node:path";

import type { Page } from "playwright-core";

import { NETWORK_BUFFER_CAP, type SessionBrowser } from "../sessions.js";
import {
  DOWNLOAD_MAX_BYTES,
  isAllowedTransferFilename,
  mimeTypeForFilename,
  ownWorkspacePath,
  resolveWorkspaceDir,
  sanitizeFilename,
} from "./transferPolicy.js";
import type { BrowserToolsDeps } from "./types.js";

// Kept on this module for compatibility with existing imports.
export { DOWNLOAD_MAX_BYTES, sanitizeFilename };

/** One wiring per context — re-wiring would double-save every download. */
const wired = new WeakSet<object>();

/**
 * Destination chat per PAGE. One browser is shared across a user's chats, so
 * the same context hosts tabs from several chats; the download must follow
 * the page that started it (not whichever tool call ran last).
 */
const pageWorkspaceSession = new WeakMap<object, string>();

/** Remember `chatSessionId` for the session's currently active page. */
function rememberChatForActivePage(session: SessionBrowser, chatSessionId: string): void {
  const active: Page | undefined = session.tabs[session.activeIndex];
  if (active !== undefined) pageWorkspaceSession.set(active, chatSessionId);
}

/** Filename from a URL's last path segment, or null when absent/invalid. */
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

/** Record a refusal in the session network ring (the model's only signal). */
function recordRefusal(deps: BrowserToolsDeps, session: SessionBrowser, url: string, failure: string): void {
  session.network.push({
    ts: deps.now?.() ?? Date.now(),
    url,
    method: "GET",
    status: null,
    failure,
  });
  if (session.network.length > NETWORK_BUFFER_CAP) {
    session.network.splice(0, session.network.length - NETWORK_BUFFER_CAP);
  }
}

/** Attach the context download listener for `session` (idempotent). */
export function wireDownloads(
  deps: BrowserToolsDeps,
  session: SessionBrowser,
  chatSessionId?: string,
): void {
  const context = session.handle.context;
  // Rewire the page→chat mapping on EVERY tool call (the same user may be
  // driving several chats on one shared context); the listener itself is
  // installed once.
  if (chatSessionId !== undefined) rememberChatForActivePage(session, chatSessionId);
  if (wired.has(context)) return;
  wired.add(context);

  context.on("download", (download) => {
    void (async () => {
      try {
        const url = download.url();
        const suggested = sanitizeFilename(download.suggestedFilename());
        const name = suggested ?? defaultFilename(url);

        // Same allowlist as uploads/explicit downloads: a known active
        // content extension (.html, .svg, .exe) is refused BEFORE any byte
        // reaches the workspace. An extension-less name is generic binary.
        if (name === null || !isAllowedTransferFilename(name)) {
          await download.delete().catch(() => {});
          recordRefusal(deps, session, url, "download refused: file type not allowed");
          return;
        }

        // Playwright has no streaming handle for page-initiated downloads:
        // the browser writes the body to its own temp file and `path()`
        // resolves when that write finishes. We therefore cap BEFORE the
        // body reaches the session workspace — an oversized download is
        // deleted (never copied in) and recorded as a refusal.
        const limit = deps.downloadMaxBytes ?? DOWNLOAD_MAX_BYTES;
        const downloadedPath = await download.path();
        const info = await stat(downloadedPath);
        if (info.size > limit) {
          await download.delete().catch(() => {});
          recordRefusal(deps, session, url, "download refused: exceeds size limit");
          return;
        }

        // The chat that owns the page that triggered this download (falling
        // back to the browser-key's own workspace for a page never wired).
        const page = typeof download.page === "function" ? download.page() : null;
        const chat = (page !== null ? pageWorkspaceSession.get(page) : undefined) ?? session.sessionId;
        const root = await deps.workspaceDir(session.userId, chat);
        // Same jail as explicit downloads: a symlinked `browser/` component is
        // refused instead of silently creating `downloads/` outside the root.
        const dir = await resolveWorkspaceDir(root, "browser/downloads");
        if (dir === null) {
          await download.delete().catch(() => {});
          recordRefusal(deps, session, url, "download refused: destination escapes the workspace");
          return;
        }

        // Save to a fresh name and rename into place: `rename` replaces a
        // planted symlink instead of following it outside the jail.
        const temp = join(dir, `.part-${randomBytes(6).toString("hex")}`);
        try {
          await download.saveAs(temp);
          await rename(temp, join(dir, name));
        } catch (err) {
          await rm(temp, { force: true }).catch(() => {});
          throw err;
        }
        // Same hand-off as browser_download: the agent owns the file.
        await ownWorkspacePath(deps, session.userId, dir);
        await ownWorkspacePath(deps, session.userId, join(dir, name));

        // Wave 6 W4: the page's own download also lands in the account
        // Artifact Vault. Failure is non-fatal — the workspace copy exists.
        if (deps.artifactVault !== undefined) {
          try {
            await deps.artifactVault.registerFromWorkspace({
              userId: session.userId,
              sessionId: chat,
              path: `browser/downloads/${name}`,
              mimeType: mimeTypeForFilename(name) ?? "application/octet-stream",
            });
          } catch (err) {
            deps.log?.("page download: artifact vault registration failed", err);
          }
        }

        session.network.push({
          ts: deps.now?.() ?? Date.now(),
          url,
          method: "GET",
          status: 200,
          failure: null,
        });
        if (session.network.length > NETWORK_BUFFER_CAP) {
          session.network.splice(0, session.network.length - NETWORK_BUFFER_CAP);
        }
      } catch {
        // An event listener must never throw into the emitter; a failed
        // auto-save simply leaves no artifact (the model can retry with
        // browser_download and the explicit URL).
      }
    })();
  });
}
