/**
 * The P2 → @ovid/mcp sandbox seam (P5 Task 16).
 *
 * This is the ONLY app file that constructs the P2-backed
 * `{ spawner, files }` pair the router/installer consume. It absorbs the
 * interface drift between the two packages:
 *
 * - P2's `SandboxManager.attach(userId)` owns the per-user jail. Its
 *   `handle.workspaceDir` is the HOST path for `{workspacesRoot}/{uid}/workspace`;
 *   @ovid/mcp's file seam speaks JAIL paths rooted at `/workspace`. Every
 *   file operation here maps `/workspace/...` onto `handle.workspaceDir/...`
 *   (through the worker's confinement helper, so `..`/symlink escapes are
 *   refused before any host access).
 * - P2's one-shot `handle.exec` takes `{command}` (bash -c) or `{argv}`
 *   (exec'd directly). @ovid/mcp's installer speaks `{command, args}` — the
 *   adapter passes `argv: [command, ...args]` so no shell is involved.
 * - P2's `ExecResult` reports `blocked`/`timedOut` instead of an exit code;
 *   the adapter maps those to NON-ZERO (`blocked` → 126 with the refusal,
 *   killed/timed-out → -1) so the installer's `failed()` check cannot read a
 *   refusal as success.
 * - P2's long-lived `handle.spawnProcess({argv})` is the stdio-MCP backing;
 *   it is structurally the @ovid/mcp `SandboxedProcess`, so it is returned
 *   unchanged.
 *
 * `createUnavailableSandbox()` is the null-sandbox fallback: every call
 * rejects `SandboxUnavailableError` (`code: "sandbox_unavailable"`) so
 * curated fetch/REST/GitHub tools keep working while stdio/filesystem/memory
 * tools and plugin installs fail cleanly.
 */

