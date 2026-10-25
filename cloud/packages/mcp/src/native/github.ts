/**
 * Native GitHub MCP handler — a 1:1 port of the Dart NativeGitHubMcpHandler
 * (lib/core/native_mcp.dart): tool schemas and REST paths verbatim, responses
 * passed through as text (base64 file contents decoded), trimmed inline.
 *
 * Two cloud adaptations, both forced by the singleton + per-call context
 * design:
 *  - the token comes from ctx.secrets.GITHUB_TOKEN (decrypted per call); a
 *    missing token yields a configure-first message that never echoes a value
 *  - every request goes through ctx.fetchImpl — the per-call SSRF-guarded
 *    fetch — with redirects followed MANUALLY, one fetchImpl call per hop, so
 *    each Location hop is re-guarded (T3-review I1)
 */

import { trimToolResult, type McpToolDef, type McpToolCallResult } from "../client.js";
import type { McpCallContext, NativeMcpHandler } from "../transports/native.js";
import {
  assertBoundedHeadersOrCancel,
  egressResponseFromDecodedFetch,
  readBoundedBody,
  type EgressLimits,
  type ProviderEgress,
} from "../egress/responseLimits.js";
import { createSecretRedactor } from "../egress/redactor.js";
import {
  authorizeProviderOperation,
  snapshotProviderArgs,
  validateProviderArgs,
  type Effect,
  type ProviderOperation,
  type ToolContext,
} from "../providers/types.js";

export const GITHUB_TOOLS: readonly string[] = [
  "search_repositories",
  "get_file_contents",
  "list_issues",
  "get_issue",
  "list_pull_requests",
  "list_commits",
  "get_user",
];

const DEFAULT_API_BASE = "https://api.github.com";

const NO_TOKEN_MESSAGE =
  "Configure GitHub token first: add GITHUB_TOKEN in your Ovid integrations to use GitHub tools.";

interface GhRequest {
  url: string;
  method: ProviderOperation["request"]["method"];
  headers: Record<string, string>;
  body?: string;
}

const TOOLS: McpToolDef[] = [
  {
    name: "search_repositories",
    description: "Search for GitHub repositories by query.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "The search query." },
        per_page: { type: "integer", description: "Results per page (default: 30)." },
        page: { type: "integer", description: "Page number." },
      },
      required: ["query"],
    },
  },
  {
    name: "get_file_contents",
    description: "Get contents of a file or directory in a repository.",
    inputSchema: {
      type: "object",
      properties: {
        owner: { type: "string", description: "Repository owner." },
        repo: { type: "string", description: "Repository name." },
        path: { type: "string", description: "File path within the repository." },
        ref: { type: "string", description: "Branch, tag, or commit ref." },
      },
      required: ["owner", "repo", "path"],
    },
  },
  {
    name: "create_or_update_file",
    description: "Create or update a file in a repository.",
    inputSchema: {
      type: "object",
      properties: {
        owner: { type: "string", description: "Repository owner." },
        repo: { type: "string", description: "Repository name." },
        path: { type: "string", description: "File path within repository." },
        content: { type: "string", description: "File content." },
        message: { type: "string", description: "Commit message." },
        branch: { type: "string", description: "Branch to commit to." },
        sha: { type: "string", description: "Blob SHA if updating an existing file." },
      },
      required: ["owner", "repo", "path", "content", "message"],
    },
  },
  {
    name: "create_issue",
    description: "Create an issue in a repository.",
    inputSchema: {
      type: "object",
      properties: {
        owner: { type: "string", description: "Repository owner." },
        repo: { type: "string", description: "Repository name." },
        title: { type: "string", description: "Issue title." },
        body: { type: "string", description: "Issue body markdown." },
        labels: {
          type: "array",
          items: { type: "string" },
          description: "List of label names.",
        },
        assignees: {
          type: "array",
          items: { type: "string" },
          description: "List of GitHub usernames.",
        },
      },
      required: ["owner", "repo", "title"],
    },
  },
  {
    name: "list_issues",
    description: "List issues in a repository.",
    inputSchema: {
      type: "object",
      properties: {
        owner: { type: "string" },
        repo: { type: "string" },
        state: { type: "string", enum: ["open", "closed", "all"] },
        per_page: { type: "integer" },
        page: { type: "integer" },
      },
      required: ["owner", "repo"],
    },
  },
  {
    name: "get_issue",
    description: "Get details of a specific issue.",
    inputSchema: {
      type: "object",
      properties: {
        owner: { type: "string", description: "Repository owner." },
        repo: { type: "string", description: "Repository name." },
        issue_number: { type: "integer", description: "Issue number." },
      },
      required: ["owner", "repo", "issue_number"],
    },
  },
  {
    name: "add_issue_comment",
    description: "Add a comment to an existing issue.",
    inputSchema: {
      type: "object",
      properties: {
        owner: { type: "string", description: "Repository owner." },
        repo: { type: "string", description: "Repository name." },
        issue_number: { type: "integer", description: "Issue number." },
        body: { type: "string", description: "Comment body." },
      },
      required: ["owner", "repo", "issue_number", "body"],
    },
  },
  {
    name: "create_pull_request",
    description: "Create a new pull request.",
    inputSchema: {
      type: "object",
      properties: {
        owner: { type: "string", description: "Repository owner." },
        repo: { type: "string", description: "Repository name." },
        title: { type: "string", description: "PR title." },
        head: { type: "string", description: "Branch with changes." },
        base: { type: "string", description: "Target branch to merge into." },
        body: { type: "string", description: "PR body markdown." },
      },
      required: ["owner", "repo", "title", "head", "base"],
    },
  },
  {
    name: "list_pull_requests",
    description: "List pull requests in a repository.",
    inputSchema: {
      type: "object",
      properties: {
        owner: { type: "string" },
        repo: { type: "string" },
        state: { type: "string", enum: ["open", "closed", "all"] },
        per_page: { type: "integer" },
        page: { type: "integer" },
      },
      required: ["owner", "repo"],
    },
  },
  {
    name: "fork_repository",
    description: "Fork a repository.",
    inputSchema: {
      type: "object",
      properties: {
        owner: { type: "string", description: "Repository owner." },
        repo: { type: "string", description: "Repository name." },
        organization: { type: "string", description: "Optional target organization." },
      },
      required: ["owner", "repo"],
    },
  },
  {
    name: "list_commits",
    description: "List commits in a repository.",
    inputSchema: {
      type: "object",
      properties: {
        owner: { type: "string" },
        repo: { type: "string" },
        page: { type: "integer" },
        per_page: { type: "integer" },
      },
      required: ["owner", "repo"],
    },
  },
  {
    name: "get_user",
    description: "Get profile information for a GitHub user.",
    inputSchema: {
      type: "object",
      properties: {
        username: {
          type: "string",
          description: "GitHub username (optional, defaults to authenticated user).",
        },
      },
    },
  },
];

