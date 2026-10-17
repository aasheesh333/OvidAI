import { mkdir, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";

import { createSandboxManagerEviction } from "./sandboxEviction.js";
import { workspaceDir } from "./workspacePaths.js";

const roots: string[] = [];
afterAll(async () => {
  for (const r of roots) await rm(r, { recursive: true, force: true });
});

async function freshRoot(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "ovid-evict-"));
  roots.push(root);
  return root;
}

async function seedWorkspace(root: string, uid: number, files: string[]): Promise<string> {
  const dir = workspaceDir(root, uid, "ignored");
  await mkdir(dir, { recursive: true });
  for (const f of files) {
    await writeFile(join(dir, f), f);
  }
  return dir;
}

describe("createSandboxManagerEviction (P2-backed, authoritative)", () => {
  it("enumerates EVERY warm directory on disk, not only attached handles", async () => {
    const root = await freshRoot();
    await seedWorkspace(root, 200_001, ["a.txt", "b.txt"]);
    await seedWorkspace(root, 200_002, ["c.txt"]);
    // 200_003 has known sessions but no workspace dir on disk.

    const eviction = createSandboxManagerEviction({
      workspacesRoot: root,
      manager: { destroy: async () => {} },
      listKnownSessions: async () => [
        { userId: "firebase-a", uid: 200_001, sessionId: "s-a1" },
        { userId: "firebase-a", uid: 200_001, sessionId: "s-a2" },
        { userId: "firebase-b", uid: 200_002, sessionId: "s-b1" },
        { userId: "firebase-c", uid: 200_003, sessionId: "s-c1" },
      ],
    });

    expect(eviction.authoritative).toBe(true);
    const entries = await eviction.listWarmWorkspaces();

    // Per-user workspace: every session of a warm user is listed, and the
    // uid-200_003 user (no dir) is absent.
    expect(entries.map((e) => e.sessionId).sort()).toEqual(["s-a1", "s-a2", "s-b1"]);
    const a = entries.find((e) => e.sessionId === "s-a1")!;
    expect(a.userId).toBe("firebase-a");
    expect(a.bytes).toBeGreaterThan(0);
    // Sessions sharing the per-user tree report the same size.
    expect(entries.find((e) => e.sessionId === "s-a2")!.bytes).toBe(a.bytes);
  });

  it("ignores non-numeric/zero uids and a missing workspace root", async () => {
    const root = await freshRoot();
    const eviction = createSandboxManagerEviction({
      workspacesRoot: join(root, "does-not-exist"),
      manager: { destroy: async () => {} },
      listKnownSessions: async () => [
        { userId: "bad", uid: "not-a-uid", sessionId: "s1" },
        { userId: "zero", uid: 0, sessionId: "s2" },
      ],
    });
    await expect(eviction.listWarmWorkspaces()).resolves.toEqual([]);
  });

  it("evictWorkspace destroys P2's env (leaves the files to the engine)", async () => {
    const root = await freshRoot();
    const dir = await seedWorkspace(root, 200_001, ["keep.txt"]);
    const destroyed: string[] = [];
    const eviction = createSandboxManagerEviction({
      workspacesRoot: root,
      manager: {
        destroy: async (userId) => {
          destroyed.push(userId);
        },
      },
      listKnownSessions: async () => [],
    });

    await eviction.evictWorkspace("firebase-a", "s1");
    expect(destroyed).toEqual(["firebase-a"]);
    // The pack-safe contract: destroy never removes workspace data.
    await expect(stat(dir)).resolves.toBeTruthy();
  });
});
