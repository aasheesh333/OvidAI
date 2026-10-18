import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import type { JsonRpcMessage } from "../jsonrpc.js";
import { createSseTransport } from "./sse.js";

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

    const t = createSseTransport({ url: baseUrl });
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

  it("GET refusal surfaces as transport start error", async () => {
    await startFixture((_req, res) => {
      res.writeHead(404);
      res.end();
    });

    const t = createSseTransport({ url: baseUrl });
    await expect(t.start()).rejects.toThrow(/404/);
  });

  it("server closing the stream fires onClose unexpected", async () => {
    await startFixture(sseServerWithEndpoint((_msg, res) => {
      res.writeHead(202);
      res.end();
    }));

    const t = createSseTransport({ url: baseUrl });
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
