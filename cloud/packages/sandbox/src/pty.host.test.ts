import { randomBytes } from "node:crypto";
import { mkdir } from "node:fs/promises";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  rmdirSync,
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
import { createJobRegistry, spawnLongRunning, type JobRegistry, type SpawnedProcess } from "./jobs.js";
import { createSetuidLauncher } from "./launcher.js";
import { createPtySession, type PtySession } from "./pty.js";
import { REFUSAL_MESSAGE } from "./policy.js";
import { resolveRootfs } from "./rootfs.js";
import type { JailContext } from "./types.js";

/**
 * HOST-GATED PTY / job / spawn proofs (Task 9 Step 5): real node-pty terminals
 * through real bwrap jails via the real `sandbox-enter.sh` launcher, against
 * the REAL /sys/fs/cgroup. This suite also closes the research open item
 * "node-pty through bwrap --new-session".
 *
 * Gated exactly like Task 7's exec host suite: OVID_SANDBOX_HOST_TESTS=1 +
 * root + a working bwrap mechanism (jailMechanismAvailable — bwrap is NOT
 * installed until the owner-gated Task-1 probe runs, so this suite skips on
 * this box until then).
 *
 * Scope guard (plan Global Constraints): throwaway `ovid-probe-pty-{pid}`
 * cgroup base + mkdtemp scratch only, full cleanup in afterAll with an
 * explicit no-leftovers assertion (no jobmark-* processes, no probe
 * cgroups). Production cgroup paths are never touched.
 */

const UID = 200097;
/** Second env for the pids-max proof — its caps are overridden to pidsMax 16. */
const UID_PIDS = 200096;
const CG_ROOT = "/sys/fs/cgroup";
const BASE = `ovid-probe-pty-${process.pid}`;

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

/** Host processes whose /proc/<pid>/cmdline contains `marker`. */
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