function toolResult(text: string, isError = false): McpToolCallResult {
  const trimmed = trimToolResult(text);
  return { text: trimmed, isError, content: [{ type: "text", text: trimmed }] };
}

function ghHeaders(token: string): Record<string, string> {
  return {
    Accept: "application/vnd.github+json",
    "User-Agent": "OvidAI/1.0",
    Authorization: `Bearer ${token}`,
    "X-GitHub-Api-Version": "2026-03-10",
  };
}

const READ_EFFECTS: Readonly<Record<string, Effect>> = {
  search_repositories: "read",
  get_file_contents: "read",
  list_issues: "read",
  get_issue: "read",
  list_pull_requests: "read",
  list_commits: "read",
  get_user: "read",
};

function boundedSchema(schema: Record<string, unknown>): Record<string, unknown> {
  const properties = Object.fromEntries(Object.entries(schema.properties ?? {}).map(([name, value]) => {
    const field = value as Record<string, unknown>;
    if (field.type === "string") return [name, { ...field, minLength: name === "path" ? 0 : 1, maxLength: 8_192 }];
    if (field.type === "integer") return [name, { ...field, minimum: 1, maximum: 100 }];
    if (field.type === "array") return [name, { ...field, maxItems: 100, items: { type: "string", minLength: 1, maxLength: 256 } }];
    return [name, field];
  }));
  return {
    ...schema,
    properties,
    additionalProperties: false,
    maxProperties: Object.keys(properties).length,
  };
}

const READ_REQUEST_PATHS: Readonly<Record<string, string>> = {
  search_repositories: "/search/repositories",
  get_file_contents: "/repos/{owner}/{repo}/contents/{path}",
  list_issues: "/repos/{owner}/{repo}/issues",
  get_issue: "/repos/{owner}/{repo}/issues/{issue_number}",
  list_pull_requests: "/repos/{owner}/{repo}/pulls",
  list_commits: "/repos/{owner}/{repo}/commits",
  get_user: "/user",
};

