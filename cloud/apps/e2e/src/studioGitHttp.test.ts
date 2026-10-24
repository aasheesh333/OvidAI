import { execFile } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import { Writable } from "node:stream";
import { promisify } from "node:util";
import { afterEach, describe, expect, it } from "vitest";
import type { SandboxManager } from "@ovid/sandbox";
import { GitCredentialLeakError } from "@ovid/sandbox/gitCredential";
import { schema, type Db } from "@ovid/db";
import { createEnvelopeCrypto } from "@ovid/escrow";

import { buildGateway } from "../../gateway/src/app.js";
import { createTestVerifier } from "../../gateway/src/auth.js";
import { createStudioGitHttpTransport } from "../../gateway/src/studioGitHttp.js";
import { StudioGitRefusal } from "../../gateway/src/studioGit.js";
import {
  authHeaders,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubSystemBus,
  stubTickets,
} from "../../gateway/src/test/stubs.js";
import { buildFileService, type FileServiceDeps } from "../../worker/src/fileService.js";
import {
  createPerUserGithubTokenResolver,
  createStudioGit,
  type GitRunner,
} from "../../worker/src/studioGit.js";
import {
  createStudioGitService,
  type StudioGitRoutesDeps,
} from "../../worker/src/studioGitRoutes.js";

const execFileAsync = promisify(execFile);
const INTERNAL_TOKEN = "internal-real-socket-studio-test";
const PAT = "ghp_real_socket_secret_1234567890";
const OTHER_PAT = "ghp_other_user_secret_1234567890";
const MASTER_KEY = "22".repeat(32);
const UID = "real-socket-user";
const SID = "00000000-0000-4000-8000-000000000003";
const GIT_ENV: NodeJS.ProcessEnv = {
  ...process.env,
  GIT_CONFIG_NOSYSTEM: "1",
  GIT_CONFIG_GLOBAL: "/dev/null",
  GIT_TERMINAL_PROMPT: "0",
  GIT_AUTHOR_NAME: "Ovid Test",
  GIT_AUTHOR_EMAIL: "test@ovid.invalid",
  GIT_COMMITTER_NAME: "Ovid Test",
  GIT_COMMITTER_EMAIL: "test@ovid.invalid",
};

async function git(cwd: string, ...args: string[]): Promise<string> {
  const { stdout } = await execFileAsync("git", args, { cwd, env: GIT_ENV });
  return stdout;
}

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

