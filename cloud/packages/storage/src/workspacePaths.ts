/**
 * Workspace path layout — CONTROLLER RULING (fix round 1): P2's LANDED seam
 * wins. @ovid/sandbox's SandboxManager.workspaceDir(userId, sessionId)
 * (cloud/packages/sandbox/src/manager.ts:439-447, pinned by its
 * manager.test.ts "G1 / P6-Q2 seam" suite) keys by the NUMERIC sandbox uid
 * allocated per user:
 *   {workspacesRoot}/{uid}/sessions/{sessionId}
 * — no "users/" segment, no "workspace" suffix. The P7 plan brief's
 * ruling-R1 string ("/workspaces/users/{uid}/sessions/{sid}/workspace") was
 * superseded; equality with the landed seam (contract 1) is pinned by
 * workspacePaths.test.ts against the real SandboxManager.
 */

import { join } from "node:path";

import { assertSafeSegment } from "./keys.js";

/**
 * path.join(root, String(uid), "sessions", sessionId) after asserting both
 * segments. `uid` is the numeric sandbox uid (P2's idempotent per-user
 * allocator); callers that only hold the userId must go through the
 * SandboxManager seam instead.
 */
export function workspaceDir(
  workspacesRoot: string,
  uid: number | string,
  sessionId: string,
): string {
  const uidSegment = String(uid);
  assertSafeSegment(uidSegment);
  assertSafeSegment(sessionId);
  return join(workspacesRoot, uidSegment, "sessions", sessionId);
}

/** Rename alias (ledger continuity). */
export const sessionWorkspacePath: typeof workspaceDir = workspaceDir;
