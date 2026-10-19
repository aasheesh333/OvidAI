import { describe, expect, it, vi, afterEach } from "vitest";

import type { JsonRpcMessage } from "./jsonrpc.js";
import type { McpTransport } from "./transport.js";
import {
  CLIENT_INFO,
  MAX_CURSOR_CHARS,
  MAX_TOOL_LIST_PAGES,
  MAX_TOOL_RESULT_CHARS,
  McpClient,
  McpRpcError,
  McpTimeoutError,
  trimToolResult,
} from "./client.js";

/**
 * In-file fake transport: records every sent message, lets the test push
 * responses/notifications from the "server" side, and can simulate an
 * expected close (close()) or an unexpected disconnect (dropConnection()).
 */
class FakeTransport implements McpTransport {
  sent: JsonRpcMessage[] = [];
  started = false;
  /** When set, send() throws this — a closed/closing transport (every real transport throws once closed). */
  sendError: Error | undefined;
  private msgCb: ((m: JsonRpcMessage) => void) | undefined;
  private closeCb: ((info: { expected: boolean }) => void) | undefined;

  async start(): Promise<void> {
    this.started = true;
  }
  async send(msg: JsonRpcMessage): Promise<void> {
    if (this.sendError !== undefined) throw this.sendError;
    this.sent.push(msg);
  }
  onMessage(cb: (m: JsonRpcMessage) => void): void {
    this.msgCb = cb;
  }
  onClose(cb: (info: { expected: boolean }) => void): void {
    this.closeCb = cb;
  }
  async close(): Promise<void> {
    this.closeCb?.({ expected: true });
  }
  /** Server → client message. */
  push(m: JsonRpcMessage): void {
    this.msgCb?.(m);
  }
  /** Wire died under us. */
  dropConnection(): void {
    this.closeCb?.({ expected: false });
  }
}

function makeClient(opts?: ConstructorParameters<typeof McpClient>[1]) {
  const t = new FakeTransport();
  const c = new McpClient(t, opts);
  return { t, c };
}

const flush = () => new Promise<void>((r) => setImmediate(r));

afterEach(() => {
  vi.useRealTimers();
});

describe("initialize", () => {
  it("sends 2025-06-18 with roots/sampling/elicitation capabilities", async () => {
    const { t, c } = makeClient();
    const p = c.initialize();
    expect(t.sent[0]).toEqual({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2025-06-18",
        capabilities: { roots: { listChanged: false }, sampling: {}, elicitation: {} },
        clientInfo: { name: CLIENT_INFO.name, version: CLIENT_INFO.version },
      },
    });
    t.push({
      jsonrpc: "2.0",
      id: 1,
      result: { protocolVersion: "2024-11-05", capabilities: { tools: {} } },
    });
    const res = await p;
    expect(res.capabilities).toEqual({ tools: {} });
    expect(c.protocolVersion).toBe("2024-11-05");
    expect(c.connected).toBe(true);
  });

  it("falls back to 2024-11-05 when the response omits protocolVersion", async () => {
    const { t, c } = makeClient();
    const p = c.initialize();
    t.push({ jsonrpc: "2.0", id: 1, result: { capabilities: {} } });
    await p;
    expect(c.protocolVersion).toBe("2024-11-05");
  });

  it("falls back to 2024-11-05 for an unsupported server version", async () => {
    const { t, c } = makeClient();
    const p = c.initialize();
    t.push({
      jsonrpc: "2.0",
      id: 1,
      result: { protocolVersion: "1999-01-01", capabilities: {} },
    });
    await p;
    expect(c.protocolVersion).toBe("2024-11-05");
  });
});

