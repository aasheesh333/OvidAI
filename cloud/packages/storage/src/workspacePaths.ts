/**
 * Workspace path layout per controller ruling R1 (converged with P2's
 * per-session dirs):
 *   /workspaces/users/{uid}/sessions/{sessionId}/workspace
 * ({uid} = per-user dir keyed by nft/cgroup).
 *
 * This is a PURE helper so P7's suites run before P2's manager does; the
 * equality with P2's @ovid/sandbox workspaceDir(userId, sessionId) seam
 * (contract 1) is pinned by an equality test once P2 lands.
 */

import { join } from "node:path";

import { assertSafeSegment } from "./keys.js";

/** path.join(root, "users", uid, "sessions", sid, "workspace") after asserting both ids. */
export function workspaceDir(workspacesRoot: string, userId: string, sessionId: string): string {
  assertSafeSegment(userId);
  assertSafeSegment(sessionId);
  return join(workspacesRoot, "users", userId, "sessions", sessionId, "workspace");
}

/** Rename alias (ledger continuity). */
export const sessionWorkspacePath: typeof workspaceDir = workspaceDir;
