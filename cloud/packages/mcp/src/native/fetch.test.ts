import { describe, expect, it } from "vitest";
import { createFetchHandler, FETCH_TOOLS } from "./fetch.js";
import type { McpCallContext } from "../transports/native.js";

// ---------------------------------------------------------------------------
// Native Fetch MCP handler — a 1:1 port of the Dart NativeFetchMcpHandler,
// with the egress seam swapped: the Dart class owned its URL policy, the
// cloud port delegates it to ctx.fetchImpl (the per-call SSRF-guarded
// fetch). Redirects are followed MANUALLY, one ctx.fetchImpl call per hop —
// so the guard re-runs scheme/host/port/DNS classification on every Location
// (T3-review I1: the stack must never follow a hop the guard has not seen).
// ---------------------------------------------------------------------------

interface RecordedCall {
  url: string;
  init: RequestInit | undefined;
}

function makeFetch(script: (url: string, n: number) => Response): {
  calls: RecordedCall[];
  fetchImpl: (url: string, init?: RequestInit) => Promise<Response>;
} {
  const calls: RecordedCall[] = [];
  const fetchImpl = async (url: string, init?: RequestInit): Promise<Response> => {
    calls.push({ url, init });
    return script(url, calls.length - 1);
  };
  return { calls, fetchImpl };
}

function makeCtx(fetchImpl: (url: string, init?: RequestInit) => Promise<Response>): McpCallContext {
  return { uid: "u-1", secrets: {}, workspace: {}, fetchImpl };
}

