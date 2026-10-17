import * as fsp from "node:fs/promises";
import { join } from "node:path";
import type { SandboxConfig, SandboxLimits } from "./config.js";

/**
 * Controllers enabled on the base and on every env cgroup so the leaves
 * (exec-*, pty-*, job-*) get their interface files (research §3 gotcha 2:
 * memory.max etc. only exist once the PARENT's subtree_control enables the
 * controller).
 */
const CONTROLLERS = "+cpu +memory +pids";

/** Cgroup v2 resource-manager for one sandbox host. See Task 6 brief. */
export interface CgroupManager {
  /**
   * Leaf-first bootstrap (research §3 gotcha 1 — no-internal-process rule):
   * create {base}/worker, move our own pid into it, then enable
   * "+cpu +memory +pids" on {base}/cgroup.subtree_control. Idempotent.
   * Still-EBUSY after the self-move means another process is parked in the
   * base — throw CgroupSetupError loudly instead of half-booting.
   */
  init(): Promise<void>;
  /** {cgroupRoot}/{cgroupBase}/sandbox-{uid} */
  envPath(uid: number): string;
  /** {envPath}/{name} — names: exec-*, pty-*, job-* */
  leafPath(uid: number, name: string): string;
  /**
   * Create the env cgroup and write its caps — EXACT values from `limits`
   * (bytes strings for memory, "0"-style for swap, raw cpu.max pair).
   */
  createEnv(uid: number, limits: SandboxLimits): Promise<void>;
  /** Create {envPath}/{name}; returns the absolute path. */
  createLeaf(uid: number, name: string): Promise<string>;
  /** Migrate `pid` into the cgroup at `path` (write to cgroup.procs). */
  attachPid(path: string, pid: number): Promise<void>;
  /** {path}/cgroup.procs — handed to the Task 7 launcher. */
  procsFile(path: string): string;
  /**
   * Kill every process in the cgroup subtree: write 1 to cgroup.kill, poll
   * cgroup.procs until empty (50 ms × 100), then rmdir.
   */
  kill(path: string): Promise<void>;
  /** rmdir — the cgroup must be empty (no processes, no child cgroups). */
  remove(path: string): Promise<void>;
  /** Read an interface file (memory.events, pids.events, cpu.stat, …). */
  readFile(path: string, file: string): Promise<string>;
  /** Absolute paths of the child cgroup directories of `path`. */
  listChildren(path: string): Promise<string[]>;
}

/** Base cgroup is occupied by a foreign process — worker refuses to boot. */
export class CgroupSetupError extends Error {
  constructor(message: string, options?: { cause: unknown }) {
    super(message, options);
    this.name = "CgroupSetupError";
  }
}

function isErrnoException(err: unknown): err is NodeJS.ErrnoException {
  return err instanceof Error && "code" in err;
}

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * Plain fs reads/writes against {cgroupRoot}/{cgroupBase} — the same
 * implementation serves unit tests (tmpdir root: the files are inert) and
 * production (/sys/fs/cgroup: the kernel enforces).
 */
export function createCgroupManager(
  cfg: Pick<SandboxConfig, "cgroupRoot" | "cgroupBase">,
): CgroupManager {
  const base = join(cfg.cgroupRoot, cfg.cgroupBase);

  const write = (path: string, value: string | number) =>
    fsp.writeFile(path, String(value), "utf8");

  return {
    async init(): Promise<void> {
      const worker = join(base, "worker");
      await fsp.mkdir(worker, { recursive: true });
      // No-internal-process rule: the base must hold no processes before
      // controllers can be enabled on it, so move ourselves into the worker
      // leaf first. (A parent parked in the base still triggers EBUSY below.)
      await write(join(worker, "cgroup.procs"), process.pid);
      try {
        await write(join(base, "cgroup.subtree_control"), CONTROLLERS);
      } catch (err) {
        if (isErrnoException(err) && err.code === "EBUSY") {
          throw new CgroupSetupError(
            `cgroup init: enabling "${CONTROLLERS}" on ${join(base, "cgroup.subtree_control")} ` +
              `returned EBUSY even after moving this process into ${worker} — ` +
              `another process is parked in ${base}. Stop or migrate it before starting the worker.`,
            { cause: err },
          );
        }
        throw err;
      }
    },

    envPath(uid: number): string {
      return join(base, `sandbox-${uid}`);
    },

    leafPath(uid: number, name: string): string {
      return join(base, `sandbox-${uid}`, name);
    },

    async createEnv(uid: number, limits: SandboxLimits): Promise<void> {
      const env = join(base, `sandbox-${uid}`);
      await fsp.mkdir(env, { recursive: true });
      await write(join(env, "cgroup.subtree_control"), CONTROLLERS);
      await write(join(env, "memory.max"), limits.memoryMaxBytes);
      await write(join(env, "memory.swap.max"), limits.memorySwapMaxBytes);
      await write(join(env, "pids.max"), limits.pidsMax);
      await write(join(env, "cpu.max"), limits.cpuMax);
    },

    async createLeaf(uid: number, name: string): Promise<string> {
      const leaf = join(base, `sandbox-${uid}`, name);
      await fsp.mkdir(leaf); // env must exist — ENOENT here means createEnv was skipped
      return leaf;
    },

    async attachPid(path: string, pid: number): Promise<void> {
      await write(join(path, "cgroup.procs"), pid);
    },

    procsFile(path: string): string {
      return join(path, "cgroup.procs");
    },

    async kill(path: string): Promise<void> {
      await write(join(path, "cgroup.kill"), "1");
      for (let i = 0; i < 100; i++) {
        const procs = await fsp
          .readFile(join(path, "cgroup.procs"), "utf8")
          .catch(() => ""); // cgroup already gone — fall through to rmdir
        if (procs.trim() === "") break;
        await sleep(50);
      }
      try {
        await fsp.rmdir(path);
      } catch (err) {
        if (!isErrnoException(err) || err.code !== "ENOTEMPTY") throw err;
        // tmpdir-rooted tests only: on an ordinary filesystem the interface
        // files (cgroup.kill, memory.max, cpu.max, … — pure simulation
        // artifacts, including the env caps the Task 8 manager tears down on
        // destroy) block rmdir. cgroupfs never returns ENOTEMPTY (its
        // interface files are not removable entries; a busy cgroup yields
        // EBUSY instead), so this branch is dead code in production. Unlink
        // every regular file and retry; child cgroup DIRECTORIES still
        // rethrow — those are a real error.
        const entries = await fsp.readdir(path, { withFileTypes: true });
        if (entries.some((e) => e.isDirectory())) throw err;
        for (const e of entries) await fsp.unlink(join(path, e.name)).catch(() => {});
        await fsp.rmdir(path);
      }
    },

    async remove(path: string): Promise<void> {
      await fsp.rmdir(path);
    },

    async readFile(path: string, file: string): Promise<string> {
      return fsp.readFile(join(path, file), "utf8");
    },

    async listChildren(path: string): Promise<string[]> {
      const entries = await fsp.readdir(path, { withFileTypes: true });
      return entries
        .filter((e) => e.isDirectory())
        .map((e) => join(path, e.name));
    },
  };
}
