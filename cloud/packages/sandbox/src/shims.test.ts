import { spawnSync } from "node:child_process";
import { accessSync, chmodSync, constants, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, describe, expect, it } from "vitest";

// <cloud>/deploy/rootfs/shims, resolved from this file's location in src/.
const SHIMS_DIR = fileURLToPath(new URL("../../../deploy/rootfs/shims", import.meta.url));

// The spec §7 refusal copy, carried VERBATIM by every blocking shim (layer 2).
// Task 4 pins the SandboxManager interceptor constant against these files.
const REFUSAL_COPY =
  "Heavy native compilation (APK/Gradle/Kotlin builds) is disabled on live cloud workspaces. Use GitHub Actions CI or syntax/lint preview mode instead.";

// Every shim that must exist in cloud/deploy/rootfs/shims (Task 3 contract).
const ALL_SHIMS = [
  "gcc",
  "g++",
  "make",
  "gradle",
  "gradlew",
  "kotlinc",
  "javac",
  "sdkmanager",
  "ndk-build",
  "cargo",
  "docker",
  "flutter",
  "ovid",
] as const;

// Unconditional blockers: refuse every invocation (spec §7 denylist).
// cargo and docker joined the list in the 2026-10-18 lockdown: the policy
// blocks the whole toolchain, not just the `build` subcommand, so the layer-2
// shims must agree (a `cargo test` fall-through would run a real compiler).
const UNCONDITIONAL = [
  "gcc",
  "g++",
  "make",
  "gradle",
  "gradlew",
  "kotlinc",
  "javac",
  "sdkmanager",
  "ndk-build",
  "cargo",
  "docker",
] as const;

interface ShimRun {
  status: number | null;
  stdout: string;
  stderr: string;
}

// Portable execution: the host's `sh` interprets the shim file directly, so
// the suite needs no jail and no executable bit on a fresh checkout.
function runShim(
  name: string,
  args: string[],
  opts: { cwd?: string; path?: string } = {},
): ShimRun {
  const r = spawnSync("sh", [join(SHIMS_DIR, name), ...args], {
    encoding: "utf8",
    timeout: 15_000,
    cwd: opts.cwd,
    env: opts.path === undefined ? process.env : { ...process.env, PATH: opts.path },
  });
  if (r.error) throw r.error;
  return { status: r.status, stdout: r.stdout, stderr: r.stderr };
}

const tmpDirs: string[] = [];
afterAll(() => {
  for (const d of tmpDirs) rmSync(d, { recursive: true, force: true });
});

// A stub binary that records "<name>" then each argv word, one per line, to
// logPath — lets the ovid shim tests capture exactly what pnpm/uv received.
function makeStubDir(name: string, logPath: string): string {
  const dir = mkdtempSync(join(tmpdir(), "ovid-shims-stub-"));
  tmpDirs.push(dir);
  const stub = join(dir, name);
  writeFileSync(
    stub,
    `#!/bin/sh\n{ echo "${name}"; for a in "$@"; do echo "$a"; done; } >> ${JSON.stringify(logPath)}\n`,
  );
  chmodSync(stub, 0o755);
  return dir;
}

function stubLog(): string {
  const dir = mkdtempSync(join(tmpdir(), "ovid-shims-log-"));
  tmpDirs.push(dir);
  return join(dir, "log");
}

function projDir(files: Record<string, string>): string {
  const dir = mkdtempSync(join(tmpdir(), "ovid-shims-proj-"));
  tmpDirs.push(dir);
  for (const [name, content] of Object.entries(files)) {
    writeFileSync(join(dir, name), content);
  }
  return dir;
}

describe("shim file contract", () => {
  it("contains exactly the 13 Task 3 shims", () => {
    expect(readdirSync(SHIMS_DIR).sort()).toEqual([...ALL_SHIMS].sort());
  });

  it("every shim is #!/bin/sh with mode 755 (baked ahead of /usr/bin)", () => {
    for (const name of ALL_SHIMS) {
      const p = join(SHIMS_DIR, name);
      expect(readFileSync(p, "utf8").split("\n", 1)[0]).toBe("#!/bin/sh");
      accessSync(p, constants.X_OK);
    }
  });
});