export const GITHUB_READ_OPERATIONS: readonly ProviderOperation[] = TOOLS.flatMap((tool) => {
  const effect = READ_EFFECTS[tool.name];
  const pathTemplate = READ_REQUEST_PATHS[tool.name];
  if (effect === undefined || pathTemplate === undefined) return [];
  return [{
    name: tool.name,
    description: tool.description ?? `Read ${tool.name} through GitHub REST.`,
    inputSchema: boundedSchema(tool.inputSchema ?? {}),
    effect,
    approval: "mode",
    requiredScopes: tool.name === "list_issues" || tool.name === "get_issue"
      ? ["Issues: Read"]
      : tool.name === "get_user" || tool.name === "search_repositories"
        ? []
        : ["Contents: Read"],
    request: { originKey: "github", method: "GET", pathTemplate },
    limits: { timeoutMs: 30_000, responseBytes: 65_536, frameBytes: 65_536, pageBytes: 65_536 },
    outputPolicy: { kind: "redacted_text", maxBytes: 65_536 },
  }];
});

function str(v: unknown): string | undefined {
  return typeof v === "string" ? v : undefined;
}

function num(v: unknown, fallback: number): number {
  return typeof v === "number" ? v : fallback;
}

function safeRepositoryPath(value: string): boolean {
  if (value.startsWith("/") || value.includes("\\") || /[\u0000-\u001f]/.test(value)) return false;
  return value.split("/").every((segment) => {
    if (segment === "." || segment === "..") return false;
    try {
      const decoded = decodeURIComponent(segment);
      return decoded !== "." && decoded !== ".." && !decoded.includes("/") && !decoded.includes("\\");
    } catch {
      return true; // A literal percent is encoded as data before the request.
    }
  });
}

function encodeRepositoryPath(value: string): string {
  return value.split("/").map((segment) => encodeURIComponent(segment)).join("/");
}

function validOperationCoordinates(name: string, args: Record<string, unknown>): boolean {
  for (const key of ["owner", "repo"] as const) {
    const value = args[key];
    if (value !== undefined && (typeof value !== "string" || !/^[A-Za-z0-9_.-]+$/.test(value))) return false;
  }
  if (name === "get_file_contents") {
    const path = args.path;
    if (typeof path !== "string" || !safeRepositoryPath(path)) return false;
  }
  if (name === "get_user" && args.username !== undefined) {
    if (typeof args.username !== "string" || !/^[A-Za-z0-9-]*$/.test(args.username)) return false;
  }
  return true;
}

function nativeAuthorizationContext(ctx: McpCallContext): ToolContext {
  const candidate = ctx as unknown as Partial<ToolContext>;
  return {
    ...candidate,
    sessionId: candidate.sessionId ?? "",
    runId: candidate.runId ?? "",
    userId: candidate.userId ?? ctx.uid,
    connectionId: candidate.connectionId ?? "",
    providerId: "github",
    mode: candidate.mode ?? "safe",
    planMode: candidate.planMode ?? false,
    unattended: candidate.unattended ?? true,
    isSubagent: candidate.isSubagent ?? false,
    depth: candidate.depth ?? 0,
    callKey: candidate.callKey ?? "",
    signal: candidate.signal ?? new AbortController().signal,
  } as ToolContext;
}

