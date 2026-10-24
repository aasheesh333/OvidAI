import { request as httpsRequest, Agent as HttpsAgent } from "node:https";
import type { LookupFunction } from "node:net";
import { isIP } from "node:net";
import { Readable } from "node:stream";

import { parseAddressBytes } from "@ovid/shared";
import {
  defaultHostResolver,
  isLoopbackAddress,
  isNonPublicAddress,
  SsrfBlockedError,
  type HostResolver,
} from "../ssrf.js";
import type { SecretRedactor } from "./redactor.js";

export type EgressMethod = "GET" | "POST" | "PUT" | "PATCH" | "DELETE" | "HEAD";

export interface EgressLimits {
  connectMs: number;
  headersMs: number;
  idleMs: number;
  totalMs: number;
  maxRedirects: number;
  headerBytes: number;
  responseBytes: number;
  decompressedBytes: number;
}

export interface EgressRequest {
  originKey: string;
  url: URL;
  method: EgressMethod;
  headers: Record<string, string>;
  body?: Uint8Array;
  secretValues?: readonly string[];
  privileged?: boolean;
  redirect: "deny" | "same_origin";
  limits: EgressLimits;
  signal?: AbortSignal;
}

export interface EgressResponse {
  status: number;
  headers: Headers;
  body: ReadableStream<Uint8Array>;
  origin: URL;
  remoteAddress: string;
}

export interface ProviderEgress {
  request(req: EgressRequest): Promise<EgressResponse>;
  close(): Promise<void>;
}

/** Low-level test seam. Production construction rejects a supplied factory. */
export interface PinnedDispatcherOptions {
  origin: URL;
  addresses: readonly string[];
  servername: string;
  lookup: LookupFunction;
}

export interface PinnedDispatchRequest {
  url: URL;
  method: EgressMethod;
  headers: Record<string, string>;
  body?: Uint8Array;
  signal: AbortSignal;
  connectMs: number;
  headersMs: number;
}

export interface PinnedDispatchResponse {
  status: number;
  headers: Headers;
  body: ReadableStream<Uint8Array>;
  remoteAddress: string;
  /** Raw wire bytes when the dispatcher has them; normalized headers are a fallback. */
  headerBytes?: number;
}

export interface PinnedDispatcher {
  dispatch(req: PinnedDispatchRequest): Promise<PinnedDispatchResponse>;
  close(): Promise<void>;
}

export type PinnedDispatcherFactory = (options: PinnedDispatcherOptions) => PinnedDispatcher;

export interface CreateProviderEgressOptions {
  origins: Readonly<Record<string, readonly URL[]>>;
  resolver?: HostResolver;
  dispatcherFactory?: PinnedDispatcherFactory;
  redactor: SecretRedactor;
  production: boolean;
}

export class ProviderEgressError extends Error {
  readonly code: string;

  constructor(code: string, message = code, name = "ProviderEgressError") {
    super(message);
    this.name = name;
    this.code = code;
  }
}

const METHODS = new Set<EgressMethod>(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]);
const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);
const FORBIDDEN_HEADERS = new Set([
  "connection",
  "host",
  "keep-alive",
  "proxy-connection",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);
const encoder = new TextEncoder();

function bareHost(url: URL): string {
  return url.hostname.toLowerCase().replace(/^\[/, "").replace(/\]$/, "").replace(/\.+$/, "");
}

function portOf(url: URL): number {
  return url.port === "" ? 443 : Number(url.port);
}

function localName(host: string): boolean {
  return host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local");
}

function validateOrigin(url: URL): void {
  if (url.protocol !== "https:") throw new ProviderEgressError("egress_https_required");
  if (url.username !== "" || url.password !== "") {
    throw new ProviderEgressError("egress_userinfo_denied");
  }
  const host = bareHost(url);
  if (host === "" || localName(host)) throw new SsrfBlockedError("egress_local_name_denied");
  const literalLoopback = isIP(host) !== 0 && isLoopbackAddress(host);
  if (portOf(url) !== 443 && !literalLoopback) {
    throw new ProviderEgressError("egress_port_denied");
  }
}

function validateLimits(limits: EgressLimits): void {
  for (const [name, value] of Object.entries({
    connectMs: limits.connectMs,
    headersMs: limits.headersMs,
    idleMs: limits.idleMs,
    totalMs: limits.totalMs,
  })) {
    if (!Number.isFinite(value) || value <= 0) {
      throw new ProviderEgressError("egress_limits_invalid", `egress_limits_invalid:${name}`);
    }
  }
  for (const [name, value] of Object.entries({
    maxRedirects: limits.maxRedirects,
    headerBytes: limits.headerBytes,
    responseBytes: limits.responseBytes,
    decompressedBytes: limits.decompressedBytes,
  })) {
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new ProviderEgressError("egress_limits_invalid", `egress_limits_invalid:${name}`);
    }
  }
}

