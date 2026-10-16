import { randomBytes } from "node:crypto";
import { buildBwrapArgs, type JailSpec } from "./invocation.js";
import { quote } from "shell-quote";
import { checkCommandPolicy, REFUSAL_MESSAGE } from "./policy.js";
import type { Readable } from "node:stream";
import {
  EXEC_OUTPUT_CAP_BYTES,
  EXEC_TIMEOUT_DEFAULT_MS,
  EXEC_TIMEOUT_MAX_MS,
  type ExecRequest,
  type ExecResult,
  type JailContext,
} from "./types.js";

/**
 * One-shot jail execution (P2 Task 7): policy gate → cgroup leaf →
 * sandbox-enter launcher spawn → capped, timeout'd output collection.
 *
 * Pinned semantics:
 * - `argv` requests are normalized to a policy-checkable command string via
 *   shell-quote words (structure preserved — quotes keep one argv word one
 *   shell word), then `checkCommandPolicy` runs on the join.
 * - A blocked request returns `{blocked:true, refusal:REFUSAL_MESSAGE}` with
 *   ZERO side effects: no cgroup leaf is created and the launcher is never
 *   called (Review Focus #1).
 * - The launcher child self-attaches to the cgroup leaf BEFORE dropping
 *   privileges (research §3 ordering — sandbox-enter.sh body).
 * - Output is capped at `maxOutputBytes ?? EXEC_OUTPUT_CAP_BYTES`; the stream
 *   keeps draining past the cap (discarding) so the child never stalls, and
 *   `truncated` is set.
 * - Timeout is `min(timeoutMs ?? default, max)`; on fire the leaf is killed
 *   (cgroup.kill — the whole tree) and `timedOut` is set.
 * - finally: the leaf is removed and the launcher unlinks its argv scratch
 *   file on child exit.
 */

/** Monotonic per-context exec counter for leaf names exec-{n}-{rand}. */
const leafCounters = new WeakMap<JailContext, number>();

function nextLeafName(ctx: JailContext): string {
  const n = (leafCounters.get(ctx) ?? 0) + 1;
  leafCounters.set(ctx, n);
  return `exec-${n}-${randomBytes(4).toString("hex")}`;
}

function isErrnoException(err: unknown): err is NodeJS.ErrnoException {
  return err instanceof Error && "code" in err;
}

/** Tolerates a leaf that is already gone (timeout path: kill() removes it). */
async function removeLeafQuietly(ctx: JailContext, leaf: string): Promise<void> {
  try {
    await ctx.cgroups.remove(leaf);
  } catch (err) {
    if (isErrnoException(err) && err.code === "ENOENT") return;
    // EBUSY etc. (fix-round M-3): a payload that daemonized a descendant may
    // still hold the leaf. Tree-kill it, retry the removal once…
    await ctx.cgroups.kill(leaf).catch(() => {});
    try {
      await ctx.cgroups.remove(leaf);
    } catch (retryErr) {
      if (isErrnoException(retryErr) && retryErr.code === "ENOENT") return;
      // …and if it STILL fails, log and continue: teardown must never
      // replace a valid ExecResult with a rejection.
      console.error(`execOnce: leaf teardown failed for ${leaf}:`, retryErr);
    }
  }
}

/** Capped output collector: keeps the first `cap` bytes, drains the rest. */
function collectCapped(stream: Readable | null, cap: number) {
  const chunks: Buffer[] = [];
  let kept = 0;
  let total = 0;
  if (stream !== null) {
    // The listener stays attached past the cap — that IS the drain: without
    // it the child's pipe would fill and the child would stall forever.
    stream.on("data", (chunk: Buffer) => {
      total += chunk.length;
      if (kept < cap) {
        chunks.push(chunk);
        kept += chunk.length;
      }
    });
  }
  return {
    finish(): { text: string; truncated: boolean } {
      // The last kept chunk may cross the cap — slice to exactly `cap` bytes.
      const text = Buffer.concat(chunks).subarray(0, cap).toString("utf8");
      return { text, truncated: total > cap };
    },
  };
}

/** Assembles a {@link JailContext} from its parts (pure — no fs effects). */
export function makeJailContext(deps: {
  config: JailContext["config"];
  cgroups: JailContext["cgroups"];
  launcher: JailContext["launcher"];
  uid: number;
  rootfs: string;
  workspaceDir: string;
  homeDir: string;
  etcDir: string;
}): JailContext {
  return {
    config: deps.config,
    launcher: deps.launcher,
    cgroups: deps.cgroups,
    uid: deps.uid,
    rootfs: deps.rootfs,
    workspaceDir: deps.workspaceDir,
    homeDir: deps.homeDir,
    etcDir: deps.etcDir,
  };
}

