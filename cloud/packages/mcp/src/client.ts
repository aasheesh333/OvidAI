/**
 * McpClient — JSON-RPC 2.0 client for Model Context Protocol servers, ported
 * from the Dart app's `lib/core/mcp_service.dart` (handshake, tools/list
 * pagination, tool-result trimming).
 */

import { isNotification, isResponse, isServerRequest } from "./jsonrpc.js";
import type {
  JsonRpcMessage,
  JsonRpcNotification,
  JsonRpcRequest,
  JsonRpcResponse,
} from "./jsonrpc.js";
import type { McpTransport } from "./transport.js";

export const MCP_PROTOCOL_VERSION = "2025-06-18";
export const PROTOCOL_FALLBACK_VERSION = "2024-11-05";
export const CLIENT_INFO = { name: "ovid-cloud", version: "1.0.0" } as const;

/** Inline cap for a tool result handed to the model (Dart parity: 6000). */
export const MAX_TOOL_RESULT_CHARS = 6000;
/** Give up on tools/list pagination after this many pages. */
export const MAX_TOOL_LIST_PAGES = 50;
/** A nextCursor longer than this is treated as a broken server. */
export const MAX_CURSOR_CHARS = 4096;

const DEFAULT_REQUEST_TIMEOUT_MS = 30_000;

export interface McpToolDef {
  name: string;
  description?: string;
  inputSchema?: Record<string, unknown>;
}

export interface McpToolCallResult {
  text: string;
  isError: boolean;
  content: unknown[];
}

export interface McpInitializeResult {
  protocolVersion: string;
  capabilities: Record<string, unknown>;
  serverInfo?: { name?: string; version?: string };
}

export interface McpClientHooks {
  /** Server → us request (e.g. ping, sampling/createMessage). Task 4 plugs in here. */
  onServerRequest?(req: JsonRpcRequest): Promise<JsonRpcResponse>;
  onNotification?(n: JsonRpcNotification): void;
  onUnexpectedDisconnect?(): void;
}

export class McpRpcError extends Error {
  constructor(readonly code: number, message: string) {
    super(message);
    this.name = "McpRpcError";
  }
}

export class McpTimeoutError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "McpTimeoutError";
  }
}

interface PendingEntry {
  resolve(value: unknown): void;
  reject(err: unknown): void;
}

/**
 * Trim oversized tool output head+tail with an exact omission notice
 * (spill-style) — byte-for-byte the Dart `_trimResult` notice
 * (mcp_service.dart:840).
 */
export function trimToolResult(text: string): string {
  if (text.length <= MAX_TOOL_RESULT_CHARS) return text;
  const head = text.slice(0, MAX_TOOL_RESULT_CHARS / 2);
  const tail = text.slice(text.length - MAX_TOOL_RESULT_CHARS / 2);
  const omitted = text.length - MAX_TOOL_RESULT_CHARS;
  return (
    `${head}\n\n[…${omitted} characters omitted — ` +
    `ask again with a narrower query to see the middle…]\n\n${tail}`
  );
}

/** Decoded byte length of a base64 content block (Dart `_base64ByteLength`). */
function base64ByteLength(data: string): number {
  const buf = Buffer.from(data, "base64");
  // Buffer.from never throws; invalid base64 decodes to whatever prefix was
  // valid, matching the intent of Dart's fallback arithmetic.
  return buf.length;
}

/** Non-text content blocks are reported by decoded size, not dropped. */
function renderBlock(block: unknown): string | null {
  if (typeof block !== "object" || block === null) return null;
  const b = block as Record<string, unknown>;
  if (typeof b.text === "string") return b.text;
  if (typeof b.data === "string" && typeof b.mimeType === "string") {
    const kind = typeof b.type === "string" ? b.type : "binary";
    return `[${kind} ${base64ByteLength(b.data)} bytes]`;
  }
  const kind = typeof b.type === "string" ? b.type : "block";
  return `[${kind} block]`;
}

export class McpClient {
  private readonly transport: McpTransport;
  private readonly requestTimeoutMs: number;
  private readonly hooks: McpClientHooks;
  private nextId = 1;
  private readonly pending = new Map<string, PendingEntry>();
  private _connected = false;
  private _protocolVersion: string | null = null;
  private closed = false;

  constructor(
    transport: McpTransport,
    opts?: { requestTimeoutMs?: number; hooks?: McpClientHooks },
  ) {
    this.transport = transport;
    this.requestTimeoutMs = opts?.requestTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;
    this.hooks = opts?.hooks ?? {};
    transport.onMessage((m) => {
      // Fire-and-forget by necessity (the transport callback cannot await),
      // but NEVER unhandled: a server request racing a close must not take
      // the host process down with an unhandledRejection.
      void this.handleMessage(m).catch((err: unknown) => {
        console.debug("[mcp-client] inbound message handler failed (contained)", err);
      });
    });
    transport.onClose((info) => this.handleClose(info));
  }

  get connected(): boolean {
    return this._connected && !this.closed;
  }

  get protocolVersion(): string | null {
    return this._protocolVersion;
  }

  async initialize(): Promise<McpInitializeResult> {
    const result = (await this.request("initialize", {
      protocolVersion: MCP_PROTOCOL_VERSION,
      capabilities: {
        roots: { listChanged: false },
        sampling: {},
        elicitation: {},
      },
      clientInfo: { ...CLIENT_INFO },
    })) as Partial<McpInitializeResult> | null;

    const raw =
      typeof result === "object" && result !== null && typeof result.protocolVersion === "string"
        ? result.protocolVersion
        : undefined;
    // Use the server's version only when it is one we speak; anything else
    // falls back to the oldest version we support (Dart parity).
    this._protocolVersion =
      raw === MCP_PROTOCOL_VERSION || raw === PROTOCOL_FALLBACK_VERSION
        ? raw
        : PROTOCOL_FALLBACK_VERSION;
    this._connected = true;
    await this.transport.send({ jsonrpc: "2.0", method: "notifications/initialized" });
    return {
      protocolVersion: this._protocolVersion,
      capabilities: result?.capabilities ?? {},
      serverInfo: result?.serverInfo,
    };
  }

