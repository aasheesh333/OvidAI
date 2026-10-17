/**
 * URL gate + SSRF guard for the browser engine.
 *
 * `navigableUrlReason` is the pre-navigation gate (Dart `unloadableUrlReason`
 * parity): only http/https may be navigated (an empty scheme is allowed as a
 * relative URL), and the refusal copy names both the tool and the scheme.
 *
 * `assertPublicHost` is the fetch-side SSRF guard. It classifies literal IPs
 * directly and RESOLVES named hosts, refusing when ANY returned address is
 * non-public — plus the host's own public IP (self-block). The IP
 * classification is vendored from @ovid/agent-core's ssrf.ts (landed but not
 * yet exported from its index.ts — P3-T4 owns index.ts this wave).
 * TODO(dedupe): once @ovid/agent-core exports isNonPublicAddress, drop this
 * local copy and import it (controller rules the dedupe at P3-T4 review).
 */

import { lookup as dnsLookup } from "node:dns/promises";
import { isIP } from "node:net";

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
// IP classification — vendored from @ovid/agent-core ssrf.ts
// (byte-for-byte the same logic; see the file-header TODO for the dedupe)
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
  // An IPv4 dotted tail (::ffff:a.b.c.d) becomes two hex groups.
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
    if (body.indexOf("::", dbl + 1) !== -1) return null;
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
  while (groups.length < 8 - tail.length) groups.push(0);
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

function isNonPublicIpv4Bytes(b: number[]): boolean {
  const a0 = b[0];
  const a1 = b[1];
  if (a0 === 0) return true;
  if (a0 === 10) return true;
  if (a0 === 100 && a1 >= 64 && a1 <= 127) return true;
  if (a0 === 127) return true;
  if (a0 === 169 && a1 === 254) return true;
  if (a0 === 172 && a1 >= 16 && a1 <= 31) return true;
  if (a0 === 192 && a1 === 0 && b[2] === 0) return true;
  if (a0 === 192 && a1 === 168) return true;
  if (a0 === 198 && (a1 === 18 || a1 === 19)) return true;
  if (a0 >= 224) return true;
  return false;
}

/** True for every address the browser engine must never fetch. Fail-closed. */
function isNonPublicAddress(ip: string): boolean {
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
