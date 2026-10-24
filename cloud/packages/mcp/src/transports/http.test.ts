import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import type { JsonRpcMessage } from "../jsonrpc.js";
import {
  createHttpTransport,
  McpAuthRequiredError,
  McpSessionExpiredError,
  type HttpTransport,
} from "./http.js";

// ---------------------------------------------------------------------------
// Streamable HTTP transport (MCP 2025-06-18): every message is a POST to the
// single URL; the response body is JSON or SSE-formatted; Mcp-Session-Id and
// MCP-Protocol-Version are echoed on later requests. Fixtures are real
// node:http servers on 127.0.0.1:0.
// ---------------------------------------------------------------------------

interface CapturedRequest {
  method: string;
  url: string;
  headers: IncomingMessage["headers"];
  body: JsonRpcMessage;
}

let server: Server | undefined;
let baseUrl = "";
const requests: CapturedRequest[] = [];

afterEach(async () => {
  if (server !== undefined) {
    const s = server;
    server = undefined;
    s.closeAllConnections();
    await new Promise<void>((resolve) => s.close(() => resolve()));
  }
  requests.length = 0;
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

/** Handler that records every request and delegates to per-test logic. */
function recording(
  onBody: (msg: JsonRpcMessage, res: ServerResponse) => void,
): (req: IncomingMessage, res: ServerResponse) => void {
  return (req, res) => {
    let body = "";
    req.on("data", (c: Buffer) => (body += c.toString("utf8")));
    req.on("end", () => {
      const msg = JSON.parse(body) as JsonRpcMessage;
      requests.push({ method: req.method!, url: req.url!, headers: req.headers, body: msg });
      onBody(msg, res);
    });
  };
}

const INIT_REQUEST: JsonRpcMessage = {
  jsonrpc: "2.0",
  id: 1,
  method: "initialize",
  params: { protocolVersion: "2025-06-18" },
};

describe("createHttpTransport", () => {
  it("initialize round-trip captures Mcp-Session-Id and echoes it on later requests", async () => {
    await startFixture(
      recording((msg, res) => {
        if ("method" in msg && msg.method === "initialize") {
          res.writeHead(200, {
            "content-type": "application/json",
            "mcp-session-id": "sess-42",
          });
          res.end(
            JSON.stringify({
              jsonrpc: "2.0",
              id: "id" in msg ? msg.id : 1,
              result: { protocolVersion: "2025-06-18" },
            }),
          );
        } else {
          res.writeHead(202);
          res.end();
        }
      }),
    );

    const t = createHttpTransport({ url: baseUrl, fetchImpl: fetch });
    const got: JsonRpcMessage[] = [];
    t.onMessage((m) => got.push(m));
    await t.start();
    await t.send(INIT_REQUEST);
    expect(got).toHaveLength(1); // response parsed before send resolves
    await t.send({ jsonrpc: "2.0", method: "notifications/initialized" });
    expect(requests).toHaveLength(2);
    expect(requests[1]!.headers["mcp-session-id"]).toBe("sess-42");
    expect(requests[1]!.headers["content-type"]).toBe("application/json");
    expect(requests[1]!.headers["accept"]).toBe("application/json, text/event-stream");
    await t.close();
  });

  it("SSE-formatted response body is parsed (comments skipped, partial lines across chunks)", async () => {
    await startFixture(
      recording((msg, res) => {
        res.writeHead(200, { "content-type": "text/event-stream" });
        // A notification arrives before the response frame; a `:` comment is
        // skipped; the response data line is split across two write chunks.
        const notification = `data: ${JSON.stringify({
          jsonrpc: "2.0",
          method: "notifications/roots/list_changed",
        })}\n\n`;
        const response = `: keep-alive comment\ndata: ${JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          result: { protocolVersion: "2025-06-18" },
        })}\n\n`;
        res.write(notification);
        res.write(response.slice(0, 20));
        res.end(response.slice(20));
      }),
    );

    const t = createHttpTransport({ url: baseUrl, fetchImpl: fetch });
    const got: JsonRpcMessage[] = [];
    t.onMessage((m) => got.push(m));
    await t.start();
    await t.send(INIT_REQUEST);
    expect(got).toEqual([
      { jsonrpc: "2.0", method: "notifications/roots/list_changed" },
      { jsonrpc: "2.0", id: 1, result: { protocolVersion: "2025-06-18" } },
    ]);
    await t.close();
  });

  it("JSON response body parses", async () => {
    await startFixture(
      recording((msg, res) => {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(
          JSON.stringify({
            jsonrpc: "2.0",
            id: "id" in msg ? msg.id : 1,
            result: { protocolVersion: "2025-06-18" },
          }),
        );
      }),
    );

    const t = createHttpTransport({ url: baseUrl, fetchImpl: fetch });
    const got: JsonRpcMessage[] = [];
    t.onMessage((m) => got.push(m));
    await t.start();
    await t.send(INIT_REQUEST);
    expect(got).toEqual([
      { jsonrpc: "2.0", id: 1, result: { protocolVersion: "2025-06-18" } },
    ]);
    await t.close();
  });

  it("202 on a notification POST resolves send with no message dispatched", async () => {
    await startFixture(
      recording((_msg, res) => {
        res.writeHead(202);
        res.end();
      }),
    );

    const t = createHttpTransport({ url: baseUrl, fetchImpl: fetch });
    const got: JsonRpcMessage[] = [];
    t.onMessage((m) => got.push(m));
    await t.start();
    await t.send({ jsonrpc: "2.0", method: "notifications/initialized" });
    expect(got).toHaveLength(0);
    await t.close();
  });

  it("401 throws McpAuthRequiredError carrying WWW-Authenticate", async () => {
    await startFixture(
      recording((_msg, res) => {
        res.writeHead(401, {
          "www-authenticate": 'Bearer realm="mcp", error="invalid_token"',
        });
        res.end();
      }),
    );

    const t = createHttpTransport({ url: baseUrl, fetchImpl: fetch });
    await t.start();
    const err: unknown = await t.send(INIT_REQUEST).then(
      () => undefined,
      (e: unknown) => e,
    );
    expect(err).toBeInstanceOf(McpAuthRequiredError);
    const authErr = err as McpAuthRequiredError;
    expect(authErr.status).toBe(401);
    expect(authErr.wwwAuthenticate).toBe('Bearer realm="mcp", error="invalid_token"');
    await t.close();
  });

  it("404 on a remembered session throws McpSessionExpiredError", async () => {
    await startFixture(
      recording((msg, res) => {
        if ("method" in msg && msg.method === "initialize") {
          res.writeHead(200, {
            "content-type": "application/json",
            "mcp-session-id": "sess-9",
          });
          res.end(
            JSON.stringify({ jsonrpc: "2.0", id: "id" in msg ? msg.id : 1, result: { protocolVersion: "2025-06-18" } }),
          );
        } else {
          res.writeHead(404);
          res.end();
        }
      }),
    );

    const t = createHttpTransport({ url: baseUrl, fetchImpl: fetch });
    await t.start();
    await t.send(INIT_REQUEST);
    const err: unknown = await t
      .send({ jsonrpc: "2.0", id: 2, method: "tools/list" })
      .then(() => undefined, (e: unknown) => e);
    expect(err).toBeInstanceOf(McpSessionExpiredError);
    await t.close();
  });

  it("MCP-Protocol-Version header is sent after setProtocolVersion", async () => {
    await startFixture(
      recording((msg, res) => {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(
          JSON.stringify({
            jsonrpc: "2.0",
            id: "id" in msg ? msg.id : 1,
            result: { tools: [] },
          }),
        );
      }),
    );

    const t: HttpTransport = createHttpTransport({ url: baseUrl, fetchImpl: fetch });
    await t.start();
    await t.send(INIT_REQUEST);
    expect(requests[0]!.headers["mcp-protocol-version"]).toBeUndefined();
    t.setProtocolVersion("2025-06-18");
    await t.send({ jsonrpc: "2.0", id: 2, method: "tools/list" });
    expect(requests[1]!.headers["mcp-protocol-version"]).toBe("2025-06-18");
    await t.close();
  });

  it("accessToken() supplies a bearer token on every request", async () => {
    await startFixture(
      recording((_msg, res) => {
        res.writeHead(202);
        res.end();
      }),
    );

    const t = createHttpTransport({ url: baseUrl, fetchImpl: fetch, accessToken: async () => "tok-7" });
    await t.start();
    await t.send({ jsonrpc: "2.0", method: "notifications/initialized" });
    expect(requests[0]!.headers["authorization"]).toBe("Bearer tok-7");
    await t.close();
  });

  it("bounds a JSON-RPC response before parsing and cancels overflow", async () => {
    let cancelled = 0;
    const oversized = JSON.stringify({ jsonrpc: "2.0", id: 1, result: { padding: "x".repeat(200) } });
    let sent = false;
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (sent) return;
        sent = true;
        controller.enqueue(new TextEncoder().encode(oversized));
      },
      cancel() {
        cancelled++;
      },
    });
    const t = createHttpTransport({
      url: baseUrl,
      fetchImpl: async () => new Response(body, {
        status: 200,
        headers: { "content-type": "application/json", "content-length": String(oversized.length) },
      }),
      limits: {
        connectMs: 100,
        headersMs: 100,
        idleMs: 100,
        totalMs: 1_000,
        maxRedirects: 0,
        headerBytes: 1_024,
        responseBytes: 32,
        decompressedBytes: 32,
        sseEventBytes: 1_024,
        sseEventCount: 4,
        jsonRpcFrameBytes: 32,
        aggregateStreamBytes: 1_024,
        toolResultBytes: 1_024,
      },
    });
    const got: JsonRpcMessage[] = [];
    t.onMessage((m) => got.push(m));
    await expect(t.send(INIT_REQUEST)).rejects.toThrow(/response_bytes|jsonrpc_frame_bytes/);
    expect(got).toEqual([]);
    expect(cancelled).toBe(1);
  });

  it("cancels the response body when HTTP header validation fails", async () => {
    let cancelled = 0;
    const body = new ReadableStream<Uint8Array>({
      pull() {},
      cancel() { cancelled++; },
    });
    const t = createHttpTransport({
      url: "http://127.0.0.1:9463",
      fetchImpl: async () => new Response(body, {
        status: 200,
        headers: { "content-type": "application/json", "x-overflow": "x".repeat(200) },
      }),
      limits: {
        connectMs: 100,
        headersMs: 100,
        idleMs: 100,
        totalMs: 1_000,
        maxRedirects: 0,
        headerBytes: 32,
        responseBytes: 1_024,
        decompressedBytes: 1_024,
        sseEventBytes: 1_024,
        sseEventCount: 4,
        jsonRpcFrameBytes: 1_024,
        aggregateStreamBytes: 1_024,
        toolResultBytes: 1_024,
      },
    });
    const failure = await t.send(INIT_REQUEST).then(() => undefined, (error: unknown) => error);
    expect(failure).toBeInstanceOf(Error);
    expect((failure as Error).message).toMatch(/header_bytes/);
    expect(cancelled).toBe(1);
  });

  it("requires an explicit provider transport instead of falling back to global fetch", async () => {
    const t = createHttpTransport({ url: "http://127.0.0.1:1" });
    await expect(t.send(INIT_REQUEST)).rejects.toThrow(/ProviderEgress|fetchImpl/);
  });

  it("uses an injected ProviderEgress with denied redirects and token secret metadata", async () => {
    const requests: unknown[] = [];
    const legacy = async (): Promise<Response> => {
      throw new Error("legacy fetch must not run");
    };
    const t = createHttpTransport({
      url: "https://mcp.example/rpc",
      fetchImpl: legacy,
      providerEgress: {
        async request(req) {
          requests.push(req);
          return {
            status: 202,
            headers: new Headers(),
            body: new Response(null, { status: 202 }).body ?? new ReadableStream<Uint8Array>(),
            origin: new URL("https://mcp.example"),
            remoteAddress: "192.0.2.5",
          };
        },
        async close() {},
      },
      accessToken: async () => "token-canary",
    });
    await t.send({ jsonrpc: "2.0", method: "notifications/initialized" });
    expect(requests).toHaveLength(1);
    expect(requests[0]).toMatchObject({
      originKey: "mcp",
      method: "POST",
      redirect: "deny",
      privileged: true,
      secretValues: ["token-canary"],
    });
  });

  it("close() fires onClose as expected and send afterwards rejects", async () => {
    await startFixture(
      recording((_msg, res) => {
        res.writeHead(202);
        res.end();
      }),
    );

    const t = createHttpTransport({ url: baseUrl, fetchImpl: fetch });
    const closes: { expected: boolean }[] = [];
    t.onClose((info) => closes.push(info));
    await t.start();
    await t.close();
    expect(closes).toEqual([{ expected: true }]);
    await expect(t.send({ jsonrpc: "2.0", method: "notifications/initialized" })).rejects.toThrow(
      /closed/,
    );
  });
});
