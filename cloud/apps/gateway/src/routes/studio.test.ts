import { describe, expect, it, vi } from "vitest";
import { createEnvelopeCrypto } from "@ovid/mcp";
import { schema, sessions, studioRepos, type Db } from "@ovid/db";
import { buildGateway } from "../app.js";
import { StudioGitRefusal, type StudioGitTransport } from "../studioGit.js";
import {
  authHeaders,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubSystemBus,
  stubTickets,
  stubVerifier,
} from "../test/stubs.js";

// Studio repo/branch/clone routes.
//
// Studio was unreachable from every client: the worker could clone, but no
// gateway route reached it, so the screen could not list a repo, list a
// branch or start a clone. These tests pin the wire contract:
//
//   - the token comes from the user's own GitHub integration (the curated
//     `github` MCP row) and is NEVER echoed, logged or put in a response;
//   - clone/switch/sync are refused loudly (`studio_git_unavailable`) when
//     the composition has no worker transport — a 200 here would be the
//     "control with no handler" this project forbids;
//   - the session's repo binding is what makes "change branch any time" and
//     "sync latest" possible, so it is read back, not kept client-side.

const MASTER_KEY_HEX = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";
const SESSION_ID = "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b";
const GITHUB_TOKEN = "ghp_super_secret_value_do_not_echo";

const crypto = createEnvelopeCrypto(MASTER_KEY_HEX);

interface State {
  servers: Array<Record<string, unknown>>;
  session: Record<string, unknown> | null;
  binding: Record<string, unknown> | null;
}

function githubRow(sealed: unknown): Record<string, unknown> {
  return {
    id: "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a6c",
    userId: "u1",
    name: "github",
    transport: "native",
    curatedId: "github",
    config: null,
    secretsSealed: sealed,
    enabled: true,
    createdAt: new Date(),
    updatedAt: new Date(),
  };
}

function sessionRow(userId = "u1"): Record<string, unknown> {
  return {
    id: SESSION_ID,
    userId,
    title: "studio",
    mode: "studio",
    projectId: null,
    createdAt: new Date(),
    updatedAt: new Date(),
    archivedAt: null,
    pinnedAt: null,
    deletedAt: null,
  };
}

/**
 * A Db stub that answers the four reads the routes make, keyed by drizzle
 * table identity. `.where()` is ignored — each table has at most one row in
 * a test — and the insert path records the binding so it can be read back.
 * Ownership-specific tests replace the repo functions with UID-aware fakes.
 */
function fakeDb(state: State): Db {
  const rowsFor = (table: unknown): Array<Record<string, unknown>> => {
    if (table === schema.sessions) return state.session === null ? [] : [state.session];
    if (table === schema.mcpServers) return state.servers;
    if (table === schema.studioRepos) return state.binding === null ? [] : [state.binding];
    return [];
  };

  return {
    select: () => ({
      from: (table: unknown) => {
        const rows = rowsFor(table);
        const chain = {
          limit: async () => rows,
          orderBy: async () => rows,
        };
        return {
          where: () => chain,
          orderBy: async () => rows,
        };
      },
    }),
    insert: (table: unknown) => ({
      values: (values: Record<string, unknown>) => ({
        onConflictDoUpdate: () => ({
          returning: async () => {
            if (table === schema.studioRepos) {
              state.binding = { ...values, createdAt: new Date(), updatedAt: new Date() };
              return [state.binding];
            }
            return [];
          },
        }),
      }),
    }),
  } as unknown as Db;
}

interface GithubCall {
  url: string;
  init: RequestInit | undefined;
}

function githubStub(
  handler: (url: string) => { status: number; body: unknown; headers?: Record<string, string> },
): { impl: typeof fetch; calls: GithubCall[] } {
  const calls: GithubCall[] = [];
  const impl = async (input: unknown, init?: RequestInit): Promise<Response> => {
    const url = String(input);
    calls.push({ url, init });
    const answer = handler(url);
    return new Response(JSON.stringify(answer.body), {
      status: answer.status,
      headers: { "content-type": "application/json", ...(answer.headers ?? {}) },
    });
  };
  return { impl: impl as unknown as typeof fetch, calls };
}

