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

/**
 * Throws SsrfError unless every address `url`'s host maps to is public.
 * Blocks RFC1918, 127/8, 169.254/16, 100.64/10, ::1, fc00::/7, fe80::/10,
 * IPv4-embedded IPv6, and the host's own public IP. `allowHosts` is an
 * exact-host bypass (tests and explicit opt-ins only).
 */
export async function assertPublicHost(
  url: string,
  cfg: SsrfConfig,
  lookup: HostLookup = defaultLookup,
): Promise<void> {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new SsrfError(`"${url}" is not a valid URL`);
  }
  const host = bareHost(parsed.hostname);
  if (host === "") throw new SsrfError(`"${url}" has no host`);
  // Exact-match bypass only ("127.0.0.1" must not match "x.127.0.0.1").
  if (cfg.allowHosts.some((h) => bareHost(h) === host)) return;
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
}

/**
 * A fetch wrapper that runs assertPublicHost on every request URL before
 * handing it to the transport. NOTE: unlike @ovid/agent-core's
 * createGuardedEgressFetch this does NOT follow redirects manually — the
 * browser engine's fetches are navigation/resource loads whose redirects are
 * handled (and re-gated) by the engine itself.
 */
export function createSsrfGuardedFetch(
  cfg: SsrfConfig,
  fetchImpl: typeof fetch = fetch,
): typeof fetch {
  return async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    await assertPublicHost(url, cfg);
    return init === undefined ? fetchImpl(input as Parameters<typeof fetch>[0]) : fetchImpl(input as Parameters<typeof fetch>[0], init);
  };
}
