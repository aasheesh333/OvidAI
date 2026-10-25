import { isIP } from "node:net";
import { performance } from "node:perf_hooks";

import type { PreviewBinding } from "./studioPreviewTickets.js";

export const PREVIEW_HTTP_MAX_BYTES = 16 * 1024 * 1024;
export const PREVIEW_HTTP_IDLE_TIMEOUT_MS = 15_000;
export const PREVIEW_WS_MAX_FRAME_BYTES = 256 * 1024;
export const PREVIEW_WS_MAX_FRAMES_PER_WINDOW = 120;
export const PREVIEW_WS_RATE_WINDOW_MS = 60_000;
export const PREVIEW_WS_IDLE_TTL_MS = 15 * 60_000;
export const PREVIEW_WS_ABSOLUTE_TTL_MS = 60 * 60_000;

const PRIVATE_PORT_MIN = 20_000;
const PRIVATE_PORT_MAX = 29_999;
const MAX_PATH_LENGTH = 16 * 1024;
const MAX_FORWARDED_HEADER_LENGTH = 16 * 1024;
const HMR_PATHS = new Set(["/", "/__vite_hmr"]);
const HMR_PROTOCOLS = new Set(["vite-hmr", "vite-ping"]);

export type PreviewHeaderInput =
  | HeadersInit
  | Record<string, string | string[] | undefined>;

export type PreviewErrorCode =
  | "bad_headers"
  | "bad_path"
  | "method_not_allowed"
  | "not_found"
  | "hmr_denied"
  | "redirect_denied"
  | "response_too_large"
  | "upstream_timeout"
  | "registration_unavailable"
  | "upstream_unavailable";

const ERROR_MESSAGES: Readonly<Record<PreviewErrorCode, string>> = {
  bad_headers: "Preview request headers are invalid.",
  bad_path: "Preview path is invalid.",
  method_not_allowed: "Only GET and HEAD are allowed for preview content.",
  not_found: "Preview not found.",
  hmr_denied: "Only same-preview HMR upgrades are allowed.",
  redirect_denied: "Preview upstream redirects are not allowed.",
  response_too_large: "Preview response is too large.",
  upstream_timeout: "Preview upstream timed out.",
  registration_unavailable: "Preview registration is unavailable.",
  upstream_unavailable: "Preview upstream is unavailable.",
};

/** Fixed public failure; raw network/registration errors never cross this type. */
export class PreviewProxyError extends Error {
  readonly headers = {
    "cache-control": "private, no-store",
    pragma: "no-cache",
    "referrer-policy": "no-referrer",
  } as const;

  constructor(
    readonly code: PreviewErrorCode,
    readonly status: number,
    message?: string,
  ) {
    super(message ?? ERROR_MESSAGES[code]);
    this.name = "PreviewProxyError";
  }
}

export interface LivePreviewRegistration {
  id: string;
  userId: string;
  sessionId: string;
  generation: number;
  kind: "static" | "dev_server";
  status: "starting" | "running" | "stopping" | "stopped" | "failed" | "expired";
  bindHost: string;
  port: number;
  expiresAt: string | Date;
  /** Authoritative worker-store value, refreshed by the required touch. */
  lastAccessAt: string | null;
}

export interface PreviewUpstream {
  origin: string;
  generation: number;
}

export interface ReconstructPreviewUpstreamInput {
  configuredWorkerHost: string;
  registration: LivePreviewRegistration;
  binding: PreviewBinding;
  now?: Date;
}

/**
 * Reconstructs the private origin from trusted configuration + a live row.
 * Client host, port, URL, forwarding, and similarly-named row decorations are
 * deliberately absent from this calculation.
 */
export function reconstructPreviewUpstream(
  input: ReconstructPreviewUpstreamInput,
): PreviewUpstream | null {
  const { registration, binding } = input;
  if (
    registration.id !== binding.previewId ||
    registration.userId !== binding.userId ||
    registration.sessionId !== binding.sessionId ||
    registration.generation !== binding.generation ||
    !Number.isSafeInteger(registration.generation) ||
    registration.generation <= 0 ||
    registration.status !== "running" ||
    !Number.isInteger(registration.port) ||
    registration.port < PRIVATE_PORT_MIN ||
    registration.port > PRIVATE_PORT_MAX ||
    !isPrivatePreviewBindHost(registration.bindHost)
  ) {
    return null;
  }

  const expiresAt = registration.expiresAt instanceof Date
    ? registration.expiresAt.getTime()
    : Date.parse(registration.expiresAt);
  const now = (input.now ?? new Date()).getTime();
  if (!Number.isFinite(expiresAt) || !Number.isFinite(now) || expiresAt <= now) {
    return null;
  }

  const workerHost = normalizeConfiguredWorkerHost(input.configuredWorkerHost);
  if (workerHost === null) return null;
  return {
    origin: `http://${workerHost}:${registration.port}`,
    generation: registration.generation,
  };
}

