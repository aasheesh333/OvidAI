/**
 * Which address is the CLIENT? — the one trust decision behind IP anomaly
 * detection.
 *
 * The gateway does NOT enable Fastify's `trustProxy`, so `request.ip` is the
 * raw socket peer (Caddy or the Docker bridge). Turning `trustProxy` on
 * globally would be a security bug: any client that can reach the gateway
 * directly could then choose its own `request.ip` by sending a header.
 *
 * Instead this module trusts X-Forwarded-For ONLY when the socket peer is one
 * of the configured reverse proxies. The algorithm:
 *
 *   1. No peer, or an unparseable peer → no client IP, and the header is
 *      never consulted (untrusted by default).
 *   2. Peer not in the trusted set → return the PEER. The header is
 *      attacker-controlled and is ignored entirely.
 *   3. Peer trusted → parse the header right-to-left and return the
 *      rightmost address that is not itself a trusted proxy. Everything to
 *      the left of that hop is client-supplied and must never be trusted.
 *   4. All hops trusted → return the leftmost (the originating address).
 *   5. Any malformed hop → ignore the WHOLE header and fall back to the peer.
 *      Never salvage a partial chain: the salvageable entry may be the
 *      attacker's.
 *
 * WHY THE RIGHTMOST UNTRUSTED HOP, CONCRETELY
 *
 * In production Caddy is the only hop. `deploy/caddy-snippet.conf` sets
 * `header_up X-Forwarded-For {client_ip}`, so the gateway receives exactly
 * one address — the visitor address Caddy resolved (Caddy itself trusts
 * Cloudflare's CIDRs and reads CF-Connecting-IP/XFF). If the deployed Caddy
 * instead APPENDS (its default), the header is `client-supplied…, real-peer`
 * and the rightmost untrusted address is still the real visitor. The
 * leftmost value is never used unless every hop is a trusted proxy.
 *
 * WHY THE PEER CHECK IS MEANINGFUL HERE — the deployment, not the header
 * ---------------------------------------------------------------------
 * `deploy/docker-compose.yml` publishes the gateway ONLY on the host
 * loopback: `127.0.0.1:${GATEWAY_HOST_PORT:-8082}:8081`. A client on the
 * public internet therefore CANNOT open a TCP connection to the gateway
 * directly; the socket peer is always Caddy on 127.0.0.1 (host) or the
 * Docker bridge gateway (container network). That binding is what makes
 * "trust XFF only from a private/loopback peer" safe: a public attacker has
 * no way to become the peer. If the gateway is ever published on a public
 * interface, this assumption breaks — keep the publish address loopback.
 *
 * The trusted set defaults to loopback + RFC1918: that is the reverse proxy's
 * own address space (host loopback or the Docker bridge), and a public client
 * cannot present one of those as its source. Operators can narrow it with
 * OVID_TRUSTED_PROXY_CIDRS (comma/space separated CIDRs), and should narrow
 * it if the gateway shares a private network with peers they do not control.
 */

import { bareHost, parseAddressBytes } from "@ovid/shared";

/** A compiled CIDR block. `bytes` is 4 (IPv4) or 16 (IPv6) octets. */
export interface TrustedProxy {
  readonly bytes: readonly number[];
  readonly prefix: number;
}

/**
 * Default trusted peers: the reverse proxy's own address space.
 *
 * - loopback: bare-metal Caddy → 127.0.0.1:8082
 * - 172.16/12: Docker's userland proxy / bridge gateway
 * - 10/8 + 192.168/16: other common private Docker/host networks
 *
 * These are only used to decide whether the SOCKET PEER may supply
 * X-Forwarded-For. A public client cannot forge a private source address.
 * If the gateway shares a private network with peers you do not trust, narrow
 * this set.
 */
export const DEFAULT_TRUSTED_PROXY_CIDRS: readonly string[] = [
  "127.0.0.0/8",
  "::1/128",
  "10.0.0.0/8",
  "172.16.0.0/12",
  "192.168.0.0/16",
];

