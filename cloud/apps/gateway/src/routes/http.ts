import type { FastifyReply } from "fastify";
import type { ZodError } from "zod";
import { createHash } from "node:crypto";
import type { ApiError } from "@ovid/shared";

// Shared route plumbing: the one error envelope (ApiError shape) and the
// page-limit clamping rule, so every route answers identically.

export function sendError(
  reply: FastifyReply,
  status: number,
  code: string,
  message: string,
): FastifyReply {
  const body: ApiError = { error: { code, message } };
  return reply.code(status).send(body);
}

export function badRequest(reply: FastifyReply, message: string): FastifyReply {
  return sendError(reply, 400, "bad_request", message);
}

/** Wrong owner and unknown resource are indistinguishable — never 403. */
export function notFound(reply: FastifyReply, message = "Session not found."): FastifyReply {
  return sendError(reply, 404, "not_found", message);
}

export function zodBadRequest(reply: FastifyReply, error: ZodError): FastifyReply {
  const details = error.issues
    .map((issue) => `${issue.path.join(".") || "(root)"}: ${issue.message}`)
    .join("; ");
  return badRequest(reply, `Invalid request body: ${details}`);
}

export const DEFAULT_PAGE_LIMIT = 30;
export const MAX_PAGE_LIMIT = 100;

/**
 * Page-limit parsing, CLAMPED (controller ruling — never a 400):
 * missing/empty/non-numeric/NaN/<1 → default 30; >100 → 100; fractional →
 * floor (limit=2.7 behaves as 2). Accepts the string[] form repeated
 * query params produce (?limit=2&limit=9) by using the first value.
 */
export function parsePageLimit(raw: string | string[] | undefined): number {
  const text = Array.isArray(raw) ? raw[0] : raw;
  if (text === undefined || text.trim() === "") return DEFAULT_PAGE_LIMIT;
  const n = Number(text);
  if (!Number.isFinite(n) || n < 1) return DEFAULT_PAGE_LIMIT;
  if (n > MAX_PAGE_LIMIT) return MAX_PAGE_LIMIT;
  return Math.max(1, Math.floor(n));
}

/** First value of a possibly-repeated query param, or null. */
export function queryValue(raw: string | string[] | undefined): string | null {
  const text = Array.isArray(raw) ? raw[0] : raw;
  return typeof text === "string" && text !== "" ? text : null;
}

/**
 * Strong ETag over a response body (W12). `JSON.stringify` is stable for the
 * route-constructed objects (fixed key insertion order), so the same snapshot
 * yields the same tag across requests.
 */
export function etagFor(body: unknown): string {
  const text = typeof body === "string" ? body : JSON.stringify(body);
  const digest = createHash("sha256").update(text, "utf8").digest("base64url");
  return `"${digest}"`;
}

/**
 * RFC 9110 If-None-Match comparison: comma-separated list, weak tags
 * (`W/"x"`) compare by opaque tag, `*` matches any current representation.
 */
export function matchesIfNoneMatch(header: string | undefined, etag: string): boolean {
  if (header === undefined || header.trim() === "") return false;
  const normalize = (value: string): string => value.trim().replace(/^W\//, "");
  const target = normalize(etag);
  return header.split(",").some((candidate) => {
    const value = normalize(candidate);
    return value === "*" || value === target;
  });
}

// Canonical UUID shape: 8-4-4-4-12 hex digits, any version, case-insensitive.
// Version/variant bits are deliberately NOT checked — the guard's only job is
// to keep client garbage away from id-typed db columns and keyset comparisons
// (a non-UUID bound to a native Postgres `uuid` column raises 22P02, which
// would surface as a 500 and pollute the 5xx alert signal with client typos).
// Any canonically-shaped UUID is safe to bind and simply matches no row, which
// the routes already answer with the contracted 404 not_found envelope.
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** True when `value` has canonical UUID shape (8-4-4-4-12 hex). */
export function isUuid(value: string): boolean {
  return UUID_RE.test(value);
}
