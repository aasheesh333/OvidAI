/**
 * P9 Task 9 — HMAC request signing for the INTERNAL server-to-server mint
 * API (single host, docker-internal network).
 *
 * CHOSEN DESIGN: a shared secret plus a per-request HMAC-SHA256 over
 *   "METHOD\nPATH\nUID\nTIMESTAMP"
 * with a ±INTERNAL_WINDOW_S (300 s) window. Headers are base64:
 *   X-Ovid-Timestamp: base64(decimal epoch seconds)
 *   X-Ovid-Signature: base64(HMAC-SHA256(secret, payload))
 * Verification is constant-time (timingSafeEqual). The secret is env-only
 * (OVID_INTERNAL_API_SECRET, >= 32 bytes) and never appears in a URL, body
 * or log line.
 *
 * mTLS-lite was rejected: both processes live on one compose network; certs
 * would add rotation infrastructure without adding a boundary. Documented in
 * cloud/docs/internal-mint-auth.md.
 *
 * Replay: a byte-identical request inside the window is accepted and the
 * route is idempotent by design (per-(uid, platform) key minting + the mint
 * lock). There is deliberately no nonce store: the only replayable effect is
 * "return the same key", and a nonce store would add a shared Redis
 * dependency to a route whose whole point is a small trusted surface.
 */

import { createHmac, timingSafeEqual } from "node:crypto";

export const INTERNAL_WINDOW_S = 300;

/** The single internal route (path only — queries are never signed). */
export const INTERNAL_MINT_PATH = "/internal/mint-key";

export const INTERNAL_TIMESTAMP_HEADER = "x-ovid-timestamp";
export const INTERNAL_SIGNATURE_HEADER = "x-ovid-signature";

/** The exact bytes covered by the HMAC. Timestamp = decimal epoch seconds. */
export function internalSignaturePayload(
  method: string,
  path: string,
  uid: string,
  timestamp: number,
): string {
  return `${method.toUpperCase()}\n${path}\n${uid}\n${String(timestamp)}`;
}

/**
 * base64 HMAC-SHA256 over the canonical payload. An empty secret is a
 * configuration error; it must never produce a "valid" signature.
 */
export function signInternalRequest(
  secret: string,
  method: string,
  path: string,
  uid: string,
  timestamp: number,
): string {
  if (secret === "") {
    throw new Error("internal signing secret must not be empty");
  }
  return createHmac("sha256", secret)
    .update(internalSignaturePayload(method, path, uid, timestamp), "utf8")
    .digest("base64");
}

/**
 * Decode a timestamp header. The wire format is base64(decimal), but a plain
 * decimal is accepted too: both encode the same signed value, and accepting
 * it removes a needless interoperability trap for operators hand-crafting a
 * request. Returns null on anything that is not a non-negative integer.
 */
function decodeTimestamp(header: string): number | null {
  const trimmed = header.trim();
  if (trimmed === "") return null;
  let text: string | null = null;
  if (/^\d+$/.test(trimmed)) {
    text = trimmed;
  } else {
    try {
      const decoded = Buffer.from(trimmed, "base64").toString("utf8");
      if (/^\d+$/.test(decoded)) text = decoded;
    } catch {
      text = null;
    }
  }
  if (text === null) return null;
  const value = Number(text);
  return Number.isSafeInteger(value) && value >= 0 ? value : null;
}

/**
 * Constant-time verification of a signed internal request.
 *
 * `now` is epoch seconds (the same unit as the signed timestamp). Returns
 * false — never throws — on any malformed input, an empty secret, an
 * out-of-window timestamp, or a signature mismatch.
 */
export function verifyInternalRequest(
  secret: string,
  method: string,
  path: string,
  uid: string,
  timestampHeader: string,
  signatureHeader: string,
  now: number,
): boolean {
  if (secret === "") return false;
  if (signatureHeader === "") return false;
  const timestamp = decodeTimestamp(timestampHeader);
  if (timestamp === null) return false;
  if (!Number.isFinite(now)) return false;
  if (Math.abs(now - timestamp) > INTERNAL_WINDOW_S) return false;

  const expected = Buffer.from(
    signInternalRequest(secret, method, path, uid, timestamp),
    "utf8",
  );
  const got = Buffer.from(signatureHeader.trim(), "utf8");
  // timingSafeEqual throws on length mismatch — the length itself is not a
  // secret (the signature is fixed-width base64).
  if (got.length !== expected.length) return false;
  return timingSafeEqual(got, expected);
}