  async listTools(): Promise<McpToolDef[]> {
    const tools: McpToolDef[] = [];
    const seenCursors = new Set<string>();
    let cursor: string | undefined;
    for (let pages = 0; ; pages++) {
      if (pages >= MAX_TOOL_LIST_PAGES) {
        throw new Error(
          `tools/list exceeded ${MAX_TOOL_LIST_PAGES} pages without terminating — giving up`,
        );
      }
      const res = (await this.request(
        "tools/list",
        cursor === undefined ? undefined : { cursor },
      )) as { tools?: unknown; nextCursor?: unknown } | null;
      if (typeof res === "object" && res !== null && Array.isArray(res.tools)) {
        tools.push(...(res.tools as McpToolDef[]));
      }
      const next = res && typeof res === "object" ? res.nextCursor : undefined;
      if (typeof next !== "string" || next === "") return tools;
      if (next.length > MAX_CURSOR_CHARS) {
        throw new Error(
          `tools/list returned a ${next.length}-char cursor (max ${MAX_CURSOR_CHARS}) — refusing`,
        );
      }
      if (seenCursors.has(next)) {
        throw new Error(`tools/list returned a repeated cursor "${next}" — refusing to loop`);
      }
      seenCursors.add(next);
      cursor = next;
    }
  }

  async callTool(
    name: string,
    args: Record<string, unknown>,
    opts?: { timeoutMs?: number },
  ): Promise<McpToolCallResult> {
    const res = (await this.request("tools/call", { name, arguments: args }, opts)) as
      | { content?: unknown; isError?: unknown }
      | null;
    const content = typeof res === "object" && res !== null && Array.isArray(res.content)
      ? res.content
      : [];
    const parts: string[] = [];
    for (const block of content) {
      const rendered = renderBlock(block);
      if (rendered !== null) parts.push(rendered);
    }
    return {
      text: trimToolResult(parts.join("\n\n")),
      isError: typeof res === "object" && res !== null && res.isError === true,
      content,
    };
  }

  request(
    method: string,
    params?: Record<string, unknown>,
    opts?: { timeoutMs?: number },
  ): Promise<unknown> {
    if (this.closed) {
      return Promise.reject(new Error(`McpClient is closed — cannot send ${method}`));
    }
    const id = this.nextId++;
    const key = String(id);
    const timeoutMs = opts?.timeoutMs ?? this.requestTimeoutMs;
    const msg: JsonRpcRequest = {
      jsonrpc: "2.0",
      id,
      method,
      ...(params === undefined ? {} : { params }),
    };
    return new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(key);
        reject(new McpTimeoutError(`MCP request ${method} (id ${id}) timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      this.pending.set(key, {
        resolve: (value) => {
          clearTimeout(timer);
          resolve(value);
        },
        reject: (err) => {
          clearTimeout(timer);
          reject(err);
        },
      });
      void this.transport.send(msg).catch((err: unknown) => {
        const entry = this.pending.get(key);
        if (entry) {
          this.pending.delete(key);
          entry.reject(err);
        }
      });
    });
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    await this.transport.close();
    this.failPending(new Error("McpClient connection closed"));
  }

  private async handleMessage(m: JsonRpcMessage): Promise<void> {
    // Dart parity: a server request is checked BEFORE response matching, so
    // an id collision with a pending request can never be mistaken for its
    // response.
    if (isServerRequest(m)) {
      await this.answerServerRequest(m);
      return;
    }
    if (isResponse(m)) {
      const entry = this.pending.get(String(m.id));
      if (!entry) return; // late response to a timed-out/abandoned request
      this.pending.delete(String(m.id));
      if (m.error) {
        entry.reject(new McpRpcError(m.error.code, m.error.message));
      } else {
        entry.resolve(m.result);
      }
      return;
    }
    if (isNotification(m)) {
      this.hooks.onNotification?.(m);
    }
  }

  private async answerServerRequest(req: JsonRpcRequest): Promise<void> {
    if (this.hooks.onServerRequest) {
      let response: JsonRpcResponse;
      try {
        response = await this.hooks.onServerRequest(req);
      } catch (err) {
        response = {
          jsonrpc: "2.0",
          id: req.id,
          error: { code: -32603, message: err instanceof Error ? err.message : String(err) },
        };
      }
      await this.sendResponse(response);
      return;
    }
    await this.sendResponse({
      jsonrpc: "2.0",
      id: req.id,
      error: { code: -32601, message: `Method not found: ${req.method}` },
    });
  }

  /**
   * A server→client response is best-effort: every transport throws once
   * closed, and a request that races close() must not crash the host with an
   * unhandled rejection. An undeliverable response on a closing transport is
   * a no-op — logged at debug only.
   */
  private async sendResponse(response: JsonRpcResponse): Promise<void> {
    try {
      await this.transport.send(response);
    } catch (err) {
      console.debug("[mcp-client] server response undeliverable (transport closing or closed)", err);
    }
  }

  private handleClose(info: { expected: boolean }): void {
    this._connected = false;
    this.failPending(new Error("MCP connection closed before the request was answered"));
    if (!info.expected) {
      // Expected closes NEVER trigger reconnect logic or this hook.
      this.hooks.onUnexpectedDisconnect?.();
    }
  }

  private failPending(err: Error): void {
    for (const entry of this.pending.values()) entry.reject(err);
    this.pending.clear();
  }
}