describe("unconditional blockers", () => {
  it.each(UNCONDITIONAL)("%s prints the refusal copy verbatim to stdout and exits 126", (name) => {
    const r = runShim(name, []);
    expect(r.status).toBe(126);
    expect(r.stdout).toBe(`${REFUSAL_COPY}\n`);
    expect(r.stderr).toBe("");
  });

  it.each(UNCONDITIONAL)("%s refuses regardless of subcommand", (name) => {
    const r = runShim(name, ["anything", "--flag"]);
    expect(r.status).toBe(126);
    expect(r.stdout).toBe(`${REFUSAL_COPY}\n`);
  });
});

describe("cargo/docker shims (fully unavailable since the lockdown)", () => {
  it.each([
    ["cargo", "build"],
    ["cargo", "test"],
    ["cargo", "--version"],
    ["docker", "build"],
    ["docker", "ps"],
    ["docker", "pull"],
  ])("%s %s is refused with the pinned copy", (name, sub) => {
    const r = runShim(name, [sub]);
    expect(r.status).toBe(126);
    expect(r.stdout).toBe(`${REFUSAL_COPY}\n`);
  });
});

describe("flutter shim (blocks `flutter build apk|appbundle|ios` only)", () => {
  it.each(["apk", "appbundle", "ios"])("refuses `flutter build %s`", (target) => {
    const r = runShim("flutter", ["build", target]);
    expect(r.status).toBe(126);
    expect(r.stdout).toBe(`${REFUSAL_COPY}\n`);
  });

  it.each(["analyze", "test"])("does not refuse `flutter %s` (spec §7 must pass)", (sub) => {
    const r = runShim("flutter", [sub]);
    expect(r.status).not.toBe(126);
    expect(r.stdout).not.toContain(REFUSAL_COPY);
  });
});

