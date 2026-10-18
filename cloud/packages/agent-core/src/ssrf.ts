// SSRF guard — port of lib/core/ssrf_guard.dart (M3).
//
// A literal-only check ("is the host string 10.x?") is walked around by any
// name that RESOLVES to an internal address — a public DNS record pointing at
// `127.0.0.1`, `169.254.169.254` or an IPv4-mapped IPv6 address. This guard
// resolves the name and refuses when ANY returned address is non-public, so a
// mixed record set cannot slip one internal target in.
//
// Cloud deviation from the Dart original (per the task brief): resolution
// failure refuses here (fail-closed) — Dart's `nonPublicHostReason` returned
// "no reason" when the resolver threw. The egress path must never treat an
// unresolvable name as safe.
//
// Remaining limit (documented, not solved here): the transport resolves again
// when it connects, so a rebinding resolver with a near-zero TTL can still
// swap answers between the check and the connect.

import { lookup } from "node:dns/promises";

import {
  bareHost,
  isMetadataOrLinkLocalAddress,
  isNonPublicAddress,
  parseAddressBytes,
} from "@ovid/shared";

import type { EgressFetch } from "./ports.js";

// The address classifier lives in @ovid/shared so every egress guard shares
// ONE blocklist. Re-exported here because consumers import it from
// "./ssrf.js" (and the package barrel star-exports this module).
export { isMetadataOrLinkLocalAddress, isNonPublicAddress };

export class SsrfBlockedError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SsrfBlockedError";
  }
}

/** Resolves a host name to every address it maps to (A + AAAA records). */
export type SsrfResolver = (host: string) => Promise<string[]>;

export interface SsrfGuard {
  /** Throws SsrfBlockedError unless the URL is safe to fetch. */
  assertSafeUrl(rawUrl: string): Promise<URL>;
  /** True when every address the host resolves to is public. */
  checkHost(host: string): Promise<boolean>;
}

const DEFAULT_LOOKUP_TIMEOUT_MS = 4000;
const DEFAULT_MAX_REDIRECTS = 5;
const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);
const ALLOWED_EGRESS_PORTS = new Set([80, 443]);

// ---------------------------------------------------------------------------
// Resolution and the guard itself.
// ---------------------------------------------------------------------------

async function defaultResolve(host: string): Promise<string[]> {
  const records = await lookup(host, { all: true, verbatim: true });
  return records.map((r) => r.address);
}

function withTimeout<T>(p: Promise<T>, ms: number, onTimeout: () => Error): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(onTimeout()), ms);
    p.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (err) => {
        clearTimeout(timer);
        reject(err);
      },
    );
  });
}

/**
 * Why `host` must not be fetched, or null when every address it resolves to
 * is public. Refuses `localhost`/`*.localhost` by name. Literal hosts are
 * classified directly; named hosts go through the resolver (timeout-wrapped)
 * and a resolver failure or empty answer refuses — fail-closed.
 */
async function nonPublicHostReason(
  host: string,
  resolve: SsrfResolver,
  lookupTimeoutMs: number,
): Promise<string | null> {
  const bare = bareHost(host);
  if (bare === "") return `host "${host}" is empty`;
  if (bare === "localhost" || bare.endsWith(".localhost")) {
    return `host "${host}" is a loopback name`;
  }
  if (parseAddressBytes(bare) !== null) {
    return isNonPublicAddress(bare)
      ? `host "${host}" is the non-public address ${bare}`
      : null;
  }
  let addresses: string[];
  try {
    addresses = await withTimeout(
      resolve(bare),
      lookupTimeoutMs,
      () => new Error(`DNS lookup for "${bare}" timed out after ${lookupTimeoutMs}ms`),
    );
  } catch {
    return `host "${host}" could not be resolved — refusing (fail-closed)`;
  }
  if (addresses.length === 0) {
    return `host "${host}" resolved to no addresses — refusing (fail-closed)`;
  }
  for (const a of addresses) {
    if (isNonPublicAddress(a)) {
      return `host "${host}" resolves to a non-public address (${a})`;
    }
  }
  return null;
}

