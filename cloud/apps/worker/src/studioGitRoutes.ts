import type { FastifyInstance, FastifyReply } from "fastify";
import { z } from "zod";
import type { SandboxManager } from "@ovid/sandbox";
import { GitCredentialLeakError } from "@ovid/sandbox/gitCredential";
import { createEnvelopeCrypto, type EncryptedEnvelope } from "@ovid/escrow";

import { searchWorkspacePaths } from "./studioFiles.js";
import {
  DEFAULT_GITHUB_HOSTS,
  StudioGitError,
  createPerUserGithubTokenResolver,
  createStudioGit,
  type GithubTokenSourceRow,
  type StudioGit,
  type StudioGitErrorCode,
  type StudioGitTokenResolver,
} from "./studioGit.js";

/** Studio DTOs are small; the legacy 16 MiB file-upload ceiling does not apply. */
export const STUDIO_GIT_BODY_LIMIT_BYTES = 64 * 1024;

export interface StudioGitRoutesDeps {
  git: StudioGit;
  resolveToken: StudioGitTokenResolver;
  /** Search shares the same attached user workspace as git, without a PAT. */
  manager: Pick<SandboxManager, "attach">;
}

export interface StudioGitServiceConfig {
  manager: Pick<SandboxManager, "attach">;
  masterKey: string;
  /** Production binds this to mcpServersRepo.list(db, userId). */
  listServers: (userId: string) => Promise<readonly GithubTokenSourceRow[]>;
  allowedHosts?: readonly string[];
}

/** OVID_GIT_ALLOWED_HOSTS: exact hosts, github.com when unset or empty. */
export function parseStudioGitAllowedHosts(raw: string | undefined): string[] {
  const hosts = (raw ?? "")
    .split(",")
    .map((host) => host.trim().toLowerCase())
    .filter((host) => host !== "");
  return hosts.length === 0 ? [...DEFAULT_GITHUB_HOSTS] : hosts;
}

/**
 * Real worker composition: curated per-user MCP credential + master-key
 * envelope crypto on every network call. There is no local-URL escape hatch,
 * deployment-wide token, or unavailable resolver placeholder in this path.
 */
export function createStudioGitService(
  config: StudioGitServiceConfig,
): StudioGitRoutesDeps {
  const crypto = createEnvelopeCrypto(config.masterKey);
  const resolveToken = createPerUserGithubTokenResolver({
    listServers: config.listServers,
    decrypt: (sealed, recordId) =>
      crypto.decrypt(sealed as EncryptedEnvelope, recordId),
  });
  return {
    manager: config.manager,
    resolveToken,
    git: createStudioGit({
      manager: config.manager,
      ...(config.allowedHosts !== undefined ? { allowedHosts: config.allowedHosts } : {}),
    }),
  };
}

const requiredText = (max: number) => z.string().trim().min(1).max(max);
const cloneBody = z.object({
  repo: requiredText(2_048),
  branch: requiredText(255).optional(),
  dest: requiredText(255).optional(),
}).strict();
const repoBody = z.object({ repoDir: requiredText(4_096) }).strict();
const syncBody = repoBody;
const inspectBody = repoBody;
const statusBody = repoBody;
const switchBranchBody = z.object({
  repoDir: requiredText(4_096),
  branch: requiredText(255),
}).strict();
const diffBody = z.object({
  repoDir: requiredText(4_096),
  staged: z.boolean().optional(),
  path: requiredText(4_096).optional(),
  maxBytes: z.number().int().min(1).max(256 * 1024).optional(),
}).strict();
const logsBody = z.object({
  repoDir: requiredText(4_096),
  limit: z.number().int().min(1).max(50).optional(),
}).strict();
const searchBody = z.object({
  repoDir: requiredText(4_096),
  query: z.string().max(512),
  limit: z.number().int().min(1).max(100).optional(),
}).strict();

const REFUSAL_STATUS: Record<StudioGitErrorCode, number> = {
  invalid_repo: 400,
  invalid_path: 400,
  invalid_branch: 400,
  destination_exists: 409,
  not_a_repo: 409,
  clone_failed: 502,
  fetch_failed: 502,
  sync_failed: 502,
  stash_failed: 409,
  switch_failed: 409,
  search_failed: 500,
  token_unavailable: 409,
  credential_leak: 500,
};

