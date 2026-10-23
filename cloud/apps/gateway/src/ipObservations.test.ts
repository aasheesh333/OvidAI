import { describe, expect, it } from "vitest";
import { evaluateIpAnomaly, type IpObservation } from "./anomaly.js";
import {
  IP_OBSERVATION_KEY_PREFIX,
  IP_OBSERVATION_MAX_ENTRIES,
  createIpObservationStore,
  parseIpObservationMember,
} from "./ipObservations.js";

/**
 * Observation store contract. A sorted set per uid scores each observation
 * by epoch ms, so trimming is O(log n) and the window is exact. These tests
 * use an in-memory ZSET fake — no redis server required.
 */

const NOW = Date.parse("2026-10-23T12:00:00.000Z");
const WINDOW = 10 * 60 * 1000;

interface FakeRedis {
  sets: Map<string, Map<string, number>>;
  expirations: Map<string, number>;
  zadd(key: string, score: number, member: string): Promise<number>;
  zremrangebyscore(
    key: string,
    min: string | number,
    max: string | number,
  ): Promise<number>;
  zremrangebyrank(key: string, start: number, stop: number): Promise<number>;
  zrangebyscore(
    key: string,
    min: string | number,
    max: string | number,
  ): Promise<string[]>;
  expire(key: string, seconds: number): Promise<number>;
}

function bound(value: string | number): number {
  if (value === "+inf" || value === "+Infinity") return Infinity;
  if (value === "-inf" || value === "-Infinity") return -Infinity;
  return Number(value);
}

function fakeRedis(): FakeRedis {
  const sets = new Map<string, Map<string, number>>();
  const expirations = new Map<string, number>();
  const sorted = (key: string): Array<[string, number]> => {
    const set = sets.get(key);
    if (set === undefined) return [];
    return [...set.entries()].sort((a, b) => a[1] - b[1] || a[0].localeCompare(b[0]));
  };
  return {
    sets,
    expirations,
    async zadd(key, score, member) {
      let set = sets.get(key);
      if (set === undefined) {
        set = new Map();
        sets.set(key, set);
      }
      const existed = set.has(member);
      set.set(member, Number(score));
      return existed ? 0 : 1;
    },
    async zremrangebyscore(key, min, max) {
      const set = sets.get(key);
      if (set === undefined) return 0;
      const lo = bound(min);
      const hi = bound(max);
      let removed = 0;
      for (const [member, score] of [...set.entries()]) {
        if (score >= lo && score <= hi) {
          set.delete(member);
          removed += 1;
        }
      }
      return removed;
    },
    async zremrangebyrank(key, start, stop) {
      const rows = sorted(key);
      const len = rows.length;
      const from = start < 0 ? Math.max(0, len + start) : start;
      const to = stop < 0 ? len + stop : stop;
      if (from > to) return 0;
      let removed = 0;
      for (let i = from; i <= Math.min(to, len - 1); i += 1) {
        sets.get(key)!.delete(rows[i]![0]);
        removed += 1;
      }
      return removed;
    },
    async zrangebyscore(key, min, max) {
      const lo = bound(min);
      const hi = bound(max);
      return sorted(key)
        .filter(([, score]) => score >= lo && score <= hi)
        .map(([member]) => member);
    },
    async expire(key, seconds) {
      expirations.set(key, seconds);
      return 1;
    },
  };
}

function observation(ip: string, at: number, asn: string | null = null): IpObservation {
  return { ip, asn, at };
}

