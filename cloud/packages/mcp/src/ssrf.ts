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

// ---------------------------------------------------------------------------
// Address parsing (the Dart code parsed to raw bytes; we parse IP strings)
// ---------------------------------------------------------------------------

function ipv4Bytes(ip: string): number[] | null {
  const parts = ip.split(".");
  if (parts.length !== 4) return null;
  const out: number[] = [];
  for (const p of parts) {
    if (!/^\d{1,3}$/.test(p)) return null;
    const n = Number(p);
    if (n > 255) return null;
    out.push(n);
  }
  return out;
}

function ipv6Groups(chunk: string): number[] | null {
  if (chunk === "") return [];
  const groups: number[] = [];
  for (const g of chunk.split(":")) {
    if (g.includes(".")) {
      const v4 = ipv4Bytes(g);
      if (v4 === null) return null;
      groups.push((v4[0] << 8) | v4[1], (v4[2] << 8) | v4[3]);
    } else {
      if (!/^[0-9a-f]{1,4}$/.test(g)) return null;
      groups.push(Number.parseInt(g, 16));
    }
  }
  return groups;
}

function ipv6Bytes(addr: string): number[] | null {
  let h = addr.toLowerCase();
  const zone = h.indexOf("%"); // strip a zone index (%eth0)
  if (zone !== -1) h = h.slice(0, zone);
  if (!h.includes(":")) return null;
  const halves = h.split("::");
  if (halves.length > 2) return null;
  const bytes: number[] = [];
  const pushGroups = (groups: number[]): void => {
    for (const g of groups) bytes.push(g >>> 8, g & 0xff);
  };
  if (halves.length === 2) {
    const head = ipv6Groups(halves[0]);
    const tail = ipv6Groups(halves[1]);
    if (head === null || tail === null) return null;
    if (head.length + tail.length > 8) return null;
    pushGroups(head);
    for (let i = head.length + tail.length; i < 8; i++) bytes.push(0, 0);
    pushGroups(tail);
  } else {
    const groups = ipv6Groups(h);
    if (groups === null || groups.length !== 8) return null;
    pushGroups(groups);
  }
  return bytes.length === 16 ? bytes : null;
}

function addressBytes(ip: string): number[] | null {
  return ip.includes(":") ? ipv6Bytes(ip) : ipv4Bytes(ip);
}

// ---------------------------------------------------------------------------
// Classification (byte-for-byte the Dart isNonPublicAddress)
// ---------------------------------------------------------------------------

function isNonPublicIpv4(b: number[]): boolean {
  const a0 = b[0];
  const a1 = b[1];
  if (a0 === 0) return true;
  if (a0 === 10) return true;
  if (a0 === 100 && a1 >= 64 && a1 <= 127) return true; // CGNAT, incl. Alibaba metadata 100.100.100.200
  if (a0 === 127) return true;
  if (a0 === 169 && a1 === 254) return true; // link-local / cloud metadata
  if (a0 === 172 && a1 >= 16 && a1 <= 31) return true;
  if (a0 === 192 && a1 === 0 && b[2] === 0) return true;
  if (a0 === 192 && a1 === 168) return true;
  if (a0 === 198 && (a1 === 18 || a1 === 19)) return true;
  if (a0 >= 224) return true; // multicast, reserved, broadcast
  return false;
}

/**
 * True for every address an agent or plugin fetch must never reach:
 *
 * IPv4 `0.0.0.0/8`, `10/8`, `100.64/10` (CGNAT, incl. Alibaba metadata
 * `100.100.100.200`), `127/8`, `169.254/16` (link-local / cloud metadata),
 * `172.16/12`, `192.0.0/24`, `192.168/16`, `198.18/15`, multicast `224/4`,
 * reserved `240/4` and broadcast.
 *
 * IPv6 unspecified `::`, loopback `::1`, ULA `fc00::/7`, link-local
 * `fe80::/10`, deprecated site-local `fec0::/10`, multicast `ff00::/8`, and
 * every IPv6 form that embeds an IPv4 address — mapped `::ffff:a.b.c.d`,
 * compatible `::a.b.c.d`, NAT64 `64:ff9b::/96` and 6to4 `2002::/16` —
 * classified by the embedded IPv4.
 *
 * Unparseable input is non-public (fail closed).
 */
export function isNonPublicAddress(ip: string): boolean {
  const b = addressBytes(ip);
  if (b === null) return true;
  if (b.length === 4) return isNonPublicIpv4(b);
  if (b.length !== 16) return true;
  let allZeroPrefix = true;
  for (let i = 0; i < 10; i++) {
    if (b[i] !== 0) {
      allZeroPrefix = false;
      break;
    }
  }
  if (allZeroPrefix) {
    // ::ffff:a.b.c.d (mapped) and ::a.b.c.d (compatible; also covers
    // :: and ::1, whose embedded "IPv4" is 0.0.0.0 / 0.0.0.1).
    if ((b[10] === 0xff && b[11] === 0xff) || (b[10] === 0 && b[11] === 0)) {
      return isNonPublicIpv4(b.slice(12));
    }
  }
  // NAT64 well-known prefix 64:ff9b::/96.
  if (b[0] === 0x00 && b[1] === 0x64 && b[2] === 0xff && b[3] === 0x9b) {
    let zeros = true;
    for (let i = 4; i < 12; i++) {
      if (b[i] !== 0) zeros = false;
    }
    if (zeros) return isNonPublicIpv4(b.slice(12));
  }
  // 6to4 2002:AABB:CCDD::/48 embeds AA.BB.CC.DD.
  if (b[0] === 0x20 && b[1] === 0x02) return isNonPublicIpv4(b.slice(2, 6));
  if ((b[0] & 0xfe) === 0xfc) return true; // fc00::/7 ULA
  if (b[0] === 0xfe && (b[1] & 0xc0) === 0x80) return true; // fe80::/10
  if (b[0] === 0xfe && (b[1] & 0xc0) === 0xc0) return true; // fec0::/10
  if (b[0] === 0xff) return true; // multicast
  return false;
}

/** Loopback only (127/8, ::1, and their IPv6-embedded forms) — the dev-mode exemption. */
function isLoopbackAddress(ip: string): boolean {
  const b = addressBytes(ip);
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
