// SSRF address classification — the ONE shared copy.
//
// Port of the Dart app's `lib/core/ssrf_guard.dart` classification table.
// Every egress guard in the cloud (`@ovid/agent-core`, `@ovid/escrow`,
// `@ovid/mcp`, `@ovid/browser`) imports this module instead of carrying its
// own blocklist: a prefix added here is added everywhere at once, so a new
// reserved range cannot be forgotten in one copy.
//
// The classification is deliberately literal-only (it says nothing about DNS
// resolution — each guard resolves names and feeds every answer through
// `isNonPublicAddress`). Unparseable input fails closed (non-public).

import { isIP } from "node:net";

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
export function bareHost(host: string): string {
  let h = host.trim().toLowerCase();
  if (h.startsWith("[") && h.endsWith("]")) h = h.slice(1, -1);
  while (h.endsWith(".")) h = h.slice(0, -1);
  return h;
}

/** Raw 4/16 bytes for a literal address, or null when it is not one. */
export function parseAddressBytes(ip: string): number[] | null {
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
