import { execFile } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, renameSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { promisify } from "node:util";
import { afterAll, describe, expect, it } from "vitest";
import type { SandboxManager } from "@ovid/sandbox";

import {
  StudioGitError,
  assertSafeBranch,
  createPerUserGithubTokenResolver,
  createSpawnGitRunner,
  createStudioGit,
  defaultRepoDir,
  normalizeRepoUrl,
  safeRelDir,
  safeRepoDirName,
  type GitCommandRequest,
  type GitRunner,
} from "./studioGit.js";

const execFileAsync = promisify(execFile);
const TOKEN = "ghp_worker_studio_token_abcdef123456";

const roots: string[] = [];
afterAll(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

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

function uid(): number {
  return typeof process.getuid === "function" ? process.getuid() : 0;
}

interface Fixture {
  root: string;
  home: string;
  workspace: string;
  helperDir: string;
  remote: string;
  remoteUrl: string;
  seed: string;
  manager: Pick<SandboxManager, "attach">;
}

async function fixture(): Promise<Fixture> {
  const root = mkdtempSync(join(tmpdir(), "ovid-studio-git-"));
  roots.push(root);
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const helperDir = join(root, "git-helper");
  mkdirSync(home, { recursive: true });
  mkdirSync(workspace, { recursive: true });
  mkdirSync(helperDir, { recursive: true });

  const remote = join(root, "app.git");
  await git(root, "init", "--bare", "-b", "main", "app.git");

  const seed = join(root, "seed");
  await git(root, "init", "-b", "main", "seed");
  writeFileSync(join(seed, "README.md"), "hello\n");
  await git(seed, "add", ".");
  await git(seed, "commit", "-m", "initial");
  const remoteUrl = `file://${remote}`;
  await git(seed, "remote", "add", "origin", remoteUrl);
  await git(seed, "push", "-u", "origin", "main");

  const handle = {
    userId: "user-1",
    uid: uid(),
    workspaceDir: workspace,
    homeDir: home,
    jailWorkspaceDir: "/workspace",
  };
  const manager = {
    attach: async () => handle,
  } as unknown as Pick<SandboxManager, "attach">;

  return { root, home, workspace, helperDir, remote, remoteUrl, seed, manager };
}

/** Records every git request and delegates to the real direct-spawn runner. */
function recordingRunner(): {
  runner: GitRunner;
  calls: GitCommandRequest[];
  envDuring: Array<Record<string, string>>;
  envRefs: Array<Record<string, string>>;
  askpass: Array<{ path: string; existed: boolean; mode: number }>;
} {
  const calls: GitCommandRequest[] = [];
  const envDuring: Array<Record<string, string>> = [];
  const envRefs: Array<Record<string, string>> = [];
  const askpass: Array<{ path: string; existed: boolean; mode: number }> = [];
  const real = createSpawnGitRunner();
  const runner: GitRunner = async (req) => {
    envDuring.push({ ...req.env });
    envRefs.push(req.env);
    // Keep the live env reference in calls: after disposal, serializing the
    // complete call/log/result record must not reveal the ephemeral secret.
    calls.push({ ...req, argv: [...req.argv], env: req.env });
    const path = req.env.GIT_ASKPASS;
    if (path !== undefined) {
      askpass.push({
        path,
        existed: existsSync(path),
        mode: existsSync(path) ? statSync(path).mode & 0o777 : 0,
      });
    }
    return real(req);
  };
  return { runner, calls, envDuring, envRefs, askpass };
}

async function cloneFixture(fx: Fixture, extra: { log?: (l: string) => void; runner?: GitRunner } = {}) {
  const gitJob = createStudioGit({
    manager: fx.manager,
    allowLocalUrls: true,
    credentialDir: fx.helperDir,
    ...(extra.runner !== undefined ? { runner: extra.runner } : {}),
    ...(extra.log !== undefined ? { log: extra.log } : {}),
  });
  const result = await gitJob.clone({ userId: "user-1", repo: fx.remoteUrl, token: TOKEN });
  return { gitJob, result };
}

function configText(repo: string): string {
  return readFileSync(join(repo, ".git", "config"), "utf8");
}

/** Host path of the destination used by a clone request in either design. */
function operationCloneDir(req: GitCommandRequest): string {
  const inherited = req.fds?.[0];
  if (inherited !== undefined) return `/proc/self/fd/${inherited}`;
  return resolve(req.cwd, req.argv[req.argv.length - 1]!);
}

function expectSafeArgv(calls: readonly GitCommandRequest[]): void {
  for (const call of calls) {
    expect(call.argv).not.toContain("--force");
    expect(call.argv).not.toContain("reset");
    expect(call.argv).not.toContain("--hard");
  }
}

interface CredentialTrap {
  url: string;
  readonly contacts: number;
  readonly sawToken: boolean;
  close(): Promise<void>;
}

/** A real loopback HTTP auth challenge; records booleans, never credentials. */
async function credentialTrap(): Promise<CredentialTrap> {
  let contacts = 0;
  let sawToken = false;
  const server = createServer((req, res) => {
    contacts += 1;
    const authorization = req.headers.authorization;
    if (authorization?.startsWith("Basic ")) {
      const decoded = Buffer.from(authorization.slice(6), "base64").toString("utf8");
      if (decoded.includes(TOKEN)) sawToken = true;
    }
    res.writeHead(401, { "WWW-Authenticate": 'Basic realm="studio-test"' });
    res.end();
  });
  await new Promise<void>((resolveListen, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolveListen());
  });
  const address = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${address.port}/attacker.git`,
    get contacts() {
      return contacts;
    },
    get sawToken() {
      return sawToken;
    },
    close: async () => {
      server.closeAllConnections();
      await new Promise<void>((resolveClose, reject) => {
        server.close((err) => (err === undefined ? resolveClose() : reject(err)));
      });
    },
  };
}

async function refExists(repo: string, ref: string): Promise<boolean> {
  try {
    await git(repo, "rev-parse", "--verify", "--quiet", ref);
    return true;
  } catch {
    return false;
  }
}

describe("Studio clone", () => {
  it("clones with an ephemeral askpass helper and leaves no token in calls, config, response or logs", async () => {
    const fx = await fixture();
    const logs: string[] = [];
    const rec = recordingRunner();
    const calls = rec.calls;
    const { gitJob, result } = await cloneFixture(fx, {
      runner: rec.runner,
      log: (l) => logs.push(l),
    });

    expect(result).toEqual({ status: "cloned", repoDir: "app", branch: "main" });
    expect(readFileSync(join(fx.workspace, "app", "README.md"), "utf8")).toBe("hello\n");

    const config = configText(join(fx.workspace, "app"));
    expect(config).not.toContain(TOKEN);
    expect(config).toMatch(/url = file:\/\//);

    expect(rec.calls.length).toBeGreaterThan(0);
    for (const call of rec.calls) {
      for (const arg of call.argv) expect(arg).not.toContain(TOKEN);
    }
    for (const [index, env] of rec.envDuring.entries()) {
      const argv = rec.calls[index]!.argv;
      const network = argv.includes("clone") || argv.includes("fetch");
      if (network) {
        expect(env.GIT_ASKPASS).toBeDefined();
        expect(env.GIT_TERMINAL_PROMPT).toBe("0");
        expect(env.OVID_GIT_TOKEN).toBe(TOKEN);
      } else {
        expect(env.GIT_ASKPASS).toBeUndefined();
        expect(env.OVID_GIT_TOKEN).toBeUndefined();
      }
    }
    for (const ref of rec.envRefs) {
      expect(ref.OVID_GIT_TOKEN).toBeUndefined();
      expect(ref.GIT_ASKPASS).toBeUndefined();
    }

    expect(rec.askpass.length).toBeGreaterThan(0);
    for (const seen of rec.askpass) {
      expect(seen.existed).toBe(true);
      expect(seen.mode & 0o022).toBe(0);
      expect(seen.mode & 0o111).not.toBe(0);
    }

    expect(existsSync(join(fx.home, ".ovid"))).toBe(false);
    expect(existsSync(fx.helperDir)).toBe(true);
    expect(readdirSync(fx.helperDir)).toEqual([]);

    expect(logs.length).toBeGreaterThan(0);
    expect(JSON.stringify({ calls, logs, result })).not.toContain(TOKEN);
    expectSafeArgv(calls);

    const status = await gitJob.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN });
    expect(status.status).toBe("up_to_date");
    expect(JSON.stringify({ calls, logs, result })).not.toContain(TOKEN);
    expectSafeArgv(calls);
  });

  it("removes the askpass helper and partial destination when clone fails, with safe logs and errors", async () => {
    const fx = await fixture();
    const logs: string[] = [];
    const calls: GitCommandRequest[] = [];
    let result: unknown;
    const failing: GitRunner = async (req) => {
      calls.push({ ...req, argv: [...req.argv], env: req.env });
      if (req.argv.includes("clone")) {
        const partial = operationCloneDir(req);
        mkdirSync(join(partial, ".git"), { recursive: true });
        writeFileSync(
          join(partial, ".git", "config"),
          '[remote "origin"]\n\turl = https://github.com/acme/app.git\n',
        );
        return {
          code: 128,
          stdout: "",
          stderr: `fatal: could not read Password for 'https://x-access-token:${TOKEN}@github.com/acme/app.git'`,
          timedOut: false,
        };
      }
      return { code: 0, stdout: "", stderr: "", timedOut: false };
    };
    const gitJob = createStudioGit({
      manager: fx.manager,
      allowLocalUrls: true,
      credentialDir: fx.helperDir,
      runner: failing,
      log: (l) => logs.push(l),
    });

    let caught: unknown;
    try {
      result = await gitJob.clone({ userId: "user-1", repo: fx.remoteUrl, token: TOKEN });
    } catch (err) {
      caught = err;
    }
    expect(caught).toBeInstanceOf(StudioGitError);
    expect((caught as StudioGitError).code).toBe("clone_failed");
    expect((caught as Error).message).not.toContain(TOKEN);
    expect((caught as Error).message).not.toContain("github.com/acme/app");
    expect((caught as Error).message).toMatch(/Could not clone the repository/);
    expect(JSON.stringify({ calls, logs, result })).not.toContain(TOKEN);

    expect(readdirSync(fx.helperDir)).toEqual([]);
    expect(existsSync(join(fx.workspace, "app"))).toBe(false);
    expectSafeArgv(calls);
  });

  it.each([0, 128])("scans for leaks when clone exits %i, then cleans helper and destination", async (cloneCode) => {
    const fx = await fixture();
    const logs: string[] = [];
    const calls: GitCommandRequest[] = [];
    let result: unknown;
    const runner: GitRunner = async (req) => {
      calls.push({ ...req, argv: [...req.argv], env: req.env });
      if (req.argv.includes("clone")) {
        const partial = operationCloneDir(req);
        mkdirSync(join(partial, ".git"), { recursive: true });
        writeFileSync(
          join(partial, ".git", "config"),
          `[remote "origin"]\n\turl = https://x-access-token:${TOKEN}@github.com/acme/app.git\n`,
        );
        return { code: cloneCode, stdout: "", stderr: "clone failed safely", timedOut: false };
      }
      return { code: 0, stdout: "main\n", stderr: "", timedOut: false };
    };
    const gitJob = createStudioGit({
      manager: fx.manager,
      allowLocalUrls: true,
      credentialDir: fx.helperDir,
      runner,
      log: (line) => logs.push(line),
    });

    let caught: unknown;
    try {
      result = await gitJob.clone({ userId: "user-1", repo: fx.remoteUrl, token: TOKEN });
    } catch (err) {
      caught = err;
    }
    expect(caught).toMatchObject({ code: "credential_leak" });
    expect((caught as Error).message).not.toContain(TOKEN);
    expect(JSON.stringify({ calls, logs, result })).not.toContain(TOKEN);
    expect(readdirSync(fx.helperDir)).toEqual([]);
    expect(existsSync(join(fx.workspace, "app"))).toBe(false);
  });

  it("refuses an existing destination and never deletes it", async () => {
    const fx = await fixture();
    mkdirSync(join(fx.workspace, "app"));
    writeFileSync(join(fx.workspace, "app", "keep.txt"), "keep\n");
    const gitJob = createStudioGit({ manager: fx.manager, allowLocalUrls: true });

    await expect(
      gitJob.clone({ userId: "user-1", repo: fx.remoteUrl, token: TOKEN }),
    ).rejects.toMatchObject({ code: "destination_exists" });
    expect(readFileSync(join(fx.workspace, "app", "keep.txt"), "utf8")).toBe("keep\n");
  });

  it("rejects credential-bearing and non-https repository URLs", () => {
    expect(normalizeRepoUrl("acme/app")).toBe("https://github.com/acme/app.git");
    expect(normalizeRepoUrl("https://github.com/acme/app.git")).toBe(
      "https://github.com/acme/app.git",
    );
    expect(() => normalizeRepoUrl(`https://x-access-token:${TOKEN}@github.com/acme/app.git`)).toThrow(
      /credential/,
    );
    expect(() => normalizeRepoUrl("http://github.com/acme/app.git")).toThrow(/https only/);
    expect(() => normalizeRepoUrl("git@github.com:acme/app.git")).toThrow(/not a URL/);
    expect(() => normalizeRepoUrl("file:///tmp/only-in-isolated-tests.git")).toThrow(/https only/);
    expect(() => normalizeRepoUrl("https://github.com/acme/app.git", {})).not.toThrow();
    expect(defaultRepoDir("https://github.com/acme/app.git")).toBe("app");
  });

  it("refuses a non-approved host so the token cannot answer an attacker's challenge", () => {
    for (const url of [
      "https://evil.example/acme/app.git",
      "https://github.com.evil.example/acme/app.git",
      "https://githubXcom/acme/app.git",
      "https://github.com:444/acme/app.git",
      "https://github.com/acme/app.git?access_token=stolen",
    ]) {
      expect(() => normalizeRepoUrl(url)).toThrow(/approved git host|unexpected parameters|default https port/);
    }

    const opts = { allowedHosts: ["github.com", "git.corp.example"] };
    expect(normalizeRepoUrl("https://git.corp.example/acme/app.git", opts)).toBe(
      "https://git.corp.example/acme/app.git",
    );
    expect(() => normalizeRepoUrl("https://evil.example/acme/app.git", opts)).toThrow(
      /approved git host/,
    );
  });

  it("logs only host + repo (never the full local URL)", async () => {
    const fx = await fixture();
    const logs: string[] = [];
    const { gitJob } = await cloneFixture(fx, { log: (l) => logs.push(l) });
    await gitJob.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN });
    const start = logs.find((line) => line.includes("clone start"));
    expect(start).toBeDefined();
    expect(start).toContain("local/app");
    expect(start).not.toContain(fx.remoteUrl);
  });
});

