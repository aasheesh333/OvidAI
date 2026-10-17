import { randomBytes } from "node:crypto";
import { buildBwrapArgs, type JailSpec } from "./invocation.js";
import type { ChildProcessLike } from "./launcher.js";
import { CommandBlockedError, checkCommandPolicy, REFUSAL_MESSAGE } from "./policy.js";
import { createChunkRing, JOB_OUTPUT_RING_BYTES, type ChunkRing, type RingChunk } from "./ring.js";
import type { JailContext } from "./types.js";

/**
 * Background jobs and long-lived jailed processes (P2 Task 9).
 *
 * - `createJobRegistry`: policy-checked background shell jobs under a
 *   `job-{id}` leaf, each with a 1 MB output ring, max 16 concurrent per env.
 *   Killing a job is a cgroup tree-kill — daemonized descendants die too.
 * - `spawnLongRunning` (gap G3): a long-lived jailed process with PIPES —
 *   the P5 `SandboxSpawner` stdio-MCP backing capability. Same machinery as
 *   jobs minus the tty and minus the shell: NO policy check (the argv is
 *   operator-configured, not model-authored text; P5 enforces its own
 *   LAUNCHER_ONLY_COMMANDS allowlist at the seam), launcher.spawn with stdin
 *   kept open and stdout/stderr as pipes. A tty is deliberately NOT used:
 *   echo/CRLF would corrupt the JSON-RPC line channel.
 */

/** Max concurrent RUNNING jobs per env (spec: 16 background jobs). */
const MAX_CONCURRENT_JOBS = 16;

/** Capped stderr collector for spawned processes (drained, surfaced on exit). */
const SPAWN_STDERR_CAP_BYTES = 64 * 1024;

function isErrnoException(err: unknown): err is NodeJS.ErrnoException {
  return err instanceof Error && "code" in err;
}

/** Tolerates a leaf that is already gone (kill() removes it). */
async function teardownLeafQuietly(ctx: JailContext, leafPath: string): Promise<void> {
  try {
    await ctx.cgroups.remove(leafPath);
  } catch (err) {
    if (isErrnoException(err) && err.code === "ENOENT") return;
    // EBUSY etc.: a daemonized descendant may still hold the leaf — tree-kill
    // and retry once; a STILL-failing teardown is logged, never thrown
    // (teardown must not replace a valid result with a rejection).
    await ctx.cgroups.kill(leafPath).catch(() => {});
    try {
      await ctx.cgroups.remove(leafPath);
    } catch (retryErr) {
      if (isErrnoException(retryErr) && retryErr.code === "ENOENT") return;
      console.error(`sandbox job teardown: leaf teardown failed for ${leafPath}:`, retryErr);
    }
  }
}

// ---------------------------------------------------------------------------
// JobRegistry
// ---------------------------------------------------------------------------

export interface JobRequest {
  command: string;
  cwd?: string;
  env?: Record<string, string>;
  /** Optional wall-clock kill (tree-killed → state "killed"); no default. */
  timeoutMs?: number;
}

export interface JobInfo {
  id: string;
  command: string;
  state: "running" | "exited" | "killed";
  exitCode: number | null;
  startedAt: string;
  /** The job ring's CURRENT lifetime end offset (moves as output streams). */
  endOffset: number;
}

export interface JobOutput {
  truncated: boolean;
  chunks: RingChunk[];
  endOffset: number;
}

export interface JobRegistry {
  /** Policy-checked: a blocked command throws CommandBlockedError (no spawn). */
  start(req: JobRequest): Promise<JobInfo>;
  /** Snapshot of every tracked job (running and finished). */
  list(): JobInfo[];
  /** null = unknown id. */
  output(id: string, afterOffset?: number | null): JobOutput | null;
  /** cgroup.kill the job leaf (whole tree) → state "killed". Unknown id: no-op. */
  kill(id: string): Promise<void>;
  /** Tree-kill every running job (sandbox destroy calls this first). */
  killAll(): Promise<void>;
  /** Number of tracked jobs (all states). */
  readonly size: number;
}

interface JobRecord {
  id: string;
  command: string;
  state: "running" | "exited" | "killed";
  exitCode: number | null;
  startedAt: string;
  ring: ChunkRing;
  leafPath: string;
  child: ChildProcessLike;
  timer?: NodeJS.Timeout;
  killPromise?: Promise<void>;
}

