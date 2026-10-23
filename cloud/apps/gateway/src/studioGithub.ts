/**
 * GitHub REST client for the Studio repo picker.
 *
 * The token is the user's own GitHub integration (`GITHUB_TOKEN` in the
 * curated `github` MCP row), decrypted by the route for the duration of one
 * request. It travels only in the `Authorization` header — never the URL,
 * never a response, never a log line.
 *
 * Only three read-only calls are made here: who is connected, which repos the
 * token can see, and which branches a repo has. Cloning is the worker's job
 * (`studioGit.ts`), because only the worker can touch the session workspace.
 */

export interface GithubRepo {
  id: number;
  owner: string;
  name: string;
  fullName: string;
  private: boolean;
  defaultBranch: string;
  description: string | null;
  updatedAt: string | null;
  url: string;
}

export interface GithubBranch {
  name: string;
  protected: boolean;
  commitSha: string;
}

/** Why a GitHub call failed, as far as the client can honestly tell. */
export type GithubFailure = "unauthorized" | "not_found" | "rate_limited" | "unavailable";

export class GithubError extends Error {
  readonly name = "GithubError";

  constructor(readonly kind: GithubFailure, message: string) {
    super(message);
  }
}

export interface GithubClient {
  /** The account the token belongs to. Throws `GithubError`. */
  getUser(): Promise<{ login: string }>;
  listRepos(page: number, perPage: number): Promise<GithubRepo[]>;
  listBranches(owner: string, repo: string, page: number, perPage: number): Promise<GithubBranch[]>;
}

export interface GithubClientConfig {
  token: string;
  /** Defaults to `https://api.github.com`; tests point this at a stub. */
  apiBase?: string;
  /** Defaults to global fetch; tests inject a stub so no network is touched. */
  fetchImpl?: typeof fetch;
  /** Default 10_000 ms. */
  timeoutMs?: number;
}

/**
 * Gateway composition seam for the Studio GitHub reads. Production wires
 * nothing (the defaults are the public API); tests inject a fetch stub so no
 * network is touched. Mirrors `GatewayDeps.byok`'s overrides pattern.
 */
export interface GithubRouteOverrides {
  apiBase?: string;
  fetch?: typeof fetch;
  timeoutMs?: number;
}

export const DEFAULT_GITHUB_API_BASE = "https://api.github.com";
export const DEFAULT_GITHUB_TIMEOUT_MS = 10_000;

/** Owner segment: starts alphanumeric, then letters/digits/`-_.` up to 100. */
const OWNER_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$/;
/** Repo segment: GitHub allows a leading dot (`.github`), not `.`/`..`. */
const REPO_RE = /^[A-Za-z0-9_.-]{1,100}$/;
/** The `owner/name` shorthand. */
const SHORTHAND_RE = /^([A-Za-z0-9][A-Za-z0-9_.-]{0,99})\/([A-Za-z0-9_.-]{1,100})$/;

export function isSafeOwner(owner: string): boolean {
  return OWNER_RE.test(owner);
}

export function isSafeRepoName(repo: string): boolean {
  return REPO_RE.test(repo) && repo !== "." && repo !== "..";
}

/**
 * Canonicalise what a Studio screen may send as a repository: `owner/name`
 * or `https://github.com/owner/name(.git)?`.
 *
 * The rules mirror the worker's `normalizeRepoUrl`: no userinfo (that is how
 * a token gets smuggled into a clone), https only, the exact `github.com`
 * host (a token must never be offered to `github.com.evil`), no port, no
 * query/hash, no extra path segments. Anything else is a 400 before the
 * worker is asked to do anything.
 */
export function parseRepoRef(raw: string): { owner: string; name: string; fullName: string } | null {
  const value = raw.trim();
  if (value === "") return null;

  const shorthand = SHORTHAND_RE.exec(value);
  if (shorthand !== null) {
    const [, owner, name] = shorthand;
    if (!isSafeOwner(owner!) || !isSafeRepoName(name!)) return null;
    return { owner: owner!, name: name!, fullName: `${owner}/${name}` };
  }

  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  if (url.protocol !== "https:") return null;
  if (url.username !== "" || url.password !== "") return null;
  if (url.hostname.toLowerCase() !== "github.com") return null;
  if (url.port !== "") return null;
  if (url.search !== "" || url.hash !== "") return null;

  const parts = url.pathname.replace(/^\/+/, "").replace(/\/+$/, "").split("/");
  if (parts.length !== 2) return null;
  const owner = parts[0]!;
  const name = parts[1]!.replace(/\.git$/i, "");
  if (!isSafeOwner(owner) || !isSafeRepoName(name)) return null;
  return { owner, name, fullName: `${owner}/${name}` };
}

/**
 * Branch names git accepts, minus anything that looks like an option.
 * Kept in sync with the worker's `assertSafeBranch` — the gateway refuses
 * early so the user gets the error before a job is queued.
 */
export function isSafeBranch(raw: string): boolean {
  const value = raw.trim();
  if (value === "" || value.startsWith("-")) return false;
  if (/[\s~^:?*[\]\\]/.test(value)) return false;
  if (value.includes("..") || value.includes("@{") || value.endsWith(".")) return false;
  if (value.endsWith(".lock")) return false;
  return true;
}

