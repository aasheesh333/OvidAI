/**
 * MCP Streamable HTTP transport. Network I/O is injected through the narrow
 * ProviderEgress consumer contract (Task 2) or the legacy guarded-fetch
 * adapter; there is deliberately no raw global-fetch fallback.
 */

import {
  assertBoundedHeadersOrCancel,
  DEFAULT_STREAM_LIMITS,
  EgressLimitError,
  egressResponseFromDecodedFetch,
  readBoundedBody,
  readBoundedSse,
  type EgressResponse,
  type ProviderEgress,
  type StreamLimits,
} from "../egress/responseLimits.js";
import { createSecretRedactor, type SecretRedactor } from "../egress/redactor.js";
import type { JsonRpcMessage } from "../jsonrpc.js";
import type { McpTransport } from "../transport.js";

export interface HttpTransportOptions {
  url: string;
  /** Extra headers (custom auth schemes, tenancy headers, ...). */
  headers?: Record<string, string>;
  /** Legacy guarded-fetch adapter, retained until Task 2 composition lands. */
  fetchImpl?: typeof fetch;
  /** Narrow consumer interface; this task does not implement DNS pinning. */
  providerEgress?: ProviderEgress;
  originKey?: string;
  limits?: StreamLimits;
  redactor?: SecretRedactor;
  /** OAuth bearer supplier (Task 9 wires it). */
  accessToken?: () => Promise<string | null>;
}

/** HTTP 401 from the MCP server, carrying a redacted challenge for discovery. */
export class McpAuthRequiredError extends Error {
  constructor(
    readonly status: number,
    readonly wwwAuthenticate: string | null,
  ) {
    super(`MCP server returned HTTP ${status}; authorization is required`);
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
  setProtocolVersion(v: string): void;
}

class MatchingFrame extends Error {}

/** Redact first, then replace provider-controlled RPC/tool error text. */
export function projectMcpRpcMessage(
  parsed: unknown,
  redactor: SecretRedactor,
  secrets: readonly string[],
): JsonRpcMessage | null {
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return null;
  const projected = redactor.json(parsed, secrets) as unknown as Record<string, unknown>;
  if (typeof projected.error === "object" && projected.error !== null && !Array.isArray(projected.error)) {
    const error = projected.error as Record<string, unknown>;
    projected.error = {
      code: typeof error.code === "number" && Number.isInteger(error.code) ? error.code : -32603,
      message: "MCP server returned an error.",
    };
  }
  if (typeof projected.result === "object" && projected.result !== null && !Array.isArray(projected.result)) {
    const result = projected.result as Record<string, unknown>;
    if (result.isError === true && Array.isArray(result.content)) {
      result.content = result.content.map((block) => {
        if (typeof block === "object" && block !== null && (block as { type?: unknown }).type === "text") {
          return { type: "text", text: "MCP tool failed." };
        }
        return block;
      });
    }
  }
  return projected as unknown as JsonRpcMessage;
}

export function createHttpTransport(opts: HttpTransportOptions): HttpTransport {
  const baseHeaders: Record<string, string> = opts.headers ?? {};
  const limits = opts.limits ?? DEFAULT_STREAM_LIMITS;
  const redactor = opts.redactor ?? createSecretRedactor();
  const abort = new AbortController();
  let sessionId: string | null = null;
  let protocolVersion: string | null = null;
  let closed = false;
  let closeFired = false;
  let msgCb: ((m: JsonRpcMessage) => void) | undefined;
  let closeCb: ((info: { expected: boolean }) => void) | undefined;

  function fireClose(expected: boolean): void {
    if (closeFired) return;
    closeFired = true;
    closeCb?.({ expected });
  }

  function parseAndDispatch(text: string, secrets: readonly string[]): JsonRpcMessage | null {
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      return null;
    }
    const message = projectMcpRpcMessage(parsed, redactor, secrets);
    if (message !== null) msgCb?.(message);
    return message;
  }

