import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type { SandboxManager } from "@ovid/sandbox";
import { GitCredentialLeakError } from "@ovid/sandbox/gitCredential";
import { createEnvelopeCrypto } from "@ovid/escrow";

import { buildFileService, type FileServiceDeps } from "./fileService.js";
import {
  StudioGitError,
  type StudioGit,
  type StudioGitTokenRequest,
  type StudioGitTokenResolver,
} from "./studioGit.js";
import {
  createStudioGitService,
  parseStudioGitAllowedHosts,
  type StudioGitRoutesDeps,
} from "./studioGitRoutes.js";

const INTERNAL_TOKEN = "internal-studio-route-test";
const PAT = "ghp_route_test_secret_1234567890";
const UID = "verified-user";
const SID = "00000000-0000-4000-8000-000000000003";
const PREFIX = `/internal/sessions/${SID}/studio-git`;

const VALID_BODIES: Record<string, Record<string, unknown>> = {
  clone: { repo: "acme/app", branch: "main", dest: "app" },
  sync: { repoDir: "app" },
  "switch-branch": { repoDir: "app", branch: "next" },
  inspect: { repoDir: "app" },
  status: { repoDir: "app" },
  diff: { repoDir: "app", staged: true, path: "README.md", maxBytes: 4096 },
  logs: { repoDir: "app", limit: 10 },
  search: { repoDir: "app", query: "readme", limit: 10 },
};

const STATUS = {
  branch: "main",
  headSha: "0123456789012345678901234567890123456789",
  upstream: "origin/main",
  dirty: false,
  ahead: 0,
  behind: 0,
  reason: "clean" as const,
  fetchedAt: null,
};

interface Call {
  method: string;
  req: Record<string, unknown>;
}

interface HarnessOptions {
  git?: Partial<StudioGit>;
  resolveToken?: StudioGitTokenResolver;
}

const apps: Array<ReturnType<typeof buildFileService>> = [];
const roots: string[] = [];

