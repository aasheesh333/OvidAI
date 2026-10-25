import { describe, expect, it, vi } from "vitest";
import { createFetchHandler, FETCH_TOOLS, followGuardedRedirects } from "./fetch.js";
import { MAX_TOOL_RESULT_CHARS } from "../client.js";
import { SsrfBlockedError } from "../ssrf.js";
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

function makeFetch(script: (url: string, n: number) => Response | Promise<Response>): {
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
  it("fetches an HTTPS URL via ctx.fetchImpl and returns text (html stripped)", async () => {
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

  it("non-2xx → generic status error without statusText, body, or header canaries", async () => {
    let cancelled = 0;
    const canary = "upstream-private-canary";
    const body = new ReadableStream<Uint8Array>({ cancel: () => { cancelled++; } });
    const { fetchImpl } = makeFetch(() => new Response(body, {
      status: 404,
      statusText: canary,
      headers: { "x-upstream-secret": canary },
    }));
    const handler = createFetchHandler();
    const res = await handler.callTool("fetch", { url: "https://example.test/nope" }, makeCtx(fetchImpl));
    expect(res).toEqual({
      text: "HTTP error 404",
      isError: true,
      content: [{ type: "text", text: "HTTP error 404" }],
    });
    expect(JSON.stringify(res)).not.toContain(canary);
    expect(cancelled).toBe(1);
  });

  it("guard rejection → a generic Fetch error without internal address text", async () => {
    const fetchImpl = async (): Promise<Response> => {
      throw new SsrfBlockedError('host "169.254.169.254" resolves to a non-public address (169.254.169.254)');
    };
    const handler = createFetchHandler();
    const res = await handler.callTool("fetch", { url: "https://169.254.169.254/latest/meta-data" }, makeCtx(fetchImpl));
    expect(res.isError).toBe(true);
    expect(res.text).toBe("Fetch error: request blocked.");
    expect(res.text).not.toContain("169.254.169.254");
  });

  it("default max_length is a 5000-character total including the truncation suffix", async () => {
    const { fetchImpl } = makeFetch(() => new Response("a".repeat(7000), { status: 200 }));
    const handler = createFetchHandler();
    const res = await handler.callTool("fetch", { url: "https://example.test/big" }, makeCtx(fetchImpl));
    expect(res.text).toBe(`${"a".repeat(4983)}\n\n... [truncated]`);
    expect(res.text).toHaveLength(5000);
    expect(res.content).toEqual([{ type: "text", text: res.text }]);
  });

  it("small max_length values reserve room for their omission marker", async () => {
    const { fetchImpl } = makeFetch((url) => new Response(
      url.includes("/exact") ? "abcdefghijklmnopqrstuvwxyz" : "abcdefghijkl",
      { status: 200 },
    ));
    const handler = createFetchHandler();
    const small = await handler.callTool(
      "fetch",
      { url: "https://example.test/small", max_length: 8, raw: true },
      makeCtx(fetchImpl),
    );
    expect(small.text).toBe("abcdefg…");
    expect(small.text).toHaveLength(8);
    const exact = await handler.callTool(
      "fetch",
      { url: "https://example.test/exact", max_length: 24, raw: true },
      makeCtx(fetchImpl),
    );
    expect(exact.text).toBe("abcdefg\n\n... [truncated]");
    expect(exact.text).toHaveLength(24);
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
    expect(res.text.length).toBeLessThanOrEqual(MAX_TOOL_RESULT_CHARS);
    expect(Buffer.byteLength(res.text, "utf8")).toBeLessThanOrEqual(MAX_TOOL_RESULT_CHARS * 3);
    expect(res.content).toEqual([{ type: "text", text: res.text }]);
  });

  it("bounds final UTF-8 bytes as well as UTF-16 characters for multibyte output", async () => {
    const { fetchImpl } = makeFetch(() => new Response("é".repeat(20_000)));
    const result = await createFetchHandler().callTool(
      "fetch",
      { url: "https://example.test/multibyte", max_length: 100_000, raw: true },
      makeCtx(fetchImpl),
    );
    expect(result.text.length).toBeLessThanOrEqual(MAX_TOOL_RESULT_CHARS);
    expect(Buffer.byteLength(result.text, "utf8")).toBeLessThanOrEqual(MAX_TOOL_RESULT_CHARS * 3);
    expect(result.text).toContain("characters omitted —");
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

  it("marks only the terminal response as redirected after native-owned hops", async () => {
    const { calls, fetchImpl } = makeFetch((_url, n) => n === 0
      ? new Response(null, { status: 302, headers: { location: "/final" } })
      : new Response("landed"));
    const response = await followGuardedRedirects(fetchImpl, "https://example.test/start");
    expect(calls).toHaveLength(2);
    expect(response.redirected).toBe(true);
    expect(await response.text()).toBe("landed");
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

  it("rejects URL userinfo on a redirect before a second request and cancels the hop", async () => {
    let cancelled = 0;
    const canary = "redirect-userinfo-canary";
    const body = new ReadableStream<Uint8Array>({ cancel: () => { cancelled++; } });
    const { calls, fetchImpl } = makeFetch(() => new Response(body, {
      status: 302,
      headers: { location: `https://user:${canary}@target.test/final` },
    }));
    const res = await createFetchHandler().callTool(
      "fetch",
      { url: "https://example.test/start" },
      makeCtx(fetchImpl),
    );
    expect(res.isError).toBe(true);
    expect(res.text).toBe("Fetch error: request blocked.");
    expect(res.text).not.toContain(canary);
    expect(calls).toHaveLength(1);
    expect(cancelled).toBe(1);
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
    expect(missing.text).toContain("Invalid operation arguments");
    const invalid = await handler.callTool("fetch", { url: "not a url at all" }, makeCtx(fetchImpl));
    expect(invalid.isError).toBe(true);
    expect(invalid.text).toContain("invalid URL");
  });

  it("supports HTTPS only and rejects initial URL userinfo before transport", async () => {
    const { calls, fetchImpl } = makeFetch(() => new Response("must not be fetched"));
    const handler = createFetchHandler();
    for (const url of [
      "http://example.test/",
      "https://user:secret-canary@example.test/",
      "https://secret-canary@example.test/",
    ]) {
      const result = await handler.callTool("fetch", { url }, makeCtx(fetchImpl));
      expect(result.isError).toBe(true);
      expect(result.text).toBe("Fetch error: public HTTPS URL required");
      expect(result.text).not.toContain("secret-canary");
    }
    expect(calls).toHaveLength(0);
  });

  it("does not reflect caught transport internals or upstream canaries", async () => {
    const canary = "caught-internal-canary";
    const { fetchImpl } = makeFetch(() => { throw new Error(`socket failed: ${canary}`); });
    const result = await createFetchHandler().callTool(
      "fetch",
      { url: "https://example.test/" },
      makeCtx(fetchImpl),
    );
    expect(result).toEqual({
      text: "Fetch error: request failed.",
      isError: true,
      content: [{ type: "text", text: "Fetch error: request failed." }],
    });
    expect(JSON.stringify(result)).not.toContain(canary);
  });

  it("rejects caller-supplied auth, methods, and transport overrides before any request", async () => {
    const { calls, fetchImpl } = makeFetch(() => new Response("ok"));
    const handler = createFetchHandler();
    for (const args of [
      { url: "https://example.test", headers: { authorization: "Bearer secret" } },
      { url: "https://example.test", method: "POST" },
      { url: "https://example.test", proxy: "http://proxy.test" },
      { url: "https://example.test", unexpected: true },
    ]) {
      const result = await handler.callTool("fetch", args, makeCtx(fetchImpl));
      expect(result.isError).toBe(true);
    }
    expect(calls).toHaveLength(0);
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
    expect((tools[0] as { effect?: string }).effect).toBe("read");
    expect((tools[0] as { request?: { originKey?: string } }).request?.originKey).toBe("public-web");
    expect(tools[0].inputSchema).toEqual({
      type: "object",
      properties: {
        url: { type: "string", minLength: 1, maxLength: 2_048, description: "The public HTTPS URL to fetch (port 443 only; no userinfo)." },
        max_length: { type: "integer", minimum: 1, maximum: 100_000, description: "Maximum total returned characters, including any truncation notice; a 6000-character final cap also applies." },
        raw: { type: "boolean", description: "If true, return raw content without HTML-to-markdown conversion." },
      },
      required: ["url"],
      additionalProperties: false,
      maxProperties: 3,
    });
  });

  it("replaces invalid UTF-8 deterministically without changing raw/HTML mode semantics", async () => {
    const { fetchImpl } = makeFetch(() => new Response(new Uint8Array([0x66, 0x80, 0x67])));
    const result = await createFetchHandler().callTool(
      "fetch",
      { url: "https://example.test/invalid-utf8", raw: true },
      makeCtx(fetchImpl),
    );
    expect(result.isError).toBe(false);
    expect(result.text).toBe("f�g");
  });

  it("stops and closes a body at the 2 MiB read cap without waiting for another chunk", async () => {
    let cancelled = 0;
    const body = new ReadableStream<Uint8Array>({
      start(controller) { controller.enqueue(new Uint8Array(2 * 1024 * 1024)); },
      pull() {},
      cancel() { cancelled++; },
    });
    const { fetchImpl } = makeFetch(() => new Response(body));
    const result = await createFetchHandler().callTool(
      "fetch",
      { url: "https://example.test/exact-body-cap", max_length: 100_000, raw: true },
      makeCtx(fetchImpl),
    );
    expect(result.isError).toBe(false);
    expect(result.text.length).toBeLessThanOrEqual(MAX_TOOL_RESULT_CHARS);
    expect(cancelled).toBe(1);
    expect(body.locked).toBe(false);
  });

  it("does not start a request when the caller is already aborted", async () => {
    const { calls, fetchImpl } = makeFetch(() => new Response("must not be fetched"));
    const controller = new AbortController();
    controller.abort(new Error("caller-canary"));
    const ctx = Object.assign(makeCtx(fetchImpl), { signal: controller.signal });
    const result = await createFetchHandler().callTool(
      "fetch",
      { url: "https://example.test/pre-aborted" },
      ctx,
    );
    expect(result.isError).toBe(true);
    expect(result.text).toBe("Operation denied (cancelled).");
    expect(result.text).not.toContain("caller-canary");
    expect(calls).toHaveLength(0);
  });

  it("returns the 2 MiB prefix rather than a hard error when a larger body arrives", async () => {
    let cancelled = 0;
    const prefix = new Uint8Array(2 * 1024 * 1024).fill(0x61);
    const oversized = new Uint8Array(prefix.byteLength + 32);
    oversized.set(prefix, 0);
    oversized.fill(0x62, prefix.byteLength);
    const body = new ReadableStream<Uint8Array>({
      start(controller) { controller.enqueue(oversized); },
      pull() {},
      cancel() { cancelled++; },
    });
    const { fetchImpl } = makeFetch(() => new Response(body));
    const result = await createFetchHandler().callTool(
      "fetch",
      { url: "https://example.test/over-body-cap", max_length: 100_000, raw: true },
      makeCtx(fetchImpl),
    );
    expect(result.isError).toBe(false);
    expect(result.text.length).toBeLessThanOrEqual(MAX_TOOL_RESULT_CHARS);
    expect(result.text).toContain("characters omitted —");
    expect(result.text).not.toContain("b");
    expect(cancelled).toBe(1);
    expect(body.locked).toBe(false);
  });

  it("enforces the actual 30s deadline across a stalled redirect request", async () => {
    vi.useFakeTimers();
    try {
      const { fetchImpl } = makeFetch((_url, n) => n === 0
        ? new Response(null, { status: 302, headers: { location: "https://example.test/next" } })
        : new Promise<Response>(() => {}));
      const pending = createFetchHandler().callTool("fetch", { url: "https://example.test/start" }, makeCtx(fetchImpl));
      let settled = false;
      void pending.then(() => { settled = true; });
      await vi.advanceTimersByTimeAsync(30_000);
      expect(settled).toBe(true);
      const result = await pending;
      expect(result.isError).toBe(true);
      expect(result.text).toMatch(/timed out|abort|deadline/i);
    } finally {
      vi.useRealTimers();
    }
  });

  it("enforces the actual 30s deadline across a stalled response body and cancels its reader", async () => {
    vi.useFakeTimers();
    try {
      let cancelled = 0;
      const body = new ReadableStream<Uint8Array>({
        pull() {},
        cancel() { cancelled++; },
      });
      const { fetchImpl } = makeFetch(() => new Response(body, { status: 200 }));
      const pending = createFetchHandler().callTool("fetch", { url: "https://example.test/stalled-body" }, makeCtx(fetchImpl));
      let settled = false;
      void pending.then(() => { settled = true; });
      await vi.advanceTimersByTimeAsync(30_000);
      expect(settled).toBe(true);
      const result = await pending;
      expect(result.isError).toBe(true);
      expect(result.text).toMatch(/timed out|abort|deadline/i);
      expect(cancelled).toBe(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it("settles by the 30s deadline even when body cancellation never resolves", async () => {
    vi.useFakeTimers();
    try {
      const body = new ReadableStream<Uint8Array>({
        pull() {},
        cancel() { return new Promise<void>(() => {}); },
      });
      const { fetchImpl } = makeFetch(() => new Response(body, { status: 200 }));
      const pending = createFetchHandler().callTool(
        "fetch",
        { url: "https://example.test/never-resolving-cancel" },
        makeCtx(fetchImpl),
      );
      let settled = false;
      void pending.then(() => { settled = true; });
      await vi.advanceTimersByTimeAsync(30_000);
      expect(settled).toBe(true);
      const result = await pending;
      expect(result.isError).toBe(true);
      expect(result.text).toMatch(/timed out|abort|deadline/i);
      expect(body.locked).toBe(false);
    } finally {
      vi.useRealTimers();
    }
  });

  it("settles redirect cleanup by the 30s deadline when cancellation never resolves", async () => {
    vi.useFakeTimers();
    try {
      const body = new ReadableStream<Uint8Array>({
        pull() {},
        cancel() { return new Promise<void>(() => {}); },
      });
      const { fetchImpl } = makeFetch(() => new Response(body, {
        status: 302,
        headers: { location: "https://example.test/next" },
      }));
      const pending = createFetchHandler().callTool(
        "fetch",
        { url: "https://example.test/redirect-never-resolving-cancel" },
        makeCtx(fetchImpl),
      );
      let settled = false;
      void pending.then(() => { settled = true; });
      await vi.advanceTimersByTimeAsync(30_000);
      expect(settled).toBe(true);
      const result = await pending;
      expect(result.isError).toBe(true);
      expect(result.text).toMatch(/timed out|abort|deadline/i);
      expect(body.locked).toBe(false);
    } finally {
      vi.useRealTimers();
    }
  });

  it("sanitizes synchronous cleanup failures and releases the response reader", async () => {
    const body = new ReadableStream<Uint8Array>({
      start(controller) { controller.enqueue(new Uint8Array(2 * 1024 * 1024 + 1)); },
      cancel() { throw new Error("cleanup failed"); },
    });
    const { fetchImpl } = makeFetch(() => new Response(body, { status: 200 }));
    const result = await createFetchHandler().callTool(
      "fetch",
      { url: "https://example.test/cleanup-error" },
      makeCtx(fetchImpl),
    );
    expect(result.isError).toBe(true);
    expect(result.text).toBe("Fetch error: request failed.");
    expect(result.text).not.toContain("cleanup failed");
    expect(body.locked).toBe(false);
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
