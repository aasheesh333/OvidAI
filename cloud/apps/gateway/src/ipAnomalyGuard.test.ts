import { describe, expect, it } from "vitest";
import type { IpObservation } from "./anomaly.js";
import { createIpAnomalyGuard } from "./ipAnomalyGuard.js";
import {
  createIpObservationStore,
  type IpObservationRedis,
  type IpObservationStore,
} from "./ipObservations.js";

const NOW = Date.parse("2026-10-23T12:00:00.000Z");
const WINDOW = 10 * 60 * 1000;

function fakeRedis(): IpObservationRedis {
  const sets = new Map<string, Map<string, number>>();
  const sorted = (key: string): Array<[string, number]> => {
    const set = sets.get(key);
    if (set === undefined) return [];
    return [...set.entries()].sort((a, b) => a[1] - b[1] || a[0].localeCompare(b[0]));
  };
  return {
    async zadd(key, score, member) {
      let set = sets.get(key);
      if (set === undefined) {
        set = new Map();
        sets.set(key, set);
      }
      set.set(member, Number(score));
      return 1;
    },
    async zremrangebyscore(key, min, max) {
      const lo = min === "-inf" ? -Infinity : Number(min);
      const hi = max === "+inf" ? Infinity : Number(max);
      const set = sets.get(key);
      if (set === undefined) return 0;
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
      let removed = 0;
      for (let i = from; i <= Math.min(to, len - 1); i += 1) {
        sets.get(key)!.delete(rows[i]![0]);
        removed += 1;
      }
      return removed;
    },
    async zrangebyscore(key, min, max) {
      const lo = min === "-inf" ? -Infinity : Number(min);
      const hi = max === "+inf" ? Infinity : Number(max);
      return sorted(key)
        .filter(([, score]) => score >= lo && score <= hi)
        .map(([member]) => member);
    },
    async expire() {
      return 1;
    },
  };
}

async function seed(store: IpObservationStore, uid: string, count: number) {
  for (let i = 0; i < count; i += 1) {
    await store.record(uid, {
      ip: `198.51.100.${i + 1}`,
      asn: null,
      at: NOW - i * 1000,
    });
  }
}

describe("createIpAnomalyGuard", () => {
  it("admits normal traffic and records the client IP from a trusted hop", async () => {
    const store = createIpObservationStore(fakeRedis(), { windowMs: WINDOW });
    const guard = createIpAnomalyGuard({
      store,
      now: () => NOW,
      trustedProxyCidrs: ["127.0.0.0/8"],
    });

    const decision = await guard.admit("uid-normal", {
      peerAddress: "127.0.0.1",
      forwardedFor: "203.0.113.7",
    });

    expect(decision.block).toBe(false);
    expect(await store.read("uid-normal", NOW)).toEqual([
      { ip: "203.0.113.7", asn: null, at: NOW },
    ]);
  });

  it("IGNORES an X-Forwarded-For header from an untrusted peer", async () => {
    const store = createIpObservationStore(fakeRedis(), { windowMs: WINDOW });
    const guard = createIpAnomalyGuard({
      store,
      now: () => NOW,
      trustedProxyCidrs: ["127.0.0.0/8"],
    });

    await guard.admit("uid-untrusted", {
      peerAddress: "203.0.113.9",
      forwardedFor: "198.51.100.1",
    });

    expect(await store.read("uid-untrusted", NOW)).toEqual([
      { ip: "203.0.113.9", asn: null, at: NOW },
    ]);
  });

  it("blocks once the window fans out across too many networks", async () => {
    const store = createIpObservationStore(fakeRedis(), { windowMs: WINDOW });
    await seed(store, "uid-fanout", 13);
    const guard = createIpAnomalyGuard({
      store,
      now: () => NOW,
      trustedProxyCidrs: ["127.0.0.0/8"],
    });

    const decision = await guard.admit("uid-fanout", {
      peerAddress: "127.0.0.1",
      forwardedFor: "203.0.113.200",
    });

    expect(decision).toEqual({ block: true, reason: "network_fanout" });
  });

  it("fails OPEN (and reports) when the observation store is unavailable", async () => {
    const errors: unknown[] = [];
    const broken: IpObservationStore = {
      async record() {
        throw new Error("redis down");
      },
      async read() {
        throw new Error("redis down");
      },
    };
    const guard = createIpAnomalyGuard({
      store: broken,
      now: () => NOW,
      onError: (err) => errors.push(err),
    });

    const decision = await guard.admit("uid-broken", {
      peerAddress: "127.0.0.1",
      forwardedFor: "203.0.113.7",
    });

    expect(decision).toEqual({ block: false, reason: "store_unavailable" });
    expect(errors).toHaveLength(1);
  });

  it("records an empty IP when the peer cannot be identified (no evidence)", async () => {
    const store = createIpObservationStore(fakeRedis(), { windowMs: WINDOW });
    const guard = createIpAnomalyGuard({ store, now: () => NOW });
    await guard.admit("uid-nopeer", { peerAddress: undefined });
    expect(await store.read("uid-nopeer", NOW)).toEqual<IpObservation[]>([
      { ip: "", asn: null, at: NOW },
    ]);
  });
});
