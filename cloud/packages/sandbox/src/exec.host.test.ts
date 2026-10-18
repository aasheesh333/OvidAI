import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
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
import { buildBwrapArgs, type JailSpec } from "./invocation.js";
import { createSetuidLauncher } from "./launcher.js";
import { REFUSAL_MESSAGE } from "./policy.js";
import { resolveRootfs } from "./rootfs.js";
import type { JailContext } from "./types.js";

/**
 * HOST-GATED exec API proofs (Task 7 Step 5): real bwrap jails through the
 * real `sandbox-enter.sh` launcher, against the REAL /sys/fs/cgroup.
 *
 * Gated on OVID_SANDBOX_HOST_TESTS=1 + root + a working bwrap mechanism
 * (jailMechanismAvailable — bwrap is NOT installed until the owner-gated
 * Task-1 probe runs, so this suite skips on this box until then).
 *
 * Scope guard (plan Global Constraints): throwaway `ovid-probe-exec-{pid}`
 * cgroup base + mkdtemp scratch only, full cleanup in afterAll, explicit
 * no-leftovers assertion. Production cgroup paths are never touched.
 */

const UID = 200099;
const CG_ROOT = "/sys/fs/cgroup";
const BASE = `ovid-probe-exec-${process.pid}`;

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

function scanForMarker(marker: string): number {
  let n = 0;
  for (const entry of readdirSync("/proc")) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      if (readFileSync(join("/proc", entry, "cmdline"), "utf8").includes(marker)) n++;
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

async function untilAtLeast(fn: () => number, target: number, ms: number): Promise<number> {
  const deadline = Date.now() + ms;
  let v = fn();
  while (v < target && Date.now() < deadline) {
    await sleep(50);
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

/**
 * die-with-parent fixture (g): a plain node child that spawns the jail via
 * the sandbox-enter.sh launcher contract (NUL-separated argv file →
 * bash sandbox-enter.sh <procs> <uid> <gid> <argvfile>). Kept dependency-free
 * on purpose — the child must not import the (possibly stale) dist build.
 */
// The argv file is NUL-separated with a trailing NUL — exactly the format
// sandbox-enter.sh's `read -r -d ''` loop consumes (fix-round M-2).
const DWP_SCRIPT = `
const { spawn } = require("node:child_process");
const { mkdtempSync, writeFileSync, rmSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const spec = JSON.parse(process.env.OVID_DWP_SPEC);
const scratch = mkdtempSync(join(tmpdir(), "ovid-dwp-"));
const argvFile = join(scratch, "argv");
writeFileSync(argvFile, spec.bwrapArgv.join("\\0") + "\\0", { mode: 0o600 });
const child = spawn("bash", [spec.launcherPath, spec.procsFile, String(spec.uid), String(spec.gid), argvFile], { cwd: spec.cwd, stdio: ["ignore", "pipe", "pipe"] });
child.stdout.resume();
child.stderr.resume();
child.on("exit", () => { try { rmSync(scratch, { recursive: true, force: true }); } catch {} });
setInterval(() => {}, 1 << 30); // stay alive while the jail runs
`;

/** Single-quote a shell word. */
function shSingle(s: string): string {
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

describe.skipIf(!hostTestsAvailable() || !jailMechanismAvailable(cfg))(
  "exec API — real bwrap jails (host-gated)",
  () => {
    let ctx: JailContext;
    let workspaceDir: string;
    let homeDir: string;
    let etcDir: string;
    let rootfs: string;
    const scratchDirs: string[] = [];

    beforeAll(async () => {
      rootfs = (await resolveRootfs(cfg.rootfsPath)).path;

      const workspacesRoot = mkdtempSync(join(tmpdir(), "ovid-exec-ws-"));
      scratchDirs.push(workspacesRoot);
      workspaceDir = join(workspacesRoot, String(UID), "sessions", "probe");
      // The launcher spawns with cwd=workspaceDir: node spawn against a
      // nonexistent cwd emits an async ENOENT with NO exit event, which would
      // wedge every spawning test. The dir must exist (fix-round I-1).
      mkdirSync(workspaceDir, { recursive: true });
      homeDir = mkdtempSync(join(tmpdir(), "ovid-exec-home-"));
      etcDir = mkdtempSync(join(tmpdir(), "ovid-exec-etc-"));
      scratchDirs.push(homeDir, etcDir);
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
      // 64 MB env cap for (i); every other probe payload is far below it.
      await mgr.createEnv(UID, {
        ...DEFAULT_SANDBOX_LIMITS,
        memoryMaxBytes: 64 * 1024 * 1024,
        pidsMax: 32,
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
    });

    afterAll(async () => {
      const problems: string[] = [];
      try {
        moveSelfTo(ORIGINAL_CGROUP);
      } catch (e) {
        problems.push(`restore placement: ${String(e)}`);
      }
      // Drain any leaf a failed test left behind, then the env, worker leaf
      // and base — depth-first kill+remove.
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
      // dwp scratch dirs are owned by the (killed) node children — sweep.
      for (const entry of readdirSync(tmpdir())) {
        if (!entry.startsWith("ovid-dwp-")) continue;
        try {
          rmSync(join(tmpdir(), entry), { recursive: true, force: true });
        } catch {
          /* best effort */
        }
      }
      const tmpLeftovers = readdirSync(tmpdir()).filter(
        (e) => e.startsWith("ovid-exec-") || e.startsWith("ovid-dwp-"),
      );
      if (tmpLeftovers.length > 0) {
        problems.push(`leftover scratch dirs: ${tmpLeftovers.join(", ")}`);
      }
      if (problems.length > 0) {
        throw new Error(`exec host-test cleanup failed:\n- ${problems.join("\n- ")}`);
      }
    });

    it("(a) echo hello — exit 0, stdout captured through the launcher", async () => {
      const res = await execOnce(ctx, { command: "echo hello" });
      expect(res.blocked).toBe(false);
      expect(res.exitCode).toBe(0);
      expect(res.stdout).toBe("hello\n");
      expect(res.stderr).toBe("");
    });

    it("(b) uid map — (0, 200099, 1) and id -u → 0 inside the jail", async () => {
      const res = await execOnce(ctx, { command: "cat /proc/self/uid_map" });
      expect(res.exitCode).toBe(0);
      expect(res.stdout.trim().split(/\s+/).map(Number)).toEqual([0, UID, 1]);
      const id = await execOnce(ctx, { command: "id -u" });
      expect(id.exitCode).toBe(0);
      expect(id.stdout.trim()).toBe("0");
    });

    it("(c) host ownership — jail writes land as uid 200099 on the host", async () => {
      const res = await execOnce(ctx, { command: "touch /workspace/owned.txt" });
      expect(res.exitCode).toBe(0);
      expect(statSync(join(workspaceDir, "owned.txt")).uid).toBe(UID);
    });

    it("(d) RO root — /etc and /usr/bin writes fail read-only", async () => {
      const etc = await execOnce(ctx, { command: "sh -c 'echo x > /etc/pwn'" });
      expect(etc.exitCode).not.toBe(0);
      expect(etc.stderr).toMatch(/read-only/i);
      expect(existsSync("/etc/pwn")).toBe(false);
      const usr = await execOnce(ctx, { command: "touch /usr/bin/x" });
      expect(usr.exitCode).not.toBe(0);
      expect(usr.stderr).toMatch(/read-only/i);
    });

    it("(e) host invisibility — no /workspaces, no host /tmp or /opt content", async () => {
      const ws = await execOnce(ctx, { command: "ls /workspaces" });
      expect(ws.exitCode).not.toBe(0);
      expect(ws.stderr).toMatch(/No such file/i);
      // The jail's /tmp is a fresh tmpfs: the host scratch extract (which
      // definitely exists — it is the jail's own rootfs source) is invisible.
      const scratch = await execOnce(ctx, { command: "ls /tmp/ovid-rootfs-test" });
      expect(scratch.exitCode).not.toBe(0);
      expect(scratch.stderr).toMatch(/No such file/i);
      // Deviation from the brief's literal "ls /opt → ENOENT", recorded in
      // task-7-report.md: the built noble rootfs SHIPS an (empty) /opt, so
      // the invisibility proof is that no HOST /opt content leaks into it.
      const opt = await execOnce(ctx, { command: "ls /opt" });
      if (opt.exitCode === 0) {
        expect(opt.stdout.trim()).toBe("");
      } else {
        expect(opt.stderr).toMatch(/No such file/i);
      }
    });

    it("(f) pid isolation — own pid namespace, sandbox-200099 cgroup", async () => {
      const cg = await execOnce(ctx, { command: "cat /proc/self/cgroup" });
      expect(cg.exitCode).toBe(0);
      expect(cg.stdout).toContain(`sandbox-${UID}`);
      const ps = await execOnce(ctx, { command: "ps -e" });
      expect(ps.exitCode).toBe(0);
      const pids = ps.stdout
        .trim()
        .split("\n")
        .slice(1) // header
        .map((line) => line.trim().split(/\s+/)[0])
        .filter((p) => /^\d+$/.test(p));
      expect(pids.length).toBeGreaterThan(0);
      expect(pids.length).toBeLessThanOrEqual(10); // a handful, not the host
      expect(pids).not.toContain(String(process.pid)); // not the test runner
    });

    it("(g) die-with-parent — killing the spawning node child reaps the jail", async () => {
      const rand = randomBytes(4).toString("hex");
      const marker = `sleep 300 dwp-${rand}`;
      const leaf = await mgr.createLeaf(UID, `exec-dwp-${rand}`);
      const spec: JailSpec = {
        rootfs,
        workspaceDir,
        homeDir,
        etcDir,
        // exec -a rewrites argv[0] so the sleeper is findable by marker in
        // host /proc/<pid>/cmdline.
        argv: ["bash", "-c", `exec -a ${shSingle(marker)} sleep 300`],
      };
      const nodeChild = spawn(process.execPath, ["-e", DWP_SCRIPT], {
        env: {
          ...process.env,
          OVID_DWP_SPEC: JSON.stringify({
            launcherPath: cfg.launcherPath,
            procsFile: mgr.procsFile(leaf),
            uid: UID,
            gid: UID,
            cwd: workspaceDir,
            bwrapArgv: buildBwrapArgs(spec, cfg),
          }),
        },
        stdio: ["ignore", "pipe", "pipe"],
      });
      try {
        // The jail is up once the marker process exists on the host.
        expect(await untilAtLeast(() => scanForMarker(marker), 1, 10_000)).toBeGreaterThanOrEqual(1);
        nodeChild.kill("SIGKILL");
        // bwrap --die-with-parent: the whole jail dies with the node child.
        expect(await untilZero(() => scanForMarker(marker), 2_000)).toBe(0);
      } finally {
        try {
          nodeChild.kill("SIGKILL");
        } catch {
          /* already gone */
        }
        await mgr.kill(leaf).catch(() => {});
      }
    });

    it("(h) blocked — layer 1 refuses with zero cgroup side effects", async () => {
      const before = await mgr.listChildren(mgr.envPath(UID));
      const res = await execOnce(ctx, { command: "make" });
      expect(res.blocked).toBe(true);
      expect(res.refusal).toBe(REFUSAL_MESSAGE);
      expect(res.exitCode).toBeNull();
      expect(res.stdout).toBe("");
      expect(await mgr.listChildren(mgr.envPath(UID))).toEqual(before);
    });

    it("(i) cgroup attribution + enforcement — 64 MB env OOM-kills the hog (exit 137)", async () => {
      const py = [
        "total = 0",
        "chunks = []",
        "while total < 128 * 1024 * 1024:",
        '    chunks.append(b"x" * (8 * 1024 * 1024))',
        "    total += 8 * 1024 * 1024",
        "import time",
        "time.sleep(300)",
      ].join("\n");
      // Double-bounded hog (Task 6 shape): allocation capped at 128 MB —
      // even with no enforcement it can never balloon the host.
      const res = await execOnce(ctx, {
        command: `python3 -c ${shSingle(py)}`,
        timeoutMs: 25_000,
      });
      expect(res.exitCode).toBe(137); // 128 + SIGKILL — the cgroup OOM killer
      const events = await mgr.readFile(mgr.envPath(UID), "memory.events");
      expect(parseInt(events.match(/^oom_kill (\d+)$/m)?.[1] ?? "0", 10)).toBeGreaterThanOrEqual(1);
    });
  },
);