function stubTransport(behavior: {
  cloneThrows?: unknown;
  readThrows?: unknown;
  syncStatus?: "up_to_date" | "synced" | "needs_merge";
} = {}) {
  const calls: Array<Record<string, unknown>> = [];
  const transport: StudioGitTransport = {
    async clone(req) {
      calls.push({ op: "clone", ...req });
      if (behavior.cloneThrows !== undefined) throw behavior.cloneThrows;
      return { repoDir: req.dest ?? "app", branch: req.branch ?? "main" };
    },
    async sync(req) {
      calls.push({ op: "sync", ...req });
      return {
        status: behavior.syncStatus ?? "up_to_date",
        dirty: false,
        behind: 0,
        ahead: 0,
        branch: "main",
        message: "Up to date.",
      };
    },
    async switchBranch(req) {
      calls.push({ op: "switch_branch", ...req });
      return {
        status: "switched",
        branch: req.branch,
        stashed: false,
        message: `Switched to ${req.branch}.`,
      };
    },
    async inspect(req) {
      calls.push({ op: "inspect", ...req });
      if (behavior.readThrows !== undefined) throw behavior.readThrows;
      return {
        branch: "main",
        headSha: "0123456789012345678901234567890123456789",
        upstream: "origin/main",
        dirty: true,
        ahead: 0,
        behind: 1,
        reason: "dirty_worktree" as const,
        fetchedAt: "2026-10-24T12:00:00.000Z",
      };
    },
    async status(req) {
      calls.push({ op: "status", ...req });
      if (behavior.readThrows !== undefined) throw behavior.readThrows;
      return {
        branch: "main",
        headSha: "0123456789012345678901234567890123456789",
        upstream: "origin/main",
        dirty: false,
        ahead: 0,
        behind: 0,
        reason: "clean" as const,
        fetchedAt: null,
      };
    },
    async diff(req) {
      calls.push({ op: "diff", ...req });
      if (behavior.readThrows !== undefined) throw behavior.readThrows;
      return { patch: "diff --git a/src/App.tsx b/src/App.tsx\n+changed\n", truncated: true };
    },
    async logs(req) {
      calls.push({ op: "logs", ...req });
      if (behavior.readThrows !== undefined) throw behavior.readThrows;
      return {
        items: [{
          sha: "0123456789012345678901234567890123456789",
          subject: "initial",
          authoredAt: "2026-10-24T11:00:00.000Z",
        }],
      };
    },
    async search(req) {
      calls.push({ op: "search", ...req });
      if (behavior.readThrows !== undefined) throw behavior.readThrows;
      return {
        items: [{ path: "app/src/App.tsx", name: "App.tsx" }],
        truncated: true,
      };
    },
  };
  return { transport, calls };
}

interface ComposeOptions {
  state?: Partial<State>;
  github?: ReturnType<typeof githubStub>;
  studioGit?: StudioGitTransport;
  cryptoEnabled?: boolean;
  token?: string | null;
}

function compose(opts: ComposeOptions = {}) {
  const state: State = {
    servers: [],
    session: sessionRow(),
    binding: null,
    ...opts.state,
  };
  if (opts.token !== null && state.servers.length === 0) {
    const token = opts.token ?? GITHUB_TOKEN;
    const row = githubRow(undefined);
    row.secretsSealed = crypto.encrypt(
      JSON.stringify({ GITHUB_TOKEN: token }),
      `mcp_servers:${row.id}`,
    );
    state.servers = [row];
  }

  const gh = opts.github ?? githubStub(() => ({ status: 200, body: [] }));
  const app = buildGateway({
    system: stubSystemBus(),
    db: fakeDb(state),
    queues: stubQueues().queues,
    verifier: stubVerifier(),
    tickets: stubTickets(),
    keys: stubKeys(),
    mint: stubMint(),
    events: noopEvents,
    ...(opts.cryptoEnabled === false ? {} : { crypto }),
    github: { apiBase: "https://gh.test", fetch: gh.impl },
    ...(opts.studioGit !== undefined ? { studioGit: opts.studioGit } : {}),
  });
  return { app, state, gh };
}

function auth(uid = "u1") {
  return authHeaders(uid);
}

describe("GET /cloud/v1/studio/github", () => {
  it("reports the connected account, and never echoes the token", async () => {
    const gh = githubStub((url) =>
      url.endsWith("/user")
        ? { status: 200, body: { login: "octocat", id: 1 } }
        : { status: 404, body: {} },
    );
    const { app } = compose({ github: gh });
    const res = await app.inject({ method: "GET", url: "/cloud/v1/studio/github", headers: auth() });

    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ connected: true, login: "octocat", source: "mcp" });
    expect(JSON.stringify(res.json())).not.toContain(GITHUB_TOKEN);
    expect(res.headers["cache-control"]).toBe("private, no-store");

    // The token travels in the Authorization header only — never the URL.
    const call = gh.calls.find((c) => c.url.endsWith("/user"))!;
    expect(call.url).toBe("https://gh.test/user");
    expect((call.init?.headers as Record<string, string>).authorization).toBe(
      `Bearer ${GITHUB_TOKEN}`,
    );
  });

  it("is disconnected, not broken, when the user has no GitHub integration", async () => {
    const { app } = compose({ token: null });
    const res = await app.inject({ method: "GET", url: "/cloud/v1/studio/github", headers: auth() });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ connected: false, login: null, source: "mcp" });
  });

  it("treats a rejected token as disconnected so the screen offers reconnect", async () => {
    const gh = githubStub(() => ({ status: 401, body: { message: "Bad credentials" } }));
    const { app } = compose({ github: gh });
    const res = await app.inject({ method: "GET", url: "/cloud/v1/studio/github", headers: auth() });
    expect(res.statusCode).toBe(200);
    expect(res.json().connected).toBe(false);
  });
});

