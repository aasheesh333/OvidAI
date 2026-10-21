/**
 * Studio git job (P0 "Studio credential helper").
 *
 * The worker-side half of Studio repo binding: clone a repository into the
 * session's cloud workspace, run the one-click "Sync latest changes" fetch +
 * fast-forward, and switch branches without ever losing uncommitted work.
 *
 * Credential model (see @ovid/sandbox `gitCredential.ts`):
 *
 *   - the token is passed to `git` ONLY through the child's environment
 *     (`GIT_ASKPASS` + `OVID_GIT_TOKEN`), never as an argv element;
 *   - the askpass helper is created for exactly one operation and deleted in
 *     a `finally`; the env object is cleared by `dispose()`;
 *   - every operation re-scans `.git/config` (and its own argv) for the
 *     token before reporting success;
 *   - every log line and error message goes through `redactToken`.
 *
 * Why a host-side git process rather than `SandboxHandle.exec`? The jail
 * layer injects `ExecRequest.env` into bwrap's `--setenv` argv, which would
 * put the token on a world-readable `/proc/<pid>/cmdline`. The git child
 * here is spawned directly (argv = git arguments only), runs as the sandbox
 * uid/gid against the same workspace tree the jail mounts at /workspace, and
 * therefore keeps the "never in argv" promise. File ownership is preserved
 * because the child runs as the sandbox uid.
 *
 * Sync semantics (product spec §7): fetch is always safe; the working tree
 * is fast-forwarded ONLY when it is clean and HEAD is an ancestor of the
 * upstream. A dirty tree or a diverged history reports `needs_merge` — no
 * merge commit, no reset, no force, ever.
 */

import { spawn, type ChildProcess } from "node:child_process";
import { access, rm, stat } from "node:fs/promises";
import { basename, isAbsolute, join, resolve, sep } from "node:path";

import {
  GIT_ASKPASS_ENV,
  GIT_ASKPASS_REQUIRE_ENV,
  GIT_TOKEN_ENV,
  assertNoCredentialLeak,
  installGitCredential,
  redactToken,
  type GitCredential,
} from "@ovid/sandbox/gitCredential";
import type { SandboxManager } from "@ovid/sandbox";

// ---------------------------------------------------------------------------
// Git process seam
// ---------------------------------------------------------------------------

export interface GitCommandRequest {
  /** git arguments — NEVER include the token here. */
  argv: string[];
  cwd: string;
  /** The child environment, including the ephemeral credential env. */
  env: Record<string, string>;
  /** Sandbox uid to drop to (root only); omitted in tests/non-root. */
  uid?: number;
  timeoutMs?: number;
}

export interface GitCommandResult {
  code: number | null;
  stdout: string;
  stderr: string;
  timedOut: boolean;
}

export type GitRunner = (req: GitCommandRequest) => Promise<GitCommandResult>;

const OUTPUT_CAP_BYTES = 256 * 1024;
const DEFAULT_TIMEOUT_MS = 300_000;

/** The production runner: `git` spawned directly, no shell, no argv secret. */
export function createSpawnGitRunner(): GitRunner {
  return (req) =>
    new Promise<GitCommandResult>((resolvePromise, reject) => {
      const uid =
        typeof process.getuid === "function" && process.getuid() === 0 ? req.uid : undefined;
      let child: ChildProcess;
      try {
        child = spawn("git", req.argv, {
          cwd: req.cwd,
          env: req.env,
          stdio: ["ignore", "pipe", "pipe"],
          // Root only: run as the sandbox uid so cloned files belong to the
          // jail user. A non-root harness already runs as its own uid.
          ...(uid !== undefined ? { uid, gid: uid } : {}),
        });
      } catch (err) {
        reject(err);
        return;
      }

      const out: Buffer[] = [];
      const errOut: Buffer[] = [];
      let outBytes = 0;
      let errBytes = 0;
      let timedOut = false;

      const keep = (chunks: Buffer[], bytes: number, chunk: Buffer): number => {
        if (bytes >= OUTPUT_CAP_BYTES) return bytes;
        const room = OUTPUT_CAP_BYTES - bytes;
        chunks.push(chunk.length <= room ? chunk : chunk.subarray(0, room));
        return bytes + Math.min(chunk.length, room);
      };

      child.stdout?.on("data", (chunk: Buffer) => {
        outBytes = keep(out, outBytes, chunk);
      });
      child.stderr?.on("data", (chunk: Buffer) => {
        errBytes = keep(errOut, errBytes, chunk);
      });

      const timeoutMs = Math.min(req.timeoutMs ?? DEFAULT_TIMEOUT_MS, 900_000);
      const timer = setTimeout(() => {
        timedOut = true;
        child.kill("SIGKILL");
      }, timeoutMs);
      timer.unref?.();

      child.once("error", (err) => {
        clearTimeout(timer);
        reject(err);
      });
      child.once("exit", (code) => {
        clearTimeout(timer);
        resolvePromise({
          code,
          stdout: Buffer.concat(out).toString("utf8"),
          stderr: Buffer.concat(errOut).toString("utf8"),
          timedOut,
        });
      });
    });
}

