import { randomBytes } from "node:crypto";
import { BASE_JAIL_ENV, buildBwrapArgs, type JailSpec } from "./invocation.js";
import { createChunkRing, PTY_SCROLLBACK_BYTES, type ChunkRing, type RingChunk } from "./ring.js";
import type { JailContext } from "./types.js";

/**
 * PTY sessions (P2 Task 9): an interactive `/bin/bash` behind the bwrap jail,
 * spawned on a pty master via {@link JailLauncher.spawnPty} so the payload has
 * a real controlling terminal (tty, stty, interactive tools). Output flows
 * into a 256 KB scrollback ring (spec §6.2) for incremental reads.
 *
 * PTY sessions are the INTERACTIVE surface only. They are deliberately NOT
 * used for stdio MCP (gap G3 / P5's SandboxSpawner): a tty echoes input and
 * translates LF to CRLF, which corrupts JSON-RPC lines — that path uses
 * `spawnLongRunning` with pipes instead.
 */

export interface PtyRequest {
  sessionId: string;
  /** Default 80, clamped to 1..500. */
  cols?: number;
  /** Default 24. */
  rows?: number;
  /** Merged over BASE_JAIL_ENV inside the jail (TERM is pinned from it). */
  env?: Record<string, string>;
}

export interface PtyHandlers {
  /** Live output push: one per pty data event (the chunk is ring-pushed). */
  onData(chunk: RingChunk): void;
  /** Fired once when the pty payload exits. */
  onExit(exitCode: number | null): void;
}

export interface PtySession {
  readonly id: string;
  readonly sessionId: string;
  /** Scrollback ring, cap PTY_SCROLLBACK_BYTES. */
  readonly ring: ChunkRing;
  /** Writes UTF-8 text to the pty master (the payload sees keyboard input). */
  write(data: Buffer): void;
  resize(cols: number, rows: number): void;
  /** cgroup.kill the leaf (whole tree) + pty kill; idempotent. */
  kill(): Promise<void>;
  /** Resolves with the payload's exit code (null when signalled/unknown). */
  readonly exit: Promise<number | null>;
  readonly alive: boolean;
}

/** Terminal dimension bounds (node-pty rejects nonsense; clamp, don't throw). */
const MAX_DIM = 500;

function clampDim(v: number | undefined, fallback: number): number {
  const n = v ?? fallback;
  if (!Number.isFinite(n)) return fallback;
  return Math.min(MAX_DIM, Math.max(1, Math.round(n)));
}

function isErrnoException(err: unknown): err is NodeJS.ErrnoException {
  return err instanceof Error && "code" in err;
}

/** Tolerates a leaf that is already gone (the kill path removes it). */
async function killLeafQuietly(ctx: JailContext, leafPath: string): Promise<void> {
  try {
    await ctx.cgroups.kill(leafPath);
  } catch (err) {
    if (isErrnoException(err) && err.code === "ENOENT") return;
    console.error(`pty session: leaf teardown failed for ${leafPath}:`, err);
  }
}

export async function createPtySession(
  ctx: JailContext,
  req: PtyRequest,
  handlers: PtyHandlers,
): Promise<PtySession> {
  const id = randomBytes(6).toString("hex");
  const cols = clampDim(req.cols, 80);
  const rows = clampDim(req.rows, 24);
  const ring = createChunkRing(PTY_SCROLLBACK_BYTES);

  const spec: JailSpec = {
    rootfs: ctx.rootfs,
    workspaceDir: ctx.workspaceDir,
    homeDir: ctx.homeDir,
    etcDir: ctx.etcDir,
    // TERM is pinned from BASE_JAIL_ENV — the jail env is the single source of
    // truth for the payload's terminal type, not the caller.
    env: { ...req.env, TERM: BASE_JAIL_ENV.TERM },
    argv: ["/bin/bash"],
  };

  const leafPath = await ctx.cgroups.createLeaf(ctx.uid, `pty-${id}`);
  let exited = false;
  let killPromise: Promise<void> | undefined;
  let resolveExit: (code: number | null) => void = () => {};
  const exit = new Promise<number | null>((resolve) => {
    resolveExit = resolve;
  });

  let child;
  try {
    child = ctx.launcher.spawnPty(buildBwrapArgs(spec, ctx.config), {
      uid: ctx.uid,
      gid: ctx.uid,
      cgroupProcsFile: ctx.cgroups.procsFile(leafPath),
      cwd: ctx.workspaceDir,
      cols,
      rows,
    });
  } catch (err) {
    // Zero side effects on a failed spawn: the just-created leaf goes away.
    await ctx.cgroups.remove(leafPath).catch(() => {});
    throw err;
  }

  child.onData((data: string) => {
    handlers.onData(ring.push(Buffer.from(data, "utf8")));
  });

  child.onExit((e: { exitCode: number; signal?: number }) => {
    if (exited) return;
    exited = true;
    const code = typeof e.exitCode === "number" ? e.exitCode : null;
    // The payload (and its whole tree) is gone; drain+remove the leaf.
    killLeafQuietly(ctx, leafPath).finally(() => resolveExit(code));
    handlers.onExit(code);
  });

  return {
    id,
    sessionId: req.sessionId,
    ring,
    write: (data: Buffer) => {
      if (!exited) child.write(data.toString("utf8"));
    },
    resize: (c: number, r: number) => {
      if (!exited) child.resize(clampDim(c, 80), clampDim(r, 24));
    },
    kill: () => {
      if (killPromise !== undefined) return killPromise;
      killPromise = (async () => {
        // Tree-kill the leaf first (cgroup.kill removes it), then signal the
        // pty child as a belt — a wedged master must not wedge the caller.
        await killLeafQuietly(ctx, leafPath);
        try {
          child.kill("SIGKILL");
        } catch {
          // already gone
        }
        await exit;
      })();
      return killPromise;
    },
    get alive(): boolean {
      return !exited;
    },
    exit,
  };
}
