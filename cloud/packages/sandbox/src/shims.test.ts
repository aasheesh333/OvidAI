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
const UNCONDITIONAL = ALL_SHIMS.slice(0, 9);

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

describe("cargo shim (blocks `cargo build` only)", () => {
  it("refuses `cargo build`", () => {
    const r = runShim("cargo", ["build"]);
    expect(r.status).toBe(126);
    expect(r.stdout).toBe(`${REFUSAL_COPY}\n`);
  });

  it("passes `cargo test` through — real cargo is absent, so 127 not-installed", () => {
    const r = runShim("cargo", ["test"]);
    expect(r.status).toBe(127);
    expect(r.stdout).toBe("");
    expect(r.stderr).toContain("cargo: not installed in cloud workspaces");
  });
});

describe("docker shim (blocks `docker build` only)", () => {
  it("refuses `docker build`", () => {
    const r = runShim("docker", ["build", "x"]);
    expect(r.status).toBe(126);
    expect(r.stdout).toBe(`${REFUSAL_COPY}\n`);
  });

  it("does not refuse `docker ps` (may exec the real docker on this host)", () => {
    const r = runShim("docker", ["ps"]);
    expect(r.status).not.toBe(126);
    expect(r.stdout).not.toContain(REFUSAL_COPY);
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
});
