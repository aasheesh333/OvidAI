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
import { isIP } from "node:net";

import type { EgressFetch } from "./ports.js";

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
// Address parsing: node:net isIP picks the family, strict byte parsers turn
// the text into the 4/16 raw bytes Dart got from InternetAddress.rawAddress.
// ---------------------------------------------------------------------------

function parseIpv4Bytes(s: string): number[] | null {
  const parts = s.split(".");
  if (parts.length !== 4) return null;
  const out: number[] = [];
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return null;
    const value = Number(part);
    if (value > 255) return null;
    out.push(value);
  }
  return out;
}

function parseHexGroup(group: string): number | null {
  if (!/^[0-9a-f]{1,4}$/.test(group)) return null;
  return Number.parseInt(group, 16);
}

function parseIpv6Bytes(s: string): number[] | null {
  let body = s;
  // An IPv4 dotted tail (::ffff:a.b.c.d, 64:ff9b::a.b.c.d) becomes two hex
  // groups so the generic group parser below can handle everything.
  if (body.includes(".")) {
    const lastColon = body.lastIndexOf(":");
    if (lastColon === -1) return null;
    const v4 = parseIpv4Bytes(body.slice(lastColon + 1));
    if (!v4) return null;
    const hi = ((v4[0] << 8) | v4[1]).toString(16);
    const lo = ((v4[2] << 8) | v4[3]).toString(16);
    body = body.slice(0, lastColon + 1) + hi + ":" + lo;
  }
  const dbl = body.indexOf("::");
  let head: string[];
  let tail: string[] = [];
  if (dbl !== -1) {
    if (body.indexOf("::", dbl + 1) !== -1) return null; // only one "::" allowed
    const headPart = body.slice(0, dbl);
    const tailPart = body.slice(dbl + 2);
    head = headPart === "" ? [] : headPart.split(":");
    tail = tailPart === "" ? [] : tailPart.split(":");
    if (head.length + tail.length > 7) return null;
  } else {
    head = body.split(":");
    if (head.length !== 8) return null;
  }
  const groups: number[] = [];
  for (const g of head) {
    const v = parseHexGroup(g);
    if (v === null) return null;
    groups.push(v);
  }
  while (groups.length < 8 - tail.length) groups.push(0); // "::" zero fill
  for (const g of tail) {
    const v = parseHexGroup(g);
    if (v === null) return null;
    groups.push(v);
  }
  if (groups.length !== 8) return null;
  const bytes: number[] = [];
  for (const g of groups) bytes.push(g >> 8, g & 0xff);
  return bytes;
}

/** Strips IPv6 brackets and a trailing dot (Dart `_bareHost`). */
function bareHost(host: string): string {
  let h = host.trim().toLowerCase();
  if (h.startsWith("[") && h.endsWith("]")) h = h.slice(1, -1);
  while (h.endsWith(".")) h = h.slice(0, -1);
  return h;
}

function parseAddressBytes(ip: string): number[] | null {
  const bare = bareHost(ip);
  if (bare === "") return null;
  const family = isIP(bare);
  if (family === 4) return parseIpv4Bytes(bare);
  if (family === 6) return parseIpv6Bytes(bare);
  return null;
}

// ---------------------------------------------------------------------------
// Classification — port of ssrf_guard.dart lines 45-110, byte for byte.
// ---------------------------------------------------------------------------

function isNonPublicIpv4Bytes(b: number[]): boolean {
  const a0 = b[0];
  const a1 = b[1];
  if (a0 === 0) return true; // "this network", incl. 0.0.0.0
  if (a0 === 10) return true; // private
  if (a0 === 100 && a1 >= 64 && a1 <= 127) return true; // CGNAT + Alibaba metadata
  if (a0 === 127) return true; // loopback
  if (a0 === 169 && a1 === 254) return true; // link-local / cloud metadata
  if (a0 === 172 && a1 >= 16 && a1 <= 31) return true; // private
  if (a0 === 192 && a1 === 0 && b[2] === 0) return true; // 192.0.0.0/24
  if (a0 === 192 && a1 === 168) return true; // private
  if (a0 === 198 && (a1 === 18 || a1 === 19)) return true; // benchmarking
  if (a0 >= 224) return true; // multicast, reserved, broadcast
  return false;
}

