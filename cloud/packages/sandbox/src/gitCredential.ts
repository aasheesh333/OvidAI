/**
 * Ephemeral git credentials for Studio.
 *
 * The token is available only to the git child's environment through an
 * askpass helper. The helper contains no secret, lives outside the writable
 * sandbox home, and is removed by dispose(). Verification helpers scan the
 * repository, home credential files, and argv after success and failure.
 */

import { randomBytes } from "node:crypto";
import { constants as FS_CONSTANTS } from "node:fs";
import { chmod, chown, lstat, mkdir, open, readFile, realpath, rm, type FileHandle } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve, sep } from "node:path";

/** The env var the askpass script reads the token from. */
export const GIT_TOKEN_ENV = "OVID_GIT_TOKEN";
/** The env var git reads the askpass program path from. */
export const GIT_ASKPASS_ENV = "GIT_ASKPASS";
/** Disables git's own terminal prompt fallback. */
export const GIT_TERMINAL_PROMPT_ENV = "GIT_TERMINAL_PROMPT";
/** Forces the askpass hook even when a tty is present (git >= 2.35). */
export const GIT_ASKPASS_REQUIRE_ENV = "GIT_ASKPASS_REQUIRE";
/** Executable by the sandbox uid, but protected by the non-writable directory. */
export const GIT_ASKPASS_MODE = 0o755;
/** The helper directory is traversable/readable, never group/other-writable. */
export const GIT_HELPER_DIR_MODE = 0o755;
/** Production helper root: root-owned, outside every sandbox bind mount. */
export const DEFAULT_GIT_HELPER_DIR = "/run/ovid/git-askpass";
/** Default username presented for GitHub fine-grained PATs / OAuth tokens. */
export const DEFAULT_GIT_USERNAME = "x-access-token";

/** The script git executes for a username/password prompt. Contains no token. */
export function renderAskpassScript(): string {
  return [
    "#!/bin/sh",
    "# Ovid Si ephemeral git askpass — deleted after one git operation.",
    "# The token lives ONLY in this process's environment, never in this file.",
    'case "$1" in',
    "  [Uu]sername*) printf '%s\\n' \"${OVID_GIT_USERNAME:-x-access-token}\" ;;",
    "  *) printf '%s\\n' \"${OVID_GIT_TOKEN:-}\" ;;",
    "esac",
    "",
  ].join("\n");
}

export interface GitCredentialOptions {
  /** HOST path of the agent-writable sandbox home. The helper never lives here. */
  homeDir: string;
  /** The bearer token. Never written to disk, argv or a log. */
  token: string;
  /** Numeric sandbox uid the host-side git child runs as. */
  uid: number;
  /** Root-owned helper directory; an explicit value is intended for tests/dev. */
  helperDir?: string;
  /** Path git sees for the helper directory when it differs from the host path. */
  visibleHelperDir?: string;
  /** @deprecated use visibleHelperDir. */
  visibleHomeDir?: string;
  /** Username git should present; defaults to x-access-token. */
  username?: string;
}

export interface GitCredential {
  /** HOST path of the askpass script (for stat/cleanup assertions). */
  readonly scriptPath: string;
  /** Path git is given via GIT_ASKPASS (host path or jail path). */
  readonly askpassPath: string;
  /** HOST path of the empty global git config used for isolation. */
  readonly configPath: string;
  /** Environment git must see. dispose() clears its secret entries. */
  readonly env: Readonly<Record<string, string>>;
  /** Deletes the helper + isolation config and clears the env. Idempotent. */
  dispose(): Promise<void>;
}

function randomSuffix(): string {
  return randomBytes(8).toString("hex");
}

function isErrnoException(err: unknown): err is NodeJS.ErrnoException {
  return err instanceof Error && "code" in err;
}

function currentUid(): number {
  return typeof process.getuid === "function" ? process.getuid() : 0;
}

function resolveHelperDir(opts: GitCredentialOptions): string {
  const explicit = opts.helperDir ?? process.env.OVID_GIT_ASKPASS_DIR?.trim();
  if (explicit !== undefined && explicit !== "") return explicit;
  return currentUid() === 0
    ? DEFAULT_GIT_HELPER_DIR
    : join(tmpdir(), `ovid-git-askpass-${currentUid()}`);
}

function isWithin(parent: string, candidate: string): boolean {
  return candidate === parent || candidate.startsWith(`${parent}${sep}`);
}

/** Resolve the nearest existing ancestor before mkdir follows any symlink. */
async function canonicalPathForCreation(path: string): Promise<string> {
  const missing: string[] = [];
  let current = resolve(path);
  for (;;) {
    try {
      const ancestor = await realpath(current);
      return join(ancestor, ...missing);
    } catch (err) {
      if (!isErrnoException(err) || err.code !== "ENOENT") throw err;
      const parent = dirname(current);
      if (parent === current) throw err;
      missing.unshift(basename(current));
      current = parent;
    }
  }
}

