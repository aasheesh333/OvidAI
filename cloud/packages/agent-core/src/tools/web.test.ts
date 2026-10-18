import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";

import type { ApprovalDecision, ApprovalGate, ApprovalRequest, EgressFetch, SandboxPort } from "../ports.js";
import { createGuardedEgressFetch, createSsrfGuard } from "../ssrf.js";
import type { Tool, ToolContext } from "../types.js";
import { createFetchUrlTool, createWebSearchTool, WEB_SEARCH_MAX_QUERIES, WEB_SEARCH_MAX_RESULTS } from "./web.js";

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

const ctx = (): ToolContext => ({
  sessionId: "s1",
  runId: "r1",
  userId: "u1",
  mode: "auto",
  planMode: false,
  isSubagent: false,
  depth: 0,
  unattended: false,
  callKey: "toolcall-1",
  signal: new AbortController().signal,
});

function fakeSandbox() {
  const writes: Array<{ userId: string; path: string; content: string }> = [];
  const sandbox: SandboxPort = {
    exec: async () => ({ exitCode: 0, stdout: "", stderr: "" }),
    killCall: async () => {},
    readFile: async () => "",
    writeFile: async (userId, path, content) => {
      writes.push({ userId, path, content });
    },
    exists: async () => false,
    listDir: async () => [],
    jobStart: async () => ({ jobId: "job-1" }),
    jobOutput: async () => ({ output: "", running: false, exitCode: null }),
    jobList: async () => [],
    jobKill: async () => {},
  };
  return { sandbox, writes };
}

function fakeGate(decision: ApprovalDecision) {
  const calls: ApprovalRequest[] = [];
  const gate: ApprovalGate = {
    async approve(_ctx, req) {
      calls.push(req);
      return decision;
    },
  };
  return { gate, calls };
}

interface Recorded {
  method: string;
  url: string;
  headers: Record<string, string | string[] | undefined>;
}

const openServers: Array<() => void> = [];
afterEach(() => {
  for (const close of openServers.splice(0)) close();
});

function startServer(
  handler: (req: IncomingMessage, res: ServerResponse, hit: Recorded) => void,
): Promise<{ origin: string; requests: Recorded[] }> {
  const requests: Recorded[] = [];
  const server: Server = createServer((req, res) => {
    const hit: Recorded = {
      method: req.method ?? "",
      url: req.url ?? "",
      headers: req.headers,
    };
    requests.push(hit);
    handler(req, res, hit);
  });
  const ready = new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  openServers.push(() => {
    server.closeAllConnections();
    server.close();
  });
  return ready.then(() => {
    const { port } = server.address() as AddressInfo;
    return { origin: `http://127.0.0.1:${port}`, requests };
  });
}

/**
 * A REAL SsrfGuard with a table-backed stub resolver (T2's test seam): the
 * model-facing URL uses a hostname the table maps to a public address, while
 * the transport-level fetch below rewrites it onto the local test server —
 * so the full per-hop guard path runs against real HTTP.
 */
function makeEgress(port: number, table: Record<string, string[]>): EgressFetch {
  const guard = createSsrfGuard({ resolver: (host) => Promise.resolve(table[host] ?? []) });
  const toServer: typeof fetch = (url, init) => {
    const u = new URL(String(url));
    u.hostname = "127.0.0.1";
    u.port = String(port);
    return fetch(u, init);
  };
  return createGuardedEgressFetch(guard, toServer);
}

const TABLE: Record<string, string[]> = { "ok.example": ["93.184.216.34"] };

/** One DuckDuckGo-style result block (anchor + snippet pair) — Dart `_ddgResult`. */
const ddgResult = (title: string, href: string, snippet: string): string =>
  `<a class="result__a" href="${href}">${title}</a>` +
  `<a class="result__snippet" href="${href}">${snippet}z</a>`;

const ddgPage = (...results: string[]): string => `<html><body>${results.join("")}</body></html>`;

// ---------------------------------------------------------------------------
// fetch_url
// ---------------------------------------------------------------------------

