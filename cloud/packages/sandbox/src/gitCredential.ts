/**
 * Ephemeral git credentials (P0 "Studio credential helper").
 *
 * The token a Studio clone/fetch/push needs must never be persisted:
 *
 *   - NO token in `.git/config` (the classic `https://user:token@host/...`
 *     remote URL or a `credential.helper store` entry);
 *   - NO token in a remote URL, a log line or a process argv;
 *   - NO token left behind on disk after the operation.
 *
 * The mechanism is git's own askpass hook:
 *
 *   1. `installGitCredential` writes a tiny `sh` script into a ROOT-OWNED,
 *      non-writable helper directory (random name). The script contains NO
 *      secret — it prints `$OVID_GIT_TOKEN`, which exists only in the git
 *      child's environment for the duration of one operation. It must NEVER
 *      live in the agent-writable sandbox home: the agent could replace it
 *      and capture every token.
 *   2. The returned `env` carries `GIT_ASKPASS`, `GIT_TERMINAL_PROMPT=0`
 *      and the token variable. `GIT_ASKPASS_REQUIRE=force` makes git use the
 *      hook even when a tty is attached.
 *   3. `dispose()` deletes the script (and the empty global-config file that
 *      isolates git from the host's credential helpers) and clears the
 *      token from the env object. It is idempotent and must run in a
 *      `finally`.
 *
 * File mode: 0755 (script) and 0644 (empty isolation config). The script is
 * executed by the host-side git child running as the sandbox uid, so it must
 * be executable by that uid; it is owned by root and the helper directory is
 * root-owned and not group/other-writable, so the agent can execute it but
 * cannot modify or replace it. The script contains no secret, so readable
 * group/other bits are not a leak. 0600 cannot work — git `exec`s
 * GIT_ASKPASS directly, so a non-executable script fails with
 * `cannot exec ...: Permission denied`.
 *
 * The helpers below (`assertNoTokenInGitConfig`, `assertNoCredentialLeak`,
 * `assertNoTokenInArgv`, `redactToken`) are the verification half: every
 * caller runs them after EVERY operation (success or failure), and the tests
 * pin them.
 */

import { randomBytes } from "node:crypto";
import { chmod, chown, lstat, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

/** The env var the askpass script reads the token from. */
export const GIT_TOKEN_ENV = "OVID_GIT_TOKEN";

/** The env var git reads the askpass program path from. */
export const GIT_ASKPASS_ENV = "GIT_ASKPASS";

/** Disables git's own terminal prompt fallback. */
export const GIT_TERMINAL_PROMPT_ENV = "GIT_TERMINAL_PROMPT";

/** Forces the askpass hook even when a tty is present (git ≥ 2.35). */
export const GIT_ASKPASS_REQUIRE_ENV = "GIT_ASKPASS_REQUIRE";

/**
 * The script's mode. Executable by the sandbox uid (the host-side git child
 * runs as that uid), but the directory is root-owned and non-writable, so the
 * agent cannot replace it. See the module header for why not 0600.
 */
export const GIT_ASKPASS_MODE = 0o755;

/** The helper directory's mode: traversable/readable, never writable. */
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
  /**
   * HOST path of the sandbox home (`SandboxHandle.homeDir`). Retained for
   * callers/tests, but the helper is deliberately NOT written here — this
   * path is agent-writable.
   */
  homeDir: string;
  /** The bearer token. Never written to disk, argv or a log. */
  token: string;
  /** Numeric sandbox uid the host-side git child runs as. */
  uid: number;
  /**
   * HOST path of the root-owned helper directory. Defaults to
   * `OVID_GIT_ASKPASS_DIR`, then to {@link DEFAULT_GIT_HELPER_DIR} when the
   * worker is root, else a private per-uid temp directory (tests/dev).
   */
  helperDir?: string;
  /**
   * The path git sees for the helper directory. Defaults to `helperDir`
   * (host-side git). A jail-side caller passes the mounted path.
   */
  visibleHelperDir?: string;
  /**
   * @deprecated use {@link visibleHelperDir}. Kept for existing callers: the
   * visible helper dir becomes `<visibleHomeDir>/.ovid`.
   */
  visibleHomeDir?: string;
  /** Username git should present; defaults to {@link DEFAULT_GIT_USERNAME}. */
  username?: string;
}

