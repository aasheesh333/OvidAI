/**
 * Multi-IP / multi-ASN anomaly detection — the PURE decision function.
 *
 * One account's Ovid key is bound to one person. A stolen or shared key is
 * commonly exercised from many unrelated networks at once. This module
 * answers exactly one question from a window of observations:
 *
 *   "does this account look like one key being used from many independent
 *    networks right now?"
 *
 * It performs no I/O, reads no clock, and blocks nothing by itself: the
 * caller supplies the observations and `now`, then decides what to do with
 * `{ block, reason }`. Keeping it pure makes every threshold boundary
 * exhaustively testable and keeps the security decision out of a request
 * handler.
 *
 * ── WHY THE THRESHOLDS ARE DELIBERATELY HIGH ───────────────────────────────
 *
 * A false positive here SUSPENDS A PAYING CUSTOMER, so the detector is built
 * to stay quiet through every ordinary mobile pattern:
 *
 *   • Mobile ↔ WiFi handoff — a phone has one WiFi egress and one carrier
 *     egress, i.e. 2 IPs / 2 ASNs. Reconnecting repeatedly does not add new
 *     ASNs.
 *   • IPv6 privacy addresses (RFC 4941) — the interface identifier rotates,
 *     but the /64 prefix does not. `ipNetworkKey` collapses every address in
 *     a /64 to one network, so rotation can never inflate the count.
 *   • Carrier-grade NAT — many users share one public IPv4. For ONE uid that
 *     still looks like one address, and it cannot multiply ASNs.
 *   • Office / VPN / hotspot — adds at most a few more ASNs.
 *
 * The defaults therefore allow up to SIX distinct ASNs and TWELVE distinct
 * networks in a ten-minute window, and require at least TEN observations
 * before acting. The worst realistic legitimate pattern (home + mobile +
 * office + VPN + hotspot + a second eSIM) is six ASNs; blocking starts at
 * seven. A botnet or a key-sharing ring spans dozens of ASNs, so the margin
 * costs almost nothing in detection power.
 *
 * ASN data is the trustworthy signal: it survives NAT and IPv6 rotation. The
 * distinct-network fallback is used ONLY when the window carries no ASN data
 * at all. If ASN data is present, a carrier rotating /64s while staying in
 * one ASN must not trip the fallback — that would be a false positive.
 */

import { bareHost, parseAddressBytes } from "@ovid/shared";

/** One request's network identity, as observed at the edge. */
export interface IpObservation {
  /** Client IP. `""` and `"unknown"` are accepted but ignored for counting. */
  ip: string;
  /**
   * Autonomous system number or label (`64500`, `"64500"`, `"AS64500"`).
   * `null` / `undefined` when the edge did not supply one.
   */
  asn?: string | number | null;
  /** Epoch milliseconds. */
  at: number;
}

export interface IpAnomalyPolicy {
  /** Sliding window length in milliseconds. */
  windowMs: number;
  /** Distinct ASNs ALLOWED in the window; blocking starts one above this. */
  maxDistinctAsns: number;
  /** Distinct networks allowed when no ASN data is available. */
  maxDistinctNetworks: number;
  /** Below this many in-window observations, never block (volume floor). */
  minObservations: number;
}

/**
 * Defaults are the false-positive-averse contract described in the module
 * comment. Six ASNs / twelve networks in ten minutes / ten observations.
 */
export const DEFAULT_IP_ANOMALY_POLICY: IpAnomalyPolicy = {
  windowMs: 10 * 60 * 1000,
  maxDistinctAsns: 6,
  maxDistinctNetworks: 12,
  minObservations: 10,
};

export type IpAnomalyReason =
  | "no_observations"
  | "below_min_observations"
  | "asn_fanout"
  | "network_fanout"
  | "within_thresholds";

export interface IpAnomalyDecision {
  /** True means: block the key (0 requests allowed) and notify the person. */
  block: boolean;
  /** Stable machine code for logs, audits and tests. */
  reason: IpAnomalyReason;
}

/**
 * Canonical ASN label. `64500`, `"64500"`, `"as64500"` and `" AS64500 "`
 * all become `"AS64500"`, so the same network is never counted twice.
 * Missing, blank, non-finite and negative values are "unknown" (`null`).
 * Non-numeric labels are kept (upper-cased) as evidence rather than dropped.
 */