/** The IPv4 bytes embedded in an IPv6 form, when there is one (Dart `_embeddedIpv4`). */
function embeddedIpv4(b: number[]): number[] | null {
  let zeros = true;
  for (let i = 0; i < 10; i++) {
    if (b[i] !== 0) zeros = false;
  }
  if (zeros && ((b[10] === 0xff && b[11] === 0xff) || (b[10] === 0 && b[11] === 0))) {
    return b.slice(12); // ::ffff:a.b.c.d (mapped) and ::a.b.c.d (compatible)
  }
  if (b[0] === 0x00 && b[1] === 0x64 && b[2] === 0xff && b[3] === 0x9b) {
    return b.slice(12); // NAT64 well-known prefix 64:ff9b::/96
  }
  if (b[0] === 0x20 && b[1] === 0x02) return b.slice(2, 6); // 6to4 2002:AABB:CCDD::/48
  return null;
}

/**
 * True for every address an egress fetch must never reach — see the exact
 * prefix list in ssrf_guard.dart (IPv4: 0/8, 10/8, 100.64/10, 127/8,
 * 169.254/16, 172.16/12, 192.0.0/24, 192.168/16, 198.18/15, 224/4+, broadcast;
 * IPv6: `::`, `::1`, fc00::/7, fe80::/10, fec0::/10, ff00::/8, and every
 * IPv4-embedding form, classified by the embedded IPv4). Unparseable input
 * fails closed (non-public).
 */
export function isNonPublicAddress(ip: string): boolean {
  const b = parseAddressBytes(ip);
  if (b === null) return true;
  if (b.length === 4) return isNonPublicIpv4Bytes(b);
  if (b.length !== 16) return true;
  let allZeroPrefix = true;
  for (let i = 0; i < 10; i++) {
    if (b[i] !== 0) {
      allZeroPrefix = false;
      break;
    }
  }
  if (allZeroPrefix) {
    // :: and ::1 also land here: their embedded "IPv4" is 0.0.0.0 / 0.0.0.1.
    if ((b[10] === 0xff && b[11] === 0xff) || (b[10] === 0 && b[11] === 0)) {
      return isNonPublicIpv4Bytes(b.slice(12));
    }
  }
  if (b[0] === 0x00 && b[1] === 0x64 && b[2] === 0xff && b[3] === 0x9b) {
    let zeros = true;
    for (let i = 4; i < 12; i++) {
      if (b[i] !== 0) zeros = false;
    }
    if (zeros) return isNonPublicIpv4Bytes(b.slice(12));
  }
  if (b[0] === 0x20 && b[1] === 0x02) return isNonPublicIpv4Bytes(b.slice(2, 6));
  if ((b[0] & 0xfe) === 0xfc) return true; // fc00::/7 ULA
  if (b[0] === 0xfe && (b[1] & 0xc0) === 0x80) return true; // fe80::/10 link-local
  if (b[0] === 0xfe && (b[1] & 0xc0) === 0xc0) return true; // fec0::/10 site-local
  if (b[0] === 0xff) return true; // multicast
  return false;
}

/**
 * Link-local / cloud-metadata only: `169.254/16`, `fe80::/10`, Alibaba
 * `100.100.100.200`, and their IPv4-embedding IPv6 forms. Used where loopback
 * and LAN stay legitimate (behind a host grant) but metadata must be refused
 * in every mode. Unparseable input is not a metadata address.
 */
export function isMetadataOrLinkLocalAddress(ip: string): boolean {
  let b = parseAddressBytes(ip);
  if (b === null) return false;
  if (b.length === 16) {
    if (b[0] === 0xfe && (b[1] & 0xc0) === 0x80) return true;
    const embedded = embeddedIpv4(b);
    if (embedded === null) return false;
    b = embedded;
  }
  if (b.length !== 4) return false;
  if (b[0] === 169 && b[1] === 254) return true;
  return b[0] === 100 && b[1] === 100 && b[2] === 100 && b[3] === 200;
}

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
