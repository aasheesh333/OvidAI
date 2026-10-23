import { afterEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import type { Db } from "@ovid/db";
import { buildGateway } from "../app.js";
import { createIpAnomalyGuard } from "../ipAnomalyGuard.js";
import {
  createIpObservationStore,
  type IpObservationRedis,
} from "../ipObservations.js";
import { authHeaders, noopEvents, stubKeys, stubMint, stubQueues, stubSystemBus, stubTickets, stubVerifier } from "../test/stubs.js";

const NOW = Date.parse("2026-10-23T12:00:00.000Z");
const WINDOW = 10 * 60 * 1000;

function fakeRedis(): IpObservationRedis {
  const sets = new Map<string, Map<string, number>>();
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
      const set = sets.get(key);
      if (set === undefined) return 0;
      const rows = [...set.entries()].sort((a, b) => a[1] - b[1]);
      const len = rows.length;
      const from = start < 0 ? Math.max(0, len + start) : start;
      const to = stop < 0 ? len + stop : stop;
      for (let i = from; i <= Math.min(to, len - 1); i += 1) set.delete(rows[i]![0]);
      return Math.max(0, Math.min(to, len - 1) - from + 1);
    },
    async zrangebyscore(key, min, max) {
      const lo = min === "-inf" ? -Infinity : Number(min);
      const hi = max === "+inf" ? Infinity : Number(max);
      const set = sets.get(key);
      if (set === undefined) return [];
      return [...set.entries()]
        .filter(([, score]) => score >= lo && score <= hi)
        .sort((a, b) => a[1] - b[1])
        .map(([member]) => member);
    },
    async expire() {
      return 1;
    },
  };
}

/**
 * Admission runs BEFORE the database. A blocked send must therefore never
 * touch the db, mint or the queue. The db below throws on ANY property read:
 * if the route reaches it, the test fails with a 500 instead of the typed
 * 403 the contract requires.
 */
function forbiddenDb(): Db {
  return new Proxy(
    {},
    {
      get() {
        throw new Error("db must not be touched by a blocked send");
      },
    },
  ) as unknown as Db;
}

describe("send admission — IP anomaly", () => {
  const built: FastifyInstance[] = [];

  afterEach(async () => {
    while (built.length > 0) await built.pop()!.close();
  });

  function makeApp(guard: ReturnType<typeof createIpAnomalyGuard>) {
    const { queues, adds } = stubQueues();
    const mint = stubMint();
    const app = buildGateway({
      db: forbiddenDb(),
      queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint,
      events: noopEvents,
      system: stubSystemBus(),
      ipAnomaly: guard,
    });
    built.push(app);
    return { app, adds, mint };
  }

  it("a fan-out refuses the send with a typed 403 before any work", async () => {
    const uid = "uid-route-fanout";
    const store = createIpObservationStore(fakeRedis(), { windowMs: WINDOW });
    for (let i = 0; i < 13; i += 1) {
      await store.record(uid, {
        ip: `198.51.100.${i + 1}`,
        asn: null,
        at: NOW - i * 1000,
      });
    }
    const guard = createIpAnomalyGuard({
      store,
      now: () => NOW,
      trustedProxyCidrs: ["127.0.0.0/8"],
    });
    const { app, adds, mint } = makeApp(guard);

    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/sessions/00000000-0000-4000-8000-000000000001/messages",
      headers: {
        ...authHeaders(uid),
        "x-forwarded-for": "203.0.113.200",
      },
      remoteAddress: "127.0.0.1",
      payload: { content: "should never run" },
    });

    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({
      error: {
        code: "ip_anomaly_blocked",
        message: expect.stringContaining("unusual network activity"),
      },
    });
    expect(adds).toEqual([]);
    expect(mint.calls).toEqual([]);
  });

  it("an untrusted peer cannot spoof its way past the check", async () => {
    // The peer itself is the observed address; the XFF value naming a fresh
    // network is ignored, so this request adds NO new network.
    const uid = "uid-route-untrusted";
    const store = createIpObservationStore(fakeRedis(), { windowMs: WINDOW });
    for (let i = 0; i < 11; i += 1) {
      await store.record(uid, {
        ip: `198.51.100.${i + 1}`,
        asn: null,
        at: NOW - i * 1000,
      });
    }
    // The peer is already one of the 12 known networks, so the request stays
    // at 12 distinct networks (the limit) and is NOT blocked. It then reaches
    // the db (forbidden), proving admission let it through.
    await store.record(uid, { ip: "203.0.113.9", asn: null, at: NOW - 30_000 });
    const guard = createIpAnomalyGuard({
      store,
      now: () => NOW,
      trustedProxyCidrs: ["127.0.0.0/8"],
    });
    const { app } = makeApp(guard);

    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/sessions/00000000-0000-4000-8000-000000000001/messages",
      headers: {
        ...authHeaders(uid),
        "x-forwarded-for": "192.0.2.44", // a 13th network, if it were trusted
      },
      remoteAddress: "203.0.113.9",
      payload: { content: "peer address only" },
    });

    // The block did NOT fire; the request proceeded to the (forbidden) db.
    expect(res.statusCode).toBe(500);
    const recorded = await store.read(uid, NOW);
    expect(recorded.filter((o) => o.ip === "203.0.113.9")).toHaveLength(2);
    expect(recorded.some((o) => o.ip === "192.0.2.44")).toBe(false);
  });
});