// ---------------------------------------------------------------------------
// Errors + result shapes
// ---------------------------------------------------------------------------

export type StudioGitErrorCode =
  | "invalid_repo"
  | "invalid_path"
  | "invalid_branch"
  | "destination_exists"
  | "not_a_repo"
  | "clone_failed"
  | "fetch_failed"
  | "sync_failed"
  | "stash_failed"
  | "switch_failed"
  | "token_unavailable"
  | "credential_leak";

/** A typed failure with a user-safe message (never contains the token). */
export class StudioGitError extends Error {
  readonly name = "StudioGitError";

  constructor(
    readonly code: StudioGitErrorCode,
    message: string,
    /** Present when uncommitted work is sitting in a stash. */
    readonly stashRef?: string,
  ) {
    super(message);
  }
}

export type StudioSyncReason = "dirty_worktree" | "diverged" | "no_upstream" | "merge_failed";

export interface StudioSyncResult {
  status: "up_to_date" | "synced" | "needs_merge";
  dirty: boolean;
  behind: number;
  ahead: number;
  branch: string;
  message: string;
  reason?: StudioSyncReason;
}

export interface StudioCloneResult {
  status: "cloned";
  /** Workspace-relative repo directory (what the Studio binding stores). */
  repoDir: string;
  branch: string;
}

export interface StudioSwitchResult {
  status: "switched" | "unchanged" | "failed";
  branch: string;
  stashed: boolean;
  stashRef?: string;
  stashNote?: string;
  message: string;
}

export interface StudioGit {
  clone(req: {
    userId: string;
    sessionId?: string;
    repo: string;
    branch?: string;
    dest?: string;
    token: string;
  }): Promise<StudioCloneResult>;
  syncLatest(req: {
    userId: string;
    sessionId?: string;
    repoDir?: string;
    token: string;
  }): Promise<StudioSyncResult>;
  switchBranch(req: {
    userId: string;
    sessionId?: string;
    repoDir?: string;
    branch: string;
    token: string;
  }): Promise<StudioSwitchResult>;
}

export interface StudioGitDeps {
  manager: Pick<SandboxManager, "attach">;
  runner?: GitRunner;
  log?: (line: string) => void;
  /** Test-only: allow file:// remotes (production is https only). */
  allowLocalUrls?: boolean;
  now?: () => Date;
}

// ---------------------------------------------------------------------------
// Validation helpers
// ---------------------------------------------------------------------------

const GITHUB_SHORTHAND = /^[\w.-]+\/[\w.-]+$/;

/**
 * Normalizes `owner/name` to a GitHub https URL and rejects anything that
 * could smuggle a credential (userinfo, non-https scheme, ssh/scp form —
 * askpass cannot answer those prompts).
 */
export function normalizeRepoUrl(repo: string, opts: { allowLocalUrls?: boolean } = {}): string {
  const raw = repo.trim();
  if (raw === "") throw new StudioGitError("invalid_repo", "Choose a repository first.");
  if (GITHUB_SHORTHAND.test(raw)) return `https://github.com/${raw}.git`;

  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new StudioGitError("invalid_repo", "That repository address is not a URL we can clone.");
  }
  if (url.username !== "" || url.password !== "") {
    throw new StudioGitError(
      "invalid_repo",
      "The repository address contains a credential. Connect GitHub instead.",
    );
  }
  const local = url.protocol === "file:";
  if (local && opts.allowLocalUrls === true) return url.toString();
  if (url.protocol !== "https:") {
    throw new StudioGitError("invalid_repo", "Studio clones repositories over https only.");
  }
  if (url.hostname === "") throw new StudioGitError("invalid_repo", "That repository has no host.");
  return url.toString();
}

