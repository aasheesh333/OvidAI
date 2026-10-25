import { randomUUID } from "node:crypto";

import type {
  ApprovalDecision,
  ApprovalGate,
  ApprovalRequest,
  Tool,
  ToolContext,
  ToolResult,
} from "@ovid/agent-core";
import type { StudioRepoBinding } from "@ovid/db";
import { GitCredentialLeakError } from "@ovid/sandbox/gitCredential";

import { searchWorkspacePaths } from "./studioFiles.js";
import {
  assertSafeBranch,
  safeRepoDirName,
  StudioGitError,
  type StudioGit,
  type StudioGitErrorCode,
  type StudioGitTokenRequest,
  type StudioGitTokenResolver,
} from "./studioGit.js";
import {
  StudioRunBindingError,
  type StudioRunBindingIdentity,
  type StudioRunBindingPort,
} from "./studioRunBinding.js";

/** The existing worker bundle: canonical Git, its PAT resolver, and workspace. */
export interface StudioAgentGitService {
  git: Pick<StudioGit, "clone" | "switchBranch" | "syncLatest">;
  resolveToken: StudioGitTokenResolver;
  manager: {
    attach(userId: string): Promise<{ workspaceDir: string }>;
  };
}

const MUTATION_TIMEOUT_MS = 300_000;
const READ_TIMEOUT_MS = 120_000;
const INVALID_ARGUMENTS = "Invalid Studio tool arguments.";

class StudioAgentToolError extends Error {
  constructor(readonly code: "bad_request" | "no_repo", message: string) {
    super(message);
  }
}

function invalidArguments(): never {
  throw new StudioAgentToolError("bad_request", INVALID_ARGUMENTS);
}

function assertOnly(args: Record<string, unknown>, allowed: readonly string[]): void {
  if (args === null || typeof args !== "object" || Array.isArray(args)) invalidArguments();
  const permitted = new Set(allowed);
  if (Object.keys(args).some((key) => !permitted.has(key))) invalidArguments();
}

function requiredText(args: Record<string, unknown>, key: string, max: number): string {
  const value = args[key];
  if (typeof value !== "string") invalidArguments();
  const trimmed = value.trim();
  if (trimmed === "" || trimmed.length > max) invalidArguments();
  return trimmed;
}

function optionalText(args: Record<string, unknown>, key: string, max: number): string | undefined {
  return args[key] === undefined ? undefined : requiredText(args, key, max);
}

function optionalLimit(args: Record<string, unknown>): number | undefined {
  const value = args.limit;
  if (value === undefined) return undefined;
  if (typeof value !== "number" || !Number.isInteger(value) || value < 1) invalidArguments();
  return Math.min(value, 100);
}

const OWNER = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$/;
const REPO_NAME = /^[A-Za-z0-9_.-]{1,100}$/;
const SHORTHAND = /^([A-Za-z0-9][A-Za-z0-9_.-]{0,99})\/([A-Za-z0-9_.-]{1,100})$/;

/** Canonical binding identity and approval host, without logging raw userinfo. */
function canonicalRepo(raw: string): { fullName: string; host: string } {
  const shorthand = SHORTHAND.exec(raw);
  if (shorthand !== null) return { fullName: raw, host: "github.com" };

  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new StudioGitError("invalid_repo", "That repository address is not a valid owner/name repository.");
  }
  if (
    url.protocol !== "https:" ||
    url.username !== "" ||
    url.password !== "" ||
    url.hostname === "" ||
    url.port !== "" ||
    url.search !== "" ||
    url.hash !== ""
  ) {
    throw new StudioGitError("invalid_repo", "That repository address is not a valid owner/name repository.");
  }
  const parts = url.pathname.replace(/^\/+/, "").replace(/\/+$/, "").split("/");
  const owner = parts[0] ?? "";
  const name = (parts[1] ?? "").replace(/\.git$/i, "");
  if (
    parts.length !== 2 ||
    !OWNER.test(owner) ||
    !REPO_NAME.test(name) ||
    name === "." ||
    name === ".."
  ) {
    throw new StudioGitError("invalid_repo", "That repository address is not a valid owner/name repository.");
  }
  return { fullName: `${owner}/${name}`, host: url.hostname.toLowerCase() };
}

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

function jsonResult(value: unknown, isError?: boolean): ToolResult {
  return {
    content: JSON.stringify(value),
    ...(isError === true ? { isError: true } : {}),
  };
}

