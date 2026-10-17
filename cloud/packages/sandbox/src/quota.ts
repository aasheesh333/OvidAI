import { execFile } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { statfs } from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

/** statfs magic for XFS ("XFSB"). */
const XFS_MAGIC = 0x58465342;

/**
 * Per-user workspace/store quotas (P2 Task 8). Two backends:
 * - "xfs": the production path — XFS project quotas on the dedicated
 *   /workspaces volume (Task 16 setup-workspaces.sh mounts it prjquota).
 * - "noop": every other filesystem — quotas are NOT enforced; capacity is
 *   guarded only by the admission gate and the disk-pressure guard.
 *   selectQuotaBackend warns (once) when it picks this.
 */
export interface QuotaBackend {
  readonly kind: "xfs" | "noop";
  /**
   * Tag `path`'s subtree with `projectId` and set that project's hard limit
   * to `hardBytes`. Idempotent (re-applying re-asserts both).
   */
  applyQuota(path: string, projectId: number, hardBytes: number): Promise<void>;
}

/** The workspace project id for a sandbox uid — the PER-USER quota key. */
export function workspaceProjectId(uid: number): number {
  return uid;
}

/** The package-cache project id for a sandbox uid (separate keyspace). */
export function cacheProjectId(uid: number): number {
  return uid + 100_000;
}

export function createNoopQuotaBackend(): QuotaBackend {
  return {
    kind: "noop",
    async applyQuota(_path: string, _projectId: number, _hardBytes: number): Promise<void> {
      // Deliberately inert: the workspace/store dirs still exist and work;
      // only the byte limits are unenforced (selectQuotaBackend's warning
      // covers the operational consequence).
    },
  };
}

/**
 * The XFS backend. `mountPoint` is the quota-bearing mount (the workspaces
 * root's filesystem); chproj tags the subtree, xfs_quota sets the limit.
 *
 * Both tools are resolved via PATH at call time (their presence was probed
 * at selection). Byte values are passed bare — xfs_quota interprets a bare
 * block-limit value as bytes (k/m/g/t suffixes scale it); this convention is
 * re-verified at the Task 16 activation gate, the first place a real XFS
 * prjquota volume exists.
 */
function createXfsQuotaBackend(mountPoint: string): QuotaBackend {
  return {
    kind: "xfs",
    async applyQuota(path: string, projectId: number, hardBytes: number): Promise<void> {
      // 1. Tag the subtree with the project id (inheritable down the tree).
      await execFileAsync("xfs_io", ["-c", `chproj -r ${projectId}`, path]);
      // 2. Set the project's hard block limit (bytes).
      await execFileAsync("xfs_quota", [
        "-x",
        "-c",
        `limit -p bhard=${hardBytes} ${projectId}`,
        mountPoint,
      ]);
    },
  };
}

/** True when `name` is executable somewhere on PATH or in the sbin fallbacks. */
function binaryAvailable(name: string): boolean {
  const dirs = [
    ...(process.env.PATH ?? "").split(":").filter(Boolean),
    "/usr/sbin",
    "/sbin",
  ];
  return dirs.some((d) => {
    try {
      accessSync(join(d, name), constants.X_OK);
      return true;
    } catch {
      return false;
    }
  });
}

let noopWarned = false;

/**
 * XFS (statfs magic 0x58465342) + the xfs_quota/xfs_io binaries → the XFS
 * backend; anything else → the noop backend with a single log-once warning
 * (per process) so a mis-provisioned volume is visible without spamming.
 */
export async function selectQuotaBackend(workspacesRoot: string): Promise<QuotaBackend> {
  const probe = await statfs(workspacesRoot);
  if (probe.type === XFS_MAGIC && binaryAvailable("xfs_quota") && binaryAvailable("xfs_io")) {
    return createXfsQuotaBackend(workspacesRoot);
  }
  if (!noopWarned) {
    noopWarned = true;
    console.warn(
      `sandbox quotas: ${workspacesRoot} is not an XFS prjquota volume with the xfs tools ` +
        `(fstype 0x${probe.type.toString(16)}${probe.type === XFS_MAGIC ? ", xfs_quota/xfs_io binary missing" : ""}) — ` +
        `using the NOOP quota backend: per-user workspace/store quotas are NOT enforced ` +
        `(capacity is guarded only by admission + disk pressure).`,
    );
  }
  return createNoopQuotaBackend();
}