describe("GET /cloud/v1/studio/repos", () => {
  it("lists the connected account's repos in camelCase, with paging", async () => {
    const gh = githubStub((url) => {
      expect(url).toContain("/user/repos");
      return {
        status: 200,
        body: [
          {
            id: 11,
            name: "app",
            full_name: "acme/app",
            private: true,
            owner: { login: "acme" },
            default_branch: "main",
            description: "The app",
            updated_at: "2026-10-01T00:00:00Z",
            html_url: "https://github.com/acme/app",
          },
        ],
      };
    });
    const { app } = compose({ github: gh });
    const res = await app.inject({
      method: "GET",
      url: "/cloud/v1/studio/repos?page=2&perPage=1",
      headers: auth(),
    });

    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({
      items: [
        {
          id: 11,
          owner: "acme",
          name: "app",
          fullName: "acme/app",
          private: true,
          defaultBranch: "main",
          description: "The app",
          updatedAt: "2026-10-01T00:00:00Z",
          url: "https://github.com/acme/app",
        },
      ],
      page: 2,
      perPage: 1,
      // A full page means "there may be more" — the client asks again.
      hasMore: true,
    });

    const url = new URL(gh.calls[0]!.url);
    expect(url.searchParams.get("page")).toBe("2");
    expect(url.searchParams.get("per_page")).toBe("1");
    expect(url.searchParams.get("affiliation")).toBe("owner,collaborator,organization_member");
    expect(JSON.stringify(res.json())).not.toContain(GITHUB_TOKEN);
  });

  it("refuses with github_not_connected when there is no token", async () => {
    const { app } = compose({ token: null });
    const res = await app.inject({ method: "GET", url: "/cloud/v1/studio/repos", headers: auth() });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe("github_not_connected");
  });

  it("maps a revoked token to github_not_connected, not a 500", async () => {
    const gh = githubStub(() => ({ status: 401, body: { message: "Bad credentials" } }));
    const { app } = compose({ github: gh });
    const res = await app.inject({ method: "GET", url: "/cloud/v1/studio/repos", headers: auth() });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe("github_not_connected");
  });

  it("reports a rate limit as 429", async () => {
    const gh = githubStub(() => ({
      status: 403,
      body: { message: "API rate limit exceeded" },
      headers: { "x-ratelimit-remaining": "0", "x-ratelimit-reset": "1790000000" },
    }));
    const { app } = compose({ github: gh });
    const res = await app.inject({ method: "GET", url: "/cloud/v1/studio/repos", headers: auth() });
    expect(res.statusCode).toBe(429);
    expect(res.json().error.code).toBe("github_rate_limited");
  });

  it("answers 503 github_unavailable when GitHub cannot be reached", async () => {
    const gh = githubStub(() => ({ status: 200, body: [] }));
    const failing = {
      impl: (async () => {
        throw new Error("connect ECONNREFUSED");
      }) as unknown as typeof fetch,
      calls: gh.calls,
    };
    const { app } = compose({ github: failing });
    const res = await app.inject({ method: "GET", url: "/cloud/v1/studio/repos", headers: auth() });
    expect(res.statusCode).toBe(503);
    expect(res.json().error.code).toBe("github_unavailable");
  });
});

