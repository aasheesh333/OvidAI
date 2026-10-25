import { isIP, type LookupFunction } from "node:net";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { createBrotliDecompress, createGunzip, createInflate } from "node:zlib";

import { parseAddressBytes } from "@ovid/shared";

import {
  defaultHostResolver,
  isNonPublicAddress,
  type GuardedFetch,
  type HostResolver,
} from "../ssrf.js";
import {
  createNodePinnedDispatcher,
  ProviderEgressError,
  type EgressLimits,
  type PinnedDispatcher,
  type PinnedDispatcherFactory,
  type PinnedDispatcherOptions,
  type PinnedDispatchRequest,
  type PinnedDispatchResponse,
} from "./providerEgress.js";

/** Internal RequestInit marker consumed only by the worker's native-fetch adapter. */
export const PUBLIC_WEB_FETCH_REQUEST: unique symbol = Symbol("ovid.public-web-fetch");
export type PublicWebFetchRequestInit = RequestInit & {
  [PUBLIC_WEB_FETCH_REQUEST]?: true;
};

export type PublicWebDispatcherOptions = PinnedDispatcherOptions;

export interface CreatePublicWebFetchOptions {
  /** Defaults to the fail-closed A+AAAA resolver shared with the SSRF guard. */
  resolver?: HostResolver;
  /** Defaults to the existing checked-address Node/TLS dispatcher. */
  dispatcherFactory?: PinnedDispatcherFactory;
  limits?: Partial<EgressLimits>;
}

export class PublicWebFetchError extends Error {
  constructor(readonly code: string, name = "PublicWebFetchError") {
    super(code);
    this.name = name;
  }
}

export const PUBLIC_WEB_FETCH_LIMITS: EgressLimits = {
  connectMs: 5_000,
  headersMs: 15_000,
  idleMs: 30_000,
  totalMs: 30_000,
  // Shared EgressLimits shape only: native followGuardedRedirects owns hops.
  maxRedirects: 0,
  headerBytes: 16_384,
  responseBytes: 2 * 1024 * 1024,
  decompressedBytes: 2 * 1024 * 1024,
};

const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);
const NULL_BODY_STATUSES = new Set([204, 205, 304]);
const encoder = new TextEncoder();
const DENIED_HEADERS = new Set([
  "api-key",
  "authorization",
  "connection",
  "cookie",
  "host",
  "keep-alive",
  "proxy-authorization",
  "proxy-connection",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
  "x-api-key",
  "x-auth-token",
]);

function abortError(): PublicWebFetchError {
  return new PublicWebFetchError("public_fetch_aborted", "AbortError");
}

function bareHost(url: URL): string {
  return url.hostname.toLowerCase().replace(/^\[/, "").replace(/\]$/, "").replace(/\.+$/, "");
}

function validateUrl(value: URL): void {
  if (value.protocol !== "https:") throw new PublicWebFetchError("public_fetch_https_required");
  if (value.username !== "" || value.password !== "") {
    throw new PublicWebFetchError("public_fetch_userinfo_denied");
  }
  const port = value.port === "" ? 443 : Number(value.port);
  if (port !== 443) throw new PublicWebFetchError("public_fetch_port_denied");
  const host = bareHost(value);
  if (host === "" || host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local")) {
    throw new PublicWebFetchError("public_fetch_non_public_address");
  }
}

function parseUrl(raw: string): URL {
  try {
    const value = new URL(raw);
    validateUrl(value);
    return value;
  } catch (error) {
    if (error instanceof PublicWebFetchError) throw error;
    throw new PublicWebFetchError("public_fetch_invalid_url");
  }
}

function validateLimits(limits: EgressLimits): void {
  for (const value of [limits.connectMs, limits.headersMs, limits.idleMs, limits.totalMs]) {
    if (!Number.isFinite(value) || value <= 0) throw new PublicWebFetchError("public_fetch_limits_invalid");
  }
  for (const value of [
    limits.maxRedirects,
    limits.headerBytes,
    limits.responseBytes,
    limits.decompressedBytes,
  ]) {
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new PublicWebFetchError("public_fetch_limits_invalid");
    }
  }
}

