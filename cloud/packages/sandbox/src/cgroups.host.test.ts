import { spawn, type ChildProcess } from "node:child_process";
import { randomBytes } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmdirSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createCgroupManager, CgroupSetupError, type CgroupManager } from "./cgroups.js";
import { DEFAULT_SANDBOX_LIMITS, type SandboxLimits } from "./config.js";
import { hostTestsAvailable } from "./hostGate.js";

/**
 * HOST-GATED cgroup v2 enforcement proofs (Task 6 Step 5). Runs only when
 * OVID_SANDBOX_HOST_TESTS=1 and root, against the REAL /sys/fs/cgroup.
 *
 * Scope guard (plan Global Constraints): throwaway `ovid-probe-cg-*` base
 * cgroups only, every hog double-bounded (capped allocation / capped fork
 * count / wall-clock cap on top of the cgroup cap), full cleanup in afterAll,
 * and an explicit assert that no `ovid-probe-*` cgroup remains. Production
 * cgroup paths and `ovid-gateway-*` are never touched.
 */

const CG_ROOT = "/sys/fs/cgroup";
const RAND = randomBytes(4).toString("hex");
const MAIN_BASE = `ovid-probe-cg-${process.pid}-${RAND}`;
const KILL_MARKER = `ovid-probe-cg-kill-${RAND}`;

const mgr: CgroupManager = createCgroupManager({
  cgroupRoot: CG_ROOT,
  cgroupBase: MAIN_BASE,
});

// Where this test process lived before init() migrated it — restored in
// beforeAll/afterAll so the probe never drags the vitest process tree into
// the throwaway cgroup for the rest of the run.
function readProcSelfCgroup(): string {
  const line = readFileSync("/proc/self/cgroup", "utf8")
    .trim()
    .split("\n")
    .find((l) => l.startsWith("0::"));
  if (!line) throw new Error("not a cgroups v2 host: no 0:: line in /proc/self/cgroup");
  return line.slice(3);
}
const ORIGINAL_CGROUP = readProcSelfCgroup();

let ebusyBaseName = "";
let ebusySleeper: ChildProcess | null = null;
let hostProcsBefore = 0;

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

function moveSelfTo(cgroupPath: string): void {
  // "" targets the root cgroup; otherwise the v2 path without /sys/fs/cgroup.
  writeFileSync(join(CG_ROOT, cgroupPath, "cgroup.procs"), String(process.pid));
}

function procCount(): number {
  return readdirSync("/proc").filter((e) => /^\d+$/.test(e)).length;
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

function countInProbeCgroups(): number {
  let n = 0;
  for (const entry of readdirSync("/proc")) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      if (readFileSync(join("/proc", entry, "cgroup"), "utf8").includes("ovid-probe-cg-")) n++;
    } catch {
      /* process gone */
    }
  }
  return n;
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

