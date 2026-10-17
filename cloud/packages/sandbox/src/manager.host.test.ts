import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  rmdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createCgroupManager, type CgroupManager } from "./cgroups.js";
import { loadSandboxConfig, type SandboxConfig } from "./config.js";
import { hostTestsAvailable, jailMechanismAvailable } from "./hostGate.js";
import {
  createSandboxManager,
  type SandboxHandle,
  type SandboxManager,
} from "./manager.js";
import { createSetuidLauncher } from "./launcher.js";
import { createNoopQuotaBackend } from "./quota.js";
import { resolveRootfs } from "./rootfs.js";

/**
 * HOST-GATED SandboxManager proofs (Task 8 Step 5): the full manager lifecycle
 * — attach (dir layout + ownership), handle.exec through a real bwrap jail,
 * destroy (cgroup gone, no uid processes left, data persists) — against the
 * REAL /sys/fs/cgroup and the real sandbox-enter.sh launcher.
 *
 * Gated exactly like Task 7's exec host suite: OVID_SANDBOX_HOST_TESTS=1 +
 * root + a working bwrap mechanism (jailMechanismAvailable — bwrap is NOT
 * installed until the owner-gated Task-1 probe runs, so this suite skips on
 * this box until then).
 *
 * Scope guard (plan Global Constraints): throwaway `ovid-probe-mgr-{pid}`
 * cgroup base + mkdtemp workspaces root only, full cleanup in afterAll with
 * an explicit no-leftovers assertion. Production cgroup paths are untouched.
 */

const UID = 200098;
const CG_ROOT = "/sys/fs/cgroup";
const BASE = `ovid-probe-mgr-${process.pid}`;

const cfg: SandboxConfig = {
  ...loadSandboxConfig({}),
  // Task 3 scratch extract (owner-run of Step 6 sets OVID_ROOTFS explicitly).
  rootfsPath: process.env.OVID_ROOTFS ?? "/tmp/ovid-rootfs-test",
  cgroupRoot: CG_ROOT,
  cgroupBase: BASE,
  launch: "setuid",
};

const rawMgr: CgroupManager = createCgroupManager({ cgroupRoot: CG_ROOT, cgroupBase: BASE });

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

function readProcSelfCgroup(): string {
  const line = readFileSync("/proc/self/cgroup", "utf8")
    .trim()
    .split("\n")
    .find((l) => l.startsWith("0::"));
  if (!line) throw new Error("not a cgroups v2 host: no 0:: line in /proc/self/cgroup");
  return line.slice(3);
}
const ORIGINAL_CGROUP = readProcSelfCgroup();

function moveSelfTo(cgroupPath: string): void {
  writeFileSync(join(CG_ROOT, cgroupPath, "cgroup.procs"), String(process.pid));
}

/** Host processes whose REAL uid is `uid` (scan /proc/<pid>/status). */
function scanForUid(uid: number): number {
  let n = 0;
  for (const entry of readdirSync("/proc")) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const status = readFileSync(join("/proc", entry, "status"), "utf8");
      const m = status.match(/^Uid:\s+(\d+)/m);
      if (m !== null && Number(m[1]) === uid) n++;
    } catch {
      /* process gone between readdir and read */
    }
  }
  return n;
}

async function untilZero(fn: () => number, ms: number): Promise<number> {
  const deadline = Date.now() + ms;
  let v = fn();
  while (v !== 0 && Date.now() < deadline) {
    await sleep(100);
    v = fn();
  }
  return v;
}

function readProcs(cgroupPath: string): number[] {
  try {
    return readFileSync(join(cgroupPath, "cgroup.procs"), "utf8")
      .trim()
      .split("\n")
      .filter(Boolean)
      .map(Number);
  } catch {
    return []; // cgroup gone
  }
}

/** Depth-first kill+remove of the probe cgroup subtree (cgroupfs: rmdir only). */
async function removeCgroupTree(path: string): Promise<void> {
  if (!existsSync(path)) return;
  for (const e of readdirSync(path, { withFileTypes: true })) {
    if (e.isDirectory()) await removeCgroupTree(join(path, e.name));
  }
  if (!readProcs(path).includes(process.pid)) {
    try {
      writeFileSync(join(path, "cgroup.kill"), "1");
    } catch {
      /* not a cgroup / already gone */
    }
  }
  for (let i = 0; i < 100; i++) {
    const pids = readProcs(path);
    if (pids.length === 0) break;
    for (const p of pids) {
      if (p === process.pid) continue;
      try {
        process.kill(p, "SIGKILL");
      } catch {
        /* already gone */
      }
    }
    await sleep(50);
  }
  rmdirSync(path);
}

/** Every dir and file under `root` (incl. root itself) is owned by `uid`. */
function assertOwnedTree(root: string, uid: number): void {
  expect(statSync(root).uid, `${root} owner`).toBe(uid);
  for (const e of readdirSync(root, { withFileTypes: true })) {
    const p = join(root, e.name);
    if (e.isDirectory()) assertOwnedTree(p, uid);
    else expect(statSync(p).uid, `${p} owner`).toBe(uid);
  }
}

