/**
 * Upload/download policy (P3 hardening): one place for the bytes ceiling, the
 * MIME allowlist and the workspace jail.
 *
 * The browser tools move user files in both directions, so every path and
 * every content type crosses this module:
 *
 *   - paths are resolved against the session workspace (`/workspace` inside
 *     the sandbox) LEXICALLY and then through `realpath`, so neither `../`
 *     nor a planted symlink can read or write outside the jail;
 *   - directory creation walks one component at a time and refuses to follow
 *     a symlink out of the jail (a recursive `mkdir` through a symlink would
 *     create directories outside it before any check could run);
 *   - downloads are capped while streaming (transfers.ts) and page-initiated
 *     downloads are capped before they are copied in (downloadWiring.ts);
 *   - only attachment-ish MIME types may be written into the workspace, and
 *     uploads are typed by extension against the same allowlist, so `.exe`,
 *     `.sh`, `.html` or `.svg` can never be pushed into a file input.
 */

import { lstat, mkdir, realpath } from "node:fs/promises";
import { isAbsolute, join, relative, resolve, sep } from "node:path";

/** Hard download ceiling — explicit downloads AND page-initiated saves. */
export const DOWNLOAD_MAX_BYTES = 50 * 1024 * 1024;

/** Hard upload ceiling — the source file handed to Playwright. */
export const UPLOAD_MAX_BYTES = 50 * 1024 * 1024;

/**
 * Attachment types the agent may download into the workspace. Deliberately
 * excludes active content (`text/html`, `application/javascript`,
 * `image/svg+xml`, executables) so a stored file can never be served back as
 * a script from our origin. `application/octet-stream` is the fallback for
 * servers that declare nothing — the bytes are still never executed here.
 */
export const TRANSFER_MIME_ALLOWLIST: readonly string[] = Object.freeze([
  // Images
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
  "image/bmp",
  "image/tiff",
  "image/avif",
  // Documents / text
  "application/pdf",
  "application/json",
  "application/xml",
  "text/xml",
  "text/plain",
  "text/csv",
  "text/tab-separated-values",
  "text/markdown",
  // Office
  "application/msword",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "application/vnd.ms-excel",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "application/vnd.ms-powerpoint",
  "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  "application/vnd.oasis.opendocument.text",
  "application/vnd.oasis.opendocument.spreadsheet",
  "application/vnd.oasis.opendocument.presentation",
  // Archives / generic binary
  "application/zip",
  "application/gzip",
  "application/x-tar",
  "application/octet-stream",
  // Media
  "audio/mpeg",
  "audio/ogg",
  "audio/wav",
  "video/mp4",
  "video/webm",
]);

/** Extension → MIME for uploads. Unknown extensions are refused. */
const EXTENSION_MIME: Readonly<Record<string, string>> = Object.freeze({
  ".txt": "text/plain",
  ".log": "text/plain",
  ".md": "text/markdown",
  ".markdown": "text/markdown",
  ".csv": "text/csv",
  ".tsv": "text/tab-separated-values",
  ".json": "application/json",
  ".xml": "application/xml",
  ".pdf": "application/pdf",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".bmp": "image/bmp",
  ".tif": "image/tiff",
  ".tiff": "image/tiff",
  ".avif": "image/avif",
  ".zip": "application/zip",
  ".gz": "application/gzip",
  ".tar": "application/x-tar",
  ".doc": "application/msword",
  ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  ".xls": "application/vnd.ms-excel",
  ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  ".ppt": "application/vnd.ms-powerpoint",
  ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  ".odt": "application/vnd.oasis.opendocument.text",
  ".ods": "application/vnd.oasis.opendocument.spreadsheet",
  ".odp": "application/vnd.oasis.opendocument.presentation",
  ".mp3": "audio/mpeg",
  ".ogg": "audio/ogg",
  ".wav": "audio/wav",
  ".mp4": "video/mp4",
  ".webm": "video/webm",
});

const ALLOWED = new Set(TRANSFER_MIME_ALLOWLIST);

