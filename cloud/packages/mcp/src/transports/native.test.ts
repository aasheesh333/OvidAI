import { describe, expect, it } from "vitest";
import type { McpToolCallResult } from "../client.js";
import { createNativeTransport, type McpCallContext, type NativeMcpHandler } from "./native.js";

// ---------------------------------------------------------------------------
// Native (in-process) MCP transport: requests bridge 1:1 onto handler
// methods, the per-call context comes from the ctxProvider (the singleton
// contract), and a throwing handler degrades to a JSON-RPC error response —
// never a transport crash.
// ---------------------------------------------------------------------------

const toolResult: McpToolCallResult = {
  text: "42",
  isError: false,
  content: [{ type: "text", text: "42" }],
};

function makeCtx(): McpCallContext {
  return {
    uid: "u-7",
    secrets: { TOKEN: "shh" },
    workspace: {},
    fetchImpl: async () => new Response("x"),
  };
}

class RecordingHandler implements NativeMcpHandler {
  readonly calls: string[] = [];
  lastCtx: McpCallContext | undefined;
  dispose?: () => Promise<void>;

  async initialize(params: Record<string, unknown>): Promise<Record<string, unknown>> {
    this.calls.push(`initialize:${JSON.stringify(params)}`);
    return { protocolVersion: "2025-06-18", capabilities: {} };
  }

  async listTools() {
    this.calls.push("listTools");
    return [{ name: "add", description: "adds numbers" }];
  }

  async callTool(name: string, args: Record<string, unknown>, ctx: McpCallContext) {
    this.calls.push(`callTool:${name}:${JSON.stringify(args)}`);
    this.lastCtx = ctx;
    return toolResult;
  }
}

describe("createNativeTransport", () => {
  it("requests bridge to handler methods with ctx from ctxProvider", async () => {
    const handler = new RecordingHandler();
    const ctx = makeCtx();
    let ctxCalls = 0;
    const t = createNativeTransport(handler, () => {
      ctxCalls++;
      return ctx;
    });
    await t.start();
    const seen: unknown[] = [];
    t.onMessage((m) => seen.push(m));

    await t.send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { clientInfo: { name: "ovid" } } });
    expect(seen[0]).toEqual({
      jsonrpc: "2.0",
      id: 1,
      result: { protocolVersion: "2025-06-18", capabilities: {} },
    });

    await t.send({ jsonrpc: "2.0", id: 2, method: "tools/list" });
    expect(seen[1]).toEqual({
      jsonrpc: "2.0",
      id: 2,
      result: { tools: [{ name: "add", description: "adds numbers" }] },
    });

    await t.send({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "add", arguments: { a: 1 } } });
    expect(seen[2]).toEqual({ jsonrpc: "2.0", id: 3, result: toolResult });

    // the handler got the per-call context, consulted once per call
    expect(handler.lastCtx).toBe(ctx);
    expect(ctxCalls).toBe(1);
    expect(handler.calls).toEqual([
      'initialize:{"clientInfo":{"name":"ovid"}}',
      "listTools",
      'callTool:add:{"a":1}',
    ]);

    // unknown methods answer method-not-found, not a crash
    await t.send({ jsonrpc: "2.0", id: 4, method: "resources/list" });
    expect(seen[3]).toMatchObject({
      id: 4,
      error: { code: -32601, message: expect.stringContaining("resources/list") },
    });

    // notifications (no id) have nothing to bridge — no response emitted
    await t.send({ jsonrpc: "2.0", method: "notifications/initialized" });
    expect(seen.length).toBe(4);
  });

  it("handler throw becomes a JSON-RPC error response, never a transport crash", async () => {
    let calls = 0;
    const handler: NativeMcpHandler = {
      async initialize() {
        return {};
      },
      async listTools() {
        return [];
      },
      async callTool() {
        calls++;
        if (calls === 1) throw new Error("boom");
        return toolResult;
      },
    };
    const t = createNativeTransport(handler, makeCtx);
    await t.start();
    const seen: unknown[] = [];
    t.onMessage((m) => seen.push(m));

    // the failing call does NOT reject the send
    await t.send({ jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "add", arguments: {} } });
    expect(seen[0]).toEqual({
      jsonrpc: "2.0",
      id: 5,
      error: { code: -32603, message: "boom" },
    });

    // the transport is still usable afterwards
    await t.send({ jsonrpc: "2.0", id: 6, method: "tools/call", params: { name: "add", arguments: {} } });
    expect(seen[1]).toEqual({ jsonrpc: "2.0", id: 6, result: toolResult });
  });

  it("close() disposes the handler and fires an expected close", async () => {
    let disposed = 0;
    const handler = new RecordingHandler();
    handler.dispose = async () => {
      disposed++;
    };
    const t = createNativeTransport(handler, makeCtx);
    await t.start();
    const closes: Array<{ expected: boolean }> = [];
    t.onClose((info) => closes.push(info));
    await t.close();
    expect(disposed).toBe(1);
    expect(closes).toEqual([{ expected: true }]);
    await t.close(); // idempotent
    expect(disposed).toBe(1);
    expect(closes.length).toBe(1);
  });

  it("close() fires the expected close even when dispose throws", async () => {
    const handler = new RecordingHandler();
    handler.dispose = async () => {
      throw new Error("dispose failed");
    };
    const t = createNativeTransport(handler, makeCtx);
    await t.start();
    const closes: Array<{ expected: boolean }> = [];
    t.onClose((info) => closes.push(info));
    await expect(t.close()).rejects.toThrow("dispose failed");
    expect(closes).toEqual([{ expected: true }]);
  });
});