describe("Sync latest changes", () => {
  it("fetches and fast-forwards a clean tree", async () => {
    const fx = await fixture();
    const logs: string[] = [];
    const rec = recordingRunner();
    const calls = rec.calls;
    const { gitJob } = await cloneFixture(fx, {
      runner: rec.runner,
      log: (line) => logs.push(line),
    });

    writeFileSync(join(fx.seed, "next.txt"), "remote change\n");
    await git(fx.seed, "add", ".");
    await git(fx.seed, "commit", "-m", "remote change");
    await git(fx.seed, "push", "origin", "main");

    const result = await gitJob.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN });
    expect(result).toMatchObject({ status: "synced", dirty: false, behind: 1, branch: "main" });
    expect(readFileSync(join(fx.workspace, "app", "next.txt"), "utf8")).toBe("remote change\n");

    const again = await gitJob.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN });
    expect(again.status).toBe("up_to_date");

    expectSafeArgv(calls);
    expect(configText(join(fx.workspace, "app"))).not.toContain(TOKEN);
    for (const ref of rec.envRefs) {
      expect(ref.OVID_GIT_TOKEN).toBeUndefined();
      expect(ref.GIT_ASKPASS).toBeUndefined();
    }
    expect(readdirSync(fx.helperDir)).toEqual([]);
    expect(JSON.stringify({ calls, logs, result })).not.toContain(TOKEN);

    const fetchCall = calls.find((call) => call.argv.includes("fetch"));
    expect(fetchCall).toBeDefined();
    expect(fetchCall!.argv.join("\n")).toContain(`remote.origin.url=${fx.remoteUrl}`);
  });

  it("forces TLS verification and disables repo-controlled proxies on https remotes", async () => {
    const fx = await fixture();
    mkdirSync(join(fx.workspace, "fake", ".git"), { recursive: true });
    const calls: GitCommandRequest[] = [];
    const runner: GitRunner = async (req) => {
      calls.push({ ...req, env: req.env });
      if (req.argv.includes("config") || req.argv.includes("get-url")) {
        return {
          code: 0,
          stdout: "https://github.com/acme/app.git\n",
          stderr: "",
          timedOut: false,
        };
      }
      if (req.argv.includes("status")) {
        return { code: 0, stdout: "", stderr: "", timedOut: false };
      }
      return { code: 128, stdout: "", stderr: "fatal: no network in test", timedOut: false };
    };
    const gitJob = createStudioGit({
      manager: fx.manager,
      credentialDir: fx.helperDir,
      runner,
      log: () => {},
    });

    await expect(
      gitJob.syncLatest({ userId: "user-1", repoDir: "fake", token: TOKEN }),
    ).rejects.toMatchObject({ code: "fetch_failed" });

    const fetchCall = calls.find((call) => call.argv.includes("fetch"));
    expect(fetchCall).toBeDefined();
    const argv = fetchCall!.argv.join("\n");
    expect(argv).toContain("remote.origin.url=https://github.com/acme/app.git");
    expect(argv).toContain("http.sslVerify=true");
    expect(argv).toContain("http.https://github.com/acme/app.git.sslVerify=true");
    expect(argv).toContain("http.proxy=");
    expect(argv).toContain("remote.origin.proxy=");
    expect(argv).not.toContain("sslVerify=false");
  });

  it("refuses an agent-edited origin instead of redirecting the token", async () => {
    const fx = await fixture();
    const rec = recordingRunner();
    const { gitJob } = await cloneFixture(fx, { runner: rec.runner });
    const repo = join(fx.workspace, "app");
    const config = configText(repo).replace(
      /url = .*/,
      "url = https://evil.example/acme/app.git",
    );
    writeFileSync(join(repo, ".git", "config"), config);

    const before = rec.calls.length;
    await expect(
      gitJob.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN }),
    ).rejects.toMatchObject({ code: "fetch_failed" });

    for (const call of rec.calls.slice(before)) {
      expect(call.argv.join(" ")).not.toContain("evil.example");
    }
  });

  it("refuses a hostile url.insteadOf rewrite before it can execute", async () => {
    const fx = await fixture();
    const rec = recordingRunner();
    const { gitJob } = await cloneFixture(fx, { runner: rec.runner });
    const repo = join(fx.workspace, "app");
    const sentinel = join(fx.root, "hostile-instead-of-executed");
    const hostileHelper = join(fx.root, "hostile-remote-helper");
    writeFileSync(hostileHelper, `#!/bin/sh\n: > "${sentinel}"\nexit 1\n`, { mode: 0o755 });
    const config =
      configText(repo) +
      `[url "ext::${hostileHelper}"]\n\tinsteadOf = ${fx.remoteUrl}\n` +
      '[protocol "ext"]\n\tallow = always\n';
    writeFileSync(join(repo, ".git", "config"), config);

    const before = rec.calls.length;
    await expect(
      gitJob.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN }),
    ).rejects.toMatchObject({ code: "fetch_failed" });
    expect(existsSync(sentinel)).toBe(false);
    expect(rec.calls.slice(before).some((call) => call.argv.includes("fetch"))).toBe(false);
  });

  it("refuses a symlinked .git instead of reading/writing outside the workspace", async () => {
    const fx = await fixture();
    const { gitJob } = await cloneFixture(fx);
    const repo = join(fx.workspace, "app");
    rmSync(join(repo, ".git"), { recursive: true, force: true });
    symlinkSync(fx.remote, join(repo, ".git"), "dir");

    await expect(
      gitJob.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN }),
    ).rejects.toMatchObject({ code: "not_a_repo" });
  });

  it("reports needs_merge on a dirty tree and leaves the work untouched", async () => {
    const fx = await fixture();
    const { gitJob } = await cloneFixture(fx);

    writeFileSync(join(fx.workspace, "app", "README.md"), "local edit\n");
    writeFileSync(join(fx.seed, "next.txt"), "remote change\n");
    await git(fx.seed, "add", ".");
    await git(fx.seed, "commit", "-m", "remote change");
    await git(fx.seed, "push", "origin", "main");

    const result = await gitJob.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN });
    expect(result).toMatchObject({
      status: "needs_merge",
      dirty: true,
      behind: 1,
      reason: "dirty_worktree",
    });
    expect(readFileSync(join(fx.workspace, "app", "README.md"), "utf8")).toBe("local edit\n");
    expect(existsSync(join(fx.workspace, "app", "next.txt"))).toBe(false);
  });

  it("reports needs_merge when histories diverged (no merge commit, no force)", async () => {
    const fx = await fixture();
    const { gitJob } = await cloneFixture(fx);
    const repo = join(fx.workspace, "app");

    writeFileSync(join(repo, "local.txt"), "local\n");
    await git(repo, "add", ".");
    await git(repo, "commit", "-m", "local commit");
    const localHead = (await git(repo, "rev-parse", "HEAD")).trim();

    writeFileSync(join(fx.seed, "remote.txt"), "remote\n");
    await git(fx.seed, "add", ".");
    await git(fx.seed, "commit", "-m", "remote commit");
    await git(fx.seed, "push", "origin", "main");

    const result = await gitJob.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN });
    expect(result).toMatchObject({
      status: "needs_merge",
      dirty: false,
      reason: "diverged",
      ahead: 1,
      behind: 1,
    });
    expect((await git(repo, "rev-parse", "HEAD")).trim()).toBe(localHead);
  });

  it("reports no_upstream rather than guessing a remote branch", async () => {
    const fx = await fixture();
    const { gitJob } = await cloneFixture(fx);
    const repo = join(fx.workspace, "app");
    await git(repo, "checkout", "-b", "local-only");

    const result = await gitJob.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN });
    expect(result).toMatchObject({ status: "needs_merge", reason: "no_upstream" });
  });

  it("refuses a folder that is not a git repository", async () => {
    const fx = await fixture();
    const gitJob = createStudioGit({ manager: fx.manager, allowLocalUrls: true });
    await expect(
      gitJob.syncLatest({ userId: "user-1", repoDir: "missing", token: TOKEN }),
    ).rejects.toMatchObject({ code: "not_a_repo" });
  });
});

