import { z } from "zod";

import {
  StudioGitRefusal,
  type StudioGitErrorCode,
  type StudioGitTransport,
} from "./studioGit.js";
import { WorkerUnavailableError } from "./workerClient.js";

export const DEFAULT_STUDIO_GIT_HTTP_TIMEOUT_MS = 30_000;
export const MAX_STUDIO_GIT_HTTP_TIMEOUT_MS = 300_000;

export interface StudioGitHttpConfig {
  baseUrl: string;
  token: string;
  timeoutMs?: number;
  fetch?: typeof fetch;
}

interface Identity {
  userId: string;
  sessionId: string;
}

export interface StudioGitHttpRepoRequest extends Identity {
  repoDir: string;
}

export interface StudioGitHttpStatus {
  branch: string;
  headSha: string;
  upstream: string | null;
  dirty: boolean;
  ahead: number;
  behind: number;
  reason: "clean" | "dirty_worktree" | "diverged" | "no_upstream";
  fetchedAt: string | null;
}

/** Existing three-method consumers can use this transport without changes. */
export interface StudioGitHttpTransport extends StudioGitTransport {
  /** Bind the verified principal; mismatched per-request identities never fetch. */
  forUser(verifiedUserId: string): StudioGitHttpTransport;
  inspect(req: StudioGitHttpRepoRequest): Promise<StudioGitHttpStatus>;
  status(req: StudioGitHttpRepoRequest): Promise<StudioGitHttpStatus>;
  diff(req: StudioGitHttpRepoRequest & {
    staged?: boolean;
    path?: string;
    maxBytes?: number;
  }): Promise<{ patch: string; truncated: boolean }>;
  logs(req: StudioGitHttpRepoRequest & { limit?: number }): Promise<{
    items: Array<{ sha: string; subject: string; authoredAt: string }>;
  }>;
  search(req: StudioGitHttpRepoRequest & { query: string; limit?: number }): Promise<{
    items: Array<{ path: string; name: string }>;
    truncated: boolean;
  }>;
}

const cloneResult = z.object({ repoDir: z.string(), branch: z.string() }).strict();
const syncResult = z.object({
  status: z.enum(["up_to_date", "synced", "needs_merge"]),
  dirty: z.boolean(),
  behind: z.number().int().nonnegative(),
  ahead: z.number().int().nonnegative(),
  branch: z.string(),
  message: z.string(),
  reason: z.enum(["dirty_worktree", "diverged", "no_upstream", "merge_failed"]).optional(),
}).strict();
const switchResult = z.object({
  status: z.enum(["switched", "unchanged", "failed"]),
  branch: z.string(),
  stashed: z.boolean(),
  stashRef: z.string().optional(),
  stashNote: z.string().optional(),
  message: z.string(),
}).strict();
const statusResult: z.ZodType<StudioGitHttpStatus> = z.object({
  branch: z.string(),
  headSha: z.string(),
  upstream: z.string().nullable(),
  dirty: z.boolean(),
  ahead: z.number().int().nonnegative(),
  behind: z.number().int().nonnegative(),
  reason: z.enum(["clean", "dirty_worktree", "diverged", "no_upstream"]),
  fetchedAt: z.string().nullable(),
}).strict();
const diffResult = z.object({
  patch: z.string().max(256 * 1024),
  truncated: z.boolean(),
}).strict();
const logsResult = z.object({
  items: z.array(z.object({
    sha: z.string(),
    subject: z.string(),
    authoredAt: z.string(),
  }).strict()).max(50),
}).strict();
const searchResult = z.object({
  items: z.array(z.object({ path: z.string(), name: z.string() }).strict()).max(100),
  truncated: z.boolean(),
}).strict();

const refusalEnvelope = z.object({
  error: z.object({
    code: z.enum([
      "invalid_repo",
      "invalid_path",
      "invalid_branch",
      "destination_exists",
      "not_a_repo",
      "clone_failed",
      "fetch_failed",
      "sync_failed",
      "stash_failed",
      "switch_failed",
      "search_failed",
      "token_unavailable",
      "credential_leak",
    ]),
    message: z.string().max(4_096),
    stashRef: z.string().max(4_096).optional(),
  }).strict(),
}).strict();

class StudioGitDeadline extends Error {}

function boundedTimeout(configured: number | undefined): number {
  if (configured === undefined || !Number.isFinite(configured)) {
    return DEFAULT_STUDIO_GIT_HTTP_TIMEOUT_MS;
  }
  return Math.min(
    MAX_STUDIO_GIT_HTTP_TIMEOUT_MS,
    Math.max(1, Math.floor(configured)),
  );
}