/** Create/verify a real, correctly owned, non-group/other-writable directory. */
async function ensureHelperDir(requestedDir: string): Promise<string> {
  const dir = resolve(requestedDir);
  await mkdir(dir, { recursive: true, mode: GIT_HELPER_DIR_MODE });
  const before = await lstat(dir);
  if (before.isSymbolicLink() || !before.isDirectory()) {
    throw new Error(`installGitCredential: helper path is not a real directory: ${dir}`);
  }
  const canonical = await realpath(dir);
  const root = currentUid() === 0;
  if (root) await chown(canonical, 0, 0);
  await chmod(canonical, root ? GIT_HELPER_DIR_MODE : 0o700);
  const after = await lstat(canonical);
  if (after.isSymbolicLink() || !after.isDirectory()) {
    throw new Error(`installGitCredential: helper path is not a real directory: ${canonical}`);
  }
  if (after.uid !== (root ? 0 : currentUid())) {
    throw new Error(`installGitCredential: helper directory has unexpected ownership: ${canonical}`);
  }
  if ((after.mode & 0o022) !== 0) {
    throw new Error(`installGitCredential: helper directory is writable by group/other: ${canonical}`);
  }
  return canonical;
}

/** Verify both the open inode and its path after every write/chmod. */
async function createVerifiedHelperFile(
  path: string,
  body: string,
  mode: number,
  track: (path: string) => void,
): Promise<void> {
  let handle: FileHandle | undefined;
  let primaryError: unknown;
  try {
    handle = await open(
      path,
      FS_CONSTANTS.O_WRONLY |
        FS_CONSTANTS.O_CREAT |
        FS_CONSTANTS.O_EXCL |
        FS_CONSTANTS.O_NOFOLLOW,
      mode,
    );
    track(path);
    await handle.writeFile(body, "utf8");
    await handle.chmod(mode);
    const opened = await handle.stat();
    const current = await lstat(path);
    const expectedUid = currentUid() === 0 ? 0 : currentUid();
    if (
      current.isSymbolicLink() ||
      !current.isFile() ||
      !opened.isFile() ||
      current.uid !== expectedUid ||
      opened.uid !== expectedUid ||
      (current.mode & 0o777) !== mode ||
      (opened.mode & 0o777) !== mode ||
      current.dev !== opened.dev ||
      current.ino !== opened.ino
    ) {
      throw new Error(`installGitCredential: helper file failed post-write verification: ${path}`);
    }
  } catch (err) {
    primaryError = err;
  }
  try {
    await handle?.close();
  } catch (closeErr) {
    if (primaryError !== undefined) {
      throw new AggregateError([primaryError, closeErr], "installGitCredential write and close failed");
    }
    throw closeErr;
  }
  if (primaryError !== undefined) throw primaryError;
}

/** Writes the ephemeral askpass helper and returns the environment git needs. */
export async function installGitCredential(opts: GitCredentialOptions): Promise<GitCredential> {
  if (typeof opts.token !== "string" || opts.token === "") {
    throw new Error("installGitCredential: token must be a non-empty string");
  }
  if (!Number.isInteger(opts.uid) || opts.uid < 0) {
    throw new Error(`installGitCredential: uid must be a non-negative integer, got ${opts.uid}`);
  }

  const requestedDir = resolve(resolveHelperDir(opts));
  const home = await realpath(resolve(opts.homeDir));
  const prospectiveDir = await canonicalPathForCreation(requestedDir);
  if (isWithin(home, prospectiveDir)) {
    throw new Error("installGitCredential: helper directory must not be inside the sandbox home");
  }
  const dir = await ensureHelperDir(requestedDir);
  if (isWithin(home, dir)) {
    throw new Error("installGitCredential: helper directory must not be inside the sandbox home");
  }
  const visibleDir =
    opts.visibleHelperDir ??
    (opts.visibleHomeDir !== undefined ? join(opts.visibleHomeDir, ".ovid") : dir);

  const suffix = randomSuffix();
  const scriptPath = join(dir, `git-askpass-${suffix}.sh`);
  const configPath = join(dir, `git-config-${suffix}`);
  const askpassPath = join(visibleDir, `git-askpass-${suffix}.sh`);
  const visibleConfigPath = join(visibleDir, `git-config-${suffix}`);
  const env: Record<string, string> = {
    [GIT_ASKPASS_ENV]: askpassPath,
    [GIT_TERMINAL_PROMPT_ENV]: "0",
    [GIT_ASKPASS_REQUIRE_ENV]: "force",
    [GIT_TOKEN_ENV]: opts.token,
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_CONFIG_GLOBAL: visibleConfigPath,
  };
  if (opts.username !== undefined && opts.username !== "") {
    env.OVID_GIT_USERNAME = opts.username;
  }

  const pending = new Set<string>();
  const dispose = async (): Promise<void> => {
    delete env[GIT_TOKEN_ENV];
    delete env[GIT_ASKPASS_ENV];
    delete env[GIT_ASKPASS_REQUIRE_ENV];
    delete env.OVID_GIT_USERNAME;
    const errors: unknown[] = [];
    for (const path of [scriptPath, configPath]) {
      if (!pending.has(path)) continue;
      try {
        await rm(path, { force: true });
        pending.delete(path);
      } catch (err) {
        if (isErrnoException(err) && err.code === "ENOENT") {
          pending.delete(path);
        } else {
          errors.push(err);
        }
      }
    }
    if (errors.length > 0) {
      throw new AggregateError(errors, "git credential disposal did not complete; retry dispose()");
    }
  };

  try {
    await createVerifiedHelperFile(scriptPath, renderAskpassScript(), GIT_ASKPASS_MODE, (path) =>
      pending.add(path),
    );
    await createVerifiedHelperFile(configPath, "", 0o644, (path) => pending.add(path));
  } catch (err) {
    try {
      await dispose();
    } catch (cleanupErr) {
      throw new AggregateError(
        [err, cleanupErr],
        "installGitCredential failed and its rollback did not complete",
      );
    }
    throw err;
  }

  return { scriptPath, askpassPath, configPath, env, dispose };
}