describe("Branch switch", () => {
  async function withFeatureBranch(fx: Fixture): Promise<void> {
    await git(fx.seed, "checkout", "-b", "feature");
    writeFileSync(join(fx.seed, "feature.txt"), "feature\n");
    await git(fx.seed, "add", ".");
    await git(fx.seed, "commit", "-m", "feature commit");
    await git(fx.seed, "push", "-u", "origin", "feature");
    await git(fx.seed, "checkout", "main");
  }

  it("stashes dirty work, switches, and leaves the changes recoverable", async () => {
    const fx = await fixture();
    await withFeatureBranch(fx);
    const logs: string[] = [];
    const rec = recordingRunner();
    const calls = rec.calls;
    const { gitJob } = await cloneFixture(fx, {
      runner: rec.runner,
      log: (line) => logs.push(line),
    });
    const repo = join(fx.workspace, "app");

    writeFileSync(join(repo, "README.md"), "local edit\n");
    const result = await gitJob.switchBranch({
      userId: "user-1",
      repoDir: "app",
      branch: "feature",
      token: TOKEN,
    });

    expect(result.status).toBe("switched");
    expect(result.stashed).toBe(true);
    expect(result.stashRef).toMatch(/^[0-9a-f]{40}$/);
    expect(result.stashNote).toContain("before switching");
    expect(result.message).toContain("feature");
    expectSafeArgv(calls);
    expect(configText(repo)).not.toContain(TOKEN);
    for (const ref of rec.envRefs) {
      expect(ref.OVID_GIT_TOKEN).toBeUndefined();
      expect(ref.GIT_ASKPASS).toBeUndefined();
    }
    expect(readdirSync(fx.helperDir)).toEqual([]);
    expect(JSON.stringify({ calls, logs, result })).not.toContain(TOKEN);

    expect(readFileSync(join(repo, "feature.txt"), "utf8")).toBe("feature\n");
    expect((await git(repo, "status", "--porcelain")).trim()).toBe("");
    expect(await git(repo, "stash", "list")).toContain("before switching");

    await git(repo, "switch", "main");
    await git(repo, "stash", "pop");
    expect(readFileSync(join(repo, "README.md"), "utf8")).toBe("local edit\n");
  });

  it("switches cleanly without a stash and reports unchanged for the current branch", async () => {
    const fx = await fixture();
    await withFeatureBranch(fx);
    const { gitJob } = await cloneFixture(fx);

    const switched = await gitJob.switchBranch({
      userId: "user-1",
      repoDir: "app",
      branch: "feature",
      token: TOKEN,
    });
    expect(switched).toMatchObject({ status: "switched", stashed: false });

    const same = await gitJob.switchBranch({
      userId: "user-1",
      repoDir: "app",
      branch: "feature",
      token: TOKEN,
    });
    expect(same.status).toBe("unchanged");
  });

  it("leaves dirty work in place when the target branch does not exist", async () => {
    const fx = await fixture();
    const { gitJob } = await cloneFixture(fx);
    const repo = join(fx.workspace, "app");
    writeFileSync(join(repo, "README.md"), "local edit\n");

    await expect(
      gitJob.switchBranch({
        userId: "user-1",
        repoDir: "app",
        branch: "no-such-branch",
        token: TOKEN,
      }),
    ).rejects.toMatchObject({ code: "switch_failed" });

    expect(readFileSync(join(repo, "README.md"), "utf8")).toBe("local edit\n");
    expect((await git(repo, "stash", "list")).trim()).toBe("");
  });

  it("validates branch names and workspace-relative folders", () => {
    expect(() => assertSafeBranch("-delete")).toThrow(/branch/);
    expect(() => assertSafeBranch("bad..branch")).toThrow(/branch/);
    expect(() => assertSafeBranch("has space")).toThrow(/branch/);
    expect(() => assertSafeBranch("feature/ok-1")).not.toThrow();

    expect(safeRelDir(".")).toBe(".");
    expect(safeRelDir("repos/app")).toBe("repos/app");
    expect(() => safeRelDir("../escape")).toThrow(/not allowed/);
    expect(() => safeRelDir("/abs")).toThrow(/not allowed/);
    expect(() => safeRelDir("-flag")).toThrow(/not allowed/);

    expect(safeRepoDirName("app")).toBe("app");
    expect(() => safeRepoDirName("repos/app")).toThrow(/not allowed/);
    expect(() => safeRepoDirName("..")).toThrow(/not allowed/);
    expect(() => safeRepoDirName("")).toThrow(/not allowed/);
  });
});

