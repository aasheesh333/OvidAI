import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { mcpServers, sessions, studioRepos } from "@ovid/db";
import { assertSafeRelPath, KeyLayoutError } from "@ovid/storage";
import type { GatewayDeps } from "../app.js";
import {
  GithubError,
  createGithubClient,
  isSafeBranch,
  isSafeOwner,
  isSafeRepoDir,
  isSafeRepoName,
  parseRepoRef,
  type GithubBranch,
  type GithubClient,
  type GithubRepo,
} from "../studioGithub.js";
import { StudioGitRefusal, type StudioGitErrorCode } from "../studioGit.js";
import {
  badRequest,
  isUuid,
  notFound,
  parsePageLimit,
  queryValue,
  sendError,
  zodBadRequest,
} from "./http.js";

/**
 * Studio repo routes — the missing link between a Studio screen and the
 * worker's git service.
 *
 * Until now the worker could clone a repository, but no gateway route reached
 * it: a client could not list a repo, list a branch or start a clone. This
 * module is that surface.
 *
 * Three rules shape it:
 *
 *  1. **The token is the user's own GitHub integration.** It is read from the
 *     curated `github` MCP row and decrypted for one request; it travels only
 *     in an `Authorization` header. No response, error or log line ever
 *     carries it, and no route writes it into a workspace (the worker passes
 *     it to git through an ephemeral askpass helper, never `.git/config`).
 *  2. **Listing is the gateway's job; git is the worker's.** GitHub's REST API
 *     is reachable from here, so repos and branches are answered directly.
 *     Clone/switch/sync need the session workspace, which only the worker can
 *     see, so they go through `deps.studioGit`.
 *  3. **An operation with no handler is refused, never faked.** When the
 *     composition has no git transport, the routes answer
 *     `503 studio_git_unavailable` and the capability read
 *     (`GET .../git`) says so, so the client renders no dead control.
 *
 * Session-scoped routes use the house ownership rule: an unknown session and
 * a session owned by somebody else are the same 404.
 */

const noStore = (reply: FastifyReply): FastifyReply =>
  reply.header("cache-control", "private, no-store").header("pragma", "no-cache");

const cloneBody = z
  .object({
    repo: z.string().trim().min(1).max(2_048),
    branch: z.string().trim().min(1).max(255).optional(),
    dest: z.string().trim().min(1).max(255).optional(),
  })
  .strict();

const branchBody = z
  .object({
    branch: z.string().trim().min(1).max(255),
  })
  .strict();

const preflightBody = z.object({}).strict();
const emptyQuery = z.object({}).strict();
const diffQuery = z.object({
  staged: z.enum(["true", "false"]).optional(),
  path: z.string().trim().min(1).max(4_096).optional(),
}).strict();
const logsQuery = z.object({ limit: z.string().trim().max(16).optional() }).strict();
const searchQuery = z.object({
  q: z.string().trim().min(1).max(512),
  path: z.string().trim().min(1).max(4_096).optional(),
  limit: z.string().trim().max(16).optional(),
}).strict();

const DIFF_MAX_BYTES = 256 * 1024;
const DEFAULT_LOG_LIMIT = 20;
const MAX_LOG_LIMIT = 50;
const DEFAULT_SEARCH_LIMIT = 50;
const MAX_SEARCH_LIMIT = 100;

/** The GitHub credential, as the user's curated `github` integration holds it. */
type GithubConnection =
  | { kind: "ok"; token: string }
  | { kind: "not_connected" }
  | { kind: "not_configured" };

/**
 * Resolve the caller's GitHub token from the curated `github` MCP row.
 *
 * This is deliberately the same source the worker's own resolver reads
 * (`curatedId === "github"`, `GITHUB_TOKEN`, sealed under
 * `mcp_servers:{id}`), so "connected" means the same thing on both sides. A
 * deployment-wide token is never used: it could read every private repo the
 * deployment account can.
 */