/** True when text contains the token as a literal substring. */
export function containsToken(text: string, token: string): boolean {
  return token !== "" && text.includes(token);
}

/** Replaces every token occurrence with a fixed marker (safe for logs). */
export function redactToken(text: string, token: string): string {
  if (token === "" || text === "") return text;
  return text.split(token).join("[redacted]");
}

/** Thrown when a token was found somewhere it must never be. */
export class GitCredentialLeakError extends Error {
  readonly code = "credential_leak";

  constructor(readonly where: string) {
    super(`git credential leak: the token was found in ${where}`);
    this.name = "GitCredentialLeakError";
  }
}

/** Throws if any argv element contains the token (argv is world-readable). */
export function assertNoTokenInArgv(argv: readonly string[], token: string): void {
  for (const arg of argv) {
    if (containsToken(arg, token)) throw new GitCredentialLeakError("process argv");
  }
}

/** userinfo in a URL: scheme://something@host (stale secrets are still leaks). */
const URL_USERINFO_RE = /[a-z][a-z0-9+.-]*:\/\/[^\s/@]+@/i;
/** extraheader is another common way a credential gets persisted. */
const EXTRAHEADER_RE = /extraheader\s*=/i;

async function assertFileHasNoCredential(path: string, token: string, where: string): Promise<void> {
  let text: string;
  try {
    text = await readFile(path, "utf8");
  } catch (err) {
    if (isErrnoException(err) && err.code === "ENOENT") return;
    throw err;
  }
  if (containsToken(text, token)) throw new GitCredentialLeakError(where);
  if (EXTRAHEADER_RE.test(text)) throw new GitCredentialLeakError(`${where} (extraheader)`);
  if (URL_USERINFO_RE.test(text)) throw new GitCredentialLeakError(`${where} (URL userinfo)`);
}

/** Throws if a repository config carries a token, userinfo, or extraheader. */
export async function assertNoTokenInGitConfig(repoDir: string, token: string): Promise<void> {
  const configPath = join(repoDir, ".git", "config");
  let text: string;
  try {
    text = await readFile(configPath, "utf8");
  } catch (err) {
    if (isErrnoException(err) && err.code === "ENOENT") return;
    throw err;
  }
  if (containsToken(text, token)) throw new GitCredentialLeakError("git config");
  if (EXTRAHEADER_RE.test(text)) throw new GitCredentialLeakError("git config (extraheader)");
  if (URL_USERINFO_RE.test(text)) {
    throw new GitCredentialLeakError("git config (remote URL userinfo)");
  }
}

/** Scans the repo config and all supported home credential locations. */
export async function assertNoCredentialFiles(opts: {
  repoDir?: string;
  /** Held .git directory, used instead of a replaceable repository path. */
  gitDir?: string;
  homeDir?: string;
  token: string;
}): Promise<void> {
  if (opts.gitDir !== undefined) {
    await assertFileHasNoCredential(join(opts.gitDir, "config"), opts.token, "git config");
  } else if (opts.repoDir !== undefined) {
    await assertNoTokenInGitConfig(opts.repoDir, opts.token);
  }
  if (opts.homeDir !== undefined) {
    await assertFileHasNoCredential(join(opts.homeDir, ".gitconfig"), opts.token, "global git config");
    await assertFileHasNoCredential(
      join(opts.homeDir, ".git-credentials"),
      opts.token,
      "git credential store",
    );
    await assertFileHasNoCredential(
      join(opts.homeDir, ".config", "git", "config"),
      opts.token,
      "global git config",
    );
    await assertFileHasNoCredential(
      join(opts.homeDir, ".config", "git", "credentials"),
      opts.token,
      "git credential store",
    );
  }
}

/** Convenience: every post-operation check in one call. */
export async function assertNoCredentialLeak(opts: {
  repoDir?: string;
  /** Held .git directory, preferred over a replaceable repository path. */
  gitDir?: string;
  homeDir?: string;
  token: string;
  argv?: readonly string[];
}): Promise<void> {
  await assertNoCredentialFiles(opts);
  if (opts.argv !== undefined) assertNoTokenInArgv(opts.argv, opts.token);
}
