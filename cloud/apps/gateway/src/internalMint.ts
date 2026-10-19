import {
  INTERNAL_MINT_PATH,
  MintInternalError,
  signInternalRequest,
  type InternalMintProvisioner,
} from "@ovid/shared";
import { DEFAULT_MINT_TIMEOUT_MS } from "./keys.js";

/**
 * P9 Task 9 — the gateway's server-to-server mint client.
 *
 * The gateway no longer forwards the caller's Firebase token to a public mint
 * endpoint. It signs `{uid}` with OVID_INTERNAL_API_SECRET (HMAC-SHA256 over
 * "METHOD\nPATH\nUID\nTIMESTAMP") and calls mint's ADMIN listener on the
 * docker-internal network. The uid is the gateway's OWN verified principal —
 * the auth hook has already established it, and no client credential crosses
 * this boundary.
 *
 * Non-2xx responses throw MintInternalError with the status, parsed body and
 * response headers (names lowercased) preserved so the messages route can
 * relay billing/rate-limit verdicts (402/429) re-enveloped for the thin
 * client — forwarding any `x-ovid-resets-at` the mint attached.
 */
export function createInternalMintProvisioner(
  baseUrl: string,
  secret: string,
  fetchImpl: typeof fetch = fetch,
  timeoutMs: number = DEFAULT_MINT_TIMEOUT_MS,
): InternalMintProvisioner {
  const base = baseUrl.replace(/\/+$/, "");
  return {
    async ensureKeyForUid(uid, opts) {
      const timestamp = Math.floor(Date.now() / 1000);
      const body: { uid: string; platform?: "android" | "web" } = { uid };
      if (opts?.platform !== undefined) body.platform = opts.platform;

      // Fresh per call: AbortSignal.timeout is single-use and starts ticking
      // at creation.
      const deadline =
        Number.isFinite(timeoutMs) && timeoutMs > 0
          ? AbortSignal.timeout(timeoutMs)
          : undefined;
      const res = await fetchImpl(`${base}${INTERNAL_MINT_PATH}`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "X-Ovid-Timestamp": Buffer.from(String(timestamp), "utf8").toString("base64"),
          "X-Ovid-Signature": signInternalRequest(
            secret,
            "POST",
            INTERNAL_MINT_PATH,
            uid,
            timestamp,
          ),
        },
        body: JSON.stringify(body),
        ...(deadline !== undefined ? { signal: deadline } : {}),
      });

      const text = await res.text();
      let parsed: unknown = text;
      if (text !== "") {
        try {
          parsed = JSON.parse(text);
        } catch {
          parsed = text; // non-JSON bodies are preserved as raw text
        }
      }
      if (!res.ok) {
        // Headers ride along (lowercased names — fetch already normalizes,
        // toLowerCase is belt-and-braces) so a relayed 402 can forward the
        // mint's `x-ovid-resets-at` to the client.
        const headers: Record<string, string> = {};
        res.headers.forEach((value, name) => {
          headers[name.toLowerCase()] = value;
        });
        throw new MintInternalError(res.status, parsed, headers);
      }

      const key = (parsed as { key?: unknown } | null)?.key;
      if (typeof key !== "string") {
        throw new Error("internal mint returned a malformed 2xx body (no string key)");
      }
      const tier = (parsed as { tier?: unknown }).tier;
      const replyBaseUrl = (parsed as { baseUrl?: unknown }).baseUrl;
      return {
        key,
        tier: typeof tier === "string" ? tier : "",
        baseUrl: typeof replyBaseUrl === "string" ? replyBaseUrl : "",
      };
    },
  };
}

/**
 * @deprecated Admission is never cacheable. Mint's ensure endpoint combines
 * setup with live ban, deletion-fence, quota and rate-limit decisions.
 * Keep the old config/parser API compatible, but it cannot suppress a call.
 * Any future setup-only cache must sit AFTER authoritative admission.
 */
export const DEFAULT_MINT_ENSURE_CACHE_MS = 0;
/** Legacy knob: validated for compatibility, never used to cache admission. */
export function mintEnsureCacheMsFromEnv(env: NodeJS.ProcessEnv): number {
  const raw = env.OVID_MINT_ENSURE_CACHE_MS;
  if (raw === undefined || raw.trim() === "") return DEFAULT_MINT_ENSURE_CACHE_MS;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 0 || n > 600_000) {
    throw new Error(`OVID_MINT_ENSURE_CACHE_MS must be an integer 0..600000, got: ${raw}`);
  }
  return n;
}

export function withEnsureKeyCache(
  inner: InternalMintProvisioner,
  _opts: { ttlMs: number; maxEntries?: number; now?: () => number },
): InternalMintProvisioner {
  // In particular, no single-flight: each send must make its own spending
  // admission decision, including concurrent sends from the same account.
  return inner;
}
