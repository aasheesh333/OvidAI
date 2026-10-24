import { createHmac } from "node:crypto";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { Redis } from "ioredis";
import { users, type Db } from "@ovid/db";
import { buildGateway, type GatewayDeps } from "../app.js";
import {
  createIpAnomalyGuard,
  createIpAnomalySuspension,
} from "../ipAnomalyGuard.js";
import { createSuspensionMailer } from "../suspensionMailer.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "../test/db.js";
import {
  createIpObservationStore,
  type IpObservationRedis,
} from "../ipObservations.js";
import { authHeaders, noopEvents, stubKeys, stubMint, stubQueues, stubSystemBus, stubTickets, stubVerifier } from "../test/stubs.js";

const NOW = Date.parse("2026-10-23T12:00:00.000Z");
const WINDOW = 10 * 60 * 1000;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

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

  function makeApp(
    guard: ReturnType<typeof createIpAnomalyGuard>,
    extra: Partial<GatewayDeps> = {},
  ) {
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
      ...extra,
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

  it.each([
    {
      name: "direct client",
      remoteAddress: "203.0.113.200",
      forwardedFor: "192.0.2.44",
      expectedIp: "203.0.113.200",
    },
    {
      name: "trusted proxy without a verified signature",
      remoteAddress: "127.0.0.1",
      forwardedFor: "203.0.113.200",
      expectedIp: "203.0.113.200",
    },
  ])("unsigned x-ovid-edge-asn from a $name cannot suppress the multi-IP block", async (testCase) => {
    const uid = `uid-unsigned-asn-${testCase.name.replaceAll(" ", "-")}`;
    const store = createIpObservationStore(fakeRedis(), { windowMs: WINDOW });
    for (let index = 0; index < 12; index += 1) {
      await store.record(uid, {
        ip: `198.51.100.${index + 1}`,
        asn: null,
        at: NOW - index * 1000,
      });
    }
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
        "x-forwarded-for": testCase.forwardedFor,
        "x-ovid-edge-asn": "AS64500",
      },
      remoteAddress: testCase.remoteAddress,
      payload: { content: "unsigned ASN must not suppress fanout" },
    });

    expect(res.statusCode).toBe(403);
    expect(res.json().error.code).toBe("ip_anomaly_blocked");
    const current = (await store.read(uid, NOW)).find(
      (observation) => observation.ip === testCase.expectedIp && observation.at === NOW,
    );
    expect(current).toEqual({ ip: testCase.expectedIp, asn: null, at: NOW });
  });

  it("uses signed Cloudflare network metadata for anomaly observation, never spoofed XFF", async () => {
    const secret = "anomaly-edge-test-secret-at-least-32-bytes";
    const nowSeconds = Math.floor(NOW / 1000);
    const requestId = "anomaly-edge-request";
    const ip = "198.51.100.76";
    const asn = "AS64500";
    const authorization = "Bearer test:uid-signed-edge";
    const appCheck = "app-check-stub";
    const signature = createHmac("sha256", secret)
      .update(
        `EDGE\n${nowSeconds}\n${requestId}\nsend\n${ip}\n${asn}\n${authorization}\n${appCheck}`,
      )
      .digest("hex");
    let observed: unknown;
    const guard = {
      async admit(_uid: string, context: unknown) {
        observed = context;
        return { block: true as const, reason: "network_fanout" as const };
      },
    };
    const { app } = makeApp(guard, {
      rateLimiter: {
        async consume() {
          return { allowed: true, retryAfterSeconds: 0, scope: "uid+ip" };
        },
      },
      rateLimitInternalSecret: secret,
      clock: () => new Date(NOW),
    });

    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/sessions/00000000-0000-4000-8000-000000000001/messages",
      headers: {
        authorization,
        "x-firebase-appcheck": appCheck,
        "x-forwarded-for": "192.0.2.200",
        "x-ovid-edge-request-id": requestId,
        "x-ovid-edge-ip": ip,
        "x-ovid-edge-asn": asn,
        "x-ovid-edge-timestamp": String(nowSeconds),
        "x-ovid-edge-signature": signature,
      },
      remoteAddress: "127.0.0.1",
      payload: { content: "blocked before DB" },
    });
    expect(res.statusCode).toBe(403);
    expect(observed).toMatchObject({ edge: { ip, asn } });
  });
});

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)(
  "automatic multi-IP suspension (isolated real Postgres and Redis)",
  () => {
    let db: Db;
    let redis: Redis;
    const built: FastifyInstance[] = [];

    beforeAll(async () => {
      db = await openTestDb();
      redis = new Redis(TEST_REDIS_URL!);
    }, 60_000);

    afterEach(async () => {
      while (built.length > 0) await built.pop()!.close();
    });

    afterAll(async () => {
      redis.disconnect();
      await closeDb(db);
    });

    async function seedFanout(uid: string) {
      const store = createIpObservationStore(redis, {
        keyPrefix: `ovid:test:ipobs:${uid}:`,
        windowMs: WINDOW,
      });
      for (let index = 0; index < 13; index += 1) {
        await store.record(uid, {
          ip: `198.51.100.${index + 1}`,
          asn: null,
          at: NOW - index * 1000,
        });
      }
      return store;
    }

    function appForGuard(guard: ReturnType<typeof createIpAnomalyGuard>) {
      const app = buildGateway({
        db,
        queues: stubQueues().queues,
        verifier: stubVerifier(),
        tickets: stubTickets(),
        keys: stubKeys(),
        mint: stubMint(),
        events: noopEvents,
        system: stubSystemBus(),
        ipAnomaly: guard,
      });
      built.push(app);
      return app;
    }

    async function postBlocked(app: FastifyInstance, uid: string) {
      return app.inject({
        method: "POST",
        url: "/cloud/v1/sessions/00000000-0000-4000-8000-000000000001/messages",
        headers: { ...authHeaders(uid), "x-forwarded-for": "203.0.113.200" },
        remoteAddress: "127.0.0.1",
        payload: { content: "must remain blocked" },
      });
    }

    it("persists standing and blocks every live key BEFORE registered-email delivery", async () => {
      const uid = testUid("anomaly-order");
      await users.ensure(db, uid, "registered-owner@example.test");
      const store = await seedFanout(uid);
      const order: string[] = [];
      const mailInputs: Array<Record<string, unknown>> = [];
      const standing = async () => {
        const rows = await db.$client`
          SELECT banned_at IS NOT NULL AS banned, banned_reason AS reason
          FROM users WHERE uid = ${uid}`;
        return rows[0] as { banned: boolean; reason: string | null };
      };
      const keyAdmin = {
        async listKeys(keyUid: string) {
          expect(keyUid).toBe(uid);
          expect((await standing()).banned).toBe(true);
          order.push("keys:list");
          return ["live-android-key", "live-web-key"];
        },
        async keyBlock(key: string) {
          expect((await standing()).banned).toBe(true);
          order.push(`keys:block:${key}`);
          return 200;
        },
      };
      const suspension = createIpAnomalySuspension({
        db,
        redis,
        keyAdmin,
        now: () => new Date(NOW),
        mailer: {
          async send(input) {
            expect((await standing()).banned).toBe(true);
            expect(order).toEqual([
              "keys:list",
              "keys:block:live-android-key",
              "keys:block:live-web-key",
            ]);
            order.push("mail");
            mailInputs.push(input as unknown as Record<string, unknown>);
            return "sent";
          },
        },
      });
      const guard = createIpAnomalyGuard({
        store,
        suspension,
        now: () => NOW,
        trustedProxyCidrs: ["127.0.0.0/8"],
      });
      const app = appForGuard(guard);

      const res = await postBlocked(app, uid);
      expect(res.statusCode).toBe(403);
      expect(res.json().error.code).toBe("ip_anomaly_blocked");
      expect(order).toEqual([
        "keys:list",
        "keys:block:live-android-key",
        "keys:block:live-web-key",
        "mail",
      ]);
      expect(await standing()).toEqual({ banned: true, reason: "auto" });
      await expect(redis.get(`user:${uid}:banned`)).resolves.toBe("auto");
      expect(mailInputs).toEqual([
        {
          uid,
          blockId: `anomaly:${uid}:${Math.floor(NOW / WINDOW)}:network_fanout`,
          registeredEmail: "registered-owner@example.test",
        },
      ]);
      expect(JSON.stringify(mailInputs)).not.toContain(`${uid}@stub.test`);
    });

    it("mail failure leaves the real block intact and leaks no provider payload", async () => {
      const uid = testUid("anomaly-mail-failure");
      await users.ensure(db, uid, "registered-owner@example.test");
      const store = await seedFanout(uid);
      const blockedKeys: string[] = [];
      const secret = "raw-mail-provider-secret-canary";
      const suspension = createIpAnomalySuspension({
        db,
        redis,
        keyAdmin: {
          async listKeys() {
            return ["live-key"];
          },
          async keyBlock(key) {
            blockedKeys.push(key);
            return 200;
          },
        },
        mailer: createSuspensionMailer({
          apiKey: "test-provider-secret",
          from: "security@ovid.example",
          fetchImpl: async () => new Response(JSON.stringify({ error: secret }), { status: 500 }),
        }),
        now: () => new Date(NOW),
      });
      const guard = createIpAnomalyGuard({
        store,
        suspension,
        now: () => NOW,
        trustedProxyCidrs: ["127.0.0.0/8"],
      });
      const app = appForGuard(guard);

      const res = await postBlocked(app, uid);
      expect(res.statusCode).toBe(403);
      expect(res.body).not.toContain(secret);
      expect(blockedKeys).toEqual(["live-key"]);
      await expect(redis.get(`user:${uid}:banned`)).resolves.toBe("auto");
      const rows = await db.$client`
        SELECT banned_at IS NOT NULL AS banned FROM users WHERE uid = ${uid}`;
      expect(rows[0]!.banned).toBe(true);
    });

    it("a missing registered email performs no provider send and never uses the token email", async () => {
      const uid = testUid("anomaly-no-registered-email");
      await users.ensure(db, uid, null);
      let providerCalls = 0;
      const suspension = createIpAnomalySuspension({
        db,
        redis,
        keyAdmin: {
          async listKeys() {
            return [];
          },
          async keyBlock() {
            return 200;
          },
        },
        mailer: createSuspensionMailer({
          apiKey: "test-provider-secret",
          from: "security@ovid.example",
          fetchImpl: async () => {
            providerCalls += 1;
            return new Response("{}", { status: 200 });
          },
        }),
        now: () => new Date(NOW),
      });

      const result = await suspension.suspend({
        uid,
        blockId: `anomaly:${uid}:${Math.floor(NOW / WINDOW)}:network_fanout`,
        reason: "network_fanout",
      });
      expect(result.mailOutcome).toBe("not_configured");
      expect(providerCalls).toBe(0);
      await expect(redis.get(`user:${uid}:banned`)).resolves.toBe("auto");
    });
  },
);
