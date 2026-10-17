import { describe, expect, it } from "vitest";
import { createGitHubHandler, GITHUB_TOOLS } from "./github.js";
import type { McpCallContext } from "../transports/native.js";

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
    expect(headers["X-GitHub-Api-Version"]).toBe("2022-11-28");
    expect(headers["User-Agent"]).toBe("OvidAI/1.0");
  });

  it("search_repositories defaults per_page=30 page=1", async () => {
    const { calls, fetchImpl } = makeFetch(() => ok("{}"));
    const handler = createGitHubHandler({ apiBase: API_BASE });
    await handler.callTool("search_repositories", { query: "q" }, makeCtx({ secrets: { GITHUB_TOKEN: "t" }, fetchImpl }));
    expect(calls[0].url).toBe(`${API_BASE}/search/repositories?q=q&per_page=30&page=1`);
  });

  it("create_issue POSTs body {title, body}", async () => {
    const { calls, fetchImpl } = makeFetch(() => ok('{"number":7}'));
    const handler = createGitHubHandler({ apiBase: API_BASE });

    const res = await handler.callTool(
      "create_issue",
      { owner: "ovid", repo: "app", title: "Bug", body: "It broke" },
      makeCtx({ secrets: { GITHUB_TOKEN: "tok" }, fetchImpl }),
    );
    expect(res.isError).toBe(false);
    expect(calls[0].url).toBe(`${API_BASE}/repos/ovid/app/issues`);
    expect(calls[0].method).toBe("POST");
    expect(JSON.parse(String(calls[0].body))).toEqual({ title: "Bug", body: "It broke" });
  });

  it("create_or_update_file PUTs base64 content with message", async () => {
    const { calls, fetchImpl } = makeFetch(() => ok('{"content":{}}'));
    const handler = createGitHubHandler({ apiBase: API_BASE });

    await handler.callTool(
      "create_or_update_file",
      { owner: "o", repo: "r", path: "docs/a.md", content: "hello", message: "add doc", branch: "main", sha: "abc" },
      makeCtx({ secrets: { GITHUB_TOKEN: "tok" }, fetchImpl }),
    );
    expect(calls[0].url).toBe(`${API_BASE}/repos/o/r/contents/docs/a.md`);
    expect(calls[0].method).toBe("PUT");
    const body = JSON.parse(String(calls[0].body)) as Record<string, string>;
    expect(body.message).toBe("add doc");
    expect(body.content).toBe(Buffer.from("hello", "utf8").toString("base64"));
    expect(body.branch).toBe("main");
    expect(body.sha).toBe("abc");
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

  it("non-2xx → isError with status and body", async () => {
    const { fetchImpl } = makeFetch(() => new Response("nope", { status: 404 }));
    const handler = createGitHubHandler({ apiBase: API_BASE });
    const res = await handler.callTool("get_user", {}, makeCtx({ secrets: { GITHUB_TOKEN: "tok" }, fetchImpl }));
    expect(res.isError).toBe(true);
    expect(res.text).toContain("GitHub API error (404)");
    expect(res.text).toContain("nope");
  });

  it("fetch rejection → isError GitHub request failed (e.g. SSRF guard)", async () => {
    const fetchImpl = async (): Promise<Response> => {
      throw new Error("host \"api.github.test\" resolves to a non-public address (10.0.0.5)");
    };
    const handler = createGitHubHandler({ apiBase: API_BASE });
    const res = await handler.callTool("get_user", {}, makeCtx({ secrets: { GITHUB_TOKEN: "tok" }, fetchImpl }));
    expect(res.isError).toBe(true);
    expect(res.text).toContain("GitHub request failed:");
  });

  it("redirects followed manually — every hop goes back through ctx.fetchImpl (re-guarded)", async () => {
    const { calls, fetchImpl } = makeFetch((url) =>
      url.includes("/moved")
        ? new Response(null, { status: 302, headers: { location: `${API_BASE}/repos/o/r2/issues` } })
        : ok("[{\"number\":1}]"),
    );
    const handler = createGitHubHandler({ apiBase: API_BASE });

    const res = await handler.callTool(
      "list_issues",
      { owner: "o", repo: "moved" },
      makeCtx({ secrets: { GITHUB_TOKEN: "tok" }, fetchImpl }),
    );
    expect(res.isError).toBe(false);
    expect(calls.map((c) => c.url)).toEqual([
      `${API_BASE}/repos/o/moved/issues?state=open&per_page=30&page=1`,
      `${API_BASE}/repos/o/r2/issues`,
    ]);
    // the hole T3-review I1 flagged: no hop may be followed by the HTTP stack
    for (const c of calls) expect(c.redirect).toBe("manual");
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
    // the brief's enumerated set (a 1:1 port of the Dart tool list)
    for (const name of [
      "search_repositories",
      "get_file_contents",
      "create_issue",
      "list_issues",
      "get_issue",
      "add_issue_comment",
      "create_pull_request",
      "list_pull_requests",
      "fork_repository",
      "list_commits",
      "get_user",
    ]) {
      expect(GITHUB_TOOLS).toContain(name);
    }
    const search = tools.find((t) => t.name === "search_repositories");
    expect(search?.description).toBe("Search for GitHub repositories by query.");
    expect(search?.inputSchema).toEqual({
      type: "object",
      properties: {
        query: { type: "string", description: "The search query." },
        per_page: { type: "integer", description: "Results per page (default: 30)." },
        page: { type: "integer", description: "Page number." },
      },
      required: ["query"],
    });
  });

  it("initialize reports serverInfo github", async () => {
    const handler = createGitHubHandler({ apiBase: API_BASE });
    const res = await handler.initialize({});
    expect(res.serverInfo).toEqual({ name: "github", version: "1.0.0" });
    expect(res.capabilities).toEqual({ tools: {} });
  });
});