describe("createFetchUrlTool", () => {
  it("is named fetch_url with a 60s budget", () => {
    const { sandbox } = fakeSandbox();
    const { gate } = fakeGate("allow");
    const tool = createFetchUrlTool({
      egress: makeEgress(1, TABLE),
      guard: createSsrfGuard({ resolver: (h) => Promise.resolve(TABLE[h] ?? []) }),
      approvals: gate,
      sandbox,
    });
    expect(tool.spec.name).toBe("fetch_url");
    expect(tool.timeoutMs).toBe(60_000);
  });

  it("happy path: asks the gate for the host, fetches with the OvidAgent UA, returns markdown", async () => {
    const { origin, requests } = await startServer((_req, res) => {
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end("<html><body><h1>Hello</h1><p>World</p></body></html>");
    });
    const port = Number(new URL(origin).port);
    const { sandbox, writes } = fakeSandbox();
    const { gate, calls } = fakeGate("allow");
    const tool = createFetchUrlTool({
      egress: makeEgress(port, TABLE),
      guard: createSsrfGuard({ resolver: (h) => Promise.resolve(TABLE[h] ?? []) }),
      approvals: gate,
      sandbox,
    });

    const res = await tool.execute({ url: "http://ok.example/page" }, ctx());
    expect(res.isError).toBeFalsy();
    expect(res.content).toContain("# Hello");
    expect(res.content).toContain("World");
    expect(writes).toEqual([]); // under the 8000 cap — no spill

    // exactly one request, with the pinned UA
    expect(requests).toHaveLength(1);
    expect(requests[0].headers["user-agent"]).toBe("OvidAgent/1.0");

    // the gate saw a host-targeted tool approval, allowAlways enabled
    expect(calls).toHaveLength(1);
    expect(calls[0].kind).toBe("tool");
    expect(calls[0].tool).toBe("fetch_url");
    expect(calls[0].hostTargets).toEqual(["ok.example"]);
    expect(calls[0].allowAlways).toBe(true);
  });

  it("spills markdown bodies over the 8000-char cap with the full text persisted", async () => {
    const big = `<p>${"x".repeat(20_000)}</p>`;
    const { origin } = await startServer((_req, res) => {
      res.writeHead(200, { "content-type": "text/html" });
      res.end(big);
    });
    const port = Number(new URL(origin).port);
    const { sandbox, writes } = fakeSandbox();
    const { gate } = fakeGate("allow");
    const tool = createFetchUrlTool({
      egress: makeEgress(port, TABLE),
      guard: createSsrfGuard({ resolver: (h) => Promise.resolve(TABLE[h] ?? []) }),
      approvals: gate,
      sandbox,
    });

    const res = await tool.execute({ url: "http://ok.example/big" }, ctx());
    const markdown = "x".repeat(20_000);
    expect(res.content).toContain("characters omitted");
    expect(res.content.startsWith(markdown.slice(0, 4000))).toBe(true);
    expect(res.content.endsWith(markdown.slice(markdown.length - 4000))).toBe(true);
    expect(writes).toHaveLength(1);
    expect(writes[0].content).toBe(markdown);
    expect(writes[0].path).toMatch(/^\.spill\/\d+\.txt$/);
  });

  it("returns raw text untouched when the content-type is not html", async () => {
    const { origin } = await startServer((_req, res) => {
      res.writeHead(200, { "content-type": "application/json" });
      res.end('{"not":"markdown"}');
    });
    const port = Number(new URL(origin).port);
    const { sandbox } = fakeSandbox();
    const { gate } = fakeGate("allow");
    const tool = createFetchUrlTool({
      egress: makeEgress(port, TABLE),
      guard: createSsrfGuard({ resolver: (h) => Promise.resolve(TABLE[h] ?? []) }),
      approvals: gate,
      sandbox,
    });
    const res = await tool.execute({ url: "http://ok.example/data.json" }, ctx());
    expect(res.content).toBe('{"not":"markdown"}');
  });

  it("gate deny → EXACTLY 'DENIED by user' and no fetch ever happens", async () => {
    const { origin, requests } = await startServer((_req, res) => {
      res.writeHead(200, { "content-type": "text/plain" });
      res.end("should never be reached");
    });
    const port = Number(new URL(origin).port);
    const { sandbox } = fakeSandbox();
    const { gate, calls } = fakeGate("deny");
    const tool = createFetchUrlTool({
      egress: makeEgress(port, TABLE),
      guard: createSsrfGuard({ resolver: (h) => Promise.resolve(TABLE[h] ?? []) }),
      approvals: gate,
      sandbox,
    });
    const res = await tool.execute({ url: "http://ok.example/secret" }, ctx());
    expect(res.content).toBe("DENIED by user");
    expect(requests).toHaveLength(0);
    expect(calls).toHaveLength(1);
  });

  it("gate 'always' proceeds like allow", async () => {
    const { origin } = await startServer((_req, res) => {
      res.writeHead(200, { "content-type": "text/plain" });
      res.end("granted");
    });
    const port = Number(new URL(origin).port);
    const { sandbox } = fakeSandbox();
    const { gate } = fakeGate("always");
    const tool = createFetchUrlTool({
      egress: makeEgress(port, TABLE),
      guard: createSsrfGuard({ resolver: (h) => Promise.resolve(TABLE[h] ?? []) }),
      approvals: gate,
      sandbox,
    });
    const res = await tool.execute({ url: "http://ok.example/" }, ctx());
    expect(res.content).toBe("granted");
  });

  it("a 302 to the cloud metadata address is blocked by the per-hop guard → fetch failed:", async () => {
    const { origin } = await startServer((_req, res) => {
      res.writeHead(302, { location: "http://169.254.169.254/" });
      res.end();
    });
    const port = Number(new URL(origin).port);
    const { sandbox } = fakeSandbox();
    const { gate } = fakeGate("allow");
    const tool = createFetchUrlTool({
      egress: makeEgress(port, TABLE),
      guard: createSsrfGuard({ resolver: (h) => Promise.resolve(TABLE[h] ?? []) }),
      approvals: gate,
      sandbox,
    });
    const res = await tool.execute({ url: "http://ok.example/hop" }, ctx());
    expect(res.content.startsWith("fetch failed:")).toBe(true);
    expect(res.content).toContain("169.254.169.254");
  });

  it("a name resolving to a private address is refused before any prompt (fail-closed)", async () => {
    const table: Record<string, string[]> = { "inner.example": ["93.184.216.34", "10.1.2.3"] };
    const { origin, requests } = await startServer((_req, res) => {
      res.writeHead(200, { "content-type": "text/plain" });
      res.end("reached");
    });
    const port = Number(new URL(origin).port);
    const { sandbox } = fakeSandbox();
    const { gate, calls } = fakeGate("allow");
    const tool = createFetchUrlTool({
      egress: makeEgress(port, table),
      guard: createSsrfGuard({ resolver: (h) => Promise.resolve(table[h] ?? []) }),
      approvals: gate,
      sandbox,
    });
    const res = await tool.execute({ url: "http://inner.example/" }, ctx());
    expect(res.content.startsWith("fetch failed:")).toBe(true);
    expect(res.content).toContain("non-public");
    expect(requests).toHaveLength(0);
    expect(calls).toHaveLength(0); // never prompt for a host the guard refuses
  });

  it("server 500 → fetch failed: HTTP 500", async () => {
    const { origin } = await startServer((_req, res) => {
      res.writeHead(500, { "content-type": "text/plain" });
      res.end("boom");
    });
    const port = Number(new URL(origin).port);
    const { sandbox } = fakeSandbox();
    const { gate } = fakeGate("allow");
    const tool = createFetchUrlTool({
      egress: makeEgress(port, TABLE),
      guard: createSsrfGuard({ resolver: (h) => Promise.resolve(TABLE[h] ?? []) }),
      approvals: gate,
      sandbox,
    });
    const res = await tool.execute({ url: "http://ok.example/" }, ctx());
    expect(res.content.startsWith("fetch failed:")).toBe(true);
    expect(res.content).toContain("HTTP 500");
  });

  it("refuses non-http(s) schemes before prompting (scheme-guard parity leg)", async () => {
    const { sandbox } = fakeSandbox();
    const { gate, calls } = fakeGate("allow");
    const tool = createFetchUrlTool({
      egress: makeEgress(1, TABLE),
      guard: createSsrfGuard({ resolver: (h) => Promise.resolve(TABLE[h] ?? []) }),
      approvals: gate,
      sandbox,
    });
    for (const bad of ["file:///etc/passwd", "javascript:alert(1)"]) {
      const res = await tool.execute({ url: bad }, ctx());
      expect(res.content.startsWith("fetch failed:")).toBe(true);
      expect(res.content).toContain("scheme");
    }
    expect(calls).toHaveLength(0);
  });

  it("an unparseable URL fails as fetch failed:", async () => {
    const { sandbox } = fakeSandbox();
    const { gate } = fakeGate("allow");
    const tool = createFetchUrlTool({
      egress: makeEgress(1, TABLE),
      guard: createSsrfGuard({ resolver: (h) => Promise.resolve(TABLE[h] ?? []) }),
      approvals: gate,
      sandbox,
    });
    const res = await tool.execute({ url: "http://" }, ctx());
    expect(res.content.startsWith("fetch failed:")).toBe(true);
    expect(res.content).toContain("not a valid URL");
  });
});

