/**
 * W12 — Cloudflare Worker for signed-token CDN reads of private R2 objects.
 *
 * URL contract (minted by the gateway, see @ovid/storage/cdn.ts):
 *
 *   GET|HEAD https://cdn.ovidsi.com/o/<base64url(key)>?t=<hmac>&e=<expiry>
 *              [&d=attachment][&fn=<filename>][&ct=<type/subtype>][&c=<class>]
 *
 * The Worker:
 *   1. validates the HMAC over (version, key, expiry, disposition, filename,
 *      content-type, cache-class) — every input that changes the response;
 *   2. rejects expired tokens;
 *   3. decodes the opaque key and refuses traversal/control/absolute keys;
 *   4. streams the object from the R2 binding (never a bucket listing);
 *   5. supports GET, HEAD, single-range GETs and If-None-Match revalidation;
 *   6. caches ONLY successful object responses, keyed by object identity (not
 *      by the per-mint token), and validates the token BEFORE any cache hit;
 *   7. returns 403/404/416/405 with `Cache-Control: no-store`.
 *
 * Deploy: bind the bucket as `BUCKET`, set `OVID_CDN_SIGNING_SECRET` to the
 * same value the gateway uses, optionally `OVID_CDN_ALLOWED_ORIGINS`
 * (comma-separated) and `OVID_CDN_MAX_TTL_SECONDS` (default 3600).
 *
 * This file is deliberately dependency-free (Workers runtime + Web Crypto) and
 * is exercised in Node by cloud/packages/storage/src/cdnWorker.test.ts with a
 * fake R2 binding and cache.
 */

const TOKEN_VERSION = "v1";
const IMMUTABLE_CACHE_CONTROL = "public, max-age=31536000, immutable";
const SHORT_CACHE_CONTROL = "public, max-age=60, s-maxage=60, must-revalidate";
const DEFAULT_MAX_TTL_SECONDS = 3600;
const MAX_KEY_BYTES = 4096;

// ---------------------------------------------------------------------------
// Encoding helpers (base64url without padding, UTF-8)
// ---------------------------------------------------------------------------

const textEncoder = new TextEncoder();