describe.skipIf(!hostTestsAvailable() || !jailMechanismAvailable(cfg))(
  "SandboxManager — real jails (host-gated)",
  () => {
    let manager: SandboxManager;
    let handle: SandboxHandle;
    let wsRoot: string;
    const scratchDirs: string[] = [];

    beforeAll(async () => {
      wsRoot = mkdtempSync(join(tmpdir(), "ovid-mgr-host-ws-"));
      scratchDirs.push(wsRoot);

      await rawMgr.init();
      // init() parked this process in the probe base's worker leaf; move it
      // back out so the vitest tree does not live in the throwaway cgroup.
      moveSelfTo(ORIGINAL_CGROUP);

      manager = createSandboxManager({
        config: { ...cfg, workspacesRoot: wsRoot },
        // Stub allocator: the manager treats it as the idempotent prod seam.
        allocateUid: async () => UID,
        cgroups: rawMgr,
        // Noop-safe quota (this host's / is ext4 — no XFS prjquota volume
        // until the Task 16 activation).
        quota: createNoopQuotaBackend(),
        launcher: createSetuidLauncher(cfg),
        rootfs: await resolveRootfs(cfg.rootfsPath),
        // diskUsage default: real statfs + du of the (tiny) scratch tree.
      });
    });

    afterAll(async () => {
      const problems: string[] = [];
      try {
        await manager.close(); // no-op when every handle was already destroyed
      } catch (e) {
        problems.push(`manager.close(): ${String(e)}`);
      }
      try {
        moveSelfTo(ORIGINAL_CGROUP);
      } catch (e) {
        problems.push(`restore placement: ${String(e)}`);
      }
      try {
        await removeCgroupTree(join(CG_ROOT, BASE));
      } catch (e) {
        problems.push(`cleanup ${BASE}: ${String(e)}`);
      }
      // Defensive sweep: nothing named ovid-probe-* may remain at the root.
      for (const entry of readdirSync(CG_ROOT)) {
        if (!entry.startsWith("ovid-probe-")) continue;
        try {
          await removeCgroupTree(join(CG_ROOT, entry));
        } catch (e) {
          problems.push(`sweep ${entry}: ${String(e)}`);
        }
      }
      const leftovers = readdirSync(CG_ROOT).filter((e) => e.startsWith("ovid-probe-"));
      if (leftovers.length > 0) problems.push(`leftover probe cgroups: ${leftovers.join(", ")}`);

      for (const dir of scratchDirs) {
        try {
          rmSync(dir, { recursive: true, force: true });
        } catch (e) {
          problems.push(`rm ${dir}: ${String(e)}`);
        }
      }
      const tmpLeftovers = readdirSync(tmpdir()).filter((e) =>
        e.startsWith("ovid-mgr-host-"),
      );
      if (tmpLeftovers.length > 0) {
        problems.push(`leftover scratch dirs: ${tmpLeftovers.join(", ")}`);
      }
      if (problems.length > 0) {
        throw new Error(`manager host-test cleanup failed:\n- ${problems.join("\n- ")}`);
      }
    });

    it("(a) attach — the exact layout, every created dir/file owned by uid 200098", async () => {
      handle = await manager.attach("host-user");
      expect(handle.uid).toBe(UID);
      expect(handle.workspaceDir).toBe(join(wsRoot, String(UID), "workspace"));
      expect(handle.homeDir).toBe(join(wsRoot, String(UID), ".home"));
      expect(handle.jailWorkspaceDir).toBe("/workspace");
      // all five subdirs
      const userRoot = join(wsRoot, String(UID));
      for (const d of [
        "workspace",
        ".home",
        ".home/.cache/pnpm-store",
        ".home/.cache/uv",
        "etc",
      ]) {
        expect(existsSync(join(userRoot, d)), `missing ${d}`).toBe(true);
      }
      // every created dir AND file (etc bundle, .npmrc) lands on the uid
      assertOwnedTree(userRoot, UID);
      expect(manager.activeCount()).toBe(1);
      expect(manager.list()).toEqual([
        { userId: "host-user", uid: UID, createdAt: expect.any(String) },
      ]);
    });

    it("(b) exec — id -u is 0 INSIDE while host files land as 200098", async () => {
      const id = await handle.exec({ command: "id -u" });
      expect(id.exitCode).toBe(0);
      expect(id.stdout.trim()).toBe("0"); // root in the user-mapped jail
      const touch = await handle.exec({ command: "touch /workspace/owned.txt" });
      expect(touch.exitCode).toBe(0);
      expect(touch.blocked).toBe(false);
      expect(statSync(join(handle.workspaceDir, "owned.txt")).uid).toBe(UID);
    });

    it("(c) destroy — env cgroup gone, zero uid-200098 processes, data persists", async () => {
      writeFileSync(join(handle.workspaceDir, "persist.txt"), "kept");
      await manager.destroy("host-user");
      expect(existsSync(join(CG_ROOT, BASE, `sandbox-${UID}`))).toBe(false);
      expect(await untilZero(() => scanForUid(UID), 5_000)).toBe(0);
      expect(manager.activeCount()).toBe(0);
      expect(manager.get("host-user")).toBeUndefined();
      expect(manager.list()).toEqual([]);
      // workspace DATA persists (purge is P9 account deletion)
      expect(readFileSync(join(wsRoot, String(UID), "workspace", "persist.txt"), "utf8")).toBe(
        "kept",
      );
    });
  },
);