function requestParts(init: RequestInit): {
  method: "GET" | "HEAD";
  headers: Record<string, string>;
} {
  const method = (init.method ?? "GET").toUpperCase();
  if (method !== "GET" && method !== "HEAD") {
    throw new PublicWebFetchError("public_fetch_method_denied");
  }
  if (init.body !== undefined && init.body !== null) {
    throw new PublicWebFetchError("public_fetch_body_denied");
  }
  if (init.credentials !== undefined && init.credentials !== "omit") {
    throw new PublicWebFetchError("public_fetch_credentials_denied");
  }
  const overrides = init as unknown as Record<string, unknown>;
  for (const key of ["agent", "dispatcher", "proxy", "transport"]) {
    if (overrides[key] !== undefined) throw new PublicWebFetchError("public_fetch_transport_override_denied");
  }

  let incoming: Headers;
  try {
    incoming = new Headers(init.headers);
  } catch {
    throw new PublicWebFetchError("public_fetch_headers_denied");
  }
  const headers: Record<string, string> = {};
  let denied = false;
  incoming.forEach((value, name) => {
    if (DENIED_HEADERS.has(name)) denied = true;
    else headers[name] = value;
  });
  if (denied) throw new PublicWebFetchError("public_fetch_credentials_denied");
  return { method, headers };
}

async function waitWithSignal<T>(pending: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) {
    // The promise was already created by the caller. Observe a late rejection
    // even though the abort has already won, then refuse the operation.
    void pending.then(() => undefined, () => undefined);
    throw signal.reason;
  }
  return new Promise<T>((resolve, reject) => {
    let settled = false;
    const cleanup = () => signal.removeEventListener("abort", onAbort);
    const onAbort = () => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(signal.reason);
    };
    signal.addEventListener("abort", onAbort, { once: true });
    pending.then(
      (value) => {
        if (settled) return;
        settled = true;
        cleanup();
        resolve(value);
      },
      (error: unknown) => {
        if (settled) return;
        settled = true;
        cleanup();
        reject(error);
      },
    );
  });
}

function mappedIpv4(bytes: number[]): number[] | null {
  if (bytes.length !== 16) return null;
  for (let index = 0; index < 10; index++) if (bytes[index] !== 0) return null;
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

async function resolveCheckedAddresses(
  url: URL,
  resolver: HostResolver,
  signal: AbortSignal,
): Promise<readonly string[]> {
  const host = bareHost(url);
  let addresses: readonly string[];
  if (isIP(host) !== 0) {
    addresses = [host];
  } else {
    let resolved: string[];
    try {
      resolved = await waitWithSignal(Promise.resolve().then(() => resolver(host)), signal);
    } catch (error) {
      if (signal.aborted) throw signal.reason;
      throw new PublicWebFetchError("public_fetch_dns_failed");
    }
    if (!Array.isArray(resolved)) throw new PublicWebFetchError("public_fetch_dns_failed");
    addresses = [...resolved];
  }
  if (addresses.length === 0) throw new PublicWebFetchError("public_fetch_dns_empty");
  for (const address of addresses) {
    if (typeof address !== "string" || isNonPublicAddress(address)) {
      throw new PublicWebFetchError("public_fetch_non_public_address");
    }
  }
  if (signal.aborted) throw signal.reason;
  return addresses;
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
    throw new PublicWebFetchError("public_fetch_remote_address");
  }
  const headerBytes = Math.max(responseHeaderBytes(response.headers), response.headerBytes ?? 0);
  if (headerBytes > limits.headerBytes) throw new PublicWebFetchError("public_fetch_response_limit");
  if (!Number.isInteger(response.status) || response.status < 200 || response.status > 599) {
    throw new PublicWebFetchError("public_fetch_response_invalid");
  }
}

async function cancelBody(body: ReadableStream<Uint8Array>, signal: AbortSignal): Promise<void> {
  try {
    await waitWithSignal(Promise.resolve().then(() => body.cancel()), signal);
  } catch {
    // Cleanup is best-effort and bounded by the same total/abort signal. The
    // per-hop dispatcher is always destroyed as the final socket backstop.
  }
}

async function closeDispatcher(dispatcher: PinnedDispatcher, signal: AbortSignal): Promise<void> {
  try {
    await waitWithSignal(Promise.resolve().then(() => dispatcher.close()), signal);
  } catch {
    // Closing is a cleanup backstop; preserve the typed request outcome.
  }
}

