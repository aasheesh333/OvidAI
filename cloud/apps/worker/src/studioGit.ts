/**
 * Transport-free Studio git service.
 *
 * Git is spawned directly (never through a shell) as the sandbox uid/gid. The
 * PAT travels only in the child's ephemeral askpass environment. Repository
 * URLs and effective insteadOf rewrites are validated before network access;
 * TLS and proxy settings are forced; credential scans and disposal run on both
 * success and failure. Sync never resets or force-updates the user's work.
 */

import { spawn, type ChildProcess, type StdioOptions } from "node:child_process";
import { constants as FS_CONSTANTS, type Stats } from "node:fs";
import { access, lstat, mkdir, mkdtemp, open, realpath, rm, type FileHandle } from "node:fs/promises";
import { basename, isAbsolute, resolve, sep } from "node:path";

import {
  GIT_ASKPASS_ENV,
  GIT_ASKPASS_REQUIRE_ENV,
  GIT_TERMINAL_PROMPT_ENV,
  GIT_TOKEN_ENV,
  assertNoCredentialLeak,
  installGitCredential,
  redactToken,
  type GitCredential,
} from "@ovid/sandbox/gitCredential";
import type { SandboxManager } from "@ovid/sandbox";

export interface GitCommandRequest {
  /** git arguments — NEVER include the token here. */
  argv: string[];
  cwd: string;
  /** The child environment, including the ephemeral credential env. */
  env: Record<string, string>;
  /** Sandbox uid to drop to (root only); omitted in tests/non-root. */
  uid?: number;
  /** Directory handles inherited as fd 3, 4, ... by the direct child. */
  fds?: readonly number[];
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

/** The production runner: git spawned directly, no shell, no argv secret. */
export function createSpawnGitRunner(): GitRunner {
  return (req) =>
    new Promise<GitCommandResult>((resolvePromise, reject) => {
      const uid =
        typeof process.getuid === "function" && process.getuid() === 0 ? req.uid : undefined;
      let child: ChildProcess;
      try {
        const stdio: StdioOptions = ["ignore", "pipe", "pipe", ...(req.fds ?? [])];
        child = spawn("git", req.argv, {
          cwd: req.cwd,
          env: req.env,
          stdio,
          // A separate process group lets timeout cleanup include git helpers
          // and all descendants, not just the immediate child.
          detached: process.platform !== "win32",
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

      let processError: unknown;
      const timeoutMs = Math.min(req.timeoutMs ?? DEFAULT_TIMEOUT_MS, 900_000);
      const timer = setTimeout(() => {
        timedOut = true;
        try {
          if (process.platform === "win32" || child.pid === undefined) {
            child.kill("SIGKILL");
          } else {
            process.kill(-child.pid, "SIGKILL");
          }
        } catch (err) {
          if (!isErrnoException(err) || err.code !== "ESRCH") processError = err;
          try {
            child.kill("SIGKILL");
          } catch {
            // The original process error is reported after stdio closes.
          }
        }
      }, timeoutMs);
      timer.unref?.();

      child.once("error", (err) => {
        processError = err;
      });
      // close, unlike exit, waits for the child's stdio to close as well.
      child.once("close", (code) => {
        clearTimeout(timer);
        if (processError !== undefined) {
          reject(processError);
          return;
        }
        resolvePromise({
          code,
          stdout: Buffer.concat(out).toString("utf8"),
          stderr: Buffer.concat(errOut).toString("utf8"),
          timedOut,
        });
      });
    });
}

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
    repoDir: string;
    token: string;
  }): Promise<StudioSyncResult>;
  switchBranch(req: {
    userId: string;
    sessionId?: string;
    repoDir: string;
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
  /** Exact hosts a token may be sent to. Defaults to github.com only. */
  allowedHosts?: readonly string[];
  /** Root-owned, non-sandbox-writable directory for the ephemeral helper. */
  credentialDir?: string;
  now?: () => Date;
}

export const DEFAULT_GITHUB_HOSTS: readonly string[] = ["github.com"];

const GITHUB_SHORTHAND = /^[\w.-]+\/[\w.-]+$/;

/** Normalize owner/name and reject credential-bearing or unapproved URLs. */
export function normalizeRepoUrl(
  repo: string,
  opts: { allowLocalUrls?: boolean; allowedHosts?: readonly string[] } = {},
): string {
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
  const allowed = new Set(
    (opts.allowedHosts !== undefined && opts.allowedHosts.length > 0
      ? opts.allowedHosts
      : DEFAULT_GITHUB_HOSTS
    )
      .map((host) => host.trim().toLowerCase())
      .filter((host) => host !== ""),
  );
  const hostname = url.hostname.toLowerCase();
  if (!allowed.has(hostname)) {
    throw new StudioGitError(
      "invalid_repo",
      "Studio can only clone from an approved git host. Connect GitHub instead.",
    );
  }
  if (url.port !== "") {
    throw new StudioGitError(
      "invalid_repo",
      "Studio clones repositories over the default https port only.",
    );
  }
  if (url.search !== "" || url.hash !== "") {
    throw new StudioGitError("invalid_repo", "The repository address has unexpected parameters.");
  }
  return url.toString();
}

/** Default clone directory: the repo name, without .git. */
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

/** Clone destinations are exactly one folder, so the sandbox uid owns them. */
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
  if (
    /[\s~^:?*[\\]/.test(value) ||
    value.includes("..") ||
    value.includes("@{") ||
    value.endsWith(".") ||
    value.endsWith(".lock")
  ) {
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

const DIRECTORY_FLAGS = FS_CONSTANTS.O_RDONLY | FS_CONSTANTS.O_DIRECTORY | FS_CONSTANTS.O_NOFOLLOW;

interface OperationBoundary {
  requestedCwd: string;
  /** /proc path resolved by the parent while spawning, pinned to an open inode. */
  cwd: string;
  fds?: readonly number[];
  /** Host /proc path of the held .git directory for credential scans. */
  gitDir?: string;
  env?: Record<string, string>;
  assertCurrent(): Promise<void>;
  close(): Promise<void>;
}

async function openDirectory(path: string): Promise<FileHandle> {
  const handle = await open(path, DIRECTORY_FLAGS);
  const stat = await handle.stat();
  if (!stat.isDirectory()) {
    await handle.close();
    throw new StudioGitError("invalid_path", "That folder is not a real workspace directory.");
  }
  return handle;
}

function identity(stat: Stats): { dev: number; ino: number } {
  return { dev: stat.dev, ino: stat.ino };
}

async function assertDirectoryIdentity(path: string, expected: { dev: number; ino: number }): Promise<void> {
  let current: Stats;
  try {
    current = await lstat(path);
  } catch (err) {
    if (isErrnoException(err) && ["ENOENT", "ENOTDIR", "ELOOP"].includes(err.code ?? "")) {
      throw new StudioGitError("invalid_path", "The workspace changed during the git operation. Retry it.");
    }
    throw err;
  }
  if (
    current.isSymbolicLink() ||
    !current.isDirectory() ||
    current.dev !== expected.dev ||
    current.ino !== expected.ino
  ) {
    throw new StudioGitError("invalid_path", "The workspace changed during the git operation. Retry it.");
  }
}

async function closeHandles(handles: readonly FileHandle[]): Promise<void> {
  const errors: unknown[] = [];
  for (const handle of handles) {
    try {
      await handle.close();
    } catch (err) {
      errors.push(err);
    }
  }
  if (errors.length > 0) throw new AggregateError(errors, "Could not close every git directory handle");
}

type WorkspaceBoundary = OperationBoundary & { rootFd: number; rootPath: string };

async function openWorkspaceBoundary(workspaceDir: string): Promise<WorkspaceBoundary> {
  const requestedCwd = resolve(workspaceDir);
  const rootPath = await realpath(requestedCwd);
  const root = await openDirectory(rootPath);
  const rootIdentity = identity(await root.stat());
  const assertCurrent = async (): Promise<void> => {
    await assertDirectoryIdentity(rootPath, rootIdentity);
  };
  try {
    await assertCurrent();
  } catch (err) {
    await root.close();
    throw err;
  }
  return {
    requestedCwd,
    cwd: `/proc/self/fd/${root.fd}`,
    rootFd: root.fd,
    rootPath,
    assertCurrent,
    close: async () => root.close(),
  };
}

type RepoBoundary = OperationBoundary;

/** Open each path component without following symlinks and retain the inodes. */
async function openRepoBoundary(workspaceDir: string, rel: string | undefined): Promise<RepoBoundary> {
  const relDir = safeRelDir(rel ?? ".");
  const workspace = await openWorkspaceBoundary(workspaceDir);
  const extra: FileHandle[] = [];
  try {
    let parentFd = workspace.rootFd;
    for (const part of relDir === "." ? [] : relDir.split("/")) {
      let next: FileHandle;
      try {
        next = await openDirectory(`/proc/self/fd/${parentFd}/${part}`);
      } catch (err) {
        if (isErrnoException(err) && ["ENOENT", "ENOTDIR"].includes(err.code ?? "")) {
          throw new StudioGitError("not_a_repo", "This folder is not a git repository yet.");
        }
        if (isErrnoException(err) && err.code === "ELOOP") {
          throw new StudioGitError("invalid_path", "That folder is outside the workspace.");
        }
        throw err;
      }
      extra.push(next);
      parentFd = next.fd;
    }
    const worktree = extra.length > 0 ? extra[extra.length - 1]! : await openDirectory(`${workspace.cwd}/.`);
    if (extra.length === 0) extra.push(worktree);
    let gitDir: FileHandle;
    try {
      gitDir = await openDirectory(`/proc/self/fd/${worktree.fd}/.git`);
    } catch (err) {
      if (isErrnoException(err) && ["ENOENT", "ENOTDIR", "ELOOP"].includes(err.code ?? "")) {
        throw new StudioGitError("not_a_repo", "This folder is not a git repository yet.");
      }
      throw err;
    }
    extra.push(gitDir);
    const worktreeIdentity = identity(await worktree.stat());
    const gitIdentity = identity(await gitDir.stat());
    const dirPath = resolve(workspace.rootPath, relDir);
    const requestedCwd = resolve(workspaceDir, relDir);
    const assertCurrent = async (): Promise<void> => {
      await workspace.assertCurrent();
      await assertDirectoryIdentity(dirPath, worktreeIdentity);
      await assertDirectoryIdentity(`/proc/self/fd/${worktree.fd}/.git`, gitIdentity);
    };
    await assertCurrent();
    return {
      requestedCwd,
      cwd: `/proc/self/fd/${worktree.fd}`,
      fds: [worktree.fd, gitDir.fd],
      gitDir: `/proc/self/fd/${gitDir.fd}`,
      env: {
        GIT_WORK_TREE: "/proc/self/fd/3",
        GIT_DIR: "/proc/self/fd/4",
        GIT_COMMON_DIR: "/proc/self/fd/4",
      },
      assertCurrent,
      close: async () => {
        const errors: unknown[] = [];
        try {
          await closeHandles(extra);
        } catch (err) {
          errors.push(err);
        }
        try {
          await workspace.close();
        } catch (err) {
          errors.push(err);
        }
        if (errors.length > 0) throw new AggregateError(errors, "Could not close the git repository boundary");
      },
    };
  } catch (err) {
    const closeError = await closeHandles(extra).then(() => undefined, (closeErr) => closeErr);
    const workspaceCloseError = await workspace.close().then(() => undefined, (closeErr) => closeErr);
    if (closeError !== undefined || workspaceCloseError !== undefined) {
      throw new AggregateError(
        [err, closeError, workspaceCloseError].filter((value) => value !== undefined),
        "Could not close a rejected git repository boundary",
      );
    }
    throw err;
  }
}

function resolveWorkspaceDir(workspaceDir: string, rel: string | undefined): string {
  const relDir = safeRelDir(rel ?? ".");
  const root = resolve(workspaceDir);
  const dir = resolve(root, relDir);
  if (dir !== root && !dir.startsWith(`${root}${sep}`)) {
    throw new StudioGitError("invalid_path", "That folder is outside the workspace.");
  }
  return dir;
}

/** Every invocation clears ambient credential helpers. */
function gitArgv(args: string[]): string[] {
  return [
    "-c",
    "credential.helper=",
    // Command-scope values outrank mutable repository config. No repository
    // hook or ext:: helper may execute in the PAT-bearing process group.
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "protocol.ext.allow=never",
    ...args,
  ];
}

function isNetworkGitCommand(args: readonly string[]): boolean {
  let index = 0;
  while (args[index] === "-c") index += 2;
  return args[index] === "clone" || args[index] === "fetch";
}

function firstLine(text: string): string {
  return text.trim().split("\n")[0]?.trim() ?? "";
}

/** Host + repo only: never log URL userinfo, query, or a long path prefix. */
function displayRepo(url: string): string {
  try {
    const parsed = new URL(url);
    if (parsed.protocol === "file:") {
      return `local/${basename(parsed.pathname).replace(/\.git$/i, "") || "repo"}`;
    }
    const parts = parsed.pathname
      .replace(/\.git$/i, "")
      .split("/")
      .filter((part) => part !== "");
    const repo = parts.slice(-2).join("/");
    return repo === "" ? parsed.host : `${parsed.host}/${repo}`;
  } catch {
    return "repository";
  }
}

/** Force the validated remote, TLS verification, and no repository proxy. */
function hardenedRemoteArgs(url: string): string[] {
  if (url.startsWith("file:")) return ["-c", `remote.origin.url=${url}`];
  return [
    "-c",
    `remote.origin.url=${url}`,
    "-c",
    "http.sslVerify=true",
    "-c",
    `http.${url}.sslVerify=true`,
    "-c",
    "http.proxy=",
    "-c",
    `http.${url}.proxy=`,
    "-c",
    "remote.origin.proxy=",
  ];
}

/**
 * Pin an exact self-rewrite in the trusted global config, which Git reads
 * before repository config. Git chooses the longest insteadOf match and keeps
 * the first entry on a tie, so no later repository rewrite can redirect this
 * exact canonical URL, even if config changes immediately before fetch.
 */
async function pinCanonicalOrigin(cred: GitCredential, url: string): Promise<void> {
  const before = await lstat(cred.configPath);
  const handle = await open(
    cred.configPath,
    FS_CONSTANTS.O_WRONLY | FS_CONSTANTS.O_TRUNC | FS_CONSTANTS.O_NOFOLLOW,
  );
  try {
    const opened = await handle.stat();
    if (before.isSymbolicLink() || !before.isFile() || before.dev !== opened.dev || before.ino !== opened.ino) {
      throw new StudioGitError("fetch_failed", "Could not isolate the repository remote.");
    }
    const quoted = JSON.stringify(url);
    await handle.writeFile(`[url ${quoted}]\n\tinsteadOf = ${quoted}\n`, "utf8");
  } finally {
    await handle.close();
  }
  const after = await lstat(cred.configPath);
  if (
    after.isSymbolicLink() ||
    !after.isFile() ||
    after.dev !== before.dev ||
    after.ino !== before.ino ||
    after.uid !== before.uid
  ) {
    throw new StudioGitError("fetch_failed", "Could not isolate the repository remote.");
  }
}

/** Canonicalize origin and reject every effective insteadOf mismatch. */
async function canonicalOrigin(
  run: (args: string[], cwd: string, timeoutMs?: number) => Promise<GitCommandResult>,
  dir: string,
  opts: { allowLocalUrls?: boolean; allowedHosts?: readonly string[] },
): Promise<string> {
  const res = await run(["config", "--get", "remote.origin.url"], dir);
  const raw = res.stdout.trim();
  if (res.code !== 0 || raw === "") {
    throw new StudioGitError("fetch_failed", "This repository has no remote configured.");
  }
  let canonical: string;
  try {
    canonical = normalizeRepoUrl(raw, opts);
  } catch {
    throw new StudioGitError(
      "fetch_failed",
      "The repository remote is not an approved git host. Rebind the repository in Studio.",
    );
  }

  const effective = await run(["remote", "get-url", "--all", "origin"], dir);
  if (effective.code !== 0) {
    throw new StudioGitError("fetch_failed", "This repository has no remote configured.");
  }
  const effectiveUrls = effective.stdout
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line !== "");
  for (const effectiveUrl of effectiveUrls) {
    let normalized: string;
    try {
      normalized = normalizeRepoUrl(effectiveUrl, opts);
    } catch {
      throw new StudioGitError(
        "fetch_failed",
        "The repository remote is not an approved git host. Rebind the repository in Studio.",
      );
    }
    if (normalized !== canonical) {
      throw new StudioGitError(
        "fetch_failed",
        "The repository remote is not an approved git host. Rebind the repository in Studio.",
      );
    }
  }
  return canonical;
}

interface CloneStaging {
  name: string;
  path: string;
  parent: FileHandle;
  directory: FileHandle;
  /** Opened after clone and retained across publication for the final scan. */
  gitDirectory?: FileHandle;
  cleanup(): Promise<void>;
}

/** A random staging directory anchored to held, verified directory inodes. */
async function createCloneStaging(workspace: WorkspaceBoundary, uid: number): Promise<CloneStaging> {
  const parentPath = `${workspace.cwd}/.ovid-studio-git`;
  await mkdir(parentPath, { recursive: true, mode: 0o711 });
  const root = typeof process.getuid === "function" && process.getuid() === 0;
  const parent = await openDirectory(parentPath);
  let directory: FileHandle | undefined;
  let path: string | undefined;
  try {
    if (root) await parent.chown(0, 0);
    await parent.chmod(0o711);
    const parentStat = await parent.stat();
    if (
      parentStat.uid !== (root ? 0 : process.getuid!()) ||
      (parentStat.mode & 0o022) !== 0
    ) {
      throw new StudioGitError("invalid_path", "The workspace staging directory is not trusted.");
    }
    await assertDirectoryIdentity(parentPath, identity(parentStat));

    // Every later stage path is relative to this held parent, never to the
    // replaceable .ovid-studio-git name in the workspace.
    path = await mkdtemp(`/proc/self/fd/${parent.fd}/clone-`);
    directory = await openDirectory(path);
    if (root) await directory.chown(uid, uid);
    await directory.chmod(0o700);
    const directoryStat = await directory.stat();
    if (
      directoryStat.uid !== (root ? uid : process.getuid!()) ||
      (directoryStat.mode & 0o777) !== 0o700
    ) {
      throw new StudioGitError("invalid_path", "The clone staging directory is not trusted.");
    }
    const ownedDirectory = directory;
    const ownedPath = path;
    const owned: CloneStaging = {
      name: basename(ownedPath),
      path: ownedPath,
      parent,
      directory: ownedDirectory,
      cleanup: async () => {
        const errors: unknown[] = [];
        try {
          // Only the operation-owned staging inode is recursively cleaned.
          await rm(ownedPath, { recursive: true, force: true });
        } catch (err) {
          errors.push(err);
        }
        try {
          await closeHandles([
            ...(owned.gitDirectory === undefined ? [] : [owned.gitDirectory]),
            ownedDirectory,
            parent,
          ]);
        } catch (err) {
          errors.push(err);
        }
        if (errors.length > 0) throw new AggregateError(errors, "Could not clean the clone staging directory");
      },
    };
    return owned;
  } catch (err) {
    const errors = [err];
    if (directory !== undefined) {
      try {
        await directory.close();
      } catch (closeErr) {
        errors.push(closeErr);
      }
    }
    if (path !== undefined) {
      try {
        await rm(path, { recursive: true, force: true });
      } catch (cleanupErr) {
        errors.push(cleanupErr);
      }
    }
    try {
      await parent.close();
    } catch (closeErr) {
      errors.push(closeErr);
    }
    if (errors.length > 1) throw new AggregateError(errors, "Could not create and clean clone staging");
    throw err;
  }
}

/** GNU mv uses renameat2(RENAME_NOREPLACE) for this same-filesystem operation. */
async function publishClone(
  workspace: WorkspaceBoundary,
  staging: CloneStaging,
  relDir: string,
  homeDir: string,
): Promise<void> {
  const expected = identity(await staging.directory.stat());
  const destination = `/proc/self/fd/3/${relDir}`;
  const source = `/proc/self/fd/4/${staging.name}`;
  const code = await new Promise<number | null>((resolvePromise, reject) => {
    const child = spawn("mv", ["-n", "-T", "--", source, destination], {
      cwd: workspace.cwd,
      env: {
        PATH: process.env.PATH ?? "/usr/local/bin:/usr/bin:/bin",
        HOME: homeDir,
        LANG: "C.UTF-8",
        LC_ALL: "C",
      },
      stdio: ["ignore", "ignore", "pipe", workspace.rootFd, staging.parent.fd],
    });
    child.stderr?.resume();
    child.once("error", reject);
    child.once("close", resolvePromise);
  });

  let sourceCurrent: Stats | undefined;
  try {
    sourceCurrent = await lstat(staging.path);
  } catch (err) {
    if (!isErrnoException(err) || err.code !== "ENOENT") throw err;
  }
  if (code !== 0) {
    if (sourceCurrent !== undefined && sourceCurrent.dev === expected.dev && sourceCurrent.ino === expected.ino) {
      throw new StudioGitError("destination_exists", `The folder "${relDir}" already exists in this workspace.`);
    }
    throw new StudioGitError("clone_failed", "Could not publish the cloned repository. Retry it.");
  }
  if (sourceCurrent !== undefined) {
    if (sourceCurrent.dev === expected.dev && sourceCurrent.ino === expected.ino) {
      // mv -n exits zero when it declines an existing destination.
      throw new StudioGitError("destination_exists", `The folder "${relDir}" already exists in this workspace.`);
    }
    throw new StudioGitError("invalid_path", "The clone staging directory changed during publication.");
  }

  const published = await openDirectory(`/proc/self/fd/${workspace.rootFd}/${relDir}`);
  try {
    const actual = await published.stat();
    if (actual.dev !== expected.dev || actual.ino !== expected.ino) {
      throw new StudioGitError("invalid_path", "The clone destination changed during publication.");
    }
  } finally {
    await published.close();
  }
}

export function createStudioGit(deps: StudioGitDeps): StudioGit {
  const runner = deps.runner ?? createSpawnGitRunner();
  const now = deps.now ?? (() => new Date());
  const log = deps.log ?? ((line: string) => console.log(line));
  const allowedHosts = deps.allowedHosts ?? DEFAULT_GITHUB_HOSTS;
  const repoOpts = { allowLocalUrls: deps.allowLocalUrls, allowedHosts };

  const baseEnv = (homeDir: string): Record<string, string> => ({
    PATH: process.env.PATH ?? "/usr/local/bin:/usr/bin:/bin",
    HOME: homeDir,
    LANG: "C.UTF-8",
    LC_ALL: "C",
  });

  /** One operation = one credential; all cleanup paths preserve the primary error. */
  const withCredential = async <T>(
    handle: { homeDir: string; uid: number },
    token: string,
    fn: (ctx: {
      cred: GitCredential;
      env: Record<string, string>;
      run: (
        args: string[],
        cwd: string,
        timeoutMs?: number,
        fds?: readonly number[],
      ) => Promise<GitCommandResult>;
      logSafe: (line: string) => void;
      fail: (code: StudioGitErrorCode, message: string, stashRef?: string) => never;
    }) => Promise<T>,
    leakCheck?: {
      repoDir: string | (() => string);
      gitDir?: string | (() => string | undefined);
      argv?: readonly string[];
    },
    boundary?: OperationBoundary,
    cleanup?: () => Promise<void>,
  ): Promise<T> => {
    const logSafe = (line: string): void => log(redactToken(line, token));
    let cred: GitCredential;
    try {
      cred = await installGitCredential({
        homeDir: handle.homeDir,
        token,
        uid: handle.uid,
        ...(deps.credentialDir !== undefined ? { helperDir: deps.credentialDir } : {}),
      });
    } catch (err) {
      const errors = [err];
      if (cleanup !== undefined) {
        try {
          await cleanup();
        } catch (cleanupErr) {
          errors.push(cleanupErr);
        }
      }
      if (boundary !== undefined) {
        try {
          await boundary.close();
        } catch (closeErr) {
          errors.push(closeErr);
        }
      }
      if (errors.length > 1) throw new AggregateError(errors, "Git credential installation and cleanup failed");
      throw err;
    }

    const env = { ...baseEnv(handle.homeDir), ...cred.env };
    const fail = (code: StudioGitErrorCode, message: string, stashRef?: string): never => {
      throw new StudioGitError(code, redactToken(message, token), stashRef);
    };
    const run = async (
      args: string[],
      cwd: string,
      timeoutMs?: number,
      fds?: readonly number[],
    ): Promise<GitCommandResult> => {
      if (boundary?.env !== undefined) Object.assign(env, boundary.env);
      const activeFds = fds ?? boundary?.fds;
      const credentialEnv = [
        GIT_TOKEN_ENV,
        GIT_ASKPASS_ENV,
        GIT_ASKPASS_REQUIRE_ENV,
        GIT_TERMINAL_PROMPT_ENV,
        "OVID_GIT_USERNAME",
      ] as const;
      if (isNetworkGitCommand(args)) {
        // Only clone/fetch can receive the PAT. Local config/status/stash/
        // switch/merge commands may run repository filters, but get no secret.
        for (const key of credentialEnv) {
          const value = cred.env[key];
          if (value !== undefined) env[key] = value;
        }
      } else {
        for (const key of credentialEnv) delete env[key];
      }
      try {
        const result = await runner({
          argv: gitArgv(args),
          cwd: boundary !== undefined && cwd === boundary.requestedCwd ? boundary.cwd : cwd,
          env,
          uid: handle.uid,
          ...(activeFds !== undefined ? { fds: activeFds } : {}),
          timeoutMs,
        });
        await boundary?.assertCurrent();
        return result;
      } finally {
        delete env.GIT_WORK_TREE;
        delete env.GIT_DIR;
        delete env.GIT_COMMON_DIR;
        for (const key of credentialEnv) delete env[key];
      }
    };

    let outcome!: T;
    let primaryError: unknown;
    try {
      outcome = await fn({ cred, env, run, logSafe, fail });
    } catch (err) {
      primaryError = err;
    }

    let leakError: unknown;
    if (leakCheck !== undefined) {
      try {
        const gitDir =
          typeof leakCheck.gitDir === "function" ? leakCheck.gitDir() : leakCheck.gitDir;
        await assertNoCredentialLeak({
          repoDir: typeof leakCheck.repoDir === "function" ? leakCheck.repoDir() : leakCheck.repoDir,
          homeDir: handle.homeDir,
          token,
          ...(gitDir !== undefined ? { gitDir } : {}),
          ...(leakCheck.argv !== undefined ? { argv: leakCheck.argv } : {}),
        });
      } catch (err) {
        leakError = err;
      }
    }

    delete env[GIT_TOKEN_ENV];
    delete env[GIT_ASKPASS_ENV];
    delete env[GIT_ASKPASS_REQUIRE_ENV];
    delete env.OVID_GIT_USERNAME;
    const cleanupErrors: unknown[] = [];
    try {
      await cred.dispose();
    } catch (err) {
      cleanupErrors.push(err);
    }
    if (cleanup !== undefined) {
      try {
        await cleanup();
      } catch (err) {
        cleanupErrors.push(err);
      }
    }
    if (boundary !== undefined) {
      try {
        await boundary.close();
      } catch (err) {
        cleanupErrors.push(err);
      }
    }

    for (const cleanupErr of cleanupErrors) {
      const message = cleanupErr instanceof Error ? cleanupErr.message : "unknown cleanup failure";
      logSafe(`[studio-git] cleanup failed: ${message}`);
    }
    if (leakError !== undefined) throw leakError;
    if (primaryError !== undefined) throw primaryError;
    if (cleanupErrors.length > 0) {
      throw new StudioGitError(
        "sync_failed",
        "Studio could not finish cleaning up the git operation. Retry it.",
      );
    }
    return outcome;
  };

  return {
    async clone(req) {
      const url = normalizeRepoUrl(req.repo, repoOpts);
      const requested = req.dest?.trim() ?? "";
      const relDir = safeRepoDirName(requested === "" ? defaultRepoDir(url) : requested);
      const handle = await deps.manager.attach(req.userId);
      const originalDest = resolveWorkspaceDir(handle.workspaceDir, relDir);
      if (await exists(originalDest)) {
        throw new StudioGitError(
          "destination_exists",
          `The folder "${relDir}" already exists in this workspace.`,
        );
      }

      const branch = req.branch?.trim() ?? "";
      if (branch !== "") assertSafeBranch(branch);
      let workspace: WorkspaceBoundary | undefined;
      let staging: CloneStaging | undefined;
      let stagedGitDir: string | undefined;
      let delegatedCleanup = false;
      try {
        workspace = await openWorkspaceBoundary(handle.workspaceDir);
        const dest = resolveWorkspaceDir(workspace.rootPath, relDir);
        if (await exists(dest)) {
          throw new StudioGitError(
            "destination_exists",
            `The folder "${relDir}" already exists in this workspace.`,
          );
        }
        staging = await createCloneStaging(workspace, handle.uid);
        const args = ["clone"];
        if (branch !== "") args.push("--branch", branch);
        // The staging directory is inherited as fd 3 by this git child.
        args.push("--", url, "/proc/self/fd/3");
        delegatedCleanup = true;
        return await withCredential(
          handle,
          req.token,
          async ({ run, logSafe, fail }) => {
            const ownedWorkspace = workspace!;
            const ownedStaging = staging!;
            logSafe(`[studio-git] clone start: ${displayRepo(url)} -> ${relDir}`);
            const res = await run(args, ownedWorkspace.requestedCwd, undefined, [ownedStaging.directory.fd]);
            if (res.code !== 0) {
              logSafe(`[studio-git] clone failed: ${firstLine(res.stderr)}`);
              fail(
                "clone_failed",
                "Could not clone the repository. Check the address and your GitHub connection.",
              );
            }

            const gitDirectory = await openDirectory(
              `/proc/self/fd/${ownedStaging.directory.fd}/.git`,
            );
            ownedStaging.gitDirectory = gitDirectory;
            const gitDirectoryPath = `/proc/self/fd/${gitDirectory.fd}`;
            stagedGitDir = gitDirectoryPath;

            const head = await run(["rev-parse", "--abbrev-ref", "HEAD"], ownedStaging.path);
            const actualBranch = head.code === 0 ? head.stdout.trim() : branch;
            await ownedWorkspace.assertCurrent();
            // Publish only after the staged config is known clean. The finally
            // scan repeats this check through the same held inodes after publication.
            await assertNoCredentialLeak({
              repoDir: ownedStaging.path,
              gitDir: gitDirectoryPath,
              homeDir: handle.homeDir,
              token: req.token,
              argv: args,
            });
            await publishClone(ownedWorkspace, ownedStaging, relDir, handle.homeDir);
            await ownedWorkspace.assertCurrent();
            logSafe(`[studio-git] clone ok: ${relDir} (${actualBranch})`);
            return { status: "cloned" as const, repoDir: relDir, branch: actualBranch };
          },
          {
            repoDir: staging.path,
            gitDir: () => stagedGitDir,
            argv: args,
          },
          workspace,
          staging.cleanup,
        );
      } catch (err) {
        if (!delegatedCleanup) {
          const cleanupErrors: unknown[] = [];
          if (staging !== undefined) {
            try {
              await staging.cleanup();
            } catch (cleanupErr) {
              cleanupErrors.push(cleanupErr);
            }
          }
          if (workspace !== undefined) {
            try {
              await workspace.close();
            } catch (closeErr) {
              cleanupErrors.push(closeErr);
            }
          }
          for (const cleanupErr of cleanupErrors) {
            const message = cleanupErr instanceof Error ? cleanupErr.message : "unknown cleanup failure";
            log(redactToken(`[studio-git] cleanup failed: ${message}`, req.token));
          }
        }
        throw err;
      }
    },

    async syncLatest(req) {
      const handle = await deps.manager.attach(req.userId);
      const dir = resolveWorkspaceDir(handle.workspaceDir, req.repoDir);
      const boundary = await openRepoBoundary(handle.workspaceDir, req.repoDir);

      return withCredential(
        handle,
        req.token,
        async ({ cred, run, logSafe, fail }) => {
          const canonicalUrl = await canonicalOrigin(run, dir, repoOpts);
          await pinCanonicalOrigin(cred, canonicalUrl);
          const status = await run(["status", "--porcelain"], dir);
          const dirty = status.stdout.trim() !== "";
          const branchRes = await run(["rev-parse", "--abbrev-ref", "HEAD"], dir);
          const branch = branchRes.code === 0 ? branchRes.stdout.trim() : "";
          const hasBranch = branch !== "" && branch !== "HEAD";
          const trackingRef = hasBranch ? `refs/remotes/origin/${branch}` : undefined;
          if (trackingRef !== undefined) {
            const tracking = await run(["rev-parse", "--verify", "--quiet", trackingRef], dir);
            if (tracking.code !== 0) {
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
          }

          // An explicit refspec ignores every repository-controlled fetch
          // mapping. It can update only origin's remote-tracking namespace,
          // never a local branch, and no stale ref is pruned.
          const refspec = hasBranch
            ? `+refs/heads/${branch}:${trackingRef}`
            : "+refs/heads/*:refs/remotes/origin/*";
          const fetched = await run(
            [
              ...hardenedRemoteArgs(canonicalUrl),
              "fetch",
              "--no-prune",
              "--no-tags",
              "--no-recurse-submodules",
              canonicalUrl,
              refspec,
            ],
            dir,
          );
          if (fetched.code !== 0) {
            logSafe(`[studio-git] fetch failed: ${firstLine(fetched.stderr)}`);
            fail("fetch_failed", "Could not reach the remote. Check your connection and try again.");
          }

          const upstream = trackingRef ?? "@{upstream}";
          if (trackingRef === undefined) {
            const upstreamRes = await run(
              ["rev-parse", "--abbrev-ref", "--symbolic-full-name", upstream],
              dir,
            );
            if (upstreamRes.code !== 0) {
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
          }

          const behindRes = await run(["rev-list", "--count", `HEAD..${upstream}`], dir);
          const aheadRes = await run(["rev-list", "--count", `${upstream}..HEAD`], dir);
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

          const ancestor = await run(["merge-base", "--is-ancestor", "HEAD", upstream], dir);
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

          const merged = await run(["merge", "--ff-only", upstream], dir);
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
          logSafe(`[studio-git] sync ok: ${branch} fast-forwarded ${behind}`);
          return {
            status: "synced" as const,
            dirty: false,
            behind,
            ahead,
            branch,
            message: `Updated to the latest ${behind} change${behind === 1 ? "" : "s"}.`,
          };
        },
        { repoDir: dir, gitDir: boundary.gitDir },
        boundary,
      );
    },

    async switchBranch(req) {
      assertSafeBranch(req.branch);
      const target = req.branch.trim();
      const handle = await deps.manager.attach(req.userId);
      const dir = resolveWorkspaceDir(handle.workspaceDir, req.repoDir);
      const boundary = await openRepoBoundary(handle.workspaceDir, req.repoDir);

      return withCredential(
        handle,
        req.token,
        async ({ cred, run, logSafe, fail }) => {
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

          const local = await run(
            ["rev-parse", "--verify", "--quiet", `refs/heads/${target}`],
            dir,
          );
          let createTracking = false;
          let trackingRef: string | undefined;
          if (local.code !== 0) {
            const canonicalUrl = await canonicalOrigin(run, dir, repoOpts);
            await pinCanonicalOrigin(cred, canonicalUrl);
            trackingRef = `refs/remotes/origin/${target}`;
            const refspec = `+refs/heads/${target}:${trackingRef}`;
            const fetched = await run(
              [
                ...hardenedRemoteArgs(canonicalUrl),
                "fetch",
                "--no-prune",
                "--no-tags",
                "--no-recurse-submodules",
                canonicalUrl,
                refspec,
              ],
              dir,
            );
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
              "Ovid Si: uncommitted changes saved before switching " +
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
            ? ["switch", "--track", "-c", target, trackingRef!]
            : ["switch", target];
          const switched = await run(switchArgs, dir);
          if (switched.code !== 0) {
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
            message: stashRef !== undefined ? `Switched to ${target}. ${stashNote}` : `Switched to ${target}.`,
          };
        },
        { repoDir: dir, gitDir: boundary.gitDir },
        boundary,
      );
    },
  };
}

export interface StudioGitTokenRequest {
  userId: string;
  /** Present for clone (the normalized repo address). */
  repo?: string;
  /** Present for sync/switch. */
  repoDir?: string;
}

/** Returning null refuses the job; there is no deployment-wide fallback. */
export type StudioGitTokenResolver = (req: StudioGitTokenRequest) => Promise<string | null>;

export interface GithubTokenSourceRow {
  id: string;
  curatedId: string | null;
  enabled?: boolean;
  secretsSealed: unknown;
}

/** Resolve only the requesting user's enabled curated GitHub GITHUB_TOKEN. */
export function createPerUserGithubTokenResolver(opts: {
  listServers: (userId: string) => Promise<readonly GithubTokenSourceRow[]>;
  decrypt: (sealed: unknown, recordId: string) => string;
}): StudioGitTokenResolver {
  return async (req) => {
    let rows: readonly GithubTokenSourceRow[];
    try {
      rows = await opts.listServers(req.userId);
    } catch {
      return null;
    }
    const row = rows.find(
      (candidate) =>
        candidate.enabled !== false &&
        candidate.curatedId === "github" &&
        candidate.secretsSealed != null,
    );
    if (row === undefined) return null;
    try {
      const secrets = JSON.parse(opts.decrypt(row.secretsSealed, `mcp_servers:${row.id}`)) as unknown;
      if (typeof secrets !== "object" || secrets === null) return null;
      const token = (secrets as Record<string, unknown>).GITHUB_TOKEN;
      return typeof token === "string" && token.trim() !== "" ? token.trim() : null;
    } catch {
      return null;
    }
  };
}