describe("read-only Studio inspection", () => {
  async function headAndTree(repo: string) {
    return {
      head: (await git(repo, "rev-parse", "HEAD")).trim(),
      status: await git(repo, "status", "--porcelain"),
      stash: await git(repo, "stash", "list"),
      readme: readFileSync(join(repo, "README.md"), "utf8"),
    };
  }

  it("inspect fetches only remote metadata and preserves dirty HEAD/files/stash", async () => {
    const fx = await fixture();
    const { gitJob } = await cloneFixture(fx);
    const repo = join(fx.workspace, "app");
    writeFileSync(join(repo, "README.md"), "local edit\n");
    writeFileSync(join(fx.seed, "next.txt"), "remote change\n");
    await git(fx.seed, "add", ".");
    await git(fx.seed, "commit", "-m", "remote change");
    await git(fx.seed, "push", "origin", "main");
    const before = await headAndTree(repo);

    const result = await gitJob.inspect({ userId: "user-1", repoDir: "app", token: TOKEN });

    expect(result).toMatchObject({
      dirty: true,
      behind: 1,
      ahead: 0,
      reason: "dirty_worktree",
      fetchedAt: expect.any(String),
    });
    expect(await headAndTree(repo)).toEqual(before);
    expect(existsSync(join(repo, "next.txt"))).toBe(false);
  });

  it("status never fetches and reports divergence without changing local history", async () => {
    const fx = await fixture();
    const { gitJob } = await cloneFixture(fx);
    const repo = join(fx.workspace, "app");
    writeFileSync(join(repo, "local.txt"), "local\n");
    await git(repo, "add", ".");
    await git(repo, "commit", "-m", "local commit");
    const localHead = (await git(repo, "rev-parse", "HEAD")).trim();
    writeFileSync(join(fx.seed, "remote.txt"), "remote\n");
    await git(fx.seed, "add", ".");
    await git(fx.seed, "commit", "-m", "remote commit");
    await git(fx.seed, "push", "origin", "main");
    const real = createSpawnGitRunner();
    let fetchCalls = 0;
    const runner: GitRunner = async (req) => {
      if (req.argv.includes("fetch")) fetchCalls += 1;
      return real(req);
    };
    const readOnly = createStudioGit({
      manager: fx.manager,
      allowLocalUrls: true,
      credentialDir: fx.helperDir,
      runner,
      log: () => {},
    });

    const inspected = await readOnly.inspect({ userId: "user-1", repoDir: "app", token: TOKEN });
    expect(inspected).toMatchObject({ reason: "diverged", ahead: 1, behind: 1, dirty: false });
    expect((await git(repo, "rev-parse", "HEAD")).trim()).toBe(localHead);

    const beforeStatusCalls = fetchCalls;
    const status = await readOnly.status({ userId: "user-1", repoDir: "app" });
    expect(status).toMatchObject({
      reason: "diverged",
      ahead: 1,
      behind: 1,
      dirty: false,
      headSha: localHead,
      fetchedAt: null,
    });
    expect(fetchCalls).toBe(beforeStatusCalls);
  });

  it("diff honors staged and path filters and caps large patches without mutating", async () => {
    const fx = await fixture();
    const { gitJob } = await cloneFixture(fx);
    const repo = join(fx.workspace, "app");
    writeFileSync(join(repo, "README.md"), "unstaged change\n");
    writeFileSync(join(repo, "notes.txt"), "staged change\n");
    await git(repo, "add", "notes.txt");

    const unstaged = await gitJob.diff({ userId: "user-1", repoDir: "app", path: "README.md" });
    expect(unstaged.patch).toContain("unstaged change");
    expect(unstaged.patch).not.toContain("notes.txt");
    expect(unstaged.truncated).toBe(false);

    const staged = await gitJob.diff({ userId: "user-1", repoDir: "app", staged: true });
    expect(staged.patch).toContain("notes.txt");
    expect(staged.patch).not.toContain("unstaged change");

    writeFileSync(join(repo, "README.md"), "A".repeat(300_000));
    const headBefore = (await git(repo, "rev-parse", "HEAD")).trim();
    const truncated = await gitJob.diff({ userId: "user-1", repoDir: "app", path: "README.md", maxBytes: 1024 });
    expect(Buffer.byteLength(truncated.patch, "utf8")).toBeLessThanOrEqual(1024);
    expect(truncated.truncated).toBe(true);
    expect((await git(repo, "rev-parse", "HEAD")).trim()).toBe(headBefore);
  });

  it("logs return real commit records and clamp the limit to 50", async () => {
    const fx = await fixture();
    const { gitJob } = await cloneFixture(fx);
    const repo = join(fx.workspace, "app");
    for (let index = 1; index <= 51; index += 1) {
      writeFileSync(join(repo, "history.txt"), `${index}\n`);
      await git(repo, "add", "history.txt");
      await git(repo, "commit", "-m", `history ${index}`);
    }

    const result = await gitJob.logs({ userId: "user-1", repoDir: "app", limit: 51 });
    expect(result.items).toHaveLength(50);
    expect(result.items[0]).toMatchObject({
      sha: expect.stringMatching(/^[0-9a-f]{40}$/),
      subject: "history 51",
      authoredAt: expect.any(String),
    });
    expect(result.items.at(-1)?.subject).toBe("history 2");
  });
});

interface RepoSentinel {
  head: string;
  branch: string;
  status: string;
  stash: string;
  tree: Record<string, string>;
}

function fileTree(root: string, relative = ""): Record<string, string> {
  const result: Record<string, string> = {};
  const directory = join(root, relative);
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (relative === "" && entry.name === ".git") continue;
    const path = relative === "" ? entry.name : `${relative}/${entry.name}`;
    if (entry.isDirectory()) Object.assign(result, fileTree(root, path));
    else if (entry.isFile()) result[path] = readFileSync(join(root, path)).toString("base64");
  }
  return result;
}

async function headAndTree(repo: string): Promise<RepoSentinel> {
  return {
    head: (await git(repo, "rev-parse", "HEAD")).trim(),
    branch: (await git(repo, "rev-parse", "--abbrev-ref", "HEAD")).trim(),
    status: await git(repo, "status", "--porcelain=v1", "-z"),
    stash: await git(repo, "stash", "list", "--format=%H"),
    tree: fileTree(repo),
  };
}

const repoRequest = { userId: "user-1", sessionId: "session-1", repoDir: "app" } as const;

describe("read-only Studio inspection and status", () => {
  it("fetch-inspects a dirty behind-by-one tree without changing HEAD, files, index state, or stash", async () => {
    const fx = await fixture();
    const rec = recordingRunner();
    const { gitJob } = await cloneFixture(fx, { runner: rec.runner });
    const repo = join(fx.workspace, "app");

    writeFileSync(join(repo, "README.md"), "stash this first\n");
    await git(repo, "stash", "push", "-m", "existing user stash");
    writeFileSync(join(repo, "README.md"), "dirty local edit\n");
    writeFileSync(join(fx.seed, "next.txt"), "remote change\n");
    await git(fx.seed, "add", ".");
    await git(fx.seed, "commit", "-m", "remote change");
    await git(fx.seed, "push", "origin", "main");

    const before = await headAndTree(repo);
    const inspected = await gitJob.inspect({ ...repoRequest, token: TOKEN });
    expect(inspected).toMatchObject({
      branch: "main",
      headSha: before.head,
      upstream: "origin/main",
      dirty: true,
      ahead: 0,
      behind: 1,
      reason: "dirty_worktree",
      fetchedAt: expect.any(String),
    });
    expect(await headAndTree(repo)).toEqual(before);
    expect(rec.calls.slice(-10).filter((call) => call.argv.includes("fetch"))).toHaveLength(1);

    const statusCalls = rec.calls.length;
    const status = await gitJob.status(repoRequest);
    expect(status).toEqual({ ...inspected, fetchedAt: null });
    expect(rec.calls.slice(statusCalls).some((call) => call.argv.includes("fetch"))).toBe(false);
    expect(await headAndTree(repo)).toEqual(before);
  });

  it("does not fast-forward a clean behind tree during inspect", async () => {
    const fx = await fixture();
    const { gitJob } = await cloneFixture(fx);
    const repo = join(fx.workspace, "app");
    writeFileSync(join(fx.seed, "next.txt"), "remote only\n");
    await git(fx.seed, "add", ".");
    await git(fx.seed, "commit", "-m", "remote change");
    await git(fx.seed, "push", "origin", "main");

    const before = await headAndTree(repo);
    const inspected = await gitJob.inspect({ ...repoRequest, token: TOKEN });
    expect(inspected).toMatchObject({
      headSha: before.head,
      behind: 1,
      ahead: 0,
      dirty: false,
      reason: "clean",
    });
    expect(await headAndTree(repo)).toEqual(before);
    expect(existsSync(join(repo, "next.txt"))).toBe(false);
  });

  it("reports divergence during inspect and preserves the same sentinel through needs_merge sync", async () => {
    const fx = await fixture();
    const { gitJob } = await cloneFixture(fx);
    const repo = join(fx.workspace, "app");
    writeFileSync(join(repo, "local.txt"), "local\n");
    await git(repo, "add", ".");
    await git(repo, "commit", "-m", "local commit");
    writeFileSync(join(fx.seed, "remote.txt"), "remote\n");
    await git(fx.seed, "add", ".");
    await git(fx.seed, "commit", "-m", "remote commit");
    await git(fx.seed, "push", "origin", "main");

    const before = await headAndTree(repo);
    const inspected = await gitJob.inspect({ ...repoRequest, token: TOKEN });
    expect(inspected).toMatchObject({ ahead: 1, behind: 1, reason: "diverged" });
    expect(await headAndTree(repo)).toEqual(before);

    const synced = await gitJob.syncLatest({ ...repoRequest, token: TOKEN });
    expect(synced).toMatchObject({
      status: "needs_merge",
      reason: "diverged",
      ahead: 1,
      behind: 1,
    });
    expect(await headAndTree(repo)).toEqual(before);
  });

  it("fails safely instead of converting a timed-out branch read into no_upstream", async () => {
    const fx = await fixture();
    const { gitJob } = await cloneFixture(fx);
    const real = createSpawnGitRunner();
    const runner: GitRunner = async (req) => {
      if (req.argv.includes("--abbrev-ref") && req.argv.includes("HEAD")) {
        return { code: null, stdout: "", stderr: "raw timeout detail", timedOut: true };
      }
      return real(req);
    };
    const readOnly = createStudioGit({
      manager: fx.manager,
      allowLocalUrls: true,
      credentialDir: fx.helperDir,
      runner,
      log: () => {},
    });

    await expect(readOnly.status(repoRequest)).rejects.toMatchObject({
      code: "sync_failed",
      message: "Could not read repository metadata.",
    });
  });

  it("returns no_upstream for a local-only inspect without fetching or changing HEAD", async () => {
    const fx = await fixture();
    const rec = recordingRunner();
    const { gitJob } = await cloneFixture(fx, { runner: rec.runner });
    const repo = join(fx.workspace, "app");
    await git(repo, "checkout", "-b", "local-only");
    const before = await headAndTree(repo);
    const calls = rec.calls.length;

    const result = await gitJob.inspect({ ...repoRequest, token: TOKEN });
    expect(result).toMatchObject({
      branch: "local-only",
      upstream: null,
      ahead: 0,
      behind: 0,
      reason: "no_upstream",
      fetchedAt: null,
    });
    expect(rec.calls.slice(calls).some((call) => call.argv.includes("fetch"))).toBe(false);
    expect(await headAndTree(repo)).toEqual(before);
  });

  it("computes clean and no-upstream status locally without fetching", async () => {
    const fx = await fixture();
    const rec = recordingRunner();
    const { gitJob } = await cloneFixture(fx, { runner: rec.runner });
    const repo = join(fx.workspace, "app");
    const head = (await git(repo, "rev-parse", "HEAD")).trim();
    const before = rec.calls.length;

    const clean = await gitJob.status(repoRequest);
    expect(clean).toEqual({
      branch: "main",
      headSha: head,
      upstream: "origin/main",
      dirty: false,
      ahead: 0,
      behind: 0,
      reason: "clean",
      fetchedAt: null,
    });
    expect(rec.calls.slice(before).some((call) => call.argv.includes("fetch"))).toBe(false);

    await git(repo, "checkout", "-b", "local-only");
    const localCalls = rec.calls.length;
    const local = await gitJob.status(repoRequest);
    expect(local).toMatchObject({
      branch: "local-only",
      headSha: head,
      upstream: null,
      ahead: 0,
      behind: 0,
      reason: "no_upstream",
    });
    expect(rec.calls.slice(localCalls).some((call) => call.argv.includes("fetch"))).toBe(false);
  });
});

