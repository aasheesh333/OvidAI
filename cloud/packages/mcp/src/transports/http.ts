/**
 * MCP Streamable HTTP transport (2025-06-18 spec): every outgoing JSON-RPC
 * message is a POST to the single server URL with Accept:
 * application/json, text/event-stream. The response body is parsed by
 * content-type — JSON directly, or an SSE-formatted stream read until the
 * frame answering our request arrives (notifications and server requests on
 * the stream are dispatched through onMessage immediately). Mcp-Session-Id is
 * kept from the initialize response and echoed (with MCP-Protocol-Version,
 * set via setProtocolVersion) on later requests.
 */

import type { JsonRpcMessage } from "../jsonrpc.js";
import type { McpTransport } from "../transport.js";

export interface HttpTransportOptions {
  url: string;
  /** Extra headers (custom auth schemes, tenancy headers, ...). */
  headers?: Record<string, string>;
  /** Tests inject a fake; production passes the SSRF-guarded fetch (Task 3). */
  fetchImpl?: typeof fetch;
  /** OAuth bearer supplier (Task 9 wires it). */
  accessToken?: () => Promise<string | null>;
}

/** HTTP 401 from the MCP server, carrying the WWW-Authenticate challenge. */
export class McpAuthRequiredError extends Error {
  constructor(
    readonly status: number,
    readonly wwwAuthenticate: string | null,
  ) {
    super(
      `MCP server returned HTTP ${status}` +
        (wwwAuthenticate === null ? "" : ` (WWW-Authenticate: ${wwwAuthenticate})`),
    );
    this.name = "McpAuthRequiredError";
  }
}

/** The server dropped our remembered session (404) — re-initialize. */
export class McpSessionExpiredError extends Error {
  constructor() {
    super("MCP session expired — the server returned 404 for the remembered Mcp-Session-Id");
    this.name = "McpSessionExpiredError";
  }
}

export interface HttpTransport extends McpTransport {
  /**
   * The router hands the transport the version negotiated during
   * initialize; it is echoed as MCP-Protocol-Version on later requests.
   * (Legacy SSE has no such header — that transport type omits this member.)
   */
  setProtocolVersion(v: string): void;
}

export function createHttpTransport(opts: HttpTransportOptions): HttpTransport {
  const fetchImpl = opts.fetchImpl ?? fetch;
  const baseHeaders: Record<string, string> = opts.headers ?? {};
  let sessionId: string | null = null;
  let protocolVersion: string | null = null;
  let closed = false;
  let msgCb: ((m: JsonRpcMessage) => void) | undefined;
  let closeCb: ((info: { expected: boolean }) => void) | undefined;

  function parseAndDispatch(text: string): JsonRpcMessage | null {
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      return null; // a frame we cannot parse is dropped, not fatal
    }
    if (typeof parsed !== "object" || parsed === null) return null;
    const m = parsed as JsonRpcMessage;
    msgCb?.(m);
    return m;
  }

  async function send(msg: JsonRpcMessage): Promise<void> {
    if (closed) throw new Error("MCP HTTP transport is closed");
    const headers: Record<string, string> = {
      ...baseHeaders,
      accept: "application/json, text/event-stream",
      "content-type": "application/json",
    };
    const token = await opts.accessToken?.();
    if (token != null) headers.authorization = `Bearer ${token}`;
    if (sessionId !== null) headers["mcp-session-id"] = sessionId;
    if (protocolVersion !== null) headers["mcp-protocol-version"] = protocolVersion;

    const isInitialize = "method" in msg && msg.method === "initialize";
    const res = await fetchImpl(opts.url, {
      method: "POST",
      headers,
      body: JSON.stringify(msg),
    });

    if (res.status === 401) {
      await res.body?.cancel().catch(() => {});
      throw new McpAuthRequiredError(res.status, res.headers.get("www-authenticate"));
    }
    if (res.status === 404 && sessionId !== null) {
      await res.body?.cancel().catch(() => {});
      throw new McpSessionExpiredError();
    }
    if (isInitialize) {
      const sid = res.headers.get("mcp-session-id");
      if (sid !== null) sessionId = sid;
    }
    if (res.status === 202) {
      await res.body?.cancel().catch(() => {});
      return; // notification accepted — no body, nothing to dispatch
    }
    if (!res.ok) {
      await res.body?.cancel().catch(() => {});
      throw new Error(`MCP server returned HTTP ${res.status}`);
    }

    const contentType = res.headers.get("content-type") ?? "";
    if (contentType.includes("text/event-stream")) {
      await readSseResponse(res, msg);
      return;
    }
    const body = await res.text();
    if (body.trim() !== "") parseAndDispatch(body);
  }

  /**
   * SSE-formatted POST response: line-buffered parse (partial lines across
   * chunks, `:` comments skipped); every complete frame is dispatched through
   * onMessage immediately, and we stop reading once the frame whose id
   * matches our request has been seen.
   */
  async function readSseResponse(res: Response, sent: JsonRpcMessage): Promise<void> {
    const wantId = "id" in sent ? String(sent.id) : null;
    const reader = res.body?.getReader();
    if (reader === undefined) return;
    const decoder = new TextDecoder();
    let buffer = "";
    let dataLines: string[] = [];
    let matched = false;

    const handleLine = (line: string): void => {
      if (line === "") {
        if (dataLines.length > 0) {
          const m = parseAndDispatch(dataLines.join("\n"));
          dataLines = [];
          if (m !== null && wantId !== null && "id" in m && String(m.id) === wantId) {
            matched = true;
          }
        }
        return;
      }
      if (line.startsWith(":")) return; // comment / keep-alive
      if (line.startsWith("data:")) dataLines.push(line.slice(5).replace(/^ /, ""));
      // event:/id:/retry: fields are irrelevant on a POST response body
    };

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      let nl: number;
      while ((nl = buffer.indexOf("\n")) !== -1) {
        const raw = buffer.slice(0, nl);
        buffer = buffer.slice(nl + 1);
        handleLine(raw.endsWith("\r") ? raw.slice(0, -1) : raw);
      }
      if (matched) {
        await reader.cancel().catch(() => {});
        return;
      }
    }
    buffer += decoder.decode();
    if (buffer !== "") handleLine(buffer.replace(/\r$/, ""));
    handleLine(""); // flush a trailing unterminated frame
  }

  const transport: HttpTransport = {
    // Streamable HTTP has no channel to open — the first POST carries
    // initialize. start() exists for McpTransport lifecycle symmetry.
    async start(): Promise<void> {
      if (closed) throw new Error("MCP HTTP transport is closed");
    },
    send,
    onMessage(cb: (m: JsonRpcMessage) => void): void {
      msgCb = cb;
    },
    onClose(cb: (info: { expected: boolean }) => void): void {
      closeCb = cb;
    },
    setProtocolVersion(v: string): void {
      protocolVersion = v;
    },
    async close(): Promise<void> {
      if (closed) return;
      closed = true;
      closeCb?.({ expected: true });
    },
  };
  return transport;
}
