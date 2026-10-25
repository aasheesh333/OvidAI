import { describe, expect, it } from "vitest";
import { createGitHubHandler, GITHUB_TOOLS } from "./github.js";
import type { McpCallContext } from "../transports/native.js";
import type { ProviderEgress } from "../egress/responseLimits.js";

// ---------------------------------------------------------------------------
// Native GitHub MCP handler — a 1:1 port of the Dart NativeGitHubMcpHandler:
// token from ctx.secrets.GITHUB_TOKEN (missing → configure-first message,
// never the value), REST paths verbatim against a configurable apiBase, and
// every request through ctx.fetchImpl (the SSRF-guarded per-call seam) with
// redirect:"manual" so each hop is re-guarded (T3-review I1).
// ---------------------------------------------------------------------------

const API_BASE = "https://api.github.test";

interface RecordedCall {
  url: string;
  method: string | undefined;
  headers: unknown;
  body: unknown;
  redirect: RequestRedirect | undefined;
}

function makeFetch(responder: (url: string, n: number) => Response): {
  calls: RecordedCall[];
  fetchImpl: (url: string, init?: RequestInit) => Promise<Response>;
} {
  const calls: RecordedCall[] = [];
  const fetchImpl = async (url: string, init?: RequestInit): Promise<Response> => {
    calls.push({
      url,
      method: init?.method,
      headers: init?.headers,
      body: init?.body,
      redirect: init?.redirect,
    });
    return responder(url, calls.length - 1);
  };
  return { calls, fetchImpl };
}

function makeCtx(opts: {
  secrets?: Record<string, string>;
  fetchImpl: (url: string, init?: RequestInit) => Promise<Response>;
}): McpCallContext {
  return { uid: "u-1", secrets: opts.secrets ?? {}, workspace: {}, fetchImpl: opts.fetchImpl };
}

const ok = (body: string): Response => new Response(body, { status: 200 });