export interface GitCredential {
  /** HOST path of the askpass script (for stat/cleanup assertions). */
  readonly scriptPath: string;
  /** Path git is given via `GIT_ASKPASS` (host path or jail path). */
  readonly askpassPath: string;
  /** HOST path of the empty global git config used for isolation. */
  readonly configPath: string;
  /**
   * Environment git must see. Contains the token — pass it to the child
   * only, never persist or log it. `dispose()` clears the secret entries.
   */
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

/**
 * The helper directory must be owned by the worker/root and NOT writable by
 * the sandbox. It is deliberately outside `homeDir` (agent-writable).
 */
function resolveHelperDir(opts: GitCredentialOptions): string {
  const explicit = opts.helperDir ?? process.env.OVID_GIT_ASKPASS_DIR?.trim();
  if (explicit !== undefined && explicit !== "") return explicit;
  return currentUid() === 0
    ? DEFAULT_GIT_HELPER_DIR
    : join(tmpdir(), `ovid-git-askpass-${currentUid()}`);
}

/**
 * Create/verify the helper directory. A symlink, a non-directory, or a
 * group/other-writable directory is refused: either would let the sandbox
 * agent replace the askpass script.
 */
async function ensureHelperDir(dir: string): Promise<void> {
  await mkdir(dir, { recursive: true, mode: GIT_HELPER_DIR_MODE });
  const before = await lstat(dir);
  if (before.isSymbolicLink() || !before.isDirectory()) {
    throw new Error(`installGitCredential: helper path is not a real directory: ${dir}`);
  }
  const root = currentUid() === 0;
  // Root takes ownership even if a stale sandbox-owned directory exists.
  if (root) {
    try {
      await chown(dir, 0, 0);
    } catch {
      // Best-effort; the mode check below is the real gate.
    }
  }
  await chmod(dir, root ? GIT_HELPER_DIR_MODE : 0o700);
  const after = await lstat(dir);
  if ((after.mode & 0o022) !== 0) {
    throw new Error(
      `installGitCredential: helper directory is writable by group/other: ${dir}`,
    );
  }
  if (!after.isDirectory() || after.isSymbolicLink()) {
    throw new Error(`installGitCredential: helper path is not a real directory: ${dir}`);
  }
}

/**
 * Writes the askpass helper and returns the env git must run with.
 *
 * Throws on an empty token — a clone that silently falls back to a prompt is
 * worse than a clean refusal.
 */
export async function installGitCredential(opts: GitCredentialOptions): Promise<GitCredential> {
  if (typeof opts.token !== "string" || opts.token === "") {
    throw new Error("installGitCredential: token must be a non-empty string");
  }
  if (!Number.isInteger(opts.uid) || opts.uid < 0) {
    throw new Error(`installGitCredential: uid must be a non-negative integer, got ${opts.uid}`);
  }

  const dir = resolveHelperDir(opts);
  // Never accept a helper path inside the agent-writable sandbox home: even a
  // root-owned child can be renamed/replaced when its parent is sandbox-owned.
  const home = opts.homeDir.trim().replace(/\/+$/, "");
  const normalizedDir = dir.trim().replace(/\/+$/, "");
  if (home !== "" && (normalizedDir === home || normalizedDir.startsWith(`${home}/`))) {
    throw new Error(
      "installGitCredential: helper directory must not be inside the sandbox home",
    );
  }
  await ensureHelperDir(dir);
  const visibleDir =
    opts.visibleHelperDir ??
    (opts.visibleHomeDir !== undefined ? join(opts.visibleHomeDir, ".ovid") : dir);

  const suffix = randomSuffix();
  const scriptPath = join(dir, `git-askpass-${suffix}.sh`);
  const configPath = join(dir, `git-config-${suffix}`);
  const askpassPath = join(visibleDir, `git-askpass-${suffix}.sh`);
  const visibleConfigPath = join(visibleDir, `git-config-${suffix}`);

  await writeFile(scriptPath, renderAskpassScript(), { mode: GIT_ASKPASS_MODE });
  // writeFile's mode only applies at creation — re-assert so a stale file can
  // never be turned into a group/other-writable helper.
  await chmod(scriptPath, GIT_ASKPASS_MODE);

  // Empty global config: git must not read the host's ~/.gitconfig (which may
  // install a `store` helper and write the token to disk). An empty file also
  // keeps user.name/email out of reach, which is fine for clone/fetch/pull.
  // Root-owned and world-readable (no secret), so the sandbox-uid git child
  // can read it but cannot modify it.
  await writeFile(configPath, "", { mode: 0o644 });
  await chmod(configPath, 0o644);

  // Ownership stays with the worker/root: handing either file to the sandbox
  // uid would let the agent replace the helper. The directory check above
  // guarantees non-writability for the sandbox.

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

  let disposed = false;
  const dispose = async (): Promise<void> => {
    if (disposed) return;
    disposed = true;
    // Clear the secret FIRST: even if a filesystem error follows, the env
    // object a caller might still hold no longer carries the token.
    delete env[GIT_TOKEN_ENV];
    delete env[GIT_ASKPASS_ENV];
    delete env[GIT_ASKPASS_REQUIRE_ENV];
    delete env.OVID_GIT_USERNAME;
    for (const path of [scriptPath, configPath]) {
      try {
        await rm(path, { force: true });
      } catch (err) {
        if (isErrnoException(err) && err.code === "ENOENT") continue;
        throw err;
      }
    }
  };

  return {
    scriptPath,
    askpassPath,
    configPath,
    env,
    dispose,
  };
}

// ---------------------------------------------------------------------------
// Verification helpers
// ---------------------------------------------------------------------------

/** True when `text` contains the token as a literal substring. */
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
/** `extraheader = …` (the other common way a token gets persisted). */
const EXTRAHEADER_RE = /extraheader\s*=/i;

async function assertFileHasNoCredential(path: string, token: string, where: string): Promise<void> {
  let text: string;
  try {
    text = await readFile(path, "utf8");
  } catch (err) {
    if (isErrnoException(err) && err.code === "ENOENT") return; // absent = clean
    throw err;
  }
  if (containsToken(text, token)) throw new GitCredentialLeakError(where);
  if (EXTRAHEADER_RE.test(text)) throw new GitCredentialLeakError(`${where} (extraheader)`);
  if (URL_USERINFO_RE.test(text)) {
    throw new GitCredentialLeakError(`${where} (URL userinfo)`);
  }
}

/**
 * Reads `<repoDir>/.git/config` and throws if it carries the token, a
 * credential-bearing URL (`https://user:pass@…`) or an `extraheader` line.
 */
export async function assertNoTokenInGitConfig(repoDir: string, token: string): Promise<void> {
  const configPath = join(repoDir, ".git", "config");
  let text: string;
  try {
    text = await readFile(configPath, "utf8");
  } catch (err) {
    if (isErrnoException(err) && err.code === "ENOENT") return; // no repo/config
    throw err;
  }
  if (containsToken(text, token)) throw new GitCredentialLeakError("git config");
  if (EXTRAHEADER_RE.test(text)) throw new GitCredentialLeakError("git config (extraheader)");
  if (URL_USERINFO_RE.test(text)) {
    throw new GitCredentialLeakError("git config (remote URL userinfo)");
  }
}

/**
 * Scans every place git might persist a credential: the repo config plus the
 * sandbox home's global config and credential store. Callers must run this on
 * EVERY operation, including failures — a failed clone can still leave a
 * partial `.git/config`, and the agent can write `.gitconfig`/
 * `.git-credentials` at any time.
 */
export async function assertNoCredentialFiles(opts: {
  repoDir?: string;
  homeDir?: string;
  token: string;
}): Promise<void> {
  if (opts.repoDir !== undefined) {
    await assertNoTokenInGitConfig(opts.repoDir, opts.token);
  }
  if (opts.homeDir !== undefined) {
    await assertFileHasNoCredential(
      join(opts.homeDir, ".gitconfig"),
      opts.token,
      "global git config",
    );
    await assertFileHasNoCredential(
      join(opts.homeDir, ".git-credentials"),
      opts.token,
      "git credential store",
    );
    // XDG location used when GIT_CONFIG_GLOBAL/HOME differ.
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
  /** Sandbox home: scanned for `.gitconfig` / `.git-credentials` too. */
  homeDir?: string;
  token: string;
  argv?: readonly string[];
}): Promise<void> {
  await assertNoCredentialFiles(opts);
  if (opts.argv !== undefined) assertNoTokenInArgv(opts.argv, opts.token);
}
