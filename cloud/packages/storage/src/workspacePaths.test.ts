import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import {
  createCgroupManager,
} from "../../sandbox/src/cgroups.js";
import { loadSandboxConfig } from "../../sandbox/src/config.js";
import {
  createSandboxManager,
  type SandboxManager,
} from "../../sandbox/src/manager.js";
import type { JailLauncher } from "../../sandbox/src/launcher.js";
import type { RootfsManifest } from "../../sandbox/src/rootfs.js";
import type { QuotaBackend } from "../../sandbox/src/quota.js";

import { sessionWorkspacePath, workspaceDir } from "./workspacePaths.js";
import { KeyLayoutError } from "./errors.js";

/**
 * Contract 1 (fix round 1): this helper's output must EQUAL P2's landed
 * SandboxManager.workspaceDir(userId, sessionId) seam — the controller ruled
 * the numeric-uid layout {workspacesRoot}/{uid}/sessions/{sessionId} wins.
 * The test drives the REAL manager (stub allocator + tmpdir roots — the
 * portable-fixture pattern from sandbox's own manager.test.ts; workspaceDir
 * spawns no jail and creates no cgroups, so the stub launcher is never
 * called).
 */

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

class NoopQuota implements QuotaBackend {
  readonly kind = "noop" as const;
  async applyQuota(): Promise<void> {
    /* recorded by the manager's own suite; irrelevant to the layout pin */
  }
}

class NeverSpawnedLauncher implements JailLauncher {
  spawn(): never {
    throw new Error("workspaceDir must never spawn a jail");
  }
  spawnPty(): never {
    throw new Error("workspaceDir must never spawn a pty");
  }
}

const FIXED_UID = 200_001;

async function freshManager(wsRoot: string): Promise<SandboxManager> {
  const cgRoot = mkdtempSync(join(tmpdir(), "ovid-wsp-cg-"));
  roots.push(cgRoot);
  const config = {
    ...loadSandboxConfig({}),
    workspacesRoot: wsRoot,
    cgroupRoot: cgRoot,
    cgroupBase: "base",
  };
  return createSandboxManager({
    config,
    // Stub allocator: idempotent fixed uid — everything the seam needs.
    allocateUid: async () => FIXED_UID,
    cgroups: createCgroupManager(config),
    quota: new NoopQuota(),
    launcher: new NeverSpawnedLauncher(),
    rootfs: { path: "/tmp/ovid-storage-rootfs-unused", manifest: FAKE_MANIFEST },
    diskUsage: async () => ({ freeGb: 100, warmGb: 0 }),
    clock: () => new Date("2026-10-16T00:00:00Z"),
  });
}

describe("workspaceDir — landed layout", () => {
  it("keys by the numeric uid with no users/ segment and no workspace suffix", () => {
    expect(workspaceDir("/workspaces/users", 200001, "sess-1")).toBe(
      join("/workspaces/users", "200001", "sessions", "sess-1"),
    );
  });

  it("accepts the uid as a string too", () => {
    expect(workspaceDir("/ws", "200001", "s")).toBe(join("/ws", "200001", "sessions", "s"));
  });

  it("still asserts both segments", () => {
    expect(() => workspaceDir("/ws", "../escape", "s")).toThrow(KeyLayoutError);
    expect(() => workspaceDir("/ws", 200001, "a/b")).toThrow(KeyLayoutError);
    expect(() => workspaceDir("/ws", 200001, "")).toThrow(KeyLayoutError);
  });

  it("sessionWorkspacePath is the same function (ledger alias)", () => {
    expect(sessionWorkspacePath).toBe(workspaceDir);
  });
});

describe("workspaceDir — equality with @ovid/sandbox's landed seam (contract 1)", () => {
  it("equals SandboxManager.workspaceDir(userId, sessionId) for the same inputs", async () => {
    const wsRoot = mkdtempSync(join(tmpdir(), "ovid-wsp-ws-"));
    roots.push(wsRoot);
    const manager = await freshManager(wsRoot);
    const sandboxPath = await manager.workspaceDir("u1", "sess-1");
    const helperPath = workspaceDir(wsRoot, FIXED_UID, "sess-1");
    expect(sandboxPath).toBe(join(wsRoot, "200001", "sessions", "sess-1"));
    expect(helperPath).toBe(sandboxPath);
    // the seam mkdir -p's the dir; our pure helper only names it
    expect(existsSync(sandboxPath)).toBe(true);
  });

  it("two sessionIds are siblings under the same uid", async () => {
    const wsRoot = mkdtempSync(join(tmpdir(), "ovid-wsp-ws-"));
    roots.push(wsRoot);
    const manager = await freshManager(wsRoot);
    const p1 = await manager.workspaceDir("u1", "s-a");
    const p2 = await manager.workspaceDir("u1", "s-b");
    expect(workspaceDir(wsRoot, FIXED_UID, "s-a")).toBe(p1);
    expect(workspaceDir(wsRoot, FIXED_UID, "s-b")).toBe(p2);
    expect(join(p1, "..")).toBe(join(p2, ".."));
  });
});