export function createSsrfGuard(o?: {
  resolver?: SsrfResolver;
  lookupTimeoutMs?: number;
}): SsrfGuard {
  const resolve = o?.resolver ?? defaultResolve;
  const lookupTimeoutMs = o?.lookupTimeoutMs ?? DEFAULT_LOOKUP_TIMEOUT_MS;
  const reasonFor = (host: string) => nonPublicHostReason(host, resolve, lookupTimeoutMs);
  return {
    async checkHost(host: string): Promise<boolean> {
      return (await reasonFor(host)) === null;
    },
    async assertSafeUrl(rawUrl: string): Promise<URL> {
      let url: URL;
      try {
        url = new URL(rawUrl);
      } catch {
        throw new SsrfBlockedError(`"${rawUrl}" is not a valid URL`);
      }
      if (url.protocol !== "http:" && url.protocol !== "https:") {
        throw new SsrfBlockedError(
          `scheme ${url.protocol} is not allowed for egress (http/https only): ${rawUrl}`,
        );
      }
      const port =
        url.port === "" ? (url.protocol === "https:" ? 443 : 80) : Number(url.port);
      if (!ALLOWED_EGRESS_PORTS.has(port)) {
        throw new SsrfBlockedError(
          `port ${port} is not allowed for egress (80/443 only): ${rawUrl}`,
        );
      }
      const reason = await reasonFor(url.hostname);
      if (reason !== null) throw new SsrfBlockedError(reason);
      return url;
    },
  };
}

/**
 * fetch with manual redirect handling: assertSafeUrl runs on EVERY hop, so a
 * redirect can never land on a non-public target even when the first URL was
 * clean. After maxRedirects (default 5) followed redirects, the next redirect
 * response throws SsrfBlockedError. The init (including any AbortSignal) is
 * passed through to the transport on every hop.
 *
 * onHop (P3 Task 12 carry, T10 review) restores Dart's per-hop host-GRANT
 * re-check (agent_service.dart fetch_url's redirectGuard): the guarded egress
 * re-runs the SSRF check on every hop but NOT the caller's grant, so a
 * granted site could bounce the request to any other public host the user
 * never approved. The hook runs for each REDIRECT hop (after that hop's
 * SSRF check passes — a blocked host never reaches it); the INITIAL url is
 * deliberately NOT passed, because the caller's own gate covered it (the
 * same split as Dart). A throwing hook refuses the hop — fetch_url wires it
 * to the grant store.
 */
export type EgressHopHook = (url: URL) => Promise<void>;

export function createGuardedEgressFetch(
  guard: SsrfGuard,
  fetchImpl: typeof fetch = fetch,
  maxRedirects: number = DEFAULT_MAX_REDIRECTS,
  onHop?: EgressHopHook,
): EgressFetch {
  return async (url: string, init?: RequestInit): Promise<Response> => {
    let current = await guard.assertSafeUrl(url);
    for (let redirects = 0; ; redirects++) {
      const res = await fetchImpl(current.toString(), { ...init, redirect: "manual" });
      if (!REDIRECT_STATUSES.has(res.status)) return res;
      const location = res.headers.get("location");
      if (location === null) return res; // malformed redirect: hand back the response
      if (redirects >= maxRedirects) {
        throw new SsrfBlockedError(
          `too many redirects (>${maxRedirects}) while fetching ${url}; last hop: ${current.toString()}`,
        );
      }
      let next: URL;
      try {
        next = new URL(location, current);
      } catch {
        throw new SsrfBlockedError(
          `redirect from ${current.toString()} has an invalid Location "${location}"`,
        );
      }
      // Release the redirect response body so the socket returns to the pool.
      try {
        await res.body?.cancel();
      } catch {
        /* already released */
      }
      current = await guard.assertSafeUrl(next.toString());
      // Per-hop grant re-check: runs only after the hop passed the SSRF
      // check; a throw refuses the fetch (the caller surfaces it).
      if (onHop !== undefined) await onHop(next);
    }
  };
}
