import { chmodSync, mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { parseRootfsManifest, resolveRootfs, RootfsUnavailable } from "./rootfs.js";

const VALID_MANIFEST = {
  name: "ubuntu-noble-min-20261016-r1",
  baseImage: "ubuntu:24.04",
  baseImageDigest: `sha256:${"a".repeat(64)}`,
  nodeVersion: "v22.20.0",
  pnpmVersion: "10.34.0",
  uvVersion: "0.13.1",
  aptPackages: ["ca-certificates", "curl", "git"],
  buildDate: "2026-10-16T00:00:00.000Z",
  builderCommit: "365df63",
};

// The binaries resolveRootfs requires inside the tree (rootfs.ts contract).
const REQUIRED_FILES = [
  "usr/bin/env",
  "usr/local/bin/node",
  "usr/local/bin/pnpm",
  "usr/local/bin/uv",
  "usr/bin/git",
  "usr/bin/python3",
  "usr/local/bin/ovid",
] as const;

const fixtures: string[] = [];
afterAll(() => {
  for (const d of fixtures) rmSync(d, { recursive: true, force: true });
});

function writeFixture(manifest: unknown = VALID_MANIFEST): string {
  const dir = mkdtempSync(join(tmpdir(), "ovid-rootfs-fixture-"));
  fixtures.push(dir);
  for (const rel of ["usr/bin", "usr/local/bin"]) {
    mkdirSync(join(dir, rel), { recursive: true });
  }
  for (const rel of REQUIRED_FILES) {
    const p = join(dir, rel);
    writeFileSync(p, "#!/bin/sh\n", { flag: "wx" });
    chmodSync(p, 0o755);
  }
  writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
  return dir;
}

describe("parseRootfsManifest", () => {
  it("accepts a well-formed manifest", () => {
    const m = parseRootfsManifest(VALID_MANIFEST);
    expect(m).toEqual(VALID_MANIFEST);
    expect(m.name).toBe("ubuntu-noble-min-20261016-r1");
  });

  it("rejects a manifest missing baseImageDigest", () => {
    const { baseImageDigest: _omit, ...rest } = VALID_MANIFEST;
    expect(() => parseRootfsManifest(rest)).toThrow(/baseImageDigest/);
  });

  it("rejects an ill-typed field (aptPackages as string)", () => {
    expect(() =>
      parseRootfsManifest({ ...VALID_MANIFEST, aptPackages: "ca-certificates" }),
    ).toThrow();
  });

  it("rejects non-objects", () => {
    expect(() => parseRootfsManifest(null)).toThrow();
    expect(() => parseRootfsManifest("nope")).toThrow();
    expect(() => parseRootfsManifest([VALID_MANIFEST])).toThrow();
  });

  it("ignores extra fields the build pipeline adds (dpkg snapshot)", () => {
    const m = parseRootfsManifest({ ...VALID_MANIFEST, dpkgSnapshot: "ii  curl ..." });
    expect(m).toEqual(VALID_MANIFEST);
  });
});

describe("resolveRootfs", () => {
  it("returns the realpath and parsed manifest for a complete tree", async () => {
    const dir = writeFixture();
    const r = await resolveRootfs(dir);
    expect(r.path).toBe(realpathSync(dir));
    expect(r.manifest).toEqual(VALID_MANIFEST);
  });

  it("follows the `current` symlink to the real revision directory", async () => {
    const dir = writeFixture();
    const linkParent = mkdtempSync(join(tmpdir(), "ovid-rootfs-link-"));
    fixtures.push(linkParent);
    symlinkSync(dir, join(linkParent, "current"));
    const r = await resolveRootfs(join(linkParent, "current"));
    expect(r.path).toBe(realpathSync(dir));
    expect(r.manifest.name).toBe(VALID_MANIFEST.name);
  });

  it("throws RootfsUnavailable naming a missing binary (usr/local/bin/uv)", async () => {
    const dir = writeFixture();
    unlinkSync(join(dir, "usr/local/bin/uv"));
    await expect(resolveRootfs(dir)).rejects.toThrow(RootfsUnavailable);
    await expect(resolveRootfs(dir)).rejects.toThrow(/usr\/local\/bin\/uv/);
  });

  it("throws RootfsUnavailable when manifest.json is missing", async () => {
    const dir = writeFixture();
    unlinkSync(join(dir, "manifest.json"));
    await expect(resolveRootfs(dir)).rejects.toThrow(RootfsUnavailable);
  });

  it("throws RootfsUnavailable for a nonexistent path", async () => {
    await expect(resolveRootfs("/opt/ovid-rootfs/does-not-exist")).rejects.toThrow(
      RootfsUnavailable,
    );
  });

  it("throws RootfsUnavailable when the manifest inside the tree is invalid", async () => {
    const dir = writeFixture({ ...VALID_MANIFEST, nodeVersion: 22 });
    await expect(resolveRootfs(dir)).rejects.toThrow(RootfsUnavailable);
  });
});
