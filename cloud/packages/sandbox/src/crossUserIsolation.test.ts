// Cross-USER isolation: one user (and their agent) can never touch another
// user's workspace, Studio repo or browser files.
//
// Owner requirement: "har user ka browser and studio bhi isolated ho bass
// sessions me shared ho — kabhi bhi ek user ya ovid agent dusre user ka
// workspace ya studio ya browser data kuchh bhi na touch kar paaye"
//
// Two layers enforce this and both are pinned here:
//  1. Every user gets their own numeric uid, and every directory under their
//     tree is chowned to it. The jail runs as that uid, so the OS refuses a
//     read/write into another user's tree even if a path is guessed.
//  2. Every path the agent supplies is confined to the session workspace
//     (resolveConfined), so `..`, absolute paths and symlinks cannot climb
//     out into a sibling user's tree.

import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";

import { createCgroupManager } from "./cgroups.js";
import { loadSandboxConfig, type SandboxConfig } from "./config.js";
import { createSandboxManager, type SandboxManager } from "./manager.js";
import { createNoopQuotaBackend } from "./quota.js";
import type { JailLauncher } from "./launcher.js";
import type { RootfsManifest } from "./rootfs.js";

const roots: string[] = [];
afterAll(() => {
  for (const r of roots) rmSync(r, { recursive: true, force: true });
});

const FAKE_MANIFEST: RootfsManifest = {
  name: "test-rootfs",
  baseImage: "ubuntu:noble",
  baseImageDigest: `sha256:${"a".repeat(64)}`,
  nodeVersion: "v22.0.0",
  pnpmVersion: "9.0.0",
  uvVersion: "0.5.0",
  aptPackages: [],
  buildDate: "2026-10-16T00:00:00Z",
  builderCommit: "testcommit",
};

class StubLauncher implements JailLauncher {
  spawn(): never {
    throw new Error("the isolation suite never spawns a jail");
  }
  spawnPty(): never {
    throw new Error("not used");
  }
}

async function fixture() {
  const wsRoot = mkdtempSync(join(tmpdir(), "ovid-iso-ws-"));
  const cgRoot = mkdtempSync(join(tmpdir(), "ovid-iso-cg-"));
  roots.push(wsRoot, cgRoot);
  const config: SandboxConfig = {
    ...loadSandboxConfig({}),
    workspacesRoot: wsRoot,
    cgroupRoot: cgRoot,
    cgroupBase: "base",
  };
  let next = 300_000;
  const launcher = new StubLauncher();
  const manager = createSandboxManager({
    config,
    allocateUid: async () => ++next,
    cgroups: createCgroupManager(config),
    quota: createNoopQuotaBackend(),
    launcher,
    rootfs: { path: "/tmp/unused-rootfs", manifest: FAKE_MANIFEST },
    diskUsage: async () => ({ freeGb: 100, warmGb: 0 }),
    clock: () => new Date("2026-10-23T00:00:00Z"),
  });
  return { manager, wsRoot };
}

const isRoot = typeof process.getuid === "function" && process.getuid() === 0;

describe.skipIf(!isRoot)("cross-user isolation", () => {
  it("gives each user a distinct uid and a distinct tree", async () => {
    const { manager } = await fixture();
    const a = await manager.attachSession("user-a", "chat-1");
    const b = await manager.attachSession("user-b", "chat-1");
    expect(a.uid).not.toBe(b.uid);
    expect(a.workspaceDir).not.toBe(b.workspaceDir);
  });

  it("never places one user's session workspace inside another's tree", async () => {
    const { manager, wsRoot } = await fixture();
    const a = await manager.attachSession("user-a", "chat-1");
    const b = await manager.attachSession("user-b", "chat-1");
    const aRoot = join(wsRoot, String(a.uid));
    const bRoot = join(wsRoot, String(b.uid));
    expect(a.workspaceDir.startsWith(`${aRoot}/`)).toBe(true);
    expect(a.workspaceDir.startsWith(`${bRoot}/`)).toBe(false);
    expect(b.workspaceDir.startsWith(`${bRoot}/`)).toBe(true);
    expect(b.workspaceDir.startsWith(`${aRoot}/`)).toBe(false);
  });

  it("keeps Studio roots per user — a session only ever binds its OWN user's repo root", async () => {
    const { manager, wsRoot } = await fixture();
    const a = await manager.attachSession("user-a", "chat-1");
    const b = await manager.attachSession("user-b", "chat-1");
    expect(a.studioDir).toBe(join(wsRoot, String(a.uid), "workspace"));
    expect(b.studioDir).toBe(join(wsRoot, String(b.uid), "workspace"));
    expect(a.studioDir).not.toBe(b.studioDir);
  });

  it("keeps the browser directory per user — two users never share one", async () => {
    const { manager, wsRoot } = await fixture();
    const a = await manager.browserWorkspaceDir("user-a");
    const b = await manager.browserWorkspaceDir("user-b");
    expect(a).not.toBe(b);
    expect(a.startsWith(`${join(wsRoot, "300001")}/`)).toBe(true);
    expect(b.startsWith(`${join(wsRoot, "300002")}/`)).toBe(true);
  });

  it("shares the browser and Studio roots across THAT user's sessions only", async () => {
    const { manager } = await fixture();
    const s1 = await manager.attachSession("user-a", "chat-1");
    const s2 = await manager.attachSession("user-a", "chat-2");
    // Sessions differ…
    expect(s1.workspaceDir).not.toBe(s2.workspaceDir);
    // …but the shared surfaces are the same for both.
    expect(s1.studioDir).toBe(s2.studioDir);
    expect(await manager.browserWorkspaceDir("user-a")).toBe(
      await manager.browserWorkspaceDir("user-a"),
    );
  });

  it("rejects a sessionId that could climb out of the user's tree", async () => {
    const { manager } = await fixture();
    for (const bad of ["../other-user", "a/b", "", "a".repeat(65)]) {
      await expect(manager.sessionWorkspaceDir("user-a", bad)).rejects.toThrow(/sessionId/);
    }
  });

});

describe.skipIf(!isRoot)("shared surfaces stay inside one user's tree", () => {
  it("binds /studio and /browser from this user's own uid tree only", async () => {
    const { manager, wsRoot } = await fixture();
    const a = await manager.attachSession("user-a", "chat-1");
    const b = await manager.attachSession("user-b", "chat-1");

    const aRoot = join(wsRoot, String(a.uid));
    expect(a.studioDir?.startsWith(`${aRoot}/`)).toBe(true);
    expect(a.browserDir?.startsWith(`${aRoot}/`)).toBe(true);
    // Never another user's tree.
    expect(a.studioDir?.includes(String(b.uid))).toBe(false);
    expect(a.browserDir?.includes(String(b.uid))).toBe(false);
    expect(b.studioDir?.includes(String(a.uid))).toBe(false);
    expect(b.browserDir?.includes(String(a.uid))).toBe(false);
  });

  it("a session's /workspace is a sibling of its shared surfaces, not inside them", async () => {
    const { manager } = await fixture();
    const a = await manager.attachSession("user-a", "chat-1");
    expect(a.workspaceDir.startsWith(`${a.studioDir}/`)).toBe(false);
    expect(a.workspaceDir.startsWith(`${a.browserDir}/`)).toBe(false);
    expect(a.studioDir).not.toBe(a.browserDir);
  });
});
