import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
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

import {
  resolveWorkspaceDir,
  sessionWorkspacePath,
  workspaceDir,
  type SandboxUidResolver,
} from "./workspacePaths.js";
import { KeyLayoutError } from "./errors.js";

/**
 * Contract 1 (fix round 1, C1): P7's directory must be the directory the agent
 * actually runs in — P2's `SandboxHandle.workspaceDir`
 * (`{workspacesRoot}/{numericUid}/workspace`, manager.ts:308-309) — resolved
 * from the SAME numeric uid `SandboxManager` allocates. The previous version
 * of this suite passed a fixed uid to the helper and `"u1"` to the manager, so
 * it proved only that two independently chosen numbers produced the same
 * shape. This suite drives the REAL manager to learn its uid, feeds that uid
 * through the resolver, and asserts byte equality against the agent path.
 *
 * The manager's `workspaceDir(userId, sessionId)` seam creates the SIBLING
 * `{root}/{uid}/sessions/{sid}` (P6 browser artifacts); it is deliberately
 * not P7's target (see workspacePaths.ts).
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

/** The uid P2 allocated, read back from its own session-dir seam. */
function uidFromSessionDir(sessionDir: string): number {
  // {root}/{uid}/sessions/{sid}
  return Number(basename(dirname(dirname(sessionDir))));
}

describe("workspaceDir — P2's agent workspace", () => {
  it("is {root}/{numericUid}/workspace — no session segment", () => {
    expect(workspaceDir("/workspaces/users", 200001, "sess-1")).toBe(
      join("/workspaces/users", "200001", "workspace"),
    );
  });

  it("accepts the uid as a string too", () => {
    expect(workspaceDir("/ws", "200001", "s")).toBe(join("/ws", "200001", "workspace"));
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

describe("resolveWorkspaceDir — equality with P2's landed identity (contract 1)", () => {
  it("resolves the SAME numeric uid the manager allocates and equals the agent cwd", async () => {
    const wsRoot = mkdtempSync(join(tmpdir(), "ovid-wsp-ws-"));
    roots.push(wsRoot);
    const manager = await freshManager(wsRoot);

    // P2's session seam creates {root}/{uid}/sessions/{sid}; read the uid it
    // actually allocated from that path.
    const sessionDir = await manager.workspaceDir("u1", "sess-1");
    const p2Uid = uidFromSessionDir(sessionDir);
    expect(p2Uid).toBe(FIXED_UID);

    let seenUserId: string | null = null;
    const resolver: SandboxUidResolver = async (userId) => {
      seenUserId = userId;
      return p2Uid;
    };

    const helperPath = await resolveWorkspaceDir(resolver, wsRoot, "u1", "sess-1");
    expect(seenUserId).toBe("u1");

    // Byte-for-byte P2's SandboxHandle.workspaceDir (manager.ts:308-309).
    expect(helperPath).toBe(join(wsRoot, String(FIXED_UID), "workspace"));
    // And the sibling relationship to P2's session seam is exact: the agent
    // workspace lives beside `sessions/`, under the same numeric uid.
    expect(helperPath).toBe(join(dirname(dirname(sessionDir)), "workspace"));
    expect(existsSync(sessionDir)).toBe(true);
  });

  it("two sessions of one user resolve to the SAME per-user agent workspace", async () => {
    const wsRoot = mkdtempSync(join(tmpdir(), "ovid-wsp-ws-"));
    roots.push(wsRoot);
    const manager = await freshManager(wsRoot);
    const resolver: SandboxUidResolver = async () => FIXED_UID;

    const p1 = await manager.workspaceDir("u1", "s-a");
    const p2 = await manager.workspaceDir("u1", "s-b");
    const a = await resolveWorkspaceDir(resolver, wsRoot, "u1", "s-a");
    const b = await resolveWorkspaceDir(resolver, wsRoot, "u1", "s-b");

    // P2's session trees are siblings...
    expect(dirname(p1)).toBe(dirname(p2));
    // ...but the agent workspace is per-user, so P7 targets the same dir.
    expect(a).toBe(b);
    expect(a).toBe(join(dirname(dirname(p1)), "workspace"));
  });
});