/** The IPv4 embedded in `::ffff:a.b.c.d`, or null. */
function mappedIpv4(bytes: readonly number[]): number[] | null {
  if (bytes.length !== 16) return null;
  for (let i = 0; i < 10; i += 1) {
    if (bytes[i] !== 0) return null;
  }
  if (bytes[10] !== 0xff || bytes[11] !== 0xff) return null;
  return bytes.slice(12);
}

function matchesCidr(address: readonly number[], cidr: TrustedProxy): boolean {
  if (address.length !== cidr.bytes.length) return false;
  const fullBytes = Math.floor(cidr.prefix / 8);
  for (let i = 0; i < fullBytes; i += 1) {
    if (address[i] !== cidr.bytes[i]) return false;
  }
  const remainder = cidr.prefix % 8;
  if (remainder !== 0) {
    const mask = (0xff << (8 - remainder)) & 0xff;
    if ((address[fullBytes]! & mask) !== (cidr.bytes[fullBytes]! & mask)) {
      return false;
    }
  }
  return true;
}

/** Compile one CIDR. A bare address means a /32 (IPv4) or /128 (IPv6). */
export function compileTrustedProxy(cidr: string): TrustedProxy {
  const text = cidr.trim();
  const slash = text.indexOf("/");
  const addressText = slash === -1 ? text : text.slice(0, slash);
  const bytes = parseAddressBytes(addressText);
  if (bytes === null) {
    throw new Error(`invalid trusted proxy address: ${cidr}`);
  }
  const maxPrefix = bytes.length * 8;
  let prefix = maxPrefix;
  if (slash !== -1) {
    const prefixText = text.slice(slash + 1);
    if (!/^\d{1,3}$/.test(prefixText)) {
      throw new Error(`invalid trusted proxy prefix: ${cidr}`);
    }
    prefix = Number(prefixText);
    if (prefix > maxPrefix) {
      throw new Error(`invalid trusted proxy prefix: ${cidr}`);
    }
  }
  return { bytes, prefix };
}

export function compileTrustedProxies(
  cidrs: readonly string[],
): TrustedProxy[] {
  return cidrs.map(compileTrustedProxy);
}

/**
 * Parse OVID_TRUSTED_PROXY_CIDRS. Unset/blank means the documented defaults.
 * Every entry is validated at boot: a typo must fail loudly, never silently
 * widen or narrow the trusted set.
 */
export function parseTrustedProxyCidrs(raw: string | undefined): string[] {
  if (raw === undefined || raw.trim() === "") {
    return [...DEFAULT_TRUSTED_PROXY_CIDRS];
  }
  const entries = raw
    .split(/[,\s]+/)
    .map((entry) => entry.trim())
    .filter((entry) => entry !== "");
  if (entries.length === 0) return [...DEFAULT_TRUSTED_PROXY_CIDRS];
  for (const entry of entries) {
    try {
      compileTrustedProxy(entry);
    } catch {
      throw new Error(
        `OVID_TRUSTED_PROXY_CIDRS contains an invalid CIDR: ${entry}`,
      );
    }
  }
  return entries;
}

/** True when `address` falls inside any trusted CIDR. */
export function isTrustedProxy(
  address: string,
  proxies: readonly TrustedProxy[],
): boolean {
  const bytes = parseAddressBytes(address);
  if (bytes === null) return false;
  const mapped = mappedIpv4(bytes);
  for (const proxy of proxies) {
    if (matchesCidr(bytes, proxy)) return true;
    if (mapped !== null && matchesCidr(mapped, proxy)) return true;
  }
  return false;
}

export interface ClientIpInput {
  /** The raw socket peer (request.socket.remoteAddress), NOT request.ip. */
  peerAddress: string | undefined;
  /**
   * The X-Forwarded-For header value. Duplicate headers arrive as an array;
   * they are joined and parsed as one chain.
   */
  forwardedFor: string | readonly string[] | undefined;
  trustedProxies: readonly TrustedProxy[];
}

