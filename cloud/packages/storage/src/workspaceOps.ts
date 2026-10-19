/**
 * Studio file management over the WARM agent workspace (Wave 2, ST-008):
 * delete, move/rename and mkdir. Same trust model and jail as
 * `writeWorkspaceFile` (hydrate.ts):
 *
 *  - every path goes through `assertSafeRelPath` (no absolute, no `..`, no
 *    empty/root path);
 *  - the PARENT of every touched path must realpath inside the workspace, so
 *    a symlinked folder can never redirect a delete/rename outside it;
 *  - the leaf itself is never followed: deleting a symlink removes the link,
 *    not its target;
 *  - a missing workspace dir is "not_warm" (the gateway hydrates first, the
 *    same contract as writes).
 *
 * Mutations are deliberately non-clobbering: a move never replaces an
 * existing destination and mkdir never turns a file into a folder
 * (PreconditionFailedError "already_exists"). A folder delete needs an
 * explicit `recursive` (else "not_empty") — the Studio confirm dialog is the
 * one place that sets it.
 */

import { link, lstat, mkdir, readdir, realpath, rename, rm, stat } from "node:fs/promises";
import { dirname, join } from "node:path";

import type { ActivityTracker } from "./activity.js";
import { KeyLayoutError, NotFoundError, PreconditionFailedError, WorkspaceStateError } from "./errors.js";
import { assertParentInsideWorkspace } from "./hydrate.js";
import { withWorkspaceMutation } from "./workspaceMutationLock.js";
import { assertSafeRelPath } from "./keys.js";
import { resolveWorkspaceDir, type SandboxUidResolver } from "./workspacePaths.js";

export interface WorkspaceOpsDeps {
  sandboxUid: SandboxUidResolver;
  workspacesRoot: string;
  activity: ActivityTracker;
}

export interface WorkspaceOpsRef {
  userId: string;
  sessionId: string;
}

export type WorkspaceNodeKind = "file" | "dir" | "symlink";

async function lstatOrNull(p: string): Promise<Awaited<ReturnType<typeof lstat>> | null> {
  try {
    return await lstat(p);
  } catch {
    return null;
  }
}

/** The warm workspace dir + its realpath, or "not_warm" when it is absent. */
async function warmRoot(
  dir: string,
  ref: WorkspaceOpsRef,
): Promise<{ realDir: string }> {
  let isDir = false;
  try {
    isDir = (await stat(dir)).isDirectory();
  } catch {
    isDir = false;
  }
  if (!isDir) {
    throw new WorkspaceStateError(
      `workspace ${ref.sessionId} is not warm — hydrate before changing files`,
      { code: "not_warm" },
    );
  }
  return { realDir: await realpath(dir) };
}

function kindOf(st: Awaited<ReturnType<typeof lstat>>): WorkspaceNodeKind {
  if (st.isSymbolicLink()) return "symlink";
  if (st.isDirectory()) return "dir";
  return "file";
}

/** Delete one file, symlink or (with `recursive`) folder. */
export async function deleteWorkspacePath(
  deps: WorkspaceOpsDeps,
  ref: WorkspaceOpsRef & { path: string },
  opts: { recursive?: boolean } = {},
): Promise<{ path: string; type: WorkspaceNodeKind }> {
  const rel = assertSafeRelPath(ref.path);
  const dir = await resolveWorkspaceDir(deps.sandboxUid, deps.workspacesRoot, ref.userId, ref.sessionId);
  const full = join(dir, rel);
  return withWorkspaceMutation([full], async () => {
    const { realDir } = await warmRoot(dir, ref);
    await assertParentInsideWorkspace(realDir, dirname(full));
    const st = await lstatOrNull(full);
    if (st === null) {
      throw new NotFoundError(`'${rel}' is not present in the workspace`);
    }
    const type = kindOf(st);
    if (type === "dir") {
      if (opts.recursive !== true && (await readdir(full)).length > 0) {
        throw new PreconditionFailedError(`'${rel}' is not empty`, { code: "not_empty" });
      }
      await rm(full, { recursive: true });
    } else {
      // rm on a symlink unlinks the link itself (never its target).
      await rm(full);
    }
    await deps.activity.bump(ref.sessionId);
    return { path: rel, type };
  });
}

/** Move/rename a file or folder. Never overwrites the destination. */
export async function moveWorkspacePath(
  deps: WorkspaceOpsDeps,
  ref: WorkspaceOpsRef & { from: string; to: string },
): Promise<{ from: string; to: string }> {
  const from = assertSafeRelPath(ref.from);
  const to = assertSafeRelPath(ref.to);
  if (from === to) {
    throw new KeyLayoutError("source and destination are the same path");
  }
  if (to.startsWith(`${from}/`)) {
    throw new KeyLayoutError("a folder cannot be moved into itself");
  }
  const dir = await resolveWorkspaceDir(deps.sandboxUid, deps.workspacesRoot, ref.userId, ref.sessionId);
  const src = join(dir, from);
  const dest = join(dir, to);
  return withWorkspaceMutation([src, dest], async () => {
    const { realDir } = await warmRoot(dir, ref);
    await assertParentInsideWorkspace(realDir, dirname(src));
    await assertParentInsideWorkspace(realDir, dirname(dest));
    const st = await lstatOrNull(src);
    if (st === null) {
      throw new NotFoundError(`'${from}' is not present in the workspace`);
    }
    if ((await lstatOrNull(dest)) !== null) {
      throw new PreconditionFailedError(`'${to}' already exists`, { code: "already_exists" });
    }
    await mkdir(dirname(dest), { recursive: true });
    if (st.isDirectory()) {
      // The lock protects the destination check from other Studio mutations
      // in this process; rename is not no-clobber against external writers.
      await rename(src, dest);
    } else {
      // Files and symlinks: link(2) is an atomic no-clobber create (EEXIST),
      // then the old name goes.
      try {
        await link(src, dest);
      } catch (err) {
        if ((err as NodeJS.ErrnoException).code === "EEXIST") {
          throw new PreconditionFailedError(`'${to}' already exists`, { code: "already_exists" });
        }
        throw err;
      }
      await rm(src);
    }
    await deps.activity.bump(ref.sessionId);
    return { from, to };
  });
}

/** Create a folder (and its parents). Idempotent for an existing folder. */
export async function makeWorkspaceDir(
  deps: WorkspaceOpsDeps,
  ref: WorkspaceOpsRef & { path: string },
): Promise<{ path: string; created: boolean }> {
  const rel = assertSafeRelPath(ref.path);
  const dir = await resolveWorkspaceDir(deps.sandboxUid, deps.workspacesRoot, ref.userId, ref.sessionId);
  const full = join(dir, rel);
  return withWorkspaceMutation([full], async () => {
    const { realDir } = await warmRoot(dir, ref);
    await assertParentInsideWorkspace(realDir, dirname(full));
    const st = await lstatOrNull(full);
    if (st !== null) {
      if (st.isDirectory()) return { path: rel, created: false };
      throw new PreconditionFailedError(`'${rel}' already exists`, { code: "already_exists" });
    }
    await mkdir(full, { recursive: true });
    await deps.activity.bump(ref.sessionId);
    return { path: rel, created: true };
  });
}
