import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

const exporter = fileURLToPath(new URL("./export-fixtures.mjs", import.meta.url));
let root;

function run(...args) {
  return spawnSync(process.execPath, [exporter, ...args], {
    encoding: "utf8",
    env: { ...process.env, OVID_CONTRACT_EXPORT_ROOT: root },
  });
}

function directoryFor(kind) {
  const directories = {
    source: ["contracts", "fixtures"],
    web: ["web", "contracts", "fixtures"],
    flutter: ["flutter", "test", "fixtures", "contracts"],
  };
  return join(root, ...directories[kind]);
}

function pathFor(kind, name = "alpha-v1.json") {
  return join(directoryFor(kind), name);
}

function jsonFiles(kind) {
  if (!existsSync(directoryFor(kind))) return [];
  return readdirSync(directoryFor(kind), { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith(".json"))
    .map((entry) => entry.name)
    .sort();
}

function expectDirectoryByteIdentity() {
  const canonicalNames = jsonFiles("source");
  expect(canonicalNames.length).toBeGreaterThan(0);
  for (const kind of ["web", "flutter"]) {
    expect(jsonFiles(kind)).toEqual(canonicalNames);
    for (const name of canonicalNames) {
      expect(readFileSync(pathFor(kind, name))).toEqual(readFileSync(pathFor("source", name)));
    }
  }
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "ovid-contract-export-"));
  mkdirSync(directoryFor("source"), { recursive: true });
  writeFileSync(pathFor("source"), '{\n  "contractVersion": 1,\n  "value": "alpha"\n}\n');
  mkdirSync(join(directoryFor("source"), "nested"), { recursive: true });
  writeFileSync(join(directoryFor("source"), "nested", "ignored.txt"), "not a fixture\n");
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

describe("canonical fixture exporter", () => {
  it("writes deterministic directory-level byte-identical Web and Flutter mirrors", () => {
    const first = run();
    expect(first.status, first.stderr || first.stdout).toBe(0);
    expectDirectoryByteIdentity();

    const firstWeb = readFileSync(pathFor("web"));
    const firstFlutter = readFileSync(pathFor("flutter"));
    const second = run();
    expect(second.status, second.stderr || second.stdout).toBe(0);
    expect(readFileSync(pathFor("web"))).toEqual(firstWeb);
    expect(readFileSync(pathFor("flutter"))).toEqual(firstFlutter);
    expectDirectoryByteIdentity();
  });

  it("passes --check only when complete filename sets and bytes match", () => {
    expect(run().status).toBe(0);
    const checked = run("--check");
    expect(checked.status, checked.stderr || checked.stdout).toBe(0);
  });

  it("fails --check on content drift without repairing the drifted mirror", () => {
    expect(run().status).toBe(0);
    writeFileSync(pathFor("web"), '{"drifted":true}\n');
    const checked = run("--check");
    expect(checked.status).not.toBe(0);
    expect(`${checked.stdout}${checked.stderr}`).toContain("alpha-v1.json");
    expect(readFileSync(pathFor("web"), "utf8")).toBe('{"drifted":true}\n');
  });

  it("fails --check when a required mirror file is missing", () => {
    expect(run().status).toBe(0);
    rmSync(pathFor("flutter"));
    const checked = run("--check");
    expect(checked.status).not.toBe(0);
    expect(`${checked.stdout}${checked.stderr}`).toContain("alpha-v1.json");
  });

  it("fails --check on unexpected stale mirror JSON without deleting it", () => {
    expect(run().status).toBe(0);
    writeFileSync(pathFor("web", "stale-v1.json"), '{"stale":true}\n');
    writeFileSync(pathFor("flutter", "unexpected-v1.json"), '{"unexpected":true}\n');
    const checked = run("--check");
    expect(checked.status).not.toBe(0);
    expect(`${checked.stdout}${checked.stderr}`).toContain("stale-v1.json");
    expect(`${checked.stdout}${checked.stderr}`).toContain("unexpected-v1.json");
    expect(existsSync(pathFor("web", "stale-v1.json"))).toBe(true);
    expect(existsSync(pathFor("flutter", "unexpected-v1.json"))).toBe(true);
  });

  it("export removes stale mirror JSON only inside the owned fixture directories", () => {
    expect(run().status).toBe(0);
    writeFileSync(pathFor("web", "stale-v1.json"), '{"stale":true}\n');
    writeFileSync(pathFor("flutter", "stale-v1.json"), '{"stale":true}\n');
    writeFileSync(pathFor("web", "keep.txt"), "leave non-JSON files alone\n");
    writeFileSync(join(root, "web", "contracts", "unrelated.json"), '{"keep":true}\n');
    expect(run("--check").status).not.toBe(0);

    const exported = run();
    expect(exported.status, exported.stderr || exported.stdout).toBe(0);
    expect(existsSync(pathFor("web", "stale-v1.json"))).toBe(false);
    expect(existsSync(pathFor("flutter", "stale-v1.json"))).toBe(false);
    expect(readFileSync(pathFor("web", "keep.txt"), "utf8")).toBe("leave non-JSON files alone\n");
    expect(existsSync(join(root, "web", "contracts", "unrelated.json"))).toBe(true);
    expectDirectoryByteIdentity();
    expect(run("--check").status).toBe(0);
  });

  it("detects a new canonical fixture and a deleted canonical fixture in both directions", () => {
    expect(run().status).toBe(0);
    writeFileSync(pathFor("source", "beta-v1.json"), '{"contractVersion":1,"value":"beta"}\n');
    const missing = run("--check");
    expect(missing.status).not.toBe(0);
    expect(`${missing.stdout}${missing.stderr}`).toContain("beta-v1.json");
    expect(run().status).toBe(0);
    expectDirectoryByteIdentity();

    rmSync(pathFor("source", "beta-v1.json"));
    const deleted = run("--check");
    expect(deleted.status).not.toBe(0);
    expect(`${deleted.stdout}${deleted.stderr}`).toContain("beta-v1.json");
    expect(run().status).toBe(0);
    expect(existsSync(pathFor("web", "beta-v1.json"))).toBe(false);
    expect(existsSync(pathFor("flutter", "beta-v1.json"))).toBe(false);
    expectDirectoryByteIdentity();
    expect(run("--check").status).toBe(0);
  });

  it("refuses an empty canonical source for both export and --check without erasing mirrors", () => {
    expect(run().status).toBe(0);
    const before = readFileSync(pathFor("web"));
    rmSync(pathFor("source"));
    const checked = run("--check");
    expect(checked.status).not.toBe(0);
    expect(`${checked.stdout}${checked.stderr}`).toMatch(/empty|no canonical/i);
    const exported = run();
    expect(exported.status).not.toBe(0);
    expect(`${exported.stdout}${exported.stderr}`).toMatch(/empty|no canonical/i);
    expect(readFileSync(pathFor("web"))).toEqual(before);
    expect(readFileSync(pathFor("flutter"))).toEqual(before);
  });
});
