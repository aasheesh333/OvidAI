// Hierarchical permission grants — port of lib/core/grant_store.dart's
// MATCHING semantics (P3 Task 12).
//
// A folder grant covers the folder itself and every path beneath it
// (children), but never siblings or parents; a host grant covers the host
// itself, its child domains (`example.com` covers `api.example.com`) and
// every port/path on it — so granting `127.0.0.1` covers everything served
// from loopback. IP literals match only themselves (a suffix match would
// let an attacker-controlled name like `evil.127.0.0.1` ride on a loopback
// grant). Blank / near-blank patterns match nothing — the Dart
// grant_store_blank_path_test parity: a persisted blank path must never
// normalize into a root grant.
//
// Persistence lives in @ovid/db's grants table (session-scoped only — the
// Dart global scope is NOT ported: the agent never consults it). This
// module is the pure matching core the approval gate (approvals.ts) and
// the db rows share.

/** Structural grant shape — db GrantRow projections and test fixtures alike. */
export interface GrantLike {
  /** "path" | "host" */
  kind: "path" | "host";
  /** Normalized absolute path (kind "path") or normalized host (kind "host"). */
  pattern: string;
  /** "allow" | "always" | "deny" — explicit deny beats allow at equal specificity. */
  decision: "allow" | "always" | "deny";
}

/**
 * Normalizes a raw path to an absolute POSIX-style path: `~` expanded,
 * `.`/`..` collapsed lexically, duplicate/trailing slashes removed.
 * Relative paths resolve against `base` (defaults to `/`).
 * Port of grant_store.dart's normalizeGrantPath.
 */
export function normalizeGrantPath(raw: string, base: string = "/"): string {
  let p = raw.trim().replaceAll("\\", "/");
  if (p === "~" || p.startsWith("~/")) {
    p = `/home/user${p.length > 1 ? p.substring(1) : ""}`;
  }
  if (!p.startsWith("/")) {
    const b = base.endsWith("/") ? base.substring(0, base.length - 1) : base;
    p = `${b}/${p}`;
  }
  const parts: string[] = [];
  for (const seg of p.split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") {
      if (parts.length > 0) parts.pop();
      continue;
    }
    parts.push(seg);
  }
  return `/${parts.join("/")}`;
}

/**
 * Normalizes a host: lower-cased, port stripped, IPv6 brackets stripped,
 * trailing dot stripped. Returns "" for empty input.
 * Port of grant_store.dart's normalizeGrantHost.
 */
export function normalizeGrantHost(raw: string): string {
  let h = raw.trim().toLowerCase();
  if (h.startsWith("[")) {
    const end = h.indexOf("]");
    if (end > 0) h = h.substring(1, end);
  } else {
    // Strip the port, but leave bare IPv6 literals (multiple colons) alone.
    const colon = h.lastIndexOf(":");
    if (colon > 0 && h.indexOf(":") === colon) {
      h = h.substring(0, colon);
    }
  }
  if (h.endsWith(".") && h.length > 1) h = h.substring(0, h.length - 1);
  return h;
}

/**
 * True when `candidate` is inside (or equal to) `grantPath`: a strict
 * segment-boundary check, so `/a/b` covers `/a/b/c` but NOT `/a/bc`.
 * A grant on the filesystem root `/` covers every absolute path.
 * Blank inputs on either side never match (blank-path parity).
 */
export function pathCoveredBy(grantPath: string, candidate: string): boolean {
  if (grantPath.trim() === "" || candidate.trim() === "") return false;
  const g = normalizeGrantPath(grantPath);
  const c = normalizeGrantPath(candidate);
  if (c === g) return true;
  if (g === "/") return true;
  return c.startsWith(`${g}/`);
}

/** True for an IP literal (IPv4 or IPv6) after normalizeGrantHost. */
function isIpLiteral(host: string): boolean {
  if (host.includes(":")) return true; // IPv6 (brackets already stripped)
  const v4 = /^\d{1,3}(\.\d{1,3}){3}$/;
  if (!v4.test(host)) return false;
  return host.split(".").every((p) => {
    const n = Number(p);
    return n >= 0 && n <= 255;
  });
}

/**
 * True when `candidateHost` is covered by `grantHost`: exact match or a
 * child domain (`example.com` covers `api.example.com`). IP literals match
 * only themselves — but since matching is host-level, a grant covers every
 * port and path on that host. Blank inputs on either side never match.
 */
export function hostCoveredBy(grantHost: string, candidateHost: string): boolean {
  const g = normalizeGrantHost(grantHost);
  const c = normalizeGrantHost(candidateHost);
  if (g === "" || c === "") return false;
  if (c === g) return true;
  // IP literals match only themselves — a suffix match would let an
  // attacker-controlled name like `evil.127.0.0.1` ride on a loopback grant.
  if (isIpLiteral(g)) return false;
  return c.endsWith(`.${g}`);
}

/** Blank / near-blank patterns never authorize anything (blank-path parity). */
export function grantMatchesPath(pattern: string, target: string): boolean {
  if (pattern.trim() === "" || target.trim() === "") return false;
  return pathCoveredBy(pattern, target);
}

/** Blank hosts never authorize anything; ports/brackets/case normalize away. */
export function grantMatchesHost(pattern: string, host: string): boolean {
  return hostCoveredBy(pattern, host);
}

/** Specificity score: deeper (more specific) patterns score higher. */
function pathSpecificity(pattern: string): number {
  return normalizeGrantPath(pattern)
    .split("/")
    .filter((seg) => seg !== "").length;
}

/** Specificity score: more labels = deeper subdomain = more specific. */
function hostSpecificity(pattern: string): number {
  const h = normalizeGrantHost(pattern);
  if (h === "") return -1;
  return h.split(".").filter((label) => label !== "").length;
}

/**
 * The single applicable grant for `target` among `grants` of the given
 * kind, or null when none matches:
 * - the MOST SPECIFIC pattern wins (a deeper allow beats a shallower deny —
 *   the cloud's P5-revision semantics; Dart let any covering deny win);
 * - an explicit deny beats an allow at EQUAL specificity (the same
 *   normalized pattern recorded with conflicting decisions).
 */
export function findApplicableGrant(
  grants: readonly GrantLike[],
  kind: "path" | "host",
  target: string,
): GrantLike | null {
  let best: GrantLike | null = null;
  let bestScore = -1;
  for (const g of grants) {
    if (g.kind !== kind) continue;
    const matches =
      kind === "path" ? grantMatchesPath(g.pattern, target) : grantMatchesHost(g.pattern, target);
    if (!matches) continue;
    const score = kind === "path" ? pathSpecificity(g.pattern) : hostSpecificity(g.pattern);
    if (best === null || score > bestScore) {
      best = g;
      bestScore = score;
    } else if (
      score === bestScore &&
      g.decision === "deny" &&
      best.decision !== "deny"
    ) {
      best = g; // explicit deny beats allow at equal specificity
    }
  }
  return best;
}
