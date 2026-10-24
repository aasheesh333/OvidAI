import { spawnSync } from "node:child_process";
import {
  existsSync,
  lstatSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

const exporter = fileURLToPath(new URL("./exportSystemRequestFixtures.mjs", import.meta.url));
const fixtureName = "system-requests-v1.json";
let root;
let canaryRoot;

function directoryFor(kind) {
  const directories = {
    source: ["contracts", "fixtures"],
    web: ["web", "test", "fixtures"],
    flutter: ["flutter", "test", "fixtures"],
  };
  return join(root, ...directories[kind]);
}

function pathFor(kind) {
  return join(directoryFor(kind), fixtureName);
}

function run(...args) {
  return spawnSync(process.execPath, [exporter, ...args], {
    encoding: "utf8",
    env: { ...process.env, OVID_SYSTEM_REQUEST_FIXTURE_ROOT: root },
  });
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "ovid-system-request-fixtures-"));
  canaryRoot = mkdtempSync(join(tmpdir(), "ovid-system-request-external-canary-"));
  mkdirSync(directoryFor("source"), { recursive: true });
  writeFileSync(pathFor("source"), '{\n  "contractVersion": 1,\n  "fixture": "safe"\n}\n');
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
  rmSync(canaryRoot, { recursive: true, force: true });
});