export function createJobRegistry(ctx: JailContext): JobRegistry {
  const jobs = new Map<string, JobRecord>();

  const info = (rec: JobRecord): JobInfo => ({
    id: rec.id,
    command: rec.command,
    state: rec.state,
    exitCode: rec.exitCode,
    startedAt: rec.startedAt,
    endOffset: rec.ring.endOffset,
  });

  const finalize = (rec: JobRecord, state: "exited" | "killed", code: number | null): void => {
    if (rec.state !== "running") return; // kill() marks "killed" synchronously
    if (rec.timer !== undefined) clearTimeout(rec.timer);
    rec.state = state;
    rec.exitCode = state === "killed" ? null : code;
    // The payload is gone; drain+remove the leaf (kill() may have raced us).
    void teardownLeafQuietly(ctx, rec.leafPath);
  };

  const killRecord = (rec: JobRecord): Promise<void> => {
    if (rec.killPromise !== undefined) return rec.killPromise;
    // State flips FIRST so a synchronous child 'exit' during the kill cannot
    // relabel the job "exited" — a killed job reports "killed".
    finalize(rec, "killed", null);
    rec.killPromise = (async () => {
      try {
        await ctx.cgroups.kill(rec.leafPath); // whole tree, removes the leaf
      } catch (err) {
        if (!isErrnoException(err) || err.code !== "ENOENT") {
          console.error(`job kill: leaf kill failed for ${rec.leafPath}:`, err);
        }
      }
      try {
        rec.child.kill("SIGKILL"); // belt under the tree kill
      } catch {
        // already gone
      }
    })();
    return rec.killPromise;
  };

  return {
    async start(req: JobRequest): Promise<JobInfo> {
      if (typeof req.command !== "string" || req.command.trim() === "") {
        throw new Error("JobRequest.command must be non-empty");
      }
      // Policy gate FIRST — a blocked request has ZERO side effects: no leaf,
      // no spawn, no registry entry (Review Focus #1).
      const verdict = checkCommandPolicy(req.command);
      if (!verdict.allowed) {
        throw new CommandBlockedError(REFUSAL_MESSAGE, verdict.matched);
      }
      let running = 0;
      for (const rec of jobs.values()) if (rec.state === "running") running++;
      if (running >= MAX_CONCURRENT_JOBS) {
        throw new Error("job_limit");
      }

      const id = randomBytes(6).toString("hex");
      const leafPath = await ctx.cgroups.createLeaf(ctx.uid, `job-${id}`);
      const spec: JailSpec = {
        rootfs: ctx.rootfs,
        workspaceDir: ctx.workspaceDir,
        homeDir: ctx.homeDir,
        etcDir: ctx.etcDir,
        cwd: req.cwd,
        env: req.env,
        argv: ["/bin/bash", "-c", req.command],
      };

      let child: ChildProcessLike;
      try {
        child = ctx.launcher.spawn(buildBwrapArgs(spec, ctx.config), {
          uid: ctx.uid,
          gid: ctx.uid,
          cgroupProcsFile: ctx.cgroups.procsFile(leafPath),
          cwd: ctx.workspaceDir,
        });
      } catch (err) {
        await teardownLeafQuietly(ctx, leafPath);
        throw err;
      }

      const rec: JobRecord = {
        id,
        command: req.command,
        state: "running",
        exitCode: null,
        startedAt: new Date().toISOString(),
        ring: createChunkRing(JOB_OUTPUT_RING_BYTES),
        leafPath,
        child,
      };
      jobs.set(id, rec);

      // stdout AND stderr both stream into the job's ring — a background
      // job's log is one interleaved channel (this is a log, not a protocol).
      child.stdout?.on("data", (chunk: Buffer) => {
        rec.ring.push(chunk);
      });
      child.stderr?.on("data", (chunk: Buffer) => {
        rec.ring.push(chunk);
      });

      child.once("exit", (code) => finalize(rec, "exited", code));
      child.once("error", () => finalize(rec, "exited", null));

      if (req.timeoutMs !== undefined && req.timeoutMs > 0) {
        rec.timer = setTimeout(() => {
          void killRecord(rec);
        }, req.timeoutMs);
      }

      return info(rec);
    },

    list(): JobInfo[] {
      return [...jobs.values()].map(info);
    },

    output(id: string, afterOffset?: number | null): JobOutput | null {
      const rec = jobs.get(id);
      if (rec === undefined) return null;
      const res = rec.ring.since(afterOffset ?? null);
      return { truncated: res.truncated, chunks: res.chunks, endOffset: res.endOffset };
    },

    kill(id: string): Promise<void> {
      const rec = jobs.get(id);
      if (rec === undefined) return Promise.resolve(); // unknown id: no-op
      if (rec.state !== "running") return Promise.resolve(); // already finished
      return killRecord(rec);
    },

    async killAll(): Promise<void> {
      await Promise.allSettled(
        [...jobs.values()]
          .filter((rec) => rec.state === "running")
          .map((rec) => killRecord(rec)),
      );
    },

    get size(): number {
      return jobs.size;
    },
  };
}

// ---------------------------------------------------------------------------
// spawnLongRunning — the P5 stdio-MCP backing (gap G3)
// ---------------------------------------------------------------------------

export interface SpawnedProcess {
  readonly id: string;
  readonly pid: number;
  /** UTF-8 + "\\n" (appended when absent) → child stdin; never throws. */
  writeLine(line: string): void;
  /**
   * stdout split on "\\n" (trailing empty line dropped). stderr is NOT
   * line-streamed — it is collected and surfaced on exit.
   */
  onStdoutLine(cb: (line: string) => void): void;
  onExit(cb: (code: number | null) => void): void;
  /** End stdin, cgroup.kill the leaf (whole tree), rmdir; idempotent. */
  kill(): Promise<void>;
}

