/**
 * Page-initiated download wiring (P6 Task 13, transfers half).
 *
 * `browser_download` covers explicit URL fetches; pages also start downloads
 * themselves (a link to a PDF, a generated CSV). Those are auto-saved to the
 * same `browser/downloads/` directory and recorded in the session's network
 * ring so the model can find them without an extra round-trip.
 *
 * Kept in its own module (rather than transfers.ts) because the shared
 * execute wrapper in types.ts owns the "wire when a session exists" hook —
 * importing transfers.ts from there would create a runtime cycle.
 */

import { randomBytes } from "node:crypto";
import { rename, rm, stat } from "node:fs/promises";
import { join } from "node:path";

import { NETWORK_BUFFER_CAP, type SessionBrowser } from "../sessions.js";
import {
  DOWNLOAD_MAX_BYTES,
  resolveWorkspaceDir,
  sanitizeFilename,
} from "./transferPolicy.js";
import type { BrowserToolsDeps } from "./types.js";

// Kept on this module for compatibility with existing imports.
export { DOWNLOAD_MAX_BYTES, sanitizeFilename };

/** One wiring per context — re-wiring would double-save every download. */
const wired = new WeakSet<object>();

/**
 * The chat workspace that receives page-initiated downloads. One browser is
 * shared across a user's chats, so the LATEST tool call's chat wins (the
 * listener is context-wide, not per tool call).
 */
const workspaceSession = new WeakMap<object, string>();

/** Attach the context download listener for `session` (idempotent). */
export function wireDownloads(
  deps: BrowserToolsDeps,
  session: SessionBrowser,
  chatSessionId?: string,
): void {
  const context = session.handle.context;
  if (chatSessionId !== undefined) workspaceSession.set(context, chatSessionId);
  if (wired.has(context)) return;
  wired.add(context);
  workspaceSession.set(context, chatSessionId ?? session.sessionId);

  context.on("download", (download) => {
    void (async () => {
      try {
        const url = download.url();
        const name = sanitizeFilename(download.suggestedFilename()) ?? `download-${deps.now?.() ?? Date.now()}`;

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
          session.network.push({
            ts: deps.now?.() ?? Date.now(),
            url,
            method: "GET",
            status: null,
            failure: "download refused: exceeds size limit",
          });
          if (session.network.length > NETWORK_BUFFER_CAP) {
            session.network.splice(0, session.network.length - NETWORK_BUFFER_CAP);
          }
          return;
        }

        const chat = workspaceSession.get(context) ?? session.sessionId;
        const root = await deps.workspaceDir(session.userId, chat);
        // Same jail as explicit downloads: a symlinked `browser/` component is
        // refused instead of silently creating `downloads/` outside the root.
        const dir = await resolveWorkspaceDir(root, "browser/downloads");
        if (dir === null) {
          await download.delete().catch(() => {});
          session.network.push({
            ts: deps.now?.() ?? Date.now(),
            url,
            method: "GET",
            status: null,
            failure: "download refused: destination escapes the workspace",
          });
          if (session.network.length > NETWORK_BUFFER_CAP) {
            session.network.splice(0, session.network.length - NETWORK_BUFFER_CAP);
          }
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

        // Wave 6 W4: the page's own download also lands in the account
        // Artifact Vault. Failure is non-fatal — the workspace copy exists.
        if (deps.artifactVault !== undefined) {
          try {
            await deps.artifactVault.registerFromWorkspace({
              userId: session.userId,
              sessionId: chat,
              path: `browser/downloads/${name}`,
              mimeType: "application/octet-stream",
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