function canonicalAddress(bytes: readonly number[]): string {
  const mapped = mappedIpv4(bytes);
  if (mapped !== null) return mapped.join(".");
  if (bytes.length === 4) return bytes.join(".");
  const groups: number[] = [];
  for (let i = 0; i < 16; i += 2) groups.push((bytes[i]! << 8) | bytes[i + 1]!);

  // RFC 5952: lower-case hex and the FIRST longest run of two or more zero
  // groups compressed. Canonical spellings keep one client in one IP bucket.
  let bestStart = -1;
  let bestLength = 0;
  for (let i = 0; i < groups.length; ) {
    if (groups[i] !== 0) {
      i += 1;
      continue;
    }
    let end = i;
    while (end < groups.length && groups[end] === 0) end += 1;
    if (end - i > bestLength) {
      bestStart = i;
      bestLength = end - i;
    }
    i = end;
  }
  const hex = groups.map((group) => group.toString(16));
  if (bestLength < 2) return hex.join(":");
  const left = hex.slice(0, bestStart).join(":");
  const right = hex.slice(bestStart + bestLength).join(":");
  return `${left}::${right}`;
}

function normalizeAddress(raw: string | undefined): string | null {
  if (raw === undefined) return null;
  const bare = bareHost(raw.trim());
  if (bare === "" || bare.toLowerCase() === "unknown") return null;
  const bytes = parseAddressBytes(bare);
  return bytes === null ? null : canonicalAddress(bytes);
}

/** Canonical client IP for durable buckets, or null for malformed/unknown input. */
export function canonicalizeClientIp(raw: string | null | undefined): string | null {
  return normalizeAddress(raw ?? undefined);
}

/**
 * Parse X-Forwarded-For. Returns `null` when ANY hop is malformed (the whole
 * header is then ignored), `[]` when absent/empty.
 */
function forwardedEntries(
  raw: string | readonly string[] | undefined,
): string[] | null {
  if (raw === undefined) return [];
  const text = typeof raw === "string" ? raw : raw.join(",");
  const parts = text
    .split(",")
    .map((part) => part.trim())
    .filter((part) => part !== "");
  if (parts.length === 0) return [];
  const entries: string[] = [];
  for (const part of parts) {
    const normalized = normalizeAddress(part);
    if (normalized === null) return null;
    entries.push(normalized);
  }
  return entries;
}

/**
 * Resolve the client IP, or null when it cannot be identified. See the module
 * comment for the exact hop read and why.
 */
export function resolveClientIp(input: ClientIpInput): string | null {
  const peer = normalizeAddress(input.peerAddress);
  if (peer === null) return null;

  // An untrusted peer's header is attacker-controlled: ignore it completely.
  if (!isTrustedProxy(peer, input.trustedProxies)) return peer;

  const entries = forwardedEntries(input.forwardedFor);
  if (entries === null || entries.length === 0) return peer;

  for (let i = entries.length - 1; i >= 0; i -= 1) {
    const entry = entries[i]!;
    if (!isTrustedProxy(entry, input.trustedProxies)) return entry;
  }
  return entries[0]!;
}

export interface ClientNetworkInput extends ClientIpInput {
  /** Edge-supplied ASN header. Trusted only under the same proxy/XFF contract. */
  asn: string | readonly string[] | undefined;
}

export interface ClientNetwork {
  ip: string | null;
  asn: string | null;
}

/**
 * Resolve IP and ASN as ONE trusted edge observation. An ASN is accepted only
 * from a configured proxy that also supplied a complete, valid XFF chain. A
 * malformed chain, duplicate ASN, arbitrary label, or direct-client header is
 * unknown evidence (null), never an attacker-selected network identity.
 */
export function resolveClientNetwork(input: ClientNetworkInput): ClientNetwork {
  const ip = resolveClientIp(input);
  const peer = normalizeAddress(input.peerAddress);
  if (peer === null || !isTrustedProxy(peer, input.trustedProxies)) return { ip, asn: null };
  const entries = forwardedEntries(input.forwardedFor);
  if (entries === null || entries.length === 0 || typeof input.asn !== "string") {
    return { ip, asn: null };
  }
  const match = /^(?:as)?(\d{1,10})$/i.exec(input.asn.trim());
  if (match === null) return { ip, asn: null };
  const value = Number(match[1]);
  if (!Number.isSafeInteger(value) || value > 4_294_967_295) return { ip, asn: null };
  return { ip, asn: `AS${value}` };
}
