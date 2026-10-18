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
import { DEFAULT_SANDBOX_LIMITS, loadSandboxConfig, type SandboxConfig } from "./config.js";
import { renderEtcBundle, renderHomeDotfiles, writeEnvFiles } from "./etcFiles.js";
import { execOnce, makeJailContext } from "./exec.js";
import { hostTestsAvailable, jailMechanismAvailable } from "./hostGate.js";
import { createSetuidLauncher } from "./launcher.js";
import { resolveRootfs } from "./rootfs.js";
import type { JailContext } from "./types.js";

/**
 * HOST-GATED per-user cache proofs (Task 10 Step 5): real bwrap jails through
 * the real `sandbox-enter.sh` launcher, reproducing research §5 per-user —
 * pnpm installs are hardlinks out of /root/.cache/pnpm-store, uv the same
 * out of /root/.cache/uv, and a warm store makes installs fast.
 *
 * Gated exactly like Task 7's exec host suite (OVID_SANDBOX_HOST_TESTS=1 +
 * root + jailMechanismAvailable) — bwrap is NOT installed until the
 * owner-gated Task-1 probe runs, so this suite skips on this box until then.
 *
 * Network egress: the FIRST install per store needs registry access — the
 * sandbox uid is not yet nft-filtered in test context (Task 11), and
 * registry access is allowed traffic anyway.
 *
 * Layout mirrors the manager (Task 8): {workspacesRoot}/{uid}/.home is the
 * jail's /root, so the stores land at {uid}/.home/.cache/… on the host —
 * the same `.cache` project-quota subtree as the workspace.
 */

const UID = 200099;
const CG_ROOT = "/sys/fs/cgroup";
const BASE = `ovid-probe-caches-${process.pid}`;

const cfg: SandboxConfig = {
  ...loadSandboxConfig({}),
  // Task 3 scratch extract (owner-run of Step 6 sets OVID_ROOTFS explicitly).
  rootfsPath: process.env.OVID_ROOTFS ?? "/tmp/ovid-rootfs-test",
  cgroupRoot: CG_ROOT,
  cgroupBase: BASE,
  launch: "setuid",
};

const mgr: CgroupManager = createCgroupManager({ cgroupRoot: CG_ROOT, cgroupBase: BASE });

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

