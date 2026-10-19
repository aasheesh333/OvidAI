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
 * Capacity wave 2026-10-19: per-uid positive cache in front of the signed
 * mint call. Every message send awaited a full mint round trip (ban check,
 * deletion fence, tier, free-cap read, key get-or-mint, plan) even when the
 * key already existed; the mint is one Node process, and an 1800-send burst
 * queued behind it for ~10 s (p95 send→202 10.1 s in the baseline run).
 *
 * Only SUCCESSES are cached, for `ttlMs` per (uid, platform); concurrent sends
 * of one uid share one in-flight call; errors (402/429/timeouts) are never
 * cached, so a refused user is re-checked on every send. The cost is a
 * free-cap check that can lag up to `ttlMs` — LiteLLM's per-user budget clock
 * stays the hard backstop on the model call itself. `ttlMs` 0 disables.
 */
export const DEFAULT_MINT_ENSURE_CACHE_MS = 60_000;
const MINT_CACHE_MAX_ENTRIES = 50_000;

/** OVID_MINT_ENSURE_CACHE_MS (0 disables, max 10 min; default 60 s). */
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
  opts: { ttlMs: number; maxEntries?: number; now?: () => number },
): InternalMintProvisioner {
  if (opts.ttlMs <= 0) return inner;
  const now = opts.now ?? Date.now;
  const maxEntries = opts.maxEntries ?? MINT_CACHE_MAX_ENTRIES;
  type Result = Awaited<ReturnType<InternalMintProvisioner["ensureKeyForUid"]>>;
  const cache = new Map<string, { at: number; value: Result }>();
  const inFlight = new Map<string, Promise<Result>>();
  return {
    ensureKeyForUid(uid, callOpts) {
      const key = `${uid}\u0000${callOpts?.platform ?? ""}`;
      const hit = cache.get(key);
      if (hit !== undefined && now() - hit.at < opts.ttlMs) return Promise.resolve(hit.value);
      const pending = inFlight.get(key);
      if (pending !== undefined) return pending;
      const started = now();
      const p = inner
        .ensureKeyForUid(uid, callOpts)
        .then((value) => {
          cache.delete(key); // re-insert at the end: Map order = age order
          cache.set(key, { at: started, value });
          while (cache.size > maxEntries) {
            const oldest = cache.keys().next().value;
            if (oldest === undefined) break;
            cache.delete(oldest);
          }
          return value;
        })
        .finally(() => {
          inFlight.delete(key);
        });
      inFlight.set(key, p);
      return p;
    },
  };
}
