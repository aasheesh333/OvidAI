/**
 * Images gateway shared types — port of the constants and error ladder in
 * server/images/service.py. Wire receipts stay snake_case (the public
 * contract); money values are exact decimal strings.
 */

/** Public image alias (service.py ALIAS). */
export const IMAGE_ALIAS = "ovid-image";

/** service.py SIZES — the only sizes the gateway advertises/accepts. */
export const SIZES = ["1024x1024", "1536x1024", "1024x1536", "2048x2048"] as const;
export type ImageSize = (typeof SIZES)[number];

/** service.py REPLAY_RETENTION — 24 h. */
export const REPLAY_RETENTION = 86_400;
/** service.py RECEIPT_RETENTION — 90 days. */
export const RECEIPT_RETENTION = 90 * 86_400;

/** service.py CAPACITY_RETRY_DEFAULT / CAPACITY_RETRY_MAX. */
export const CAPACITY_RETRY_DEFAULT = 30;
export const CAPACITY_RETRY_MAX = 120;

/**
 * Port of service.py capacity_retry_seconds(): a public delta-seconds value
 * only — digit strings (bounded by digit count, never parsed as a huge int),
 * integral numbers; everything else falls back to 30 s. The result is always
 * 1..120.
 */
export function capacityRetrySeconds(value?: unknown): number {
  let candidate = value;
  if (typeof candidate === "string" && /^[0-9]+$/.test(candidate)) {
    const digits = candidate.replace(/^0+/, "") || "0";
    candidate = digits.length > 3 ? CAPACITY_RETRY_MAX : Number.parseInt(digits, 10);
  }
  if (typeof candidate !== "number" || !Number.isInteger(candidate) || candidate < 0) {
    return CAPACITY_RETRY_DEFAULT;
  }
  return Math.max(1, Math.min(CAPACITY_RETRY_MAX, candidate));
}

/** Wire receipt (snake_case = the public contract; charged is exact decimal text). */
export interface Receipt {
  account_id: string;
  request_id: string;
  fingerprint: string;
  state: "pending" | "unknown" | "confirmed" | "failed";
  charged: string | null;
  model?: string;
}

export interface ImageErrorOptions {
  receipt?: Receipt | null;
  retryAfterSeconds?: number | null;
  detail?: Record<string, unknown> | null;
}

/**
 * Port of service.py ImageError. `retryAfterSeconds` is populated ONLY for
 * 503/image_capacity_unavailable, bounded by capacityRetrySeconds (30 s
 * default) — never copied from provider text.
 */
export class ImageError extends Error {
  readonly receipt: Receipt | null;
  readonly detail: Record<string, unknown> | null;
  readonly retryAfterSeconds: number | null;

  constructor(
    readonly status: number = 503,
    readonly code: string = "image_unavailable",
    opts: ImageErrorOptions = {},
  ) {
    super(code);
    this.name = "ImageError";
    this.receipt = opts.receipt ?? null;
    this.detail = opts.detail ?? null;
    this.retryAfterSeconds =
      status === 503 && code === "image_capacity_unavailable"
        ? capacityRetrySeconds(opts.retryAfterSeconds ?? undefined)
        : null;
  }
}

/** Port of service.py UpstreamError: the status alone proves nothing. */
export class UpstreamError extends Error {
  constructor(readonly status: number) {
    super("upstream request failed");
    this.name = "UpstreamError";
  }
}

/**
 * Adapter-VERIFIED nonacceptance only (service.py UpstreamNotAccepted): the
 * attempt provably never entered execution/billing, so fallback is safe.
 */
export class UpstreamNotAccepted extends UpstreamError {
  constructor(status: number) {
    super(status);
    this.name = "UpstreamNotAccepted";
  }
}
