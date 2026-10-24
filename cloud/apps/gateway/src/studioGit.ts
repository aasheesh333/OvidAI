/**
 * Studio git — the gateway half of the worker's git service.
 *
 * The worker owns git execution: it is the only process that can see the
 * session workspace, and it is the only place the GitHub token is ever
 * materialised (through an ephemeral `GIT_ASKPASS` helper, never argv, never
 * `.git/config`). The gateway therefore does not run git and does not carry a
 * token into any job: this interface deliberately has no `token` parameter.
 *
 * The transport is a seam, exactly like `WorkerClient` for workspace bytes:
 * the composition wires the worker's implementation when the deployment has
 * one, and the routes answer a loud `studio_git_unavailable` when it does
 * not. A route must never answer success for an operation that did not
 * happen.
 *
 * The result shapes mirror the worker service 1:1 (status strings, stash
 * details, sync reasons) so the client sees one vocabulary regardless of
 * which side produced the answer.
 */

/** The worker's machine-readable refusal codes. */
export type StudioGitErrorCode =
  | "invalid_repo"
  | "invalid_path"
  | "invalid_branch"
  | "destination_exists"
  | "not_a_repo"
  | "clone_failed"
  | "fetch_failed"
  | "sync_failed"
  | "stash_failed"
  | "switch_failed"
  | "search_failed"
  | "token_unavailable"
  | "credential_leak";

/**
 * A typed, user-safe refusal from the worker. The message never contains a
 * token or raw git stderr — the worker guarantees that, and the route relays
 * it as-is.
 */
export class StudioGitRefusal extends Error {
  readonly name = "StudioGitRefusal";

  constructor(
    readonly code: StudioGitErrorCode,
    message: string,
    /** Present when uncommitted work is sitting in a stash. */
    readonly stashRef?: string,
  ) {
    super(message);
  }
}

export type StudioSyncReason = "dirty_worktree" | "diverged" | "no_upstream" | "merge_failed";

export interface StudioCloneResult {
  /** Workspace-relative folder the clone created. */
  repoDir: string;
  /** The branch HEAD ended on (may differ from the requested one). */
  branch: string;
}

export interface StudioSyncResult {
  status: "up_to_date" | "synced" | "needs_merge";
  dirty: boolean;
  behind: number;
  ahead: number;
  branch: string;
  message: string;
  reason?: StudioSyncReason;
}

export interface StudioSwitchResult {
  status: "switched" | "unchanged" | "failed";
  branch: string;
  stashed: boolean;
  stashRef?: string;
  stashNote?: string;
  message: string;
}

export interface StudioRepoRequest {
  userId: string;
  sessionId: string;
  /** Always read from the server-side session binding, never the client. */
  repoDir: string;
}

export interface StudioGitStatus {
  branch: string;
  headSha: string;
  upstream: string | null;
  dirty: boolean;
  ahead: number;
  behind: number;
  reason: "clean" | "dirty_worktree" | "diverged" | "no_upstream";
  fetchedAt: string | null;
}

export interface StudioDiffResult {
  patch: string;
  truncated: boolean;
}

export interface StudioGitLogsResult {
  items: Array<{ sha: string; subject: string; authoredAt: string }>;
}

export interface StudioPathSearchResult {
  items: Array<{ path: string; name: string }>;
  truncated: boolean;
}

/**
 * The worker git service, as the gateway calls it. `userId` is the verified
 * principal (the worker resolves that user's own token); `sessionId` is
 * already ownership-checked by the route.
 */
export interface StudioGitTransport {
  clone(req: {
    userId: string;
    sessionId: string;
    /** Canonical `owner/name`. */
    repo: string;
    branch?: string;
    /** Workspace-relative destination folder (one level). */
    dest?: string;
  }): Promise<StudioCloneResult>;

  sync(req: {
    userId: string;
    sessionId: string;
    /** Workspace-relative folder of the existing clone. */
    repoDir: string;
  }): Promise<StudioSyncResult>;

  switchBranch(req: {
    userId: string;
    sessionId: string;
    repoDir: string;
    branch: string;
  }): Promise<StudioSwitchResult>;

  /** Fetch-only preflight; distinct from the mutating sync/fast-forward path. */
  inspect(req: StudioRepoRequest): Promise<StudioGitStatus>;
  /** Local status only; never fetches or resolves a PAT. */
  status(req: StudioRepoRequest): Promise<StudioGitStatus>;
  diff(req: StudioRepoRequest & {
    staged?: boolean;
    path?: string;
    maxBytes?: number;
  }): Promise<StudioDiffResult>;
  logs(req: StudioRepoRequest & { limit?: number }): Promise<StudioGitLogsResult>;
  search(req: StudioRepoRequest & { query: string; limit?: number }): Promise<StudioPathSearchResult>;
}