describe("bounded Studio diffs and real commit logs", () => {
  it("returns distinct staged, unstaged, and literal path diffs", async () => {
    const fx = await fixture();
    const rec = recordingRunner();
    const { gitJob } = await cloneFixture(fx, { runner: rec.runner });
    const repo = join(fx.workspace, "app");
    writeFileSync(join(repo, "one.txt"), "base one\n");
    writeFileSync(join(repo, "two.txt"), "base two\n");
    await git(repo, "add", ".");
    await git(repo, "commit", "-m", "diff fixtures");
    writeFileSync(join(repo, "one.txt"), "staged one\n");
    await git(repo, "add", "one.txt");
    writeFileSync(join(repo, "one.txt"), "working one\n");
    writeFileSync(join(repo, "two.txt"), "working two\n");

    const staged = await gitJob.diff({ ...repoRequest, staged: true, path: "one.txt" });
    expect(staged.truncated).toBe(false);
    expect(staged.patch).toContain("+staged one");
    expect(staged.patch).not.toContain("working one");
    expect(staged.patch).not.toContain("two.txt");

    const unstaged = await gitJob.diff({ ...repoRequest, path: "one.txt" });
    expect(unstaged.patch).toContain("+working one");
    expect(unstaged.patch).toContain("-staged one");
    expect(unstaged.patch).not.toContain("two.txt");

    const other = await gitJob.diff({ ...repoRequest, path: "two.txt" });
    expect(other.patch).toContain("+working two");
    expect(other.patch).not.toContain("one.txt");
    const pathCall = rec.calls[rec.calls.length - 1]!;
    const separator = pathCall.argv.lastIndexOf("--");
    expect(separator).toBeGreaterThan(-1);
    expect(pathCall.argv[separator + 1]).toBe(":(literal)two.txt");
  });

  it("honors a small byte limit and the absolute 256 KiB diff cap", async () => {
    const fx = await fixture();
    const { gitJob } = await cloneFixture(fx);
    const repo = join(fx.workspace, "app");
    writeFileSync(join(repo, "README.md"), `${"é".repeat(200)}\n`);

    const complete = await gitJob.diff(repoRequest);
    expect(complete.truncated).toBe(false);
    const shortened = await gitJob.diff({ ...repoRequest, maxBytes: 64 });
    expect(shortened.truncated).toBe(true);
    expect(Buffer.byteLength(shortened.patch, "utf8")).toBeLessThanOrEqual(64);
    expect(shortened.patch).not.toContain("�");
    const splitCharacter = Buffer.from(complete.patch, "utf8").indexOf(Buffer.from("é", "utf8")) + 1;
    const split = await gitJob.diff({ ...repoRequest, maxBytes: splitCharacter });
    expect(split.truncated).toBe(true);
    expect(split.patch).not.toContain("�");
    expect(Buffer.byteLength(split.patch, "utf8")).toBeLessThanOrEqual(splitCharacter);

    writeFileSync(join(repo, "README.md"), `${"x".repeat(300 * 1024)}\n`);
    const capped = await gitJob.diff({ ...repoRequest, maxBytes: 1024 * 1024 });
    expect(capped.truncated).toBe(true);
    expect(Buffer.byteLength(capped.patch, "utf8")).toBeLessThanOrEqual(256 * 1024);
  });

  it("rejects escaping or option-like diff paths before invoking git", async () => {
    const fx = await fixture();
    const rec = recordingRunner();
    const { gitJob } = await cloneFixture(fx, { runner: rec.runner });
    const before = rec.calls.length;

    await expect(gitJob.diff({ ...repoRequest, path: "../outside" })).rejects.toMatchObject({
      code: "invalid_path",
    });
    await expect(gitJob.diff({ ...repoRequest, path: "--cached" })).rejects.toMatchObject({
      code: "invalid_path",
    });
    expect(rec.calls).toHaveLength(before);
  });

  it("clamps a 51-commit request to 50 real log records", async () => {
    const fx = await fixture();
    for (let index = 1; index <= 51; index += 1) {
      writeFileSync(join(fx.seed, "history.txt"), `${index}\n`);
      await git(fx.seed, "add", "history.txt");
      await git(fx.seed, "commit", "-m", `commit ${index}`);
    }
    await git(fx.seed, "push", "origin", "main");
    const { gitJob } = await cloneFixture(fx);
    const repo = join(fx.workspace, "app");

    const result = await gitJob.logs({ ...repoRequest, limit: 51 });
    expect(result.items).toHaveLength(50);
    expect(result.items[0]).toMatchObject({
      sha: (await git(repo, "rev-parse", "HEAD")).trim(),
      subject: "commit 51",
      authoredAt: expect.any(String),
    });
    expect(result.items[49]?.subject).toBe("commit 2");
    expect(new Set(result.items.map((item) => item.sha)).size).toBe(50);
    for (const item of result.items) {
      expect(item.sha).toMatch(/^[0-9a-f]{40}$/);
      expect(Number.isNaN(Date.parse(item.authoredAt))).toBe(false);
    }

    const two = await gitJob.logs({ ...repoRequest, limit: 2 });
    expect(two.items.map((item) => item.subject)).toEqual(["commit 51", "commit 50"]);
  });
});

describe("per-user GitHub token resolver", () => {
  it("reads only the requesting user's enabled, sealed GITHUB_TOKEN with no deployment fallback", async () => {
    const rows: Record<string, Array<{ id: string; curatedId: string | null; enabled?: boolean; secretsSealed: unknown }>> = {
      "user-2": [
        { id: "srv-2", curatedId: "github", enabled: true, secretsSealed: { sealed: "user-2" } },
      ],
      "user-3": [
        { id: "srv-3", curatedId: "github", enabled: false, secretsSealed: { sealed: "user-3" } },
      ],
      "user-4": [
        { id: "srv-4", curatedId: "gitlab", enabled: true, secretsSealed: { sealed: "user-4" } },
      ],
    };
    const resolver = createPerUserGithubTokenResolver({
      listServers: async (userId) => rows[userId] ?? [],
      decrypt: (sealed, recordId) => {
        const value = (sealed as { sealed: string }).sealed;
        expect(recordId).toBe(`mcp_servers:srv-${value.split("-")[1]}`);
        return JSON.stringify({ GITHUB_TOKEN: `ghp_${value}` });
      },
    });

    await expect(resolver({ userId: "user-2", repo: "acme/app" })).resolves.toBe("ghp_user-2");
    await expect(resolver({ userId: "user-3" })).resolves.toBeNull();
    await expect(resolver({ userId: "user-4" })).resolves.toBeNull();
    await expect(resolver({ userId: "user-1" })).resolves.toBeNull();
  });

  it("refuses malformed or undecryptable sealed credentials instead of using another identity", async () => {
    const resolver = createPerUserGithubTokenResolver({
      listServers: async () => [
        { id: "srv-1", curatedId: "github", enabled: true, secretsSealed: { sealed: true } },
      ],
      decrypt: () => {
        throw new Error("sealed credential cannot be decrypted");
      },
    });
    await expect(resolver({ userId: "user-1" })).resolves.toBeNull();

    const malformed = createPerUserGithubTokenResolver({
      listServers: async () => [
        { id: "srv-1", curatedId: "github", enabled: true, secretsSealed: { sealed: true } },
      ],
      decrypt: () => JSON.stringify({ GITHUB_API_TOKEN: "not-the-studio-secret" }),
    });
    await expect(malformed({ userId: "user-1" })).resolves.toBeNull();
  });
});

// Fix round 1: every test below reproduces an adversarial behavior against the
// real service/runner. No policy is accepted merely because its argv looks safe.