async function githubConnection(deps: GatewayDeps, uid: string): Promise<GithubConnection> {
  if (deps.crypto === undefined) return { kind: "not_configured" };

  const rows = await mcpServers.list(deps.db, uid);
  const row = rows.find(
    (candidate) =>
      candidate.enabled !== false &&
      candidate.curatedId === "github" &&
      candidate.secretsSealed !== null &&
      candidate.secretsSealed !== undefined,
  );
  if (row === undefined) return { kind: "not_connected" };
  const sealed = row.secretsSealed;
  if (sealed === null || sealed === undefined) return { kind: "not_connected" };

  try {
    const raw = deps.crypto.decrypt(sealed, `mcp_servers:${row.id}`);
    const parsed = JSON.parse(raw) as unknown;
    if (typeof parsed !== "object" || parsed === null) return { kind: "not_connected" };
    const token = (parsed as Record<string, unknown>).GITHUB_TOKEN;
    if (typeof token !== "string" || token.trim() === "") return { kind: "not_connected" };
    return { kind: "ok", token: token.trim() };
  } catch {
    // Wrong key or a forged envelope is "reconnect", not a crash. The worker
    // refuses the same way, so both sides agree.
    return { kind: "not_connected" };
  }
}

/** A client for this request, or null after the refusal has been sent. */
async function githubClient(
  deps: GatewayDeps,
  uid: string,
  reply: FastifyReply,
): Promise<GithubClient | null> {
  const connection = await githubConnection(deps, uid);
  if (connection.kind === "not_configured") {
    sendError(
      reply,
      503,
      "unavailable",
      "GitHub access is not configured on this deployment.",
    );
    return null;
  }
  if (connection.kind === "not_connected") {
    sendError(
      reply,
      409,
      "github_not_connected",
      "Connect GitHub in Settings to see your repositories.",
    );
    return null;
  }
  return createGithubClient({
    token: connection.token,
    ...(deps.github?.apiBase !== undefined ? { apiBase: deps.github.apiBase } : {}),
    ...(deps.github?.fetch !== undefined ? { fetchImpl: deps.github.fetch } : {}),
    ...(deps.github?.timeoutMs !== undefined ? { timeoutMs: deps.github.timeoutMs } : {}),
  });
}

/** One mapping for every GitHub failure, so the client has one vocabulary. */
function relayGithubError(reply: FastifyReply, err: GithubError): FastifyReply {
  switch (err.kind) {
    case "unauthorized":
      return sendError(
        reply,
        409,
        "github_not_connected",
        "GitHub rejected the saved token. Reconnect GitHub in Settings.",
      );
    case "not_found":
      return notFound(reply, "That repository was not found or your token cannot see it.");
    case "rate_limited":
      return sendError(
        reply,
        429,
        "github_rate_limited",
        "GitHub rate limit reached. Try again shortly.",
      );
    case "unavailable":
      return sendError(reply, 503, "github_unavailable", "GitHub is temporarily unavailable.");
  }
}

/** 1-based page, clamped; malformed input behaves as page 1 (never a 400). */
function parsePage(raw: string | string[] | undefined): number {
  const text = queryValue(raw);
  if (text === null) return 1;
  const n = Number(text);
  if (!Number.isFinite(n) || n < 1) return 1;
  return Math.min(10_000, Math.floor(n));
}

/** 503 when no worker git transport is wired — the honest refusal. */
function gitOr503(deps: GatewayDeps, reply: FastifyReply): boolean {
  if (deps.studioGit !== undefined) return true;
  sendError(
    reply,
    503,
    "studio_git_unavailable",
    "Git operations are not available on this deployment yet.",
  );
  return false;
}

/**
 * Map the worker's typed refusal onto the public envelope. The worker's
 * message is user-safe by contract; the one exception is a credential leak,
 * which is a security incident and answers a fixed message (the detail goes
 * to the server log only).
 */
const REFUSAL_MAP: Record<StudioGitErrorCode, { status: number; code: string }> = {
  invalid_repo: { status: 400, code: "bad_request" },
  invalid_path: { status: 400, code: "bad_request" },
  invalid_branch: { status: 400, code: "bad_request" },
  destination_exists: { status: 409, code: "destination_exists" },
  not_a_repo: { status: 409, code: "no_repo" },
  clone_failed: { status: 502, code: "clone_failed" },
  fetch_failed: { status: 502, code: "fetch_failed" },
  sync_failed: { status: 502, code: "sync_failed" },
  stash_failed: { status: 409, code: "stash_failed" },
  switch_failed: { status: 409, code: "switch_failed" },
  search_failed: { status: 500, code: "internal" },
  token_unavailable: { status: 409, code: "github_not_connected" },
  credential_leak: { status: 500, code: "internal" },
};

function relayRefusal(reply: FastifyReply, err: StudioGitRefusal): FastifyReply {
  const mapped = REFUSAL_MAP[err.code];
  if (mapped.code === "internal") {
    return sendError(reply, 500, "internal", "Internal server error.");
  }
  return sendError(reply, mapped.status, mapped.code, err.message);
}

