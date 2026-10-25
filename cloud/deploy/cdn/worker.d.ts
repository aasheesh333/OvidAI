/**
 * Type surface for the dependency-free Cloudflare Worker at worker.js.
 * Kept next to it so TypeScript tests can import the JS module without
 * turning on allowJs for the whole workspace.
 */

export interface CdnClaims {
  key: string;
  expiresAtEpochSeconds: number;
  disposition: "inline" | "attachment";
  filename?: string;
  contentType?: string;
  cacheClass: "immutable" | "short";
  /** v2 grant claims; absent only for legacy v1 signature-compatibility tests. */
  grantId?: string;
  versionHash?: string;
}

export interface CdnParsedUrl extends CdnClaims {
  opaque: string;
  token: string;
}

export interface CdnR2Object {
  body: ReadableStream<Uint8Array>;
  size?: number;
  etag?: string;
  httpEtag?: string;
  httpMetadata?: { contentType?: string };
  range?: { offset: number; length: number };
}

export interface CdnR2Bucket {
  get(
    key: string,
    options?: { range?: { offset: number; length: number } },
  ): Promise<CdnR2Object | null>;
  head(key: string): Promise<CdnR2Object | null>;
}

export interface CdnCache {
  match(request: Request): Promise<Response | undefined>;
  put(request: Request, response: Response): Promise<void>;
}

export interface CdnEnv {
  BUCKET: CdnR2Bucket;
  OVID_CDN_SIGNING_SECRET: string;
  OVID_CDN_ALLOWED_ORIGINS?: string;
  OVID_CDN_MAX_TTL_SECONDS?: string;
  OVID_CDN_CACHE?: string;
  OVID_CDN_GRANT_CHECK_URL?: string;
  OVID_CDN_GRANT_INTERNAL_SECRET?: string;
  OVID_INTERNAL_API_SECRET?: string;
}

export interface CdnHandlerOptions {
  nowSeconds?: number;
  cache?: CdnCache;
  waitUntil?: (promise: Promise<unknown>) => void;
  /** Test/service transport seam; production uses the platform global fetch. */
  fetchImpl?: typeof fetch;
}

export function base64UrlEncode(bytes: Uint8Array): string;
export function base64UrlDecode(value: string): Uint8Array | null;
export function decodeOpaqueKey(opaque: string): string | null;
export function isSafeKey(key: string): boolean;
export function canonicalString(claims: CdnClaims): string;
export function verifyToken(
  claims: CdnClaims,
  token: string,
  secret: string,
  nowSeconds: number,
  maxTtlSeconds: number,
): Promise<boolean>;
export function parseCdnUrl(rawUrl: string): CdnParsedUrl | null;
export function cacheClassForKey(key: string): "immutable" | "short";
export function cacheControlFor(cacheClass: "immutable" | "short"): string;
export function contentTypeForKey(key: string): string;
export function isActiveContent(contentType: string): boolean;
export function sanitizeHeaderFilename(name: string): string | undefined;
export function contentDisposition(
  disposition: "inline" | "attachment",
  filename: string | undefined,
  key: string,
): string;
export function parseRange(
  header: string | null,
  size: number,
): { offset: number; length: number } | null;
export function handleRequest(
  request: Request,
  env: CdnEnv,
  opts?: CdnHandlerOptions,
): Promise<Response>;

declare const worker: { fetch(request: Request, env: CdnEnv, ctx?: unknown): Promise<Response> };
export default worker;