describe("createGitHubHandler", () => {
  it("missing token → configure-first message, no HTTP call", async () => {
    const { calls, fetchImpl } = makeFetch(() => ok("{}"));
    const handler = createGitHubHandler({ apiBase: API_BASE });

    const noToken = await handler.callTool("search_repositories", { query: "x" }, makeCtx({ fetchImpl }));
    expect(noToken.isError).toBe(true);
    expect(noToken.text).toContain("Configure GitHub token first");

    const blankToken = await handler.callTool("get_user", {}, makeCtx({ secrets: { GITHUB_TOKEN: "   " }, fetchImpl }));
    expect(blankToken.isError).toBe(true);
    expect(blankToken.text).toContain("Configure GitHub token first");

    // the token value is never the message — there is none
    expect(calls).toHaveLength(0);
  });

  it("search_repositories GETs {apiBase}/search/repositories?q=…&per_page=…&page=… with GitHub headers", async () => {
    const { calls, fetchImpl } = makeFetch(() => ok('{"total_count":0,"items":[]}'));
    const handler = createGitHubHandler({ apiBase: API_BASE });

    const res = await handler.callTool(
      "search_repositories",
      { query: "ovid ai", per_page: 10, page: 2 },
      makeCtx({ secrets: { GITHUB_TOKEN: "tok-123" }, fetchImpl }),
    );
    expect(res.isError).toBe(false);
    expect(res.text).toBe('{"total_count":0,"items":[]}');

    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe(
      `${API_BASE}/search/repositories?q=${encodeURIComponent("ovid ai")}&per_page=10&page=2`,
    );
    expect(calls[0].method).toBe("GET");
    const headers = calls[0].headers as Record<string, string>;
    expect(headers.Accept).toBe("application/vnd.github+json");
    expect(headers.Authorization).toBe("Bearer tok-123");
    expect(headers["X-GitHub-Api-Version"]).toBe("2026-03-10");
    expect(headers["User-Agent"]).toBe("OvidAI/1.0");
  });

  it("search_repositories defaults per_page=30 page=1", async () => {
    const { calls, fetchImpl } = makeFetch(() => ok("{}"));
    const handler = createGitHubHandler({ apiBase: API_BASE });
    await handler.callTool("search_repositories", { query: "q" }, makeCtx({ secrets: { GITHUB_TOKEN: "t" }, fetchImpl }));
    expect(calls[0].url).toBe(`${API_BASE}/search/repositories?q=q&per_page=30&page=1`);
  });

  it("legacy create_issue and create_or_update_file are absent and uncallable", async () => {
    const { calls, fetchImpl } = makeFetch(() => ok("{}"));
    const handler = createGitHubHandler({ apiBase: API_BASE });
    for (const [name, args] of [
      ["create_issue", { owner: "ovid", repo: "app", title: "Bug" }],
      ["create_or_update_file", { owner: "o", repo: "r", path: "a", content: "x", message: "x" }],
    ] as const) {
      const result = await handler.callTool(name, args, makeCtx({ secrets: { GITHUB_TOKEN: "tok" }, fetchImpl }));
      expect(result.isError).toBe(true);
      expect(result.text).toContain("Unknown tool");
    }
    expect(calls).toHaveLength(0);
  });

  it("get_file_contents decodes base64 file content", async () => {
    const content = Buffer.from("# hi\nthere", "utf8").toString("base64");
    const { calls, fetchImpl } = makeFetch(() =>
      ok(JSON.stringify({ encoding: "base64", content, name: "a.md" })),
    );
    const handler = createGitHubHandler({ apiBase: API_BASE });

    const res = await handler.callTool(
      "get_file_contents",
      { owner: "o", repo: "r", path: "a.md", ref: "dev" },
      makeCtx({ secrets: { GITHUB_TOKEN: "tok" }, fetchImpl }),
    );
    expect(res.isError).toBe(false);
    expect(res.text).toBe("# hi\nthere");
    expect(calls[0].url).toBe(`${API_BASE}/repos/o/r/contents/a.md?ref=${encodeURIComponent("dev")}`);
  });

  it("get_file_contents returns status-only errors without raw body or echoed secrets", async () => {
    const token = "github-secret-token";
    const { fetchImpl } = makeFetch(() => new Response(
      JSON.stringify({ message: "private upstream detail", echo: token, authorization: `Bearer ${token}` }),
      { status: 404 },
    ));
    const result = await createGitHubHandler({ apiBase: API_BASE }).callTool(
      "get_file_contents",
      { owner: "o", repo: "r", path: "a.md" },
      makeCtx({ secrets: { GITHUB_TOKEN: token }, fetchImpl }),
    );
    expect(result.isError).toBe(true);
    expect(result.text).toBe("Provider request failed (HTTP 404).");
    expect(result.text).not.toContain(token);
    expect(result.text).not.toContain("private upstream detail");
  });

  it("non-2xx → bounded status-only error without upstream text", async () => {
    const { fetchImpl } = makeFetch(() => new Response("secret upstream detail", { status: 404 }));
    const handler = createGitHubHandler({ apiBase: API_BASE });
    const res = await handler.callTool("get_user", {}, makeCtx({ secrets: { GITHUB_TOKEN: "tok" }, fetchImpl }));
    expect(res.isError).toBe(true);
    expect(res.text).toBe("Provider request failed (HTTP 404).");
    expect(res.text).not.toContain("secret upstream detail");
  });

  it("fetch rejection → isError GitHub request failed (e.g. SSRF guard)", async () => {
    const fetchImpl = async (): Promise<Response> => {
      throw new Error("host \"api.github.test\" resolves to a non-public address (10.0.0.5)");
    };
    const handler = createGitHubHandler({ apiBase: API_BASE });
    const res = await handler.callTool("get_user", {}, makeCtx({ secrets: { GITHUB_TOKEN: "tok" }, fetchImpl }));
    expect(res.isError).toBe(true);
    expect(res.text).toContain("GitHub request failed");
  });

  it("privileged redirects are denied without replaying authorization", async () => {
    const { calls, fetchImpl } = makeFetch(() =>
      new Response("do not expose", { status: 302, headers: { location: `${API_BASE}/repos/o/r2/issues` } }),
    );
    const handler = createGitHubHandler({ apiBase: API_BASE });
    const res = await handler.callTool(
      "list_issues",
      { owner: "o", repo: "moved" },
      makeCtx({ secrets: { GITHUB_TOKEN: "tok" }, fetchImpl }),
    );
    expect(res.isError).toBe(true);
    expect(res.text).not.toContain("do not expose");
    expect(calls.map((c) => c.url)).toEqual([
      `${API_BASE}/repos/o/moved/issues?state=open&per_page=30&page=1`,
    ]);
    expect(calls[0].redirect).toBe("manual");
  });

  it("rejects path escapes and malformed repository coordinates before egress", async () => {
    const { calls, fetchImpl } = makeFetch(() => ok("{}"));
    const handler = createGitHubHandler({ apiBase: API_BASE });
    for (const args of [
      { owner: "../user", repo: "repo", path: "a.txt" },
      { owner: "o", repo: "r", path: "../user" },
      { owner: "o", repo: "r", path: "%2e%2e/user" },
      { owner: "o", repo: "r", path: "/absolute" },
    ]) {
      const result = await handler.callTool("get_file_contents", args, makeCtx({ secrets: { GITHUB_TOKEN: "t" }, fetchImpl }));
      expect(result.isError).toBe(true);
    }
    expect(calls).toHaveLength(0);
  });

  it("unknown tool → isError \"Unknown tool \"x\" for github MCP\"", async () => {
    const { fetchImpl } = makeFetch(() => ok("{}"));
    const handler = createGitHubHandler({ apiBase: API_BASE });
    const res = await handler.callTool("explode", {}, makeCtx({ secrets: { GITHUB_TOKEN: "t" }, fetchImpl }));
    expect(res.isError).toBe(true);
    expect(res.text).toBe('Unknown tool "explode" for github MCP');
  });

  it("results trimmed via trimToolResult", async () => {
    const { fetchImpl } = makeFetch(() => ok("x".repeat(10_000)));
    const handler = createGitHubHandler({ apiBase: API_BASE });
    const res = await handler.callTool("get_user", {}, makeCtx({ secrets: { GITHUB_TOKEN: "t" }, fetchImpl }));
    expect(res.text.length).toBeLessThan(10_000);
    expect(res.text).toContain("characters omitted —");
    expect(res.content).toEqual([{ type: "text", text: res.text }]);
  });

  it("listTools returns GITHUB_TOOLS with verbatim schemas", async () => {
    const handler = createGitHubHandler({ apiBase: API_BASE });
    const tools = await handler.listTools();
    expect(tools.map((t) => t.name)).toEqual([...GITHUB_TOOLS]);
    expect(GITHUB_TOOLS).toEqual([
      "search_repositories",
      "get_file_contents",
      "list_issues",
      "get_issue",
      "list_pull_requests",
      "list_commits",
      "get_user",
    ]);
    const search = tools.find((t) => t.name === "search_repositories");
    expect(search?.description).toBe("Search for GitHub repositories by query.");
    expect(search?.inputSchema).toEqual({
      type: "object",
      properties: {
        query: { type: "string", minLength: 1, maxLength: 8_192, description: "The search query." },
        per_page: { type: "integer", minimum: 1, maximum: 100, description: "Results per page (default: 30)." },
        page: { type: "integer", minimum: 1, maximum: 100, description: "Page number." },
      },
      required: ["query"],
      additionalProperties: false,
      maxProperties: 3,
    });
  });

  it("uses the typed bounded ProviderEgress boundary and denies redirects", async () => {
    const requests: Parameters<ProviderEgress["request"]>[0][] = [];
    const providerEgress: ProviderEgress = {
      async request(req) {
        requests.push(req);
        return {
          status: 200,
          headers: new Headers({ "content-type": "application/json" }),
          body: new Response('{"id":"user-1"}').body!,
          origin: new URL(API_BASE),
          remoteAddress: "192.0.2.20",
        };
      },
      async close() {},
    };
    const legacy = makeFetch(() => ok("{}"));
    const result = await createGitHubHandler({ apiBase: API_BASE, providerEgress }).callTool(
      "get_user",
      {},
      makeCtx({ secrets: { GITHUB_TOKEN: "github-token" }, fetchImpl: legacy.fetchImpl }),
    );
    expect(result.isError).toBe(false);
    expect(requests).toHaveLength(1);
    expect(requests[0].originKey).toBe("github");
    expect(requests[0].redirect).toBe("deny");
    expect(requests[0].secretValues).toContain("github-token");
    expect(legacy.calls).toHaveLength(0);
  });

  it("keeps unproven writes out of the read-first native definition", async () => {
    const tools = await createGitHubHandler({ apiBase: API_BASE }).listTools();
    expect(tools.map((tool) => tool.name)).not.toContain("create_issue");
    expect(tools.map((tool) => tool.name)).not.toContain("create_or_update_file");
    expect(tools.map((tool) => tool.name)).not.toContain("create_pull_request");
    expect(tools.every((tool) => (tool as { effect?: string }).effect === "read")).toBe(true);
  });

  it("initialize reports serverInfo github", async () => {
    const handler = createGitHubHandler({ apiBase: API_BASE });
    const res = await handler.initialize({});
    expect(res.serverInfo).toEqual({ name: "github", version: "1.0.0" });
    expect(res.capabilities).toEqual({ tools: {} });
  });
});
