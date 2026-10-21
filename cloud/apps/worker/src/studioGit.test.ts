import { execFile } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { afterAll, describe, expect, it } from "vitest";
import type { SandboxManager } from "@ovid/sandbox";

import {
  StudioGitError,
  assertSafeBranch,
  createPerUserGithubTokenResolver,
  createSpawnGitRunner,
  createStudioGit,
  createStudioGitProcessor,
  defaultRepoDir,
  normalizeRepoUrl,
  safeRelDir,
  safeRepoDirName,
  type GitCommandRequest,
  type GitRunner,
  type StudioGitJob,
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
  /** Root-owned helper dir, outside the agent-writable home. */
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

/** Records every git request and delegates to the real spawn runner. */
function recordingRunner(): {
  runner: GitRunner;
  calls: GitCommandRequest[];
  envRefs: Array<Record<string, string>>;
  askpass: Array<{ path: string; existed: boolean; mode: number }>;
} {
  const calls: GitCommandRequest[] = [];
  const envRefs: Array<Record<string, string>> = [];
  const askpass: Array<{ path: string; existed: boolean; mode: number }> = [];
  const real = createSpawnGitRunner();
  const runner: GitRunner = async (req) => {
    // Snapshot the env as it was DURING the call; keep a reference too, to
    // prove the job unsets the token after the operation.
    calls.push({ ...req, argv: [...req.argv], env: { ...req.env } });
    envRefs.push(req.env);
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
  return { runner, calls, envRefs, askpass };
}

// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------

describe("Studio clone", () => {
  it("clones with an ephemeral askpass helper and leaves no token in config, argv or logs", async () => {
    const fx = await fixture();
    const logs: string[] = [];
    const rec = recordingRunner();
    const { gitJob, result } = await cloneFixture(fx, {
      runner: rec.runner,
      log: (l) => logs.push(l),
    });

    expect(result).toEqual({ status: "cloned", repoDir: "app", branch: "main" });
    expect(readFileSync(join(fx.workspace, "app", "README.md"), "utf8")).toBe("hello\n");

    // 1. .git/config carries no token and no credential-bearing URL.
    const config = configText(join(fx.workspace, "app"));
    expect(config).not.toContain(TOKEN);
    expect(config).toMatch(/url = file:\/\//);

    // 2. The token never appears in an argv element (argv is world-readable).
    expect(rec.calls.length).toBeGreaterThan(0);
    for (const call of rec.calls) {
      for (const arg of call.argv) expect(arg).not.toContain(TOKEN);
      // …but it WAS delivered through the child environment.
      expect(call.env.GIT_ASKPASS).toBeDefined();
      expect(call.env.GIT_TERMINAL_PROMPT).toBe("0");
      expect(call.env.OVID_GIT_TOKEN).toBe(TOKEN);
    }

    // …and the env handed to the runner was unset after the operation.
    for (const ref of rec.envRefs) {
      expect(ref.OVID_GIT_TOKEN).toBeUndefined();
      expect(ref.GIT_ASKPASS).toBeUndefined();
    }

    // 3. The helper existed, owner-only, during the operation.
    expect(rec.askpass.length).toBeGreaterThan(0);
    for (const seen of rec.askpass) {
      expect(seen.existed).toBe(true);
      // Never writable by group/other (the sandbox uid): the agent can
      // execute the helper but cannot replace it.
      expect(seen.mode & 0o022).toBe(0);
      expect(seen.mode & 0o111).not.toBe(0);
    }

    // 4. The helper lived OUTSIDE the agent-writable home and was deleted
    //    afterwards, together with the isolation config.
    expect(existsSync(join(fx.home, ".ovid"))).toBe(false);
    expect(existsSync(fx.helperDir)).toBe(true);
    expect(readdirSync(fx.helperDir)).toEqual([]);

    // 5. No log line carried the token.
    expect(logs.length).toBeGreaterThan(0);
    for (const line of logs) expect(line).not.toContain(TOKEN);

    // The cloned repo is usable and the token is gone from the credential env.
    const status = await gitJob.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN });
    expect(status.status).toBe("up_to_date");
  });

  it("removes the helper when the clone fails, and redacts the token from the error", async () => {
    const fx = await fixture();
    const logs: string[] = [];
    const failing: GitRunner = async (req) => {
      if (req.argv.includes("clone")) {
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
      await gitJob.clone({ userId: "user-1", repo: fx.remoteUrl, token: TOKEN });
    } catch (err) {
      caught = err;
    }
    expect(caught).toBeInstanceOf(StudioGitError);
    expect((caught as StudioGitError).code).toBe("clone_failed");
    expect((caught as Error).message).not.toContain(TOKEN);
    // Fixed user-facing message: raw git stderr (internal hosts/paths) never
    // reaches the caller.
    expect((caught as Error).message).not.toContain("github.com/acme/app");
    expect((caught as Error).message).toMatch(/Could not clone the repository/);
    for (const line of logs) expect(line).not.toContain(TOKEN);

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

    // A deployment-configured allowlist is honoured, exact-host only.
    const opts = { allowedHosts: ["github.com", "git.corp.example"] };
    expect(normalizeRepoUrl("https://git.corp.example/acme/app.git", opts)).toBe(
      "https://git.corp.example/acme/app.git",
    );
    expect(() => normalizeRepoUrl("https://evil.example/acme/app.git", opts)).toThrow(
      /approved git host/,
    );
  });

  it("logs only host + repo (never URL query credentials)", async () => {
    const fx = await fixture();
    const logs: string[] = [];
    // The allowlist rejects query strings, but a configured host may still
    // have a long path; pin that the log is built from host+repo, not the raw
    // URL. normalizeRepoUrl returned this value, so exercise displayRepo via a
    // successful local clone log line instead.
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
    const rec = recordingRunner();
    const { gitJob } = await cloneFixture(fx, { runner: rec.runner });

    writeFileSync(join(fx.seed, "next.txt"), "remote change\n");
    await git(fx.seed, "add", ".");
    await git(fx.seed, "commit", "-m", "remote change");
    await git(fx.seed, "push", "origin", "main");

    const result = await gitJob.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN });
    expect(result).toMatchObject({ status: "synced", dirty: false, behind: 1, branch: "main" });
    expect(readFileSync(join(fx.workspace, "app", "next.txt"), "utf8")).toBe("remote change\n");

    // A second click is a no-op.
    const again = await gitJob.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN });
    expect(again.status).toBe("up_to_date");

    // Never force: no reset/force flags anywhere in the recorded argv.
    for (const call of rec.calls) {
      expect(call.argv).not.toContain("--force");
      expect(call.argv).not.toContain("reset");
      expect(call.argv).not.toContain("--hard");
    }
    expect(configText(join(fx.workspace, "app"))).not.toContain(TOKEN);

    // The fetch forces the server-derived remote, so a repo-level origin edit
    // cannot change where the token goes.
    const fetchCall = rec.calls.find((call) => call.argv.includes("fetch"));
    expect(fetchCall).toBeDefined();
    expect(fetchCall!.argv.join("\n")).toContain(`remote.origin.url=${fx.remoteUrl}`);
  });

  it("forces TLS verification and disables repo-controlled proxies on https remotes", async () => {
    const fx = await fixture();
    // A bare directory with a real .git dir is enough: the runner is faked, so
    // no network is touched and no valid git metadata is needed.
    mkdirSync(join(fx.workspace, "fake", ".git"), { recursive: true });
    const calls: GitCommandRequest[] = [];
    const runner: GitRunner = async (req) => {
      calls.push(req);
      if (req.argv.includes("config") || req.argv.includes("get-url")) {
        return {
          code: 0,
          stdout: "https://github.com/acme/app.git\n",
          stderr: "",
          timedOut: false,
        };
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
    // A repo-level sslVerify=false never runs as the effective setting.
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

    // No git command was ever pointed at the attacker host.
    for (const call of rec.calls.slice(before)) {
      expect(call.argv.join(" ")).not.toContain("evil.example");
    }
  });

  it("refuses a repo-level url.insteadOf rewrite of the remote", async () => {
    const fx = await fixture();
    const { gitJob } = await cloneFixture(fx);
    const repo = join(fx.workspace, "app");
    const config =
      configText(repo) +
      `[url "file://${fx.root}/evil/"]\n\tinsteadOf = file://${fx.remote}\n`;
    writeFileSync(join(repo, ".git", "config"), config);

    await expect(
      gitJob.syncLatest({ userId: "user-1", repoDir: "app", token: TOKEN }),
    ).rejects.toMatchObject({ code: "fetch_failed" });
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
    // The user's edit is still there and the remote file was NOT checked out.
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
    // No merge commit was created: HEAD is still the user's commit.
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
    const { gitJob } = await cloneFixture(fx);
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

    // The switch happened and the worktree is clean.
    expect(readFileSync(join(repo, "feature.txt"), "utf8")).toBe("feature\n");
    expect((await git(repo, "status", "--porcelain")).trim()).toBe("");
    expect(await git(repo, "stash", "list")).toContain("before switching");

    // The uncommitted edit is in the stash, not lost.
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

describe("Studio git processor", () => {
  const job: StudioGitJob = { op: "sync", userId: "user-1", repoDir: "app" };

  it("refuses to run without a token", async () => {
    const processor = createStudioGitProcessor({
      git: {
        clone: async () => {
          throw new Error("unreachable");
        },
        syncLatest: async () => {
          throw new Error("unreachable");
        },
        switchBranch: async () => {
          throw new Error("unreachable");
        },
      },
      tokenFor: async () => null,
      log: () => {},
    });
    await expect(processor(job)).rejects.toMatchObject({ code: "token_unavailable" });
  });

  it("dispatches sync with the resolved token and returns only the result", async () => {
    const seen: string[] = [];
    const processor = createStudioGitProcessor({
      git: {
        clone: async () => {
          throw new Error("unreachable");
        },
        syncLatest: async (req) => {
          seen.push(req.token);
          return {
            status: "up_to_date",
            dirty: false,
            behind: 0,
            ahead: 0,
            branch: "main",
            message: "Up to date.",
          };
        },
        switchBranch: async () => {
          throw new Error("unreachable");
        },
      },
      tokenFor: async () => TOKEN,
      log: () => {},
    });

    const outcome = await processor(job);
    expect(outcome).toEqual({
      op: "sync",
      result: {
        status: "up_to_date",
        dirty: false,
        behind: 0,
        ahead: 0,
        branch: "main",
        message: "Up to date.",
      },
    });
    expect(seen).toEqual([TOKEN]);
    expect(JSON.stringify(outcome)).not.toContain(TOKEN);
  });

  it("resolves the token per user and passes the repo to the resolver", async () => {
    const requests: Array<{ userId: string; repo?: string; repoDir?: string }> = [];
    const tokensSeen: string[] = [];
    const processor = createStudioGitProcessor({
      git: {
        clone: async (req) => {
          tokensSeen.push(req.token);
          return { status: "cloned", repoDir: "app", branch: "main" };
        },
        syncLatest: async () => {
          throw new Error("unreachable");
        },
        switchBranch: async () => {
          throw new Error("unreachable");
        },
      },
      // Per-user lookup: user-2 has a token, user-1 does not.
      tokenFor: async (req) => {
        requests.push(req);
        return req.userId === "user-2" ? "token-for-user-2" : null;
      },
      log: () => {},
    });

    await processor({ op: "clone", userId: "user-2", repo: "acme/app" });
    expect(requests).toEqual([{ userId: "user-2", repo: "acme/app" }]);
    expect(tokensSeen).toEqual(["token-for-user-2"]);

    // No token for that user ⇒ refuse, never fall back to another user's.
    await expect(
      processor({ op: "sync", userId: "user-1", repoDir: "app" }),
    ).rejects.toMatchObject({ code: "token_unavailable" });
    expect(tokensSeen).toEqual(["token-for-user-2"]);
  });

  it("reads the per-user GitHub token from that user's own integration only", async () => {
    const rows: Record<string, Array<{ id: string; curatedId: string | null; enabled?: boolean; secretsSealed: unknown }>> = {
      "user-2": [
        { id: "srv-2", curatedId: "github", enabled: true, secretsSealed: { sealed: "user-2" } },
      ],
      "user-3": [
        { id: "srv-3", curatedId: "github", enabled: false, secretsSealed: { sealed: "user-3" } },
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
    // Disabled integration or unknown user ⇒ no token, never the deployment's.
    await expect(resolver({ userId: "user-3" })).resolves.toBeNull();
    await expect(resolver({ userId: "user-1" })).resolves.toBeNull();
  });
});