describe("adversarial repository execution policy", () => {
  it("never executes repository hooks with the PAT during switch or sync", async () => {
    const fx = await fixture();
    await git(fx.seed, "checkout", "-b", "feature");
    await git(fx.seed, "push", "-u", "origin", "feature");
    await git(fx.seed, "checkout", "main");
    const { gitJob } = await cloneFixture(fx);
    const repo = join(fx.workspace, "app");
    const hooks = join(fx.root, "hostile-hooks");
    const sentinel = join(fx.root, "hook-executions");
    mkdirSync(hooks, { recursive: true });
    const script = `#!/bin/sh\nprintf 'hook executed with token=%s\\n' "\${OVID_GIT_TOKEN:+yes}" >> "${sentinel}"\n`;
    writeFileSync(join(hooks, "post-checkout"), script, { mode: 0o755 });
    writeFileSync(join(hooks, "post-merge"), script, { mode: 0o755 });
    await git(repo, "config", "core.hooksPath", hooks);

    await gitJob.switchBranch({ userId: "user-1", repoDir: "app", branch: "feature", token: TOKEN });
    await gitJob.switchBranch({ userId: "user-1", repoDir: "app", branch: "main", token: TOKEN });
    writeFileSync(join(fx.seed, "next.txt"), "remote change\n");
    await git(fx.seed, "add", ".");
    await git(fx.seed, "commit", "-m", "remote change");
    await git(fx.seed, "push", "origin", "main");
    await gitJob.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN });

    expect(existsSync(sentinel) ? readFileSync(sentinel, "utf8") : "").toBe("");
  });

  it("does not expose the PAT to repository filters during local switch", async () => {
    const fx = await fixture();
    await git(fx.seed, "checkout", "-b", "feature");
    writeFileSync(join(fx.seed, ".gitattributes"), "README.md filter=hostile\n");
    writeFileSync(join(fx.seed, "README.md"), "feature content\n");
    await git(fx.seed, "add", ".");
    await git(fx.seed, "commit", "-m", "feature filter input");
    await git(fx.seed, "push", "-u", "origin", "feature");
    await git(fx.seed, "checkout", "main");
    const { gitJob } = await cloneFixture(fx);
    const repo = join(fx.workspace, "app");
    const sentinel = join(fx.root, "filter-token-access");
    const filter = join(fx.root, "hostile-filter");
    writeFileSync(
      filter,
      `#!/bin/sh\nprintf 'filter ran with token=%s\\n' "\${OVID_GIT_TOKEN:+yes}" >> "${sentinel}"\ncat\n`,
      { mode: 0o755 },
    );
    await git(repo, "config", "filter.hostile.smudge", filter);
    await git(repo, "config", "filter.hostile.clean", filter);

    await gitJob.switchBranch({ userId: "user-1", repoDir: "app", branch: "feature", token: TOKEN });
    const events = existsSync(sentinel) ? readFileSync(sentinel, "utf8") : "";
    expect(events).not.toContain("token=yes");
    expect(readFileSync(join(repo, "README.md"), "utf8")).toBe("feature content\n");
  });

  it("does not execute a template post-checkout hook during clone", async () => {
    const fx = await fixture();
    const template = join(fx.root, "hostile-template");
    const sentinel = join(fx.root, "clone-hook-executed");
    mkdirSync(join(template, "hooks"), { recursive: true });
    writeFileSync(
      join(template, "hooks", "post-checkout"),
      `#!/bin/sh\n: > "${sentinel}"\n`,
      { mode: 0o755 },
    );
    const real = createSpawnGitRunner();
    const runner: GitRunner = async (req) => {
      if (req.argv.includes("clone")) req.env.GIT_TEMPLATE_DIR = template;
      return real(req);
    };
    const gitJob = createStudioGit({
      manager: fx.manager,
      allowLocalUrls: true,
      credentialDir: fx.helperDir,
      runner,
      log: () => {},
    });

    await gitJob.clone({ userId: "user-1", repo: fx.remoteUrl, token: TOKEN });
    expect(existsSync(sentinel)).toBe(false);
  });

  it("neutralizes an exact insteadOf rewrite installed immediately before fetch", async () => {
    const fx = await fixture();
    const { gitJob } = await cloneFixture(fx);
    const repo = join(fx.workspace, "app");
    const sentinel = join(fx.root, "prefetch-helper-contact");
    const helper = join(fx.root, "prefetch-helper");
    writeFileSync(
      helper,
      `#!/bin/sh\nprintf 'helper contacted with token=%s\\n' "\${OVID_GIT_TOKEN:+yes}" > "${sentinel}"\nexit 1\n`,
      { mode: 0o755 },
    );
    const real = createSpawnGitRunner();
    const runner: GitRunner = async (req) => {
      if (req.argv.includes("fetch")) {
        const hostile =
          `[url "ext::${helper}"]\n\tinsteadOf = ${fx.remoteUrl}\n` +
          '[protocol "ext"]\n\tallow = always\n';
        const configPath = join(repo, ".git", "config");
        const config = readFileSync(configPath, "utf8");
        if (!config.includes("prefetch-helper")) writeFileSync(configPath, config + hostile);
      }
      return real(req);
    };
    const hardened = createStudioGit({
      manager: fx.manager,
      allowLocalUrls: true,
      credentialDir: fx.helperDir,
      runner,
      log: () => {},
    });

    const result = await hardened.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN });
    expect(result.status).toBe("up_to_date");
    expect(existsSync(sentinel)).toBe(false);
  });
});

describe("clone destination ownership and concurrency", () => {
  it("allows exactly one of two concurrent clones to publish the destination", async () => {
    const fx = await fixture();
    const real = createSpawnGitRunner();
    let arrivals = 0;
    let release: () => void = () => {};
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const runner: GitRunner = async (req) => {
      if (req.argv.includes("clone")) {
        arrivals += 1;
        if (arrivals === 2) release();
        await gate;
      }
      return real(req);
    };
    const gitJob = createStudioGit({
      manager: fx.manager,
      allowLocalUrls: true,
      credentialDir: fx.helperDir,
      runner,
      log: () => {},
    });

    const outcomes = await Promise.allSettled([
      gitJob.clone({ userId: "user-1", repo: fx.remoteUrl, token: TOKEN }),
      gitJob.clone({ userId: "user-1", repo: fx.remoteUrl, token: TOKEN }),
    ]);
    expect(outcomes.filter((outcome) => outcome.status === "fulfilled")).toHaveLength(1);
    expect(outcomes.filter((outcome) => outcome.status === "rejected")).toHaveLength(1);
    expect(readFileSync(join(fx.workspace, "app", "README.md"), "utf8")).toBe("hello\n");
  });

  it("never deletes another actor's late destination after clone failure", async () => {
    const fx = await fixture();
    const real = createSpawnGitRunner();
    const runner: GitRunner = async (req) => {
      if (req.argv.includes("clone")) {
        mkdirSync(join(fx.workspace, "app"), { recursive: true });
        writeFileSync(join(fx.workspace, "app", "keep.txt"), "other actor\n");
      }
      return real(req);
    };
    const gitJob = createStudioGit({
      manager: fx.manager,
      allowLocalUrls: true,
      credentialDir: fx.helperDir,
      runner,
      log: () => {},
    });

    await expect(
      gitJob.clone({ userId: "user-1", repo: fx.remoteUrl, token: TOKEN }),
    ).rejects.toMatchObject({ code: "destination_exists" });
    expect(readFileSync(join(fx.workspace, "app", "keep.txt"), "utf8")).toBe("other actor\n");
  });

  it("does not clean through a replaced staging parent", async () => {
    const fx = await fixture();
    const outside = join(fx.root, "replacement-staging-parent");
    mkdirSync(outside);
    const real = createSpawnGitRunner();
    const runner: GitRunner = async (req) => {
      if (req.argv.includes("clone")) {
        const stageFd = req.fds?.[0];
        expect(stageFd).toBeDefined();
        const stageName = basename(realpathSync(`/proc/self/fd/${stageFd}`));
        const parent = join(fx.workspace, ".ovid-studio-git");
        renameSync(parent, `${parent}-moved`);
        mkdirSync(join(outside, stageName));
        writeFileSync(join(outside, stageName, "keep.txt"), "other actor\n");
        symlinkSync(outside, parent, "dir");
      }
      return real(req);
    };
    const gitJob = createStudioGit({
      manager: fx.manager,
      allowLocalUrls: true,
      credentialDir: fx.helperDir,
      runner,
      log: () => {},
    });

    await gitJob.clone({ userId: "user-1", repo: fx.remoteUrl, token: TOKEN });
    const replacementKeep = join(outside, readdirSync(outside)[0]!, "keep.txt");
    expect(readFileSync(replacementKeep, "utf8")).toBe("other actor\n");
  });
});

describe("git runner process lifecycle", () => {
  it("kills the whole timed-out process group and waits for closure", async () => {
    const root = mkdtempSync(join(tmpdir(), "ovid-git-process-group-"));
    roots.push(root);
    const bin = join(root, "bin");
    const descendantPidFile = join(root, "descendant.pid");
    mkdirSync(bin);
    writeFileSync(
      join(bin, "git"),
      `#!/usr/bin/env node\n` +
        `const { spawn } = require("node:child_process");\n` +
        `const fs = require("node:fs");\n` +
        `const child = spawn(process.execPath, ["-e", "setTimeout(() => {}, 30000)"], { stdio: ["ignore", "inherit", "inherit"] });\n` +
        `fs.writeFileSync(${JSON.stringify(descendantPidFile)}, String(child.pid));\n` +
        `setTimeout(() => {}, 30000);\n`,
      { mode: 0o755 },
    );
    const runner = createSpawnGitRunner();
    let descendantPid = 0;
    try {
      const result = await runner({
        argv: ["status"],
        cwd: root,
        env: {
          PATH: `${bin}:${process.env.PATH ?? "/usr/bin:/bin"}`,
          HOME: root,
          OVID_GIT_TOKEN: TOKEN,
        },
        timeoutMs: 100,
      });
      descendantPid = Number.parseInt(readFileSync(descendantPidFile, "utf8"), 10);
      expect(result.timedOut).toBe(true);
      expect(descendantPid).toBeGreaterThan(0);

      let alive = true;
      for (let attempt = 0; attempt < 50 && alive; attempt += 1) {
        try {
          process.kill(descendantPid, 0);
          const stat = readFileSync(`/proc/${descendantPid}/stat`, "utf8");
          alive = !/\) Z /.test(stat);
        } catch {
          alive = false;
        }
        if (alive) await delay(20);
      }
      expect(alive).toBe(false);
    } finally {
      if (descendantPid > 0) {
        try {
          process.kill(descendantPid, "SIGKILL");
        } catch {
          // Already reaped.
        }
      }
    }
  });
});

