/**
 * W12 — signed-token CDN URLs for private R2 objects.
 *
 * The gateway never exposes the bucket or a raw object key to a browser. It
 * mints a capability of the shape:
 *
 *   https://cdn.ovidsi.com/o/<base64url(key)>?t=<hmac>&e=<expiry>&c=<class>
 *
 * The token is an HMAC-SHA256 over a canonical, newline-separated claim set
 * (key, expiry, disposition, filename, cache class). Every input that can
 * change what the Worker returns is signed, so a client cannot:
 *   - swap the opaque key for another object,
 *   - extend the expiry,
 *   - turn a download into inline HTML (or vice versa),
 *   - rename the downloaded file,
 *   - upgrade a short-TTL object to an immutable one.
 *
 * The Worker (cloud/deploy/cdn/worker.js) re-implements this exact canonical
 * string with Web Crypto; `cdn.test.ts` cross-checks a gateway-minted URL
 * against the Worker's validator so the two copies cannot drift silently.
 *
 * This module is pure: no network, no DB, no clock reads outside `now`.
 */

import { createHmac, timingSafeEqual } from "node:crypto";

import { assertSafeRelPath } from "./keys.js";

export type CdnCacheClass = "immutable" | "short";
export type CdnDisposition = "inline" | "attachment";

export const CDN_TOKEN_VERSION = "v1";
/** Default capability lifetime: 15 minutes (matches the Worker's edge TTL). */
export const DEFAULT_CDN_TTL_SECONDS = 900;
export const CDN_TTL_MIN_SECONDS = 60;
export const CDN_TTL_MAX_SECONDS = 3600;
/** HMAC secrets shorter than this are refused at boot. */
export const MIN_CDN_SECRET_BYTES = 32;

export interface CdnConfig {
  /** Absolute origin, no trailing slash, e.g. `https://cdn.ovidsi.com`. */
  baseUrl: string;
  /** Server-side HMAC secret (never sent to clients). */
  secret: string;
  /** Capability lifetime in seconds (60..3600). */
  ttlSeconds: number;
}

export interface CdnTokenClaims {
  key: string;
  expiresAtEpochSeconds: number;
  disposition: CdnDisposition;
  filename?: string;
  /** Bare `type/subtype` served by the Worker (signed, so not spoofable). */
  contentType?: string;
  cacheClass: CdnCacheClass;
}

export interface MintCdnUrlInput {
  key: string;
  /** Display name for Content-Disposition (sanitized before signing). */
  filename?: string;
  /** Object content type; attachments have no extension in their key. */
  contentType?: string;
  disposition?: CdnDisposition;
  /** Override the key-derived class (tests / future object kinds). */
  cacheClass?: CdnCacheClass;
  /** Injectable clock for deterministic tests. */
  now?: Date;
}