function internalError(reply: FastifyReply): FastifyReply {
  return reply.code(500).send({
    error: { code: "internal", message: "Internal server error." },
  });
}

/** Typed worker refusals cross the hop; Fastify/git/provider failures do not. */
function sendStudioGitError(reply: FastifyReply, err: unknown): FastifyReply {
  if (
    err instanceof GitCredentialLeakError ||
    (err instanceof StudioGitError && err.code === "credential_leak")
  ) {
    return reply.code(500).send({
      error: {
        code: "credential_leak",
        message: "Studio git stopped because it detected a credential leak.",
      },
    });
  }
  if (!(err instanceof StudioGitError)) return internalError(reply);
  return reply.code(REFUSAL_STATUS[err.code]).send({
    error: {
      code: err.code,
      message: err.message,
      ...(err.stashRef !== undefined ? { stashRef: err.stashRef } : {}),
    },
  });
}

interface OperationRequest<Body> {
  userId: string;
  sessionId: string;
  body: Body;
}

function register<Body>(
  app: FastifyInstance,
  deps: StudioGitRoutesDeps,
  operation: string,
  schema: z.ZodType<Body>,
  handler: (req: OperationRequest<Body>) => Promise<unknown>,
): void {
  app.post<{ Params: { sid: string } }>(
    `/internal/sessions/:sid/studio-git/${operation}`,
    { bodyLimit: STUDIO_GIT_BODY_LIMIT_BYTES },
    async (req, reply) => {
      const parsed = schema.safeParse(req.body);
      if (!parsed.success) {
        return reply.code(400).send({
          error: { code: "bad_request", message: "Invalid Studio git request." },
        });
      }
      try {
        return await handler({
          userId: String(req.headers["x-ovid-user-id"]),
          sessionId: req.params.sid,
          body: parsed.data,
        });
      } catch (err) {
        return sendStudioGitError(reply, err);
      }
    },
  );
}

async function tokenFor(
  deps: StudioGitRoutesDeps,
  req: { userId: string; repo?: string; repoDir?: string },
): Promise<string> {
  const token = await deps.resolveToken(req);
  if (token === null) {
    throw new StudioGitError(
      "token_unavailable",
      "Connect GitHub in Settings to use Studio git.",
    );
  }
  return token;
}

/** Register the synchronous Studio surface below the file service's auth gate. */
export function registerStudioGitRoutes(
  app: FastifyInstance,
  deps: StudioGitRoutesDeps,
): void {
  register(app, deps, "clone", cloneBody, async ({ userId, sessionId, body }) => {
    const token = await tokenFor(deps, { userId, repo: body.repo });
    const result = await deps.git.clone({
      ...body,
      userId,
      sessionId,
      token,
    });
    return { repoDir: result.repoDir, branch: result.branch };
  });

  register(app, deps, "sync", syncBody, async ({ userId, sessionId, body }) => {
    const token = await tokenFor(deps, { userId, repoDir: body.repoDir });
    return deps.git.syncLatest({ ...body, userId, sessionId, token });
  });

  register(app, deps, "switch-branch", switchBranchBody, async ({ userId, sessionId, body }) => {
    const token = await tokenFor(deps, { userId, repoDir: body.repoDir });
    return deps.git.switchBranch({ ...body, userId, sessionId, token });
  });

  register(app, deps, "inspect", inspectBody, async ({ userId, sessionId, body }) => {
    const token = await tokenFor(deps, { userId, repoDir: body.repoDir });
    return deps.git.inspect({ ...body, userId, sessionId, token });
  });

  // Local reads deliberately do not even decrypt the user's credential.
  register(app, deps, "status", statusBody, async ({ userId, sessionId, body }) =>
    deps.git.status({ ...body, userId, sessionId }),
  );
  register(app, deps, "diff", diffBody, async ({ userId, sessionId, body }) =>
    deps.git.diff({ ...body, userId, sessionId }),
  );
  register(app, deps, "logs", logsBody, async ({ userId, sessionId, body }) =>
    deps.git.logs({ ...body, userId, sessionId }),
  );
  register(app, deps, "search", searchBody, async ({ userId, body }) => {
    const handle = await deps.manager.attach(userId);
    return searchWorkspacePaths({ workspaceDir: handle.workspaceDir, ...body });
  });
}