export function normalizeAsn(
  asn: string | number | null | undefined,
): string | null {
  if (asn === null || asn === undefined) return null;
  if (typeof asn === "number" && (!Number.isFinite(asn) || asn < 0)) {
    return null;
  }
  const text = String(asn).trim();
  if (text === "") return null;
  const numeric = /^(?:as)?\s*(\d{1,10})$/i.exec(text);
  if (numeric !== null) return `AS${numeric[1]}`;
  return text.toUpperCase();
}

/**
 * The network identity of one address:
 *   • IPv4        → the dotted address (carrier NAT is one address per uid).
 *   • IPv6        → its /64 prefix, so privacy-address rotation collapses.
 *   • IPv4-mapped → the embedded IPv4 (all `::ffff:*` would otherwise share
 *                   the meaningless `::/64` bucket).
 *   • blank / "unknown" → `null` (no evidence, never a network).
 *   • unparseable non-empty text → its lower-cased self, so garbage cannot
 *     silently hide a fan-out.
 */
export function ipNetworkKey(ip: string): string | null {
  const bare = bareHost(ip ?? "");
  if (bare === "" || bare === "unknown") return null;

  const bytes = parseAddressBytes(bare);
  if (bytes === null) return bare.toLowerCase();

  if (bytes.length === 4) return bytes.join(".");

  if (bytes.length === 16) {
    // IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d): treat as
    // the embedded IPv4. The first ten bytes are zero in both forms.
    let zeroPrefix = true;
    for (let i = 0; i < 10; i++) {
      if (bytes[i] !== 0) {
        zeroPrefix = false;
        break;
      }
    }
    if (
      zeroPrefix &&
      ((bytes[10] === 0xff && bytes[11] === 0xff) ||
        (bytes[10] === 0 && bytes[11] === 0))
    ) {
      return bytes.slice(12).join(".");
    }

    const groups: string[] = [];
    for (let i = 0; i < 8; i += 2) {
      groups.push((((bytes[i]! << 8) | bytes[i + 1]!) >>> 0).toString(16));
    }
    return `${groups.join(":")}::/64`;
  }

  return bare.toLowerCase();
}

/**
 * Decide whether one uid's key should be blocked.
 *
 * The window is INCLUSIVE at both ends: `now - windowMs <= at <= now`.
 * Future timestamps and non-finite timestamps are ignored.
 *
 * Decision order (strongest evidence first):
 *   1. no in-window observations            → no block
 *   2. fewer than `minObservations`         → no block (volume floor)
 *   3. distinct ASNs > `maxDistinctAsns`    → block (ASN fan-out)
 *   4. no ASN data AND distinct networks
 *      > `maxDistinctNetworks`              → block (network fan-out)
 *   5. otherwise                            → no block
 */
export function evaluateIpAnomaly(
  observations: readonly IpObservation[],
  now: number,
  policy: IpAnomalyPolicy = DEFAULT_IP_ANOMALY_POLICY,
): IpAnomalyDecision {
  const cutoff = now - policy.windowMs;
  const inWindow = observations.filter(
    (o) => Number.isFinite(o.at) && o.at >= cutoff && o.at <= now,
  );

  if (inWindow.length === 0) {
    return { block: false, reason: "no_observations" };
  }
  if (inWindow.length < policy.minObservations) {
    return { block: false, reason: "below_min_observations" };
  }

  const asns = new Set<string>();
  const networks = new Set<string>();
  let hasAsn = false;

  for (const observation of inWindow) {
    const asn = normalizeAsn(observation.asn);
    if (asn !== null) {
      hasAsn = true;
      asns.add(asn);
    }
    const network = ipNetworkKey(observation.ip);
    if (network !== null) networks.add(network);
  }

  if (asns.size > policy.maxDistinctAsns) {
    return { block: true, reason: "asn_fanout" };
  }

  // Only when the edge gave us NO ASN evidence. With ASN data present, many
  // networks inside a few ASNs is normal carrier behaviour, not an attack.
  if (!hasAsn && networks.size > policy.maxDistinctNetworks) {
    return { block: true, reason: "network_fanout" };
  }

  return { block: false, reason: "within_thresholds" };
}
