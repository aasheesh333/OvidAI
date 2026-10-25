import type { SessionMode } from "@ovid/agent-core";
import { GitCredentialLeakError } from "@ovid/sandbox/gitCredential";

import {
  StudioGitError,
  type StudioGit,
  type StudioGitErrorCode,
  type StudioGitStatus,
  type StudioGitTokenResolver,
} from "./studioGit.js";
import {
  StudioRunBindingError,
  type StudioRunBindingPort,
} from "./studioRunBinding.js";

export interface StudioPreflightInput {
  /** Verified run owner, never a model- or client-supplied repository owner. */
  userId: string;
  sessionId: string;
  /** The processor's effective run mode. */
  mode: SessionMode;
}

export interface StudioPreflightFailure {
  code: string;
  message: string;
}

export interface StudioPreflightResult {
  status: StudioGitStatus | null;
  failure: StudioPreflightFailure | null;
}

/** The optional dependency shape shared by RunDeps and FullRunDeps. */
export type StudioPreflight = (
  input: StudioPreflightInput,
) => Promise<StudioPreflightResult>;

export interface StudioPreflightDeps {
  /**
   * The existing StudioGitRoutesDeps/StudioAgentGitService bundle. Only its
   * canonical inspect operation and per-user resolver are exposed here.
   */
  git: {
    git: Pick<StudioGit, "inspect">;
    resolveToken: StudioGitTokenResolver;
  };
  /** The canonical studio_repos view, including its session-ownership check. */
  binding: Pick<StudioRunBindingPort, "get">;
}

const FAILURE_MESSAGE_MAX_CHARS = 512;
const TOKEN_REQUIRED_MESSAGE = "Connect GitHub in Settings to use Studio git.";

/** Match the public vocabulary already used by the Studio agent tools. */
const PUBLIC_ERROR_CODE: Record<StudioGitErrorCode, string> = {
  invalid_repo: "bad_request",
  invalid_path: "bad_request",
  invalid_branch: "bad_request",
  destination_exists: "destination_exists",
  not_a_repo: "no_repo",
  clone_failed: "clone_failed",
  fetch_failed: "fetch_failed",
  sync_failed: "sync_failed",
  stash_failed: "stash_failed",
  switch_failed: "switch_failed",
  search_failed: "internal",
  token_unavailable: "github_not_connected",
  credential_leak: "internal",
};

function emptyResult(): StudioPreflightResult {
  return { status: null, failure: null };
}

function internalFailure(): StudioPreflightFailure {
  return { code: "internal", message: "Internal server error." };
}

function safeFailure(error: unknown): StudioPreflightFailure {
  if (error instanceof StudioRunBindingError) {
    return { code: error.code, message: error.message };
  }
  if (error instanceof GitCredentialLeakError) return internalFailure();
  if (!(error instanceof StudioGitError)) return internalFailure();

  const code = PUBLIC_ERROR_CODE[error.code];
  if (code === "internal") return internalFailure();
  if (error.code === "token_unavailable") {
    return { code, message: TOKEN_REQUIRED_MESSAGE };
  }
  return {
    code,
    // StudioGitError carries public copy, never raw Git/provider output. Keep
    // even that trusted context bounded; all other errors use the fixed text.
    message: error.message.slice(0, FAILURE_MESSAGE_MAX_CHARS),
  };
}

/**
 * Build the run-scoped Studio preflight over the canonical worker Git service.
 * It returns model context only: no transcript/event write, binding mutation,
 * sync, branch switch, or other HEAD/worktree operation is available here.
 */
export function createStudioPreflight(deps: StudioPreflightDeps): StudioPreflight {
  return async ({ userId, sessionId, mode }) => {
    if (mode !== "studio") return emptyResult();

    try {
      const bound = await deps.binding.get({ userId, sessionId });
      if (bound === null) return emptyResult();

      const token = await deps.git.resolveToken({ userId, repoDir: bound.repoDir });
      if (token === null) {
        return {
          status: null,
          failure: { code: "github_not_connected", message: TOKEN_REQUIRED_MESSAGE },
        };
      }

      // Canonical inspect fetches remote-tracking refs only. In particular, do
      // not substitute syncLatest: preflight must never fast-forward HEAD or
      // alter the user's uncommitted work.
      const status = await deps.git.git.inspect({
        userId,
        sessionId,
        repoDir: bound.repoDir,
        token,
      });
      return { status, failure: null };
    } catch (error) {
      // Inspection is advisory context, not a new run-terminal failure path.
      return { status: null, failure: safeFailure(error) };
    }
  };
}

/**
 * Pure phase sequencing for either processor path. All I/O is injected: warm
 * finishes first, preflight finishes second, and only then does the caller's
 * model/tool phase receive the bounded, transient preflight context.
 *
 * The caller retains its existing warm-error policy; in particular, model/tool
 * errors from runModelTools must not be reclassified as hydration failures.
 */
export async function runStudioPreflightAfterWarm<T>(o: {
  input: StudioPreflightInput;
  ensureWarm?: (sessionId: string, userId: string) => Promise<void>;
  studioPreflight?: StudioPreflight;
  runModelTools: (context: StudioPreflightResult) => Promise<T>;
}): Promise<T> {
  await o.ensureWarm?.(o.input.sessionId, o.input.userId);
  const context = o.studioPreflight === undefined
    ? emptyResult()
    : await o.studioPreflight(o.input);
  return o.runModelTools(context);
}