async function realSocketFixture(opts: {
  allowLocalUrls: boolean;
  pat?: string | null;
  leakOnClone?: boolean;
}) {
  const root = await mkdtemp(join("/tmp/opencode/", "ovid-studio-http-e2e-"));
  cleanups.push(async () => rm(root, { recursive: true, force: true }));
  const homeDir = join(root, "home");
  const workspaceDir = join(root, "workspace");
  const credentialDir = join(root, "credential");
  await Promise.all([
    mkdir(homeDir, { recursive: true }),
    mkdir(workspaceDir, { recursive: true }),
    mkdir(credentialDir, { recursive: true }),
  ]);

  const remote = join(root, "app.git");
  await git(root, "init", "--bare", "-b", "main", "app.git");
  const seed = join(root, "seed");
  await git(root, "init", "-b", "main", "seed");
  await writeFile(join(seed, "README.md"), "hello\n");
  await git(seed, "add", ".");
  await git(seed, "commit", "-m", "initial");
  const remoteUrl = `file://${remote}`;
  await git(seed, "remote", "add", "origin", remoteUrl);
  await git(seed, "push", "-u", "origin", "main");
  await git(seed, "branch", "feature");
  await git(seed, "push", "-u", "origin", "feature");

  const handle = {
    userId: UID,
    uid: typeof process.getuid === "function" ? process.getuid() : 0,
    workspaceDir,
    homeDir,
    jailWorkspaceDir: "/workspace",
  };
  const manager = {
    attach: async () => handle,
  } as unknown as Pick<SandboxManager, "attach">;
  const logs: string[] = [];
  const crypto = createEnvelopeCrypto(MASTER_KEY);
  const githubRowId = "00000000-0000-4000-8000-000000000091";
  const otherRowId = "00000000-0000-4000-8000-000000000092";
  const resolverCalls: string[] = [];
  const leakingCloneRunner: GitRunner = async (req) => {
    if (!req.argv.includes("clone")) throw new Error("leak fixture only runs clone");
    const stagingFd = req.fds?.[0];
    if (stagingFd === undefined) throw new Error("clone staging fd is required");
    const stagedGitDir = `/proc/self/fd/${stagingFd}/.git`;
    await mkdir(stagedGitDir, { recursive: true });
    await writeFile(
      join(stagedGitDir, "config"),
      `[remote "origin"]\n\turl = https://x-access-token:${PAT}@github.com/acme/app.git\n`,
    );
    return { code: 128, stdout: "", stderr: "clone failed", timedOut: false };
  };
  const listServers = async (userId: string) => {
    resolverCalls.push(userId);
    if (userId !== UID) return [];
    const pat = opts.pat === undefined ? PAT : opts.pat;
    return [
      {
        id: otherRowId,
        curatedId: "other",
        enabled: true,
        secretsSealed: crypto.encrypt(
          JSON.stringify({ GITHUB_TOKEN: OTHER_PAT }),
          `mcp_servers:${otherRowId}`,
        ),
      },
      {
        id: githubRowId,
        curatedId: "github",
        enabled: true,
        secretsSealed: crypto.encrypt(
          JSON.stringify(pat === null ? {} : { GITHUB_TOKEN: pat }),
          `mcp_servers:${githubRowId}`,
        ),
      },
    ];
  };
  const decrypt = (sealed: unknown, recordId: string): string =>
    crypto.decrypt(sealed as Parameters<typeof crypto.decrypt>[0], recordId);
  const workerErrors: unknown[] = [];
  const localStudio = opts.allowLocalUrls
    ? createStudioGit({
        manager,
        credentialDir,
        allowLocalUrls: true,
        log: (line) => logs.push(line),
        ...(opts.leakOnClone === true ? { runner: leakingCloneRunner } : {}),
      })
    : undefined;
  const observedGit = localStudio === undefined
    ? undefined
    : {
        ...localStudio,
        clone: async (req: Parameters<typeof localStudio.clone>[0]) => {
          try {
            return await localStudio.clone(req);
          } catch (err) {
            workerErrors.push(err);
            throw err;
          }
        },
      };
  const studioGit: StudioGitRoutesDeps = opts.allowLocalUrls
    ? {
        manager,
        git: observedGit!,
        resolveToken: createPerUserGithubTokenResolver({ listServers, decrypt }),
      }
    : createStudioGitService({
        manager,
        masterKey: MASTER_KEY,
        listServers,
        allowedHosts: ["github.com"],
      });
  const app = buildFileService({
    internalToken: INTERNAL_TOKEN,
    inlineMaxBytes: 1024,
    port: 0,
    workspacesRoot: workspaceDir,
    studioGit,
  } as FileServiceDeps);
  await app.listen({ host: "127.0.0.1", port: 0 });
  cleanups.push(async () => app.close());
  const baseUrl = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`;

  const captured: Array<Record<string, unknown>> = [];
  const captureFetch = (async (input: string | URL | Request, init?: RequestInit) => {
    captured.push({
      direction: "request",
      url: String(input),
      headers: init?.headers,
      body: init?.body,
    });
    const response = await globalThis.fetch(input, init);
    const body = await response.text();
    captured.push({ direction: "response", status: response.status, body });
    return new Response(body, {
      status: response.status,
      statusText: response.statusText,
      headers: response.headers,
    });
  }) as typeof fetch;
  const transport = createStudioGitHttpTransport({
    baseUrl,
    token: INTERNAL_TOKEN,
    timeoutMs: 30_000,
    fetch: captureFetch,
  }).forUser(UID);
  return { transport, root, workspaceDir, logs, resolverCalls, captured, remoteUrl, workerErrors };
}

/** Only the real session/MCP/binding reads used by the public Studio clone route. */
function publicCloneDb(): Db {
  const crypto = createEnvelopeCrypto(MASTER_KEY);
  const githubRow = {
    id: "00000000-0000-4000-8000-000000000093",
    userId: UID,
    name: "github",
    transport: "native",
    curatedId: "github",
    config: null,
    enabled: true,
    secretsSealed: crypto.encrypt(
      JSON.stringify({ GITHUB_TOKEN: PAT }),
      "mcp_servers:00000000-0000-4000-8000-000000000093",
    ),
    createdAt: new Date(),
    updatedAt: new Date(),
  };
  const session = {
    id: SID,
    userId: UID,
    title: "studio",
    mode: "studio",
    projectId: null,
    createdAt: new Date(),
    updatedAt: new Date(),
    archivedAt: null,
    pinnedAt: null,
    deletedAt: null,
  };
  return {
    select: () => ({
      from: (table: unknown) => {
        const rows = table === schema.sessions
          ? [session]
          : table === schema.mcpServers
            ? [githubRow]
            : [];
        return {
          where: () => ({
            limit: async () => rows,
            orderBy: async () => rows,
          }),
          orderBy: async () => rows,
        };
      },
    }),
    insert: () => ({
      values: (values: Record<string, unknown>) => ({
        onConflictDoUpdate: () => ({ returning: async () => [values] }),
      }),
    }),
  } as unknown as Db;
}

describe("Studio git real HTTP + git round trip", () => {
  it("runs authenticated clone/sync/switch/inspect and local reads through the sealed UID resolver", async () => {
    const fx = await realSocketFixture({ allowLocalUrls: true });
    const request = { userId: UID, sessionId: SID };

    await expect(fx.transport.clone({ ...request, repo: fx.remoteUrl, dest: "app" })).resolves.toEqual({
      repoDir: "app",
      branch: "main",
    });
    expect(await readFile(join(fx.workspaceDir, "app", "README.md"), "utf8")).toBe("hello\n");
    expect(fx.resolverCalls).toEqual([UID]);

    const callsBeforeMismatch = fx.captured.length;
    await expect(fx.transport.status({ userId: "different-user", sessionId: SID, repoDir: "app" }))
      .rejects.toMatchObject({ name: "StudioGitRefusal", code: "invalid_path" });
    expect(fx.captured).toHaveLength(callsBeforeMismatch);
    expect(fx.resolverCalls).toEqual([UID]);

    await expect(fx.transport.sync({ ...request, repoDir: "app" })).resolves.toMatchObject({
      status: "up_to_date",
      branch: "main",
    });
    expect(fx.resolverCalls).toEqual([UID, UID]);
    await expect(fx.transport.switchBranch({ ...request, repoDir: "app", branch: "feature" }))
      .resolves.toMatchObject({ status: "switched", branch: "feature", stashed: false });
    expect(fx.resolverCalls).toEqual([UID, UID, UID]);

    const status = await fx.transport.status({ ...request, repoDir: "app" });
    expect(status).toMatchObject({ branch: "feature", upstream: "origin/feature", dirty: false, ahead: 0, behind: 0 });
    expect(status.headSha).toMatch(/^[0-9a-f]{40}$/);
    expect(fx.resolverCalls).toHaveLength(3);

    await writeFile(join(fx.workspaceDir, "app", "README.md"), "hello\nchanged\n");
    const diff = await fx.transport.diff({ ...request, repoDir: "app", path: "README.md", maxBytes: 4096 });
    expect(diff.truncated).toBe(false);
    expect(diff.patch).toContain("+changed");
    expect(fx.resolverCalls).toHaveLength(3);

    const logs = await fx.transport.logs({ ...request, repoDir: "app", limit: 10 });
    expect(logs.items).toHaveLength(1);
    expect(logs.items[0]).toMatchObject({ sha: status.headSha, subject: "initial" });
    expect(fx.resolverCalls).toHaveLength(3);

    const search = await fx.transport.search({ ...request, repoDir: "app", query: "readme", limit: 10 });
    expect(search).toEqual({ items: [{ path: "app/README.md", name: "README.md" }], truncated: false });
    expect(fx.resolverCalls).toHaveLength(3);

    const inspected = await fx.transport.inspect({ ...request, repoDir: "app" });
    expect(inspected).toMatchObject({ branch: "feature", dirty: true });
    expect(inspected.fetchedAt).toEqual(expect.any(String));
    expect(fx.resolverCalls).toEqual([UID, UID, UID, UID]);

    const config = await readFile(join(fx.workspaceDir, "app", ".git", "config"), "utf8");
    expect(config).not.toContain(PAT);
    expect(JSON.stringify({ captured: fx.captured, logs: fx.logs })).not.toContain(PAT);
    expect(JSON.stringify({ captured: fx.captured, logs: fx.logs })).not.toContain(OTHER_PAT);
  }, 60_000);

  it("refuses every network operation when the verified user has no sealed PAT", async () => {
    const fx = await realSocketFixture({ allowLocalUrls: true, pat: null });
    const request = { userId: UID, sessionId: SID, repoDir: "app" };
    const attempts = [
      () => fx.transport.clone({ userId: UID, sessionId: SID, repo: fx.remoteUrl, dest: "app" }),
      () => fx.transport.sync(request),
      () => fx.transport.switchBranch({ ...request, branch: "feature" }),
      () => fx.transport.inspect(request),
    ];
    for (const attempt of attempts) {
      const promise = attempt();
      await expect(promise).rejects.toBeInstanceOf(StudioGitRefusal);
      await expect(promise).rejects.toMatchObject({ code: "token_unavailable" });
    }
    expect(fx.resolverCalls).toEqual([UID, UID, UID, UID]);
    await expect(readFile(join(fx.workspaceDir, "app", "README.md"), "utf8")).rejects.toMatchObject({
      code: "ENOENT",
    });
    expect(JSON.stringify(fx.captured)).not.toContain(OTHER_PAT);
  }, 60_000);

  it("maps the real credential scanner error to public 500 internal and logs the incident safely", async () => {
    const fx = await realSocketFixture({ allowLocalUrls: true, leakOnClone: true });
    const publicLogs: string[] = [];
    const logStream = new Writable({
      write(chunk, _encoding, callback) {
        publicLogs.push(String(chunk));
        callback();
      },
    });
    const publicApp = buildGateway({
      db: publicCloneDb(),
      queues: stubQueues().queues,
      verifier: createTestVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      system: stubSystemBus(),
      crypto: createEnvelopeCrypto(MASTER_KEY),
      studioGit: fx.transport,
    }, { logger: { level: "error", stream: logStream } });
    cleanups.push(async () => publicApp.close());

    const res = await publicApp.inject({
      method: "POST",
      url: `/cloud/v1/studio/sessions/${SID}/git/clone`,
      headers: authHeaders(UID),
      payload: { repo: "acme/app" },
    });
    expect(res.statusCode).toBe(500);
    expect(res.json()).toEqual({ error: { code: "internal", message: "Internal server error." } });
    expect(fx.workerErrors).toHaveLength(1);
    expect(fx.workerErrors[0]).toBeInstanceOf(GitCredentialLeakError);
    expect(fx.captured).toContainEqual(expect.objectContaining({
      direction: "response",
      status: 500,
    }));
    expect(publicLogs.join("")).toContain("studio git reported a credential leak");
    expect(JSON.stringify({ response: res.body, publicLogs, captured: fx.captured })).not.toContain(PAT);
    expect(JSON.stringify({ response: res.body, publicLogs, captured: fx.captured })).not.toContain(OTHER_PAT);
  }, 60_000);

  it("production git configuration refuses file: URLs instead of cloning them", async () => {
    const fx = await realSocketFixture({ allowLocalUrls: false });
    const promise = fx.transport.clone({ userId: UID, sessionId: SID, repo: fx.remoteUrl, dest: "app" });
    await expect(promise).rejects.toBeInstanceOf(StudioGitRefusal);
    await expect(promise).rejects.toMatchObject({ code: "invalid_repo" });
    await expect(readFile(join(fx.workspaceDir, "app", "README.md"), "utf8")).rejects.toMatchObject({
      code: "ENOENT",
    });
    expect(JSON.stringify({ captured: fx.captured, logs: fx.logs })).not.toContain(PAT);
  }, 60_000);
});
