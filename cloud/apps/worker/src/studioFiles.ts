import { constants as FS_CONSTANTS } from "node:fs";
import {
  lstat,
  open,
  readdir,
  realpath,
  type FileHandle,
} from "node:fs/promises";
import { resolve } from "node:path";

import { safeRelDir, StudioGitError } from "./studioGit.js";
export type { StudioPathSearchItem, StudioPathSearchResult } from "./studioGit.js";

const DIRECTORY_FLAGS = FS_CONSTANTS.O_RDONLY | FS_CONSTANTS.O_DIRECTORY | FS_CONSTANTS.O_NOFOLLOW;
const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 100;
const MAX_SCANNED_ENTRIES = 20_000;
const MAX_DEPTH = 64;
const SEARCH_TIMEOUT_MS = 10_000;

export interface WorkspacePathSearchRequest {
  workspaceDir: string;
  repoDir: string;
  query: string;
  limit?: number;
}

export interface WorkspacePathSearchResult {
  items: Array<{ path: string; name: string }>;
  truncated: boolean;
}

function boundedLimit(value: number | undefined): number {
  if (value === undefined || !Number.isFinite(value)) return DEFAULT_LIMIT;
  return Math.min(MAX_LIMIT, Math.max(1, Math.floor(value)));
}

/** NFKC + lowercase handles canonical/case variants; these are full-fold exceptions. */
function fold(value: string): string {
  return value
    .normalize("NFKC")
    .toLowerCase()
    .replace(/ß/g, "ss")
    .replace(/ς/g, "σ")
    .normalize("NFKC");
}

function compareText(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

function invalidPath(): never {
  throw new StudioGitError("invalid_path", "That folder is outside the workspace.");
}

async function openDirectory(path: string): Promise<FileHandle> {
  let handle: FileHandle;
  try {
    handle = await open(path, DIRECTORY_FLAGS);
  } catch (err) {
    if (err instanceof Error && "code" in err) {
      const code = (err as NodeJS.ErrnoException).code;
      if (["ELOOP", "ENOTDIR", "ENOENT"].includes(code ?? "")) invalidPath();
    }
    throw err;
  }
  const stat = await handle.stat();
  if (!stat.isDirectory()) {
    await handle.close();
    invalidPath();
  }
  return handle;
}

/**
 * Searches only regular files below a descriptor-pinned workspace/repo root.
 * Returned paths are workspace-relative so they can be passed to workspace file
 * APIs directly. Matching uses the path relative to repoDir.
 */
export async function searchWorkspacePaths(
  req: WorkspacePathSearchRequest,
): Promise<WorkspacePathSearchResult> {
  const repoDir = safeRelDir(req.repoDir);
  if (Buffer.byteLength(repoDir, "utf8") > 4096 || repoDir.split("/").includes(".git")) {
    invalidPath();
  }
  const limit = boundedLimit(req.limit);
  const handles: FileHandle[] = [];
  let outcome: WorkspacePathSearchResult | undefined;
  let failure: unknown;

  try {
    const workspacePath = await realpath(resolve(req.workspaceDir));
    let directory = await openDirectory(workspacePath);
    handles.push(directory);
    if (repoDir !== ".") {
      for (const part of repoDir.split("/")) {
        directory = await openDirectory(`/proc/self/fd/${directory.fd}/${part}`);
        handles.push(directory);
      }
    }

    const root = directory;
    const foldedQuery = fold(req.query);
    const matches: Array<{ path: string; name: string }> = [];
    const deadline = Date.now() + SEARCH_TIMEOUT_MS;
    let scanned = 0;
    let truncated = false;

    const walk = async (parent: FileHandle, relative: string, depth: number): Promise<void> => {
      if (truncated) return;
      if (depth > MAX_DEPTH || Date.now() >= deadline) {
        truncated = true;
        return;
      }
      const entries = await readdir(`/proc/self/fd/${parent.fd}`, { withFileTypes: true });
      entries.sort((left, right) => compareText(left.name, right.name));
      for (const entry of entries) {
        if (truncated) return;
        if (Date.now() >= deadline || scanned >= MAX_SCANNED_ENTRIES) {
          truncated = true;
          return;
        }
        scanned += 1;
        if (entry.name === ".git") continue;
        const childRelative = relative === "" ? entry.name : `${relative}/${entry.name}`;
        if (Buffer.byteLength(childRelative, "utf8") > 4096) {
          truncated = true;
          continue;
        }
        const childPath = `/proc/self/fd/${parent.fd}/${entry.name}`;
        let stat;
        try {
          stat = await lstat(childPath);
        } catch (err) {
          if (err instanceof Error && "code" in err && (err as NodeJS.ErrnoException).code === "ENOENT") {
            continue;
          }
          throw err;
        }
        if (stat.isSymbolicLink()) continue;
        if (stat.isFile()) {
          if (fold(childRelative).includes(foldedQuery)) {
            matches.push({
              path: repoDir === "." ? childRelative : `${repoDir}/${childRelative}`,
              name: entry.name,
            });
            if (matches.length > limit) {
              truncated = true;
              return;
            }
          }
          continue;
        }
        if (!stat.isDirectory()) continue;

        const child = await openDirectory(childPath);
        try {
          const opened = await child.stat();
          if (opened.dev !== stat.dev || opened.ino !== stat.ino) continue;
          await walk(child, childRelative, depth + 1);
        } finally {
          await child.close();
        }
      }
    };

    await walk(root, "", 0);
    matches.sort((left, right) =>
      compareText(fold(left.path), fold(right.path)) || compareText(left.path, right.path),
    );
    outcome = { items: matches.slice(0, limit), truncated };
  } catch (err) {
    failure = err instanceof StudioGitError
      ? err
      : new StudioGitError("search_failed", "Could not search workspace files. Retry it.");
  }

  let closeFailed = false;
  for (const handle of handles.reverse()) {
    try {
      await handle.close();
    } catch {
      closeFailed = true;
    }
  }
  if (failure !== undefined) throw failure;
  if (closeFailed) {
    throw new StudioGitError("search_failed", "Could not finish searching workspace files. Retry it.");
  }
  return outcome!;
}