export function base64UrlEncode(bytes) {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Strict decode: canonical alphabet + canonical re-encode. Null on garbage. */
export function base64UrlDecode(value) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  try {
    let b64 = value.replace(/-/g, "+").replace(/_/g, "/");
    while (b64.length % 4 !== 0) b64 += "=";
    const binary = atob(b64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
    if (base64UrlEncode(bytes) !== value) return null;
    return bytes;
  } catch {
    return null;
  }
}

export function decodeOpaqueKey(opaque) {
  const bytes = base64UrlDecode(opaque);
  if (bytes === null) return null;
  try {
    const key = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    return isSafeKey(key) ? key : null;
  } catch {
    return null;
  }
}

/**
 * A signed key can only ever be one of the gateway's own layouts, but the
 * Worker re-checks independently: no absolute path, no backslash, no "..",
 * no empty/dot segments, no control chars, bounded length.
 */
export function isSafeKey(key) {
  if (typeof key !== "string" || key === "" || key.length > MAX_KEY_BYTES) return false;
  if (key.startsWith("/") || key.startsWith("\\")) return false;
  if (key.includes("\\")) return false;
  if (/[\u0000-\u001f\u007f]/.test(key)) return false;
  for (const segment of key.split("/")) {
    if (segment === "" || segment === "." || segment === "..") return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Token verification (must match @ovid/storage/cdn.ts exactly)
// ---------------------------------------------------------------------------

export function canonicalString(claims) {
  return [
    TOKEN_VERSION,
    claims.key,
    String(claims.expiresAtEpochSeconds),
    claims.disposition,
    claims.filename ?? "",
    claims.contentType ?? "",
    claims.cacheClass,
  ].join("\n");
}

async function hmacBase64Url(secret, message) {
  const key = await crypto.subtle.importKey(
    "raw",
    textEncoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, textEncoder.encode(message));
  return base64UrlEncode(new Uint8Array(signature));
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export async function verifyToken(claims, token, secret, nowSeconds, maxTtlSeconds) {
  if (typeof secret !== "string" || secret === "") return false;
  if (typeof token !== "string" || !/^[A-Za-z0-9_-]+$/.test(token)) return false;
  if (!Number.isInteger(claims.expiresAtEpochSeconds) || claims.expiresAtEpochSeconds <= 0) {
    return false;
  }
  if (claims.expiresAtEpochSeconds <= nowSeconds) return false;
  if (claims.expiresAtEpochSeconds - nowSeconds > maxTtlSeconds) return false;
  const expected = await hmacBase64Url(secret, canonicalString(claims));
  return timingSafeEqual(expected, token);
}

// ---------------------------------------------------------------------------
// URL parsing
// ---------------------------------------------------------------------------

/**
 * Parses `/o/<opaque>?...` into claims. Returns null for any malformed or
 * unknown parameter — never a partially-trusted claim set.
 */
export function parseCdnUrl(rawUrl) {
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    return null;
  }
  const match = /^\/o\/([A-Za-z0-9_-]+)$/.exec(url.pathname);
  if (match === null) return null;

  const opaque = match[1];
  const key = decodeOpaqueKey(opaque);
  if (key === null) return null;

  const token = url.searchParams.get("t");
  const expiryRaw = url.searchParams.get("e");
  if (token === null || expiryRaw === null || !/^\d{1,12}$/.test(expiryRaw)) return null;
  const expiresAtEpochSeconds = Number(expiryRaw);
  if (!Number.isSafeInteger(expiresAtEpochSeconds) || expiresAtEpochSeconds <= 0) return null;

  const disposition = url.searchParams.get("d") ?? "inline";
  if (disposition !== "inline" && disposition !== "attachment") return null;

  const filename = url.searchParams.get("fn") ?? undefined;
  if (filename !== undefined && /[\r\n]/.test(filename)) return null;

  const contentType = url.searchParams.get("ct") ?? undefined;
  if (contentType !== undefined && !/^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/.test(contentType)) {
    return null;
  }

  const classRaw = url.searchParams.get("c");
  let cacheClass;
  if (classRaw === null) {
    cacheClass = cacheClassForKey(key);
  } else if (classRaw === "immutable" || classRaw === "short") {
    cacheClass = classRaw;
  } else {
    return null;
  }

  return {
    opaque,
    key,
    token,
    expiresAtEpochSeconds,
    disposition,
    filename,
    contentType,
    cacheClass,
  };
}

// ---------------------------------------------------------------------------
// Response policy
// ---------------------------------------------------------------------------

export function cacheClassForKey(key) {
  const artifact =
    /^users\/[^/]+\/artifacts\/[^/]+\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-/i;
  const contentAddressed = /(?:^|\/)sha256-[0-9a-f]{16,64}(?:[-/]|$)/i;
  return artifact.test(key) || contentAddressed.test(key) ? "immutable" : "short";
}

export function cacheControlFor(cacheClass) {
  return cacheClass === "immutable" ? IMMUTABLE_CACHE_CONTROL : SHORT_CACHE_CONTROL;
}

const CONTENT_TYPES = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  avif: "image/avif",
  svg: "image/svg+xml",
  pdf: "application/pdf",
  json: "application/json",
  html: "text/html",
  htm: "text/html",
  css: "text/css",
  js: "text/javascript",
  mjs: "text/javascript",
  ts: "text/plain",
  txt: "text/plain",
  md: "text/markdown",
  csv: "text/csv",
  zip: "application/zip",
  mp4: "video/mp4",
  mp3: "audio/mpeg",
  wav: "audio/wav",
  webm: "video/webm",
};

export function contentTypeForKey(key) {
  const ext = (key.split("/").pop() ?? "").toLowerCase().split(".").pop() ?? "";
  return CONTENT_TYPES[ext] ?? "application/octet-stream";
}

export function isActiveContent(contentType) {
  return (
    contentType === "text/html" ||
    contentType === "application/xhtml+xml" ||
    contentType === "image/svg+xml" ||
    contentType === "text/xml" ||
    contentType === "application/xml"
  );
}

export function sanitizeHeaderFilename(name) {
  if (typeof name !== "string") return undefined;
  const base = name.split(/[\\/]/).pop() ?? "";
  const out = base
    .replace(/[\r\n"]/g, "")
    .replace(/[^A-Za-z0-9._ -]+/g, "_")
    .trim()
    .slice(0, 120);
  return out === "" ? undefined : out;
}

export function contentDisposition(disposition, filename, key) {
  const fallback = sanitizeHeaderFilename(key.split("/").pop()) ?? "download";
  const name = sanitizeHeaderFilename(filename) ?? fallback;
  return `${disposition}; filename="${name}"; filename*=UTF-8''${encodeURIComponent(name)}`;
}

/** Single `bytes=` range only. Returns null for absent/malformed/unsatisfiable. */
export function parseRange(header, size) {
  if (typeof header !== "string") return null;
  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (match === null) return null;
  const startRaw = match[1];
  const endRaw = match[2];
  if (startRaw === "" && endRaw === "") return null;

  let start;
  let end;
  if (startRaw === "") {
    const suffix = Number(endRaw);
    if (!Number.isSafeInteger(suffix) || suffix <= 0) return null;
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number(startRaw);
    end = endRaw === "" ? size - 1 : Math.min(Number(endRaw), size - 1);
  }
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end)) return null;
  if (start < 0 || start > end || start >= size) return null;
  return { offset: start, length: end - start + 1 };
}

function etagMatches(ifNoneMatch, etag) {
  if (typeof ifNoneMatch !== "string" || ifNoneMatch.trim() === "") return false;
  const normalize = (value) => value.trim().replace(/^W\//, "");
  const target = normalize(etag);
  return ifNoneMatch
    .split(",")
    .map(normalize)
    .some((candidate) => candidate === "*" || candidate === target);
}

function errorResponse(status, code, extraHeaders) {
  const headers = new Headers({
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    pragma: "no-cache",
    "x-content-type-options": "nosniff",
    vary: "Accept-Encoding",
  });
  for (const [name, value] of Object.entries(extraHeaders ?? {})) headers.set(name, value);
  return new Response(JSON.stringify({ error: code }), { status, headers });
}

function applyCors(headers, request, env) {
  const origin = request.headers.get("origin");
  if (origin === null) return;
  const allowed = String(env.OVID_CDN_ALLOWED_ORIGINS ?? "")
    .split(",")
    .map((value) => value.trim())
    .filter((value) => value !== "");
  if (allowed.length === 0) return;
  if (allowed.includes("*")) {
    headers.set("access-control-allow-origin", "*");
  } else if (allowed.includes(origin)) {
    headers.set("access-control-allow-origin", origin);
  } else {
    return;
  }
  headers.set("access-control-expose-headers", "ETag, Content-Length, Content-Range, Accept-Ranges");
  headers.set("vary", "Origin, Accept-Encoding");
}

function objectHeaders(parsed, request, env, object) {
  const contentType =
    parsed.contentType ??
    object?.httpMetadata?.contentType ??
    contentTypeForKey(parsed.key);
  const headers = new Headers();
  headers.set("content-type", contentType);
  headers.set("cache-control", cacheControlFor(parsed.cacheClass));
  headers.set("x-content-type-options", "nosniff");
  headers.set("referrer-policy", "no-referrer");
  headers.set("accept-ranges", "bytes");
  headers.set("vary", "Accept-Encoding");
  headers.set(
    "content-disposition",
    contentDisposition(parsed.disposition, parsed.filename, parsed.key),
  );
  if (isActiveContent(contentType)) {
    // User HTML/SVG is served from an isolated origin and sandboxed: scripts
    // may run inside the sandbox, but no top-level navigation, forms to
    // other origins, or access to Ovid's app origin.
    headers.set(
      "content-security-policy",
      "sandbox allow-scripts allow-forms allow-popups allow-modals; " +
        "default-src 'none'; img-src 'self' data: blob:; media-src 'self' blob:; " +
        "style-src 'unsafe-inline' 'self'; script-src 'unsafe-inline' 'self'",
    );
  }
  applyCors(headers, request, env);
  return headers;
}

function cacheKeyFor(parsed) {
  // The token is intentionally NOT part of the cache key: each mint produces
  // a different signature, and keying on it would fragment the edge cache.
  // Authorization is checked BEFORE any cache lookup, so this key is never
  // reachable without a currently-valid token. Content type + class are
  // included because they are signed response-shaping claims (two legitimate
  // mints for one object must never cross-serve a different type).
  const ct = encodeURIComponent(parsed.contentType ?? "");
  return new Request(
    `https://cdn-cache.ovidsi.internal/v1/o/${parsed.opaque}?ct=${ct}&c=${parsed.cacheClass}`,
    { method: "GET" },
  );
}

function withEtag(headers, object) {
  const etag = object?.httpEtag ?? (object?.etag ? `"${object.etag}"` : undefined);
  if (typeof etag === "string" && etag !== "") headers.set("etag", etag);
  return etag;
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

/**
 * Pure-ish handler. `opts` injects the clock, a fake cache and a waitUntil
 * sink so the whole thing runs in Node tests.
 */
export async function handleRequest(request, env, opts = {}) {
  const method = (request.method ?? "GET").toUpperCase();
  const url = new URL(request.url);

  if (!url.pathname.startsWith("/o/")) return errorResponse(404, "not_found");
  if (method === "OPTIONS") {
    const headers = new Headers({
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      "access-control-allow-methods": "GET, HEAD, OPTIONS",
      "access-control-allow-headers": "Range, If-None-Match",
      "access-control-max-age": "86400",
    });
    applyCors(headers, request, env);
    return new Response(null, { status: 204, headers });
  }
  if (method !== "GET" && method !== "HEAD") {
    return errorResponse(405, "method_not_allowed", { allow: "GET, HEAD, OPTIONS" });
  }

  const parsed = parseCdnUrl(request.url);
  if (parsed === null) return errorResponse(403, "forbidden");

  const secret = env.OVID_CDN_SIGNING_SECRET;
  if (typeof secret !== "string" || secret === "") {
    return errorResponse(503, "cdn_not_configured");
  }
  const nowSeconds = opts.nowSeconds ?? Math.floor(Date.now() / 1000);
  const maxTtlRaw = Number(env.OVID_CDN_MAX_TTL_SECONDS ?? DEFAULT_MAX_TTL_SECONDS);
  const maxTtlSeconds =
    Number.isFinite(maxTtlRaw) && maxTtlRaw > 0 ? maxTtlRaw : DEFAULT_MAX_TTL_SECONDS;
  if (!(await verifyToken(parsed, parsed.token, secret, nowSeconds, maxTtlSeconds))) {
    return errorResponse(403, "forbidden");
  }

  const bucket = env.BUCKET;
  if (bucket === undefined || bucket === null) return errorResponse(503, "cdn_not_configured");

  const rangeHeader = request.headers.get("range");
  const useCache =
    method === "GET" &&
    rangeHeader === null &&
    env.OVID_CDN_CACHE !== "off" &&
    (opts.cache ?? (typeof caches !== "undefined" ? caches.default : undefined)) !== undefined;
  const cache = opts.cache ?? (typeof caches !== "undefined" ? caches.default : undefined);

  // ---- HEAD ---------------------------------------------------------------
  if (method === "HEAD") {
    let object;
    try {
      object = await bucket.head(parsed.key);
    } catch {
      return errorResponse(503, "artifact_storage_unavailable");
    }
    if (object === null || object === undefined) return errorResponse(404, "not_found");
    const headers = objectHeaders(parsed, request, env, object);
    withEtag(headers, object);
    if (object.size !== undefined) headers.set("content-length", String(object.size));
    return new Response(null, { status: 200, headers });
  }

  // ---- GET (cache hit) ----------------------------------------------------
  if (useCache) {
    try {
      const cached = await cache.match(cacheKeyFor(parsed));
      if (cached !== undefined && cached !== null) {
        const headers = objectHeaders(parsed, request, env, {
          httpMetadata: { contentType: cached.headers.get("content-type") ?? undefined },
        });
        const etag = cached.headers.get("etag");
        if (etag !== null) headers.set("etag", etag);
        const length = cached.headers.get("content-length");
        if (length !== null) headers.set("content-length", length);
        if (etagMatches(request.headers.get("if-none-match"), etag ?? "")) {
          return new Response(null, { status: 304, headers });
        }
        return new Response(cached.body, { status: 200, headers });
      }
    } catch {
      // A cache failure is never a request failure — fall through to R2.
    }
  }

  // ---- GET (R2) -----------------------------------------------------------
  let object;
  try {
    if (rangeHeader !== null) {
      // R2 needs the size to resolve suffix/end ranges; head first (cheap).
      const head = await bucket.head(parsed.key);
      if (head === null || head === undefined) return errorResponse(404, "not_found");
      const range = parseRange(rangeHeader, head.size ?? 0);
      if (range === null) {
        return errorResponse(416, "range_not_satisfiable", {
          "content-range": `bytes */${head.size ?? 0}`,
          "accept-ranges": "bytes",
        });
      }
      object = await bucket.get(parsed.key, { range });
      if (object === null || object === undefined) return errorResponse(404, "not_found");
      const headers = objectHeaders(parsed, request, env, object);
      withEtag(headers, object);
      const offset = object.range?.offset ?? range.offset;
      const length = object.range?.length ?? range.length;
      headers.set("content-range", `bytes ${offset}-${offset + length - 1}/${head.size}`);
      headers.set("content-length", String(length));
      return new Response(object.body, { status: 206, headers });
    }

    object = await bucket.get(parsed.key);
  } catch {
    return errorResponse(503, "artifact_storage_unavailable");
  }
  if (object === null || object === undefined) return errorResponse(404, "not_found");

  const headers = objectHeaders(parsed, request, env, object);
  const etag = withEtag(headers, object);
  if (object.size !== undefined) headers.set("content-length", String(object.size));
  if (etagMatches(request.headers.get("if-none-match"), etag ?? "")) {
    return new Response(null, { status: 304, headers });
  }

  if (useCache && cache !== undefined) {
    // R2 bodies are single-consumer streams. Tee BEFORE building the cached
    // response, and remember the client half: if the cache write fails after
    // the tee, the original body is already locked, so only this half can be
    // served.
    let toClient;
    try {
      const [toCache, clientHalf] = object.body.tee();
      toClient = clientHalf;
      // Cache the object representation only; per-request headers
      // (Content-Disposition/CORS) are rebuilt on every hit above.
      const cacheHeaders = new Headers();
      cacheHeaders.set("content-type", headers.get("content-type") ?? "application/octet-stream");
      if (etag !== undefined) cacheHeaders.set("etag", etag);
      if (object.size !== undefined) cacheHeaders.set("content-length", String(object.size));
      cacheHeaders.set("cache-control", cacheControlFor(parsed.cacheClass));
      const cacheable = new Response(toCache, { status: 200, headers: cacheHeaders });
      const put = cache.put(cacheKeyFor(parsed), cacheable);
      if (typeof opts.waitUntil === "function") opts.waitUntil(put);
      else await put;
    } catch {
      // A cache write failure is never a request failure: serve the client
      // half when the tee succeeded, otherwise the untouched original body.
    }
    if (toClient !== undefined) return new Response(toClient, { status: 200, headers });
  }

  return new Response(object.body, { status: 200, headers });
}

export default {
  async fetch(request, env, ctx) {
    return handleRequest(request, env, {
      waitUntil: ctx?.waitUntil?.bind(ctx),
    });
  },
};