describe("createIpObservationStore", () => {
  it("records observations under the uid key and returns the in-window set", async () => {
    const redis = fakeRedis();
    const store = createIpObservationStore(redis, { windowMs: WINDOW });
    const uid = "uid-1";

    await store.record(uid, observation("203.0.113.1", NOW - 1000));
    const window = await store.record(uid, observation("203.0.113.2", NOW));

    expect(redis.sets.has(`${IP_OBSERVATION_KEY_PREFIX}${uid}`)).toBe(true);
    expect(window).toEqual([
      { ip: "203.0.113.1", asn: null, at: NOW - 1000 },
      { ip: "203.0.113.2", asn: null, at: NOW },
    ]);
    // The window is refreshed on every record.
    expect(redis.expirations.get(`${IP_OBSERVATION_KEY_PREFIX}${uid}`)).toBe(
      Math.ceil(WINDOW / 1000) + 60,
    );
  });

  it("trims observations older than the policy window", async () => {
    const redis = fakeRedis();
    const store = createIpObservationStore(redis, { windowMs: WINDOW });
    const uid = "uid-trim";

    await store.record(uid, observation("203.0.113.1", NOW - WINDOW - 1));
    await store.record(uid, observation("203.0.113.2", NOW - WINDOW)); // inclusive
    await store.record(uid, observation("203.0.113.3", NOW));

    expect(await store.read(uid, NOW)).toEqual([
      { ip: "203.0.113.2", asn: null, at: NOW - WINDOW },
      { ip: "203.0.113.3", asn: null, at: NOW },
    ]);
  });

  it("caps stored entries so one noisy uid cannot grow unbounded", async () => {
    const redis = fakeRedis();
    const store = createIpObservationStore(redis, {
      windowMs: WINDOW,
      maxEntries: 5,
    });
    for (let i = 0; i < 10; i += 1) {
      await store.record("uid-cap", observation(`203.0.113.${i + 1}`, NOW - 10 + i));
    }
    const rows = await store.read("uid-cap", NOW);
    expect(rows).toHaveLength(5);
    // Newest kept.
    expect(rows.map((r) => r.ip)).toEqual([
      "203.0.113.6",
      "203.0.113.7",
      "203.0.113.8",
      "203.0.113.9",
      "203.0.113.10",
    ]);
  });

  it("normal mobile traffic (2 IPs, many requests) never blocks", async () => {
    const store = createIpObservationStore(fakeRedis(), { windowMs: WINDOW });
    let latest: IpObservation[] = [];
    for (let i = 0; i < 60; i += 1) {
      latest = await store.record(
        "uid-mobile",
        observation(i % 2 === 0 ? "198.51.100.7" : "198.51.100.9", NOW - i * 1000),
      );
    }
    expect(evaluateIpAnomaly(latest, NOW)).toEqual({
      block: false,
      reason: "within_thresholds",
    });
  });

  it("a fan-out across many distinct networks blocks (the no-ASN fallback)", async () => {
    const store = createIpObservationStore(fakeRedis(), { windowMs: WINDOW });
    let latest: IpObservation[] = [];
    for (let i = 0; i < 13; i += 1) {
      latest = await store.record(
        "uid-fanout",
        observation(`198.51.100.${i + 1}`, NOW - i * 1000),
      );
    }
    expect(evaluateIpAnomaly(latest, NOW)).toEqual({
      block: true,
      reason: "network_fanout",
    });
  });

  it("defaults the cap to a bounded constant", () => {
    expect(IP_OBSERVATION_MAX_ENTRIES).toBeGreaterThan(0);
    expect(IP_OBSERVATION_MAX_ENTRIES).toBeLessThanOrEqual(10_000);
  });
});

describe("parseIpObservationMember", () => {
  it("round-trips a valid member and rejects malformed ones", () => {
    const raw = JSON.stringify({
      ip: "203.0.113.1",
      asn: "AS64500",
      at: NOW,
      n: "nonce",
    });
    expect(parseIpObservationMember(raw)).toEqual({
      ip: "203.0.113.1",
      asn: "AS64500",
      at: NOW,
    });
    expect(parseIpObservationMember("not json")).toBeNull();
    expect(parseIpObservationMember(JSON.stringify({ ip: 1, at: NOW }))).toBeNull();
    expect(parseIpObservationMember(JSON.stringify({ ip: "x", at: "soon" }))).toBeNull();
    expect(parseIpObservationMember(null)).toBeNull();
  });
});
