/**
 * URL gate + SSRF guard for the browser engine.
 *
 * `navigableUrlReason` is the pre-navigation gate (Dart `unloadableUrlReason`
 * parity): only http/https may be navigated (an empty scheme is allowed as a
 * relative URL), and the refusal copy names both the tool and the scheme.
 *
 * `assertPublicHost` is the fetch-side SSRF guard. It classifies literal IPs
 * directly and RESOLVES named hosts, refusing when ANY returned address is
 * non-public — plus the host's own public IP (self-block). The address
 * classifier itself is the ONE copy in @ovid/shared (`netAddress.ts`); this
 * module only owns the resolution/self-block behaviour.
 */

import { lookup as dnsLookup } from "node:dns/promises";

import { bareHost, isNonPublicAddress, parseAddressBytes } from "@ovid/shared";

import type { BrowserEngineConfig } from "./config.js";

// ---------------------------------------------------------------------------
// navigableUrlReason — Dart unloadableUrlReason parity
// ---------------------------------------------------------------------------

/**
 * Why the URL cannot be navigated by `tool`, or null when it can. Only
 * http/https (and scheme-less relative URLs) are navigable.
 */
export function navigableUrlReason(url: string, tool: string): string | null {
  // A relative URL has no scheme (and no ":" before any "/") — allowed.
  const colon = url.indexOf(":");
  const slash = url.indexOf("/");
  if (colon === -1 || (slash !== -1 && slash < colon)) {
    return null; // relative
  }
  let scheme: string;
  try {
    scheme = new URL(url).protocol;
  } catch {
    return `${tool}: "${url}" is not a valid URL`;
  }
  if (scheme === "http:" || scheme === "https:") return null;
  return `${tool}: refused — ${scheme} URLs are not navigable (http/https only): ${url}`;
}

// ---------------------------------------------------------------------------
// assertPublicHost / createSsrfGuardedFetch
// ---------------------------------------------------------------------------

export class SsrfError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SsrfError";
  }
}

type SsrfConfig = Pick<BrowserEngineConfig, "allowHosts" | "ownPublicIp">;
export type HostLookup = (host: string) => Promise<string[]>;

async function defaultLookup(host: string): Promise<string[]> {
  const records = await dnsLookup(host, { all: true, verbatim: true });
  return records.map((r) => r.address);
}

/** The vetted host + the exact addresses the gate approved. */
export interface PublicHostVerdict {
  /** Bare, lowercase host. */
  host: string;
  /** Vetted addresses; empty for an exact `allowHosts` bypass. */
  addresses: string[];
}

/**
 * Vetted hosts → the exact addresses the tool gate approved. Keyed by the
 * engine config object (one engine per config), so pins never leak between
 * worker instances. The browser route layer authorizes requests against this
 * pin instead of resolving the name a second time: a DNS-rebinding answer
 * between `guardUrl` and `goto` can no longer widen the gate.
 */
const pinnedHosts = new WeakMap<SsrfConfig, Map<string, string[]>>();

/** Remember the addresses `guardUrl` vetted for `verdict.host`. */
export function pinPublicHost(cfg: SsrfConfig, verdict: PublicHostVerdict): void {
  if (verdict.addresses.length === 0) return; // allowHosts bypass — no pin needed
  let pins = pinnedHosts.get(cfg);
  if (pins === undefined) {
    pins = new Map();
    pinnedHosts.set(cfg, pins);
  }
  pins.set(verdict.host, [...verdict.addresses]);
}

/**
 * A lookup that answers from the pins recorded by `guardUrl`, falling back to
 * `fallback` for hosts that were never vetted (subresources, redirects). This
 * is the request-time half of DNS-rebinding defence.
 */
export function pinnedHostLookup(
  cfg: SsrfConfig,
  fallback: HostLookup = defaultLookup,
): HostLookup {
  return async (host: string): Promise<string[]> => {
    const pinned = pinnedHosts.get(cfg)?.get(bareHost(host));
    if (pinned !== undefined) return [...pinned];
    return fallback(host);
  };
}

