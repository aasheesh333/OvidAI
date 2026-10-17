import { realpath } from "node:fs/promises";
import { dirname, join } from "node:path";

/**
 * Path confinement for the host-side file tools (plan Task 12): every
 * model-supplied path must resolve INSIDE the workspace root, on the HOST
 * filesystem — the tools never spawn a jail, so this module is the whole
 * security boundary for them.
 *
 * Rules (pinned by the brief):
 * - accepts workspace-relative paths and "/workspace/…"-prefixed paths;
 * - rejects absolute paths that survive the prefix strip, and any ".." that
 *   climbs above the root;
 * - the realpath of the NEAREST EXISTING ANCESTOR of the candidate must stay
 *   within realpath(root) + "/" — a symlink pointing outside the workspace
 *   rejects even when the final segment does not exist yet;
 * - returns the HOST path (lexical join of the root and the normalized
 *   remainder) — the caller operates on it directly.
 *
 * File tools map ConfinementError to
 * {content: "confined: <path> is outside the workspace", isError: true}
 * (the "confined:" prefix is pinned — Task 14 asserts it).
 */

export class ConfinementError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConfinementError";
  }
}

const WORKSPACE_PREFIX = "/workspace/";

function isErrnoException(err: unknown): err is NodeJS.ErrnoException {
  return err instanceof Error && "code" in err;
}

function outside(p: string): ConfinementError {
  return new ConfinementError(`${p} is outside the workspace`);
}

/**
 * Strips the /workspace prefix and normalizes "."/".." segments; throws
 * ConfinementError on absolute-after-strip, empty, or escaping paths.
 * Returns the normalized RELATIVE path segments.
 */
function normalizeRelative(p: string): string[] {
  let rel: string;
  if (p.startsWith(WORKSPACE_PREFIX)) {
    rel = p.slice(WORKSPACE_PREFIX.length);
  } else if (p === "/workspace") {
    rel = "";
  } else if (p.startsWith("/")) {
    throw outside(p); // absolute but not /workspace-prefixed
  } else {
    rel = p;
  }
  if (rel === "") throw outside(p);

  const parts: string[] = [];
  for (const seg of rel.split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") {
      if (parts.length === 0) throw outside(p); // climbs above the root
      parts.pop();
      continue;
    }
    parts.push(seg);
  }
  if (parts.length === 0) throw outside(p);
  return parts;
}

/**
 * Resolves `p` (workspace-relative or /workspace-prefixed) to a HOST path
 * inside `root`. Throws {@link ConfinementError} for anything that could touch
 * a file outside the workspace, including via symlinks.
 */
export async function resolveConfined(root: string, p: string): Promise<string> {
  const parts = normalizeRelative(p);
  const rootReal = await realpath(root);
  const candidate = join(root, ...parts);

  // Nearest existing ancestor: walk up until realpath succeeds. The walk is
  // bounded by the root itself (which exists), and every existing prefix must
  // realpath INSIDE the real root — this is what makes symlink escapes
  // reject even when deeper segments do not exist yet.
  let probe = candidate;
  for (let hops = 0; hops < parts.length + 1; hops += 1) {
    let probeReal: string;
    try {
      probeReal = await realpath(probe);
    } catch (err) {
      if (isErrnoException(err) && err.code === "ENOENT") {
        probe = dirname(probe);
        continue;
      }
      throw err;
    }
    if (probeReal !== rootReal && !probeReal.startsWith(`${rootReal}/`)) {
      throw outside(p);
    }
    break;
  }
  return candidate;
}
