import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import type { JsonRpcMessage } from "../jsonrpc.js";
import { createSseTransport } from "./sse.js";
import { DEFAULT_STREAM_LIMITS } from "../egress/responseLimits.js";

// ---------------------------------------------------------------------------
// Legacy SSE transport (MCP 2024-11-05): a long-lived GET event stream whose
// first `endpoint` event names the POST target; JSON-RPC flows over the two
// channels. No MCP-Protocol-Version header on this legacy variant.
// ---------------------------------------------------------------------------

let server: Server | undefined;
let baseUrl = "";
let sseRes: ServerResponse | undefined;
const posts: { url: string; body: JsonRpcMessage }[] = [];

afterEach(async () => {
  if (server !== undefined) {
    const s = server;
    server = undefined;
    sseRes = undefined;
    s.closeAllConnections();
    await new Promise<void>((resolve) => s.close(() => resolve()));
  }
  posts.length = 0;
});

async function startFixture(
  handler: (req: IncomingMessage, res: ServerResponse) => void,
): Promise<string> {
  server = createServer(handler);
  await new Promise<void>((resolve) => server!.listen(0, "127.0.0.1", () => resolve()));
  const { port } = server.address() as AddressInfo;
  baseUrl = `http://127.0.0.1:${port}`;
  return baseUrl;
}

/** Server that answers the GET with an endpoint event and holds the stream. */
function sseServerWithEndpoint(
  onPost: (msg: JsonRpcMessage, res: ServerResponse) => void,
): (req: IncomingMessage, res: ServerResponse) => void {
  return (req, res) => {
    if (req.method === "GET") {
      res.writeHead(200, { "content-type": "text/event-stream" });
      res.write("event: endpoint\ndata: /msg?sid=1\n\n");
      sseRes = res;
      return;
    }
    let body = "";
    req.on("data", (c: Buffer) => (body += c.toString("utf8")));
    req.on("end", () => {
      const msg = JSON.parse(body) as JsonRpcMessage;
      posts.push({ url: req.url!, body: msg });
      onPost(msg, res);
    });
  };
}

async function waitFor(cond: () => boolean, ms = 2000): Promise<void> {
  const deadline = Date.now() + ms;
  while (!cond()) {
    if (Date.now() > deadline) throw new Error("waitFor: condition not met in time");
    await new Promise((r) => setTimeout(r, 10));
  }
}