function normalizedHeaders(req: EgressRequest): Record<string, string> {
  const headers: Record<string, string> = {};
  for (const [rawName, value] of Object.entries(req.headers)) {
    const name = rawName.toLowerCase();
    if (FORBIDDEN_HEADERS.has(name)) throw new ProviderEgressError("egress_header_denied");
    headers[name] = value;
  }
  const bodyLength = req.body?.byteLength ?? 0;
  const declared = headers["content-length"];
  if (declared !== undefined) {
    const parsed = Number(declared);
    if (!Number.isSafeInteger(parsed) || parsed < 0 || parsed !== bodyLength) {
      throw new ProviderEgressError("egress_content_length_invalid");
    }
  } else if (req.body !== undefined) {
    headers["content-length"] = String(bodyLength);
  }
  return headers;
}

function redirectedHeaders(headers: Record<string, string>, dropBody: boolean): Record<string, string> {
  if (!dropBody) return { ...headers };
  const next = { ...headers };
  delete next["content-length"];
  delete next["content-type"];
  return next;
}

function mappedIpv4(bytes: number[]): number[] | null {
  if (bytes.length !== 16) return null;
  for (let i = 0; i < 10; i++) if (bytes[i] !== 0) return null;
  if ((bytes[10] === 0xff && bytes[11] === 0xff) || (bytes[10] === 0 && bytes[11] === 0)) {
    return bytes.slice(12);
  }
  return null;
}

function sameAddress(left: string, right: string): boolean {
  const a = parseAddressBytes(left);
  const b = parseAddressBytes(right);
  if (a === null || b === null) return false;
  const aa = a.length === 4 ? a : (mappedIpv4(a) ?? a);
  const bb = b.length === 4 ? b : (mappedIpv4(b) ?? b);
  return aa.length === bb.length && aa.every((value, index) => value === bb[index]);
}

function checkedRemote(remoteAddress: string, addresses: readonly string[]): boolean {
  return addresses.some((address) => sameAddress(remoteAddress, address));
}

function pinnedLookup(addresses: readonly string[]): LookupFunction {
  const records = addresses.map((address) => ({ address, family: isIP(address) }));
  return (_hostname, options, callback) => {
    if (options.all) {
      callback(null, records);
      return;
    }
    const record = records.find(
      (candidate) => options.family === undefined || options.family === 0 || candidate.family === options.family,
    );
    if (record === undefined) {
      const error = new Error("checked address family unavailable") as NodeJS.ErrnoException;
      error.code = "ENOTFOUND";
      callback(error, "");
      return;
    }
    callback(null, record.address, record.family);
  };
}

function headersFromRaw(rawHeaders: readonly string[]): Headers {
  const headers = new Headers();
  for (let index = 0; index < rawHeaders.length; index += 2) {
    headers.append(rawHeaders[index], rawHeaders[index + 1]);
  }
  return headers;
}

function rawHeaderBytes(rawHeaders: readonly string[]): number {
  let bytes = 0;
  for (let index = 0; index < rawHeaders.length; index += 2) {
    bytes += encoder.encode(rawHeaders[index]).byteLength + encoder.encode(rawHeaders[index + 1]).byteLength + 4;
  }
  return bytes;
}

