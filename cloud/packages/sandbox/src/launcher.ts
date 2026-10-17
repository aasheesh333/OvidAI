import { spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Readable, Writable } from "node:stream";
import type { SandboxConfig } from "./config.js";
import { BASE_JAIL_ENV } from "./invocation.js";
// Type-only import: erased at compile time (the VALUE import below is what
// cjs-module-lexer cannot link — see createRequire note).
import type { IPty } from "node-pty";

// node-pty is a native CJS module: a static ESM named VALUE import does not
// link at runtime (cjs-module-lexer cannot see its exports), so it is
// required synchronously here. The require resolves the built pty.node
// through pnpm's isolated node_modules (node-pty is a direct dependency).
const requireNodePty = createRequire(import.meta.url);
type NodePtyModule = typeof import("node-pty");
const nodePty = requireNodePty("node-pty") as NodePtyModule;

/**
 * The child_process subset execOnce (Task 7) and the Task 9 pty/job adapters
 * consume — the node:child_process shape narrowed to what a jail spawn needs.
 * `node-pty` IPty instances are wrapped into {@link PtyChildLike} in Task 9.
 */
export interface ChildProcessLike {
  readonly pid: number;
  readonly stdout: Readable | null;
  readonly stderr: Readable | null;
  readonly stdin: Writable | null;
  kill(signal?: NodeJS.Signals): boolean;
  once(event: "exit", listener: (code: number | null, signal: NodeJS.Signals | null) => void): void;
  once(event: "error", listener: (err: Error) => void): void;
}

/**
 * node-pty's IPty (structural subset — the members the Task 9 bridge and the
 * Task 13 gateway use) plus the explicit `pid` the launcher contract names.
 */
export interface PtyChildLike {
  readonly pid: number;
  readonly cols: number;
  readonly rows: number;
  write(data: string): void;
  kill(signal?: string): boolean;
  resize(cols: number, rows: number): void;
  onData(listener: (data: string) => void): unknown;
  onExit(listener: (e: { exitCode: number; signal?: number }) => void): unknown;
  pause(): void;
  resume(): void;
}

/** How the exec layer asks for a jailed process (via bin/sandbox-enter.sh). */
export interface JailLauncher {
  /**
   * Spawns `bash sandbox-enter.sh <cgroupProcsFile> <uid> <gid> <argvFile>`
   * where the argv file holds `bwrapArgv` NUL-separated. The launcher child
   * self-attaches to the cgroup BEFORE setpriv drops to the sandbox uid
   * (research §3 ordering — Task 6 forward note).
   */
  spawn(
    bwrapArgv: string[],
    opts: {
      uid: number;
      gid: number;
      cgroupProcsFile: string;
      cwd: string;
      env?: NodeJS.ProcessEnv;
    },
  ): ChildProcessLike;
  /** Same launcher contract, spawned on a pty master (Task 9). */
  spawnPty(
    bwrapArgv: string[],
    opts: {
      uid: number;
      gid: number;
      cgroupProcsFile: string;
      cwd: string;
      cols: number;
      rows: number;
    },
  ): PtyChildLike;
}

/** Wraps a real ChildProcess into the {@link ChildProcessLike} seam. */
function adapt(child: ChildProcess): ChildProcessLike {
  return {
    pid: child.pid ?? -1,
    stdout: child.stdout,
    stderr: child.stderr,
    stdin: child.stdin,
    kill: (signal?: NodeJS.Signals) => child.kill(signal),
    once: (event, listener) => {
      child.once(event as "exit", listener as never);
    },
  };
}

/**
 * The setuid-path launcher (Task 1 DECISION working assumption): a root-run
 * `bash sandbox-enter.sh` that attaches itself to the cgroup leaf and then
 * execs the bwrap argv as the sandbox uid via setpriv. The NUL-separated
 * argv file is a mktemp scratch file with mode 0600, unlinked as soon as the
 * child exits or errors — the unlink listener is registered before any
 * execOnce exit listener, so the file is gone by the time a run resolves.
 */