describe("createSseTransport", () => {
  it("endpoint event provides POST target and messages flow both ways", async () => {
    await startFixture(
      sseServerWithEndpoint((msg, res) => {
        res.writeHead(202);
        res.end();
        if ("method" in msg && msg.method === "initialize" && sseRes !== undefined) {
          sseRes.write(
            `event: message\ndata: ${JSON.stringify({
              jsonrpc: "2.0",
              id: "id" in msg ? msg.id : 1,
              result: { protocolVersion: "2024-11-05" },
            })}\n\n`,
          );
        }
      }),
    );

    const t = createSseTransport({ url: baseUrl, fetchImpl: fetch });
    const got: JsonRpcMessage[] = [];
    const closes: { expected: boolean }[] = [];
    t.onMessage((m) => got.push(m));
    t.onClose((info) => closes.push(info));
    await t.start();
    // Relative endpoint "/msg?sid=1" resolved against the GET URL.
    await t.send({ jsonrpc: "2.0", id: 7, method: "initialize", params: {} });
    expect(posts).toEqual([
      { url: "/msg?sid=1", body: { jsonrpc: "2.0", id: 7, method: "initialize", params: {} } },
    ]);
    await waitFor(() => got.length > 0);
    expect(got).toEqual([
      { jsonrpc: "2.0", id: 7, result: { protocolVersion: "2024-11-05" } },
    ]);
    await t.close();
    expect(closes).toEqual([{ expected: true }]);
  });

  it("enforces JSON-RPC frame limits before dispatch and closes on overflow", async () => {
    await startFixture((req, res) => {
      if (req.method === "GET") {
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.write("event: endpoint\ndata: /msg\n\n");
        res.write(`event: message\ndata: ${JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          result: { padding: "x".repeat(200) },
        })}\n\n`);
        sseRes = res;
      }
    });
    const t = createSseTransport({
      url: baseUrl,
      fetchImpl: fetch,
      limits: {
        connectMs: 100,
        headersMs: 100,
        idleMs: 100,
        totalMs: 1_000,
        maxRedirects: 0,
        headerBytes: 1_024,
        responseBytes: 1_024,
        decompressedBytes: 1_024,
        sseEventBytes: 1_024,
        sseEventCount: 8,
        jsonRpcFrameBytes: 32,
        aggregateStreamBytes: 4_096,
        toolResultBytes: 1_024,
      },
    });
    const got: JsonRpcMessage[] = [];
    const closes: { expected: boolean }[] = [];
    t.onMessage((m) => got.push(m));
    t.onClose((info) => closes.push(info));
    await t.start();
    await waitFor(() => closes.length > 0);
    expect(got).toEqual([]);
    expect(closes).toEqual([{ expected: false }]);
    await t.close();
  });

  it("sanitizes raw and secret-bearing result.isError content before dispatch", async () => {
    await startFixture(sseServerWithEndpoint((_msg, res) => {
      res.writeHead(202);
      res.end();
    }));
    const t = createSseTransport({
      url: baseUrl,
      fetchImpl: fetch,
      accessToken: async () => "sse-token-canary",
    });
    const got: JsonRpcMessage[] = [];
    t.onMessage((m) => got.push(m));
    await t.start();
    for (const [id, text] of [[1, "raw provider failure"], [2, "failed with sse-token-canary"]] as const) {
      sseRes!.write(`event: message\ndata: ${JSON.stringify({
        jsonrpc: "2.0",
        id,
        result: { isError: true, content: [{ type: "text", text }] },
      })}\n\n`);
    }
    await waitFor(() => got.length === 2);
    for (const message of got) {
      expect(JSON.stringify(message)).toContain("MCP tool failed.");
      expect(JSON.stringify(message)).not.toContain("raw provider failure");
      expect(JSON.stringify(message)).not.toContain("sse-token-canary");
    }
    await t.close();
  });

  it("cancels the GET body when SSE header validation fails", async () => {
    let cancelled = 0;
    const body = new ReadableStream<Uint8Array>({
      pull() {},
      cancel() { cancelled++; },
    });
    const t = createSseTransport({
      url: "http://127.0.0.1:9463",
      fetchImpl: async () => new Response(body, {
        status: 200,
        headers: { "content-type": "text/event-stream", "x-overflow": "x".repeat(200) },
      }),
      limits: { ...DEFAULT_STREAM_LIMITS, headerBytes: 32 },
    });
    const failure = await t.start().then(() => undefined, (error: unknown) => error);
    expect(failure).toBeInstanceOf(Error);
    expect((failure as Error).message).toMatch(/header_bytes/);
    expect(cancelled).toBe(1);
  });

  it("cancels the POST body when SSE header validation fails", async () => {
    await startFixture(sseServerWithEndpoint((_msg, res) => {
      res.writeHead(202);
      res.end();
    }));
    let cancelled = 0;
    const postBody = new ReadableStream<Uint8Array>({
      pull() {},
      cancel() { cancelled++; },
    });
    const t = createSseTransport({
      url: baseUrl,
      fetchImpl: async (input, init) => {
        if (init?.method === "POST") {
          return new Response(postBody, {
            status: 202,
            headers: { "x-overflow": "x".repeat(400) },
          });
        }
        return fetch(input, init);
      },
      limits: { ...DEFAULT_STREAM_LIMITS, headerBytes: 256 },
    });
    await t.start();
    await expect(t.send({ jsonrpc: "2.0", method: "notifications/initialized" })).rejects.toThrow(/header_bytes/);
    expect(cancelled).toBe(1);
    await t.close();
  });

  it("GET refusal surfaces as transport start error", async () => {
    await startFixture((_req, res) => {
      res.writeHead(404);
      res.end();
    });

    const t = createSseTransport({ url: baseUrl, fetchImpl: fetch });
    await expect(t.start()).rejects.toThrow(/404/);
  });

  it("server closing the stream fires onClose unexpected", async () => {
    await startFixture(sseServerWithEndpoint((_msg, res) => {
      res.writeHead(202);
      res.end();
    }));

    const t = createSseTransport({ url: baseUrl, fetchImpl: fetch });
    const closes: { expected: boolean }[] = [];
    t.onClose((info) => closes.push(info));
    await t.start();
    expect(closes).toHaveLength(0);
    sseRes!.end(); // server hangs up the event stream
    await waitFor(() => closes.length > 0);
    expect(closes).toEqual([{ expected: false }]);
    await t.close();
  });
});