/** SIGKILL every process in the cgroup (never ourselves); wait until empty. */
async function drainCgroup(cgroupPath: string): Promise<void> {
  for (let i = 0; i < 100; i++) {
    const pids = readProcs(cgroupPath);
    if (pids.length === 0) return;
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
  throw new Error(`cgroup ${cgroupPath} still holds processes: ${readProcs(cgroupPath).join(", ")}`);
}

/** Depth-first kill+remove of a probe cgroup subtree (cgroupfs: rmdir only). */
async function removeCgroupTree(path: string): Promise<void> {
  if (!existsSync(path)) return;
  for (const e of readdirSync(path, { withFileTypes: true })) {
    if (e.isDirectory()) await removeCgroupTree(join(path, e.name));
  }
  // Belt over drainCgroup: signal the whole subtree at once. Guarded so we
  // can never signal a cgroup that still holds this process.
  if (!readProcs(path).includes(process.pid)) {
    try {
      writeFileSync(join(path, "cgroup.kill"), "1");
    } catch {
      /* not a cgroup / already gone */
    }
  }
  await drainCgroup(path);
  rmdirSync(path);
}

interface Buffers {
  stdout: string;
  stderr: string;
}

function spawnCapture(file: string, args: string[]): { child: ChildProcess; buf: Buffers } {
  const child = spawn(file, args, { stdio: ["ignore", "pipe", "pipe"] });
  const buf: Buffers = { stdout: "", stderr: "" };
  child.stdout?.on("data", (d: Buffer) => (buf.stdout += d.toString()));
  child.stderr?.on("data", (d: Buffer) => (buf.stderr += d.toString()));
  return { child, buf };
}

interface RunResult {
  code: number | null;
  signal: string | null;
  stdout: string;
  stderr: string;
}

/** Wait for exit with a wall-clock watchdog (the hogs' second bound). */
async function waitResult(
  child: ChildProcess,
  buf: Buffers,
  timeoutMs: number,
): Promise<RunResult> {
  const deadline = Date.now() + timeoutMs;
  while (child.exitCode === null && child.signalCode === null) {
    if (Date.now() > deadline) {
      try {
        child.kill("SIGKILL");
      } catch {
        /* already gone */
      }
      break;
    }
    await sleep(50);
  }
  // Let the exit event land and stdio flush.
  for (let i = 0; i < 40 && child.exitCode === null && child.signalCode === null; i++) {
    await sleep(50);
  }
  return { code: child.exitCode, signal: child.signalCode, stdout: buf.stdout, stderr: buf.stderr };
}

/** Attach a freshly spawned child to a cgroup and wait for the migration to
 *  be visible in /proc — children forked afterwards inherit the placement. */
async function attachAndWait(child: ChildProcess, fsPath: string): Promise<void> {
  if (!child.pid) throw new Error(`attachAndWait: child of ${fsPath} has no pid`);
  await mgr.attachPid(fsPath, child.pid);
  const rel = fsPath.slice(CG_ROOT.length); // "/ovid-probe-cg-…/sandbox-N"
  const deadline = Date.now() + 2_000;
  while (Date.now() < deadline) {
    if (readFileSync(`/proc/${child.pid}/cgroup`, "utf8").includes(rel)) return;
    await sleep(25);
  }
  throw new Error(`child ${child.pid} never migrated into ${rel}`);
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

function eventValue(events: string, key: string): number {
  return parseInt(events.match(new RegExp(`^${key} (\\d+)$`, "m"))?.[1] ?? "0", 10);
}

describe.skipIf(!hostTestsAvailable())("cgroups v2 enforcement (host-gated)", () => {
  beforeAll(async () => {
    // Delegation prerequisite (research §3 gotcha 2): the controllers must be
    // available at the cgroup root for a probe base to enable them.
    const controllers = readFileSync(join(CG_ROOT, "cgroup.controllers"), "utf8").split(/\s+/);
    for (const c of ["cpu", "memory", "pids"]) {
      if (!controllers.includes(c)) {
        throw new Error(`host cgroup root does not expose the ${c} controller`);
      }
    }

    await mgr.init();
    // init() must have parked this process in the worker leaf (leaf-first
    // bootstrap, proven on real cgroupfs)…
    expect(readProcSelfCgroup()).toBe(`/${MAIN_BASE}/worker`);
    // …but the probe must not keep the whole vitest process tree inside the
    // throwaway cgroup for the rest of the run — restore our placement.
    moveSelfTo(ORIGINAL_CGROUP);
    hostProcsBefore = procCount();
  });

  afterAll(async () => {
    const problems: string[] = [];
    // Restore placement first — a failed test may have aborted between an
    // init() self-move and the move-back.
    try {
      moveSelfTo(ORIGINAL_CGROUP);
    } catch (e) {
      problems.push(`restore placement: ${String(e)}`);
    }
    if (ebusySleeper?.pid) {
      try {
        ebusySleeper.kill("SIGKILL");
      } catch {
        /* already gone */
      }
    }
    for (const base of [MAIN_BASE, ebusyBaseName]) {
      if (!base) continue;
      try {
        await removeCgroupTree(join(CG_ROOT, base));
      } catch (e) {
        problems.push(`cleanup ${base}: ${String(e)}`);
      }
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
    if (problems.length > 0) {
      throw new Error(`cgroup host-test cleanup failed:\n- ${problems.join("\n- ")}`);
    }
  });

  it("(a) memory: a 64 MiB env cap OOM-kills the hog (exit 137, oom_kill ≥ 1)", async () => {
    const uid = 200001;
    const limits: SandboxLimits = {
      ...DEFAULT_SANDBOX_LIMITS,
      memoryMaxBytes: 67_108_864,
      pidsMax: 32,
    };
    await mgr.createEnv(uid, limits);
    // Processes live in leaves (the env itself has subtree_control enabled —
    // the no-internal-process rule forbids parking a pid directly in it);
    // caps and events are hierarchical across the env subtree.
    const leaf = await mgr.createLeaf(uid, "exec-1");
    // Double-bounded hog: 8 MB chunks, allocation hard-capped at 128 MB —
    // even with no enforcement it can never balloon the host (research §3).
    const py = [
      "total = 0",
      "chunks = []",
      "while total < 128 * 1024 * 1024:",
      '    chunks.append(b"x" * (8 * 1024 * 1024))',
      "    total += 8 * 1024 * 1024",
      "import time",
      "time.sleep(300)",
    ].join("\n");
    const { child, buf } = spawnCapture("sh", ["-c", `sleep 0.3; python3 -c '${py}'`]);
    try {
      await attachAndWait(child, leaf);
      const res = await waitResult(child, buf, 30_000);
      expect(res.code).toBe(137); // 128 + SIGKILL — the cgroup OOM killer
      const events = await mgr.readFile(mgr.envPath(uid), "memory.events");
      expect(eventValue(events, "oom_kill")).toBeGreaterThanOrEqual(1);
    } finally {
      await mgr.kill(leaf).catch(() => {});
      await mgr.remove(mgr.envPath(uid)).catch(() => {});
    }
  });

  it("(b) pids: pids.max=16 stops the fork loop with Cannot fork; pids.events max ≥ 1; host unaffected", async () => {
    const uid = 200002;
    await mgr.createEnv(uid, { ...DEFAULT_SANDBOX_LIMITS, pidsMax: 16 });
    const leaf = await mgr.createLeaf(uid, "exec-1");
    // The pinned fork loop, gated on a 0.3 s sleep so the attach lands first
    // (otherwise the first forks would escape into the uncapped host cgroup).
    const { child, buf } = spawnCapture("sh", [
      "-c",
      "sleep 0.3; while :; do sleep 10 & done",
    ]);
    try {
      await attachAndWait(child, leaf);
      const res = await waitResult(child, buf, 20_000);
      expect(res.stderr).toMatch(/Cannot fork|EAGAIN|Resource temporarily unavailable/);
      // Unlike memory.events (hierarchical up to the env — see test (a)), the
      // pids "max" event is charged to the cgroup the process lives in (the
      // leaf), even though the env's pids.max=16 is what tripped.
      const events = await mgr.readFile(leaf, "pids.events");
      expect(eventValue(events, "max")).toBeGreaterThanOrEqual(1);
    } finally {
      await mgr.kill(leaf).catch(() => {});
      await mgr.remove(mgr.envPath(uid)).catch(() => {});
    }
    // Nothing leaked out of the probe cgroups, and the host process count is
    // unchanged within noise.
    expect(await untilZero(countInProbeCgroups, 2_000)).toBe(0);
    expect(Math.abs(procCount() - hostProcsBefore)).toBeLessThan(64);
  });

  it("(c) cpu: cpu.max=\"50000 100000\" throttles a busy loop below 75% of the uncapped rate", async () => {
    // Wall-clock-bounded busy loop (2 s); the 300 ms gate lets the attach land
    // before the loop starts. Same work capped vs uncapped.
    const busy =
      "setTimeout(() => { const end = Date.now() + 2000; let n = 0; " +
      "while (Date.now() < end) n++; process.stdout.write(String(n)); }, 300);";
    await mgr.createEnv(200003, { ...DEFAULT_SANDBOX_LIMITS, cpuMax: "50000 100000" });
    await mgr.createEnv(200004, { ...DEFAULT_SANDBOX_LIMITS, cpuMax: "max 100000" });
    const cappedLeaf = await mgr.createLeaf(200003, "exec-1");
    const freeLeaf = await mgr.createLeaf(200004, "exec-1");

    const cappedRun = spawnCapture(process.execPath, ["-e", busy]);
    await attachAndWait(cappedRun.child, cappedLeaf);
    const capped = Number(
      (await waitResult(cappedRun.child, cappedRun.buf, 15_000)).stdout.trim(),
    );

    const freeRun = spawnCapture(process.execPath, ["-e", busy]);
    await attachAndWait(freeRun.child, freeLeaf);
    const uncapped = Number(
      (await waitResult(freeRun.child, freeRun.buf, 15_000)).stdout.trim(),
    );

    console.log(
      `[cpu throttle] capped=${capped} uncapped=${uncapped} ` +
        `ratio=${(capped / uncapped).toFixed(3)} (expect ≈ 0.5, must be < 0.75)`,
    );
    expect(uncapped).toBeGreaterThan(0);
    expect(capped).toBeGreaterThan(0);
    expect(capped).toBeLessThan(uncapped * 0.75);
  });

  it("(d) tree kill: cgroup.kill reaps the whole tree incl. detached grandchildren", async () => {
    const uid = 200005;
    await mgr.createEnv(uid, DEFAULT_SANDBOX_LIMITS);
    const leaf = await mgr.createLeaf(uid, "job-1");
    // Gate on 0.3 s so the attach lands first; then one foreground sleep and
    // one orphaned grandchild, both tagged with the unique /proc marker.
    const { child } = spawnCapture("/bin/bash", [
      "-c",
      `sleep 0.3; (exec -a ${KILL_MARKER} sleep 300 &) ; exec -a ${KILL_MARKER} sleep 300`,
    ]);
    try {
      await attachAndWait(child, leaf);
      expect(await untilAtLeast(() => scanForMarker(KILL_MARKER), 2, 2_000)).toBeGreaterThanOrEqual(2);
      await mgr.kill(leaf);
      expect(existsSync(leaf)).toBe(false);
      expect(await untilZero(() => scanForMarker(KILL_MARKER), 2_000)).toBe(0);
    } finally {
      await mgr.kill(leaf).catch(() => {});
    }
  });

  it("(e) EBUSY loudness: a process parked in a fresh base makes init() throw CgroupSetupError", async () => {
    ebusyBaseName = `ovid-probe-cg-${process.pid}-${randomBytes(4).toString("hex")}`;
    const baseDir = join(CG_ROOT, ebusyBaseName);
    mkdirSync(baseDir);
    const sleeper = spawn("sleep", ["300"], { stdio: "ignore" });
    ebusySleeper = sleeper;
    try {
      // Park the sleeper directly in the base — the no-internal-process rule
      // (research §3 gotcha 1) must make the subtree_control write EBUSY even
      // though init() already moved the caller into the worker leaf.
      writeFileSync(join(baseDir, "cgroup.procs"), String(sleeper.pid));
      expect(
        await (async () => {
          const deadline = Date.now() + 2_000;
          while (Date.now() < deadline) {
            try {
              if (readFileSync(`/proc/${sleeper.pid}/cgroup`, "utf8").includes(`/${ebusyBaseName}`)) {
                return true;
              }
            } catch {
              /* sleeper gone — let the deadline expire */
            }
            await sleep(25);
          }
          return false;
        })(),
      ).toBe(true);

      const parked = createCgroupManager({ cgroupRoot: CG_ROOT, cgroupBase: ebusyBaseName });
      const err: unknown = await parked.init().catch((e: unknown) => e);
      expect(err).toBeInstanceOf(CgroupSetupError);
      expect((err as Error).message).toMatch(/parked in/);
    } finally {
      try {
        sleeper.kill("SIGKILL");
      } catch {
        /* already gone */
      }
      // init() moved this process into the EBUSY base's worker before
      // throwing — restore placement so afterAll can remove the tree.
      try {
        moveSelfTo(ORIGINAL_CGROUP);
      } catch {
        /* afterAll retries */
      }
    }
  });
});