describe.skipIf(!hostTestsAvailable() || !jailMechanismAvailable(cfg))(
  "per-user caches — real bwrap jails (host-gated)",
  () => {
    let ctx: JailContext;
    let workspacesRoot: string;
    let userRoot: string;
    let workspaceDir: string;
    let homeDir: string;
    let etcDir: string;
    const scratchDirs: string[] = [];
    /** Timings surfaced to the owner via the task report (100 ms is the target,
     *  2 s the enforced sanity gate — see (c)). */
    const timings: Record<string, number> = {};

    beforeAll(async () => {
      const rootfs = (await resolveRootfs(cfg.rootfsPath)).path;

      // Manager-mirroring layout: {ws}/{uid}/.home is the jail's /root, so
      // the per-user stores land under {uid}/.home/.cache/ on the host (e).
      workspacesRoot = mkdtempSync(join(tmpdir(), "ovid-caches-ws-"));
      scratchDirs.push(workspacesRoot);
      userRoot = join(workspacesRoot, String(UID));
      workspaceDir = join(userRoot, "sessions", "probe");
      // The launcher spawns with cwd=workspaceDir — must exist (Task 7 I-1).
      mkdirSync(workspaceDir, { recursive: true });
      homeDir = join(userRoot, ".home");
      etcDir = mkdtempSync(join(tmpdir(), "ovid-caches-etc-"));
      scratchDirs.push(etcDir);
      await writeEnvFiles({
        etcDir,
        homeDir,
        bundle: renderEtcBundle({ dns: cfg.sandboxDns }),
        dotfiles: renderHomeDotfiles(),
        ownerUid: UID,
      });

      await mgr.init();
      // init() parked this process in the probe base's worker leaf; move it
      // back out so the vitest tree does not live in the throwaway cgroup.
      moveSelfTo(ORIGINAL_CGROUP);
      // Installs spawn node + package-manager children: 256 MB / 64 pids.
      await mgr.createEnv(UID, {
        ...DEFAULT_SANDBOX_LIMITS,
        memoryMaxBytes: 256 * 1024 * 1024,
        pidsMax: 64,
      });

      ctx = makeJailContext({
        config: cfg,
        cgroups: mgr,
        launcher: createSetuidLauncher(cfg),
        uid: UID,
        rootfs,
        workspaceDir,
        homeDir,
        etcDir,
      });
    }, 240_000);

    afterAll(async () => {
      const problems: string[] = [];
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
      const tmpLeftovers = readdirSync(tmpdir()).filter((e) => e.startsWith("ovid-caches-"));
      if (tmpLeftovers.length > 0) {
        problems.push(`leftover scratch dirs: ${tmpLeftovers.join(", ")}`);
      }
      if (problems.length > 0) {
        throw new Error(`caches host-test cleanup failed:\n- ${problems.join("\n- ")}`);
      }
    });

    it("(a) `pnpm store path` → the per-user store /root/.cache/pnpm-store", async () => {
      const res = await execOnce(ctx, { command: "pnpm store path", timeoutMs: 60_000 });
      expect(res.blocked).toBe(false);
      expect(res.exitCode).toBe(0);
      expect(res.stdout.trim()).toBe("/root/.cache/pnpm-store");
    }, 90_000);

    it("(b) hardlink proof — is-number installed from /workspace links ≥ 2 with the same inode in the store", async () => {
      const init = await execOnce(ctx, {
        command: "npm init -y && pnpm add is-number",
        timeoutMs: 300_000,
      });
      expect(init.blocked).toBe(false);
      expect(init.exitCode).toBe(0);

      const stat = await execOnce(ctx, {
        command: "stat -c '%h %i' node_modules/is-number/index.js",
        timeoutMs: 30_000,
      });
      expect(stat.exitCode).toBe(0);
      const [links, inode] = stat.stdout.trim().split(/\s+/).map(Number);
      // research §5 reproduced per-user: the installed file is a hardlink.
      expect(links).toBeGreaterThanOrEqual(2);

      // …and the OTHER link lives inside the per-user pnpm store.
      const find = await execOnce(ctx, {
        command: `find /root/.cache/pnpm-store -inum ${inode}`,
        timeoutMs: 60_000,
      });
      expect(find.exitCode).toBe(0);
      expect(find.stdout.trim()).not.toBe("");
      timings.bFirstInstallHardlinks = links;
    }, 420_000);

    it("(c) fast path — second project, warm store, --prefer-offline < 2 s (target 100 ms)", async () => {
      const t0 = Date.now();
      const res = await execOnce(ctx, {
        command:
          "mkdir -p /workspace/p2 && cd /workspace/p2 && npm init -y && pnpm add is-number --prefer-offline",
        timeoutMs: 300_000,
      });
      const elapsed = Date.now() - t0;
      expect(res.blocked).toBe(false);
      expect(res.exitCode).toBe(0);
      // Hard sanity gate: a warm-store install must not take seconds. The
      // <100 ms TARGET is recorded, never enforced (first-bash-script +
      // npm init are in this wall time too — the owner reads the numbers).
      expect(elapsed).toBeLessThan(2_000);
      timings.cWarmStorePreferOfflineMs = elapsed;

      // The number recorded for the owner: a warm-store no-op re-run through
      // the dispatcher itself (`ovid install is-number` in the finished p2).
      const t1 = Date.now();
      const rerun = await execOnce(ctx, {
        command: "cd /workspace/p2 && ovid install is-number",
        timeoutMs: 300_000,
      });
      const rerunMs = Date.now() - t1;
      expect(rerun.blocked).toBe(false);
      expect(rerun.exitCode).toBe(0);
      timings.cWarmStoreNoopOvidInstallMs = rerunMs;

      console.info(
        `[task-10 timings] warm-store --prefer-offline: ${elapsed} ms; ` +
          `warm-store no-op \`ovid install is-number\`: ${rerunMs} ms (target < 100 ms, gate < 2000 ms)`,
      );
    }, 660_000);

    it("(d) uv — six hardlinked out of /root/.cache/uv, no cross-device warning", async () => {
      const res = await execOnce(ctx, {
        command:
          "mkdir -p /workspace/py && cd /workspace/py && uv venv && uv pip install six",
        timeoutMs: 300_000,
      });
      expect(res.blocked).toBe(false);
      expect(res.exitCode).toBe(0);
      // UV_LINK_MODE=hardlink + same filesystem: no fallback-to-copy warning.
      expect(res.stderr).not.toMatch(/cross-device|fall(?:ing|s?) back to copy|Failed to hardlink/i);

      const stat = await execOnce(ctx, {
        command: "stat -c '%h' .venv/lib/python3*/site-packages/six.py",
        // Run from the py project dir (cwd option, jail-relative).
        cwd: "/workspace/py",
        timeoutMs: 30_000,
      });
      expect(stat.exitCode).toBe(0);
      const links = Number(stat.stdout.trim().split(/\s+/)[0]);
      expect(links).toBeGreaterThanOrEqual(2);
      timings.dUvSixHardlinks = links;
    }, 420_000);

    it("(e) host side — stores live under {uid}/.home/.cache, owned by the sandbox uid", async () => {
      const pnpmStore = join(userRoot, ".home", ".cache", "pnpm-store");
      const uvCache = join(userRoot, ".home", ".cache", "uv");
      expect(existsSync(pnpmStore)).toBe(true);
      expect(existsSync(uvCache)).toBe(true);
      // Jail root maps to host uid 200099: every store file it wrote is owned
      // by the sandbox uid, not by the test runner's root.
      expect(statSync(pnpmStore).uid).toBe(UID);
      expect(statSync(uvCache).uid).toBe(UID);
    });
  },
);
