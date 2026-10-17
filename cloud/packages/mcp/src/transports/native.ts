/**
 * Native (in-process) MCP transport: an Ovid-first-party handler implemented
 * in TypeScript, bridged through the same McpTransport the networked servers
 * use so the router treats every server alike. Requests map 1:1 onto handler
 * methods (initialize / tools/list / tools/call); the per-call McpCallContext
 * from the ctxProvider is what makes a process-wide singleton handler safe —
 * every call carries its own user, decrypted secrets and workspace.
 */

import type { JsonRpcMessage } from "../jsonrpc.js";
import type { GuardedFetch } from "../ssrf.js";
import type { McpToolCallResult, McpToolDef } from "../client.js";
import type { McpTransport } from "../transport.js";

// ---------------------------------------------------------------------------
// Forward references — the real surfaces land in later P5 tasks and live in
// @ovid/mcp so the type graph stays acyclic: WorkspaceFiles → Task 5,
// SamplingRequest / SamplingResult → Task 4, UserSystemBus → Task 10.
// Until then these are permissive placeholders those tasks replace.
// ---------------------------------------------------------------------------

/** Placeholder — Task 5 (workspace files) defines the real surface. */
export interface WorkspaceFiles {
  readonly [key: string]: unknown;
}
/** Placeholder — Task 4 (sampling) defines the real surface. */
export interface SamplingRequest {
  readonly [key: string]: unknown;
}
/** Placeholder — Task 4 (sampling) defines the real surface. */
export interface SamplingResult {
  readonly [key: string]: unknown;
}
/** Placeholder — Task 10 (approvals/elicitation) defines the real surface. */
export interface UserSystemBus {
  readonly [key: string]: unknown;
}

/** Per-call, per-user injection — the singleton handler contract. */
export interface McpCallContext {
  uid: string;
  secrets: Record<string, string>; // decrypted user config (Task 8/11); NEVER logged
  workspace: WorkspaceFiles; // Task 5
  fetchImpl: GuardedFetch;
  systemBus?: UserSystemBus; // Task 10 (approvals/elicitation)
  /** Task 4 types, P3 wires. */
  sampler?: (req: SamplingRequest) => Promise<SamplingResult | null>;
}

/**
 * A first-party MCP server implemented in-process (no jail, no network):
 * one handler object per integration, called with a fresh context per
 * request.
 */
export interface NativeMcpHandler {
  initialize(params: Record<string, unknown>): Promise<Record<string, unknown>>;
  listTools(): Promise<McpToolDef[]>;
  callTool(
    name: string,
    args: Record<string, unknown>,
    ctx: McpCallContext,
  ): Promise<McpToolCallResult>;
  dispose?(): Promise<void>;
}

const INTERNAL_ERROR = -32603;
const METHOD_NOT_FOUND = -32601;

export function createNativeTransport(
  handler: NativeMcpHandler,
  ctxProvider: () => McpCallContext,
): McpTransport {
  let msgCb: ((m: JsonRpcMessage) => void) | undefined;
  let closeCb: ((info: { expected: boolean }) => void) | undefined;
  let closing = false;
  let closeFired = false;

  function fireClose(expected: boolean): void {
    if (closeFired) return;
    closeFired = true;
    closeCb?.({ expected });
  }

  const transport: McpTransport = {
    async start(): Promise<void> {
      // in-memory — nothing to open
    },

    async send(msg: JsonRpcMessage): Promise<void> {
      if (closing) throw new Error("MCP native transport is closed");
      if (!("method" in msg) || !("id" in msg)) return; // notifications have nothing to bridge
      const params = (msg.params ?? {}) as Record<string, unknown>;
      try {
        let result: unknown;
        if (msg.method === "initialize") {
          result = await handler.initialize(params);
        } else if (msg.method === "tools/list") {
          result = { tools: await handler.listTools() };
        } else if (msg.method === "tools/call") {
          const name = typeof params.name === "string" ? params.name : "";
          const args = (params.arguments ?? {}) as Record<string, unknown>;
          result = await handler.callTool(name, args, ctxProvider());
        } else {
          msgCb?.({
            jsonrpc: "2.0",
            id: msg.id,
            error: { code: METHOD_NOT_FOUND, message: `unknown method "${msg.method}"` },
          });
          return;
        }
        msgCb?.({ jsonrpc: "2.0", id: msg.id, result });
      } catch (err) {
        // a throwing handler is a JSON-RPC error response, never a transport crash
        const message = err instanceof Error ? err.message : String(err);
        msgCb?.({ jsonrpc: "2.0", id: msg.id, error: { code: INTERNAL_ERROR, message } });
      }
    },

    onMessage(cb: (m: JsonRpcMessage) => void): void {
      msgCb = cb;
    },

    onClose(cb: (info: { expected: boolean }) => void): void {
      closeCb = cb;
    },

    async close(): Promise<void> {
      if (closing) return; // idempotent
      closing = true;
      try {
        await handler.dispose?.();
      } finally {
        fireClose(true);
      }
    },
  };
  return transport;
}
