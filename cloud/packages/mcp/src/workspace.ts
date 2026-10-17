/**
 * The P2 file seam for in-process MCP handlers (the same adaptation rule as
 * SandboxSpawner): native handlers never touch disk — they talk to this
 * structural interface through McpCallContext.workspace, and the worker's
 * sandbox seam (Task 16) adapts @ovid/sandbox to it.
 *
 * Paths on this seam are JAIL-INTERNAL: WORKSPACE_ROOT ("/workspace") is the
 * cwd a jailed agent sees, and the P2 adapter maps it to
 * /workspaces/users/{uid} on the host, one tree per user.
 */

/** One entry of a workspace directory listing. */
export interface WorkspaceEntry {
  name: string;
  type: "file" | "dir";
  size: number;
  mtime: string;
}

/** Per-user file access, resolved from McpCallContext.workspace. */
export interface WorkspaceFiles {
  read(uid: string, path: string): Promise<{ content: string; bytes: number } | null>;
  write(uid: string, path: string, content: string): Promise<void>;
  list(uid: string, dir: string): Promise<WorkspaceEntry[]>;
  stat(uid: string, path: string): Promise<{ type: "file" | "dir"; size: number; mtime: string } | null>;
  remove(uid: string, path: string): Promise<void>;
}

/** Jail-internal cwd; the P2 adapter maps this to /workspaces/users/{uid}. */
export const WORKSPACE_ROOT = "/workspace";

/** POSIX-style lexical normalization: collapses "//", "." and ".." segments. */
function normalizeAbsolutePath(abs: string): string {
  const segs: string[] = [];
  for (const seg of abs.split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") {
      if (segs.length > 0) segs.pop();
      continue;
    }
    segs.push(seg);
  }
  return `/${segs.join("/")}`;
}

/**
 * Resolve a user-supplied path against a jail base, throwing when the result
 * would escape the base — the path jail every filesystem-style tool goes
 * through before ctx.workspace is touched.
 *
 * Accepted: relative paths ("notes/a.txt", "a/../b.txt") and absolute paths
 * that stay inside the base ("/workspace/a.txt"). Rejected (throws): any
 * absolute path outside the base ("/etc/passwd", "/workspacefoo") and any
 * ".." chain that climbs above the base ("../../etc/passwd"). Backslashes
 * are treated as separators, like the Dart original.
 */
export function resolveWorkspacePath(base: string, p: string): string {
  if (typeof p !== "string") {
    throw new Error(`workspace path must be a string, got ${p === null ? "null" : typeof p}`);
  }
  const baseNorm = normalizeAbsolutePath(base);
  const unified = p.replace(/\\/g, "/");
  const working = unified.startsWith("/") ? unified : `${baseNorm}/${unified}`;
  const resolved = normalizeAbsolutePath(working);
  const prefix = baseNorm === "/" ? "/" : `${baseNorm}/`;
  if (resolved !== baseNorm && !resolved.startsWith(prefix)) {
    throw new Error(`path "${p}" escapes the workspace root "${base}"`);
  }
  return resolved;
}