/** `type/subtype` tokens only (RFC 6838-ish); parameters are stripped. */
const MIME_TOKEN = /^[a-z0-9][a-z0-9!#$&^_.+-]*\/[a-z0-9][a-z0-9!#$&^_.+-]*$/;

/**
 * Lower-case, parameter-free MIME type. Missing or malformed headers become
 * `application/octet-stream` (the allowlisted generic-binary fallback).
 */
export function normalizeMimeType(raw: string | null | undefined): string {
  if (typeof raw !== "string") return "application/octet-stream";
  const base = raw.split(";", 1)[0]?.trim().toLowerCase() ?? "";
  return MIME_TOKEN.test(base) ? base : "application/octet-stream";
}

/** True when `raw` (after normalization) is an allowed attachment type. */
export function isAllowedTransferMime(raw: string | null | undefined): boolean {
  return ALLOWED.has(normalizeMimeType(raw));
}

/**
 * MIME for an upload, inferred from its extension. Returns null for an
 * unknown extension (including no extension) — an allowlist, not a blocklist.
 */
export function mimeTypeForFilename(filename: string): string | null {
  const dot = filename.lastIndexOf(".");
  if (dot <= 0 || dot === filename.length - 1) return null;
  const ext = filename.slice(dot).toLowerCase();
  return EXTENSION_MIME[ext] ?? null;
}

/**
 * True when a filename may be stored as a download. A KNOWN extension must be
 * on the allowlist (`payload.html`/`icon.svg`/`setup.exe` are refused); an
 * extension-less name is generic binary — it cannot be served back as active
 * content by extension, so it is allowed (page fixtures and generated files
 * commonly have no suffix).
 */
export function isAllowedTransferFilename(filename: string): boolean {
  const dot = filename.lastIndexOf(".");
  // A leading-dot name (".html") still carries an extension for this check —
  // it must not slip past as "no extension".
  const hasExtension = dot !== -1 && dot < filename.length - 1;
  if (!hasExtension) return true;
  return mimeTypeForFilename(filename) !== null;
}

/** Single-component filename only: no separators, no `..`, no NUL. */
export function sanitizeFilename(raw: string | null | undefined): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  if (trimmed === "" || trimmed === "." || trimmed === "..") return null;
  if (trimmed.includes("\0") || trimmed.includes("/") || trimmed.includes("\\")) return null;
  if (isAbsolute(trimmed)) return null;
  return trimmed;
}

export type WorkspacePathReason = "escape" | "not-found" | "invalid";

export type WorkspacePathResult =
  | {
      ok: true;
      /** Real (symlink-resolved) absolute path. */
      abs: string;
      /** Path relative to the real workspace root. */
      rel: string;
    }
  | { ok: false; reason: WorkspacePathReason };

function isInside(root: string, candidate: string): boolean {
  return candidate === root || candidate.startsWith(root + sep);
}

/**
 * Resolve `candidate` (workspace-relative, or absolute) to a real file inside
 * `root`. The lexical check rejects `../` before touching the filesystem; the
 * `realpath` check then rejects symlinks that point outside the jail.
 */
export async function resolveWorkspaceEntry(
  root: string,
  candidate: string,
): Promise<WorkspacePathResult> {
  if (typeof candidate !== "string" || candidate.trim() === "" || candidate.includes("\0")) {
    return { ok: false, reason: "invalid" };
  }

  const abs = resolve(root, candidate);
  const lexicalRel = relative(root, abs);
  if (lexicalRel === ".." || lexicalRel.startsWith(".." + sep) || isAbsolute(lexicalRel)) {
    return { ok: false, reason: "escape" };
  }

  let realRoot: string;
  let realAbs: string;
  try {
    realRoot = await realpath(root);
    realAbs = await realpath(abs);
  } catch {
    return { ok: false, reason: "not-found" };
  }

  if (!isInside(realRoot, realAbs)) return { ok: false, reason: "escape" };
  return { ok: true, abs: realAbs, rel: relative(realRoot, realAbs) };
}

/**
 * Create (if needed) and return the real absolute path of `relDir` inside
 * `root`, or null when any component would escape the jail. Existing symlinks
 * are resolved and required to stay inside; new directories are created one
 * level at a time so a symlinked parent cannot redirect the `mkdir`.
 */
export async function resolveWorkspaceDir(root: string, relDir: string): Promise<string | null> {
  if (typeof relDir !== "string" || relDir.includes("\0")) return null;

  const lexical = resolve(root, relDir);
  const lexicalRel = relative(root, lexical);
  if (lexicalRel === ".." || lexicalRel.startsWith(".." + sep) || isAbsolute(lexicalRel)) {
    return null;
  }

  let realRoot: string;
  try {
    realRoot = await realpath(root);
  } catch {
    return null;
  }

  let current = realRoot;
  for (const part of lexicalRel.split(sep)) {
    if (part === "" || part === ".") continue;
    if (part === "..") return null;
    current = join(current, part);

    let info;
    try {
      info = await lstat(current);
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== "ENOENT") return null;
      try {
        await mkdir(current);
      } catch {
        return null;
      }
      continue;
    }

    if (info.isSymbolicLink()) {
      let real: string;
      try {
        real = await realpath(current);
      } catch {
        return null;
      }
      if (!isInside(realRoot, real)) return null;
      current = real;
    } else if (!info.isDirectory()) {
      return null;
    }
  }

  try {
    const real = await realpath(current);
    return isInside(realRoot, real) ? real : null;
  } catch {
    return null;
  }
}

/**
 * Hand a written workspace path to the user's sandbox uid.
 *
 * Best-effort by design: an ownership failure must not fail a download the
 * user already has bytes for — the file is still readable, and the caller's
 * report says nothing it cannot back up.
 */
export async function ownWorkspacePath(
  deps: { ownPath?(userId: string, hostPath: string): Promise<void>; log?(msg: string, err?: unknown): void },
  userId: string,
  hostPath: string,
): Promise<void> {
  const own = deps.ownPath;
  if (own === undefined) return;
  try {
    await own(userId, hostPath);
  } catch (err) {
    deps.log?.("workspace ownership hand-off failed", err);
  }
}
