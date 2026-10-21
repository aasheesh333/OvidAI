import { execFile } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { afterAll, describe, expect, it } from "vitest";

import {
  GIT_ASKPASS_ENV,
  GIT_ASKPASS_MODE,
  GIT_HELPER_DIR_MODE,
  GIT_TERMINAL_PROMPT_ENV,
  GIT_TOKEN_ENV,
  GitCredentialLeakError,
  assertNoCredentialLeak,
  assertNoTokenInArgv,
  assertNoTokenInGitConfig,
  containsToken,
  installGitCredential,
  redactToken,
  renderAskpassScript,
} from "./gitCredential.js";

const execFileAsync = promisify(execFile);
const TOKEN = "ghp_studio_ephemeral_0123456789";

const roots: string[] = [];
afterAll(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

interface TempHome {
  home: string;
  /** Root-owned helper dir, deliberately OUTSIDE the agent-writable home. */
  helperDir: string;
}

function tempHome(): TempHome {
  const root = mkdtempSync(join(tmpdir(), "ovid-gitcred-"));
  roots.push(root);
  const home = join(root, "home");
  const helperDir = join(root, "git-helper");
  mkdirSync(home, { recursive: true });
  mkdirSync(helperDir, { recursive: true });
  return { home, helperDir };
}

function uid(): number {
  return typeof process.getuid === "function" ? process.getuid() : 0;
}

async function runHelper(script: string, prompt: string, extraEnv: Record<string, string> = {}) {
  return execFileAsync(script, [prompt], {
    env: {
      PATH: process.env.PATH ?? "/usr/local/bin:/usr/bin:/bin",
      [GIT_TOKEN_ENV]: TOKEN,
      ...extraEnv,
    },
  });
}

describe("installGitCredential", () => {
  it("writes a non-writable helper outside the sandbox home that contains no secret", async () => {
    const { home, helperDir } = tempHome();
    const cred = await installGitCredential({
      homeDir: home,
      helperDir,
      token: TOKEN,
      uid: uid(),
    });
    try {
      const mode = statSync(cred.scriptPath).mode & 0o777;
      expect(mode).toBe(GIT_ASKPASS_MODE);
      // No write bits: the agent can execute the helper but never replace it.
      expect(mode & 0o022).toBe(0);
      expect(mode & 0o111).not.toBe(0);
      expect(statSync(helperDir).mode & 0o022).toBe(0);
      expect(statSync(helperDir).mode & 0o777).toBe(
        typeof process.getuid === "function" && process.getuid() === 0
          ? GIT_HELPER_DIR_MODE
          : 0o700,
      );

      // The helper is NOT in the agent-writable home.
      expect(cred.scriptPath.startsWith(home)).toBe(false);
      expect(existsSync(join(home, ".ovid"))).toBe(false);

      const body = readFileSync(cred.scriptPath, "utf8");
      expect(containsToken(body, TOKEN)).toBe(false);
      expect(body).toContain(GIT_TOKEN_ENV);

      expect(cred.env[GIT_ASKPASS_ENV]).toBe(cred.scriptPath);
      expect(cred.env[GIT_TERMINAL_PROMPT_ENV]).toBe("0");
      expect(cred.env[GIT_TOKEN_ENV]).toBe(TOKEN);
      expect(cred.env.GIT_CONFIG_NOSYSTEM).toBe("1");
      // Isolation config is empty: no credential.helper can leak in, and it
      // is root-owned/non-writable so the sandbox cannot add one.
      expect(readFileSync(cred.configPath, "utf8")).toBe("");
      expect(statSync(cred.configPath).mode & 0o022).toBe(0);
    } finally {
      await cred.dispose();
    }
  });

  it("refuses a helper directory inside the agent-writable home", async () => {
    const { home } = tempHome();
    await expect(
      installGitCredential({
        homeDir: home,
        helperDir: join(home, ".ovid"),
        token: TOKEN,
        uid: uid(),
      }),
    ).rejects.toThrow(/must not be inside the sandbox home/);
  });

  it("prints the token from the environment (and a username), never from the file", async () => {
    const { home, helperDir } = tempHome();
    const cred = await installGitCredential({
      homeDir: home,
      helperDir,
      token: TOKEN,
      uid: uid(),
    });
    try {
      const password = await runHelper(cred.scriptPath, "Password for 'https://github.com':");
      expect(password.stdout.trim()).toBe(TOKEN);

      const username = await runHelper(cred.scriptPath, "Username for 'https://github.com':");
      expect(username.stdout.trim()).toBe("x-access-token");

      const custom = await runHelper(cred.scriptPath, "Username for 'https://example.test':", {
        OVID_GIT_USERNAME: "oauth2",
      });
      expect(custom.stdout.trim()).toBe("oauth2");
    } finally {
      await cred.dispose();
    }
  });

  it("honours a jail-visible helper path while keeping the host path for cleanup", async () => {
    const { home, helperDir } = tempHome();
    const cred = await installGitCredential({
      homeDir: home,
      helperDir,
      token: TOKEN,
      uid: uid(),
      visibleHelperDir: "/run/ovid-git",
    });
    try {
      expect(cred.scriptPath.startsWith(helperDir)).toBe(true);
      expect(cred.env[GIT_ASKPASS_ENV]).toMatch(/^\/run\/ovid-git\/git-askpass-[0-9a-f]+\.sh$/);
      expect(cred.env.GIT_CONFIG_GLOBAL).toMatch(/^\/run\/ovid-git\/git-config-[0-9a-f]+$/);
    } finally {
      await cred.dispose();
    }
  });

  it("is what git itself uses: credential fill returns the token without touching disk", async () => {
    const { home, helperDir } = tempHome();
    const cred = await installGitCredential({
      homeDir: home,
      helperDir,
      token: TOKEN,
      uid: uid(),
    });
    try {
      const { stdout } = await execFileAsync(
        "/bin/sh",
        [
          "-c",
          "printf 'protocol=https\\nhost=github.com\\n\\n' | git -c credential.helper= credential fill",
        ],
        {
          env: {
            PATH: process.env.PATH ?? "/usr/local/bin:/usr/bin:/bin",
            HOME: home,
            ...cred.env,
          },
        },
      );
      expect(stdout).toContain("username=x-access-token");
      expect(stdout).toContain(`password=${TOKEN}`);
      // git's own credential store helper never ran: no plaintext file.
      expect(existsSync(join(home, ".git-credentials"))).toBe(false);
    } finally {
      await cred.dispose();
    }
  });

  it("dispose removes the helper and the isolation config and clears the token env", async () => {
    const { home, helperDir } = tempHome();
    const cred = await installGitCredential({
      homeDir: home,
      helperDir,
      token: TOKEN,
      uid: uid(),
    });
    await cred.dispose();

    expect(() => statSync(cred.scriptPath)).toThrow();
    expect(() => statSync(cred.configPath)).toThrow();
    expect(cred.env[GIT_TOKEN_ENV]).toBeUndefined();
    expect(cred.env[GIT_ASKPASS_ENV]).toBeUndefined();

    // Idempotent: a second dispose (finally + explicit cleanup) is a no-op.
    await expect(cred.dispose()).resolves.toBeUndefined();
  });

  it("refuses an empty token rather than falling back to a terminal prompt", async () => {
    const { home, helperDir } = tempHome();
    await expect(
      installGitCredential({ homeDir: home, helperDir, token: "", uid: uid() }),
    ).rejects.toThrow(/non-empty/);
  });

  it("renders a script with no token interpolation point other than the env var", () => {
    const body = renderAskpassScript();
    expect(body).toContain("OVID_GIT_TOKEN");
    expect(body).not.toContain(TOKEN);
    expect(body.startsWith("#!/bin/sh")).toBe(true);
  });
});

describe("credential leak checks", () => {
  function repoWithConfig(config: string): string {
    const dir = mkdtempSync(join(tmpdir(), "ovid-gitcfg-"));
    roots.push(dir);
    mkdirSync(join(dir, ".git"), { recursive: true });
    writeFileSync(join(dir, ".git", "config"), config);
    return dir;
  }

  it("accepts a clean .git/config with a credential-free https remote", async () => {
    const dir = repoWithConfig(
      '[remote "origin"]\n\turl = https://github.com/acme/app.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n',
    );
    await expect(assertNoTokenInGitConfig(dir, TOKEN)).resolves.toBeUndefined();
    await expect(assertNoCredentialLeak({ repoDir: dir, token: TOKEN })).resolves.toBeUndefined();
  });

  it("throws when the token is persisted in .git/config", async () => {
    const dir = repoWithConfig(
      `[remote "origin"]\n\turl = https://x-access-token:${TOKEN}@github.com/acme/app.git\n`,
    );
    await expect(assertNoTokenInGitConfig(dir, TOKEN)).rejects.toBeInstanceOf(
      GitCredentialLeakError,
    );
  });

  it("throws on a credential-bearing remote URL even when the secret is a stale token", async () => {
    const dir = repoWithConfig(
      '[remote "origin"]\n\turl = https://someone:old-secret@github.com/acme/app.git\n',
    );
    await expect(assertNoTokenInGitConfig(dir, TOKEN)).rejects.toMatchObject({
      code: "credential_leak",
      where: "git config (remote URL userinfo)",
    });
  });

  it("throws on an extraheader credential line", async () => {
    const dir = repoWithConfig(
      '[http "https://github.com/"]\n\textraheader = AUTHORIZATION: basic abcdef\n',
    );
    await expect(assertNoTokenInGitConfig(dir, TOKEN)).rejects.toMatchObject({
      code: "credential_leak",
    });
  });

  it("treats a missing config as clean", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ovid-gitcfg-empty-"));
    roots.push(dir);
    await expect(assertNoTokenInGitConfig(dir, TOKEN)).resolves.toBeUndefined();
  });

  it("detects a token in the home .gitconfig and .git-credentials", async () => {
    const home = mkdtempSync(join(tmpdir(), "ovid-githome-"));
    roots.push(home);
    const repo = repoWithConfig("[remote \"origin\"]\n\turl = https://github.com/acme/app.git\n");

    writeFileSync(join(home, ".gitconfig"), `[github]\n\ttoken = ${TOKEN}\n`);
    await expect(assertNoCredentialLeak({ repoDir: repo, homeDir: home, token: TOKEN })).rejects.toMatchObject(
      { code: "credential_leak", where: "global git config" },
    );

    rmSync(join(home, ".gitconfig"));
    writeFileSync(
      join(home, ".git-credentials"),
      `https://x-access-token:${TOKEN}@github.com\n`,
    );
    await expect(assertNoCredentialLeak({ repoDir: repo, homeDir: home, token: TOKEN })).rejects.toMatchObject(
      { code: "credential_leak", where: "git credential store" },
    );

    // And on a FAILED operation path too: the caller scans unconditionally.
    rmSync(join(home, ".git-credentials"));
    await expect(
      assertNoCredentialLeak({ repoDir: repo, homeDir: home, token: TOKEN }),
    ).resolves.toBeUndefined();
  });

  it("detects a credential-bearing .gitconfig even when the secret is not the current token", async () => {
    const home = mkdtempSync(join(tmpdir(), "ovid-githome-stale-"));
    roots.push(home);
    writeFileSync(
      join(home, ".gitconfig"),
      '[credential]\n\thelper = "store --file=/root/.git-credentials"\n',
    );
    // No token here, but the credential store file below carries a stale secret.
    writeFileSync(join(home, ".git-credentials"), "https://me:old-secret@github.com\n");
    await expect(
      assertNoCredentialLeak({ homeDir: home, token: TOKEN }),
    ).rejects.toMatchObject({ code: "credential_leak", where: "git credential store (URL userinfo)" });
  });

  it("throws when the token appears in argv", () => {
    expect(() =>
      assertNoTokenInArgv(["-c", "credential.helper=", "clone", "https://github.com/a/b.git"], TOKEN),
    ).not.toThrow();
    expect(() =>
      assertNoTokenInArgv(["-c", `http.extraHeader=AUTHORIZATION: ${TOKEN}`], TOKEN),
    ).toThrow(GitCredentialLeakError);
  });

  it("redacts every occurrence for logs", () => {
    expect(redactToken(`a ${TOKEN} b ${TOKEN}`, TOKEN)).toBe("a [redacted] b [redacted]");
    expect(redactToken("no secret here", TOKEN)).toBe("no secret here");
    expect(redactToken(`a ${TOKEN}`, "")).toBe(`a ${TOKEN}`);
  });
});
