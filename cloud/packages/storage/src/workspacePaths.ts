/**
 * Workspace path identity — CONTROLLER RULING (fix round 1): P7 must operate
 * on the SAME directory the agent runs in, keyed by P2's NUMERIC sandbox uid.
 *
 * Two different P2 paths exist; do not conflate them:
 *
 *  1. `SandboxManager.workspaceDir(userId, sessionId)` (manager.ts:439-467)
 *     creates `{workspacesRoot}/{numericUid}/sessions/{sessionId}`. That is a
 *     per-session tree used by P6's browser artifacts — it is a SIBLING of the
 *     agent workspace, NOT the agent's cwd.
 *
 *  2. `SandboxHandle.workspaceDir` (manager.ts:308-309) is
 *     `{workspacesRoot}/{numericUid}/workspace` — the HOST path mounted at
 *     `/workspace` in the jail and the cwd every agent run/file tool uses
 *     (`runProcessor` / `sandboxAdapter` / `sandboxSeam` all consume
 *     `handle.workspaceDir`).
 *
 * P7 hibernates and hydrates the agent's data, so its directory MUST be (2).
 * Hibernating the sibling (1) captured no agent data (the original C1).
 *
 * Identity: every caller carries a Firebase userId, but the path segment is
 * the numeric sandbox uid allocated idempotently by
 * `users.allocateSandboxUid(db, userId)` (repos.ts:83, wired into P2 as
 * `SandboxManagerDeps.allocateUid`). `resolveWorkspaceDir` is the ONE bridge
 * from userId to that uid; engines never pass a raw userId as a path segment.
 *
 * Note (documented, P2's model): the agent workspace is per-USER, so sessions
 * of the same user share directory (2). P7's file_manifests rows are still
 * per-session; hibernating/hydrating a session therefore operates on the
 * user's shared agent tree. This is P2's landed model (P2 keys handles by
 * userId), not a P7 choice.
 */

import { join } from "node:path";

import { assertSafeSegment } from "./keys.js";

/** Name of the per-user agent workspace under `{workspacesRoot}/{uid}`. */
export const AGENT_WORKSPACE_DIRNAME = "workspace";

/**
 * Firebase userId → numeric sandbox uid. Production supplies
 * `(userId) => users.allocateSandboxUid(db, userId)`; tests may supply an
 * identity resolver (the path helper accepts string segments too).
 */
export type SandboxUidResolver = (userId: string) => Promise<number | string>;

/**
 * P2's agent workspace: `{workspacesRoot}/{uid}/workspace`.
 *
 * `uid` is the NUMERIC sandbox uid (P2's idempotent per-user allocator), never
 * the Firebase userId. Callers that hold a userId must go through
 * `resolveWorkspaceDir`. `sessionId` is asserted but is deliberately not a
 * path component — P2's agent workspace is per-user (see the module header).
 */
export function workspaceDir(
  workspacesRoot: string,
  uid: number | string,
  sessionId: string,
): string {
  const uidSegment = String(uid);
  assertSafeSegment(uidSegment);
  assertSafeSegment(sessionId);
  return join(workspacesRoot, uidSegment, AGENT_WORKSPACE_DIRNAME);
}

/**
 * The ONE userId → agent-workspace bridge. Every P7 engine/caller resolves
 * through this so the numeric uid mapping cannot drift again.
 */
export async function resolveWorkspaceDir(
  sandboxUid: SandboxUidResolver,
  workspacesRoot: string,
  userId: string,
  sessionId: string,
): Promise<string> {
  return workspaceDir(workspacesRoot, await sandboxUid(userId), sessionId);
}

/** Rename alias (ledger continuity). */
export const sessionWorkspacePath: typeof workspaceDir = workspaceDir;