describe("GET /cloud/v1/studio/repos/:owner/:repo/branches", () => {
  it("lists branches", async () => {
    const gh = githubStub((url) => {
      expect(url).toContain("/repos/acme/app/branches");
      return {
        status: 200,
        body: [
          { name: "main", protected: true, commit: { sha: "abc123" } },
          { name: "feat/x", protected: false, commit: { sha: "def456" } },
        ],
      };
    });
    const { app } = compose({ github: gh });
    const res = await app.inject({
      method: "GET",
      url: "/cloud/v1/studio/repos/acme/app/branches",
      headers: auth(),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().items).toEqual([
      { name: "main", protected: true, commitSha: "abc123" },
      { name: "feat/x", protected: false, commitSha: "def456" },
    ]);
  });

  it("refuses a malformed owner/repo before calling GitHub", async () => {
    const gh = githubStub(() => ({ status: 200, body: [] }));
    const { app } = compose({ github: gh });
    const res = await app.inject({
      method: "GET",
      url: "/cloud/v1/studio/repos/acme/..%2F..%2Fsecret/branches",
      headers: auth(),
    });
    expect(res.statusCode).toBe(400);
    expect(gh.calls).toHaveLength(0);
  });

  it("maps a repo the token cannot see to 404", async () => {
    const gh = githubStub(() => ({ status: 404, body: { message: "Not Found" } }));
    const { app } = compose({ github: gh });
    const res = await app.inject({
      method: "GET",
      url: "/cloud/v1/studio/repos/acme/missing/branches",
      headers: auth(),
    });
    expect(res.statusCode).toBe(404);
    expect(res.json().error.code).toBe("not_found");
  });
});

describe("GET /cloud/v1/studio/sessions/:id/git", () => {
  it("reports the binding and whether git is available", async () => {
    const { transport } = stubTransport();
    const { app } = compose({
      studioGit: transport,
      state: {
        binding: {
          sessionId: SESSION_ID,
          userId: "u1",
          repo: "acme/app",
          repoDir: "app",
          branch: "main",
          createdAt: new Date(),
          updatedAt: new Date(),
        },
      },
    });
    const res = await app.inject({
      method: "GET",
      url: `/cloud/v1/studio/sessions/${SESSION_ID}/git`,
      headers: auth(),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({
      sessionId: SESSION_ID,
      repo: { repo: "acme/app", repoDir: "app", branch: "main" },
      git: { available: true, reason: null },
    });
  });

  it("says git is unavailable when the composition has no worker transport", async () => {
    const { app } = compose();
    const res = await app.inject({
      method: "GET",
      url: `/cloud/v1/studio/sessions/${SESSION_ID}/git`,
      headers: auth(),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({
      repo: null,
      git: { available: false, reason: "studio_git_unavailable" },
    });
  });

  it("404s a session the caller does not own", async () => {
    const { app } = compose({ state: { session: null } });
    const res = await app.inject({
      method: "GET",
      url: `/cloud/v1/studio/sessions/${SESSION_ID}/git`,
      headers: auth(),
    });
    expect(res.statusCode).toBe(404);
  });
});

describe("POST /cloud/v1/studio/sessions/:id/git/clone", () => {
  it("refuses loudly when no worker transport is wired — never a fake success", async () => {
    const { app } = compose();
    const res = await app.inject({
      method: "POST",
      url: `/cloud/v1/studio/sessions/${SESSION_ID}/git/clone`,
      headers: auth(),
      payload: { repo: "acme/app" },
    });
    expect(res.statusCode).toBe(503);
    expect(res.json().error.code).toBe("studio_git_unavailable");
  });

  it("clones and stores the session binding", async () => {
    const { transport, calls } = stubTransport();
    const { app } = compose({ studioGit: transport });
    const res = await app.inject({
      method: "POST",
      url: `/cloud/v1/studio/sessions/${SESSION_ID}/git/clone`,
      headers: auth(),
      payload: { repo: "acme/app", branch: "feat/x" },
    });
    expect(res.statusCode).toBe(201);
    expect(res.json()).toMatchObject({
      sessionId: SESSION_ID,
      repo: "acme/app",
      repoDir: "app",
      branch: "feat/x",
      bindingStored: true,
    });
    expect(calls).toEqual([
      { op: "clone", userId: "u1", sessionId: SESSION_ID, repo: "acme/app", branch: "feat/x" },
    ]);

    // The binding is server-side: the next read sees it without the client
    // repeating the repo.
    const read = await app.inject({
      method: "GET",
      url: `/cloud/v1/studio/sessions/${SESSION_ID}/git`,
      headers: auth(),
    });
    expect(read.json().repo).toMatchObject({ repo: "acme/app", repoDir: "app", branch: "feat/x" });
  });

  it("accepts a github URL and stores the canonical owner/name", async () => {
    const { transport, calls } = stubTransport();
    const { app } = compose({ studioGit: transport });
    const res = await app.inject({
      method: "POST",
      url: `/cloud/v1/studio/sessions/${SESSION_ID}/git/clone`,
      headers: auth(),
      payload: { repo: "https://github.com/acme/app.git" },
    });
    expect(res.statusCode).toBe(201);
    expect(calls[0]).toMatchObject({ repo: "acme/app" });
    expect(res.json().repo).toBe("acme/app");
  });

  it("refuses another host and a credential-bearing URL before the worker runs", async () => {
    const { transport, calls } = stubTransport();
    const { app } = compose({ studioGit: transport });
    for (const repo of ["https://gitlab.com/acme/app.git", "https://user:tok@github.com/acme/app"]) {
      const res = await app.inject({
        method: "POST",
        url: `/cloud/v1/studio/sessions/${SESSION_ID}/git/clone`,
        headers: auth(),
        payload: { repo },
      });
      expect(res.statusCode).toBe(400);
    }
    expect(calls).toHaveLength(0);
  });

  it("rejects unknown body keys (.strict())", async () => {
    const { transport } = stubTransport();
    const { app } = compose({ studioGit: transport });
    const res = await app.inject({
      method: "POST",
      url: `/cloud/v1/studio/sessions/${SESSION_ID}/git/clone`,
      headers: auth(),
      payload: { repo: "acme/app", token: "ghp_smuggled" },
    });
    expect(res.statusCode).toBe(400);
  });

  it("relays a typed worker refusal (destination exists)", async () => {
    const { StudioGitRefusal } = await import("../studioGit.js");
    const { transport } = stubTransport({
      cloneThrows: new StudioGitRefusal("destination_exists", "The folder already exists."),
    });
    const { app } = compose({ studioGit: transport });
    const res = await app.inject({
      method: "POST",
      url: `/cloud/v1/studio/sessions/${SESSION_ID}/git/clone`,
      headers: auth(),
      payload: { repo: "acme/app" },
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe("destination_exists");
  });

  it("refuses when GitHub is not connected, before asking the worker", async () => {
    const { transport, calls } = stubTransport();
    const { app } = compose({ studioGit: transport, token: null });
    const res = await app.inject({
      method: "POST",
      url: `/cloud/v1/studio/sessions/${SESSION_ID}/git/clone`,
      headers: auth(),
      payload: { repo: "acme/app" },
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe("github_not_connected");
    expect(calls).toHaveLength(0);
  });
});

describe("POST /cloud/v1/studio/sessions/:id/git/branch", () => {
  const bound = {
    sessionId: SESSION_ID,
    userId: "u1",
    repo: "acme/app",
    repoDir: "app",
    branch: "main",
    createdAt: new Date(),
    updatedAt: new Date(),
  };

  it("switches the branch of the bound repo and updates the binding", async () => {
    const { transport, calls } = stubTransport();
    const { app } = compose({ studioGit: transport, state: { binding: bound } });
    const res = await app.inject({
      method: "POST",
      url: `/cloud/v1/studio/sessions/${SESSION_ID}/git/branch`,
      headers: auth(),
      payload: { branch: "feat/x" },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ status: "switched", branch: "feat/x" });
    expect(calls).toEqual([
      {
        op: "switch_branch",
        userId: "u1",
        sessionId: SESSION_ID,
        repoDir: "app",
        branch: "feat/x",
      },
    ]);

    const read = await app.inject({
      method: "GET",
      url: `/cloud/v1/studio/sessions/${SESSION_ID}/git`,
      headers: auth(),
    });
    expect(read.json().repo.branch).toBe("feat/x");
  });

  it("refuses when no repo is bound to the session", async () => {
    const { transport } = stubTransport();
    const { app } = compose({ studioGit: transport });
    const res = await app.inject({
      method: "POST",
      url: `/cloud/v1/studio/sessions/${SESSION_ID}/git/branch`,
      headers: auth(),
      payload: { branch: "feat/x" },
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe("no_repo");
  });

  it("refuses an option-looking branch name", async () => {
    const { transport, calls } = stubTransport();
    const { app } = compose({ studioGit: transport, state: { binding: bound } });
    const res = await app.inject({
      method: "POST",
      url: `/cloud/v1/studio/sessions/${SESSION_ID}/git/branch`,
      headers: auth(),
      payload: { branch: "--upload-pack=evil" },
    });
    expect(res.statusCode).toBe(400);
    expect(calls).toHaveLength(0);
  });
});

describe("POST /cloud/v1/studio/sessions/:id/git/sync", () => {
  it("runs the sync-latest check for the bound repo", async () => {
    const { transport, calls } = stubTransport({ syncStatus: "needs_merge" });
    const { app } = compose({
      studioGit: transport,
      state: {
        binding: {
          sessionId: SESSION_ID,
          userId: "u1",
          repo: "acme/app",
          repoDir: "app",
          branch: "main",
          createdAt: new Date(),
          updatedAt: new Date(),
        },
      },
    });
    const res = await app.inject({
      method: "POST",
      url: `/cloud/v1/studio/sessions/${SESSION_ID}/git/sync`,
      headers: auth(),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ status: "needs_merge", branch: "main" });
    expect(calls).toEqual([
      { op: "sync", userId: "u1", sessionId: SESSION_ID, repoDir: "app" },
    ]);
  });

  it("refuses when no repo is bound", async () => {
    const { transport } = stubTransport();
    const { app } = compose({ studioGit: transport });
    const res = await app.inject({
      method: "POST",
      url: `/cloud/v1/studio/sessions/${SESSION_ID}/git/sync`,
      headers: auth(),
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe("no_repo");
  });
});

describe("canonical Studio read and preflight routes", () => {
  const bound = {
    sessionId: SESSION_ID,
    userId: "u1",
    repo: "acme/app",
    repoDir: "app",
    branch: "main",
    createdAt: new Date(),
    updatedAt: new Date(),
  };
  const base = `/cloud/v1/studio/sessions/${SESSION_ID}`;
  const requests = [
    { name: "preflight", method: "POST", url: `${base}/git/preflight`, payload: {} },
    { name: "status", method: "GET", url: `${base}/git/status` },
    { name: "diff", method: "GET", url: `${base}/git/diff?staged=true&path=src%2FApp.tsx` },
    { name: "logs", method: "GET", url: `${base}/git/logs?limit=10` },
    { name: "search", method: "GET", url: `${base}/files/search?q=button&path=src&limit=10` },
  ] as const;

  function boundCompose(behavior: Parameters<typeof stubTransport>[0] = {}) {
    const { transport, calls } = stubTransport(behavior);
    const composed = compose({ studioGit: transport, state: { binding: bound } });
    return { ...composed, transport, calls };
  }

  it("POST git/preflight inspects without calling mutating sync or changing the binding", async () => {
    const { app, calls, state } = boundCompose();
    const before = state.binding;
    const res = await app.inject({
      method: "POST",
      url: `${base}/git/preflight`,
      headers: auth(),
      payload: {},
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({
      branch: "main",
      behind: 1,
      dirty: true,
      fetchedAt: "2026-10-24T12:00:00.000Z",
    });
    expect(calls).toEqual([
      { op: "inspect", userId: "u1", sessionId: SESSION_ID, repoDir: "app" },
    ]);
    expect(calls.some((call) => call.op === "sync")).toBe(false);
    expect(state.binding).toBe(before);
    expect(res.headers["cache-control"]).toBe("private, no-store");
    expect(res.headers.pragma).toBe("no-cache");
  });

  it.each([
    "repoDir=other",
    "uid=other",
    "host=evil.example",
    "token=ghp_smuggled",
    "repoDir=app&repoDir=other",
    "other=unexpected",
  ])("POST git/preflight rejects undocumented query %s before transport", async (query) => {
    const { app, calls } = boundCompose();
    const res = await app.inject({
      method: "POST",
      url: `${base}/git/preflight?${query}`,
      headers: auth(),
      payload: {},
    });
    expect(res.statusCode).toBe(400);
    expect(calls).toEqual([]);
  });

  it("POST git/preflight rejects JSON null instead of treating it as an empty body", async () => {
    const { app, calls } = boundCompose();
    const res = await app.inject({
      method: "POST",
      url: `${base}/git/preflight`,
      headers: { ...auth(), "content-type": "application/json" },
      payload: "null",
    });
    expect(res.statusCode).toBe(400);
    expect(calls).toEqual([]);
  });

  it("POST git/preflight accepts an absent body while keeping the no-query contract", async () => {
    const { app, calls } = boundCompose();
    const res = await app.inject({
      method: "POST",
      url: `${base}/git/preflight`,
      headers: auth(),
    });
    expect(res.statusCode).toBe(200);
    expect(calls).toEqual([
      { op: "inspect", userId: "u1", sessionId: SESSION_ID, repoDir: "app" },
    ]);
  });

  it("GET git/status returns local status without an inspect/fetch", async () => {
    const { app, calls } = boundCompose();
    const res = await app.inject({ method: "GET", url: `${base}/git/status`, headers: auth() });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({
      branch: "main",
      headSha: "0123456789012345678901234567890123456789",
      upstream: "origin/main",
      dirty: false,
      behind: 0,
      ahead: 0,
      reason: "clean",
      fetchedAt: null,
    });
    expect(calls).toEqual([
      { op: "status", userId: "u1", sessionId: SESSION_ID, repoDir: "app" },
    ]);
    expect(res.headers["cache-control"]).toBe("private, no-store");
  });

  it("GET git/diff forwards only staged/path with the server byte cap and returns real truncation", async () => {
    const { app, calls } = boundCompose();
    const res = await app.inject({
      method: "GET",
      url: `${base}/git/diff?staged=true&path=src%2FApp.tsx`,
      headers: auth(),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({
      patch: "diff --git a/src/App.tsx b/src/App.tsx\n+changed\n",
      truncated: true,
    });
    expect(calls).toEqual([{
      op: "diff",
      userId: "u1",
      sessionId: SESSION_ID,
      repoDir: "app",
      staged: true,
      path: "src/App.tsx",
      maxBytes: 256 * 1024,
    }]);
  });

  it("GET git/logs clamps a high limit to 50 and defaults to 20", async () => {
    const { app, calls } = boundCompose();
    const clamped = await app.inject({
      method: "GET",
      url: `${base}/git/logs?limit=999`,
      headers: auth(),
    });
    expect(clamped.statusCode).toBe(200);
    expect(clamped.json().items).toHaveLength(1);
    const defaulted = await app.inject({ method: "GET", url: `${base}/git/logs`, headers: auth() });
    expect(defaulted.statusCode).toBe(200);
    expect(calls).toEqual([
      { op: "logs", userId: "u1", sessionId: SESSION_ID, repoDir: "app", limit: 50 },
      { op: "logs", userId: "u1", sessionId: SESSION_ID, repoDir: "app", limit: 20 },
    ]);
  });

  it("GET files/search resolves path below the binding and clamps/defaults its limit", async () => {
    const { app, calls } = boundCompose();
    const res = await app.inject({
      method: "GET",
      url: `${base}/files/search?q=button&path=src&limit=999`,
      headers: auth(),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({
      items: [{ path: "app/src/App.tsx", name: "App.tsx" }],
      truncated: true,
    });
    const defaulted = await app.inject({
      method: "GET",
      url: `${base}/files/search?q=readme`,
      headers: auth(),
    });
    expect(defaulted.statusCode).toBe(200);
    expect(calls).toEqual([
      { op: "search", userId: "u1", sessionId: SESSION_ID, repoDir: "app/src", query: "button", limit: 100 },
      { op: "search", userId: "u1", sessionId: SESSION_ID, repoDir: "app", query: "readme", limit: 50 },
    ]);
    expect(res.headers["cache-control"]).toBe("private, no-store");
  });

  it.each(requests)("$name returns 409 no_repo without a binding and never calls the worker", async (testCase) => {
    const { transport, calls } = stubTransport();
    const { app } = compose({ studioGit: transport });
    const res = await app.inject({
      method: testCase.method,
      url: testCase.url,
      headers: auth(),
      ...("payload" in testCase ? { payload: testCase.payload } : {}),
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe("no_repo");
    expect(calls).toEqual([]);
  });

  it.each(requests)("$name gives an existing foreign session the same 404 as unknown with no worker call", async (testCase) => {
    const foreignSession = sessionRow("other-user");
    const foreignBinding = { ...bound, userId: "other-user" };
    const ownershipCalls: Array<{ repo: "session" | "binding"; uid: string }> = [];
    vi.spyOn(sessions, "get").mockImplementation(async (_db, id, uid) => {
      ownershipCalls.push({ repo: "session", uid });
      return id === SESSION_ID && uid === "other-user" ? foreignSession as never : null;
    });
    vi.spyOn(studioRepos, "get").mockImplementation(async (_db, uid, id) => {
      ownershipCalls.push({ repo: "binding", uid });
      return id === SESSION_ID && uid === "other-user" ? foreignBinding as never : null;
    });
    try {
      const foreign = stubTransport();
      const foreignApp = compose({
        studioGit: foreign.transport,
        state: { session: foreignSession, binding: foreignBinding },
      });
      const foreignRes = await foreignApp.app.inject({
        method: testCase.method,
        url: testCase.url,
        headers: auth("u1"),
        ...("payload" in testCase ? { payload: testCase.payload } : {}),
      });

      const unknown = stubTransport();
      const unknownApp = compose({
        studioGit: unknown.transport,
        state: { session: null, binding: null },
      });
      const unknownRes = await unknownApp.app.inject({
        method: testCase.method,
        url: testCase.url,
        headers: auth("u1"),
        ...("payload" in testCase ? { payload: testCase.payload } : {}),
      });

      expect(foreignRes.statusCode).toBe(404);
      expect(foreignRes.json()).toEqual(unknownRes.json());
      expect(unknownRes.statusCode).toBe(404);
      expect(foreign.calls).toEqual([]);
      expect(unknown.calls).toEqual([]);
      expect(ownershipCalls.length).toBeGreaterThanOrEqual(2);
      expect(ownershipCalls.every((call) => call.uid === "u1")).toBe(true);
      expect(ownershipCalls.every((call) => call.repo === "session")).toBe(true);
    } finally {
      vi.restoreAllMocks();
    }
  });

  it("UID-aware ownership fixture still allows the actual foreign session owner", async () => {
    const foreignSession = sessionRow("other-user");
    const foreignBinding = { ...bound, userId: "other-user" };
    vi.spyOn(sessions, "get").mockImplementation(async (_db, id, uid) =>
      id === SESSION_ID && uid === "other-user" ? foreignSession as never : null,
    );
    vi.spyOn(studioRepos, "get").mockImplementation(async (_db, uid, id) =>
      id === SESSION_ID && uid === "other-user" ? foreignBinding as never : null,
    );
    try {
      const { transport, calls } = stubTransport();
      const { app } = compose({
        studioGit: transport,
        state: { session: foreignSession, binding: foreignBinding },
      });
      const res = await app.inject({
        method: "POST",
        url: `${base}/git/preflight`,
        headers: auth("other-user"),
        payload: {},
      });
      expect(res.statusCode).toBe(200);
      expect(calls).toEqual([
        { op: "inspect", userId: "other-user", sessionId: SESSION_ID, repoDir: "app" },
      ]);
    } finally {
      vi.restoreAllMocks();
    }
  });

  it.each(requests)("$name hides unknown sessions and malformed UUIDs with no worker call", async (testCase) => {
    const { transport, calls } = stubTransport();
    const wrong = compose({ studioGit: transport, state: { session: null } });
    const wrongRes = await wrong.app.inject({
      method: testCase.method,
      url: testCase.url,
      headers: auth("other-user"),
      ...("payload" in testCase ? { payload: testCase.payload } : {}),
    });
    expect(wrongRes.statusCode).toBe(404);
    const malformed = compose({ studioGit: transport, state: { binding: bound } });
    const malformedRes = await malformed.app.inject({
      method: testCase.method,
      url: testCase.url.replace(SESSION_ID, "not-a-uuid"),
      headers: auth(),
      ...("payload" in testCase ? { payload: testCase.payload } : {}),
    });
    expect(malformedRes.statusCode).toBe(404);
    expect(calls).toEqual([]);
  });

  it.each([
    { method: "POST", url: `${base}/git/preflight`, payload: { repoDir: "other" } },
    { method: "GET", url: `${base}/git/status?uid=other` },
    { method: "GET", url: `${base}/git/diff?host=evil.example` },
    { method: "GET", url: `${base}/git/logs?repoDir=other` },
    { method: "GET", url: `${base}/files/search?q=x&token=ghp_smuggled` },
  ] as const)("rejects client-selected identity/workspace fields: $url", async (testCase) => {
    const { app, calls } = boundCompose();
    const res = await app.inject({
      method: testCase.method,
      url: testCase.url,
      headers: auth(),
      ...("payload" in testCase ? { payload: testCase.payload } : {}),
    });
    expect(res.statusCode).toBe(400);
    expect(calls).toEqual([]);
  });

  it.each([
    `${base}/git/status`,
    `${base}/git/diff`,
    `${base}/git/logs`,
    `${base}/files/search?q=x`,
  ])("does not let a GET body select another workspace or credential: %s", async (url) => {
    const { app, calls } = boundCompose();
    const res = await app.inject({
      method: "GET",
      url,
      headers: { ...auth(), "content-type": "application/json" },
      payload: { repoDir: "other", token: GITHUB_TOKEN },
    });
    expect(res.statusCode).toBe(200);
    expect(res.body).not.toContain(GITHUB_TOKEN);
    expect(calls).toHaveLength(1);
    expect(calls[0]).toMatchObject({ userId: "u1", sessionId: SESSION_ID, repoDir: "app" });
    expect(calls[0]).not.toHaveProperty("token");
  });

  it.each([
    `${base}/git/logs?limit=0`,
    `${base}/git/logs?limit=1.5`,
    `${base}/git/logs?limit=nope`,
    `${base}/git/diff?staged=yes`,
    `${base}/git/diff?path=..%2Fsecret`,
    `${base}/git/diff?path=.git%2Fconfig`,
    `${base}/files/search?q=`,
    `${base}/files/search?q=x&limit=0`,
    `${base}/files/search?q=x&path=%2Fetc`,
    `${base}/files/search?q=x&path=.git`,
  ])("rejects malformed query/path input before the worker: %s", async (url) => {
    const { app, calls } = boundCompose();
    const res = await app.inject({ method: "GET", url, headers: auth() });
    expect(res.statusCode).toBe(400);
    expect(calls).toEqual([]);
  });

  it("returns 503 only when the bound operation has no transport", async () => {
    const { app } = compose({ state: { binding: bound } });
    const res = await app.inject({
      method: "POST",
      url: `${base}/git/preflight`,
      headers: auth(),
      payload: {},
    });
    expect(res.statusCode).toBe(503);
    expect(res.json().error.code).toBe("studio_git_unavailable");
  });

  it("maps preflight fetch refusal separately from sync and credential leaks to safe 500 internal", async () => {
    const fetchFailure = boundCompose({
      readThrows: new StudioGitRefusal("fetch_failed", "Could not reach the remote. Check your connection and try again."),
    });
    const fetchRes = await fetchFailure.app.inject({
      method: "POST",
      url: `${base}/git/preflight`,
      headers: auth(),
      payload: {},
    });
    expect(fetchRes.statusCode).toBe(502);
    expect(fetchRes.json().error.code).toBe("fetch_failed");

    const leak = boundCompose({
      readThrows: new StudioGitRefusal("credential_leak", `sensitive ${GITHUB_TOKEN}`),
    });
    const leakRes = await leak.app.inject({
      method: "POST",
      url: `${base}/git/preflight`,
      headers: auth(),
      payload: {},
    });
    expect(leakRes.statusCode).toBe(500);
    expect(leakRes.json()).toEqual({ error: { code: "internal", message: "Internal server error." } });
    expect(leakRes.body).not.toContain(GITHUB_TOKEN);
  });
});
