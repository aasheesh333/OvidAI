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

import { mkdir } from "node:fs/promises";
import { isAbsolute, join } from "node:path";

import { NETWORK_BUFFER_CAP, type SessionBrowser } from "../sessions.js";
import type { BrowserToolsDeps } from "./types.js";

/** One wiring per context — re-wiring would double-save every download. */
const wired = new WeakSet<object>();

/**
 * Reject anything that is not a single plain filename. `..`, absolute paths
 * and any path separator are refused, so a server's suggested filename can
 * never escape `browser/downloads/`.
 */
export function sanitizeFilename(raw: string | null | undefined): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  if (trimmed === "" || trimmed === "." || trimmed === "..") return null;
  if (trimmed.includes("\0") || trimmed.includes("/") || trimmed.includes("\\")) return null;
  if (isAbsolute(trimmed)) return null;
  return trimmed;
}

/** Attach the context download listener for `session` (idempotent). */
export function wireDownloads(deps: BrowserToolsDeps, session: SessionBrowser): void {
  const context = session.handle.context;
  if (wired.has(context)) return;
  wired.add(context);

  context.on("download", (download) => {
    void (async () => {
      try {
        const name = sanitizeFilename(download.suggestedFilename()) ?? `download-${deps.now?.() ?? Date.now()}`;
        const root = await deps.workspaceDir(session.userId, session.sessionId);
        const dir = join(root, "browser", "downloads");
        await mkdir(dir, { recursive: true });
        await download.saveAs(join(dir, name));

        session.network.push({
          ts: deps.now?.() ?? Date.now(),
          url: download.url(),
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