import { chown, lstat, mkdir, readFile, readdir, realpath, rm, stat as statPath, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { REFUSAL_MESSAGE, type SandboxHandle, type SandboxManager } from "@ovid/sandbox";
import {
  WORKSPACE_ROOT,
  type SandboxExecRequest,
  type SandboxExecResult,
  type SandboxFiles,
  type SandboxSpawner,
  type WorkspaceEntry,
} from "@ovid/mcp";
import { resolveConfined } from "./tools/confinement.js";

/** The pair the router and installer consume. */
export interface SandboxSeam {
  spawner: SandboxSpawner;
  files: SandboxFiles;
}

export interface SandboxSeamDeps {
  /** The worker's composed P2 manager (main.ts owns the rootfs/cgroup boot). */
  manager: SandboxManager;
  /** Workspace quota tier for attach(); defaults to the manager's own default. */
  tierFor?: (uid: string) => "free" | "pro" | Promise<"free" | "pro">;
}

/** Every sandbox-dependent call fails with this when no sandbox is wired. */
export class SandboxUnavailableError extends Error {
  readonly code = "sandbox_unavailable";

  constructor(message = "sandbox_unavailable: the MCP sandbox is not available in this worker") {
    super(message);
    this.name = "SandboxUnavailableError";
  }
}

function isErrnoException(err: unknown): err is NodeJS.ErrnoException {
  return err instanceof Error && "code" in err;
}

function isMissing(err: unknown): boolean {
  return isErrnoException(err) && (err.code === "ENOENT" || err.code === "EISDIR");
}

/** Best-effort ownership hand-off to the jailed uid (the worker runs as root
 *  in production; a non-root test harness owns the tree already). */
async function chownQuiet(path: string, uid: number): Promise<void> {
  try {
    await chown(path, uid, uid);
  } catch {
    // EPERM in a non-root test harness — the caller already owns the tree.
  }
}

/** Map a jail-internal path onto the handle's host workspace directory. */
async function hostPath(handle: SandboxHandle, jailPath: string): Promise<string> {
  if (jailPath === WORKSPACE_ROOT || jailPath === `${WORKSPACE_ROOT}/`) {
    return handle.workspaceDir;
  }
  // resolveConfined accepts "/workspace/…" and workspace-relative paths and
  // rejects anything that escapes the root (including via symlinks).
  return resolveConfined(handle.workspaceDir, jailPath);
}

/**
 * Map a workspace-relative cwd onto the jail-absolute cwd P2's exec/spawn
 * expects (the same rule as sandboxAdapter.ts's `jailCwd`): absolute values
 * pass through untouched; relative values are rooted at /workspace. Empty
 * means "P2's default", so it is omitted from the request.
 */
function jailCwd(cwd?: string): string | undefined {
  if (cwd === undefined || cwd === "") return undefined;
  if (cwd.startsWith("/")) return cwd;
  return `${WORKSPACE_ROOT}/${cwd}`;
}

function mapExecResult(res: {
  exitCode: number | null;
  stdout: string;
  stderr: string;
  blocked: boolean;
  timedOut: boolean;
  refusal: string | null;
}): SandboxExecResult {
  if (res.blocked) {
    // A layer-1 refusal never spawned; a non-zero code is what the
    // installer's failure check understands.
    return { exitCode: 126, stdout: res.stdout, stderr: res.refusal ?? REFUSAL_MESSAGE };
  }
  // timedOut ⇒ exitCode null; -1 keeps "killed" from reading as success.
  return { exitCode: res.exitCode ?? -1, stdout: res.stdout, stderr: res.stderr };
}

/**
 * Adapt the worker's composed P2 SandboxManager onto the @ovid/mcp seam.
 * Callers that have not composed a manager yet should pass `null` to
 * `createMcpRuntime` instead of calling this.
 */
export function createSandboxSeam(deps: SandboxSeamDeps): SandboxSeam {
  async function handleFor(uid: string): Promise<SandboxHandle> {
    const tier = deps.tierFor === undefined ? undefined : await deps.tierFor(uid);
    return deps.manager.attach(uid, tier === undefined ? undefined : { tier });
  }

  const spawner: SandboxSpawner = {
    async spawn(uid, req) {
      const handle = await handleFor(uid);
      const cwd = jailCwd(req.cwd);
      // P2's long-lived primitive is structurally SandboxedProcess.
      return handle.spawnProcess({
        argv: [req.command, ...req.args],
        ...(cwd !== undefined ? { cwd } : {}),
        ...(req.env !== undefined ? { env: req.env } : {}),
      });
    },
  };

  const files: SandboxFiles = {
    async read(uid, path) {
      const handle = await handleFor(uid);
      const abs = await hostPath(handle, path);
      try {
        const buf = await readFile(abs);
        return { content: buf.toString("utf8"), bytes: buf.byteLength };
      } catch (err) {
        if (isMissing(err)) return null;
        throw err;
      }
    },

    async write(uid, path, content) {
      const handle = await handleFor(uid);
      const abs = await hostPath(handle, path);
      await mkdir(dirname(abs), { recursive: true });
      await writeFile(abs, content, "utf8");
      await chownQuiet(abs, handle.uid);
    },

    async list(uid, dir): Promise<WorkspaceEntry[]> {
      const handle = await handleFor(uid);
      const abs = await hostPath(handle, dir);
      const entries = await readdir(abs, { withFileTypes: true });
      const out: WorkspaceEntry[] = [];
      for (const entry of entries) {
        // M9: lstat (not stat) — a symlink must never be reported as a
        // directory. `search_files` recurses on type === "dir", so a
        // symlink-to-parent would otherwise become an unbounded walk. Links
        // are skipped entirely (they are not workspace content, and the
        // installer's archive validation already rejects them).
        const info = await lstat(join(abs, entry.name)).catch(() => null);
        if (info === null) continue; // dangling symlink / raced deletion
        if (info.isSymbolicLink()) continue;
        out.push({
          name: entry.name,
          type: info.isDirectory() ? "dir" : "file",
          size: info.size,
          mtime: info.mtime.toISOString(),
        });
      }
      return out;
    },

    async stat(uid, path) {
      const handle = await handleFor(uid);
      const abs = await hostPath(handle, path);
      try {
        const info = await statPath(abs);
        return {
          type: info.isDirectory() ? "dir" : "file",
          size: info.size,
          mtime: info.mtime.toISOString(),
        };
      } catch (err) {
        if (isMissing(err)) return null;
        throw err;
      }
    },

    async remove(uid, path) {
      const handle = await handleFor(uid);
      const abs = await hostPath(handle, path);
      // C1 defense-in-depth: never rm -rf the workspace root, whatever the
      // caller passed. Compare both the lexical path and the realpath (a
      // symlink resolving to the root must not delete through it).
      const rootReal = await realpath(handle.workspaceDir).catch(() => handle.workspaceDir);
      const absReal = await realpath(abs).catch(() => null);
      if (abs === handle.workspaceDir || absReal === rootReal) {
        throw new Error("refusing to delete the workspace root");
      }
      await rm(abs, { recursive: true, force: true });
    },

    async uploadDir(uid, localDir, remoteDir) {
      const handle = await handleFor(uid);
      const target = await hostPath(handle, remoteDir);
      await mkdir(target, { recursive: true });
      await chownQuiet(target, handle.uid);

      const walk = async (source: string, dest: string): Promise<void> => {
        const entries = await readdir(source, { withFileTypes: true });
        for (const entry of entries) {
          const from = join(source, entry.name);
          const to = join(dest, entry.name);
          if (entry.isDirectory()) {
            await mkdir(to, { recursive: true });
            await chownQuiet(to, handle.uid);
            await walk(from, to);
          } else if (entry.isFile()) {
            await writeFile(to, await readFile(from));
            await chownQuiet(to, handle.uid);
          }
          // Symlinks/devices are deliberately not copied: the installer's
          // archive validation has already rejected escaping entries, and a
          // staged tree is expected to be regular files/dirs.
        }
      };
      await walk(localDir, target);
    },

    async exec(uid, req: SandboxExecRequest): Promise<SandboxExecResult> {
      const handle = await handleFor(uid);
      const cwd = jailCwd(req.cwd);
      const result = await handle.exec({
        argv: [req.command, ...req.args],
        ...(cwd !== undefined ? { cwd } : {}),
        ...(req.env !== undefined ? { env: req.env } : {}),
        ...(req.timeoutMs !== undefined ? { timeoutMs: req.timeoutMs } : {}),
      });
      return mapExecResult(result);
    },
  };

  return { spawner, files };
}

/**
 * Null-sandbox fallback: every spawner/files call rejects with
 * `SandboxUnavailableError` (code `sandbox_unavailable`). Curated
 * fetch/REST/GitHub tools do not touch the sandbox and keep working.
 */
export function createUnavailableSandbox(): SandboxSeam {
  const reject = async (): Promise<never> => {
    throw new SandboxUnavailableError();
  };
  return {
    spawner: { spawn: reject },
    files: {
      read: reject,
      write: reject,
      list: reject,
      stat: reject,
      remove: reject,
      uploadDir: reject,
      exec: reject,
    },
  };
}