describe("fetch ref and path boundaries", () => {
  it("ignores hostile configured refspecs and does not prune tracking refs", async () => {
    const fx = await fixture();
    const { gitJob } = await cloneFixture(fx);
    const repo = join(fx.workspace, "app");
    const original = (await git(repo, "rev-parse", "HEAD")).trim();
    await git(repo, "branch", "victim", original);
    await git(repo, "update-ref", "refs/remotes/origin/stale", original);
    await git(repo, "config", "--replace-all", "remote.origin.fetch", "+refs/heads/main:refs/heads/victim");
    await git(repo, "config", "--add", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*");

    writeFileSync(join(fx.seed, "next.txt"), "remote change\n");
    await git(fx.seed, "add", ".");
    await git(fx.seed, "commit", "-m", "remote change");
    await git(fx.seed, "push", "origin", "main");
    await gitJob.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN });

    expect((await git(repo, "rev-parse", "refs/heads/victim")).trim()).toBe(original);
    expect((await git(repo, "rev-parse", "refs/remotes/origin/stale")).trim()).toBe(original);
  });

  it("does not follow a repository replaced immediately before fetch", async () => {
    const fx = await fixture();
    const { gitJob } = await cloneFixture(fx);
    const repo = join(fx.workspace, "app");
    const moved = join(fx.workspace, "app-moved");
    const outside = join(fx.root, "outside");
    await git(fx.root, "clone", fx.remoteUrl, outside);
    const outsideFetchHead = join(outside, ".git", "FETCH_HEAD");
    rmSync(outsideFetchHead, { force: true });
    const real = createSpawnGitRunner();
    const runner: GitRunner = async (req) => {
      if (req.argv.includes("fetch") && existsSync(repo)) {
        renameSync(repo, moved);
        symlinkSync(outside, repo, "dir");
      }
      return real(req);
    };
    const hardened = createStudioGit({
      manager: fx.manager,
      allowLocalUrls: true,
      credentialDir: fx.helperDir,
      runner,
      log: () => {},
    });

    await expect(
      hardened.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN }),
    ).rejects.toMatchObject({ code: "invalid_path" });
    expect(existsSync(outsideFetchHead)).toBe(false);
  });

  it("does not follow .git metadata replaced immediately before fetch", async () => {
    const fx = await fixture();
    const { gitJob } = await cloneFixture(fx);
    const repo = join(fx.workspace, "app");
    const outside = join(fx.root, "outside");
    await git(fx.root, "clone", fx.remoteUrl, outside);
    const outsideFetchHead = join(outside, ".git", "FETCH_HEAD");
    rmSync(outsideFetchHead, { force: true });
    const real = createSpawnGitRunner();
    const runner: GitRunner = async (req) => {
      if (req.argv.includes("fetch") && !existsSync(join(repo, ".git-moved"))) {
        renameSync(join(repo, ".git"), join(repo, ".git-moved"));
        symlinkSync(join(outside, ".git"), join(repo, ".git"), "dir");
      }
      return real(req);
    };
    const hardened = createStudioGit({
      manager: fx.manager,
      allowLocalUrls: true,
      credentialDir: fx.helperDir,
      runner,
      log: () => {},
    });

    await expect(
      hardened.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN }),
    ).rejects.toMatchObject({ code: "invalid_path" });
    expect(existsSync(outsideFetchHead)).toBe(false);
  });

  it("does not clone through a workspace replaced during the operation", async () => {
    const fx = await fixture();
    const outside = join(fx.root, "outside-workspace");
    mkdirSync(outside);
    const real = createSpawnGitRunner();
    const runner: GitRunner = async (req) => {
      if (req.argv.includes("clone") && !existsSync(join(fx.root, "workspace-moved"))) {
        renameSync(fx.workspace, join(fx.root, "workspace-moved"));
        symlinkSync(outside, fx.workspace, "dir");
      }
      return real(req);
    };
    const gitJob = createStudioGit({
      manager: fx.manager,
      allowLocalUrls: true,
      credentialDir: fx.helperDir,
      runner,
      log: () => {},
    });

    await expect(
      gitJob.clone({ userId: "user-1", repo: fx.remoteUrl, token: TOKEN }),
    ).rejects.toMatchObject({ code: "invalid_path" });
    expect(existsSync(join(outside, "app"))).toBe(false);
  });
});

describe("credential cleanup error precedence", () => {
  it("preserves a detected leak when disposal also fails", async () => {
    const fx = await fixture();
    const logs: string[] = [];
    const runner: GitRunner = async (req) => {
      if (req.argv.includes("clone")) {
        const scriptPath = req.env.GIT_ASKPASS!;
        renameSync(scriptPath, `${scriptPath}.saved`);
        mkdirSync(scriptPath);
        const partial = operationCloneDir(req);
        mkdirSync(join(partial, ".git"), { recursive: true });
        writeFileSync(
          join(partial, ".git", "config"),
          `[remote "origin"]\n\turl = https://x-access-token:${TOKEN}@github.com/acme/app.git\n`,
        );
        return { code: 128, stdout: "", stderr: "failed", timedOut: false };
      }
      return { code: 0, stdout: "", stderr: "", timedOut: false };
    };
    const gitJob = createStudioGit({
      manager: fx.manager,
      allowLocalUrls: true,
      credentialDir: fx.helperDir,
      runner,
      log: (line) => logs.push(line),
    });

    await expect(
      gitJob.clone({ userId: "user-1", repo: fx.remoteUrl, token: TOKEN }),
    ).rejects.toMatchObject({ code: "credential_leak" });
    expect(JSON.stringify(logs)).not.toContain(TOKEN);
  });
});