async function dispatchChecked(
  dispatcher: PinnedDispatcher,
  input: PinnedDispatchRequest,
): Promise<PinnedDispatchResponse> {
  if (input.signal.aborted) {
    await closeDispatcher(dispatcher, input.signal);
    throw input.signal.reason;
  }
  return new Promise<PinnedDispatchResponse>((resolve, reject) => {
    let settled = false;
    const finish = (error?: unknown, response?: PinnedDispatchResponse) => {
      if (settled) {
        if (response !== undefined) void response.body.cancel().catch(() => {});
        return;
      }
      settled = true;
      clearTimeout(timer);
      input.signal.removeEventListener("abort", onAbort);
      if (error !== undefined) reject(error);
      else resolve(response!);
    };
    const onAbort = () => {
      void dispatcher.close().catch(() => {});
      finish(input.signal.reason);
    };
    const timer = setTimeout(() => {
      void dispatcher.close().catch(() => {});
      finish(new PublicWebFetchError("public_fetch_headers_timeout"));
    }, input.headersMs);
    timer.unref?.();
    input.signal.addEventListener("abort", onAbort, { once: true });
    Promise.resolve().then(() => dispatcher.dispatch(input)).then(
      (response) => finish(undefined, response),
      (error: unknown) => finish(error),
    );
  });
}

async function requestHop(
  url: URL,
  method: "GET" | "HEAD",
  headers: Record<string, string>,
  addresses: readonly string[],
  limits: EgressLimits,
  signal: AbortSignal,
  dispatcherFactory: PinnedDispatcherFactory,
): Promise<{ dispatcher: PinnedDispatcher; response: PinnedDispatchResponse }> {
  const dispatcher = dispatcherFactory({
    origin: new URL(url.origin),
    addresses: [...addresses],
    servername: bareHost(url),
    lookup: pinnedLookup(addresses),
  });
  let response: PinnedDispatchResponse | undefined;
  try {
    response = await dispatchChecked(dispatcher, {
      url,
      method,
      headers,
      signal,
      connectMs: limits.connectMs,
      headersMs: limits.headersMs,
    });
    validateDispatchResponse(response, addresses, limits);
    return { dispatcher, response };
  } catch (error) {
    if (response !== undefined) await cancelBody(response.body, signal);
    await closeDispatcher(dispatcher, signal);
    throw error;
  }
}

function responseWithMetadata(response: Response, url: URL): Response {
  Object.defineProperties(response, {
    // This transport never follows a redirect. Native remains the sole owner
    // and must be able to redefine the terminal response's value to true.
    redirected: { value: false, writable: true, configurable: true },
    url: { value: url.toString() },
  });
  return response;
}

function sanitizedError(error: unknown): PublicWebFetchError {
  if (error instanceof PublicWebFetchError) return error;
  if (error instanceof ProviderEgressError) {
    if (error.code === "egress_connect_timeout") return new PublicWebFetchError("public_fetch_connect_timeout");
    if (error.code === "egress_headers_timeout") return new PublicWebFetchError("public_fetch_headers_timeout");
    if (error.code === "egress_remote_address") return new PublicWebFetchError("public_fetch_remote_address");
  }
  return new PublicWebFetchError("public_fetch_transport_failed");
}

function redirectResponseHeaders(source: Headers): Headers {
  const headers = new Headers();
  const location = source.get("location");
  if (location !== null) headers.set("location", location);
  return headers;
}

function safeResponseHeaders(source: Headers): Headers {
  const headers = new Headers(source);
  for (const name of [
    "connection",
    "content-encoding",
    "content-length",
    "keep-alive",
    "set-cookie",
    "trailer",
    "transfer-encoding",
    "upgrade",
  ]) headers.delete(name);
  return headers;
}