function normalizeConfiguredWorkerHost(raw: string): string | null {
  if (raw.length === 0 || raw.length > 253 || /[\s/?#@\\]/.test(raw)) return null;
  const unbracketed = raw.startsWith("[") && raw.endsWith("]")
    ? raw.slice(1, -1)
    : raw;
  if (isIP(unbracketed) === 6) return `[${unbracketed.toLowerCase()}]`;
  if (isIP(unbracketed) === 4) return unbracketed;
  if (raw.includes(":")) return null;
  const hostname = raw.endsWith(".") ? raw.slice(0, -1) : raw;
  if (
    hostname.length === 0 ||
    hostname.length > 253 ||
    !hostname.split(".").every((label) =>
      /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label)
    )
  ) {
    return null;
  }
  return hostname.toLowerCase();
}

/** Only private/loopback bind addresses are valid Task 8 registrations. */
function isPrivatePreviewBindHost(host: string): boolean {
  if (isIP(host) === 4) return isPrivateIpv4(host);
  if (isIP(host) !== 6) return false;
  const normalized = host.toLowerCase();
  if (normalized === "::1") return true;
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(normalized);
  if (mapped !== null) return isPrivateIpv4(mapped[1]!);
  const first = Number.parseInt(normalized.split(":", 1)[0] || "0", 16);
  return (first & 0xfe00) === 0xfc00; // fc00::/7 unique local
}

function isPrivateIpv4(host: string): boolean {
  if (isIP(host) !== 4) return false;
  const parts = host.split(".").map(Number);
  const [a = -1, b = -1] = parts;
  return (
    a === 127 ||
    a === 10 ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168)
  );
}

/**
 * Decodes repeatedly before validating so double-encoded traversal cannot be
 * laundered into a different upstream path. Query data is retained verbatim;
 * it can never select an origin. Encoded slashes/backslashes are denied rather
 * than reinterpreted differently by gateway and dev server.
 */
