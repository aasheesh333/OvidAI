/**
 * MCP legacy SSE transport (2024-11-05 spec): a long-lived GET event stream
 * whose first `endpoint` event names the POST target (resolved against the
 * GET URL when relative); all JSON-RPC flows over the two channels —
 * requests/notifications POSTed, responses and server pushes arriving as
 * `message` events on the stream. Deliberately NO setProtocolVersion: this
 * legacy variant has no MCP-Protocol-Version header; the router echoes the
 * negotiated version on Streamable HTTP only.
 */

import type { JsonRpcMessage } from "../jsonrpc.js";
import type { McpTransport } from "../transport.js";
import { McpAuthRequiredError, type HttpTransportOptions } from "./http.js";

export function createSseTransport(opts: HttpTransportOptions): McpTransport {
  const fetchImpl = opts.fetchImpl ?? fetch;
  const baseHeaders: Record<string, string> = opts.headers ?? {};
  let closed = false;
  let started = false;
  let postUrl: string | null = null;
  let msgCb: ((m: JsonRpcMessage) => void) | undefined;
  let closeCb: ((info: { expected: boolean }) => void) | undefined;
  let closeFired = false;
  const abort = new AbortController();
  let endpointResolve: (() => void) | undefined;
  const endpointReady = new Promise<void>((resolve) => {
    endpointResolve = resolve;
  });

  async function authHeaders(): Promise<Record<string, string>> {
    const headers: Record<string, string> = { ...baseHeaders };
    const token = await opts.accessToken?.();
    if (token != null) headers.authorization = `Bearer ${token}`;
    return headers;
  }

  function fireClose(expected: boolean): void {
    if (closeFired) return;
    closeFired = true;
    closeCb?.({ expected });
  }

  function handleFrame(event: string, data: string): void {
    if (event === "endpoint") {
      postUrl = new URL(data, opts.url).toString();
      endpointResolve?.();
      return;
    }
    if (event !== "" && event !== "message") return; // ping etc. — ignored
    let parsed: unknown;
    try {
      parsed = JSON.parse(data);
    } catch {
      return; // a frame we cannot parse is dropped, not fatal
    }
    if (typeof parsed === "object" && parsed !== null) msgCb?.(parsed as JsonRpcMessage);
  }

  /**
   * Pump the GET event stream: line-buffered across chunk boundaries (a data
   * line may split across reads), `:` comments skipped, frames dispatched on
   * blank lines. Stream end without a user close is an UNEXPECTED close.
   */
  async function readLoop(res: Response): Promise<void> {
    const reader = res.body?.getReader();
    if (reader === undefined) {
      fireClose(false);
      return;
    }
    const decoder = new TextDecoder();
    let buffer = "";
    let eventName = "";
    let dataLines: string[] = [];

    const handleLine = (line: string): void => {
      if (line === "") {
        if (dataLines.length > 0) handleFrame(eventName, dataLines.join("\n"));
        eventName = "";
        dataLines = [];
        return;
      }
      if (line.startsWith(":")) return; // comment / keep-alive
      const colon = line.indexOf(":");
      const field = colon === -1 ? line : line.slice(0, colon);
      let value = colon === -1 ? "" : line.slice(colon + 1);
      if (value.startsWith(" ")) value = value.slice(1);
      if (field === "event") eventName = value;
      else if (field === "data") dataLines.push(value);
    };

    try {
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
      }
      buffer += decoder.decode();
      if (buffer !== "") handleLine(buffer.replace(/\r$/, ""));
      handleLine(""); // flush a trailing unterminated frame
    } catch {
      // aborted by close() (expected, already reported) or a dropped socket
      // (unexpected, reported below)
    }
    fireClose(closed);
  }

  async function start(): Promise<void> {
    if (closed) throw new Error("MCP SSE transport is closed");
    if (started) return;
    started = true;
    const headers = await authHeaders();
    headers.accept = "text/event-stream";
    const res = await fetchImpl(opts.url, { headers, signal: abort.signal });
    if (!res.ok) {
      await res.body?.cancel().catch(() => {});
      throw new Error(`MCP server refused the SSE stream with HTTP ${res.status}`);
    }
    void readLoop(res);
    await endpointReady; // start() resolves once the POST target is known
  }

  async function send(msg: JsonRpcMessage): Promise<void> {
    if (closed) throw new Error("MCP SSE transport is closed");
    if (postUrl === null) throw new Error("MCP SSE transport has no POST endpoint yet");
    const headers = await authHeaders();
    headers["content-type"] = "application/json";
    const res = await fetchImpl(postUrl, {
      method: "POST",
      headers,
      body: JSON.stringify(msg),
    });
    if (res.status === 401) {
      await res.body?.cancel().catch(() => {});
      throw new McpAuthRequiredError(res.status, res.headers.get("www-authenticate"));
    }
    if (!res.ok) {
      await res.body?.cancel().catch(() => {});
      throw new Error(`MCP server returned HTTP ${res.status} for the POST endpoint`);
    }
    await res.text(); // drain (202s carry no body)
  }

  const transport: McpTransport = {
    start,
    send,
    onMessage(cb: (m: JsonRpcMessage) => void): void {
      msgCb = cb;
    },
    onClose(cb: (info: { expected: boolean }) => void): void {
      closeCb = cb;
    },
    async close(): Promise<void> {
      if (closed) return;
      closed = true;
      abort.abort();
      fireClose(true);
    },
  };
  return transport;
}