/** Default clone directory: the repo name, without `.git`. */
export function defaultRepoDir(repoUrl: string): string {
  const path = new URL(repoUrl).pathname.replace(/\/+$/, "");
  const name = basename(path).replace(/\.git$/i, "");
  if (name === "" || name === "." || name === "..") {
    throw new StudioGitError("invalid_path", "Could not derive a folder name for this repository.");
  }
  return name;
}

/** A workspace-relative directory with no escapes and no option-looking names. */
export function safeRelDir(raw: string): string {
  const value = raw.trim();
  if (value === "" || value === ".") return ".";
  if (isAbsolute(value) || value.includes("\0") || value.startsWith("-")) {
    throw new StudioGitError("invalid_path", "That folder name is not allowed in a workspace.");
  }
  const parts = value.split("/");
  for (const part of parts) {
    if (part === "" || part === "." || part === "..") {
      throw new StudioGitError("invalid_path", "That folder name is not allowed in a workspace.");
    }
  }
  return parts.join("/");
}

/**
 * A clone destination is exactly ONE folder in the workspace. Nesting is
 * refused: the parent would be created by the worker (root), not by git as
 * the sandbox uid, and would end up unwritable for the jail user.
 */
export function safeRepoDirName(raw: string): string {
  const value = raw.trim();
  if (
    value === "" ||
    value === "." ||
    value === ".." ||
    value.includes("/") ||
    value.includes("\\") ||
    value.includes("\0") ||
    isAbsolute(value) ||
    value.startsWith("-")
  ) {
    throw new StudioGitError("invalid_path", "That folder name is not allowed in a workspace.");
  }
  return value;
}

/** Branch names git accepts, minus anything that looks like an option. */
export function assertSafeBranch(branch: string): void {
  const value = branch.trim();
  if (value === "" || value.startsWith("-")) {
    throw new StudioGitError("invalid_branch", "Choose a branch first.");
  }
  if (/[\s~^:?*[\\]/.test(value) || value.includes("..") || value.includes("@{") || value.endsWith(".") || value.endsWith(".lock")) {
    throw new StudioGitError("invalid_branch", `"${value}" is not a valid branch name.`);
  }
}

function isErrnoException(err: unknown): err is NodeJS.ErrnoException {
  return err instanceof Error && "code" in err;
}

async function exists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch (err) {
    if (isErrnoException(err) && err.code === "ENOENT") return false;
    throw err;
  }
}

/** Resolve a workspace-relative dir, refusing anything that escapes it. */
function resolveWorkspaceDir(workspaceDir: string, rel: string | undefined): string {
  const relDir = safeRelDir(rel ?? ".");
  const root = resolve(workspaceDir);
  const dir = resolve(root, relDir);
  if (dir !== root && !dir.startsWith(`${root}${sep}`)) {
    throw new StudioGitError("invalid_path", "That folder is outside the workspace.");
  }
  return dir;
}

async function assertGitRepo(dir: string): Promise<void> {
  let isDir = false;
  try {
    isDir = (await stat(join(dir, ".git"))).isDirectory();
  } catch (err) {
    if (!isErrnoException(err) || err.code !== "ENOENT") throw err;
  }
  if (!isDir) {
    throw new StudioGitError("not_a_repo", "This folder is not a git repository yet.");
  }
}

// ---------------------------------------------------------------------------
// The job
// ---------------------------------------------------------------------------

/** Every git invocation is prefixed to disable ambient credential helpers. */
function gitArgv(args: string[]): string[] {
  // `-c credential.helper=` clears any helper list inherited from config, so
  // the only source of credentials is our ephemeral askpass env.
  return ["-c", "credential.helper=", ...args];
}

function firstLine(text: string): string {
  return text.trim().split("\n")[0]?.trim() ?? "";
}

