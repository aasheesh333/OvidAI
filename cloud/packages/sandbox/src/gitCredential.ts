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
 *   1. `installGitCredential` writes a tiny `sh` script into the sandbox
 *      home (owner-only, random name). The script contains NO secret — it
 *      prints `$OVID_GIT_TOKEN`, which exists only in the git child's
 *      environment for the duration of one operation.
 *   2. The returned `env` carries `GIT_ASKPASS`, `GIT_TERMINAL_PROMPT=0`
 *      and the token variable. `GIT_ASKPASS_REQUIRE=force` makes git use the
 *      hook even when a tty is attached.
 *   3. `dispose()` deletes the script (and the empty global-config file that
 *      isolates git from the host's credential helpers) and clears the
 *      token from the env object. It is idempotent and must run in a
 *      `finally`.
 *
 * File mode: 0700. The product spec (§7) pins 0700, and it is also the
 * minimum that works — git `exec`s GIT_ASKPASS directly, so a 0600 script
 * fails with `cannot exec ...: Permission denied` (verified on git 2.43).
 * Owner-only + random name + immediate deletion is the security property;
 * group/other bits are always zero.
 *
 * The helpers below (`assertNoTokenInGitConfig`, `assertNoTokenInArgv`,
 * `redactToken`) are the verification half: every caller runs them after an
 * operation, and the tests pin them.
 */

import { randomBytes } from "node:crypto";
import { chmod, chown, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

/** The env var the askpass script reads the token from. */
export const GIT_TOKEN_ENV = "OVID_GIT_TOKEN";

/** The env var git reads the askpass program path from. */
export const GIT_ASKPASS_ENV = "GIT_ASKPASS";

/** Disables git's own terminal prompt fallback. */
export const GIT_TERMINAL_PROMPT_ENV = "GIT_TERMINAL_PROMPT";

/** Forces the askpass hook even when a tty is present (git ≥ 2.35). */
export const GIT_ASKPASS_REQUIRE_ENV = "GIT_ASKPASS_REQUIRE";

/** The script's mode. Owner-only; see the module header for why not 0600. */
export const GIT_ASKPASS_MODE = 0o700;

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
  /** HOST path of the sandbox home (`SandboxHandle.homeDir`). */
  homeDir: string;
  /** The bearer token. Never written to disk, argv or a log. */
  token: string;
  /** Numeric sandbox uid that must own the helper. */
  uid: number;
  /**
   * The path git sees for `homeDir`. Defaults to `homeDir` (host-side git).
   * A jail-side caller passes "/root" (the bwrap mount of `homeDir`).
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

/** Best-effort ownership hand-off; a non-root test harness already owns it. */
async function chownQuiet(path: string, uid: number): Promise<void> {
  try {
    await chown(path, uid, uid);
  } catch (err) {
    if (typeof process.getuid === "function" && process.getuid() !== 0) return;
    throw err;
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

  const visibleHome = opts.visibleHomeDir ?? opts.homeDir;
  const dir = join(opts.homeDir, ".ovid");
  await mkdir(dir, { recursive: true, mode: 0o700 });
  // Re-assert: mkdir's mode only applies at creation.
  await chmod(dir, 0o700);
  await chownQuiet(dir, opts.uid);

  const suffix = randomSuffix();
  const scriptPath = join(dir, `git-askpass-${suffix}.sh`);
  const configPath = join(dir, `git-config-${suffix}`);
  const askpassPath = join(visibleHome, ".ovid", `git-askpass-${suffix}.sh`);
  const visibleConfigPath = join(visibleHome, ".ovid", `git-config-${suffix}`);

  await writeFile(scriptPath, renderAskpassScript(), { mode: GIT_ASKPASS_MODE });
  // writeFile's mode only applies at creation — re-assert so a stale file can
  // never be group/world readable, and make the script executable.
  await chmod(scriptPath, GIT_ASKPASS_MODE);
  await chownQuiet(scriptPath, opts.uid);

  // Empty global config: git must not read the host's ~/.gitconfig (which may
  // install a `store` helper and write the token to disk). An empty file also
  // keeps user.name/email out of reach, which is fine for clone/fetch/pull.
  await writeFile(configPath, "", { mode: 0o600 });
  await chmod(configPath, 0o600);
  await chownQuiet(configPath, opts.uid);

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

/**
 * Reads `<repoDir>/.git/config` and throws if it carries the token, a
 * credential-bearing URL (`https://user:pass@…`) or an `extraheader` line
 * (the other common way a token gets persisted).
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
  if (/extraheader\s*=/i.test(text)) throw new GitCredentialLeakError("git config (extraheader)");
  // userinfo in a remote URL: scheme://something@host — reject regardless of
  // whether the secret equals the current token (a stale token is still a leak).
  if (/^\s*url\s*=\s*[a-z][a-z0-9+.-]*:\/\/[^\s/@]+@/im.test(text)) {
    throw new GitCredentialLeakError("git config (remote URL userinfo)");
  }
}

/** Convenience: every post-operation check in one call. */
export async function assertNoCredentialLeak(opts: {
  repoDir: string;
  token: string;
  argv?: readonly string[];
}): Promise<void> {
  await assertNoTokenInGitConfig(opts.repoDir, opts.token);
  if (opts.argv !== undefined) assertNoTokenInArgv(opts.argv, opts.token);
}