/** A clone destination is exactly one workspace folder (no nesting). */
export function isSafeRepoDir(raw: string): boolean {
  const value = raw.trim();
  if (value === "" || value === "." || value === "..") return false;
  if (value.includes("/") || value.includes("\\") || value.includes("\0")) return false;
  if (value.startsWith("-")) return false;
  return true;
}

function headerValue(res: Response, name: string): string | null {
  const value = res.headers.get(name);
  return value === null ? null : value.trim();
}

function classify(res: Response): GithubError {
  if (res.status === 401) {
    return new GithubError("unauthorized", "GitHub rejected the saved token.");
  }
  if (res.status === 403) {
    // GitHub uses 403 for both "insufficient scope" and rate limiting; the
    // rate-limit header is the only honest way to tell them apart.
    if (headerValue(res, "x-ratelimit-remaining") === "0") {
      return new GithubError("rate_limited", "GitHub rate limit reached.");
    }
    return new GithubError("unauthorized", "GitHub refused the saved token.");
  }
  if (res.status === 404) {
    return new GithubError("not_found", "Not found on GitHub.");
  }
  if (res.status === 429) {
    return new GithubError("rate_limited", "GitHub rate limit reached.");
  }
  return new GithubError("unavailable", `GitHub answered ${res.status}.`);
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function projectRepo(value: unknown): GithubRepo | null {
  const row = asRecord(value);
  if (row === null) return null;
  const owner = asRecord(row.owner);
  const id = row.id;
  const name = row.name;
  const fullName = row.full_name;
  if (typeof id !== "number" || typeof name !== "string" || typeof fullName !== "string") {
    return null;
  }
  if (owner === null || typeof owner.login !== "string") return null;
  return {
    id,
    owner: owner.login,
    name,
    fullName,
    private: row.private === true,
    defaultBranch: typeof row.default_branch === "string" ? row.default_branch : "",
    description: typeof row.description === "string" ? row.description : null,
    updatedAt: typeof row.updated_at === "string" ? row.updated_at : null,
    url: typeof row.html_url === "string" ? row.html_url : "",
  };
}

function projectBranch(value: unknown): GithubBranch | null {
  const row = asRecord(value);
  if (row === null || typeof row.name !== "string") return null;
  const commit = asRecord(row.commit);
  return {
    name: row.name,
    protected: row.protected === true,
    commitSha: commit !== null && typeof commit.sha === "string" ? commit.sha : "",
  };
}

export function createGithubClient(cfg: GithubClientConfig): GithubClient {
  const base = (cfg.apiBase ?? DEFAULT_GITHUB_API_BASE).replace(/\/+$/, "");
  const fetchImpl = cfg.fetchImpl ?? fetch;
  const timeoutMs = cfg.timeoutMs ?? DEFAULT_GITHUB_TIMEOUT_MS;

  async function getJson(path: string): Promise<unknown> {
    let res: Response;
    try {
      res = await fetchImpl(`${base}${path}`, {
        method: "GET",
        headers: {
          accept: "application/vnd.github+json",
          authorization: `Bearer ${cfg.token}`,
          "x-github-api-version": "2022-11-28",
          "user-agent": "ovid-gateway",
        },
        // A fixed API host should never redirect; fail closed if it does.
        redirect: "error",
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch {
      throw new GithubError("unavailable", "GitHub could not be reached.");
    }
    if (!res.ok) throw classify(res);
    try {
      return (await res.json()) as unknown;
    } catch {
      throw new GithubError("unavailable", "GitHub returned an unreadable answer.");
    }
  }

  return {
    async getUser() {
      const body = asRecord(await getJson("/user"));
      if (body === null || typeof body.login !== "string") {
        throw new GithubError("unavailable", "GitHub returned an unreadable account.");
      }
      return { login: body.login };
    },

    async listRepos(page, perPage) {
      const query = new URLSearchParams({
        page: String(page),
        per_page: String(perPage),
        sort: "updated",
        // Everything the person can push to, not just what they own.
        affiliation: "owner,collaborator,organization_member",
      });
      const body = await getJson(`/user/repos?${query.toString()}`);
      if (!Array.isArray(body)) {
        throw new GithubError("unavailable", "GitHub returned an unreadable repository list.");
      }
      const items: GithubRepo[] = [];
      for (const entry of body) {
        const repo = projectRepo(entry);
        if (repo !== null) items.push(repo);
      }
      return items;
    },

    async listBranches(owner, repo, page, perPage) {
      const query = new URLSearchParams({
        page: String(page),
        per_page: String(perPage),
      });
      const body = await getJson(
        `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/branches?${query.toString()}`,
      );
      if (!Array.isArray(body)) {
        throw new GithubError("unavailable", "GitHub returned an unreadable branch list.");
      }
      const items: GithubBranch[] = [];
      for (const entry of body) {
        const branch = projectBranch(entry);
        if (branch !== null) items.push(branch);
      }
      return items;
    },
  };
}