describe("ovid shim (v1 package-install dispatch)", () => {
  it("`ovid install foo` in a package.json dir dispatches `pnpm add foo`", () => {
    const log = stubLog();
    const stubDir = makeStubDir("pnpm", log);
    const proj = projDir({ "package.json": '{"name":"t","version":"0.0.0"}' });
    const r = runShim("ovid", ["install", "foo"], {
      cwd: proj,
      path: `${stubDir}:${process.env.PATH}`,
    });
    expect(r.status).toBe(0);
    expect(readFileSync(log, "utf8").split("\n").filter(Boolean)).toEqual([
      "pnpm",
      "add",
      "foo",
    ]);
  });

  it("`ovid install foo` in a pyproject.toml dir dispatches `uv add foo`", () => {
    const log = stubLog();
    const stubDir = makeStubDir("uv", log);
    const proj = projDir({ "pyproject.toml": "[project]\nname = 't'\n" });
    const r = runShim("ovid", ["install", "foo"], {
      cwd: proj,
      path: `${stubDir}:${process.env.PATH}`,
    });
    expect(r.status).toBe(0);
    expect(readFileSync(log, "utf8").split("\n").filter(Boolean)).toEqual([
      "uv",
      "add",
      "foo",
    ]);
  });

  it("`ovid install` with no package manifest errors to stderr and exits 2", () => {
    const log = stubLog();
    const stubDir = makeStubDir("pnpm", log);
    const proj = projDir({ "readme.txt": "not a manifest\n" });
    const r = runShim("ovid", ["install", "foo"], {
      cwd: proj,
      path: `${stubDir}:${process.env.PATH}`,
    });
    expect(r.status).toBe(2);
    expect(r.stderr).not.toBe("");
    expect(() => accessSync(log)).toThrow();
  });

  it("`ovid --help` succeeds", () => {
    const r = runShim("ovid", ["--help"]);
    expect(r.status).toBe(0);
    expect(r.stdout).toContain("install");
  });

  // --- Task 10: cache-prune + hardened dispatch -----------------------------

  it("`ovid cache-prune` invokes `pnpm store prune` then `uv cache prune`", () => {
    const log = stubLog();
    const pnpmDir = makeStubDir("pnpm", log);
    const uvDir = makeStubDir("uv", log);
    const proj = projDir({}); // no manifest needed — prunes are store-global
    const r = runShim("ovid", ["cache-prune"], {
      cwd: proj,
      path: `${pnpmDir}:${uvDir}:${process.env.PATH}`,
    });
    expect(r.status).toBe(0);
    expect(readFileSync(log, "utf8").split("\n").filter(Boolean)).toEqual([
      "pnpm",
      "store",
      "prune",
      "uv",
      "cache",
      "prune",
    ]);
  });

  it("`ovid cache-prune` exits non-zero when a prune fails (status propagates)", () => {
    // pnpm stub exits 3 after logging — uv still runs, overall exit is 3.
    const log = stubLog();
    const pnpmDir = makeStubDir("pnpm", log);
    const failStub = join(pnpmDir, "pnpm");
    writeFileSync(failStub, `#!/bin/sh\n{ echo "pnpm"; for a in "$@"; do echo "$a"; done; } >> ${JSON.stringify(log)}\nexit 3\n`);
    const uvDir = makeStubDir("uv", log);
    const proj = projDir({});
    const r = runShim("ovid", ["cache-prune"], {
      cwd: proj,
      path: `${pnpmDir}:${uvDir}:${process.env.PATH}`,
    });
    expect(r.status).toBe(3);
    // uv ran too — one failing prune does not skip the other.
    expect(readFileSync(log, "utf8").split("\n").filter(Boolean)).toEqual([
      "pnpm",
      "store",
      "prune",
      "uv",
      "cache",
      "prune",
    ]);
  });

  it("`ovid cache-prune extra` rejects arguments (hardened: nothing user-supplied reaches pnpm/uv)", () => {
    const log = stubLog();
    const pnpmDir = makeStubDir("pnpm", log);
    const uvDir = makeStubDir("uv", log);
    const proj = projDir({});
    const r = runShim("ovid", ["cache-prune", "--force"], {
      cwd: proj,
      path: `${pnpmDir}:${uvDir}:${process.env.PATH}`,
    });
    expect(r.status).toBe(2);
    expect(r.stderr).not.toBe("");
    expect(() => accessSync(log)).toThrow(); // neither prune invoked
  });

  it("`ovid install` precedence: package.json wins when BOTH manifests exist", () => {
    const log = stubLog();
    const pnpmDir = makeStubDir("pnpm", log);
    const uvDir = makeStubDir("uv", log);
    const proj = projDir({
      "package.json": '{"name":"t","version":"0.0.0"}',
      "pyproject.toml": "[project]\nname = 't'\n",
    });
    const r = runShim("ovid", ["install", "foo"], {
      cwd: proj,
      path: `${pnpmDir}:${uvDir}:${process.env.PATH}`,
    });
    expect(r.status).toBe(0);
    expect(readFileSync(log, "utf8").split("\n").filter(Boolean)).toEqual([
      "pnpm",
      "add",
      "foo",
    ]); // uv never invoked
  });

  it("`ovid install` with no args and both manifests → `pnpm install --prefer-offline`", () => {
    const log = stubLog();
    const pnpmDir = makeStubDir("pnpm", log);
    const uvDir = makeStubDir("uv", log);
    const proj = projDir({
      "package.json": '{"name":"t","version":"0.0.0","dependencies":{}}',
      "pyproject.toml": "[project]\nname = 't'\n",
    });
    const r = runShim("ovid", ["install"], {
      cwd: proj,
      path: `${pnpmDir}:${uvDir}:${process.env.PATH}`,
    });
    expect(r.status).toBe(0);
    expect(readFileSync(log, "utf8").split("\n").filter(Boolean)).toEqual([
      "pnpm",
      "install",
      "--prefer-offline",
    ]);
  });

  it("`ovid --help` mentions cache-prune", () => {
    const r = runShim("ovid", ["--help"]);
    expect(r.status).toBe(0);
    expect(r.stdout).toContain("cache-prune");
  });
});