export function createStudioGit(deps: StudioGitDeps): StudioGit {
  const runner = deps.runner ?? createSpawnGitRunner();
  const now = deps.now ?? (() => new Date());
  const log = deps.log ?? ((line: string) => console.log(line));

  const baseEnv = (homeDir: string): Record<string, string> => ({
    PATH: process.env.PATH ?? "/usr/local/bin:/usr/bin:/bin",
    HOME: homeDir,
    LANG: "C.UTF-8",
    LC_ALL: "C",
  });

  /**
   * One operation = one credential. The token never leaves this function's
   * scope except as the child env; dispose runs in every exit path.
   */
  const withCredential = async <T>(
    handle: { homeDir: string; uid: number },
    token: string,
    fn: (ctx: {
      cred: GitCredential;
      env: Record<string, string>;
      run: (args: string[], cwd: string, timeoutMs?: number) => Promise<GitCommandResult>;
      logSafe: (line: string) => void;
      fail: (code: StudioGitErrorCode, message: string, stashRef?: string) => never;
    }) => Promise<T>,
  ): Promise<T> => {
    const cred = await installGitCredential({
      homeDir: handle.homeDir,
      token,
      uid: handle.uid,
      visibleHomeDir: handle.homeDir,
    });
    const env = { ...baseEnv(handle.homeDir), ...cred.env };
    const logSafe = (line: string): void => log(redactToken(line, token));
    const fail = (code: StudioGitErrorCode, message: string, stashRef?: string): never => {
      throw new StudioGitError(code, redactToken(message, token), stashRef);
    };
    const run = (args: string[], cwd: string, timeoutMs?: number): Promise<GitCommandResult> =>
      runner({
        argv: gitArgv(args),
        cwd,
        env,
        uid: handle.uid,
        timeoutMs,
      });
    try {
      return await fn({ cred, env, run, logSafe, fail });
    } finally {
      // Deleting the helper and clearing the env is unconditional — a failed
      // clone must not leave an askpass script (or a live token env) behind.
      // `env` is the merged object actually handed to the runner, so clear it
      // too: a runner that retains the request must not retain the secret.
      delete env[GIT_TOKEN_ENV];
      delete env[GIT_ASKPASS_ENV];
      delete env[GIT_ASKPASS_REQUIRE_ENV];
      delete env.OVID_GIT_USERNAME;
      await cred.dispose();
    }
  };

  return {
    async clone(req) {
      const url = normalizeRepoUrl(req.repo, { allowLocalUrls: deps.allowLocalUrls });
      const requested = req.dest?.trim() ?? "";
      const relDir = safeRepoDirName(requested === "" ? defaultRepoDir(url) : requested);
      const handle = await deps.manager.attach(req.userId);
      const dest = resolveWorkspaceDir(handle.workspaceDir, relDir);
      if (await exists(dest)) {
        throw new StudioGitError(
          "destination_exists",
          `The folder "${relDir}" already exists in this workspace.`,
        );
      }

      const branch = req.branch?.trim() ?? "";
      if (branch !== "") assertSafeBranch(branch);

      return withCredential(handle, req.token, async ({ run, logSafe, fail }) => {
        const args = ["clone"];
        if (branch !== "") args.push("--branch", branch);
        args.push("--", url, relDir);
        logSafe(`[studio-git] clone start: ${url} -> ${relDir}`);
        const res = await run(args, handle.workspaceDir);
        if (res.code !== 0) {
          // The destination did not exist before this call, so removing a
          // partial clone cannot destroy user data.
          await removePartialClone(dest);
          fail("clone_failed", `Could not clone the repository. ${firstLine(res.stderr)}`);
        }
        await assertNoCredentialLeak({ repoDir: dest, token: req.token, argv: args });

        const head = await run(["rev-parse", "--abbrev-ref", "HEAD"], dest);
        const actualBranch = head.code === 0 ? head.stdout.trim() : branch;
        logSafe(`[studio-git] clone ok: ${relDir} (${actualBranch})`);
        return { status: "cloned" as const, repoDir: relDir, branch: actualBranch };
      });
    },

    async syncLatest(req) {
      const handle = await deps.manager.attach(req.userId);
      const dir = resolveWorkspaceDir(handle.workspaceDir, req.repoDir);
      await assertGitRepo(dir);

      return withCredential(handle, req.token, async ({ run, logSafe, fail }) => {
        // Fetch is safe with any working-tree state; it never touches local
        // files or branches (no --force, no prune of local refs beyond origin).
        const fetched = await run(["fetch", "--prune", "origin"], dir);
        if (fetched.code !== 0) {
          fail("fetch_failed", `Could not reach the remote. ${firstLine(fetched.stderr)}`);
        }

        const status = await run(["status", "--porcelain"], dir);
        const dirty = status.stdout.trim() !== "";
        const branchRes = await run(["rev-parse", "--abbrev-ref", "HEAD"], dir);
        const branch = branchRes.code === 0 ? branchRes.stdout.trim() : "";

        const upstream = await run(
          ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
          dir,
        );
        if (upstream.code !== 0) {
          return {
            status: "needs_merge" as const,
            dirty,
            behind: 0,
            ahead: 0,
            branch,
            reason: "no_upstream" as const,
            message: "This branch has no upstream. Publish it before syncing.",
          };
        }

        const behindRes = await run(["rev-list", "--count", "HEAD..@{upstream}"], dir);
        const aheadRes = await run(["rev-list", "--count", "@{upstream}..HEAD"], dir);
        const behind = Number.parseInt(behindRes.stdout.trim(), 10) || 0;
        const ahead = Number.parseInt(aheadRes.stdout.trim(), 10) || 0;

        if (dirty) {
          logSafe(`[studio-git] sync needs_merge: dirty worktree (${behind} behind)`);
          return {
            status: "needs_merge" as const,
            dirty: true,
            behind,
            ahead,
            branch,
            reason: "dirty_worktree" as const,
            message:
              behind > 0
                ? "You have uncommitted changes. Commit or stash them before syncing."
                : "You have uncommitted changes. There is nothing new to pull.",
          };
        }

        if (behind === 0) {
          logSafe(`[studio-git] sync up_to_date: ${branch} (${ahead} ahead)`);
          return {
            status: "up_to_date" as const,
            dirty: false,
            behind: 0,
            ahead,
            branch,
            message: ahead > 0 ? "Up to date. You have local commits to push." : "Up to date.",
          };
        }

        // Fast-forward only when HEAD is an ancestor of upstream. A diverged
        // history is a merge decision for the user, never ours.
        const ancestor = await run(["merge-base", "--is-ancestor", "HEAD", "@{upstream}"], dir);
        if (ancestor.code !== 0) {
          logSafe(`[studio-git] sync needs_merge: diverged (${behind} behind, ${ahead} ahead)`);
          return {
            status: "needs_merge" as const,
            dirty: false,
            behind,
            ahead,
            branch,
            reason: "diverged" as const,
            message: "The remote and your branch have both changed. Review the diff to merge.",
          };
        }

        const merged = await run(["merge", "--ff-only", "@{upstream}"], dir);
        if (merged.code !== 0) {
          logSafe(`[studio-git] sync merge failed: ${firstLine(merged.stderr)}`);
          return {
            status: "needs_merge" as const,
            dirty: false,
            behind,
            ahead,
            branch,
            reason: "merge_failed" as const,
            message: "Could not fast-forward. Review the diff to merge.",
          };
        }
        await assertNoCredentialLeak({ repoDir: dir, token: req.token, argv: ["merge", "--ff-only"] });
        logSafe(`[studio-git] sync ok: ${branch} fast-forwarded ${behind}`);
        return {
          status: "synced" as const,
          dirty: false,
          behind,
          ahead,
          branch,
          message: `Updated to the latest ${behind} change${behind === 1 ? "" : "s"}.`,
        };
      });
    },

    async switchBranch(req) {
      assertSafeBranch(req.branch);
      const target = req.branch.trim();
      const handle = await deps.manager.attach(req.userId);
      const dir = resolveWorkspaceDir(handle.workspaceDir, req.repoDir);
      await assertGitRepo(dir);

      return withCredential(handle, req.token, async ({ run, logSafe, fail }) => {
        const currentRes = await run(["rev-parse", "--abbrev-ref", "HEAD"], dir);
        const current = currentRes.code === 0 ? currentRes.stdout.trim() : "";
        if (current === target) {
          return {
            status: "unchanged" as const,
            branch: target,
            stashed: false,
            message: `Already on ${target}.`,
          };
        }

        // Make sure the branch exists locally; a remote-only branch is
        // fetched first so `switch` can create the tracking branch.
        const local = await run(
          ["rev-parse", "--verify", "--quiet", `refs/heads/${target}`],
          dir,
        );
        let createTracking = false;
        if (local.code !== 0) {
          const fetched = await run(["fetch", "origin", target], dir);
          if (fetched.code !== 0) {
            fail("switch_failed", `Could not find the branch "${target}" on the remote.`);
          }
          createTracking = true;
        }

        const status = await run(["status", "--porcelain"], dir);
        const dirty = status.stdout.trim() !== "";
        let stashRef: string | undefined;
        let stashNote: string | undefined;

        if (dirty) {
          const at = now().toISOString();
          stashNote =
            `Ovid Si: uncommitted changes saved before switching ` +
            `from ${current === "" ? "HEAD" : current} to ${target} (${at}).`;
          const stash = await run(
            ["stash", "push", "--include-untracked", "-m", stashNote],
            dir,
          );
          if (stash.code !== 0) {
            fail("stash_failed", "Could not save your uncommitted changes, so nothing was switched.");
          }
          const ref = await run(["rev-parse", "refs/stash"], dir);
          stashRef = ref.code === 0 ? ref.stdout.trim() : undefined;
          logSafe(`[studio-git] stashed uncommitted work before switching to ${target}`);
        }

        const switchArgs = createTracking
          ? ["switch", "--track", "-c", target, `origin/${target}`]
          : ["switch", target];
        const switched = await run(switchArgs, dir);
        if (switched.code !== 0) {
          // Never strand the user's work: put the stash back on the old
          // branch before reporting the failure.
          if (stashRef !== undefined) {
            const popped = await run(["stash", "pop"], dir);
            if (popped.code !== 0) {
              fail(
                "switch_failed",
                `Could not switch to ${target}. Your changes are safe in stash ${stashRef}.`,
                stashRef,
              );
            }
          }
          fail("switch_failed", `Could not switch to ${target}. Nothing was lost.`);
        }

        logSafe(`[studio-git] switched to ${target}${stashRef ? " (stash kept)" : ""}`);
        return {
          status: "switched" as const,
          branch: target,
          stashed: stashRef !== undefined,
          ...(stashRef !== undefined ? { stashRef } : {}),
          ...(stashNote !== undefined ? { stashNote } : {}),
          message:
            stashRef !== undefined
              ? `Switched to ${target}. ${stashNote}`
              : `Switched to ${target}.`,
        };
      });
    },
  };
}