export function normalizePreviewPath(rawPath: string): string | null {
  if (
    rawPath.length === 0 ||
    rawPath.length > MAX_PATH_LENGTH ||
    !rawPath.startsWith("/") ||
    rawPath.startsWith("//") ||
    rawPath.includes("#")
  ) {
    return null;
  }

  const queryAt = rawPath.indexOf("?");
  const pathPart = queryAt < 0 ? rawPath : rawPath.slice(0, queryAt);
  const query = queryAt < 0 ? "" : rawPath.slice(queryAt + 1);
  if (/[\u0000-\u001f\u007f#]/.test(query)) return null;

  let decoded = pathPart;
  for (let round = 0; round < 8; round += 1) {
    if (
      /[\u0000-\u001f\u007f\\]/.test(decoded) ||
      /%(?:2f|5c)/i.test(decoded)
    ) {
      return null;
    }
    let next: string;
    try {
      next = decodeURIComponent(decoded);
    } catch {
      return null;
    }
    if (next === decoded) {
      let canonical: string | null;
      try {
        canonical = canonicalDecodedPath(next);
      } catch {
        // encodeURIComponent rejects lone UTF-16 surrogates; malformed input
        // is simply not a registered upstream path.
        return null;
      }
      if (canonical === null) return null;
      return queryAt >= 0 ? `${canonical}?${query}` : canonical;
    }
    decoded = next;
  }
  return null;
}

function canonicalDecodedPath(decoded: string): string | null {
  if (!decoded.startsWith("/") || decoded.startsWith("//")) return null;
  const trailingSlash = decoded.endsWith("/");
  const segments = decoded.split("/");
  const canonicalSegments: string[] = [];
  for (const segment of segments) {
    if (segment === "." || segment === "..") return null;
    if (segment === "") continue;
    canonicalSegments.push(encodePathSegment(segment));
  }
  let canonical = `/${canonicalSegments.join("/")}`;
  if (trailingSlash && canonical !== "/") canonical += "/";
  return canonical;
}

function encodePathSegment(segment: string): string {
  // Keep RFC 3986 pchar punctuation readable while percent-encoding '/', '\\',
  // '?', '#', controls, and non-ASCII consistently. Existing '%' is encoded,
  // preventing a second decode at the upstream from reviving traversal.
  return encodeURIComponent(segment).replace(
    /%(?:3A|40|21|24|26|27|28|29|2A|2B|2C|3B|3D)/gi,
    (encoded) => String.fromCharCode(Number.parseInt(encoded.slice(1), 16)),
  );
}

const SAFE_UPSTREAM_HEADERS = new Set([
  "accept",
  "accept-language",
  "range",
  "if-none-match",
  "if-modified-since",
  "if-range",
  "if-unmodified-since",
]);

/** Explicit allowlist: authorization/cookie/host/forwarding are never copied. */
export function buildPreviewUpstreamHeaders(
  input: PreviewHeaderInput,
): Record<string, string> {
  return collectAllowedHeaders(input, SAFE_UPSTREAM_HEADERS);
}

const SAFE_WEBSOCKET_HEADERS = new Set([
  "sec-websocket-key",
  "sec-websocket-version",
  "sec-websocket-protocol",
  // No sec-websocket-extensions: compression is deliberately not negotiated,
  // so the 256 KiB relay guard and the wire frame describe the same bytes.
]);

export function buildPreviewWebSocketHeaders(
  input: PreviewHeaderInput,
): Record<string, string> {
  return collectAllowedHeaders(input, SAFE_WEBSOCKET_HEADERS);
}

function collectAllowedHeaders(
  input: PreviewHeaderInput,
  allowed: ReadonlySet<string>,
): Record<string, string> {
  const result: Record<string, string> = {};
  for (const [rawName, rawValue] of headerEntries(input)) {
    const name = rawName.toLowerCase();
    if (!allowed.has(name) || rawValue === undefined) continue;
    const value = Array.isArray(rawValue) ? rawValue.join(", ") : rawValue;
    if (
      value.length > MAX_FORWARDED_HEADER_LENGTH ||
      /[\r\n\u0000]/.test(value)
    ) {
      throw new PreviewProxyError("bad_headers", 400);
    }
    result[name] = value;
  }
  return result;
}

function headerEntries(
  input: PreviewHeaderInput,
): Array<[string, string | string[] | undefined]> {
  if (input instanceof Headers) {
    const entries: Array<[string, string]> = [];
    input.forEach((value, name) => entries.push([name, value]));
    return entries;
  }
  if (Array.isArray(input)) {
    return input.map((entry) => [String(entry[0]), String(entry[1])]);
  }
  return Object.entries(input);
}

const SAFE_RESPONSE_HEADERS = new Set([
  "accept-ranges",
  "content-range",
  "content-type",
  "etag",
  "last-modified",
  "vary",
]);

/** Upstream cache/cookie/redirect policy never survives this allowlist. */
export function createPreviewResponseHeaders(
  input: PreviewHeaderInput,
  contentSecurityPolicy: string,
): Record<string, string> {
  const result: Record<string, string> = {};
  for (const [rawName, rawValue] of headerEntries(input)) {
    const name = rawName.toLowerCase();
    if (!SAFE_RESPONSE_HEADERS.has(name) || rawValue === undefined) continue;
    const value = Array.isArray(rawValue) ? rawValue.join(", ") : rawValue;
    if (!/[\r\n\u0000]/.test(value)) result[name] = value;
  }
  return {
    ...result,
    "cache-control": "private, no-store",
    pragma: "no-cache",
    "content-security-policy": contentSecurityPolicy,
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
  };
}

export interface PreviewCspOptions {
  kind: "static" | "dev_server";
  webOrigin: string;
  previewOrigin: string;
}

/** Dedicated-origin policy; no Ovid API origin or inline/eval escape hatch. */
export function createPreviewCsp(options: PreviewCspOptions): string {
  const webOrigin = exactConfiguredOrigin(options.webOrigin);
  const previewOrigin = exactConfiguredOrigin(options.previewOrigin);
  const scripts = options.kind === "dev_server" ? "'self'" : "'none'";
  const connect = options.kind === "dev_server"
    ? `'self' ${webSocketOrigin(previewOrigin)}`
    : "'none'";
  return [
    "default-src 'none'",
    `script-src ${scripts}`,
    "style-src 'self'",
    "img-src 'self'",
    "font-src 'self'",
    `connect-src ${connect}`,
    "object-src 'none'",
    "base-uri 'none'",
    "form-action 'none'",
    `frame-ancestors ${webOrigin}`,
  ].join("; ");
}

function exactConfiguredOrigin(raw: string): string {
  const url = new URL(raw);
  if (
    (url.protocol !== "https:" && url.protocol !== "http:") ||
    url.username !== "" ||
    url.password !== "" ||
    url.pathname !== "/" ||
    url.search !== "" ||
    url.hash !== ""
  ) {
    throw new Error("Preview origins must be exact HTTP(S) origins.");
  }
  return url.origin;
}

function webSocketOrigin(httpsOrigin: string): string {
  const url = new URL(httpsOrigin);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  return url.origin;
}

export interface PreviewRegistrationTouch {
  id: string;
  generation: number;
  /** Gateway server time for deterministic touch/expiry coordination. */
  now: Date;
}

/**
 * Required authoritative registration access for BOTH content and HMR.
 *
 * `getLiveRegistration` is a read-only, full internal registration lookup (not
 * the public DTO). `touch` is the worker adapter's DEDICATED boolean DB-touch
 * result: true only for a real lastAccessAt write, and false for stale,
 * missing, denied, OR THROTTLED calls. It is never a registration and false is
 * never interpreted as denial by itself. After either boolean outcome the
 * resolver re-reads and revalidates the exact generation/status/expiry/kind.
 * The dedicated write preserves generation and all non-access fields; it must
 * not use the generic lifecycle update. `now` is gateway server time, never a
 * client-supplied timestamp (the worker adapter converts it to ISO for DB).
 */
export interface PreviewRegistrationAccess {
  getLiveRegistration: (
    previewId: string,
    generation: number,
  ) => Promise<LivePreviewRegistration | null>;
  touch: (
    input: PreviewRegistrationTouch,
  ) => Promise<boolean>;
}

export interface PreviewHttpProxyConfig extends PreviewRegistrationAccess {
  configuredWorkerHost: string;
  webOrigin: string;
  previewOrigin: string;
  now?: () => Date;
  fetch?: typeof fetch;
  /** Test-only tightening is accepted; values can never exceed the hard cap. */
  idleTimeoutMs?: number;
  maxBytes?: number;
}

export interface PreviewHttpProxyRequest {
  binding: PreviewBinding;
  method: string;
  path: string;
  headers: PreviewHeaderInput;
}

export interface PreviewHttpProxyResult {
  status: number;
  headers: Record<string, string>;
  body: Buffer;
}

/**
 * One bounded GET/HEAD exchange. Socket/HMR composition is intentionally not
 * part of this primitive. Registration is re-read, access-touched through the
 * dedicated generation-preserving port, and revalidated for every authorized call.
 */
export async function proxyPreviewHttpRequest(
  config: PreviewHttpProxyConfig,
  request: PreviewHttpProxyRequest,
): Promise<PreviewHttpProxyResult> {
  if (request.method !== "GET" && request.method !== "HEAD") {
    throw new PreviewProxyError("method_not_allowed", 405);
  }
  const path = normalizePreviewPath(request.path);
  if (path === null) throw new PreviewProxyError("bad_path", 400);
  const headers = buildPreviewUpstreamHeaders(request.headers);
  const resolved = await resolveLiveRegistration(config, request.binding);
  if (resolved === null) throw new PreviewProxyError("not_found", 404);

  const controller = new AbortController();
  const idleTimeoutMs = boundedLimit(
    config.idleTimeoutMs,
    PREVIEW_HTTP_IDLE_TIMEOUT_MS,
  );
  const maxBytes = boundedLimit(config.maxBytes, PREVIEW_HTTP_MAX_BYTES);
  let timedOut = false;
  const onTimeout = (): void => {
    timedOut = true;
    controller.abort();
  };
  const fetchImpl = config.fetch ?? globalThis.fetch;
  let response: Response | undefined;

  try {
    response = await withIdleDeadline(
      () => fetchImpl(`${resolved.upstream.origin}${path}`, {
        method: request.method,
        headers,
        redirect: "manual",
        signal: controller.signal,
      }),
      idleTimeoutMs,
      onTimeout,
    );
    if (isRedirect(response.status)) {
      throw new PreviewProxyError("redirect_denied", 502);
    }

    const declaredBytes = parseContentLength(response.headers.get("content-length"));
    if (declaredBytes !== null && declaredBytes > maxBytes) {
      throw new PreviewProxyError("response_too_large", 413);
    }
    const body = request.method === "HEAD" || response.status === 204 || response.status === 304
      ? await emptyBody(response)
      : await readBoundedBody(response, maxBytes, idleTimeoutMs, onTimeout);
    const responseHeaders = createPreviewResponseHeaders(
      response.headers,
      createPreviewCsp({
        kind: resolved.registration.kind,
        webOrigin: config.webOrigin,
        previewOrigin: config.previewOrigin,
      }),
    );
    if (request.method === "HEAD" && declaredBytes !== null) {
      responseHeaders["content-length"] = String(declaredBytes);
    } else if (response.status !== 204 && response.status !== 304) {
      responseHeaders["content-length"] = String(body.length);
    }
    return { status: response.status, headers: responseHeaders, body };
  } catch (error) {
    controller.abort();
    if (response !== undefined) void cancelBody(response);
    if (timedOut) throw new PreviewProxyError("upstream_timeout", 504);
    if (error instanceof PreviewProxyError) throw error;
    throw new PreviewProxyError("upstream_unavailable", 502);
  }
}

async function resolveLiveRegistration(
  config: Pick<
    PreviewHttpProxyConfig,
    "configuredWorkerHost" | "getLiveRegistration" | "touch" | "now"
  >,
  binding: PreviewBinding,
  options: { hmr?: boolean } = {},
): Promise<{ registration: LivePreviewRegistration; upstream: PreviewUpstream } | null> {
  if (
    !Number.isSafeInteger(binding.generation) ||
    binding.generation <= 0 ||
    binding.previewId.length === 0
  ) {
    return null;
  }
  let registration: LivePreviewRegistration | null;
  try {
    registration = await config.getLiveRegistration(
      binding.previewId,
      binding.generation,
    );
  } catch {
    throw new PreviewProxyError("registration_unavailable", 503);
  }
  if (registration === null) return null;
  const accessedAt = config.now?.() ?? new Date();
  const upstream = reconstructPreviewUpstream({
    configuredWorkerHost: config.configuredWorkerHost,
    registration,
    binding,
    now: accessedAt,
  });
  if (upstream === null) return null;
  if (options.hmr === true && registration.kind !== "dev_server") {
    // Static previews have no socket capability and are never access-touched
    // by a denied HMR attempt.
    throw new PreviewProxyError("hmr_denied", 403);
  }

  let touched: LivePreviewRegistration | null;
  try {
    const touchOutcome: unknown = await config.touch({
      id: binding.previewId,
      generation: binding.generation,
      now: accessedAt,
    });
    if (typeof touchOutcome !== "boolean") {
      // Composition returns the DB write verdict, never a record disguised by
      // a cast. A malformed adapter answer fails closed before proxying.
      throw new Error("Preview touch adapter returned a non-boolean result.");
    }
    // BOTH outcomes require an authoritative read. False may mean only the
    // one-second throttle suppressed a write; true means lastAccessAt changed.
    // The read maps the boolean protocol to Record|null without a cast.
    touched = await config.getLiveRegistration(
      binding.previewId,
      binding.generation,
    );
  } catch {
    throw new PreviewProxyError("registration_unavailable", 503);
  }
  if (touched === null) return null;
  if (options.hmr === true && touched.kind !== "dev_server") {
    throw new PreviewProxyError("hmr_denied", 403);
  }

  // Never proxy from the pre-touch snapshot, and never accept a legacy
  // incrementing update or other generation change after touch. Revalidate the
  // full live binding, status, expiry, bind, and generation on throttled paths
  // as well as real writes.
  const touchedUpstream = reconstructPreviewUpstream({
    configuredWorkerHost: config.configuredWorkerHost,
    registration: touched,
    binding,
    now: accessedAt,
  });
  return touchedUpstream === null
    ? null
    : { registration: touched, upstream: touchedUpstream };
}

function isRedirect(status: number): boolean {
  return status === 301 || status === 302 || status === 303 || status === 307 || status === 308;
}

function parseContentLength(raw: string | null): number | null {
  if (raw === null || !/^\d+$/.test(raw)) return null;
  const value = Number(raw);
  return Number.isSafeInteger(value) ? value : null;
}

async function emptyBody(response: Response): Promise<Buffer> {
  // Cleanup is best-effort and must never become an unbounded second request.
  void cancelBody(response);
  return Buffer.alloc(0);
}

async function readBoundedBody(
  response: Response,
  maxBytes: number,
  idleTimeoutMs: number,
  onTimeout: () => void,
): Promise<Buffer> {
  if (response.body === null) return Buffer.alloc(0);
  const reader = response.body.getReader();
  const chunks: Buffer[] = [];
  let total = 0;
  for (;;) {
    const next = await withIdleDeadline(
      () => reader.read(),
      idleTimeoutMs,
      onTimeout,
    );
    if (next.done) break;
    if (!(next.value instanceof Uint8Array)) {
      throw new PreviewProxyError("upstream_unavailable", 502);
    }
    total += next.value.byteLength;
    if (total > maxBytes) throw new PreviewProxyError("response_too_large", 413);
    chunks.push(Buffer.from(next.value.buffer, next.value.byteOffset, next.value.byteLength));
  }
  return Buffer.concat(chunks, total);
}

async function cancelBody(response: Response): Promise<void> {
  try {
    await response.body?.cancel();
  } catch {
    // A locked/errored stream is already being aborted by the controller.
  }
}

class IdleDeadline extends Error {}

async function withIdleDeadline<T>(
  operation: () => Promise<T>,
  timeoutMs: number,
  onTimeout: () => void,
): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => {
      onTimeout();
      reject(new IdleDeadline());
    }, timeoutMs);
  });
  try {
    return await Promise.race([Promise.resolve().then(operation), deadline]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

function boundedLimit(configured: number | undefined, hardMaximum: number): number {
  if (configured === undefined || !Number.isFinite(configured)) return hardMaximum;
  return Math.min(hardMaximum, Math.max(1, Math.floor(configured)));
}

export interface PreviewHmrConfig extends PreviewRegistrationAccess {
  configuredWorkerHost: string;
  now?: () => Date;
}

export interface PreviewHmrUpgradeRequest extends PreviewHttpProxyRequest {}

export interface PreviewHmrUpgradeGrant {
  upstream: PreviewUpstream;
  path: string;
  /** Composition adds fixed Connection/Upgrade/Host fields itself. */
  headers: Record<string, string>;
}

/** Authorizes only the Vite HMR path/protocol for this exact live preview. */
export async function authorizePreviewHmrUpgrade(
  config: PreviewHmrConfig,
  request: PreviewHmrUpgradeRequest,
): Promise<PreviewHmrUpgradeGrant> {
  if (request.method !== "GET") {
    throw new PreviewProxyError("method_not_allowed", 405);
  }
  const path = normalizePreviewPath(request.path);
  if (path === null) throw new PreviewProxyError("bad_path", 400);
  if (!HMR_PATHS.has(path.split("?", 1)[0])) {
    throw new PreviewProxyError("hmr_denied", 403);
  }
  const headers = buildPreviewWebSocketHeaders(request.headers);
  const connection = firstHeader(request.headers, "connection")?.toLowerCase() ?? "";
  const upgrade = firstHeader(request.headers, "upgrade")?.toLowerCase() ?? "";
  const protocols = (headers["sec-websocket-protocol"] ?? "")
    .split(",")
    .map((value) => value.trim());
  if (
    !connection.split(",").some((token) => token.trim() === "upgrade") ||
    upgrade !== "websocket" ||
    headers["sec-websocket-key"] === undefined ||
    headers["sec-websocket-key"] === "" ||
    headers["sec-websocket-version"] !== "13" ||
    protocols.length !== 1 ||
    !HMR_PROTOCOLS.has(protocols[0]!)
  ) {
    throw new PreviewProxyError("hmr_denied", 403);
  }

  const resolved = await resolveLiveRegistration(config, request.binding, { hmr: true });
  if (resolved === null) throw new PreviewProxyError("not_found", 404);
  return { upstream: resolved.upstream, path, headers };
}

function firstHeader(input: PreviewHeaderInput, name: string): string | null {
  for (const [candidate, raw] of headerEntries(input)) {
    if (candidate.toLowerCase() !== name || raw === undefined) continue;
    return Array.isArray(raw) ? raw.join(", ") : raw;
  }
  return null;
}

export type PreviewWebSocketDenial =
  | "invalid_frame"
  | "frame_too_large"
  | "rate_limited"
  | "idle_expired"
  | "absolute_expired";

export type PreviewWebSocketFrameDecision =
  | { allowed: true }
  | {
      allowed: false;
      reason: PreviewWebSocketDenial;
      retryAfterSeconds?: number;
    };

export interface PreviewWebSocketGuardOptions {
  now?: () => number;
  maxFramesPerWindow?: number;
  windowMs?: number;
  idleTtlMs?: number;
  absoluteTtlMs?: number;
}

export interface PreviewWebSocketGuard {
  /** Call for every inbound/outbound frame before relaying it. */
  acceptFrame(byteLength: number): PreviewWebSocketFrameDecision;
}

/** Standalone frame/rate/TTL guard; it opens and composes no sockets. */
export function createPreviewWebSocketGuard(
  options: PreviewWebSocketGuardOptions = {},
): PreviewWebSocketGuard {
  const now = options.now ?? (() => performance.now());
  const maxFrames = boundedLimit(
    options.maxFramesPerWindow,
    PREVIEW_WS_MAX_FRAMES_PER_WINDOW,
  );
  const windowMs = boundedLimit(options.windowMs, PREVIEW_WS_RATE_WINDOW_MS);
  const idleTtlMs = boundedLimit(options.idleTtlMs, PREVIEW_WS_IDLE_TTL_MS);
  const absoluteTtlMs = boundedLimit(
    options.absoluteTtlMs,
    PREVIEW_WS_ABSOLUTE_TTL_MS,
  );
  const openedAt = now();
  let lastAcceptedAt = openedAt;
  let windowStartedAt = openedAt;
  let framesInWindow = 0;
  let terminalExpiry: "idle_expired" | "absolute_expired" | null =
    Number.isFinite(openedAt) ? null : "absolute_expired";

  return {
    acceptFrame(byteLength) {
      // Expiry is a terminal lifecycle fact, not a comparison that a later
      // wall-clock adjustment can undo. The production clock is monotonic;
      // injected/non-monotonic readings also fail closed and latch.
      if (terminalExpiry !== null) {
        return { allowed: false, reason: terminalExpiry };
      }
      const timestamp = now();
      if (!Number.isFinite(timestamp)) {
        terminalExpiry = "absolute_expired";
        return { allowed: false, reason: terminalExpiry };
      }
      if (
        timestamp < openedAt ||
        timestamp < lastAcceptedAt ||
        timestamp < windowStartedAt
      ) {
        terminalExpiry = "absolute_expired";
        return { allowed: false, reason: terminalExpiry };
      }
      if (timestamp - openedAt >= absoluteTtlMs) {
        terminalExpiry = "absolute_expired";
        return { allowed: false, reason: terminalExpiry };
      }
      if (timestamp - lastAcceptedAt >= idleTtlMs) {
        terminalExpiry = "idle_expired";
        return { allowed: false, reason: terminalExpiry };
      }
      if (!Number.isSafeInteger(byteLength) || byteLength < 0) {
        return { allowed: false, reason: "invalid_frame" };
      }
      if (byteLength > PREVIEW_WS_MAX_FRAME_BYTES) {
        return { allowed: false, reason: "frame_too_large" };
      }
      if (timestamp < windowStartedAt || timestamp - windowStartedAt >= windowMs) {
        windowStartedAt = timestamp;
        framesInWindow = 0;
      }
      if (framesInWindow >= maxFrames) {
        return {
          allowed: false,
          reason: "rate_limited",
          retryAfterSeconds: Math.max(
            1,
            Math.ceil((windowStartedAt + windowMs - timestamp) / 1_000),
          ),
        };
      }

      framesInWindow += 1;
      lastAcceptedAt = timestamp;
      return { allowed: true };
    },
  };
}
