import { describe, expect, it } from "vitest";
import {
  DEFAULT_IP_ANOMALY_POLICY,
  evaluateIpAnomaly,
  ipNetworkKey,
  normalizeAsn,
  type IpAnomalyPolicy,
  type IpObservation,
} from "./anomaly.js";

/**
 * These tests pin the FALSE-POSITIVE-AVERSE contract. Every case below is a
 * pattern a real paying customer can produce on a phone; the detector must
 * stay quiet. The one case that blocks is a fan-out across many distinct
 * autonomous systems, which no single human's device handoff produces.
 */

const NOW = Date.parse("2026-10-23T12:00:00.000Z");
const MIN = 60_000;

function obs(
  ip: string,
  asn: string | number | null,
  at: number = NOW,
): IpObservation {
  return { ip, asn, at };
}

/** `n` distinct ASNs, each repeated `reps` times, all inside the window. */
function asnFanout(n: number, reps = 2): IpObservation[] {
  const out: IpObservation[] = [];
  for (let i = 0; i < n; i++) {
    for (let r = 0; r < reps; r++) {
      out.push(obs(`203.0.113.${i + 1}`, `AS${1000 + i}`, NOW - r * 1000));
    }
  }
  return out;
}

/** `n` distinct IPv4 networks, no ASN data at all. */
function networkFanout(n: number, reps = 2): IpObservation[] {
  const out: IpObservation[] = [];
  for (let i = 0; i < n; i++) {
    for (let r = 0; r < reps; r++) {
      out.push(obs(`198.51.100.${i + 1}`, null, NOW - r * 1000));
    }
  }
  return out;
}

/** One RFC 4941 privacy address per call, all inside the SAME /64. */
function ipv6Rotation(count: number, asn: string | null): IpObservation[] {
  const out: IpObservation[] = [];
  for (let i = 0; i < count; i++) {
    const tail = (0x1000 + i).toString(16).padStart(4, "0");
    out.push(
      obs(`2001:db8:abcd:1234:aaaa:bbbb:cccc:${tail}`, asn, NOW - i * 1000),
    );
  }
  return out;
}