/**
 * Built-in one-shot Node dispatcher. `ca` exists only so tests can trust a
 * local fixture certificate in their own agent; production never supplies it.
 * It is intentionally not re-exported from the package barrel.
 */
export function createNodePinnedDispatcher(
  options: PinnedDispatcherOptions & { ca?: string },
): PinnedDispatcher {
  // RFC 6066 forbids IP-literal SNI. Node still verifies an IP SAN against
  // the request hostname when servername is omitted; DNS names retain SNI.
  const tlsServername = isIP(options.servername) === 0 ? options.servername : undefined;
  const agent = new HttpsAgent({
    ca: options.ca,
    keepAlive: false,
    lookup: options.lookup,
    maxSockets: 1,
    rejectUnauthorized: true,
    servername: tlsServername,
  });
  let closed = false;
  return {
    dispatch(input) {
      if (closed) return Promise.reject(new ProviderEgressError("egress_closed"));
      if (input.signal.aborted) return Promise.reject(input.signal.reason);
      return new Promise<PinnedDispatchResponse>((resolve, reject) => {
        let settled = false;
        let remoteAddress = "";
        const request = httpsRequest(input.url, {
          agent,
          headers: input.headers,
          lookup: options.lookup,
          method: input.method,
          rejectUnauthorized: true,
          servername: tlsServername,
        });
        const finish = (error?: Error, response?: PinnedDispatchResponse) => {
          if (settled) return;
          settled = true;
          clearTimeout(connectTimer);
          clearTimeout(headersTimer);
          if (error) reject(error);
          else resolve(response!);
        };
        const onAbort = () => request.destroy(input.signal.reason);
        input.signal.addEventListener("abort", onAbort, { once: true });
        const connectTimer = setTimeout(() => {
          request.destroy(new ProviderEgressError("egress_connect_timeout"));
        }, input.connectMs);
        const headersTimer = setTimeout(() => {
          request.destroy(new ProviderEgressError("egress_headers_timeout"));
        }, input.headersMs);
        request.once("error", (error: Error) => {
          input.signal.removeEventListener("abort", onAbort);
          finish(error);
        });
        request.once("socket", (socket) => {
          socket.once("secureConnect", () => {
            if (settled) return;
            remoteAddress = socket.remoteAddress ?? "";
            if (!checkedRemote(remoteAddress, options.addresses)) {
              request.destroy(new ProviderEgressError("egress_remote_address"));
              return;
            }
            clearTimeout(connectTimer);
            request.end(input.body);
          });
        });
        request.once("response", (response) => {
          clearTimeout(headersTimer);
          const actualRemote = response.socket.remoteAddress ?? remoteAddress;
          if (!checkedRemote(actualRemote, options.addresses)) {
            response.destroy();
            finish(new ProviderEgressError("egress_remote_address"));
            return;
          }
          response.once("close", () => input.signal.removeEventListener("abort", onAbort));
          finish(undefined, {
            status: response.statusCode ?? 0,
            headers: headersFromRaw(response.rawHeaders),
            body: Readable.toWeb(response) as ReadableStream<Uint8Array>,
            remoteAddress: actualRemote,
            headerBytes: rawHeaderBytes(response.rawHeaders),
          });
        });
      });
    },
    async close() {
      if (closed) return;
      closed = true;
      agent.destroy();
    },
  };
}

function abortError(): ProviderEgressError {
  return new ProviderEgressError("egress_aborted", "egress_aborted", "AbortError");
}

function linkedSignal(signals: readonly AbortSignal[]): { signal: AbortSignal; dispose: () => void } {
  const controller = new AbortController();
  const listeners = new Map<AbortSignal, () => void>();
  for (const signal of signals) {
    const abort = () => controller.abort(signal.reason);
    if (signal.aborted) abort();
    else {
      signal.addEventListener("abort", abort, { once: true });
      listeners.set(signal, abort);
    }
  }
  return {
    signal: controller.signal,
    dispose() {
      for (const [signal, listener] of listeners) signal.removeEventListener("abort", listener);
      listeners.clear();
    },
  };
}