async function readWithIdleDeadline(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  idleMs: number,
  signal: AbortSignal,
): Promise<ReadableStreamReadResult<Uint8Array>> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => reject(new PublicWebFetchError("public_fetch_idle_timeout")), idleMs);
    timer.unref?.();
  });
  try {
    return await waitWithSignal(Promise.race([reader.read(), timeout]), signal);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

interface CutoffStream {
  stream: ReadableStream<Uint8Array>;
  /** Immediately requests upstream cancellation without waiting for a lock. */
  cancelUpstream: () => void;
}

/**
 * Backpressured, truncating byte cap. Reaching the cap closes the exposed
 * stream and cancels upstream immediately; it never waits for EOF and never
 * converts the legacy body-prefix behavior into a hard overflow error.
 */
function cutoffStream(
  source: ReadableStream<Uint8Array>,
  limit: number,
  idleMs: number,
  signal: AbortSignal,
  onSettled?: () => void,
): CutoffStream {
  const reader = source.getReader();
  let total = 0;
  let stopped = false;
  let settled = false;
  let onAbort: (() => void) | undefined;

  const settle = (): void => {
    if (settled) return;
    settled = true;
    if (onAbort !== undefined) signal.removeEventListener("abort", onAbort);
    onSettled?.();
  };
  const cancelSource = (): void => {
    try {
      void reader.cancel().catch(() => {});
    } catch {
      // The dispatcher close is the socket-level cleanup backstop.
    }
  };
  const cancelUpstream = (): void => {
    stopped = true;
    cancelSource();
    settle();
  };

  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      onAbort = () => {
        if (settled) return;
        stopped = true;
        controller.error(signal.reason instanceof PublicWebFetchError ? signal.reason : abortError());
        cancelSource();
        settle();
      };
      if (signal.aborted) onAbort();
      else signal.addEventListener("abort", onAbort, { once: true });
      if (limit === 0 && !settled) {
        stopped = true;
        controller.close();
        cancelSource();
        settle();
      }
    },
    async pull(controller) {
      if (stopped || settled) return;
      try {
        for (;;) {
          const next = await readWithIdleDeadline(reader, idleMs, signal);
          if (stopped || settled) return;
          if (next.done) {
            stopped = true;
            controller.close();
            settle();
            return;
          }
          const value = next.value;
          if (value === undefined || value.byteLength === 0) continue;
          const remaining = limit - total;
          if (value.byteLength < remaining) {
            total += value.byteLength;
            controller.enqueue(value);
            return;
          }

          const prefix = value.slice(0, Math.max(0, remaining));
          total = limit;
          stopped = true;
          if (prefix.byteLength > 0) controller.enqueue(prefix);
          controller.close();
          // Closing our stream does not guarantee that downstream cancellation
          // reaches an already-closed source, so request it explicitly now.
          cancelSource();
          settle();
          return;
        }
      } catch (error) {
        if (settled) return;
        stopped = true;
        controller.error(sanitizedError(error));
        cancelSource();
        settle();
      }
    },
    async cancel() {
      if (settled) return;
      stopped = true;
      try {
        await waitWithSignal(Promise.resolve().then(() => reader.cancel()), signal);
      } catch {
        // Cancellation is bounded by the operation's total/abort signal.
      } finally {
        settle();
      }
    },
  });
  return { stream, cancelUpstream };
}

type ContentEncoding = "identity" | "gzip" | "deflate" | "br";

function contentEncoding(headers: Headers): ContentEncoding {
  const value = (headers.get("content-encoding") ?? "identity").trim().toLowerCase();
  if (value === "" || value === "identity") return "identity";
  if (value === "gzip" || value === "x-gzip") return "gzip";
  if (value === "deflate" || value === "br") return value;
  throw new PublicWebFetchError("public_fetch_response_limit");
}

function decoderFor(encoding: Exclude<ContentEncoding, "identity">, cap: number) {
  const bufferSize = Math.max(64, Math.min(16_384, cap));
  const options = {
    chunkSize: bufferSize,
    readableHighWaterMark: bufferSize,
    writableHighWaterMark: bufferSize,
  };
  if (encoding === "gzip") return createGunzip(options);
  if (encoding === "deflate") return createInflate(options);
  return createBrotliDecompress(options);
}