describe.skipIf(!hostTestsAvailable() || !jailMechanismAvailable(cfg))(
  "PTY sessions / jobs / long-running spawn — real jails (host-gated)",
  () => {
    let ctx: JailContext;
    let ctxPids: JailContext;
    let jobs: JobRegistry;
    let jobsPids: JobRegistry;
    let workspaceDir: string;
    const ptys: PtySession[] = [];
    const procs: SpawnedProcess[] = [];
    const scratchDirs: string[] = [];

    /** Decoded text of a session's whole retained scrollback. */
    function ringText(session: PtySession): string {
      return session.ring
        .since(null)
        .chunks.map((c) => Buffer.from(c.data, "base64").toString("utf8"))
        .join("");
    }

    /** Polls `get()` until its text contains `needle` (or throws on timeout). */
    async function untilContains(get: () => string, needle: string, ms: number): Promise<void> {
      const deadline = Date.now() + ms;
      while (!get().includes(needle)) {
        if (Date.now() > deadline) {
          throw new Error(`timeout waiting for ${JSON.stringify(needle)} in: ${get().slice(-400)}`);
        }
        await sleep(50);
      }
    }

    beforeAll(async () => {
      const rootfs = (await resolveRootfs(cfg.rootfsPath)).path;

      const workspacesRoot = mkdtempSync(join(tmpdir(), "ovid-pty-ws-"));
      scratchDirs.push(workspacesRoot);
      workspaceDir = join(workspacesRoot, String(UID), "sessions", "probe");
      // The launcher spawns with cwd=workspaceDir: a nonexistent cwd wedges
      // every spawn with an async ENOENT (Task 7 fix-round I-1).
      mkdirSync(workspaceDir, { recursive: true });
      const homeDir = mkdtempSync(join(tmpdir(), "ovid-pty-home-"));
      const etcDir = mkdtempSync(join(tmpdir(), "ovid-pty-etc-"));
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
      await mgr.createEnv(UID, DEFAULT_SANDBOX_LIMITS);
      // The pids-cap env: limits overridden via the test config (pidsMax 16).
      await mgr.createEnv(UID_PIDS, { ...DEFAULT_SANDBOX_LIMITS, pidsMax: 16 });
      await mkdir(join(workspacesRoot, String(UID_PIDS), "sessions", "pids"), {
        recursive: true,
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
      ctxPids = makeJailContext({
        config: cfg,
        cgroups: mgr,
        launcher: createSetuidLauncher(cfg),
        uid: UID_PIDS,
        rootfs,
        workspaceDir: join(workspacesRoot, String(UID_PIDS), "sessions", "pids"),
        homeDir,
        etcDir,
      });
      jobs = createJobRegistry(ctx);
      jobsPids = createJobRegistry(ctxPids);
    });

    afterAll(async () => {
      const problems: string[] = [];
      // Kill every live leaf FIRST (the destroy contract, mirrored here).
      const kills: Promise<unknown>[] = [];
      for (const session of ptys) kills.push(session.kill().catch((e) => e));
      if (jobs !== undefined) kills.push(jobs.killAll().catch((e) => e));
      if (jobsPids !== undefined) kills.push(jobsPids.killAll().catch((e) => e));
      for (const proc of procs) kills.push(proc.kill().catch((e) => e));
      await Promise.allSettled(kills);
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
      const tmpLeftovers = readdirSync(tmpdir()).filter((e) => e.startsWith("ovid-pty-"));
      if (tmpLeftovers.length > 0) {
        problems.push(`leftover scratch dirs: ${tmpLeftovers.join(", ")}`);
      }
      // No jobmark-* processes may survive the suite.
      const jobmarks = scanForMarker("jobmark-");
      if (jobmarks > 0) problems.push(`leftover jobmark-* processes: ${jobmarks}`);
      if (problems.length > 0) {
        throw new Error(`pty host-test cleanup failed:\n- ${problems.join("\n- ")}`);
      }
    });

    // -- PTY sessions -------------------------------------------------------

    it("(a) pty — write 'tty\\n' → ring output contains /dev/pts/", async () => {
      const session = await createPtySession(
        ctx,
        { sessionId: "host-1" },
        { onData: () => {}, onExit: () => {} },
      );
      ptys.push(session);
      session.write(Buffer.from("tty\n"));
      await untilContains(() => ringText(session), "/dev/pts/", 15_000);
      expect(session.alive).toBe(true);
    });

    it("(b) pty — resize(100, 30) then 'stty size\\n' → output contains '30 100'", async () => {
      const session = ptys[0];
      session.resize(100, 30);
      session.write(Buffer.from("stty size\n"));
      await untilContains(() => ringText(session), "30 100", 15_000);
    });

    it("(c) pty — 'gradle build\\n' → the shim refusal copy appears VERBATIM in the ring (layer 2 in a live terminal)", async () => {
      const session = ptys[0];
      session.write(Buffer.from("gradle build\n"));
      await untilContains(() => ringText(session), REFUSAL_MESSAGE, 15_000);
    });

    it("(d) pty — kill() → exit resolves, leaf cgroup gone, alive === false", async () => {
      const session = await createPtySession(
        ctx,
        { sessionId: "host-kill" },
        { onData: () => {}, onExit: () => {} },
      );
      ptys.push(session);
      const leaf = mgr.leafPath(UID, `pty-${session.id}`);
      // The shell is up once `tty` answers (bash as mapped-root prompts "#",
      // never "$" — the tty answer is the reliable warm-up signal).
      session.write(Buffer.from("tty\n"));
      await untilContains(() => ringText(session), "/dev/pts/", 15_000);
      expect(existsSync(leaf)).toBe(true);
      await session.kill();
      await session.exit;
      expect(session.alive).toBe(false);
      expect(existsSync(leaf)).toBe(false);
      // idempotent
      await expect(session.kill()).resolves.toBeUndefined();
    });

    it("(e) pty — two ptys in one env coexist (distinct leaves)", async () => {
      const a = await createPtySession(
        ctx,
        { sessionId: "host-2a" },
        { onData: () => {}, onExit: () => {} },
      );
      const b = await createPtySession(
        ctx,
        { sessionId: "host-2b" },
        { onData: () => {}, onExit: () => {} },
      );
      ptys.push(a, b);
      const leafA = mgr.leafPath(UID, `pty-${a.id}`);
      const leafB = mgr.leafPath(UID, `pty-${b.id}`);
      expect(leafA).not.toBe(leafB);
      expect(existsSync(leafA)).toBe(true);
      expect(existsSync(leafB)).toBe(true);
      a.write(Buffer.from("echo coexist-a\n"));
      await untilContains(() => ringText(a), "coexist-a", 15_000);
      expect(b.alive).toBe(true); // a's traffic never disturbed b
      await a.kill();
      await a.exit;
      expect(existsSync(leafA)).toBe(false);
      expect(b.alive).toBe(true); // b survives a's kill — distinct leaves
      await b.kill();
      await b.exit;
    });

    // -- background jobs ----------------------------------------------------

    it("(f) job — sequential output streams into the ring; exited with code 0", async () => {
      const info = await jobs.start({
        command: "for i in 1 2 3; do echo j$i; sleep 0.2; done",
      });
      const deadline = Date.now() + 20_000;
      for (;;) {
        const out = jobs.output(info.id)!;
        const text = out.chunks
          .map((c) => Buffer.from(c.data, "base64").toString("utf8"))
          .join("");
        if (text.includes("j1") && text.includes("j2") && text.includes("j3")) break;
        if (Date.now() > deadline) {
          throw new Error(`timeout waiting for job output j1/j2/j3, got: ${text}`);
        }
        await sleep(100);
      }
      const li = jobs.list().find((j) => j.id === info.id)!;
      expect(li.state).toBe("exited");
      expect(li.exitCode).toBe(0);
      // the finished job's leaf is gone
      expect(existsSync(mgr.leafPath(UID, `job-${info.id}`))).toBe(false);
    });

    it("(g) job — cgroup tree kill reaps detached grandchildren within 2 s", async () => {
      const rand = randomBytes(4).toString("hex");
      const marker = `jobmark-${rand}`;
      const info = await jobs.start({
        command: `(sleep 300 ${marker} &) ; sleep 300 ${marker}`,
      });
      // The job's bash, the backgrounded sleep AND the foreground sleep all
      // carry the marker in /proc/<pid>/cmdline.
      expect(await untilAtLeast(() => scanForMarker(marker), 2, 15_000)).toBeGreaterThanOrEqual(2);
      await jobs.kill(info.id);
      expect(await untilZero(() => scanForMarker(marker), 2_000)).toBe(0);
      const li = jobs.list().find((j) => j.id === info.id)!;
      expect(li.state).toBe("killed");
    });

    it("(h) job — pids.max 16 stalls a fork storm; the host stays responsive (pids.events max ≥ 1)", async () => {
      const info = await jobsPids.start({
        command: "while :; do sleep 5 & done",
      });
      // The fork storm hits the env's pids cap: pids.events records it.
      const envPids = mgr.envPath(UID_PIDS);
      const deadline = Date.now() + 20_000;
      let maxEvents = 0;
      for (;;) {
        const events = await mgr.readFile(envPids, "pids.events");
        const m = events.match(/^max (\d+)$/m);
        maxEvents = m ? Number(m[1]) : 0;
        if (maxEvents >= 1) break;
        if (Date.now() > deadline) {
          throw new Error(`timeout waiting for pids.events max, got: ${events}`);
        }
        await sleep(100);
      }
      expect(maxEvents).toBeGreaterThanOrEqual(1); // Review Focus #4
      // The HOST (and this env's own spawns) stay responsive under the storm.
      const res = await execOnce(ctxPids, { command: "echo host-alive" });
      expect(res.exitCode).toBe(0);
      expect(res.stdout.trim()).toBe("host-alive");
      await jobsPids.kill(info.id);
      const li = jobsPids.list().find((j) => j.id === info.id)!;
      expect(li.state).toBe("killed");
      expect(await untilZero(() => scanForMarker("while :"), 5_000)).toBe(0);
    });

    // -- long-running spawn (G3 — the P5 stdio-MCP proof shape) -------------

    it("(i) spawn — pipes through the jail: writeLine('hello') → onStdoutLine receives 'HELLO'", async () => {
      const proc = await spawnLongRunning(ctx, {
        argv: [
          "/usr/local/bin/node",
          "-e",
          "process.stdin.on('data',d=>process.stdout.write(String(d).trim().toUpperCase()+'\\n'))",
        ],
      });
      procs.push(proc);
      const lines: string[] = [];
      proc.onStdoutLine((line) => lines.push(line));
      proc.writeLine("hello");
      const deadline = Date.now() + 20_000;
      while (!lines.includes("HELLO")) {
        if (Date.now() > deadline) throw new Error(`timeout waiting for HELLO, got: ${lines}`);
        await sleep(50);
      }
      expect(lines).toEqual(["HELLO"]); // exactly one line — no echo/CRLF noise
      await proc.kill();
    });

    it("(j) spawn — a child exiting on its own fires onExit and removes its leaf", async () => {
      const proc = await spawnLongRunning(ctx, {
        argv: ["/usr/local/bin/node", "-e", "process.exit(3)"],
      });
      procs.push(proc);
      const leaf = mgr.leafPath(UID, `spawn-${proc.id}`);
      const code = await new Promise<number | null>((resolve) => proc.onExit(resolve));
      expect(code).toBe(3);
      expect(existsSync(leaf)).toBe(false);
    });
  },
);