/** Unknown transport failure (worker down, malformed answer): loud, bounded. */
function gitUnavailable(reply: FastifyReply): FastifyReply {
  return sendError(
    reply,
    503,
    "studio_git_unavailable",
    "The git service is temporarily unavailable; please retry shortly.",
  );
}

/** One ownership + server-binding fence for every canonical Studio operation. */
async function requireBoundGitRepo(
  deps: GatewayDeps,
  uid: string,
  sessionId: string,
  reply: FastifyReply,
): Promise<{ userId: string; sessionId: string; repoDir: string } | null> {
  if (!isUuid(sessionId)) {
    notFound(reply);
    return null;
  }
  const session = await sessions.get(deps.db, sessionId, uid);
  if (session === null) {
    notFound(reply);
    return null;
  }
  const binding = await studioRepos.get(deps.db, uid, sessionId);
  if (binding === null) {
    sendError(reply, 409, "no_repo", "Clone a repository into this session first.");
    return null;
  }
  return { userId: uid, sessionId, repoDir: binding.repoDir };
}

function boundedLimit(
  reply: FastifyReply,
  raw: string | undefined,
  fallback: number,
  maximum: number,
): number | null {
  if (raw === undefined) return fallback;
  if (!/^\d+$/.test(raw)) {
    badRequest(reply, "limit must be a positive integer.");
    return null;
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 1) {
    badRequest(reply, "limit must be a positive integer.");
    return null;
  }
  return Math.min(value, maximum);
}

/** Normalize a relative path and reject .git/option-looking escapes locally. */
function safeStudioPath(reply: FastifyReply, raw: string): string | null {
  try {
    const path = assertSafeRelPath(raw);
    if (path.startsWith("-") || path.split("/").includes(".git")) {
      badRequest(reply, "That Studio path is not allowed.");
      return null;
    }
    return path;
  } catch (err) {
    if (err instanceof KeyLayoutError) {
      badRequest(reply, "That Studio path is not allowed.");
      return null;
    }
    throw err;
  }
}

function relayGitOperationError(
  request: FastifyRequest,
  reply: FastifyReply,
  err: unknown,
  operation: string,
): FastifyReply {
  const sessionId = (request.params as { id: string }).id;
  if (err instanceof StudioGitRefusal) {
    if (err.code === "credential_leak") {
      request.log.error({ sessionId }, "studio git reported a credential leak");
    }
    return relayRefusal(reply, err);
  }
  request.log.error({ err, sessionId }, `studio git ${operation} transport failed`);
  return gitUnavailable(reply);
}

