// SSRF address classification — shared by the BYOK probe (P9 Task 11 fix
// round 1, review M2). This is the canonical `isNonPublicAddress` logic from
// `@ovid/agent-core/src/ssrf.ts` (itself a byte-for-byte port of the Dart
// `ssrf_guard.dart` classification table).
//
// Why a copy instead of an import: the gateway consumes `@ovid/escrow` but not
// `@ovid/agent-core`, and adding a workspace dependency requires a
// `pnpm-lock.yaml` importer change. The two implementations must stay
// behaviourally identical — when the lockfile can be touched, collapse them
// into ONE package export rather than letting a third list drift.
//
// The probe previously carried a narrower string-shape classifier that missed
// NAT64 `64:ff9b::/96`, 6to4 `2002::/16`, IPv4-compatible `::a.b.c.d`,
// `fec0::/10` site-local and `ff00::/8` multicast. Those are deliberately
// rejected here (and tested in `address.test.ts` + the gateway route tests).

import { isIP } from "node:net";

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
    const hi = ((v4[0]! << 8) | v4[1]!).toString(16);
    const lo = ((v4[2]! << 8) | v4[3]!).toString(16);
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

function isNonPublicIpv4Bytes(b: number[]): boolean {
  const a0 = b[0];
  const a1 = b[1];
  if (a0 === 0) return true; // "this network", incl. 0.0.0.0
  if (a0 === 10) return true; // private
  if (a0 === 100 && a1! >= 64 && a1! <= 127) return true; // CGNAT + Alibaba metadata
  if (a0 === 127) return true; // loopback
  if (a0 === 169 && a1 === 254) return true; // link-local / cloud metadata
  if (a0 === 172 && a1! >= 16 && a1! <= 31) return true; // private
  if (a0 === 192 && a1 === 0 && b[2] === 0) return true; // 192.0.0.0/24
  if (a0 === 192 && a1 === 168) return true; // private
  if (a0 === 198 && (a1 === 18 || a1 === 19)) return true; // benchmarking
  if (a0! >= 224) return true; // multicast, reserved, broadcast
  return false;
}

/**
 * True for every address an egress fetch must never reach:
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
  if ((b[0]! & 0xfe) === 0xfc) return true; // fc00::/7 ULA
  if (b[0] === 0xfe && (b[1]! & 0xc0) === 0x80) return true; // fe80::/10 link-local
  if (b[0] === 0xfe && (b[1]! & 0xc0) === 0xc0) return true; // fec0::/10 site-local
  if (b[0] === 0xff) return true; // multicast
  return false;
}