async function removePartialClone(dest: string): Promise<void> {
  await rm(dest, { recursive: true, force: true }).catch(() => {});
}

// ---------------------------------------------------------------------------
// Queue-job adapter
// ---------------------------------------------------------------------------

export type StudioGitJob =
  | {
      op: "clone";
      userId: string;
      sessionId?: string;
      repo: string;
      branch?: string;
      dest?: string;
    }
  | { op: "sync"; userId: string; sessionId?: string; repoDir?: string }
  | {
      op: "switch_branch";
      userId: string;
      sessionId?: string;
      repoDir?: string;
      branch: string;
    };

export type StudioGitOutcome =
  | { op: "clone"; result: StudioCloneResult }
  | { op: "sync"; result: StudioSyncResult }
  | { op: "switch_branch"; result: StudioSwitchResult };

/**
 * Wraps the git service for a queue consumer. The token is resolved per job
 * (gateway/mint own storage) and is never part of the job payload, the
 * returned outcome or the logs.
 */
export function createStudioGitProcessor(opts: {
  git: StudioGit;
  tokenFor: (job: StudioGitJob) => Promise<string | null>;
  log?: (line: string) => void;
}): (job: StudioGitJob) => Promise<StudioGitOutcome> {
  const log = opts.log ?? ((line: string) => console.log(line));
  return async (job) => {
    const token = await opts.tokenFor(job);
    if (token === null || token === "") {
      throw new StudioGitError(
        "token_unavailable",
        "Reconnect GitHub in Settings to continue with Studio.",
      );
    }
    log(`[studio-git] job ${job.op} start (${job.userId})`);
    switch (job.op) {
      case "clone":
        return {
          op: "clone",
          result: await opts.git.clone({
            userId: job.userId,
            ...(job.sessionId !== undefined ? { sessionId: job.sessionId } : {}),
            repo: job.repo,
            ...(job.branch !== undefined ? { branch: job.branch } : {}),
            ...(job.dest !== undefined ? { dest: job.dest } : {}),
            token,
          }),
        };
      case "sync":
        return {
          op: "sync",
          result: await opts.git.syncLatest({
            userId: job.userId,
            ...(job.sessionId !== undefined ? { sessionId: job.sessionId } : {}),
            ...(job.repoDir !== undefined ? { repoDir: job.repoDir } : {}),
            token,
          }),
        };
      case "switch_branch":
        return {
          op: "switch_branch",
          result: await opts.git.switchBranch({
            userId: job.userId,
            ...(job.sessionId !== undefined ? { sessionId: job.sessionId } : {}),
            ...(job.repoDir !== undefined ? { repoDir: job.repoDir } : {}),
            branch: job.branch,
            token,
          }),
        };
    }
  };
}