export function registerStudioRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  // -- GET /studio/github ---------------------------------------------------
  // Is a GitHub account connected, and which one? The screen uses this to
  // decide between "Connected as @x" and "Connect GitHub".
  app.get("/studio/github", async (request, reply) => {
    noStore(reply);
    const { uid } = request.principal;

    const connection = await githubConnection(deps, uid);
    if (connection.kind === "not_configured") {
      return sendError(
        reply,
        503,
        "unavailable",
        "GitHub access is not configured on this deployment.",
      );
    }
    if (connection.kind === "not_connected") {
      return reply.send({ connected: false, login: null, source: "mcp" });
    }

    const client = createGithubClient({
      token: connection.token,
      ...(deps.github?.apiBase !== undefined ? { apiBase: deps.github.apiBase } : {}),
      ...(deps.github?.fetch !== undefined ? { fetchImpl: deps.github.fetch } : {}),
      ...(deps.github?.timeoutMs !== undefined ? { timeoutMs: deps.github.timeoutMs } : {}),
    });

    try {
      const { login } = await client.getUser();
      return reply.send({ connected: true, login, source: "mcp" });
    } catch (err) {
      if (err instanceof GithubError && err.kind === "unauthorized") {
        // The row exists but the token no longer works: report "disconnected"
        // so the screen offers reconnect instead of an error state.
        return reply.send({ connected: false, login: null, source: "mcp" });
      }
      if (err instanceof GithubError) {
        return sendError(reply, 503, "github_unavailable", "GitHub is temporarily unavailable.");
      }
      throw err;
    }
  });

  // -- GET /studio/repos ----------------------------------------------------
  app.get("/studio/repos", async (request, reply) => {
    noStore(reply);
    const { uid } = request.principal;
    const query = request.query as Record<string, string | string[] | undefined>;
    const page = parsePage(query.page);
    const perPage = parsePageLimit(query.perPage);

    const client = await githubClient(deps, uid, reply);
    if (client === null) return reply;

    let items: GithubRepo[];
    try {
      items = await client.listRepos(page, perPage);
    } catch (err) {
      if (err instanceof GithubError) return relayGithubError(reply, err);
      throw err;
    }

    // A full page means "there may be more" — GitHub's Link header is not
    // needed for a forward-only picker, and this answer never lies.
    return reply.send({ items, page, perPage, hasMore: items.length === perPage });
  });

  // -- GET /studio/repos/:owner/:repo/branches ------------------------------
  app.get("/studio/repos/:owner/:repo/branches", async (request, reply) => {
    noStore(reply);
    const { uid } = request.principal;
    const { owner, repo } = request.params as { owner: string; repo: string };
    if (!isSafeOwner(owner) || !isSafeRepoName(repo)) {
      return sendError(reply, 400, "bad_request", "That repository address is not valid.");
    }

    const query = request.query as Record<string, string | string[] | undefined>;
    const page = parsePage(query.page);
    const perPage = parsePageLimit(query.perPage);

    const client = await githubClient(deps, uid, reply);
    if (client === null) return reply;

    let items: GithubBranch[];
    try {
      items = await client.listBranches(owner, repo, page, perPage);
    } catch (err) {
      if (err instanceof GithubError) return relayGithubError(reply, err);
      throw err;
    }

    return reply.send({ items, page, perPage, hasMore: items.length === perPage });
  });

  // -- GET /studio/sessions/:id/git ----------------------------------------
  // The session's binding + whether git controls should be rendered at all.
  app.get("/studio/sessions/:id/git", async (request, reply) => {
    noStore(reply);
    const { id: sessionId } = request.params as { id: string };
    const { uid } = request.principal;

    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);

    const binding = await studioRepos.get(deps.db, uid, sessionId);
    const available = deps.studioGit !== undefined;

    return reply.send({
      sessionId,
      repo:
        binding === null
          ? null
          : {
              repo: binding.repo,
              repoDir: binding.repoDir,
              branch: binding.branch,
              updatedAt: binding.updatedAt,
            },
      git: {
        available,
        reason: available ? null : "studio_git_unavailable",
      },
    });
  });

  // -- POST /studio/sessions/:id/git/clone ---------------------------------
  app.post("/studio/sessions/:id/git/clone", async (request, reply) => {
    noStore(reply);
    const parsed = cloneBody.safeParse(request.body);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const body = parsed.data;

    const ref = parseRepoRef(body.repo);
    if (ref === null) {
      return sendError(
        reply,
        400,
        "bad_request",
        "Studio can only clone a github.com repository, written as owner/name or an https URL.",
      );
    }
    if (body.branch !== undefined && !isSafeBranch(body.branch)) {
      return sendError(reply, 400, "bad_request", `"${body.branch}" is not a valid branch name.`);
    }
    if (body.dest !== undefined && !isSafeRepoDir(body.dest)) {
      return sendError(
        reply,
        400,
        "bad_request",
        "The destination must be one folder name inside the workspace.",
      );
    }

    const { id: sessionId } = request.params as { id: string };
    const { uid } = request.principal;
    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);

    // The worker resolves the token per user; refuse here first so the user
    // is told to connect GitHub instead of watching a clone fail.
    const connection = await githubConnection(deps, uid);
    if (connection.kind === "not_configured") {
      return sendError(reply, 503, "unavailable", "GitHub access is not configured on this deployment.");
    }
    if (connection.kind === "not_connected") {
      return sendError(
        reply,
        409,
        "github_not_connected",
        "Connect GitHub in Settings to clone a repository.",
      );
    }

    if (!gitOr503(deps, reply)) return reply;

    let result;
    try {
      result = await deps.studioGit!.clone({
        userId: uid,
        sessionId,
        repo: ref.fullName,
        ...(body.branch !== undefined ? { branch: body.branch } : {}),
        ...(body.dest !== undefined ? { dest: body.dest } : {}),
      });
    } catch (err) {
      if (err instanceof StudioGitRefusal) {
        if (err.code === "credential_leak") {
          request.log.error({ sessionId }, "studio git reported a credential leak");
        }
        return relayRefusal(reply, err);
      }
      request.log.error({ err, sessionId }, "studio git clone transport failed");
      return gitUnavailable(reply);
    }

    // The binding is bookkeeping, not the clone itself. A database failure
    // must not present as "the clone failed" — the files are already there,
    // and a retry would hit destination_exists. Report it honestly instead.
    let bindingStored = false;
    try {
      const stored = await studioRepos.upsert(deps.db, {
        sessionId,
        userId: uid,
        repo: ref.fullName,
        repoDir: result.repoDir,
        branch: result.branch,
      });
      bindingStored = stored !== null;
    } catch (err) {
      request.log.error({ err, sessionId }, "studio repo binding could not be stored");
    }

    return reply.code(201).send({
      sessionId,
      repo: ref.fullName,
      repoDir: result.repoDir,
      branch: result.branch,
      bindingStored,
    });
  });

  // -- POST /studio/sessions/:id/git/branch --------------------------------
  app.post("/studio/sessions/:id/git/branch", async (request, reply) => {
    noStore(reply);
    const parsed = branchBody.safeParse(request.body);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const branch = parsed.data.branch;
    if (!isSafeBranch(branch)) {
      return sendError(reply, 400, "bad_request", `"${branch}" is not a valid branch name.`);
    }

    const { id: sessionId } = request.params as { id: string };
    const { uid } = request.principal;
    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);

    const binding = await studioRepos.get(deps.db, uid, sessionId);
    if (binding === null) {
      return sendError(
        reply,
        409,
        "no_repo",
        "Clone a repository into this session before switching branches.",
      );
    }
    if (!gitOr503(deps, reply)) return reply;

    let result;
    try {
      result = await deps.studioGit!.switchBranch({
        userId: uid,
        sessionId,
        repoDir: binding.repoDir,
        branch,
      });
    } catch (err) {
      if (err instanceof StudioGitRefusal) {
        if (err.code === "credential_leak") {
          request.log.error({ sessionId }, "studio git reported a credential leak");
        }
        return relayRefusal(reply, err);
      }
      request.log.error({ err, sessionId }, "studio git switch transport failed");
      return gitUnavailable(reply);
    }

    if (result.status === "failed") {
      return sendError(reply, 409, "switch_failed", result.message);
    }

    // Keep the binding honest: the next sync must run on the branch the user
    // is actually on.
    try {
      await studioRepos.upsert(deps.db, {
        sessionId,
        userId: uid,
        repo: binding.repo,
        repoDir: binding.repoDir,
        branch: result.branch,
      });
    } catch (err) {
      request.log.error({ err, sessionId }, "studio repo binding could not be updated");
    }

    return reply.send(result);
  });

  // -- POST /studio/sessions/:id/git/preflight ------------------------------
  // Fetch-only inspection. This deliberately never calls sync or changes the
  // server-side branch binding; sync remains the sole fast-forward operation.
  app.post("/studio/sessions/:id/git/preflight", async (request, reply) => {
    noStore(reply);
    const { id: sessionId } = request.params as { id: string };
    const ref = await requireBoundGitRepo(deps, request.principal.uid, sessionId, reply);
    if (ref === null) return reply;
    if (!emptyQuery.safeParse(request.query).success) {
      return badRequest(reply, "Invalid Studio preflight query.");
    }
    if (request.body !== undefined && !preflightBody.safeParse(request.body).success) {
      return badRequest(reply, "Invalid Studio preflight body.");
    }
    if (!gitOr503(deps, reply)) return reply;
    try {
      return reply.send(await deps.studioGit!.inspect(ref));
    } catch (err) {
      return relayGitOperationError(request, reply, err, "preflight");
    }
  });

  // -- GET /studio/sessions/:id/git/status ---------------------------------
  app.get("/studio/sessions/:id/git/status", async (request, reply) => {
    noStore(reply);
    const { id: sessionId } = request.params as { id: string };
    const ref = await requireBoundGitRepo(deps, request.principal.uid, sessionId, reply);
    if (ref === null) return reply;
    if (!emptyQuery.safeParse(request.query).success) {
      return badRequest(reply, "Invalid Studio status query.");
    }
    if (!gitOr503(deps, reply)) return reply;
    try {
      return reply.send(await deps.studioGit!.status(ref));
    } catch (err) {
      return relayGitOperationError(request, reply, err, "status");
    }
  });

  // -- GET /studio/sessions/:id/git/diff?staged&path ------------------------
  app.get("/studio/sessions/:id/git/diff", async (request, reply) => {
    noStore(reply);
    const { id: sessionId } = request.params as { id: string };
    const ref = await requireBoundGitRepo(deps, request.principal.uid, sessionId, reply);
    if (ref === null) return reply;
    const parsed = diffQuery.safeParse(request.query);
    if (!parsed.success) return badRequest(reply, "Invalid Studio diff query.");
    let path: string | undefined;
    if (parsed.data.path !== undefined) {
      const safePath = safeStudioPath(reply, parsed.data.path);
      if (safePath === null) return reply;
      path = safePath;
    }
    if (!gitOr503(deps, reply)) return reply;
    try {
      return reply.send(await deps.studioGit!.diff({
        ...ref,
        ...(parsed.data.staged !== undefined ? { staged: parsed.data.staged === "true" } : {}),
        ...(path !== undefined ? { path } : {}),
        maxBytes: DIFF_MAX_BYTES,
      }));
    } catch (err) {
      return relayGitOperationError(request, reply, err, "diff");
    }
  });

  // -- GET /studio/sessions/:id/git/logs?limit ------------------------------
  app.get("/studio/sessions/:id/git/logs", async (request, reply) => {
    noStore(reply);
    const { id: sessionId } = request.params as { id: string };
    const ref = await requireBoundGitRepo(deps, request.principal.uid, sessionId, reply);
    if (ref === null) return reply;
    const parsed = logsQuery.safeParse(request.query);
    if (!parsed.success) return badRequest(reply, "Invalid Studio logs query.");
    const limit = boundedLimit(reply, parsed.data.limit, DEFAULT_LOG_LIMIT, MAX_LOG_LIMIT);
    if (limit === null) return reply;
    if (!gitOr503(deps, reply)) return reply;
    try {
      return reply.send(await deps.studioGit!.logs({ ...ref, limit }));
    } catch (err) {
      return relayGitOperationError(request, reply, err, "logs");
    }
  });

  // -- GET /studio/sessions/:id/files/search?q&path&limit -------------------
  app.get("/studio/sessions/:id/files/search", async (request, reply) => {
    noStore(reply);
    const { id: sessionId } = request.params as { id: string };
    const ref = await requireBoundGitRepo(deps, request.principal.uid, sessionId, reply);
    if (ref === null) return reply;
    const parsed = searchQuery.safeParse(request.query);
    if (!parsed.success) return badRequest(reply, "Invalid Studio file search query.");
    let path: string | undefined;
    if (parsed.data.path !== undefined) {
      const safePath = safeStudioPath(reply, parsed.data.path);
      if (safePath === null) return reply;
      path = safePath;
    }
    const limit = boundedLimit(reply, parsed.data.limit, DEFAULT_SEARCH_LIMIT, MAX_SEARCH_LIMIT);
    if (limit === null) return reply;
    const repoDir = path === undefined
      ? ref.repoDir
      : ref.repoDir === "." ? path : `${ref.repoDir}/${path}`;
    if (!gitOr503(deps, reply)) return reply;
    try {
      return reply.send(await deps.studioGit!.search({
        userId: ref.userId,
        sessionId: ref.sessionId,
        repoDir,
        query: parsed.data.q,
        limit,
      }));
    } catch (err) {
      return relayGitOperationError(request, reply, err, "search");
    }
  });

  // -- POST /studio/sessions/:id/git/sync ----------------------------------
  // "Sync latest changes": fetch, then fast-forward only when the tree is
  // clean and the history is linear. A dirty tree or a divergence answers
  // `needs_merge` — the worker never resets or force-merges.
  app.post("/studio/sessions/:id/git/sync", async (request, reply) => {
    noStore(reply);
    const { id: sessionId } = request.params as { id: string };
    const { uid } = request.principal;
    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);

    const binding = await studioRepos.get(deps.db, uid, sessionId);
    if (binding === null) {
      return sendError(
        reply,
        409,
        "no_repo",
        "Clone a repository into this session before syncing.",
      );
    }
    if (!gitOr503(deps, reply)) return reply;

    let result;
    try {
      result = await deps.studioGit!.sync({
        userId: uid,
        sessionId,
        repoDir: binding.repoDir,
      });
    } catch (err) {
      if (err instanceof StudioGitRefusal) {
        if (err.code === "credential_leak") {
          request.log.error({ sessionId }, "studio git reported a credential leak");
        }
        return relayRefusal(reply, err);
      }
      request.log.error({ err, sessionId }, "studio git sync transport failed");
      return gitUnavailable(reply);
    }

    if (result.branch !== binding.branch) {
      try {
        await studioRepos.upsert(deps.db, {
          sessionId,
          userId: uid,
          repo: binding.repo,
          repoDir: binding.repoDir,
          branch: result.branch,
        });
      } catch (err) {
        request.log.error({ err, sessionId }, "studio repo binding could not be updated");
      }
    }

    return reply.send(result);
  });
}