  async function request(
    url: URL,
    method: "POST" | "GET",
    headers: Record<string, string>,
    body: Uint8Array | undefined,
    secretValues: readonly string[],
  ): Promise<EgressResponse> {
    const timeout = AbortSignal.timeout(limits.totalMs);
    const signal = AbortSignal.any([abort.signal, timeout]);
    let response: EgressResponse;
    if (opts.providerEgress !== undefined) {
      response = await opts.providerEgress.request({
        originKey: opts.originKey ?? "mcp",
        url,
        method,
        headers,
        ...(body === undefined ? {} : { body }),
        secretValues,
        privileged: true,
        redirect: "deny",
        limits,
        signal,
      });
    } else {
      if (opts.fetchImpl === undefined) {
        throw new Error("ProviderEgress or guarded fetchImpl is required (Task 2 wiring).");
      }
      const legacy = await opts.fetchImpl(url, {
        method,
        headers,
        ...(body === undefined ? {} : { body: body as unknown as BodyInit }),
        redirect: "manual",
        signal,
      });
      response = egressResponseFromDecodedFetch(legacy, url);
    }
    await assertBoundedHeadersOrCancel(response, limits);
    return response;
  }

  async function cancel(response: EgressResponse): Promise<void> {
    await response.body.cancel().catch(() => {});
  }

  async function send(msg: JsonRpcMessage): Promise<void> {
    const secretValues = Object.values(baseHeaders).filter((value) => value !== "");
    try {
      if (closed) throw new Error("MCP HTTP transport is closed");
      const headers: Record<string, string> = {
        ...baseHeaders,
        accept: "application/json, text/event-stream",
        "content-type": "application/json",
      };
      const token = await opts.accessToken?.();
      if (token != null) {
        headers.authorization = `Bearer ${token}`;
        secretValues.push(token);
      }
      if (sessionId !== null) {
        headers["mcp-session-id"] = sessionId;
        secretValues.push(sessionId);
      }
      if (protocolVersion !== null) headers["mcp-protocol-version"] = protocolVersion;
      if (closed) throw new Error("MCP HTTP transport is closed");

      const isInitialize = "method" in msg && msg.method === "initialize";
      const response = await request(
        new URL(opts.url),
        "POST",
        headers,
        new TextEncoder().encode(JSON.stringify(msg)),
        secretValues,
      );

      if (response.status === 401) {
        const challenge = response.headers.get("www-authenticate");
        await cancel(response);
        throw new McpAuthRequiredError(
          response.status,
          challenge === null ? null : redactor.text(challenge, secretValues),
        );
      }
      if (response.status === 404 && sessionId !== null) {
        await cancel(response);
        throw new McpSessionExpiredError();
      }
      if (isInitialize) {
        const sid = response.headers.get("mcp-session-id");
        if (sid !== null) sessionId = sid;
      }
      if (response.status === 202) {
        await cancel(response);
        return;
      }
      if (response.status < 200 || response.status >= 300) {
        await cancel(response);
        throw new Error(`MCP server returned HTTP ${response.status}`);
      }

      const contentType = response.headers.get("content-type") ?? "";
      if (contentType.includes("text/event-stream")) {
        const wantId = "id" in msg ? String(msg.id) : null;
        try {
          await readBoundedSse(response, limits, (data) => {
            const message = parseAndDispatch(data, secretValues);
            if (message !== null && wantId !== null && "id" in message && String(message.id) === wantId) {
              throw new MatchingFrame();
            }
          });
        } catch (error) {
          if (!(error instanceof MatchingFrame)) throw error;
        }
        return;
      }
      const frameLimits = {
        ...limits,
        responseBytes: Math.min(limits.responseBytes, limits.jsonRpcFrameBytes),
        decompressedBytes: Math.min(limits.decompressedBytes, limits.jsonRpcFrameBytes),
      };
      const body = await readBoundedBody(response, frameLimits);
      const text = new TextDecoder("utf-8", { fatal: true }).decode(body);
      if (text.trim() !== "") parseAndDispatch(text, secretValues);
    } catch (error) {
      if (error instanceof McpAuthRequiredError || error instanceof McpSessionExpiredError) throw error;
      if (error instanceof EgressLimitError) throw redactor.error(error, secretValues);
      if (error instanceof Error && error.message === "MCP HTTP transport is closed") throw error;
      if (error instanceof Error && error.message.startsWith("ProviderEgress or guarded fetchImpl")) throw error;
      if (error instanceof Error && /^MCP server returned HTTP \d+$/.test(error.message)) throw error;
      throw redactor.error(new Error("MCP HTTP request failed."), secretValues);
    }
  }

  const transport: HttpTransport = {
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
      abort.abort();
      fireClose(true);
    },
  };
  return transport;
}
