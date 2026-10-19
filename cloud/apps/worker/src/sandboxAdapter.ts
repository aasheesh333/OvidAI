import { mkdir, readdir, readFile, stat, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

import {
  JAIL_WORKSPACE,
  REFUSAL_MESSAGE,
  type ExecRequest,
  type ExecResult,
  type SandboxManager,
} from "@ovid/sandbox";
import type { SandboxPort } from "@ovid/agent-core";

import { resolveConfined } from "./tools/confinement.js";

/**
 * The SandboxPort adapter (P3 Task 9): adapts P2's landed SandboxManager
 * (attach/exec/PTY/jobs) to the canonical SandboxPort interface.
 *
 * Known drift absorptions (the C3 seam):
 * - P2's ExecRequest has NO callKey and execOnce kills on ITS timeout
 *   internally — so the adapter keeps its own callKey→child map: execOnce gets
 *   the dispatcher's timeoutMs passed down (it enforces the same deadline), and
 *   killCall(userId, callKey) waits for the tracked one-shot to settle so the
 *   call's processes are gone before the dispatch moves on. Job/PTY leaves are
 *   killed through their own ports (jobKill / sandbox destroy).
 * - The port's file methods (userId + workspace-relative path) are synthesized
 *   over the handle's workspaceDir + resolveConfined — the same confinement
 *   boundary P2's host-side file tools use (layer: P2-T12).
 * - cwd is JAIL-side in P2 (default /workspace): the port's workspace-relative
 *   cwd values are joined onto JAIL_WORKSPACE; absolute cwds pass through.
 */

interface TrackedExec {
  userId: string;
  done: Promise<ExecResult>;
}

/** Maps a workspace-relative cwd onto the jail-side cwd execOnce expects. */
function jailCwd(cwd?: string): string | undefined {
  if (cwd === undefined || cwd === "") return undefined;
  if (cwd.startsWith("/")) return cwd;
  return `${JAIL_WORKSPACE}/${cwd}`;
}

function mapExecResult(res: ExecResult): { exitCode: number; stdout: string; stderr: string } {
  if (res.blocked) {
    // execOnce enforces the command policy (layer 1) — a blocked request never
    // spawned; surface the refusal as a refused, non-zero result.
    return { exitCode: 126, stdout: res.stdout, stderr: res.refusal ?? REFUSAL_MESSAGE };
  }
  // a killed one-shot (timedOut ⇒ exitCode null) must not read as success
  return { exitCode: res.exitCode ?? -1, stdout: res.stdout, stderr: res.stderr };
}

function isErrnoException(err: unknown): err is NodeJS.ErrnoException {
  return err instanceof Error && "code" in err;
}

/**
 * A bounded gate around LOCAL resource execution (owner directive
 * 2026-10-18). Agent runs spend most of their life streaming model tokens —
 * pure async I/O that costs no CPU and a couple of MB. The expensive part is
 * the brief local step: spawning a jailed process, reading/writing a file.
 * So run concurrency and step concurrency are DIFFERENT budgets:
 *
 *   - runs: thousands may be in flight (BullMQ concurrency + admission)
 *   - steps: a bounded number may actually execute at once
 *
 * Without this, N runs that each call `run_shell` at the same moment spawn N
 * processes, and the box thrashes on CPU rather than queueing cleanly.
 *
 * `release` runs in a finally, so a throwing tool can never leak a permit.
 */
export interface StepLimiter {
  run<T>(fn: () => Promise<T>): Promise<T>;
  stats(): { active: number; waiting: number; max: number };
}

export function createStepLimiter(max: number): StepLimiter {
  if (!Number.isInteger(max) || max < 1) {
    throw new Error(`createStepLimiter: max must be a positive integer, got ${max}`);
  }
  let active = 0;
  const waiting: Array<() => void> = [];
  return {
    async run<T>(fn: () => Promise<T>): Promise<T> {
      if (active >= max) {
        // FIFO: the earliest waiter is released first, so a burst of tool
        // calls executes in arrival order instead of starving.
        await new Promise<void>((resolve) => waiting.push(resolve));
      } else {
        // Only the FRESH admission counts itself — a woken waiter must not
        // increment (see release below).
        active += 1;
      }
      try {
        return await fn();
      } finally {
        // TRANSFER, not release-then-reacquire (sandbox releaseSlot parity,
        // manager.ts): a decrement-then-wake let a run() admitted in the
        // microtask window between the decrement and the head waiter's
        // continuation see active < max and take a SECOND permit. Handing the
        // count to the woken waiter keeps it at reality, so nobody jumps the
        // queue — and the woken waiter's continuation must NOT increment,
        // or the transfer double-counts.
        const next = waiting.shift();
        if (next === undefined) active -= 1;
        else next();
      }
    },
    stats: () => ({ active, waiting: waiting.length, max }),
  };
}

export function createSandboxPort(
  manager: SandboxManager,
  opts?: {
    tier?: "free" | "pro";
    /**
     * Shared across EVERY port instance (one per run) — the bound is on the
     * box, not on a run. Absent ⇒ unbounded (tests / non-production).
     */
    stepLimit?: StepLimiter;
  },
): SandboxPort {
  const calls = new Map<string, TrackedExec>();
  const attach = (userId: string) =>
    manager.attach(userId, opts?.tier ? { tier: opts.tier } : undefined);
  const step = <T>(fn: () => Promise<T>): Promise<T> =>
    opts?.stepLimit === undefined ? fn() : opts.stepLimit.run(fn);

  return {
    async exec(userId, o) {
      return step(async () => {
        const handle = await attach(userId);
        const req: ExecRequest = {
          command: o.cmd,
          cwd: jailCwd(o.cwd),
          timeoutMs: o.timeoutMs,
          env: o.env,
        };
        const done = handle.exec(req);
        if (o.callKey) calls.set(o.callKey, { userId, done });
        try {
          return mapExecResult(await done);
        } finally {
          if (o.callKey) calls.delete(o.callKey);
        }
      });
    },

    async killCall(userId, callKey) {
      const entry = calls.get(callKey);
      if (!entry || entry.userId !== userId) return;
      calls.delete(callKey);
      // execOnce kills the exec's cgroup leaf at the timeoutMs we passed down;
      // settle with that kill instead of racing past it.
      await entry.done.catch(() => {});
    },

    async readFile(userId, path) {
      return step(async () => {
        const handle = await attach(userId);
        const host = await resolveConfined(handle.workspaceDir, path);
        try {
          return await readFile(host, "utf8");
        } catch (err) {
          if (isErrnoException(err) && err.code === "ENOENT") {
            throw new Error(`no such file: ${path}`);
          }
          throw err;
        }
      });
    },

    async writeFile(userId, path, content) {
      return step(async () => {
        const handle = await attach(userId);
        const host = await resolveConfined(handle.workspaceDir, path);
        await mkdir(dirname(host), { recursive: true });
        await writeFile(host, content, "utf8");
      });
    },

    async exists(userId, path) {
      return step(async () => {
        const handle = await attach(userId);
        const host = await resolveConfined(handle.workspaceDir, path);
        try {
          await stat(host);
          return true;
        } catch (err) {
          if (isErrnoException(err) && err.code === "ENOENT") return false;
          throw err;
        }
      });
    },

    async listDir(userId, path) {
      return step(async () => {
        const handle = await attach(userId);
        const host = await resolveConfined(handle.workspaceDir, path);
        return readdir(host);
      });
    },

    async jobStart(userId, o) {
      return step(async () => {
        const handle = await attach(userId);
        const info = await handle.jobs.start({ command: o.cmd, cwd: jailCwd(o.cwd) });
        return { jobId: info.id };
      });
    },

    async jobOutput(userId, jobId, o) {
      const handle = await attach(userId);
      const out = handle.jobs.output(jobId, o?.offset ?? null);
      if (out === null) throw new Error(`no such job: ${jobId}`);
      const output = Buffer.concat(
        out.chunks.map((c) => Buffer.from(c.data, "base64")),
      ).toString("utf8");
      const info = handle.jobs.list().find((j) => j.id === jobId);
      return {
        output,
        running: info?.state === "running",
        exitCode: info !== undefined && info.state === "exited" ? info.exitCode : null,
      };
    },

    async jobList(userId) {
      const handle = await attach(userId);
      return handle.jobs
        .list()
        .map((j) => ({ jobId: j.id, cmd: j.command, running: j.state === "running" }));
    },

    async jobKill(userId, jobId) {
      const handle = await attach(userId);
      await handle.jobs.kill(jobId);
    },
  };
}