afterEach(async () => {
  await Promise.all(apps.splice(0).map((app) => app.close()));
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function harness(options: HarnessOptions = {}) {
  const calls: Call[] = [];
  const resolverCalls: StudioGitTokenRequest[] = [];
  const attachedUsers: string[] = [];
  const root = mkdtempSync(join("/tmp/opencode/", "ovid-studio-routes-"));
  roots.push(root);
  const workspaceDir = join(root, "workspace");
  mkdirSync(join(workspaceDir, "app"), { recursive: true });
  writeFileSync(join(workspaceDir, "app", "README.md"), "hello\n");

  const record = (method: string, req: object, result: unknown) => {
    calls.push({ method, req: req as Record<string, unknown> });
    return result;
  };
  const baseGit: StudioGit = {
    clone: async (req) =>
      record("clone", req, { status: "cloned" as const, repoDir: "app", branch: "main" }),
    syncLatest: async (req) =>
      record("sync", req, {
        status: "up_to_date" as const,
        dirty: false,
        behind: 0,
        ahead: 0,
        branch: "main",
        message: "Up to date.",
      }),
    switchBranch: async (req) =>
      record("switchBranch", req, {
        status: "switched" as const,
        branch: "next",
        stashed: false,
        message: "Switched to next.",
      }),
    inspect: async (req) =>
      record("inspect", req, { ...STATUS, fetchedAt: "2026-10-24T00:00:00.000Z" }),
    status: async (req) => record("status", req, STATUS),
    diff: async (req) => record("diff", req, { patch: "diff --git a/README.md b/README.md\n", truncated: false }),
    logs: async (req) =>
      record("logs", req, {
        items: [{ sha: STATUS.headSha, subject: "initial", authoredAt: "2026-10-24T00:00:00.000Z" }],
      }),
  };
  const git = { ...baseGit, ...options.git } as StudioGit;
  const resolveToken: StudioGitTokenResolver =
    options.resolveToken ??
    (async (req) => {
      resolverCalls.push(req);
      return PAT;
    });
  const manager = {
    attach: async (userId: string) => {
      attachedUsers.push(userId);
      return {
        userId,
        uid: typeof process.getuid === "function" ? process.getuid() : 0,
        workspaceDir,
        homeDir: join(root, "home"),
        jailWorkspaceDir: "/workspace",
      };
    },
  } as unknown as Pick<SandboxManager, "attach">;
  const studioGit: StudioGitRoutesDeps = { git, resolveToken, manager };
  const app = buildFileService({
    internalToken: INTERNAL_TOKEN,
    inlineMaxBytes: 1024,
    port: 0,
    workspacesRoot: workspaceDir,
    studioGit,
  } as FileServiceDeps);
  apps.push(app);
  return { app, calls, resolverCalls, attachedUsers };
}

function post(
  app: ReturnType<typeof buildFileService>,
  operation: string,
  payload: unknown,
  headers: Record<string, string> = {
    "x-ovid-internal-token": INTERNAL_TOKEN,
    "x-ovid-user-id": UID,
  },
) {
  return app.inject({ method: "POST", url: `${PREFIX}/${operation}`, headers, payload });
}

describe("Studio git internal routes", () => {
  const cases = [
    {
      operation: "clone",
      method: "clone",
      body: VALID_BODIES.clone!,
      serviceRequest: { ...VALID_BODIES.clone, userId: UID, sessionId: SID, token: PAT },
      response: { repoDir: "app", branch: "main" },
      network: true,
    },
    {
      operation: "sync",
      method: "sync",
      body: VALID_BODIES.sync!,
      serviceRequest: { ...VALID_BODIES.sync, userId: UID, sessionId: SID, token: PAT },
      response: {
        status: "up_to_date",
        dirty: false,
        behind: 0,
        ahead: 0,
        branch: "main",
        message: "Up to date.",
      },
      network: true,
    },
    {
      operation: "switch-branch",
      method: "switchBranch",
      body: VALID_BODIES["switch-branch"]!,
      serviceRequest: { ...VALID_BODIES["switch-branch"], userId: UID, sessionId: SID, token: PAT },
      response: { status: "switched", branch: "next", stashed: false, message: "Switched to next." },
      network: true,
    },
    {
      operation: "inspect",
      method: "inspect",
      body: VALID_BODIES.inspect!,
      serviceRequest: { ...VALID_BODIES.inspect, userId: UID, sessionId: SID, token: PAT },
      response: { ...STATUS, fetchedAt: "2026-10-24T00:00:00.000Z" },
      network: true,
    },
    {
      operation: "status",
      method: "status",
      body: VALID_BODIES.status!,
      serviceRequest: { ...VALID_BODIES.status, userId: UID, sessionId: SID },
      response: STATUS,
      network: false,
    },
    {
      operation: "diff",
      method: "diff",
      body: VALID_BODIES.diff!,
      serviceRequest: { ...VALID_BODIES.diff, userId: UID, sessionId: SID },
      response: { patch: "diff --git a/README.md b/README.md\n", truncated: false },
      network: false,
    },
    {
      operation: "logs",
      method: "logs",
      body: VALID_BODIES.logs!,
      serviceRequest: { ...VALID_BODIES.logs, userId: UID, sessionId: SID },
      response: {
        items: [{ sha: STATUS.headSha, subject: "initial", authoredAt: "2026-10-24T00:00:00.000Z" }],
      },
      network: false,
    },
    {
      operation: "search",
      method: null,
      body: VALID_BODIES.search!,
      serviceRequest: null,
      response: { items: [{ path: "app/README.md", name: "README.md" }], truncated: false },
      network: false,
    },
  ] as const;

  it.each(cases)(
    "POST $operation uses the verified uid, :sid and exact operation DTO",
    async ({ operation, method, body, serviceRequest, response, network }) => {
      const h = harness();
      const res = await post(h.app, operation, body);
      expect(res.statusCode).toBe(200);
      expect(res.json()).toEqual(response);
      expect(JSON.stringify(res.body)).not.toContain(PAT);
      expect(h.resolverCalls).toHaveLength(network ? 1 : 0);
      if (method === null) {
        expect(h.calls).toEqual([]);
        expect(h.attachedUsers).toEqual([UID]);
      } else {
        expect(h.calls).toEqual([{ method, req: serviceRequest }]);
      }
    },
  );

  it.each(Object.keys(VALID_BODIES))("%s rejects missing and wrong internal auth with 401", async (operation) => {
    const h = harness();
    for (const headers of [
      { "x-ovid-user-id": UID },
      { "x-ovid-internal-token": "wrong", "x-ovid-user-id": UID },
      { "x-ovid-internal-token": INTERNAL_TOKEN },
    ]) {
      const res = await post(h.app, operation, VALID_BODIES[operation]!, headers);
      expect(res.statusCode).toBe(401);
      expect(res.json()).toMatchObject({ error: { code: "unauthenticated" } });
    }
    expect(h.calls).toEqual([]);
    expect(h.resolverCalls).toEqual([]);
  });

  it.each(Object.entries(VALID_BODIES))("%s rejects unknown and PAT body keys with 400", async (operation, body) => {
    const h = harness();
    for (const extra of [{ unexpected: true }, { token: PAT }]) {
      const res = await post(h.app, operation, { ...body, ...extra });
      expect(res.statusCode).toBe(400);
      expect(res.json()).toMatchObject({ error: { code: "bad_request" } });
      expect(res.body).not.toContain(PAT);
    }
    expect(h.calls).toEqual([]);
    expect(h.resolverCalls).toEqual([]);
  });

  it.each([
    ["clone", { repo: "" }],
    ["sync", { repoDir: 7 }],
    ["switch-branch", { repoDir: "app", branch: "" }],
    ["inspect", {}],
    ["status", { repoDir: "app", staged: true }],
    ["diff", { repoDir: "app", maxBytes: 262145 }],
    ["logs", { repoDir: "app", limit: 51 }],
    ["search", { repoDir: "app", query: "x", limit: 101 }],
  ])("%s rejects an invalid bounded DTO with 400", async (operation, body) => {
    const h = harness();
    const res = await post(h.app, operation, body);
    expect(res.statusCode).toBe(400);
    expect(res.json()).toMatchObject({ error: { code: "bad_request" } });
    expect(h.calls).toEqual([]);
  });

  it("bounds Studio request bodies below the legacy file-upload ceiling", async () => {
    const h = harness();
    const res = await post(h.app, "search", {
      repoDir: "app",
      query: "x".repeat(70 * 1024),
    });
    expect(res.statusCode).toBe(413);
    expect(h.calls).toEqual([]);
    expect(h.resolverCalls).toEqual([]);
  });

  it("returns a fixed 400 envelope for malformed JSON instead of a raw Fastify error", async () => {
    const h = harness();
    const res = await h.app.inject({
      method: "POST",
      url: `${PREFIX}/clone`,
      headers: {
        "x-ovid-internal-token": INTERNAL_TOKEN,
        "x-ovid-user-id": UID,
        "content-type": "application/json",
      },
      payload: `{"repo":"acme/app","token":"${PAT}"`,
    });
    expect(res.statusCode).toBe(400);
    expect(res.json()).toEqual({ error: { code: "bad_request", message: "Invalid Studio git request." } });
    expect(res.body).not.toContain(PAT);
  });

  it.each(["clone", "sync", "switch-branch", "inspect"])(
    "%s resolves the current user's PAT on every call and refuses a missing one",
    async (operation) => {
      const tokens = ["first-per-call-pat", "second-per-call-pat"];
      const h = harness({
        resolveToken: async (req) => {
          expect(req.userId).toBe(UID);
          return tokens.shift() ?? null;
        },
      });
      expect((await post(h.app, operation, VALID_BODIES[operation]!)).statusCode).toBe(200);
      expect((await post(h.app, operation, VALID_BODIES[operation]!)).statusCode).toBe(200);
      expect(h.calls.map((call) => call.req.token)).toEqual(["first-per-call-pat", "second-per-call-pat"]);
      const refused = await post(h.app, operation, VALID_BODIES[operation]!);
      expect(refused.statusCode).toBe(409);
      expect(refused.json()).toMatchObject({ error: { code: "token_unavailable" } });
      expect(h.calls).toHaveLength(2);
    },
  );

  const refusalCases = [
    ["invalid_repo", 400],
    ["invalid_path", 400],
    ["invalid_branch", 400],
    ["destination_exists", 409],
    ["not_a_repo", 409],
    ["clone_failed", 502],
    ["fetch_failed", 502],
    ["sync_failed", 502],
    ["stash_failed", 409],
    ["switch_failed", 409],
    ["search_failed", 500],
    ["token_unavailable", 409],
  ] as const;

  it.each(refusalCases)("maps %s to a typed %i refusal envelope", async (code, status) => {
    const h = harness({
      git: {
        status: async () => {
          throw new StudioGitError(code, "Safe Studio refusal.", "refs/stash@{0}");
        },
      },
    });
    const res = await post(h.app, "status", VALID_BODIES.status!);
    expect(res.statusCode).toBe(status);
    expect(res.json()).toEqual({
      error: { code, message: "Safe Studio refusal.", stashRef: "refs/stash@{0}" },
    });
  });

  it("production composition uses sealed MCP credentials and never enables file: remotes", async () => {
    const masterKey = "11".repeat(32);
    const crypto = createEnvelopeCrypto(masterKey);
    const rowId = "00000000-0000-4000-8000-000000000099";
    const listUsers: string[] = [];
    const root = mkdtempSync(join("/tmp/opencode/", "ovid-studio-production-compose-"));
    roots.push(root);
    const manager = {
      attach: async (userId: string) => ({
        userId,
        uid: typeof process.getuid === "function" ? process.getuid() : 0,
        workspaceDir: join(root, "workspace"),
        homeDir: join(root, "home"),
        jailWorkspaceDir: "/workspace",
      }),
    } as unknown as Pick<SandboxManager, "attach">;
    const studioGit = createStudioGitService({
      manager,
      masterKey,
      allowedHosts: parseStudioGitAllowedHosts(undefined),
      listServers: async (userId) => {
        listUsers.push(userId);
        return userId === UID
          ? [{
              id: rowId,
              curatedId: "github",
              enabled: true,
              secretsSealed: crypto.encrypt(
                JSON.stringify({ GITHUB_TOKEN: PAT }),
                `mcp_servers:${rowId}`,
              ),
            }]
          : [];
      },
    });
    const app = buildFileService({
      internalToken: INTERNAL_TOKEN,
      inlineMaxBytes: 1024,
      port: 0,
      workspacesRoot: join(root, "workspace"),
      studioGit,
    } as FileServiceDeps);
    apps.push(app);

    const res = await post(app, "clone", { repo: "file:///tmp/production-must-not-clone.git" });
    expect(res.statusCode).toBe(400);
    expect(res.json()).toMatchObject({ error: { code: "invalid_repo" } });
    expect(listUsers).toEqual([UID]);
    expect(res.body).not.toContain(PAT);
    expect(parseStudioGitAllowedHosts(undefined)).toEqual(["github.com"]);
    expect(parseStudioGitAllowedHosts(" github.com, git.corp.example ")).toEqual([
      "github.com",
      "git.corp.example",
    ]);
  });

  it("emits a safe typed refusal for the real Git credential scanner error", async () => {
    const h = harness({
      git: {
        clone: async () => {
          throw new GitCredentialLeakError(`.git/config ${PAT}`);
        },
      },
    });
    const res = await post(h.app, "clone", VALID_BODIES.clone!);
    expect(res.statusCode).toBe(500);
    expect(res.json()).toEqual({
      error: {
        code: "credential_leak",
        message: "Studio git stopped because it detected a credential leak.",
      },
    });
    expect(res.body).not.toContain(PAT);
    expect(res.body).not.toContain(".git/config");
  });

  it("does not forward arbitrary provider errors", async () => {
    const h = harness({
      git: {
        status: async () => {
          throw new Error(`provider payload ${PAT}`);
        },
      },
    });
    const res = await post(h.app, "status", VALID_BODIES.status!);
    expect(res.statusCode).toBe(500);
    expect(res.json()).toEqual({ error: { code: "internal", message: "Internal server error." } });
    expect(res.body).not.toContain(PAT);
  });
});