describe("listTools", () => {
  it("follows nextCursor and merges pages", async () => {
    const { t, c } = makeClient();
    const p = c.listTools();
    await flush();
    expect(t.sent[0]).toMatchObject({ method: "tools/list" });
    t.push({ jsonrpc: "2.0", id: 1, result: { tools: [{ name: "a" }], nextCursor: "c1" } });
    await flush();
    t.push({ jsonrpc: "2.0", id: 2, result: { tools: [{ name: "b" }, { name: "c" }] } });
    const tools = await p;
    expect(tools).toEqual([{ name: "a" }, { name: "b" }, { name: "c" }]);
    // page 2 carries the cursor
    expect(t.sent[1]).toMatchObject({ method: "tools/list", params: { cursor: "c1" } });
    expect(t.sent).toHaveLength(2);
  });

  it("rejects repeated cursor", async () => {
    const { t, c } = makeClient();
    const p = c.listTools();
    await flush();
    t.push({ jsonrpc: "2.0", id: 1, result: { tools: [{ name: "a" }], nextCursor: "c1" } });
    await flush();
    t.push({ jsonrpc: "2.0", id: 2, result: { tools: [{ name: "b" }], nextCursor: "c1" } });
    await expect(p).rejects.toThrow(/repeat/i);
  });

  it("rejects oversized cursor", async () => {
    const { t, c } = makeClient();
    const huge = "c".repeat(MAX_CURSOR_CHARS + 1);
    expect(huge).toHaveLength(4097);
    const p = c.listTools();
    await flush();
    t.push({ jsonrpc: "2.0", id: 1, result: { tools: [], nextCursor: huge } });
    await expect(p).rejects.toThrow(/cursor/i);
  });

  it("gives up after 50 pages", async () => {
    const { t, c } = makeClient();
    expect(MAX_TOOL_LIST_PAGES).toBe(50);
    const p = c.listTools();
    // The client gives up while the test is still between awaits — attach a
    // handler now so the rejection is never momentarily unhandled.
    p.catch(() => {});
    // 51 distinct cursors: c1..c51 — the client must stop after 50 requests.
    for (let i = 1; i <= 51; i++) {
      await flush();
      const listCalls = t.sent.filter((m) => "method" in m && m.method === "tools/list");
      if (listCalls.length < i) break; // the client stopped asking
      t.push({
        jsonrpc: "2.0",
        id: i,
        result: { tools: [{ name: `t${i}` }], nextCursor: `c${i}` },
      });
    }
    await expect(p).rejects.toThrow(/50 pages/);
    const listCalls = t.sent.filter((m) => "method" in m && m.method === "tools/list");
    expect(listCalls).toHaveLength(50);
    // handshake-free: no initialize request was needed for tools/list
    expect(t.sent.filter((m) => "method" in m && m.method === "initialize")).toHaveLength(0);
  });
});

describe("callTool", () => {
  it("trims at 6000 chars with the exact omission notice", async () => {
    expect(MAX_TOOL_RESULT_CHARS).toBe(6000);
    const big = "x".repeat(10_000);
    const { t, c } = makeClient();
    const p = c.callTool("search", { q: "hi" });
    await flush();
    expect(t.sent[0]).toMatchObject({
      method: "tools/call",
      params: { name: "search", arguments: { q: "hi" } },
    });
    t.push({
      jsonrpc: "2.0",
      id: 1,
      result: { content: [{ type: "text", text: big }] },
    });
    const r = await p;
    const head = big.slice(0, 3000);
    const tail = big.slice(big.length - 3000);
    expect(r.text).toBe(
      head +
        "\n\n[…4000 characters omitted — ask again with a narrower query to see the middle…]\n\n" +
        tail,
    );
    expect(r.isError).toBe(false);
  });

  it("returns ≤6000 chars verbatim", async () => {
    const small = "y".repeat(6000);
    const { t, c } = makeClient();
    const p = c.callTool("search", {});
    await flush();
    t.push({ jsonrpc: "2.0", id: 1, result: { content: [{ type: "text", text: small }] } });
    const r = await p;
    expect(r.text).toBe(small);
  });

  it("joins text blocks and reports isError", async () => {
    const { t, c } = makeClient();
    const p = c.callTool("multi", {});
    await flush();
    t.push({
      jsonrpc: "2.0",
      id: 1,
      result: {
        content: [
          { type: "text", text: "a" },
          { type: "image", data: "AAAA", mimeType: "image/png" },
          { type: "text", text: "b" },
        ],
        isError: true,
      },
    });
    const r = await p;
    // "AAAA" base64-decodes to 3 bytes.
    expect(r.text).toBe("a\n\n[image 3 bytes]\n\nb");
    expect(r.isError).toBe(true);
    expect(r.content).toHaveLength(3);
  });

  it("trimToolResult is exported and exact", () => {
    const text = "0123456789".repeat(1001); // 10010 chars
    const out = trimToolResult(text);
    expect(out.length).toBeLessThan(text.length);
    expect(out.startsWith(text.slice(0, 3000))).toBe(true);
    expect(out.endsWith(text.slice(text.length - 3000))).toBe(true);
    expect(out).toContain("[…4010 characters omitted — ask again with a narrower query to see the middle…]");
    expect(trimToolResult("short")).toBe("short");
  });
});

