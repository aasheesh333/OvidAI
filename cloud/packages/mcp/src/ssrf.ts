/**
 * SSRF guard for every agent/plugin egress fetch — a port of the Dart app's
 * `lib/core/ssrf_guard.dart` (classifier comments copied).
 *
 * A literal-only check ("is the host string 10.x?") is walked around by any
 * name that RESOLVES to an internal address — a public DNS record pointing
 * at `127.0.0.1`, `169.254.169.254` or an IPv4-mapped IPv6 address. The
 * guarded fetch resolves the name and refuses when ANY returned address is
 * non-public, so a mixed record set cannot slip one internal target in.
 *
 * Remaining limit (documented, not solved here): the HTTP stack resolves
 * again when it connects, so a rebinding resolver with a near-zero TTL can
 * still swap answers between the check and the connect.
 *
 * Loopback exemption: outside production (`NODE_ENV !== "production"`) the
 * guard allows a LITERAL loopback host only — tests and dev fixture servers
 * listen on 127.0.0.1 and are addressed by its literal. A name that
 * RESOLVES to a loopback (or any other non-public) address is refused in
 * every mode, so a mixed record set can never slip a loopback target in.
 */

import { resolve4, resolve6 } from "node:dns/promises";
import { isIP } from "node:net";

import { isNonPublicAddress, parseAddressBytes } from "@ovid/shared";

// Re-exported because consumers (and the package barrel) import the
// classifier from "./ssrf.js"; the implementation lives in @ovid/shared.
export { isNonPublicAddress };

/** Resolves a host name to every address (IP strings) it maps to. */
export type HostResolver = (host: string) => Promise<string[]>;

/** The fetch target was refused by the SSRF guard. */
export class SsrfBlockedError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SsrfBlockedError";
  }
}

export interface GuardedFetchOptions {
  /** Test seam; defaults to system DNS (resolve4 + resolve6, concatenated). */
  resolver?: HostResolver;
  /** Destination ports the guard lets through; defaults to [443, 80]. */
  allowedPorts?: number[];
  /** Fetch implementation; defaults to the global fetch. */
  fetchImpl?: typeof fetch;
}

export type GuardedFetch = (url: string, init?: RequestInit) => Promise<Response>;


/** Loopback only (127/8, ::1, and their IPv6-embedded forms) — the dev-mode exemption. */
function isLoopbackAddress(ip: string): boolean {
  const b = parseAddressBytes(ip);
  if (b === null) return false;
  if (b.length === 4) return b[0] === 127;
  if (b.length !== 16) return false;
  let zeros15 = true;
  for (let i = 0; i < 15; i++) {
    if (b[i] !== 0) {
      zeros15 = false;
      break;
    }
  }
  if (zeros15 && b[15] === 1) return true; // ::1
  let zeroPrefix = true;
  for (let i = 0; i < 10; i++) {
    if (b[i] !== 0) {
      zeroPrefix = false;
      break;
    }
  }
  // ::ffff:127.x.x.x (mapped) / ::127.x.x.x (compatible)
  if (
    zeroPrefix &&
    ((b[10] === 0xff && b[11] === 0xff) || (b[10] === 0 && b[11] === 0)) &&
    b[12] === 127
  ) {
    return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// The guarded fetch
// ---------------------------------------------------------------------------

const defaultResolver: HostResolver = async (host) => {
  const [v4, v6] = await Promise.all([
    resolve4(host).catch(() => [] as string[]),
    resolve6(host).catch(() => [] as string[]),
  ]);
  return [...v4, ...v6];
};

/**
 * A fetch that refuses to leave the public internet: https/http only,
 * allowed ports only, no loopback/local names, and EVERY resolved address
 * classified before the wire is touched. Resolution failures pass through —
 * a name that does not resolve cannot be connected to either.
 */
export function createGuardedFetch(opts: GuardedFetchOptions = {}): GuardedFetch {
  const resolver = opts.resolver ?? defaultResolver;
  const allowedPorts = opts.allowedPorts ?? [443, 80];
  const fetchImpl = opts.fetchImpl ?? fetch;
  return async function guardedFetch(url: string, init?: RequestInit): Promise<Response> {
    let parsed: URL;
    try {
      parsed = new URL(url);
    } catch {
      throw new SsrfBlockedError(`not a valid URL: ${url}`);
    }
    const scheme = parsed.protocol.slice(0, -1).toLowerCase();
    if (scheme !== "https" && scheme !== "http") {
      throw new SsrfBlockedError(`scheme "${parsed.protocol}" is not allowed (https/http only)`);
    }
    const port = parsed.port === "" ? (scheme === "https" ? 443 : 80) : Number(parsed.port);
    if (!allowedPorts.includes(port)) {
      throw new SsrfBlockedError(`port ${port} is not allowed`);
    }
    const host = parsed.hostname.toLowerCase().replace(/^\[/, "").replace(/\]$/, "").replace(/\.+$/, "");
    if (host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local")) {
      throw new SsrfBlockedError(`host "${parsed.hostname}" is a loopback/local name`);
    }

    let addresses: string[];
    if (isIP(host) !== 0) {
      addresses = [host]; // a literal resolves to itself
    } else {
      addresses = await resolver(host);
    }
    // loopback exemption: literal hosts only, and never in production
    const exemptLoopback = isIP(host) !== 0 && process.env.NODE_ENV !== "production";
    for (const a of addresses) {
      if (isNonPublicAddress(a)) {
        if (exemptLoopback && isLoopbackAddress(a)) continue; // dev/test fixture servers
        throw new SsrfBlockedError(`host "${parsed.hostname}" resolves to a non-public address (${a})`);
      }
    }
    return fetchImpl(url, init);
  };
}