describe("fix round 2 transport and final-scan boundaries", () => {
  it("does not contact a replacement named origin immediately before sync fetch", async () => {
    const fx = await fixture();
    const trap = await credentialTrap();
    try {
      const { gitJob } = await cloneFixture(fx);
      const repo = join(fx.workspace, "app");
      const real = createSpawnGitRunner();
      let fetchArgv: string[] | undefined;
      const runner: GitRunner = async (req) => {
        if (req.argv.includes("fetch")) {
          fetchArgv = [...req.argv];
          const configPath = join(repo, ".git", "config");
          const config = readFileSync(configPath, "utf8");
          writeFileSync(configPath, config.replace(/url = .*/, `url = ${trap.url}`));
          expect(readFileSync(configPath, "utf8")).toContain(`url = ${trap.url}`);
        }
        return real(req);
      };
      const hardened = createStudioGit({
        manager: fx.manager,
        allowLocalUrls: true,
        credentialDir: fx.helperDir,
        runner,
        log: () => {},
      });

      const result = await hardened.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN });
      expect(result.status).toBe("up_to_date");
      expect(fetchArgv).toBeDefined();
      expect(fetchArgv).toContain(fx.remoteUrl);
      expect(fetchArgv).not.toContain("origin");
      expect(trap.contacts).toBe(0);
      expect(trap.sawToken).toBe(false);
    } finally {
      await trap.close();
    }
  });

  it("does not contact a replacement named origin immediately before branch fetch", async () => {
    const fx = await fixture();
    const trap = await credentialTrap();
    try {
      const { gitJob } = await cloneFixture(fx);
      const repo = join(fx.workspace, "app");
      await git(fx.seed, "checkout", "-b", "feature");
      await git(fx.seed, "push", "-u", "origin", "feature");
      await git(fx.seed, "checkout", "main");
      const real = createSpawnGitRunner();
      let fetchArgv: string[] | undefined;
      const runner: GitRunner = async (req) => {
        if (req.argv.includes("fetch")) {
          fetchArgv = [...req.argv];
          const configPath = join(repo, ".git", "config");
          const config = readFileSync(configPath, "utf8");
          writeFileSync(configPath, config.replace(/url = .*/, `url = ${trap.url}`));
          expect(readFileSync(configPath, "utf8")).toContain(`url = ${trap.url}`);
        }
        return real(req);
      };
      const hardened = createStudioGit({
        manager: fx.manager,
        allowLocalUrls: true,
        credentialDir: fx.helperDir,
        runner,
        log: () => {},
      });

      const result = await hardened.switchBranch({
        userId: "user-1",
        repoDir: "app",
        branch: "feature",
        token: TOKEN,
      });
      expect(result.status).toBe("switched");
      expect(fetchArgv).toBeDefined();
      expect(fetchArgv).toContain(fx.remoteUrl);
      expect(fetchArgv).not.toContain("origin");
      expect(trap.contacts).toBe(0);
      expect(trap.sawToken).toBe(false);
    } finally {
      await trap.close();
    }
  });

  it("does not create or update tags during sync despite hostile tagOpt", async () => {
    const fx = await fixture();
    const rec = recordingRunner();
    const { gitJob } = await cloneFixture(fx, { runner: rec.runner });
    const repo = join(fx.workspace, "app");
    const original = (await git(repo, "rev-parse", "HEAD")).trim();
    await git(repo, "tag", "local-pinned", original);
    await git(repo, "config", "remote.origin.tagOpt", "--tags");

    writeFileSync(join(fx.seed, "next.txt"), "remote change\n");
    await git(fx.seed, "add", ".");
    await git(fx.seed, "commit", "-m", "remote change with tag");
    await git(fx.seed, "tag", "hostile-remote-tag");
    await git(fx.seed, "tag", "local-pinned");
    await git(
      fx.seed,
      "push",
      "origin",
      "main",
      "refs/tags/hostile-remote-tag",
      "+refs/tags/local-pinned",
    );

    await gitJob.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN });
    expect((await git(repo, "rev-parse", "refs/tags/local-pinned")).trim()).toBe(original);
    expect(await refExists(repo, "refs/tags/hostile-remote-tag")).toBe(false);
    const fetchCalls = rec.calls.filter((call) => call.argv.includes("fetch"));
    expect(fetchCalls).toHaveLength(1);
    expect(fetchCalls[0]!.argv).toContain("--no-tags");
  });

  it("does not create or update tags during branch fetch despite hostile tagOpt", async () => {
    const fx = await fixture();
    const rec = recordingRunner();
    const { gitJob } = await cloneFixture(fx, { runner: rec.runner });
    const repo = join(fx.workspace, "app");
    const original = (await git(repo, "rev-parse", "HEAD")).trim();
    await git(repo, "tag", "local-pinned", original);
    await git(repo, "config", "remote.origin.tagOpt", "--tags");

    await git(fx.seed, "checkout", "-b", "feature");
    writeFileSync(join(fx.seed, "feature.txt"), "feature\n");
    await git(fx.seed, "add", ".");
    await git(fx.seed, "commit", "-m", "feature with tag");
    await git(fx.seed, "tag", "hostile-feature-tag");
    await git(fx.seed, "tag", "local-pinned");
    await git(
      fx.seed,
      "push",
      "-u",
      "origin",
      "feature",
      "refs/tags/hostile-feature-tag",
      "+refs/tags/local-pinned",
    );
    await git(fx.seed, "checkout", "main");

    await gitJob.switchBranch({ userId: "user-1", repoDir: "app", branch: "feature", token: TOKEN });
    expect((await git(repo, "rev-parse", "refs/tags/local-pinned")).trim()).toBe(original);
    expect(await refExists(repo, "refs/tags/hostile-feature-tag")).toBe(false);
    const fetchCalls = rec.calls.filter((call) => call.argv.includes("fetch"));
    expect(fetchCalls).toHaveLength(1);
    expect(fetchCalls[0]!.argv).toContain("--no-tags");
  });

  it("scans the held published inode after a clean destination replacement", async () => {
    const fx = await fixture();
    const logs: string[] = [];
    let replaced = false;
    const gitJob = createStudioGit({
      manager: fx.manager,
      allowLocalUrls: true,
      credentialDir: fx.helperDir,
      log: (line) => {
        logs.push(line);
        if (line.includes("clone ok") && !replaced) {
          replaced = true;
          const published = join(fx.workspace, "app");
          const moved = join(fx.workspace, "published-original");
          renameSync(published, moved);
          writeFileSync(
            join(moved, ".git", "config"),
            `[remote "origin"]\n\turl = https://x-access-token:${TOKEN}@github.com/acme/app.git\n`,
          );
          mkdirSync(join(published, ".git"), { recursive: true });
          writeFileSync(
            join(published, ".git", "config"),
            '[remote "origin"]\n\turl = https://github.com/acme/app.git\n',
          );
        }
      },
    });

    await expect(
      gitJob.clone({ userId: "user-1", repo: fx.remoteUrl, token: TOKEN }),
    ).rejects.toMatchObject({ code: "credential_leak" });
    expect(replaced).toBe(true);
    expect(JSON.stringify(logs)).not.toContain(TOKEN);
  });

  interface SubmoduleFixture {
    gitJob: ReturnType<typeof createStudioGit>;
    repo: string;
    childSeed: string;
  }

  async function prepareSubmoduleCheckout(fx: Fixture): Promise<SubmoduleFixture> {
    const { gitJob } = await cloneFixture(fx);
    const repo = join(fx.workspace, "app");
    const childRemote = join(fx.root, "child.git");
    const childSeed = join(fx.root, "child-seed");
    await git(fx.root, "init", "--bare", "-b", "main", "child.git");
    await git(fx.root, "init", "-b", "main", "child-seed");
    writeFileSync(join(childSeed, "child.txt"), "initial child\n");
    await git(childSeed, "add", ".");
    await git(childSeed, "commit", "-m", "initial child");
    await git(childSeed, "remote", "add", "origin", `file://${childRemote}`);
    await git(childSeed, "push", "-u", "origin", "main");

    await git(
      fx.seed,
      "-c",
      "protocol.file.allow=always",
      "submodule",
      "add",
      `file://${childRemote}`,
      "modules/child",
    );
    await git(fx.seed, "commit", "-m", "add child submodule");
    await git(fx.seed, "push", "origin", "main");
    // Setup only: prevent the initial local-file submodule fetch from being
    // confused with the hostile recursive-fetch case exercised below.
    await git(repo, "config", "fetch.recurseSubmodules", "false");
    await gitJob.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN });
    await git(
      repo,
      "-c",
      "protocol.file.allow=always",
      "submodule",
      "update",
      "--init",
      "modules/child",
    );
    return { gitJob, repo, childSeed };
  }

  async function advanceSubmodule(
    fx: Fixture,
    childSeed: string,
    branch: "main" | "feature",
  ): Promise<void> {
    if (branch === "feature") await git(fx.seed, "checkout", "-b", branch);
    writeFileSync(join(childSeed, `change-${branch}.txt`), `${branch} child\n`);
    await git(childSeed, "add", ".");
    await git(childSeed, "commit", "-m", `${branch} child update`);
    await git(childSeed, "push", "origin", "main");
    const childInSeed = join(fx.seed, "modules", "child");
    await git(childInSeed, "fetch", "origin", "main");
    await git(childInSeed, "checkout", "FETCH_HEAD");
    await git(fx.seed, "add", "modules/child");
    await git(fx.seed, "commit", "-m", `${branch} submodule update`);
    await git(fx.seed, "push", "-u", "origin", branch);
    if (branch === "feature") await git(fx.seed, "checkout", "main");
  }

  it("does not recurse into a hostile submodule endpoint during sync", async () => {
    const fx = await fixture();
    const sub = await prepareSubmoduleCheckout(fx);
    await advanceSubmodule(fx, sub.childSeed, "main");
    const trap = await credentialTrap();
    try {
      const childGitDir = (
        await git(join(sub.repo, "modules", "child"), "rev-parse", "--absolute-git-dir")
      ).trim();
      await git(sub.repo, "config", "fetch.recurseSubmodules", "yes");
      await git(sub.repo, "config", "submodule.modules/child.url", trap.url);
      const real = createSpawnGitRunner();
      let fetchArgv: string[] | undefined;
      const runner: GitRunner = async (req) => {
        if (!req.argv.includes("fetch")) return real(req);
        fetchArgv = [...req.argv];
        const modules = join(sub.repo, ".gitmodules");
        const original = readFileSync(modules, "utf8");
        const childConfig = join(childGitDir, "config");
        const childOriginal = readFileSync(childConfig, "utf8");
        writeFileSync(modules, original.replace(/url = .*/, `url = ${trap.url}`));
        writeFileSync(childConfig, childOriginal.replace(/url = .*/, `url = ${trap.url}`));
        expect(readFileSync(childConfig, "utf8")).toContain(`url = ${trap.url}`);
        try {
          return await real(req);
        } finally {
          writeFileSync(modules, original);
          writeFileSync(childConfig, childOriginal);
        }
      };
      const hardened = createStudioGit({
        manager: fx.manager,
        allowLocalUrls: true,
        credentialDir: fx.helperDir,
        runner,
        log: () => {},
      });
      let caught: unknown;
      try {
        await hardened.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN });
      } catch (err) {
        caught = err;
      }
      expect.soft(trap.contacts).toBe(0);
      expect.soft(trap.sawToken).toBe(false);
      expect(caught).toBeUndefined();
      expect(fetchArgv).toBeDefined();
      expect(fetchArgv).toContain("--no-recurse-submodules");
    } finally {
      await trap.close();
    }
  });

  it("does not recurse into a hostile submodule endpoint during branch fetch", async () => {
    const fx = await fixture();
    const sub = await prepareSubmoduleCheckout(fx);
    await advanceSubmodule(fx, sub.childSeed, "feature");
    const trap = await credentialTrap();
    try {
      const childGitDir = (
        await git(join(sub.repo, "modules", "child"), "rev-parse", "--absolute-git-dir")
      ).trim();
      await git(sub.repo, "config", "fetch.recurseSubmodules", "yes");
      await git(sub.repo, "config", "submodule.modules/child.url", trap.url);
      const real = createSpawnGitRunner();
      let fetchArgv: string[] | undefined;
      const runner: GitRunner = async (req) => {
        if (!req.argv.includes("fetch")) return real(req);
        fetchArgv = [...req.argv];
        const modules = join(sub.repo, ".gitmodules");
        const original = readFileSync(modules, "utf8");
        const childConfig = join(childGitDir, "config");
        const childOriginal = readFileSync(childConfig, "utf8");
        writeFileSync(modules, original.replace(/url = .*/, `url = ${trap.url}`));
        writeFileSync(childConfig, childOriginal.replace(/url = .*/, `url = ${trap.url}`));
        expect(readFileSync(childConfig, "utf8")).toContain(`url = ${trap.url}`);
        try {
          return await real(req);
        } finally {
          writeFileSync(modules, original);
          writeFileSync(childConfig, childOriginal);
        }
      };
      const hardened = createStudioGit({
        manager: fx.manager,
        allowLocalUrls: true,
        credentialDir: fx.helperDir,
        runner,
        log: () => {},
      });
      let caught: unknown;
      try {
        await hardened.switchBranch({
          userId: "user-1",
          repoDir: "app",
          branch: "feature",
          token: TOKEN,
        });
      } catch (err) {
        caught = err;
      }
      expect.soft(trap.contacts).toBe(0);
      expect.soft(trap.sawToken).toBe(false);
      expect(caught).toBeUndefined();
      expect(fetchArgv).toBeDefined();
      expect(fetchArgv).toContain("--no-recurse-submodules");
    } finally {
      await trap.close();
    }
  });
});