/** Stream identity/decompressed bytes through independent truncating caps. */
function boundedDecodedBody(
  response: PinnedDispatchResponse,
  limits: EgressLimits,
  signal: AbortSignal,
  onSettled: () => void,
): ReadableStream<Uint8Array> {
  // Validate before taking the source reader lock so policy failures can still
  // use the ordinary response-body cancellation path.
  const encoding = contentEncoding(response.headers);
  const compressed = cutoffStream(response.body, limits.responseBytes, limits.idleMs, signal);
  let decoded = compressed.stream;
  if (encoding !== "identity") {
    const source = Readable.fromWeb(
      compressed.stream as unknown as import("node:stream/web").ReadableStream<Uint8Array>,
    );
    const decoder = decoderFor(encoding, limits.decompressedBytes);
    // Node's pipeline propagates cancel/backpressure and destroys both sides on
    // decoder failure. Its rejection is observed here and surfaces through the
    // web reader below, where cutoffStream maps it to a generic typed error.
    void pipeline(source, decoder).catch(() => {});
    decoded = Readable.toWeb(decoder) as ReadableStream<Uint8Array>;
  }
  return cutoffStream(decoded, limits.decompressedBytes, limits.idleMs, signal, () => {
    compressed.cancelUpstream();
    onSettled();
  }).stream;
}

/**
 * Credential-free public-web transport for ONE current network hop. Native
 * followGuardedRedirects is the sole redirect policy/count owner and calls
 * this function again for each Location. No global fetch or second system DNS
 * lookup is used: the existing checked dispatcher gets only the classified
 * addresses while URL Host/TLS identity and actual-remote checks are retained.
 */
export function createPublicWebFetch(options: CreatePublicWebFetchOptions = {}): GuardedFetch {
  const resolver = options.resolver ?? defaultHostResolver;
  const dispatcherFactory = options.dispatcherFactory ?? createNodePinnedDispatcher;
  const limits: EgressLimits = { ...PUBLIC_WEB_FETCH_LIMITS, ...options.limits };
  validateLimits(limits);

  return async (rawUrl: string, init: RequestInit = {}): Promise<Response> => {
    const controller = new AbortController();
    const externalSignal = init.signal ?? undefined;
    const forwardAbort = () => controller.abort(abortError());
    if (externalSignal?.aborted) forwardAbort();
    else externalSignal?.addEventListener("abort", forwardAbort, { once: true });
    const totalTimer = setTimeout(() => {
      controller.abort(new PublicWebFetchError("public_fetch_total_timeout"));
    }, limits.totalMs);
    totalTimer.unref?.();
    let streamingLifetime = false;
    const finishRequest = (): void => {
      clearTimeout(totalTimer);
      externalSignal?.removeEventListener("abort", forwardAbort);
    };

    try {
      const current = parseUrl(rawUrl);
      const parts = requestParts(init);
      if (controller.signal.aborted) throw controller.signal.reason;
      validateUrl(current);
      const addresses = await resolveCheckedAddresses(current, resolver, controller.signal);
      const hop = await requestHop(
        current,
        parts.method,
        parts.headers,
        addresses,
        limits,
        controller.signal,
        dispatcherFactory,
      );
      try {
        const location = hop.response.headers.get("location");
        const isRedirect = REDIRECT_STATUSES.has(hop.response.status) && location !== null;
        const noBody = isRedirect || hop.response.status < 200 || hop.response.status >= 300 ||
          parts.method === "HEAD" || NULL_BODY_STATUSES.has(hop.response.status);
        if (noBody) {
          await cancelBody(hop.response.body, controller.signal);
          await closeDispatcher(hop.dispatcher, controller.signal);
          return responseWithMetadata(new Response(null, {
            status: hop.response.status,
            statusText: "",
            headers: isRedirect
              ? redirectResponseHeaders(hop.response.headers)
              : hop.response.status < 200 || hop.response.status >= 300
                ? new Headers()
                : safeResponseHeaders(hop.response.headers),
          }), current);
        }

        const body = boundedDecodedBody(hop.response, limits, controller.signal, () => {
          finishRequest();
          void hop.dispatcher.close().catch(() => {});
        });
        const response = responseWithMetadata(new Response(body, {
          status: hop.response.status,
          statusText: "",
          headers: safeResponseHeaders(hop.response.headers),
        }), current);
        streamingLifetime = true;
        return response;
      } catch (error) {
        await cancelBody(hop.response.body, controller.signal);
        await closeDispatcher(hop.dispatcher, controller.signal);
        throw error;
      }
    } catch (error) {
      if (controller.signal.aborted && controller.signal.reason instanceof PublicWebFetchError) {
        throw controller.signal.reason;
      }
      throw sanitizedError(error);
    } finally {
      if (!streamingLifetime) finishRequest();
    }
  };
}