/** Drop every pin for `cfg` (engine/pool teardown). */
export function clearPinnedHosts(cfg: SsrfConfig): void {
  pinnedHosts.delete(cfg);
}

/**
 * Resolve and classify `url`'s host. Throws SsrfError unless every address
 * the host maps to is public. Blocks RFC1918, 127/8, 169.254/16, 100.64/10,
 * ::1, fc00::/7, fe80::/10, IPv4-embedded IPv6, and the host's own public IP.
 * `allowHosts` is an exact-host bypass (tests and explicit opt-ins only).
 */
export async function resolvePublicHost(
  url: string,
  cfg: SsrfConfig,
  lookup: HostLookup = defaultLookup,
): Promise<PublicHostVerdict> {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new SsrfError(`"${url}" is not a valid URL`);
  }
  const host = bareHost(parsed.hostname);
  if (host === "") throw new SsrfError(`"${url}" has no host`);
  // Exact-match bypass only ("127.0.0.1" must not match "x.127.0.0.1").
  if (cfg.allowHosts.some((h) => bareHost(h) === host)) {
    return { host, addresses: [] };
  }
  if (host === "localhost" || host.endsWith(".localhost")) {
    throw new SsrfError(`host "${host}" is a loopback name`);
  }
  const literal = parseAddressBytes(host);
  let addresses: string[];
  if (literal !== null) {
    addresses = [host];
  } else {
    try {
      addresses = await lookup(host);
    } catch {
      throw new SsrfError(`host "${host}" could not be resolved — refusing (fail-closed)`);
    }
    if (addresses.length === 0) {
      throw new SsrfError(`host "${host}" resolved to no addresses — refusing (fail-closed)`);
    }
  }
  for (const a of addresses) {
    if (isNonPublicAddress(a)) {
      throw new SsrfError(`host "${host}" maps to a non-public address (${a})`);
    }
  }
  if (cfg.ownPublicIp !== null && literal === null) {
    // named host: also refuse when any answer is our own public IP
    for (const a of addresses) {
      if (bareHost(a) === bareHost(cfg.ownPublicIp)) {
        throw new SsrfError(`host "${host}" resolves to this service's own IP — refusing`);
      }
    }
  } else if (cfg.ownPublicIp !== null && bareHost(cfg.ownPublicIp) === host) {
    throw new SsrfError(`host "${host}" is this service's own IP — refusing`);
  }
  return { host, addresses };
}

/** Throws unless every address `url`'s host maps to is public. */
export async function assertPublicHost(
  url: string,
  cfg: SsrfConfig,
  lookup: HostLookup = defaultLookup,
): Promise<void> {
  await resolvePublicHost(url, cfg, lookup);
}

/**
 * A fetch wrapper that runs assertPublicHost on every request URL before
 * handing it to the transport. Redirects are followed MANUALLY (at most
 * `maxRedirects` hops) and each hop is re-gated: letting the transport follow
 * `Location` would validate only the first URL. `allowHosts` still bypasses
 * the gate exactly as `assertPublicHost` does.
 */
export function createSsrfGuardedFetch(
  cfg: SsrfConfig,
  fetchImpl: typeof fetch = fetch,
  maxRedirects = 5,
): typeof fetch {
  return async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    let current =
      typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    for (let hop = 0; hop <= maxRedirects; hop++) {
      await assertPublicHost(current, cfg);
      const response = init === undefined
        ? await fetchImpl(current, { redirect: "manual" })
        : await fetchImpl(current, { ...init, redirect: "manual" });
      if (![301, 302, 303, 307, 308].includes(response.status)) {
        // Keep `res.url` describing the URL that was actually fetched (the
        // transport's manual-mode Response may report the original request or
        // an empty string for a stub).
        try {
          Object.defineProperty(response, "url", { value: current, configurable: true });
        } catch {
          // Non-configurable Response — the caller's fallback still applies.
        }
        return response;
      }
      const location = response.headers.get("location");
      await response.body?.cancel().catch(() => {});
      if (location === null || location === "") return response;
      current = new URL(location, current).toString();
    }
    throw new SsrfError(`refused: more than ${maxRedirects} redirects`);
  };
}