describe("createFetchHandler", () => {
  it("fetches http(s) URL via ctx.fetchImpl and returns text (html stripped)", async () => {
    const { calls, fetchImpl } = makeFetch(() =>
      new Response(
        "<html><head><style>body{}</style><script>alert(1)</script></head>" +
          "<body><h1>Title</h1><p>See <a href=\"https://x.test/docs\">the docs</a></p>" +
          "<strong>bold</strong>&nbsp;&amp;&nbsp;<em>it</em></body></html>",
        { status: 200 },
      ),
    );
    const handler = createFetchHandler();
    const res = await handler.callTool("fetch", { url: "https://example.test/page" }, makeCtx(fetchImpl));
    expect(res.isError).toBe(false);
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe("https://example.test/page");
    expect(res.text).toContain("# Title");
    expect(res.text).toContain("[the docs](https://x.test/docs)");
    expect(res.text).toContain("**bold**");
    expect(res.text).toContain("*it*");
    expect(res.text).not.toContain("alert(1)");
    expect(res.text).not.toContain("body{}");
    expect(res.text).not.toContain("<p>");
    expect(res.text).toContain("&");
  });

  it("raw=true returns the body untouched", async () => {
    const { fetchImpl } = makeFetch(() => new Response("<p>raw &amp; literal</p>", { status: 200 }));
    const handler = createFetchHandler();
    const res = await handler.callTool(
      "fetch",
      { url: "https://example.test/x", raw: true },
      makeCtx(fetchImpl),
    );
    expect(res.text).toBe("<p>raw &amp; literal</p>");
  });

  it("non-2xx → isError with status line", async () => {
    const { fetchImpl } = makeFetch(() => new Response("gone", { status: 404, statusText: "Not Found" }));
    const handler = createFetchHandler();
    const res = await handler.callTool("fetch", { url: "https://example.test/nope" }, makeCtx(fetchImpl));
    expect(res.isError).toBe(true);
    expect(res.text).toContain("HTTP error 404");
    expect(res.text).toContain("Not Found");
  });

  it("guard rejection (thrown SsrfBlockedError) → isError Fetch error", async () => {
    const fetchImpl = async (): Promise<Response> => {
      throw new Error('host "169.254.169.254" resolves to a non-public address (169.254.169.254)');
    };
    const handler = createFetchHandler();
    const res = await handler.callTool("fetch", { url: "http://169.254.169.254/latest/meta-data" }, makeCtx(fetchImpl));
    expect(res.isError).toBe(true);
    expect(res.text).toContain("Fetch error:");
  });

  it("default max_length truncates at 5000", async () => {
    const { fetchImpl } = makeFetch(() => new Response("a".repeat(7000), { status: 200 }));
    const handler = createFetchHandler();
    const res = await handler.callTool("fetch", { url: "https://example.test/big" }, makeCtx(fetchImpl));
    expect(res.text.startsWith("a".repeat(5000))).toBe(true);
    expect(res.text).toContain("... [truncated]");
    expect(res.text.length).toBeLessThan(5200);
  });

  it("oversized body trimmed at 6000 (hard cap MAX_TOOL_RESULT_CHARS)", async () => {
    const { fetchImpl } = makeFetch(() => new Response("b".repeat(20_000), { status: 200 }));
    const handler = createFetchHandler();
    // caller asks for more than the hard cap — the cap wins
    const res = await handler.callTool(
      "fetch",
      { url: "https://example.test/huge", max_length: 100_000 },
      makeCtx(fetchImpl),
    );
    expect(res.text).toContain("characters omitted —");
    expect(res.text.length).toBeGreaterThan(5900);
    expect(res.text.length).toBeLessThanOrEqual(6200);
  });

  it("redirects followed manually — every Location hop re-enters ctx.fetchImpl", async () => {
    const { calls, fetchImpl } = makeFetch((url) =>
      url.startsWith("https://example.test/start")
        ? new Response(null, { status: 302, headers: { location: "https://target.test/final" } })
        : new Response("landed", { status: 200 }),
    );
    const handler = createFetchHandler();
    const res = await handler.callTool("fetch", { url: "https://example.test/start" }, makeCtx(fetchImpl));
    expect(res.isError).toBe(false);
    expect(res.text).toBe("landed");
    expect(calls.map((c) => c.url)).toEqual(["https://example.test/start", "https://target.test/final"]);
    // I1: no hop is followed inside the HTTP stack — each is guarded first
    for (const c of calls) expect(c.init?.redirect).toBe("manual");
  });

  it("relative Location resolved against the current hop", async () => {
    const { calls, fetchImpl } = makeFetch((url, n) =>
      n === 0
        ? new Response(null, { status: 301, headers: { location: "/a/b" } })
        : new Response("ok", { status: 200 }),
    );
    const handler = createFetchHandler();
    const res = await handler.callTool("fetch", { url: "https://example.test/dir/" }, makeCtx(fetchImpl));
    expect(calls[1].url).toBe("https://example.test/a/b");
    expect(res.text).toBe("ok");
  });

  it("too many redirects → isError", async () => {
    const { fetchImpl } = makeFetch(
      (url) => new Response(null, { status: 302, headers: { location: `${url}/r` } }),
    );
    const handler = createFetchHandler();
    const res = await handler.callTool("fetch", { url: "https://example.test/loop" }, makeCtx(fetchImpl));
    expect(res.isError).toBe(true);
    expect(res.text).toContain("too many redirects");
  });

  it("missing url → isError; invalid URL → isError", async () => {
    const { fetchImpl } = makeFetch(() => new Response("", { status: 200 }));
    const handler = createFetchHandler();
    const missing = await handler.callTool("fetch", {}, makeCtx(fetchImpl));
    expect(missing.isError).toBe(true);
    expect(missing.text).toContain("Missing required url argument");
    const invalid = await handler.callTool("fetch", { url: "not a url at all" }, makeCtx(fetchImpl));
    expect(invalid.isError).toBe(true);
    expect(invalid.text).toContain("invalid URL");
  });

  it("unknown tool → isError \"Unknown tool … for fetch MCP\"", async () => {
    const handler = createFetchHandler();
    const res = await handler.callTool("post", { url: "https://x.test" }, makeCtx(async () => new Response("")));
    expect(res.isError).toBe(true);
    expect(res.text).toBe('Unknown tool "post" for fetch MCP');
  });

  it("listTools returns FETCH_TOOLS with the verbatim schema", async () => {
    const handler = createFetchHandler();
    const tools = await handler.listTools();
    expect(tools.map((t) => t.name)).toEqual([...FETCH_TOOLS]);
    expect(tools[0].inputSchema).toEqual({
      type: "object",
      properties: {
        url: { type: "string", description: "The URL to fetch." },
        max_length: { type: "integer", description: "Maximum character length of returned text." },
        raw: { type: "boolean", description: "If true, return raw content without markdown conversion." },
      },
      required: ["url"],
    });
  });

  it("initialize reports serverInfo fetch", async () => {
    const handler = createFetchHandler();
    expect(await handler.initialize({})).toEqual({
      protocolVersion: "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: "fetch", version: "1.0.0" },
    });
  });
});