// ---------------------------------------------------------------------------
// web_search
// ---------------------------------------------------------------------------

describe("createWebSearchTool", () => {
  const plainEgress = (urls: string[]): EgressFetch => (url, init) => {
    urls.push(String(url));
    return fetch(url, init);
  };

  it("exports the Dart constants and the 60s budget", () => {
    expect(WEB_SEARCH_MAX_QUERIES).toBe(4);
    expect(WEB_SEARCH_MAX_RESULTS).toBe(8);
    const tool = createWebSearchTool({ egress: plainEgress([]) });
    expect(tool.spec.name).toBe("web_search");
    expect(tool.timeoutMs).toBe(60_000);
  });

  it("round-robin merges two queries, dedupes by URL, cites links", async () => {
    const q1 = ddgPage(
      ddgResult("Alpha result", "https://ex.com/alpha", "About alpha"),
      ddgResult("Shared result", "https://ex.com/shared", "Both"),
    );
    const q2 = ddgPage(
      ddgResult("Beta result", "https://ex.com/beta", "About beta"),
      ddgResult("Shared result dup", "https://ex.com/shared", "Dup"),
    );
    const { origin, requests } = await startServer((req, res) => {
      const html = req.url === "/?q=one" ? q1 : q2;
      res.writeHead(200, { "content-type": "text/html" });
      res.end(html);
    });
    const urls: string[] = [];
    const tool = createWebSearchTool({ egress: plainEgress(urls), ddgBase: origin });

    const res = await tool.execute({ queries: ["one", "two"] }, ctx());

    expect(requests).toHaveLength(2); // each query runs once
    expect(requests[0].headers["user-agent"]).toBe("OvidAgent/1.0");
    expect(res.content).toContain("Web search: one | two");
    expect(res.content).toContain("[Alpha result](https://ex.com/alpha)");
    expect(res.content).toContain("[Beta result](https://ex.com/beta)");
    expect(res.content).toContain("[Shared result](https://ex.com/shared)");
    expect(res.content).toContain("About alpha");
    // dedup: exactly one line for the shared URL
    expect(res.content.split("https://ex.com/shared").length - 1).toBe(1);
    // round-robin: rank-1 of A, rank-1 of B, then rank-2 (deduped)
    expect(res.content.indexOf("ex.com/alpha")).toBeLessThan(res.content.indexOf("ex.com/beta"));
    expect(res.content.indexOf("ex.com/beta")).toBeLessThan(res.content.indexOf("ex.com/shared"));
    expect(res.content).toContain("Cite the relevant URLs above as markdown links");
  });

  it("duplicate queries are trimmed + deduped and run once", async () => {
    const page = ddgPage(ddgResult("Only", "https://ex.com/only", "S"));
    const { origin, requests } = await startServer((_req, res) => {
      res.writeHead(200, { "content-type": "text/html" });
      res.end(page);
    });
    const tool = createWebSearchTool({ egress: plainEgress([]), ddgBase: origin });
    const res = await tool.execute({ queries: [" same ", "same", "same"] }, ctx());
    expect(requests).toHaveLength(1);
    expect(res.content).toContain("[Only](https://ex.com/only)");
  });

  it("rejects empty and oversized query arrays with the exact Dart errors", async () => {
    const tool = createWebSearchTool({ egress: plainEgress([]), ddgBase: "http://127.0.0.1:1" });
    const empty = await tool.execute({ queries: [] }, ctx());
    expect(empty.content).toBe("Error: queries must contain at least one query");
    const blank = await tool.execute({ queries: ["  ", ""] }, ctx());
    expect(blank.content).toBe("Error: queries must contain at least one query");
    const tooMany = await tool.execute(
      { queries: ["a", "b", "c", "d", "e"] },
      ctx(),
    );
    expect(tooMany.content).toBe("Error: queries must contain at most 4 queries");
  });

  it("one failing query fails the whole call — no partial results", async () => {
    const ok = ddgPage(ddgResult("Ok result", "https://ex.com/ok", "fine"));
    const { origin } = await startServer((req, res) => {
      if (req.url === "/?q=bad") {
        res.writeHead(503, { "content-type": "text/html" });
        res.end("unavailable");
      } else {
        res.writeHead(200, { "content-type": "text/html" });
        res.end(ok);
      }
    });
    const tool = createWebSearchTool({ egress: plainEgress([]), ddgBase: origin });
    const res = await tool.execute({ queries: ["ok", "bad"] }, ctx());
    expect(res.content.startsWith("Error: search failed for \"bad\"")).toBe(true);
    expect(res.content).toContain("HTTP 503");
    expect(res.content).not.toContain("[Ok result]");
  });

  it("unwraps DuckDuckGo /l/?uddg= redirect links to the real URL", async () => {
    const page = ddgPage(
      ddgResult(
        "Redirected",
        "//duckduckgo.com/l/?uddg=https%3A%2F%2Freal.com%2Fpage&rut=abc",
        "Snippet",
      ),
    );
    const { origin } = await startServer((_req, res) => {
      res.writeHead(200, { "content-type": "text/html" });
      res.end(page);
    });
    const tool = createWebSearchTool({ egress: plainEgress([]), ddgBase: origin });
    const res = await tool.execute({ queries: ["anything"] }, ctx());
    expect(res.content).toContain("[Redirected](https://real.com/page)");
    expect(res.content).not.toContain("duckduckgo.com/l/");
  });

  it("zero matches → No results found.", async () => {
    const { origin } = await startServer((_req, res) => {
      res.writeHead(200, { "content-type": "text/html" });
      res.end("<html><body>nothing here</body></html>");
    });
    const tool = createWebSearchTool({ egress: plainEgress([]), ddgBase: origin });
    const res = await tool.execute({ queries: ["void"] }, ctx());
    expect(res.content).toBe("No results found.");
  });

  it("caps at 8 merged results across queries and notes the truncation", async () => {
    const q1 = ddgPage(
      ...Array.from({ length: 6 }, (_, i) => ddgResult(`A${i}`, `https://ex.com/a${i}`, `sa${i}`)),
    );
    const q2 = ddgPage(
      ...Array.from({ length: 6 }, (_, i) => ddgResult(`B${i}`, `https://ex.com/b${i}`, `sb${i}`)),
    );
    const { origin } = await startServer((req, res) => {
      res.writeHead(200, { "content-type": "text/html" });
      res.end(req.url === "/?q=one" ? q1 : q2);
    });
    const tool = createWebSearchTool({ egress: plainEgress([]), ddgBase: origin });
    const res = await tool.execute({ queries: ["one", "two"] }, ctx());
    const lines = res.content.split("\n").filter((l) => l.startsWith("- ["));
    expect(lines).toHaveLength(8);
    expect(res.content).toContain("(Showing the first 8 sources. Refine the query for more.)");
    // round-robin: A0, B0, A1, B1, … — the 8 kept are the first four ranks
    // (the trailing z is the Dart fixture's snippet-vs-title marker)
    expect(lines[0]).toBe("- [A0](https://ex.com/a0) — sa0z");
    expect(lines[1]).toBe("- [B0](https://ex.com/b0) — sb0z");
    expect(lines[7]).toBe("- [B3](https://ex.com/b3) — sb3z");
    expect(res.content).not.toContain("a4");
  });

  it("parses at most 8 results per single query (no truncation note when nothing is dropped)", async () => {
    const many = ddgPage(
      ...Array.from({ length: 12 }, (_, i) => ddgResult(`R${i}`, `https://ex.com/r${i}`, `s${i}`)),
    );
    const { origin } = await startServer((_req, res) => {
      res.writeHead(200, { "content-type": "text/html" });
      res.end(many);
    });
    const tool = createWebSearchTool({ egress: plainEgress([]), ddgBase: origin });
    const res = await tool.execute({ queries: ["q"] }, ctx());
    const lines = res.content.split("\n").filter((l) => l.startsWith("- ["));
    expect(lines).toHaveLength(8);
    expect(res.content).toContain("[R0](https://ex.com/r0)");
    expect(res.content).toContain("[R7](https://ex.com/r7)");
    expect(res.content).not.toContain("[R8](https://ex.com/r8)");
    expect(res.content).not.toContain("Showing the first");
  });

  it("render lines put the snippet after the link, em-dash separated", async () => {
    const page = ddgPage(ddgResult("T", "https://ex.com/t", "the snippet"));
    const { origin } = await startServer((_req, res) => {
      res.writeHead(200, { "content-type": "text/html" });
      res.end(page);
    });
    const tool = createWebSearchTool({ egress: plainEgress([]), ddgBase: origin });
    const res = await tool.execute({ queries: ["q"] }, ctx());
    expect(res.content).toContain("- [T](https://ex.com/t) — the snippetz");
  });
});