function errorResult(error: unknown): ToolResult {
  if (error instanceof StudioRunBindingError) {
    return jsonResult({ error: { code: "not_found", message: "Session not found." } }, true);
  }
  if (error instanceof StudioAgentToolError) {
    return jsonResult({ error: { code: error.code, message: error.message } }, true);
  }
  if (error instanceof GitCredentialLeakError) {
    return jsonResult({ error: { code: "internal", message: "Internal server error." } }, true);
  }
  if (error instanceof StudioGitError) {
    const code = PUBLIC_ERROR_CODE[error.code];
    if (code === "internal") {
      return jsonResult({ error: { code, message: "Internal server error." } }, true);
    }
    return jsonResult({
      error: {
        code,
        message: error.message,
        ...(error.stashRef !== undefined ? { stashRef: error.stashRef } : {}),
      },
    }, true);
  }
  return jsonResult({ error: { code: "internal", message: "Internal server error." } }, true);
}

function identity(ctx: ToolContext): StudioRunBindingIdentity {
  return { userId: ctx.userId, sessionId: ctx.sessionId };
}

function allowed(decision: ApprovalDecision): boolean {
  return decision === "allow" || decision === "always";
}

export function createStudioAgentTools(deps: {
  git: StudioAgentGitService;
  binding: StudioRunBindingPort;
  approvals: ApprovalGate;
}): Tool[] {
  const requireBinding = async (ctx: ToolContext, operation: "switching branches" | "syncing" | "searching") => {
    const binding = await deps.binding.get(identity(ctx));
    if (binding === null) {
      throw new StudioAgentToolError(
        "no_repo",
        `Clone a repository into this session before ${operation}.`,
      );
    }
    return binding;
  };

  const approve = async (ctx: ToolContext, req: Omit<ApprovalRequest, "approvalId" | "kind">) => {
    const decision = await deps.approvals.approve(ctx, {
      approvalId: randomUUID(),
      kind: "tool",
      ...req,
    });
    return allowed(decision);
  };

  const tokenFor = async (ctx: ToolContext, target: Pick<StudioGitTokenRequest, "repo" | "repoDir">) => {
    const token = await deps.git.resolveToken({ userId: ctx.userId, ...target });
    if (token === null) {
      throw new StudioGitError("token_unavailable", "Connect GitHub in Settings to use Studio git.");
    }
    return token;
  };

  const storeClone = async (
    ctx: ToolContext,
    input: { repo: string; repoDir: string; branch: string },
  ): Promise<boolean> => {
    try {
      return await deps.binding.upsert(identity(ctx), {
        userId: ctx.userId,
        sessionId: ctx.sessionId,
        ...input,
      }) !== null;
    } catch {
      // Git already succeeded. Match the public clone contract: report the
      // actual clone and explicitly say that its binding was not persisted.
      return false;
    }
  };

  const storeBranch = async (
    ctx: ToolContext,
    expected: StudioRepoBinding,
    branch: string,
  ): Promise<boolean> => {
    if (branch === expected.branch) return true;
    try {
      return await deps.binding.compareAndSetBranch(identity(ctx), expected, branch) !== null;
    } catch {
      // Never turn a lost CAS into an upsert: a newer binding is authoritative.
      return false;
    }
  };

  const tool = (
    name: string,
    description: string,
    parameters: Record<string, unknown>,
    timeoutMs: number,
    execute: (args: Record<string, unknown>, ctx: ToolContext) => Promise<ToolResult>,
  ): Tool => ({
    spec: { name, description, parameters },
    timeoutMs,
    execute: async (args, ctx) => {
      try {
        return await execute(args, ctx);
      } catch (error) {
        return errorResult(error);
      }
    },
  });

  return [
    tool(
      "studio_repo_clone",
      "Clone a repository into this Studio session and bind the actual cloned directory and branch.",
      {
        type: "object",
        properties: {
          repo: { type: "string", description: "Repository owner/name or https URL." },
          branch: { type: "string", description: "Optional branch to clone." },
          dest: { type: "string", description: "Optional one-folder destination in the session workspace." },
        },
        required: ["repo"],
        additionalProperties: false,
      },
      MUTATION_TIMEOUT_MS,
      async (args, ctx) => {
        assertOnly(args, ["repo", "branch", "dest"]);
        const repo = canonicalRepo(requiredText(args, "repo", 2_048));
        const branch = optionalText(args, "branch", 255);
        const dest = optionalText(args, "dest", 255);
        if (branch !== undefined) assertSafeBranch(branch);
        if (dest !== undefined) safeRepoDirName(dest);

        // Clone may replace an old binding, but this read first proves that
        // the verified context owns the session before approval or mutation.
        await deps.binding.get(identity(ctx));
        if (!await approve(ctx, {
          tool: "studio_repo_clone",
          summary: `Clone ${repo.fullName} into this Studio session`,
          detail: `Clone ${repo.fullName}${branch === undefined ? "" : ` on branch ${branch}`}.`,
          allowAlways: true,
          pathTargets: [],
          hostTargets: [repo.host],
        })) return { content: "DENIED by user" };

        const token = await tokenFor(ctx, { repo: repo.fullName });
        const result = await deps.git.git.clone({
          userId: ctx.userId,
          sessionId: ctx.sessionId,
          repo: requiredText(args, "repo", 2_048),
          ...(branch !== undefined ? { branch } : {}),
          ...(dest !== undefined ? { dest } : {}),
          token,
        });
        const bindingStored = await storeClone(ctx, {
          repo: repo.fullName,
          repoDir: result.repoDir,
          branch: result.branch,
        });
        return jsonResult({ ...result, repo: repo.fullName, bindingStored });
      },
    ),

    tool(
      "studio_repo_switch",
      "Switch the repository bound to this Studio session to another branch.",
      {
        type: "object",
        properties: {
          branch: { type: "string", description: "Branch to switch to." },
        },
        required: ["branch"],
        additionalProperties: false,
      },
      MUTATION_TIMEOUT_MS,
      async (args, ctx) => {
        assertOnly(args, ["branch"]);
        const branch = requiredText(args, "branch", 255);
        assertSafeBranch(branch);
        const bound = await requireBinding(ctx, "switching branches");
        if (!await approve(ctx, {
          tool: "studio_repo_switch",
          summary: `Switch ${bound.repo} to ${branch}`,
          detail: `Switch the bound Studio repository to ${branch}. Uncommitted work is preserved by the Studio git policy.`,
          allowAlways: true,
          pathTargets: [],
          hostTargets: [],
        })) return { content: "DENIED by user" };

        const token = await tokenFor(ctx, { repoDir: bound.repoDir });
        const result = await deps.git.git.switchBranch({
          userId: ctx.userId,
          sessionId: ctx.sessionId,
          repoDir: bound.repoDir,
          branch,
          token,
        });
        if (result.status === "failed") {
          return jsonResult({
            error: { code: "switch_failed", message: result.message },
          }, true);
        }
        const bindingStored = await storeBranch(ctx, bound, result.branch);
        return jsonResult({ ...result, bindingStored });
      },
    ),

    tool(
      "studio_repo_sync",
      "Fetch and fast-forward the bound Studio repository only when safe; needs_merge never claims an update.",
      {
        type: "object",
        properties: {},
        additionalProperties: false,
      },
      MUTATION_TIMEOUT_MS,
      async (args, ctx) => {
        assertOnly(args, []);
        const bound = await requireBinding(ctx, "syncing");
        if (!await approve(ctx, {
          tool: "studio_repo_sync",
          summary: `Sync ${bound.repo}/${bound.branch} (fast-forward only)`,
          detail: "Fetch the bound repository remote and fast-forward only when the worktree and history are safe.",
          allowAlways: true,
          pathTargets: [],
          hostTargets: [],
        })) return { content: "DENIED by user" };

        const token = await tokenFor(ctx, { repoDir: bound.repoDir });
        const result = await deps.git.git.syncLatest({
          userId: ctx.userId,
          sessionId: ctx.sessionId,
          repoDir: bound.repoDir,
          token,
        });
        const bindingStored = await storeBranch(ctx, bound, result.branch);
        return jsonResult({ ...result, bindingStored });
      },
    ),

    tool(
      "studio_file_search",
      "Search file paths below the repository bound to this Studio session. Read-only.",
      {
        type: "object",
        properties: {
          query: { type: "string", description: "Case-folded file-path substring to find." },
          path: { type: "string", description: "Optional path relative to the bound repository." },
          limit: { type: "integer", minimum: 1, maximum: 100, description: "Maximum results; defaults to 50." },
        },
        required: ["query"],
        additionalProperties: false,
      },
      READ_TIMEOUT_MS,
      async (args, ctx) => {
        assertOnly(args, ["query", "path", "limit"]);
        const query = requiredText(args, "query", 512);
        const path = optionalText(args, "path", 4_096);
        const limit = optionalLimit(args);
        const bound = await requireBinding(ctx, "searching");
        const repoDir = path === undefined
          ? bound.repoDir
          : bound.repoDir === "." ? path : `${bound.repoDir}/${path}`;
        const handle = await deps.git.manager.attach(ctx.userId);
        const result = await searchWorkspacePaths({
          workspaceDir: handle.workspaceDir,
          repoDir,
          query,
          ...(limit !== undefined ? { limit } : {}),
        });
        return jsonResult(result);
      },
    ),
  ];
}