describe("request plumbing", () => {
  it("JSON-RPC error response throws McpRpcError with code preserved", async () => {
    const { t, c } = makeClient();
    const p = c.request("tools/list");
    await flush();
    t.push({
      jsonrpc: "2.0",
      id: 1,
      error: { code: -32601, message: "Method not found" },
    });
    const err = await p.then(
      () => undefined,
      (e) => e,
    );
    expect(err).toBeInstanceOf(McpRpcError);
    expect((err as McpRpcError).code).toBe(-32601);
    expect((err as McpRpcError).message).toBe("Method not found");
  });

  it("timeout throws McpTimeoutError after the default 30000ms", async () => {
    vi.useFakeTimers();
    const { c } = makeClient();
    const p = c.request("tools/list");
    vi.advanceTimersByTime(29_999);
    const settled = await Promise.race([p.then(() => "ok", () => "err"), Promise.resolve("pending")]);
    expect(settled).toBe("pending");
    vi.advanceTimersByTime(1);
    await expect(p).rejects.toBeInstanceOf(McpTimeoutError);
  });

  it("server request is answered via hooks.onServerRequest", async () => {
    const onServerRequest = vi.fn(async () => ({ jsonrpc: "2.0" as const, id: 7, result: { pong: true } }));
    const { t, c } = makeClient({ hooks: { onServerRequest } });
    t.push({ jsonrpc: "2.0", id: 7, method: "ping" });
    await flush();
    await flush();
    expect(onServerRequest).toHaveBeenCalledWith({ jsonrpc: "2.0", id: 7, method: "ping" });
    expect(t.sent).toContainEqual({ jsonrpc: "2.0", id: 7, result: { pong: true } });
  });

  it("notification routed to hooks.onNotification", async () => {
    const onNotification = vi.fn();
    const { t, c } = makeClient({ hooks: { onNotification } });
    t.push({ jsonrpc: "2.0", method: "notifications/roots/list_changed" });
    await flush();
    expect(onNotification).toHaveBeenCalledWith({
      jsonrpc: "2.0",
      method: "notifications/roots/list_changed",
    });
  });

  it("a server request with the same id as a pending response is NOT mistaken for our response", async () => {
    // Dart parity: isServerRequest is checked BEFORE response matching.
    const { t, c } = makeClient();
    const p = c.request("tools/list");
    await flush();
    t.push({ jsonrpc: "2.0", id: 1, method: "sampling/createMessage", params: {} });
    await flush();
    // still pending — the server request did not resolve our promise
    const state = await Promise.race([p.then(() => "ok", () => "err"), Promise.resolve("pending")]);
    expect(state).toBe("pending");
    // and the request went nowhere (no hook) → we answered with a JSON-RPC error
    expect(t.sent).toContainEqual({
      jsonrpc: "2.0",
      id: 1,
      error: expect.objectContaining({ code: -32601 }),
    });
    t.push({ jsonrpc: "2.0", id: 1, result: { tools: [] } });
    await expect(p).resolves.toEqual({ tools: [] });
  });
});

describe("server request racing a close (contained — never an unhandled rejection)", () => {
  // Vitest fails the run on an unhandled rejection, so these tests passing at
  // all is itself the "no crash" assertion; the console.debug spy proves the
  // catch path (not just silence) handled the failure.
  it("hooked response undeliverable on a closing transport: logged at debug, nothing sent", async () => {
    const debug = vi.spyOn(console, "debug").mockImplementation(() => {});
    try {
      const onServerRequest = vi.fn(async () => ({ jsonrpc: "2.0" as const, id: 7, result: { pong: true } }));
      const { t, c } = makeClient({ hooks: { onServerRequest } });
      // Every transport throws once closed (stdio/http/sse) — simulate the
      // wire dying between the request arriving and our response leaving.
      t.sendError = new Error("MCP stdio transport is closed");
      t.push({ jsonrpc: "2.0", id: 7, method: "ping" });
      await flush();
      await flush();
      expect(onServerRequest).toHaveBeenCalledTimes(1);
      expect(t.sent).toEqual([]);
      expect(debug).toHaveBeenCalledTimes(1);
    } finally {
      debug.mockRestore();
    }
  });

  it("method-not-found reply on a closing transport (no hooks): same containment", async () => {
    const debug = vi.spyOn(console, "debug").mockImplementation(() => {});
    try {
      const { t, c } = makeClient();
      t.sendError = new Error("MCP HTTP transport is closed");
      t.push({ jsonrpc: "2.0", id: 9, method: "sampling/createMessage", params: {} });
      await flush();
      await flush();
      expect(t.sent).toEqual([]);
      expect(debug).toHaveBeenCalledTimes(1);
    } finally {
      debug.mockRestore();
    }
  });
});

describe("close semantics", () => {
  it("unexpected close fires onUnexpectedDisconnect and connected === false", async () => {
    const onUnexpectedDisconnect = vi.fn();
    const { t, c } = makeClient({ hooks: { onUnexpectedDisconnect } });
    const ip = c.initialize();
    t.push({ jsonrpc: "2.0", id: 1, result: { capabilities: {} } });
    await ip;
    expect(c.connected).toBe(true);
    t.dropConnection();
    expect(onUnexpectedDisconnect).toHaveBeenCalledTimes(1);
    expect(c.connected).toBe(false);
  });

  it("pending requests reject on unexpected close", async () => {
    const { t, c } = makeClient();
    const p = c.request("tools/list");
    await flush();
    t.dropConnection();
    await expect(p).rejects.toThrow(/close/i);
  });

  it("close() is expected — no onUnexpectedDisconnect", async () => {
    const onUnexpectedDisconnect = vi.fn();
    const { t, c } = makeClient({ hooks: { onUnexpectedDisconnect } });
    const ip = c.initialize();
    t.push({ jsonrpc: "2.0", id: 1, result: { capabilities: {} } });
    await ip;
    await c.close();
    expect(onUnexpectedDisconnect).not.toHaveBeenCalled();
    expect(c.connected).toBe(false);
  });
});
