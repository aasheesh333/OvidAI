/**
 * MCP legacy SSE transport (2024-11-05): a bounded long-lived GET event
 * stream plus bounded POSTs. ProviderEgress is the Task 2 consumer seam; the
 * legacy guarded-fetch adapter remains only until composition is rewired.
 */

import {
  assertBoundedHeadersOrCancel,
  DEFAULT_STREAM_LIMITS,
  EgressLimitError,
  egressResponseFromDecodedFetch,
  readBoundedBody,
  readBoundedSse,
  type EgressResponse,
  type StreamLimits,
} from "../egress/responseLimits.js";
import { createSecretRedactor } from "../egress/redactor.js";
import type { JsonRpcMessage } from "../jsonrpc.js";
import type { McpTransport } from "../transport.js";
import { McpAuthRequiredError, projectMcpRpcMessage, type HttpTransportOptions } from "./http.js";

export function createSseTransport(opts: HttpTransportOptions): McpTransport {
  const baseHeaders: Record<string, string> = opts.headers ?? {};
  const limits: StreamLimits = opts.limits ?? DEFAULT_STREAM_LIMITS;
  const redactor = opts.redactor ?? createSecretRedactor();
  let closed = false;
  let started = false;
  let postUrl: string | null = null;
  let msgCb: ((m: JsonRpcMessage) => void) | undefined;
  let closeCb: ((info: { expected: boolean }) => void) | undefined;
  let closeFired = false;
  const abort = new AbortController();
  let endpointResolve: (() => void) | undefined;
  let endpointReject: ((error: Error) => void) | undefined;
  const endpointReady = new Promise<void>((resolve, reject) => {
    endpointResolve = resolve;
    endpointReject = reject;
  });

  async function auth(): Promise<{ headers: Record<string, string>; secrets: string[] }> {
    const headers: Record<string, string> = { ...baseHeaders };
    const secrets = Object.values(baseHeaders).filter((value) => value !== "");
    const token = await opts.accessToken?.();
    if (token != null) {
      headers.authorization = `Bearer ${token}`;
      secrets.push(token);
    }
    return { headers, secrets };
  }

  function fireClose(expected: boolean): void {
    if (closeFired) return;
    closeFired = true;
    closeCb?.({ expected });
  }

  async function request(
    url: URL,
    method: "GET" | "POST",
    headers: Record<string, string>,
    body: Uint8Array | undefined,
    secrets: readonly string[],
  ): Promise<EgressResponse> {
    const signal = AbortSignal.any([abort.signal, AbortSignal.timeout(limits.totalMs)]);
    let response: EgressResponse;
    if (opts.providerEgress !== undefined) {
      response = await opts.providerEgress.request({
        originKey: opts.originKey ?? "mcp-sse",
        url,
        method,
        headers,
        ...(body === undefined ? {} : { body }),
        secretValues: secrets,
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

  function handleData(data: string, secrets: readonly string[]): void {
    if (postUrl === null) {
      const endpoint = new URL(data, opts.url);
      if (endpoint.origin !== new URL(opts.url).origin || endpoint.username !== "" || endpoint.password !== "") {
        throw new Error("MCP SSE endpoint origin was refused");
      }
      postUrl = endpoint.toString();
      endpointResolve?.();
      return;
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(data);
    } catch {
      return;
    }
    const message = projectMcpRpcMessage(parsed, redactor, secrets);
    if (message !== null) msgCb?.(message);
  }

  async function readLoop(response: EgressResponse, secrets: readonly string[]): Promise<void> {
    try {
      await readBoundedSse(response, limits, (data) => handleData(data, secrets));
      if (postUrl === null) endpointReject?.(new Error("MCP SSE stream ended before its endpoint event"));
      fireClose(closed);
    } catch (error) {
      if (postUrl === null) {
        endpointReject?.(redactor.error(new Error("MCP SSE stream failed before its endpoint event"), secrets));
      }
      fireClose(false);
    }
  }

  async function start(): Promise<void> {
    if (closed) throw new Error("MCP SSE transport is closed");
    if (started) return;
    started = true;
    try {
      const { headers, secrets } = await auth();
      headers.accept = "text/event-stream";
      const response = await request(new URL(opts.url), "GET", headers, undefined, secrets);
      if (response.status === 401) {
        const challenge = response.headers.get("www-authenticate");
        await response.body.cancel().catch(() => {});
        throw new McpAuthRequiredError(401, challenge === null ? null : redactor.text(challenge, secrets));
      }
      if (response.status < 200 || response.status >= 300) {
        await response.body.cancel().catch(() => {});
        throw new Error(`MCP server refused the SSE stream with HTTP ${response.status}`);
      }
      void readLoop(response, secrets);
      await endpointReady;
    } catch (error) {
      started = false;
      if (error instanceof McpAuthRequiredError) throw error;
      if (error instanceof EgressLimitError) throw redactor.error(error);
      if (error instanceof Error && /^MCP server refused the SSE stream with HTTP \d+$/.test(error.message)) {
        throw error;
      }
      throw redactor.error(new Error("MCP SSE transport failed to start."));
    }
  }

  async function send(msg: JsonRpcMessage): Promise<void> {
    const secrets = Object.values(baseHeaders).filter((value) => value !== "");
    try {
      if (closed) throw new Error("MCP SSE transport is closed");
      if (postUrl === null) throw new Error("MCP SSE transport has no POST endpoint yet");
      const { headers, secrets: authSecrets } = await auth();
      secrets.push(...authSecrets);
      headers["content-type"] = "application/json";
      const response = await request(
        new URL(postUrl),
        "POST",
        headers,
        new TextEncoder().encode(JSON.stringify(msg)),
        secrets,
      );
      if (response.status === 401) {
        const challenge = response.headers.get("www-authenticate");
        await response.body.cancel().catch(() => {});
        throw new McpAuthRequiredError(401, challenge === null ? null : redactor.text(challenge, secrets));
      }
      if (response.status < 200 || response.status >= 300) {
        await response.body.cancel().catch(() => {});
        throw new Error(`MCP server returned HTTP ${response.status} for the POST endpoint`);
      }
      await readBoundedBody(response, limits);
    } catch (error) {
      if (error instanceof McpAuthRequiredError) throw error;
      if (error instanceof EgressLimitError) throw redactor.error(error, secrets);
      if (error instanceof Error && error.message.startsWith("MCP SSE transport")) throw error;
      if (error instanceof Error && /^MCP server returned HTTP \d+ for the POST endpoint$/.test(error.message)) {
        throw error;
      }
      throw redactor.error(new Error("MCP SSE POST failed."), secrets);
    }
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