export function createGitHubHandler(deps: { apiBase?: string; providerEgress?: ProviderEgress } = {}): NativeMcpHandler {
  const apiBase = (deps.apiBase ?? DEFAULT_API_BASE).replace(/\/+$/, "");
  const redactor = createSecretRedactor();

  async function request(ctx: McpCallContext, req: GhRequest): Promise<{ ok: boolean; status: number; body: string }> {
    const limits: EgressLimits = {
      connectMs: 30_000,
      headersMs: 30_000,
      idleMs: 30_000,
      totalMs: 30_000,
      maxRedirects: 0,
      headerBytes: 8_192,
      responseBytes: 65_536,
      decompressedBytes: 262_144,
    };
    const token = req.headers.Authorization?.replace(/^Bearer /, "") ?? "";
    const response = deps.providerEgress !== undefined
      ? await deps.providerEgress.request({
          originKey: "github",
          url: new URL(req.url),
          method: req.method,
          headers: req.headers,
          ...(req.body === undefined ? {} : { body: new TextEncoder().encode(req.body) }),
          secretValues: [token],
          privileged: true,
          redirect: "deny",
          limits,
          signal: AbortSignal.timeout(limits.totalMs),
        })
      : await (async () => {
          const legacy = await ctx.fetchImpl(req.url, {
            method: req.method,
            headers: req.headers,
            body: req.body,
            redirect: "manual",
            signal: AbortSignal.timeout(limits.totalMs),
          });
          return egressResponseFromDecodedFetch(legacy, new URL(req.url));
        })();
    await assertBoundedHeadersOrCancel(response, limits);
    const bytes = await readBoundedBody(response, limits);
    const body = new TextDecoder().decode(bytes);
    return { ok: response.status >= 200 && response.status < 300, status: response.status, body };
  }

  async function get(ctx: McpCallContext, url: string, token: string): Promise<McpToolCallResult> {
    const r = await request(ctx, { url, method: "GET", headers: ghHeaders(token) });
    return r.ok ? toolResult(redactor.text(r.body, [token])) : toolResult(`Provider request failed (HTTP ${r.status}).`, true);
  }

  async function send(
    ctx: McpCallContext,
    url: string,
    method: "POST" | "PUT",
    token: string,
    bodyMap: Record<string, unknown>,
  ): Promise<McpToolCallResult> {
    const r = await request(ctx, {
      url,
      method,
      headers: ghHeaders(token),
      body: JSON.stringify(bodyMap),
    });
    return r.ok ? toolResult(redactor.text(r.body, [token])) : toolResult(`Provider request failed (HTTP ${r.status}).`, true);
  }

  return {
    async initialize(): Promise<Record<string, unknown>> {
      return {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "github", version: "1.0.0" },
      };
    },

    async listTools(): Promise<McpToolDef[]> {
      return GITHUB_READ_OPERATIONS.map((operation) => ({ ...operation, inputSchema: { ...operation.inputSchema } }));
    },

    async callTool(name: string, args: Record<string, unknown>, ctx: McpCallContext): Promise<McpToolCallResult> {
      const operation = GITHUB_READ_OPERATIONS.find((candidate) => candidate.name === name);
      if (operation === undefined) return toolResult(`Unknown tool "${name}" for github MCP`, true);
      try {
        args = snapshotProviderArgs(args);
      } catch {
        return toolResult("Invalid operation arguments.", true);
      }
      if (!validateProviderArgs(operation.inputSchema, args).ok || !validOperationCoordinates(name, args)) {
        return toolResult("Invalid operation arguments.", true);
      }
      const authorization = await authorizeProviderOperation(nativeAuthorizationContext(ctx), operation, args);
      if (authorization.kind === "deny") return toolResult(`Operation denied (${authorization.code}).`, true);
      const authToken = (ctx.secrets.GITHUB_TOKEN ?? "").trim();
      if (authToken === "") {
        return toolResult(NO_TOKEN_MESSAGE, true);
      }

      try {
        switch (name) {
          case "search_repositories": {
            const q = encodeURIComponent(str(args.query) ?? "");
            const perPage = num(args.per_page, 30);
            const page = num(args.page, 1);
            return await get(ctx, `${apiBase}/search/repositories?q=${q}&per_page=${perPage}&page=${page}`, authToken);
          }

          case "get_file_contents": {
            const owner = str(args.owner);
            const repo = str(args.repo);
            const path = str(args.path);
            const ref = str(args.ref);
            if (owner === undefined || repo === undefined || path === undefined) {
              return toolResult("Missing required arguments: owner, repo, path", true);
            }
            let url = `${apiBase}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/contents/${encodeRepositoryPath(path)}`;
            if (ref !== undefined && ref !== "") {
              url += `?ref=${encodeURIComponent(ref)}`;
            }
            const r = await request(ctx, { url, method: "GET", headers: ghHeaders(authToken) });
            if (!r.ok) return toolResult(`Provider request failed (HTTP ${r.status}).`, true);
            // base64-encoded file contents are decoded for the model
            try {
              const json = JSON.parse(r.body) as Record<string, unknown>;
              if (json.encoding === "base64" && typeof json.content === "string") {
                const rawBase64 = json.content.replaceAll("\n", "");
                const decoded = Buffer.from(rawBase64, "base64").toString("utf8");
                return toolResult(redactor.text(decoded, [authToken]));
              }
            } catch {
              // fall through: return the raw body (Dart parity)
            }
            return toolResult(redactor.text(r.body, [authToken]));
          }

          case "create_or_update_file": {
            const owner = str(args.owner);
            const repo = str(args.repo);
            const path = str(args.path);
            const content = str(args.content);
            const message = str(args.message);
            const branch = str(args.branch);
            const sha = str(args.sha);
            if (
              owner === undefined || repo === undefined || path === undefined ||
              content === undefined || message === undefined
            ) {
              return toolResult("Missing required arguments", true);
            }
            const bodyMap: Record<string, unknown> = {
              message,
              content: Buffer.from(content, "utf8").toString("base64"),
            };
            if (branch !== undefined) bodyMap.branch = branch;
            if (sha !== undefined) bodyMap.sha = sha;
            return await send(ctx, `${apiBase}/repos/${owner}/${repo}/contents/${path}`, "PUT", authToken, bodyMap);
          }

          case "create_issue": {
            const owner = str(args.owner);
            const repo = str(args.repo);
            const title = str(args.title);
            const body = str(args.body);
            if (owner === undefined || repo === undefined || title === undefined) {
              return toolResult("Missing required arguments: owner, repo, title", true);
            }
            const bodyMap: Record<string, unknown> = { title };
            if (body !== undefined) bodyMap.body = body;
            if (Array.isArray(args.labels)) bodyMap.labels = args.labels;
            if (Array.isArray(args.assignees)) bodyMap.assignees = args.assignees;
            return await send(ctx, `${apiBase}/repos/${owner}/${repo}/issues`, "POST", authToken, bodyMap);
          }

          case "list_issues": {
            const owner = str(args.owner);
            const repo = str(args.repo);
            const state = str(args.state) ?? "open";
            const perPage = num(args.per_page, 30);
            const page = num(args.page, 1);
            if (owner === undefined || repo === undefined) {
              return toolResult("Missing required arguments: owner, repo", true);
            }
            return await get(
              ctx,
              `${apiBase}/repos/${owner}/${repo}/issues?state=${state}&per_page=${perPage}&page=${page}`,
              authToken,
            );
          }

          case "get_issue": {
            const owner = str(args.owner);
            const repo = str(args.repo);
            const issueNum = args.issue_number;
            if (owner === undefined || repo === undefined || issueNum === undefined) {
              return toolResult("Missing required arguments: owner, repo, issue_number", true);
            }
            return await get(ctx, `${apiBase}/repos/${owner}/${repo}/issues/${issueNum}`, authToken);
          }

          case "add_issue_comment": {
            const owner = str(args.owner);
            const repo = str(args.repo);
            const issueNum = args.issue_number;
            const body = str(args.body);
            if (owner === undefined || repo === undefined || issueNum === undefined || body === undefined) {
              return toolResult("Missing required arguments", true);
            }
            return await send(ctx, `${apiBase}/repos/${owner}/${repo}/issues/${issueNum}/comments`, "POST", authToken, { body });
          }

          case "create_pull_request": {
            const owner = str(args.owner);
            const repo = str(args.repo);
            const title = str(args.title);
            const head = str(args.head);
            const base = str(args.base);
            const body = str(args.body);
            if (
              owner === undefined || repo === undefined || title === undefined ||
              head === undefined || base === undefined
            ) {
              return toolResult("Missing required arguments: owner, repo, title, head, base", true);
            }
            const bodyMap: Record<string, unknown> = { title, head, base };
            if (body !== undefined) bodyMap.body = body;
            return await send(ctx, `${apiBase}/repos/${owner}/${repo}/pulls`, "POST", authToken, bodyMap);
          }

          case "list_pull_requests": {
            const owner = str(args.owner);
            const repo = str(args.repo);
            const state = str(args.state) ?? "open";
            const perPage = num(args.per_page, 30);
            const page = num(args.page, 1);
            if (owner === undefined || repo === undefined) {
              return toolResult("Missing required arguments: owner, repo", true);
            }
            return await get(
              ctx,
              `${apiBase}/repos/${owner}/${repo}/pulls?state=${state}&per_page=${perPage}&page=${page}`,
              authToken,
            );
          }

          case "fork_repository": {
            const owner = str(args.owner);
            const repo = str(args.repo);
            const org = str(args.organization);
            if (owner === undefined || repo === undefined) {
              return toolResult("Missing required arguments: owner, repo", true);
            }
            const bodyMap: Record<string, unknown> = {};
            if (org !== undefined) bodyMap.organization = org;
            return await send(ctx, `${apiBase}/repos/${owner}/${repo}/forks`, "POST", authToken, bodyMap);
          }

          case "list_commits": {
            const owner = str(args.owner);
            const repo = str(args.repo);
            const page = num(args.page, 1);
            const perPage = num(args.per_page, 30);
            if (owner === undefined || repo === undefined) {
              return toolResult("Missing required arguments: owner, repo", true);
            }
            return await get(ctx, `${apiBase}/repos/${owner}/${repo}/commits?page=${page}&per_page=${perPage}`, authToken);
          }

          case "get_user": {
            const username = str(args.username);
            const url = username !== undefined && username !== ""
              ? `${apiBase}/users/${username}`
              : `${apiBase}/user`;
            return await get(ctx, url, authToken);
          }

          default:
            return toolResult(`Unknown tool "${name}" for github MCP`, true);
        }
      } catch {
        return toolResult("GitHub request failed.", true);
      }
    },
  };
}