describe("system request fixture exporter", () => {
  it("writes deterministic byte-identical mirrors and passes the real --check mode", () => {
    const first = run();
    expect(first.status, first.stderr || first.stdout).toBe(0);
    expect(readFileSync(pathFor("web"))).toEqual(readFileSync(pathFor("source")));
    expect(readFileSync(pathFor("flutter"))).toEqual(readFileSync(pathFor("source")));

    const webBefore = readFileSync(pathFor("web"));
    const flutterBefore = readFileSync(pathFor("flutter"));
    expect(run().status).toBe(0);
    expect(readFileSync(pathFor("web"))).toEqual(webBefore);
    expect(readFileSync(pathFor("flutter"))).toEqual(flutterBefore);
    const checked = run("--check");
    expect(checked.status, checked.stderr || checked.stdout).toBe(0);
  });

  it("fails --check on content drift without repairing either mirror", () => {
    expect(run().status).toBe(0);
    const flutterBefore = readFileSync(pathFor("flutter"));
    writeFileSync(pathFor("web"), '{"drifted":true}\n');
    const checked = run("--check");
    expect(checked.status).not.toBe(0);
    expect(`${checked.stdout}${checked.stderr}`).toContain(fixtureName);
    expect(readFileSync(pathFor("web"), "utf8")).toBe('{"drifted":true}\n');
    expect(readFileSync(pathFor("flutter"))).toEqual(flutterBefore);
  });

  it("fails --check on a missing mirror without recreating it", () => {
    expect(run().status).toBe(0);
    rmSync(pathFor("flutter"));
    const checked = run("--check");
    expect(checked.status).not.toBe(0);
    expect(`${checked.stdout}${checked.stderr}`).toContain(fixtureName);
    expect(existsSync(pathFor("flutter"))).toBe(false);
  });

  it("keeps --check non-mutating when a mirror directory is absent", () => {
    expect(run().status).toBe(0);
    rmSync(directoryFor("web"), { recursive: true });
    const checked = run("--check");
    expect(checked.status).not.toBe(0);
    expect(existsSync(directoryFor("web"))).toBe(false);
    expect(readFileSync(pathFor("flutter"))).toEqual(readFileSync(pathFor("source")));
  });

  it("rejects a canonical-named file symlink without overwriting its external target", () => {
    expect(run().status).toBe(0);
    const canary = join(canaryRoot, "file-target.json");
    const canaryBytes = "EXTERNAL FILE CANARY — MUST NOT CHANGE\n";
    writeFileSync(canary, canaryBytes);
    rmSync(pathFor("web"));
    symlinkSync(canary, pathFor("web"));

    const exported = run();
    expect.soft(exported.status, exported.stderr || exported.stdout).not.toBe(0);
    expect.soft(readFileSync(canary, "utf8")).toBe(canaryBytes);
    expect.soft(lstatSync(pathFor("web")).isSymbolicLink()).toBe(true);
  });

  it("rejects a symlinked mirror directory without touching external files", () => {
    expect(run().status).toBe(0);
    const outside = join(canaryRoot, "directory-target");
    mkdirSync(outside, { recursive: true });
    const canary = join(outside, fixtureName);
    const canaryBytes = "EXTERNAL DIRECTORY CANARY — MUST NOT CHANGE\n";
    writeFileSync(canary, canaryBytes);
    rmSync(directoryFor("web"), { recursive: true });
    symlinkSync(outside, directoryFor("web"), "dir");

    const exported = run();
    expect.soft(exported.status, exported.stderr || exported.stdout).not.toBe(0);
    expect.soft(readFileSync(canary, "utf8")).toBe(canaryBytes);
    expect.soft(readdirSync(outside)).toEqual([fixtureName]);
    expect.soft(lstatSync(directoryFor("web")).isSymbolicLink()).toBe(true);
  });

  it("rejects a symlinked mirror ancestor without touching its external target", () => {
    expect(run().status).toBe(0);
    const outside = join(canaryRoot, "ancestor-target");
    mkdirSync(join(outside, "fixtures"), { recursive: true });
    const canary = join(outside, "fixtures", fixtureName);
    const canaryBytes = "EXTERNAL ANCESTOR CANARY — MUST NOT CHANGE\n";
    writeFileSync(canary, canaryBytes);
    const ancestor = join(directoryFor("web"), "..");
    rmSync(ancestor, { recursive: true });
    symlinkSync(outside, ancestor, "dir");

    const exported = run();
    expect.soft(exported.status, exported.stderr || exported.stdout).not.toBe(0);
    expect.soft(readFileSync(canary, "utf8")).toBe(canaryBytes);
    expect.soft(lstatSync(ancestor).isSymbolicLink()).toBe(true);
  });

  it("keeps --check non-mutating and rejects a matching file-symlink target", () => {
    expect(run().status).toBe(0);
    const canary = join(canaryRoot, "matching-check-target.json");
    writeFileSync(canary, readFileSync(pathFor("source")));
    rmSync(pathFor("web"));
    symlinkSync(canary, pathFor("web"));
    const before = readFileSync(canary);

    const checked = run("--check");
    expect.soft(checked.status, checked.stderr || checked.stdout).not.toBe(0);
    expect.soft(readFileSync(canary)).toEqual(before);
    expect.soft(lstatSync(pathFor("web")).isSymbolicLink()).toBe(true);
  });

  it("keeps --check non-mutating and rejects a matching directory-symlink target", () => {
    expect(run().status).toBe(0);
    const outside = join(canaryRoot, "matching-directory-target");
    mkdirSync(outside, { recursive: true });
    writeFileSync(join(outside, fixtureName), readFileSync(pathFor("source")));
    rmSync(directoryFor("web"), { recursive: true });
    symlinkSync(outside, directoryFor("web"), "dir");
    const before = readFileSync(join(outside, fixtureName));

    const checked = run("--check");
    expect.soft(checked.status, checked.stderr || checked.stdout).not.toBe(0);
    expect.soft(readFileSync(join(outside, fixtureName))).toEqual(before);
    expect.soft(readdirSync(outside)).toEqual([fixtureName]);
    expect.soft(lstatSync(directoryFor("web")).isSymbolicLink()).toBe(true);
  });

  it("rejects a symlinked canonical source without exporting its target", () => {
    const canary = join(canaryRoot, "canonical-target.json");
    writeFileSync(canary, readFileSync(pathFor("source")));
    rmSync(pathFor("source"));
    symlinkSync(canary, pathFor("source"));

    const checked = run("--check");
    expect(checked.status).not.toBe(0);
    expect(`${checked.stdout}${checked.stderr}`).toContain("System request fixture export refused");
    expect(`${checked.stdout}${checked.stderr}`).not.toContain("Cannot find module");
    expect(existsSync(pathFor("web"))).toBe(false);
    expect(existsSync(pathFor("flutter"))).toBe(false);
    expect(lstatSync(pathFor("source")).isSymbolicLink()).toBe(true);
  });
});
