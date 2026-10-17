/**
 * The authoritative `SandboxEviction` seam built from P2's landed
 * `SandboxManager` surface (fix round 1, C3).
 *
 * Why this lives in P7 instead of `@ovid/sandbox`: P2's package lane exports
 * no enumeration/eviction seam. `SandboxManager` DOES export the two
 * primitives this needs — `destroy(userId)` (kill the env's jail/PTY/
 * background-job leaves and its cgroup, LEAVE workspace data on disk) and the
 * numeric-uid allocator the manager already owns. The only extra input is the
 * DB mapping userId/uid/sessionId, supplied by the worker composition.
 *
 * Enumeration is DISK-AUTHORITATIVE, never handle-only. An attached-handle
 * list (`manager.list()`) would omit every idle user; `reconcileWarmRegistry`
 * treats an authoritative list as complete and would close every warm row it
 * did not see. This adapter instead:
 *   1. reads the known (userId, numeric uid, sessionId) triples,
 *   2. stats each user's agent workspace `{root}/{uid}/workspace` (P2's
 *      `SandboxHandle.workspaceDir` — the directory the agent actually runs
 *      in), and
 *   3. emits one entry per SESSION whose user's workspace is present.
 * Sessions of one user share P2's per-user agent workspace, so they share the
 * same `bytes` and all appear warm together.
 *
 * `evictWorkspace(userId, sessionId)` is pack-safe: P2's `destroy` kills the
 * session's live leaves but never touches the workspace bytes (the hibernate
 * engine packs and deletes only after the upload verifies). Because P2 keys
 * environments by userId, this tears down the user's env — documented model
 * consequence of the per-user workspace.
 */

import { stat } from "node:fs/promises";

import type { SandboxEviction, WarmWorkspaceEntry } from "./hibernate.js";
import { du } from "./warmLru.js";
import { workspaceDir } from "./workspacePaths.js";

/** One session's mapping onto P2's numeric sandbox uid. */
export interface KnownSessionRef {
  userId: string;
  /** P2's numeric sandbox uid (`users.allocateSandboxUid`). */
  uid: number | string;
  sessionId: string;
}

/** The P2 surface this adapter needs. `destroy` leaves workspace data. */
export interface SandboxManagerEvictionSource {
  destroy(userId: string): Promise<void>;
}

export interface SandboxManagerEvictionDeps {
  workspacesRoot: string;
  manager: SandboxManagerEvictionSource;
  /**
   * The userId/uid/sessionId triples to enumerate. The worker supplies a
   * `users JOIN sessions` query; a session whose user has no allocated
   * sandbox_uid is omitted (its workspace cannot exist).
   */
  listKnownSessions(): Promise<KnownSessionRef[]>;
  /** Default: recursive regular-file bytes (`du`). */
  dirBytes?(dir: string): Promise<number>;
}

async function isDirectory(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isDirectory();
  } catch {
    return false;
  }
}

/**
 * Build the authoritative seam. Wire this in production; keep the noop only
 * for tests/dev that must not enumerate a shared workspace root.
 */
export function createSandboxManagerEviction(
  deps: SandboxManagerEvictionDeps,
): SandboxEviction {
  return {
    authoritative: true,

    async listWarmWorkspaces(): Promise<WarmWorkspaceEntry[]> {
      const sessions = await deps.listKnownSessions();

      // Group sessions by numeric uid: P2's agent workspace is per-user.
      const byUid = new Map<
        number,
        { userId: string; sessionIds: string[] }
      >();
      for (const ref of sessions) {
        const uid = Number(ref.uid);
        if (!Number.isInteger(uid) || uid <= 0) continue;
        const existing = byUid.get(uid);
        if (existing === undefined) {
          byUid.set(uid, { userId: ref.userId, sessionIds: [ref.sessionId] });
        } else {
          existing.sessionIds.push(ref.sessionId);
        }
      }

      const entries: WarmWorkspaceEntry[] = [];
      for (const [uid, group] of byUid) {
        // `workspaceDir` ignores sessionId by design (per-user workspace).
        const dir = workspaceDir(deps.workspacesRoot, uid, group.sessionIds[0]!);
        if (!(await isDirectory(dir))) continue;
        const bytes = await (deps.dirBytes ?? du)(dir);
        for (const sessionId of group.sessionIds) {
          entries.push({
            userId: group.userId,
            sessionId,
            bytes,
            // Activity is Postgres/Redis authority; the seam only sizes.
            lastAccessMs: null,
          });
        }
      }
      return entries;
    },

    async evictWorkspace(userId: string): Promise<void> {
      // P2 destroys the env's live leaves + cgroup; workspace DATA stays.
      await deps.manager.destroy(userId);
    },
  };
}