export interface SpawnRequest {
  /** argv ONLY — no shell, no checkCommandPolicy (see module doc). */
  argv: string[];
  cwd?: string;
  env?: Record<string, string>;
}

export async function spawnLongRunning(
  ctx: JailContext,
  req: SpawnRequest,
): Promise<SpawnedProcess> {
  if (!Array.isArray(req.argv) || req.argv.length === 0) {
    throw new Error("SpawnRequest.argv must be a non-empty array");
  }

  const id = randomBytes(6).toString("hex");
  const leafPath = await ctx.cgroups.createLeaf(ctx.uid, `spawn-${id}`);
  const spec: JailSpec = {
    rootfs: ctx.rootfs,
    workspaceDir: ctx.workspaceDir,
    homeDir: ctx.homeDir,
    etcDir: ctx.etcDir,
    cwd: req.cwd,
    env: req.env,
    argv: req.argv,
  };

  let child: ChildProcessLike;
  try {
    child = ctx.launcher.spawn(buildBwrapArgs(spec, ctx.config), {
      uid: ctx.uid,
      gid: ctx.uid,
      cgroupProcsFile: ctx.cgroups.procsFile(leafPath),
      cwd: ctx.workspaceDir,
    });
  } catch (err) {
    await teardownLeafQuietly(ctx, leafPath);
    throw err;
  }

  let finished = false;
  let lastExitCode: number | null = null;
  let killPromise: Promise<void> | undefined;
  const lineCbs: Array<(line: string) => void> = [];
  const exitCbs: Array<(code: number | null) => void> = [];
  let stdoutBuf = "";

  // stdin errors (EPIPE from an early-exiting child) must never crash the
  // worker — same reasoning as execOnce (fix-round I-2).
  child.stdin?.on("error", () => {});

  child.stdout?.on("data", (chunk: Buffer) => {
    // Always split (partial-line state stays consistent for a consumer that
    // registers late); lines emitted while no callback is attached are gone —
    // onStdoutLine is a live subscription, not a replay.
    stdoutBuf += chunk.toString("utf8");
    const parts = stdoutBuf.split("\n");
    stdoutBuf = parts.pop() ?? ""; // trailing partial (or empty) stays buffered
    for (const line of parts) {
      for (const cb of lineCbs) cb(line);
    }
  });

  // stderr is drained (a full pipe would stall the child) but not
  // line-streamed; it is surfaced when the process exits.
  let stderrKept = 0;
  let stderrTruncated = false;
  const stderrChunks: Buffer[] = [];
  child.stderr?.on("data", (chunk: Buffer) => {
    if (stderrKept < SPAWN_STDERR_CAP_BYTES) {
      const keep = chunk.subarray(0, SPAWN_STDERR_CAP_BYTES - stderrKept);
      stderrChunks.push(keep);
      stderrKept += keep.length;
      if (keep.length < chunk.length) stderrTruncated = true;
    } else {
      stderrTruncated = true;
    }
  });

  let resolveExit: () => void = () => {};
  const exitSettled = new Promise<void>((resolve) => {
    resolveExit = resolve;
  });

  const finish = (code: number | null): void => {
    if (finished) return;
    finished = true;
    lastExitCode = code;
    void teardownLeafQuietly(ctx, leafPath).finally(() => {
      const stderrText = Buffer.concat(stderrChunks).toString("utf8");
      if (stderrText.length > 0) {
        console.error(
          `spawn-${id} stderr${stderrTruncated ? " (truncated)" : ""}:\n${stderrText}`,
        );
      }
      for (const cb of exitCbs) cb(code);
      resolveExit();
    });
  };

  child.once("exit", (code) => finish(code));
  child.once("error", () => finish(null));

  return {
    id,
    pid: child.pid,
    writeLine: (line: string) => {
      if (finished) return;
      const data = line.endsWith("\n") ? line : `${line}\n`;
      try {
        child.stdin?.write(Buffer.from(data, "utf8"));
      } catch {
        // already-destroyed stream — the child's exit code is the contract
      }
    },
    onStdoutLine: (cb) => {
      lineCbs.push(cb);
    },
    onExit: (cb) => {
      // A fast-exiting child may finish before the first registration.
      if (finished) cb(lastExitCode);
      else exitCbs.push(cb);
    },
    kill: () => {
      if (killPromise !== undefined) return killPromise;
      killPromise = (async () => {
        try {
          child.stdin?.end();
        } catch {
          // already gone
        }
        try {
          await ctx.cgroups.kill(leafPath); // whole tree, removes the leaf
        } catch (err) {
          if (!isErrnoException(err) || err.code !== "ENOENT") {
            console.error(`spawn-${id} kill: leaf kill failed for ${leafPath}:`, err);
          }
        }
        try {
          child.kill("SIGKILL"); // belt under the tree kill
        } catch {
          // already gone
        }
        await exitSettled; // the exit cb fires before kill() resolves
      })();
      return killPromise;
    },
  };
}