export async function execOnce(ctx: JailContext, req: ExecRequest): Promise<ExecResult> {
  const hasCommand = req.command !== undefined;
  const hasArgv = req.argv !== undefined;
  if (hasCommand === hasArgv) {
    throw new Error(
      `ExecRequest must set exactly one of command or argv (got ${JSON.stringify({
        command: req.command,
        argv: req.argv,
      })})`,
    );
  }
  if (hasCommand && req.command!.trim() === "") {
    throw new Error("ExecRequest.command must be non-empty");
  }
  if (hasArgv && req.argv!.length === 0) {
    throw new Error("ExecRequest.argv must be non-empty");
  }

  // Normalize argv to a policy-checkable command string: shell-quote words,
  // joined — one argv element stays one shell word, so the layer-1 parser
  // sees exactly the structure the payload will execute.
  const command = hasArgv ? quote(req.argv!) : req.command!;
  const verdict = checkCommandPolicy(command);
  if (!verdict.allowed) {
    // Zero side effects (Review Focus #1): no leaf, no spawn, no files.
    return {
      exitCode: null,
      stdout: "",
      stderr: "",
      timedOut: false,
      truncated: false,
      blocked: true,
      refusal: REFUSAL_MESSAGE,
    };
  }

  const payload = hasArgv ? req.argv! : ["/bin/bash", "-c", req.command!];
  const spec: JailSpec = {
    rootfs: ctx.rootfs,
    workspaceDir: ctx.workspaceDir,
    homeDir: ctx.homeDir,
    etcDir: ctx.etcDir,
    cwd: req.cwd,
    env: req.env,
    argv: payload,
  };

  const leafName = nextLeafName(ctx);
  const leaf = await ctx.cgroups.createLeaf(ctx.uid, leafName);
  let timedOut = false;
  try {
    const child = ctx.launcher.spawn(buildBwrapArgs(spec, ctx.config), {
      uid: ctx.uid,
      gid: ctx.uid,
      cgroupProcsFile: ctx.cgroups.procsFile(leaf),
      cwd: ctx.workspaceDir,
    });

    if (req.stdin !== undefined && child.stdin !== null) {
      // EPIPE etc. must be swallowed deliberately (fix-round I-2): stdin
      // delivery is best-effort — a child that exits without reading its
      // stdin raises an async 'error' on the socket, and an unhandled one is
      // an uncaught exception in the worker. The child's exit code is the
      // contract, not stdin delivery.
      child.stdin.on("error", () => {});
      try {
        child.stdin.write(req.stdin);
        child.stdin.end();
      } catch {
        // Synchronous throw (already-destroyed stream) — same reasoning.
      }
    }

    const cap = req.maxOutputBytes ?? EXEC_OUTPUT_CAP_BYTES;
    const out = collectCapped(child.stdout, cap);
    const err = collectCapped(child.stderr, cap);

    const exit = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>(
      (resolve) => {
        child.once("exit", (code, signal) => resolve({ code, signal }));
        child.once("error", () => resolve({ code: null, signal: null }));
      },
    );
    const timeoutMs = Math.min(req.timeoutMs ?? EXEC_TIMEOUT_DEFAULT_MS, EXEC_TIMEOUT_MAX_MS);
    let timerHandle: NodeJS.Timeout | undefined;
    const timer = new Promise<"timeout">((resolve) => {
      timerHandle = setTimeout(resolve, timeoutMs, "timeout");
    });

    const winner = await Promise.race([exit.then(() => "exit" as const), timer]);
    if (winner === "exit") {
      clearTimeout(timerHandle);
      // One macrotask so trailing pipe data lands before we snapshot.
      await new Promise<void>((resolve) => setImmediate(resolve));
      const { code } = await exit;
      const o = out.finish();
      const e = err.finish();
      return {
        exitCode: code,
        stdout: o.text,
        stderr: e.text,
        timedOut: false,
        truncated: o.truncated || e.truncated,
        blocked: false,
        refusal: null,
      };
    }

    timedOut = true;
    // Tree-kill the leaf's processes (also removes the leaf); signal the
    // direct child as a belt. Do NOT wait for its exit — a wedged child must
    // not wedge the exec call.
    await ctx.cgroups.kill(leaf).catch(() => {});
    try {
      child.kill("SIGKILL");
    } catch {
      // already gone
    }
    const o = out.finish();
    const e = err.finish();
    return {
      exitCode: null,
      stdout: o.text,
      stderr: e.text,
      timedOut: true,
      truncated: o.truncated || e.truncated,
      blocked: false,
      refusal: null,
    };
  } finally {
    // Timeout path: kill() already removed the leaf (ENOENT tolerated).
    // Every other path: plain remove of the (now process-free) leaf.
    await removeLeafQuietly(ctx, leaf);
  }
}