function waitWithSignal<T>(promise: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) return Promise.reject(signal.reason);
  return new Promise<T>((resolve, reject) => {
    const onAbort = () => {
      signal.removeEventListener("abort", onAbort);
      reject(signal.reason);
    };
    signal.addEventListener("abort", onAbort, { once: true });
    promise.then(
      (value) => {
        signal.removeEventListener("abort", onAbort);
        resolve(value);
      },
      (error: unknown) => {
        signal.removeEventListener("abort", onAbort);
        reject(error);
      },
    );
  });
}

function responseHeaderBytes(headers: Headers): number {
  let bytes = 0;
  headers.forEach((value, name) => {
    bytes += encoder.encode(name).byteLength + encoder.encode(value).byteLength + 4;
  });
  return bytes;
}

function validateDispatchResponse(
  response: PinnedDispatchResponse,
  addresses: readonly string[],
  limits: EgressLimits,
): void {
  if (!checkedRemote(response.remoteAddress, addresses)) {
    throw new ProviderEgressError("egress_remote_address");
  }
  const headerBytes = Math.max(
    responseHeaderBytes(response.headers),
    response.headerBytes ?? 0,
  );
  if (headerBytes > limits.headerBytes) throw new ProviderEgressError("egress_header_bytes");
  const declared = response.headers.get("content-length");
  if (declared !== null) {
    const length = Number(declared);
    if (!Number.isSafeInteger(length) || length < 0) {
      throw new ProviderEgressError("egress_content_length_invalid");
    }
    if (length > limits.responseBytes) throw new ProviderEgressError("egress_response_bytes");
  }
}

async function dispatchWithDeadline(
  dispatcher: PinnedDispatcher,
  input: PinnedDispatchRequest,
): Promise<PinnedDispatchResponse> {
  if (input.signal.aborted) {
    await dispatcher.close().catch(() => {});
    throw input.signal.reason;
  }
  return new Promise<PinnedDispatchResponse>((resolve, reject) => {
    let settled = false;
    const finish = (error?: unknown, response?: PinnedDispatchResponse) => {
      if (settled) {
        if (response) void response.body.cancel().catch(() => {});
        return;
      }
      settled = true;
      clearTimeout(timer);
      input.signal.removeEventListener("abort", onAbort);
      if (error !== undefined) reject(error);
      else resolve(response!);
    };
    const onAbort = () => {
      void dispatcher.close();
      finish(input.signal.reason);
    };
    const timer = setTimeout(() => {
      void dispatcher.close();
      finish(new ProviderEgressError("egress_headers_timeout"));
    }, input.headersMs);
    input.signal.addEventListener("abort", onAbort, { once: true });
    dispatcher.dispatch(input).then(
      (response) => finish(undefined, response),
      (error: unknown) => finish(error),
    );
  });
}

function sanitizeError(error: unknown, redactor: SecretRedactor, secrets: readonly string[]): Error {
  const safe =
    error instanceof ProviderEgressError || error instanceof SsrfBlockedError
      ? error
      : new ProviderEgressError("egress_transport_failed");
  const cleaned = redactor.error(safe, secrets);
  if (safe instanceof SsrfBlockedError) return new SsrfBlockedError(cleaned.message);
  if (safe instanceof ProviderEgressError) {
    return new ProviderEgressError(safe.code, cleaned.message, safe.name);
  }
  return cleaned;
}