async function request<T>(
  cfg: StudioGitHttpConfig,
  schema: z.ZodType<T>,
  opts: { operation: string; userId: string; sessionId: string; body: Record<string, unknown> },
): Promise<T> {
  const fetchImpl = cfg.fetch ?? globalThis.fetch;
  const controller = new AbortController();
  const base = cfg.baseUrl.replace(/\/+$/, "");
  const url = `${base}/internal/sessions/${encodeURIComponent(opts.sessionId)}/studio-git/${opts.operation}`;
  let timer: ReturnType<typeof setTimeout> | undefined;

  const work = (async (): Promise<T> => {
    const response = await fetchImpl(url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-ovid-internal-token": cfg.token,
        "x-ovid-user-id": opts.userId,
      },
      body: JSON.stringify(opts.body),
      signal: controller.signal,
    });
    const json: unknown = await response.json();
    if (!response.ok) {
      const refusal = refusalEnvelope.safeParse(json);
      if (!refusal.success) throw new WorkerUnavailableError("Studio git worker returned an invalid response.");
      // The gateway's original public type predates search_failed; runtime
      // preserves every worker code, including that additive read-only code.
      throw new StudioGitRefusal(
        refusal.data.error.code as StudioGitErrorCode,
        refusal.data.error.message,
        refusal.data.error.stashRef,
      );
    }
    const result = schema.safeParse(json);
    if (!result.success) throw new WorkerUnavailableError("Studio git worker returned an invalid response.");
    return result.data;
  })();

  const deadline = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(new StudioGitDeadline());
    }, boundedTimeout(cfg.timeoutMs));
  });

  try {
    return await Promise.race([work, deadline]);
  } catch (err) {
    if (err instanceof StudioGitRefusal) throw err;
    if (err instanceof WorkerUnavailableError) throw err;
    // Never retain a raw fetch/Zod/provider error as `cause`: public route
    // logs serialize thrown errors, and upstream text is not a safe boundary.
    throw new WorkerUnavailableError("Studio git worker is unavailable.");
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

/** Thin synchronous gateway → worker adapter; no PAT is accepted or forwarded. */
export function createStudioGitHttpTransport(
  cfg: StudioGitHttpConfig,
): StudioGitHttpTransport {
  return createBoundStudioGitHttpTransport(cfg);
}

function createBoundStudioGitHttpTransport(
  cfg: StudioGitHttpConfig,
  verifiedUserId?: string,
): StudioGitHttpTransport {
  const call = <T>(
    schema: z.ZodType<T>,
    operation: string,
    req: Identity,
    body: Record<string, unknown>,
  ): Promise<T> => {
    if (verifiedUserId !== undefined && req.userId !== verifiedUserId) {
      return Promise.reject(new StudioGitRefusal(
        "invalid_path",
        "The Studio workspace does not belong to the verified user.",
      ));
    }
    return request(cfg, schema, {
      operation,
      userId: verifiedUserId ?? req.userId,
      sessionId: req.sessionId,
      body,
    });
  };
  const repoBody = (req: StudioGitHttpRepoRequest): Record<string, unknown> => ({
    repoDir: req.repoDir,
  });

  return {
    forUser(userId) {
      const bound = userId.trim();
      if (bound === "") throw new Error("A verified Studio user is required.");
      if (verifiedUserId !== undefined && bound !== verifiedUserId) {
        throw new Error("The Studio transport is already bound to a different verified user.");
      }
      return createBoundStudioGitHttpTransport(cfg, bound);
    },
    clone(req) {
      return call(cloneResult, "clone", req, {
        repo: req.repo,
        ...(req.branch !== undefined ? { branch: req.branch } : {}),
        ...(req.dest !== undefined ? { dest: req.dest } : {}),
      });
    },
    sync(req) {
      return call(syncResult, "sync", req, repoBody(req));
    },
    switchBranch(req) {
      return call(switchResult, "switch-branch", req, {
        repoDir: req.repoDir,
        branch: req.branch,
      });
    },
    inspect(req) {
      return call(statusResult, "inspect", req, repoBody(req));
    },
    status(req) {
      return call(statusResult, "status", req, repoBody(req));
    },
    diff(req) {
      return call(diffResult, "diff", req, {
        repoDir: req.repoDir,
        ...(req.staged !== undefined ? { staged: req.staged } : {}),
        ...(req.path !== undefined ? { path: req.path } : {}),
        ...(req.maxBytes !== undefined ? { maxBytes: req.maxBytes } : {}),
      });
    },
    logs(req) {
      return call(logsResult, "logs", req, {
        repoDir: req.repoDir,
        ...(req.limit !== undefined ? { limit: req.limit } : {}),
      });
    },
    search(req) {
      return call(searchResult, "search", req, {
        repoDir: req.repoDir,
        query: req.query,
        ...(req.limit !== undefined ? { limit: req.limit } : {}),
      });
    },
  };
}