describe("evaluateIpAnomaly", () => {
  it("an empty observation set never blocks", () => {
    expect(evaluateIpAnomaly([], NOW)).toEqual({
      block: false,
      reason: "no_observations",
    });
  });

  it("observations entirely outside the window are treated as empty", () => {
    const outside = Array.from({ length: 20 }, (_, i) =>
      obs(`203.0.113.${i + 1}`, `AS${i}`, NOW - DEFAULT_IP_ANOMALY_POLICY.windowMs - 1),
    );
    expect(evaluateIpAnomaly(outside, NOW)).toEqual({
      block: false,
      reason: "no_observations",
    });
  });

  it("normal mobile↔WiFi handoff (2 IPs, 2 ASNs, high volume) never blocks", () => {
    const samples: IpObservation[] = [
      ...Array.from({ length: 60 }, (_, i) =>
        obs("198.51.100.7", "AS64500", NOW - i * 1000),
      ),
      ...Array.from({ length: 40 }, (_, i) =>
        obs("198.51.100.9", "AS64501", NOW - i * 1000),
      ),
    ];
    expect(evaluateIpAnomaly(samples, NOW)).toEqual({
      block: false,
      reason: "within_thresholds",
    });
  });

  it("carrier NAT (many requests from one shared IP) never blocks", () => {
    const samples = Array.from({ length: 200 }, () =>
      obs("198.51.100.7", "AS64500"),
    );
    expect(evaluateIpAnomaly(samples, NOW).block).toBe(false);
  });

  it("IPv6 privacy-address rotation in one /64 never blocks (with ASN data)", () => {
    const decision = evaluateIpAnomaly(ipv6Rotation(30, "AS64500"), NOW);
    expect(decision.block).toBe(false);
    expect(decision.reason).toBe("within_thresholds");
  });

  it("IPv6 privacy-address rotation in one /64 never blocks (without ASN data)", () => {
    // The network fallback must collapse the rotating interface identifiers.
    const decision = evaluateIpAnomaly(ipv6Rotation(30, null), NOW);
    expect(decision.block).toBe(false);
    expect(decision.reason).toBe("within_thresholds");
  });

  it("a genuine fan-out across many distinct ASNs blocks", () => {
    const decision = evaluateIpAnomaly(asnFanout(8), NOW);
    expect(decision.block).toBe(true);
    expect(decision.reason).toBe("asn_fanout");
  });

  it("the ASN threshold is hard to trip: the maximum is allowed, one more blocks", () => {
    const allowed = DEFAULT_IP_ANOMALY_POLICY.maxDistinctAsns; // 6
    expect(evaluateIpAnomaly(asnFanout(allowed, 3), NOW).block).toBe(false);
    expect(evaluateIpAnomaly(asnFanout(allowed + 1, 3), NOW).block).toBe(true);
  });

  it("a low-volume burst below the observation floor never blocks", () => {
    // 7 distinct ASNs but only 7 observations: below minObservations (10).
    const decision = evaluateIpAnomaly(asnFanout(7, 1), NOW);
    expect(decision.block).toBe(false);
    expect(decision.reason).toBe("below_min_observations");
  });

  it("the window start is inclusive and the future is excluded", () => {
    const policy: IpAnomalyPolicy = {
      ...DEFAULT_IP_ANOMALY_POLICY,
      minObservations: 1,
      maxDistinctAsns: 1,
    };
    const boundary = NOW - policy.windowMs;

    // AS1 exactly on the boundary is INSIDE: two ASNs > max 1.
    expect(
      evaluateIpAnomaly(
        [obs("203.0.113.1", "AS1", boundary), obs("203.0.113.2", "AS2", NOW)],
        NOW,
        policy,
      ),
    ).toEqual({ block: true, reason: "asn_fanout" });

    // 1 ms earlier is OUTSIDE: only AS2 remains, so no block.
    expect(
      evaluateIpAnomaly(
        [obs("203.0.113.1", "AS1", boundary - 1), obs("203.0.113.2", "AS2", NOW)],
        NOW,
        policy,
      ),
    ).toEqual({ block: false, reason: "within_thresholds" });

    // A future timestamp is OUTSIDE too.
    expect(
      evaluateIpAnomaly(
        [obs("203.0.113.1", "AS1", NOW + 1), obs("203.0.113.2", "AS2", NOW)],
        NOW,
        policy,
      ),
    ).toEqual({ block: false, reason: "within_thresholds" });
  });

  it("when no ASN is available, many distinct networks block (fallback)", () => {
    const max = DEFAULT_IP_ANOMALY_POLICY.maxDistinctNetworks; // 12
    expect(evaluateIpAnomaly(networkFanout(max), NOW).block).toBe(false);
    const decision = evaluateIpAnomaly(networkFanout(max + 1), NOW);
    expect(decision.block).toBe(true);
    expect(decision.reason).toBe("network_fanout");
  });

  it("network fan-out does not override trustworthy ASN data", () => {
    // A carrier rotating /64s while the ASN stays constant is legitimate.
    // With ASN data present the network fallback must stay OFF, or this
    // would falsely suspend a customer on mobile data.
    const samples = Array.from({ length: 20 }, (_, i) =>
      obs(`2001:db8:${i.toString(16)}:1::1`, "AS64500", NOW - i * 1000),
    );
    expect(evaluateIpAnomaly(samples, NOW)).toEqual({
      block: false,
      reason: "within_thresholds",
    });
  });

  it("unknown or blank IPs never count as networks", () => {
    const samples = Array.from({ length: 20 }, () => obs("unknown", null));
    expect(evaluateIpAnomaly(samples, NOW)).toEqual({
      block: false,
      reason: "within_thresholds",
    });
    expect(ipNetworkKey("unknown")).toBeNull();
    expect(ipNetworkKey("   ")).toBeNull();
  });

  it("invalid timestamps are ignored", () => {
    const samples = Array.from({ length: 20 }, (_, i) =>
      obs(`203.0.113.${i + 1}`, `AS${i}`, Number.NaN),
    );
    expect(evaluateIpAnomaly(samples, NOW)).toEqual({
      block: false,
      reason: "no_observations",
    });
  });
});

describe("normalizeAsn", () => {
  it("collapses the numeric and prefixed spellings of one ASN", () => {
    expect(normalizeAsn("AS64500")).toBe("AS64500");
    expect(normalizeAsn("as64500")).toBe("AS64500");
    expect(normalizeAsn("  AS64500  ")).toBe("AS64500");
    expect(normalizeAsn(64500)).toBe("AS64500");
  });

  it("treats missing, blank and non-finite values as unknown", () => {
    expect(normalizeAsn(null)).toBeNull();
    expect(normalizeAsn(undefined)).toBeNull();
    expect(normalizeAsn("")).toBeNull();
    expect(normalizeAsn("   ")).toBeNull();
    expect(normalizeAsn(Number.NaN)).toBeNull();
    expect(normalizeAsn(-1)).toBeNull();
  });
});

describe("ipNetworkKey", () => {
  it("collapses IPv6 interface identifiers into one /64", () => {
    expect(ipNetworkKey("2001:db8:abcd:1234:aaaa:bbbb:cccc:0001")).toBe(
      "2001:db8:abcd:1234::/64",
    );
    expect(ipNetworkKey("2001:db8:abcd:1234:ffff:eeee:dddd:0002")).toBe(
      "2001:db8:abcd:1234::/64",
    );
  });

  it("keeps distinct IPv4 addresses distinct and unwraps IPv4-mapped IPv6", () => {
    expect(ipNetworkKey("203.0.113.1")).toBe("203.0.113.1");
    expect(ipNetworkKey("203.0.113.2")).toBe("203.0.113.2");
    expect(ipNetworkKey("::ffff:203.0.113.1")).toBe("203.0.113.1");
  });
});
