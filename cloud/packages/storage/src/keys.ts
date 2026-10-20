/**
 * R2 key layout — spec §10, EXACT strings. Every user-controlled piece that
 * lands in a key goes through assertSafeSegment / sanitizeArtifactName first;
 * the fs adapter re-asserts per segment, so a hostile key can never walk out
 * of the bucket root (or the local dev root).
 */

import { KeyLayoutError } from "./errors.js";

export const r2Keys = {
  /** `users/${uid}/workspaces/${sid}.tar.zst` */
  workspaceArchive(userId: string, sessionId: string): string {
    return `users/${userId}/workspaces/${sessionId}.tar.zst`;
  },
  /** `users/${uid}/workspaces/${sid}.manifest.json` */
  workspaceManifest(userId: string, sessionId: string): string {
    return `users/${userId}/workspaces/${sessionId}.manifest.json`;
  },
  /** `users/${uid}/browser/${profileId}.zst` */
  browserState(userId: string, profileId: string): string {
    return `users/${userId}/browser/${profileId}.zst`;
  },
  /** `users/${uid}/artifacts/${sid}/${artifactId}-${sanitized name}` */
  artifact(userId: string, sessionId: string, artifactId: string, name: string): string {
    return `users/${userId}/artifacts/${sessionId}/${artifactId}-${sanitizeArtifactName(name)}`;
  },
  /**
   * W12 content-addressed artifact key:
   * `users/${uid}/artifacts/${sid}/${artifactId}-${sha256[0..16]}-${name}`.
   *
   * The artifact id keeps the key UNIQUE (workspace_objects.r2Key is UNIQUE
   * and deletion is not refcounted, so pure hash-addressing would collide on
   * a re-generated identical file). The digest prefix still makes the object
   * verifiably content-addressed and, together with the write-once UUID,
   * justifies `Cache-Control: immutable` at the CDN.
   */
  contentAddressedArtifact(
    userId: string,
    sessionId: string,
    artifactId: string,
    sha256Hex: string,
    name: string,
  ): string {
    if (!/^[0-9a-f]{64}$/i.test(sha256Hex)) {
      throw new KeyLayoutError("artifact content digest must be 64 hex characters");
    }
    return `users/${userId}/artifacts/${sessionId}/${artifactId}-${sha256Hex
      .toLowerCase()
      .slice(0, 16)}-${sanitizeArtifactName(name)}`;
  },
} as const;

/** True for C0/C1 control characters (and DEL). */
function hasControlChars(s: string): boolean {
  for (const ch of s) {
    const c = ch.codePointAt(0)!;
    if (c < 0x20 || c === 0x7f) return true;
  }
  return false;
}

/**
 * Throws KeyLayoutError unless `segment` is a single safe path/key segment:
 * non-empty, not "." or "..", no separators, no control chars, and
 * ≤ 255 UTF-8 bytes.
 */
export function assertSafeSegment(segment: string): void {
  if (segment === "") {
    throw new KeyLayoutError("key segment must not be empty");
  }
  if (segment === "." || segment === "..") {
    throw new KeyLayoutError(`key segment must not be "${segment}"`);
  }
  if (segment.includes("/") || segment.includes("\\")) {
    throw new KeyLayoutError(`key segment must not contain a path separator: ${JSON.stringify(segment)}`);
  }
  if (hasControlChars(segment)) {
    throw new KeyLayoutError("key segment must not contain control characters");
  }
  if (Buffer.byteLength(segment, "utf8") > 255) {
    throw new KeyLayoutError("key segment must be at most 255 UTF-8 bytes");
  }
}

/**
 * Artifact display name → safe filename piece: [^A-Za-z0-9._-] → "_",
 * runs collapsed, leading dots stripped, truncated to 80 chars, "" →
 * "artifact".
 */
export function sanitizeArtifactName(name: string): string {
  let out = name.replace(/[^A-Za-z0-9._-]+/g, "_");
  out = out.replace(/^\.+/, "");
  // Dots are allowed characters, so a hostile name can still smuggle a ".."
  // run — neutralize it (the result is a filename piece, never a path).
  out = out.replace(/\.{2,}/g, "_");
  if (out.length > 80) out = out.slice(0, 80);
  return out === "" ? "artifact" : out;
}

/**
 * Throws KeyLayoutError unless `rel` is a safe POSIX-relative path: non-empty,
 * not absolute, no ".." segment, no "\\", no control chars, ≤ 4096 bytes.
 * Returns the "."-normalized POSIX-relative path ("a/./b" → "a/b").
 */
export function assertSafeRelPath(rel: string): string {
  if (rel === "") {
    throw new KeyLayoutError("relative path must not be empty");
  }
  if (rel.startsWith("/") || rel.startsWith("\\")) {
    throw new KeyLayoutError(`relative path must not be absolute: ${JSON.stringify(rel)}`);
  }
  // Windows drive form ("C:/x", "C:\\x") counts as absolute too.
  if (/^[A-Za-z]:[\\/]/.test(rel)) {
    throw new KeyLayoutError(`relative path must not be a drive path: ${JSON.stringify(rel)}`);
  }
  if (rel.includes("\\")) {
    throw new KeyLayoutError(`relative path must not contain "\\": ${JSON.stringify(rel)}`);
  }
  if (hasControlChars(rel)) {
    throw new KeyLayoutError("relative path must not contain control characters");
  }
  if (Buffer.byteLength(rel, "utf8") > 4096) {
    throw new KeyLayoutError("relative path must be at most 4096 bytes");
  }
  const segments = rel.split("/");
  const normalized: string[] = [];
  for (const seg of segments) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") {
      throw new KeyLayoutError(`relative path must not contain "..": ${JSON.stringify(rel)}`);
    }
    assertSafeSegment(seg);
    normalized.push(seg);
  }
  if (normalized.length === 0) {
    throw new KeyLayoutError(`relative path has no usable segments: ${JSON.stringify(rel)}`);
  }
  return normalized.join("/");
}