export function createSetuidLauncher(config: Pick<SandboxConfig, "launcherPath">): JailLauncher {
  return {
    spawn(bwrapArgv, opts) {
      const scratch = mkdtempSync(join(tmpdir(), "ovid-enter-"));
      const argvFile = join(scratch, "argv");
      let child: ChildProcess;
      try {
        writeFileSync(argvFile, bwrapArgv.join("\0") + "\0", { mode: 0o600 });
        child = spawn(
          "bash",
          [
            config.launcherPath,
            opts.cgroupProcsFile,
            String(opts.uid),
            String(opts.gid),
            argvFile,
          ],
          {
            cwd: opts.cwd,
            // Minimal host env for bash/setpriv/bwrap resolution — the jail
            // payload environment is --clearenv'd and rebuilt by bwrap itself.
            env: opts.env ?? { PATH: "/usr/sbin:/usr/bin:/sbin:/bin" },
            stdio: ["pipe", "pipe", "pipe"],
          },
        );
      } catch (err) {
        // fix-round M-1: a sync throw during prep (malformed argv, ENOSPC on
        // the argv write, …) must not leak the scratch dir — no child exists
        // to clean it up. Async failures go through the listeners below.
        rmSync(scratch, { recursive: true, force: true });
        throw err;
      }
      const cleanup = () => rmSync(scratch, { recursive: true, force: true });
      child.once("exit", cleanup);
      child.once("error", cleanup);
      return adapt(child);
    },

    spawnPty(
      bwrapArgv: string[],
      opts: {
        uid: number;
        gid: number;
        cgroupProcsFile: string;
        cwd: string;
        cols: number;
        rows: number;
      },
    ): PtyChildLike {
      // Same launcher contract as spawn (NUL-separated argv scratch file,
      // self-attach to the cgroup leaf inside sandbox-enter.sh), but the
      // child runs on a pty master so the jailed payload gets a controlling
      // terminal. The pty's TERM matches BASE_JAIL_ENV — one source of truth
      // for the payload's terminal type.
      const scratch = mkdtempSync(join(tmpdir(), "ovid-enter-"));
      const argvFile = join(scratch, "argv");
      let child: IPty;
      try {
        writeFileSync(argvFile, bwrapArgv.join("\0") + "\0", { mode: 0o600 });
        child = nodePty.spawn(
          "bash",
          [
            config.launcherPath,
            opts.cgroupProcsFile,
            String(opts.uid),
            String(opts.gid),
            argvFile,
          ],
          {
            name: BASE_JAIL_ENV.TERM,
            cols: opts.cols,
            rows: opts.rows,
            cwd: opts.cwd,
            // Minimal host env for bash/setpriv/bwrap resolution; the jail
            // payload environment is --clearenv'd and rebuilt by bwrap itself.
            env: { PATH: "/usr/sbin:/usr/bin:/sbin:/bin" },
          },
        );
      } catch (err) {
        // Sync prep failure must not leak the scratch dir (M-1 reasoning).
        rmSync(scratch, { recursive: true, force: true });
        throw err;
      }
      const cleanup = () => rmSync(scratch, { recursive: true, force: true });
      child.onExit(() => cleanup());
      return {
        pid: child.pid,
        cols: child.cols,
        rows: child.rows,
        write: (data) => child.write(data),
        kill: (signal) => {
          child.kill(signal);
          return true;
        },
        resize: (cols, rows) => child.resize(cols, rows),
        onData: (listener) => child.onData(listener),
        onExit: (listener) => child.onExit(listener),
        pause: () => child.pause(),
        resume: () => child.resume(),
      };
    },
  };
}

/**
 * The rootmap-path launcher — STUB. Task 1's MECHANISM.md DECISION line is
 * still empty (setuid is the working assumption); the map-writer mechanics
 * land here only if the probe decides rootmap.
 */
export function createRootmapLauncher(
  _config: Pick<SandboxConfig, "launcherPath">,
): JailLauncher {
  const pending = (): never => {
    throw new Error("rootmap launcher pending MECHANISM.md decision");
  };
  return { spawn: pending, spawnPty: pending };
}