export function createProviderEgress(deps: CreateProviderEgressOptions): ProviderEgress {
  if (deps.production && (deps.resolver !== undefined || deps.dispatcherFactory !== undefined)) {
    throw new ProviderEgressError("egress_test_only_transport", "egress transport seams are test-only");
  }
  const resolver = deps.resolver ?? defaultHostResolver;
  const dispatcherFactory = deps.dispatcherFactory ?? createNodePinnedDispatcher;
  const origins = new Map<string, URL[]>();
  for (const [key, values] of Object.entries(deps.origins)) {
    const copied = values.map((value) => new URL(value));
    for (const value of copied) validateOrigin(value);
    origins.set(key, copied);
  }

  const dispatchers = new Set<PinnedDispatcher>();
  const totals = new Set<AbortController>();
  let closed = false;

  async function closeDispatcher(dispatcher: PinnedDispatcher): Promise<void> {
    dispatchers.delete(dispatcher);
    await dispatcher.close();
  }

  async function request(req: EgressRequest): Promise<EgressResponse> {
    const secrets = req.secretValues ?? [];
    const total = new AbortController();
    const idle = new AbortController();
    const external = new AbortController();
    const forwardAbort = () => external.abort(abortError());
    if (req.signal?.aborted) forwardAbort();
    else req.signal?.addEventListener("abort", forwardAbort, { once: true });
    const linked = linkedSignal([total.signal, idle.signal, external.signal]);
    const timer = setTimeout(() => {
      total.abort(new ProviderEgressError("egress_total_timeout"));
    }, req.limits?.totalMs ?? 1_000);
    totals.add(total);
    let finished = false;
    const finish = () => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      totals.delete(total);
      linked.dispose();
      req.signal?.removeEventListener("abort", forwardAbort);
    };

    try {
      if (closed) throw new ProviderEgressError("egress_closed");
      if (external.signal.aborted) throw abortError();
      validateLimits(req.limits);
      if (!METHODS.has(req.method)) throw new ProviderEgressError("egress_method_denied");
      validateOrigin(req.url);
      const allowed = origins.get(req.originKey);
      if (allowed === undefined || !allowed.some((value) => value.origin === req.url.origin)) {
        throw new ProviderEgressError("egress_origin_denied");
      }

      let current = new URL(req.url);
      let method = req.method;
      let body = req.body;
      let headers = normalizedHeaders(req);
      for (let redirects = 0; ; redirects++) {
        if (external.signal.aborted) throw abortError();
        validateOrigin(current);
        const allowedOrigins = origins.get(req.originKey)!;
        if (!allowedOrigins.some((value) => value.origin === current.origin)) {
          throw new ProviderEgressError("egress_origin_denied");
        }
        const host = bareHost(current);
        const literal = isIP(host) !== 0;
        let addresses: readonly string[];
        if (literal) addresses = [host];
        else {
          try {
            addresses = [...await waitWithSignal(resolver(host), linked.signal)];
          } catch (error) {
            if (linked.signal.aborted) throw linked.signal.reason;
            throw new SsrfBlockedError("egress_dns_failed");
          }
          if (addresses.length === 0) throw new SsrfBlockedError("egress_dns_empty");
        }
        for (const address of addresses) {
          if (isNonPublicAddress(address)) {
            if (!deps.production && literal && isLoopbackAddress(address)) continue;
            throw new SsrfBlockedError("egress_non_public_address");
          }
        }
        if (addresses.length === 0) throw new SsrfBlockedError("egress_dns_empty");
        if (linked.signal.aborted) throw linked.signal.reason;

        const dispatcher = dispatcherFactory({
          origin: new URL(current.origin),
          addresses: [...addresses],
          servername: host,
          lookup: pinnedLookup(addresses),
        });
        dispatchers.add(dispatcher);
        let response: PinnedDispatchResponse | undefined;
        try {
          response = await dispatchWithDeadline(dispatcher, {
            url: current,
            method,
            headers,
            body,
            signal: linked.signal,
            connectMs: req.limits.connectMs,
            headersMs: req.limits.headersMs,
          });
          validateDispatchResponse(response, addresses, req.limits);
        } catch (error) {
          if (response !== undefined) await response.body.cancel().catch(() => {});
          await closeDispatcher(dispatcher).catch(() => {});
          throw error;
        }
        if (response === undefined) throw new ProviderEgressError("egress_transport_failed");

        const location = response.headers.get("location");
        const isRedirect = REDIRECT_STATUSES.has(response.status) && location !== null;
        if (req.redirect === "deny" || !isRedirect) {
          const source = response.body;
          const reader = source.getReader();
          let bytes = 0;
          let streamDone = false;
          const done = () => {
            if (streamDone) return;
            streamDone = true;
            finish();
            void closeDispatcher(dispatcher).catch(() => {});
          };
          const failStream = async (error: unknown): Promise<never> => {
            idle.abort(error);
            await reader.cancel(error).catch(() => {});
            done();
            throw sanitizeError(error, deps.redactor, secrets);
          };
          const onAbort = () => {
            void reader.cancel(linked.signal.reason).catch(() => {});
            done();
          };
          linked.signal.addEventListener("abort", onAbort, { once: true });
          const bodyStream = new ReadableStream<Uint8Array>({
            async pull(controller) {
              let timeout: ReturnType<typeof setTimeout> | undefined;
              try {
                if (linked.signal.aborted) throw linked.signal.reason;
                const idlePromise = new Promise<never>((_resolve, reject) => {
                  timeout = setTimeout(
                    () => reject(new ProviderEgressError("egress_idle_timeout")),
                    req.limits.idleMs,
                  );
                });
                const next = await Promise.race([reader.read(), idlePromise]);
                if (linked.signal.aborted) throw linked.signal.reason;
                if (next.done) {
                  controller.close();
                  done();
                  return;
                }
                bytes += next.value.byteLength;
                if (bytes > req.limits.responseBytes) {
                  throw new ProviderEgressError("egress_response_bytes");
                }
                controller.enqueue(next.value);
              } catch (error) {
                await failStream(error);
              } finally {
                clearTimeout(timeout);
                if (streamDone) linked.signal.removeEventListener("abort", onAbort);
              }
            },
            async cancel(reason) {
              await reader.cancel(reason).catch(() => {});
              done();
              linked.signal.removeEventListener("abort", onAbort);
            },
          });
          return {
            status: response.status,
            headers: response.headers,
            body: bodyStream,
            origin: new URL(current.origin),
            remoteAddress: response.remoteAddress,
          };
        }

        if (redirects >= req.limits.maxRedirects) {
          await response.body.cancel().catch(() => {});
          await closeDispatcher(dispatcher).catch(() => {});
          throw new ProviderEgressError("egress_too_many_redirects");
        }
        let next: URL;
        try {
          next = new URL(location, current);
        } catch {
          await response.body.cancel().catch(() => {});
          await closeDispatcher(dispatcher).catch(() => {});
          throw new ProviderEgressError("egress_redirect_invalid");
        }
        if (next.protocol !== "https:") {
          await response.body.cancel().catch(() => {});
          await closeDispatcher(dispatcher).catch(() => {});
          throw new ProviderEgressError("egress_redirect_downgrade");
        }
        if (next.origin !== current.origin) {
          await response.body.cancel().catch(() => {});
          await closeDispatcher(dispatcher).catch(() => {});
          throw new ProviderEgressError("egress_redirect_cross_origin");
        }
        await response.body.cancel().catch(() => {});
        await closeDispatcher(dispatcher);
        validateOrigin(next);
        const dropBody =
          response.status === 303 ||
          ((response.status === 301 || response.status === 302) && method !== "GET" && method !== "HEAD");
        if (dropBody) {
          method = "GET";
          body = undefined;
        }
        headers = redirectedHeaders(headers, dropBody);
        current = next;
      }
    } catch (error) {
      finish();
      throw sanitizeError(error, deps.redactor, secrets);
    }
  }

  return {
    request,
    async close() {
      if (closed) return;
      closed = true;
      for (const controller of totals) {
        controller.abort(new ProviderEgressError("egress_closed"));
      }
      await Promise.all([...dispatchers].map((dispatcher) => closeDispatcher(dispatcher).catch(() => {})));
    },
  };
}