export interface MintedCdnUrl {
  url: string;
  expiresAt: string;
  expiresAtEpochSeconds: number;
  cacheClass: CdnCacheClass;
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

/**
 * Loads OVID_CDN_BASE_URL / OVID_CDN_SIGNING_SECRET / OVID_CDN_TTL_SECONDS.
 *
 * Returns null when OVID_CDN_BASE_URL is unset or empty: the CDN is an
 * OPTIONAL acceleration layer, and an unconfigured deployment must keep
 * booting (the mint routes answer a typed 503 cdn_not_configured and the
 * client falls back to the canonical presign).
 *
 * A partially configured CDN fails loudly: a base URL without a >=32-byte
 * secret would either mint forgeable URLs or silently disable the feature.
 */
export function loadCdnConfig(env: NodeJS.ProcessEnv): CdnConfig | null {
  const baseUrlRaw = (env.OVID_CDN_BASE_URL ?? "").trim();
  const secret = (env.OVID_CDN_SIGNING_SECRET ?? "").trim();
  if (baseUrlRaw === "") return null;

  let parsed: URL;
  try {
    parsed = new URL(baseUrlRaw);
  } catch {
    throw new Error("OVID_CDN_BASE_URL must be an absolute http(s) URL");
  }
  if (parsed.protocol !== "https:" && parsed.protocol !== "http:") {
    throw new Error("OVID_CDN_BASE_URL must be an absolute http(s) URL");
  }
  if (parsed.search !== "" || parsed.hash !== "") {
    throw new Error("OVID_CDN_BASE_URL must not contain a query string or fragment");
  }
  if (parsed.pathname !== "" && parsed.pathname !== "/") {
    throw new Error("OVID_CDN_BASE_URL must be an origin with no path (the Worker serves /o/*)");
  }
  if (Buffer.byteLength(secret, "utf8") < MIN_CDN_SECRET_BYTES) {
    throw new Error(
      `OVID_CDN_SIGNING_SECRET must be at least ${MIN_CDN_SECRET_BYTES} bytes when OVID_CDN_BASE_URL is set`,
    );
  }

  let ttlSeconds = DEFAULT_CDN_TTL_SECONDS;
  const ttlRaw = (env.OVID_CDN_TTL_SECONDS ?? "").trim();
  if (ttlRaw !== "") {
    const n = Number(ttlRaw);
    if (!Number.isInteger(n) || n < 1) {
      throw new Error(`OVID_CDN_TTL_SECONDS must be a positive integer, got: ${ttlRaw}`);
    }
    // CLAMP (never fail boot for an aggressive operator value), same policy as
    // OVID_PRESIGN_TTL_SECONDS.
    ttlSeconds = Math.min(CDN_TTL_MAX_SECONDS, Math.max(CDN_TTL_MIN_SECONDS, n));
  }

  return {
    baseUrl: baseUrlRaw.replace(/\/+$/, ""),
    secret,
    ttlSeconds,
  };
}

// ---------------------------------------------------------------------------
// Cache policy
// ---------------------------------------------------------------------------

/**
 * Generated artifacts are write-once: `registerArtifact` allocates a fresh
 * UUIDv7 per object and never overwrites a key. Their keys additionally carry
 * a content digest, so the edge may keep them forever. Everything else
 * (uploads, workspace archives, browser state) is a named/mutable object and
 * gets a 60-second edge TTL with ETag revalidation.
 */
const ARTIFACT_KEY_RE =
  /^users\/[^/]+\/artifacts\/[^/]+\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-/i;
const CONTENT_ADDRESSED_RE = /(?:^|\/)sha256-[0-9a-f]{16,64}(?:[-/]|$)/i;

export function cacheClassForKey(key: string): CdnCacheClass {
  return ARTIFACT_KEY_RE.test(key) || CONTENT_ADDRESSED_RE.test(key)
    ? "immutable"
    : "short";
}

/** Cache-Control the Worker emits for a class. Errors always use no-store. */
export function cacheControlFor(cacheClass: CdnCacheClass): string {
  return cacheClass === "immutable"
    ? "public, max-age=31536000, immutable"
    : "public, max-age=60, s-maxage=60, must-revalidate";
}

// ---------------------------------------------------------------------------
// Filename + key encoding
// ---------------------------------------------------------------------------

/**
 * Content-Disposition filename: one path segment, ASCII printable, no quotes,
 * CR/LF or path separators, <=120 chars. Returns undefined for an empty name.
 */
export function sanitizeCdnFilename(name: string | undefined): string | undefined {
  if (name === undefined) return undefined;
  const lastSegment = name.split(/[\\/]/).pop() ?? "";
  const out = lastSegment
    .replace(/[\r\n"]/g, "")
    .replace(/[^A-Za-z0-9._ -]+/g, "_")
    .trim()
    .slice(0, 120);
  return out === "" ? undefined : out;
}

/**
 * Bare media type (`text/plain`, `image/png`). Parameters are stripped: the
 * Worker adds its own charset/nosniff policy, and a signed `Content-Type`
 * containing CR/LF would be a header-injection primitive.
 */
export function sanitizeCdnContentType(value: string | undefined): string | undefined {
  if (value === undefined) return undefined;
  const bare = value.split(";")[0]!.trim().toLowerCase();
  return /^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/.test(bare) ? bare : undefined;
}

/**
 * The URL path segment: base64url of the raw key. Canonical (no padding) and
 * round-trip-checked, so two spellings can never address the same object.
 */
export function encodeOpaqueKey(key: string): string {
  return Buffer.from(assertSafeRelPath(key), "utf8").toString("base64url");
}

/** Strict inverse of [encodeOpaqueKey]; null for anything non-canonical/unsafe. */
export function decodeOpaqueKey(opaque: string): string | null {
  if (!/^[A-Za-z0-9_-]+$/.test(opaque)) return null;
  try {
    const raw = Buffer.from(opaque, "base64url");
    if (raw.toString("base64url") !== opaque) return null;
    const key = raw.toString("utf8");
    // A replacement char means the bytes were not valid UTF-8.
    if (key.includes("�")) return null;
    return assertSafeRelPath(key);
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Token
// ---------------------------------------------------------------------------

/** The exact string the Worker re-builds. Field order is part of the contract. */
export function cdnCanonicalString(claims: CdnTokenClaims): string {
  return [
    CDN_TOKEN_VERSION,
    claims.key,
    String(claims.expiresAtEpochSeconds),
    claims.disposition,
    claims.filename ?? "",
    claims.contentType ?? "",
    claims.cacheClass,
  ].join("\n");
}

function assertClaimsSignable(claims: CdnTokenClaims): void {
  // The canonical string is newline-separated: a newline in any field would
  // let an attacker shift field boundaries.
  if (claims.key.includes("\n") || claims.key.includes("\r")) {
    throw new Error("cdn token key must not contain newlines");
  }
  if ((claims.filename ?? "").includes("\n") || (claims.filename ?? "").includes("\r")) {
    throw new Error("cdn token filename must not contain newlines");
  }
  if ((claims.contentType ?? "").includes("\n") || (claims.contentType ?? "").includes("\r")) {
    throw new Error("cdn token content type must not contain newlines");
  }
  if (!Number.isInteger(claims.expiresAtEpochSeconds) || claims.expiresAtEpochSeconds <= 0) {
    throw new Error("cdn token expiry must be a positive integer epoch second");
  }
}

export function signCdnToken(claims: CdnTokenClaims, secret: string): string {
  if (secret === "") throw new Error("cdn token signing requires a non-empty secret");
  assertClaimsSignable(claims);
  return createHmac("sha256", secret)
    .update(cdnCanonicalString(claims), "utf8")
    .digest("base64url");
}

export interface VerifyCdnTokenOptions {
  /** Current epoch seconds; defaults to the wall clock. */
  nowSeconds?: number;
  /**
   * Reject tokens whose remaining lifetime exceeds this. Bounds the damage of
   * an operator accidentally minting a year-long capability.
   */
  maxTtlSeconds?: number;
}

/** Timing-safe verification. Never throws for attacker-controlled input. */
export function verifyCdnToken(
  token: string,
  claims: CdnTokenClaims,
  secret: string,
  opts: VerifyCdnTokenOptions = {},
): boolean {
  try {
    if (typeof token !== "string" || !/^[A-Za-z0-9_-]+$/.test(token)) return false;
    const expected = signCdnToken(claims, secret);
    const given = Buffer.from(token, "utf8");
    const want = Buffer.from(expected, "utf8");
    if (given.length !== want.length) return false;
    if (!timingSafeEqual(given, want)) return false;

    const now = opts.nowSeconds ?? Math.floor(Date.now() / 1000);
    if (claims.expiresAtEpochSeconds <= now) return false;
    if (
      opts.maxTtlSeconds !== undefined &&
      claims.expiresAtEpochSeconds - now > opts.maxTtlSeconds
    ) {
      return false;
    }
    return true;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Mint
// ---------------------------------------------------------------------------

/**
 * Builds the signed URL. The returned `expiresAt` is the CDN capability's
 * expiry (NOT the presign TTL): clients must re-mint after it.
 */
export function mintCdnUrl(config: CdnConfig, input: MintCdnUrlInput): MintedCdnUrl {
  const key = assertSafeRelPath(input.key);
  const nowSeconds = Math.floor((input.now ?? new Date()).getTime() / 1000);
  const expiresAtEpochSeconds = nowSeconds + config.ttlSeconds;
  const cacheClass = input.cacheClass ?? cacheClassForKey(key);
  const filename = sanitizeCdnFilename(input.filename);
  const contentType = sanitizeCdnContentType(input.contentType);
  const claims: CdnTokenClaims = {
    key,
    expiresAtEpochSeconds,
    disposition: input.disposition ?? "inline",
    ...(filename !== undefined ? { filename } : {}),
    ...(contentType !== undefined ? { contentType } : {}),
    cacheClass,
  };
  const token = signCdnToken(claims, config.secret);

  const params = new URLSearchParams();
  params.set("t", token);
  params.set("e", String(expiresAtEpochSeconds));
  params.set("c", cacheClass);
  if (claims.disposition !== "inline") params.set("d", claims.disposition);
  if (claims.filename !== undefined) params.set("fn", claims.filename);
  if (claims.contentType !== undefined) params.set("ct", claims.contentType);

  return {
    url: `${config.baseUrl}/o/${encodeOpaqueKey(key)}?${params.toString()}`,
    expiresAt: new Date(expiresAtEpochSeconds * 1000).toISOString(),
    expiresAtEpochSeconds,
    cacheClass,
  };
}
