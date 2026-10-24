import { createHmac, randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { Redis } from "ioredis";
import type { FastifyInstance } from "fastify";
import type { Db } from "@ovid/db";
import {
  createRateLimiter,
  rateLimitClassFor,
  type RateLimitClass,
  type RateLimitConsume,
  type RateLimiter,
} from "./rateLimits.js";
import { buildGateway } from "./app.js";
import {
  authHeaders,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubSystemBus,
  stubTickets,
  stubVerifier,
} from "./test/stubs.js";

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;
const KEY_PREFIX = `ovid:test:ratelimit:${randomUUID()}:`;
const SECRET = "task9-test-only-rate-limit-secret-at-least-32-bytes";
const NOW = Date.parse("2026-10-24T12:00:00.000Z");
const SESSION = "00000000-0000-4000-8000-000000000001";

const CAPACITIES: ReadonlyArray<{
  className: RateLimitClass;
  uid: number;
  ip: number;
  windowSeconds: number;
}> = [
  { className: "send", uid: 20, ip: 120, windowSeconds: 60 },
  { className: "ticket", uid: 30, ip: 180, windowSeconds: 60 },
  { className: "attachments", uid: 60, ip: 360, windowSeconds: 60 },
  { className: "connections", uid: 20, ip: 120, windowSeconds: 60 },
  { className: "plugin_source", uid: 5, ip: 30, windowSeconds: 60 },
  { className: "preview", uid: 10, ip: 60, windowSeconds: 60 },
  { className: "voice", uid: 20, ip: 120, windowSeconds: 60 },
  { className: "collab_join", uid: 10, ip: 60, windowSeconds: 60 },
  { className: "turn", uid: 20, ip: 120, windowSeconds: 60 },
  { className: "poll", uid: 120, ip: 720, windowSeconds: 60 },
  { className: "shares", uid: 60, ip: 360, windowSeconds: 60 },
  { className: "admin", uid: 30, ip: 60, windowSeconds: 60 },
  { className: "default", uid: 300, ip: 1800, windowSeconds: 60 },
  { className: "reports", uid: 50, ip: 50, windowSeconds: 86_400 },
];

describe.skipIf(!TEST_REDIS_URL)("Redis rate limits (isolated real Redis)", () => {
  let redisA: Redis;
  let redisB: Redis;
  let limiterA: RateLimiter;
  let limiterB: RateLimiter;

  beforeAll(() => {
    redisA = new Redis(TEST_REDIS_URL!);
    redisB = new Redis(TEST_REDIS_URL!);
    limiterA = createRateLimiter(redisA, { keyPrefix: KEY_PREFIX });
    limiterB = createRateLimiter(redisB, { keyPrefix: KEY_PREFIX });
  });

  afterAll(() => {
    redisA.disconnect();
    redisB.disconnect();
  });

  it.each(CAPACITIES)(
    "$className enforces its exact UID and IP capacities concurrently across two instances",
    async ({ className, uid, ip, windowSeconds }) => {
      const uidReplies = await Promise.all(
        Array.from({ length: uid + 1 }, (_, index) =>
          (index % 2 === 0 ? limiterA : limiterB).consume({
            class: className,
            uid: `${className}-shared-uid`,
            ip: "203.0.113.10",
          }),
        ),
      );
      expect(uidReplies.filter((reply) => reply.allowed)).toHaveLength(uid);
      const uidDenied = uidReplies.filter((reply) => !reply.allowed);
      expect(uidDenied).toHaveLength(1);
      expect(uidDenied[0]).toMatchObject({ scope: "uid" });
      expect(uidDenied[0]!.retryAfterSeconds).toBeGreaterThan(0);
      expect(uidDenied[0]!.retryAfterSeconds).toBeLessThanOrEqual(windowSeconds);

      const ipReplies = await Promise.all(
        Array.from({ length: ip + 1 }, (_, index) =>
          (index % 2 === 0 ? limiterA : limiterB).consume({
            class: className,
            uid: `${className}-ip-test-uid-${index}`,
            ip: "198.51.100.10",
          }),
        ),
      );
      expect(ipReplies.filter((reply) => reply.allowed)).toHaveLength(ip);
      const ipDenied = ipReplies.filter((reply) => !reply.allowed);
      expect(ipDenied).toHaveLength(1);
      expect(ipDenied[0]).toMatchObject({ scope: "ip" });
      expect(ipDenied[0]!.retryAfterSeconds).toBeGreaterThan(0);
      expect(ipDenied[0]!.retryAfterSeconds).toBeLessThanOrEqual(windowSeconds);

      for (const decision of [...uidReplies, ...ipReplies]) {
        expect(Object.keys(decision).sort()).toEqual([
          "allowed",
          "retryAfterSeconds",
          "scope",
        ]);
        expect(JSON.stringify(decision)).not.toContain("token");
        expect(JSON.stringify(decision)).not.toContain("key");
      }
    },
    30_000,
  );

  it("puts every missing-identity-or-IP request into ONE conservative class bucket", async () => {
    const replies = await Promise.all(
      Array.from({ length: 21 }, (_, index) => {
        const limiter = index % 2 === 0 ? limiterA : limiterB;
        if (index % 3 === 0) return limiter.consume({ class: "send", uid: "known-uid" });
        if (index % 3 === 1) return limiter.consume({ class: "send", ip: "203.0.113.8" });
        return limiter.consume({ class: "send" });
      }),
    );

    expect(replies.filter((reply) => reply.allowed)).toHaveLength(20);
    const denied = replies.filter((reply) => !reply.allowed);
    expect(denied).toHaveLength(1);
    expect(denied[0]).toMatchObject({ allowed: false, scope: "unknown" });
    expect(denied[0]!.retryAfterSeconds).toBeGreaterThan(0);
  });

  it("an edge/gateway request id consumes the shared bucket exactly once", async () => {
    const input: RateLimitConsume = {
      class: "send",
      uid: "edge-gateway-once",
      ip: "203.0.113.77",
      requestId: "request-edge-gateway-once",
    };
    const first = await limiterA.consume(input);
    const replay = await limiterB.consume(input);
    expect(first).toEqual({ allowed: true, retryAfterSeconds: 0, scope: "uid+ip" });
    expect(replay).toEqual(first);

    const rest = await Promise.all(
      Array.from({ length: 20 }, (_, index) =>
        (index % 2 === 0 ? limiterA : limiterB).consume({
          class: "send",
          uid: input.uid,
          ip: input.ip,
          requestId: `request-edge-gateway-${index}`,
        }),
      ),
    );
    expect(rest.filter((reply) => reply.allowed)).toHaveLength(19);
    expect(rest.filter((reply) => !reply.allowed)).toHaveLength(1);
  });

  it("a delayed edge/gateway replay stays idempotent until BOTH buckets reset", async () => {
    const prefix = `${KEY_PREFIX}delayed-receipt:${randomUUID()}:`;
    const a = createRateLimiter(redisA, { keyPrefix: prefix });
    const b = createRateLimiter(redisB, { keyPrefix: prefix });
    const identity = {
      class: "send",
      uid: "delayed-receipt-user",
      ip: "203.0.113.79",
    } as const;
    await a.consume({ ...identity, requestId: "seed-buckets" });
    const uidKeys = await redisA.keys(`${prefix}send:uid:*`);
    const ipKeys = await redisA.keys(`${prefix}send:ip:*`);
    expect(uidKeys).toHaveLength(1);
    expect(ipKeys).toHaveLength(1);
    await redisA.pexpire(uidKeys[0]!, 50);

    const first = await a.consume({ ...identity, requestId: "delayed-replay" });
    await new Promise((resolve) => setTimeout(resolve, 100));
    const replay = await b.consume({ ...identity, requestId: "delayed-replay" });

    expect(replay).toEqual(first);
    // Seed + first = 2. A receipt that expired with the shorter UID bucket
    // would incorrectly increment this to 3 on the delayed gateway replay.
    await expect(redisA.get(ipKeys[0]!)).resolves.toBe("2");
  });

  it("canonical IPv6 spellings cannot evade an IP bucket", async () => {
    const expanded = "2001:0db8:0000:0000:0000:0000:0000:0001";
    const compressed = "2001:db8::1";
    const replies = [] as Awaited<ReturnType<RateLimiter["consume"]>>[];
    for (let index = 0; index < 121; index += 1) {
      replies.push(
        await (index % 2 === 0 ? limiterA : limiterB).consume({
          class: "send",
          uid: `ipv6-${index}`,
          ip: index % 2 === 0 ? expanded : compressed,
        }),
      );
    }
    expect(replies.filter((reply) => reply.allowed)).toHaveLength(120);
    expect(replies.at(-1)).toMatchObject({ allowed: false, scope: "ip" });
  });
});

describe("rate limit degradation and route classes", () => {
  it("reports a store failure instead of returning a healthy allow decision", async () => {
    const degraded: unknown[] = [];
    const limiter = createRateLimiter(
      {
        async eval() {
          throw new Error("isolated Redis unavailable");
        },
      },
      { onDegraded: (error) => degraded.push(error) },
    );

    await expect(
      limiter.consume({ class: "send", uid: "u", ip: "203.0.113.1" }),
    ).rejects.toThrow("rate limit store unavailable");
    expect(degraded).toHaveLength(1);
  });

  it.each([
    ["POST", "/cloud/v1/sessions/abc/messages", "send"],
    ["GET", "/cloud/v1/sessions/abc/messages", "default"],
    ["POST", "/cloud/v1/auth/ticket", "ticket"],
    ["POST", "/cloud/v1/sessions/abc/attachments", "attachments"],
    ["POST", "/cloud/v1/sessions/abc/attachments/id/finalize", "attachments"],
    ["PATCH", "/cloud/v1/mcp/connections/id", "connections"],
    ["POST", "/cloud/v1/plugins/install", "plugin_source"],
    ["POST", "/cloud/v1/previews", "preview"],
    ["POST", "/cloud/v1/voice/transcriptions", "voice"],
    ["POST", "/cloud/v1/collab/rooms/abc/join", "collab_join"],
    ["POST", "/cloud/v1/collab/rooms/abc/turn", "turn"],
    ["GET", "/cloud/v1/collab/rooms/abc/poll", "poll"],
    ["POST", "/chat/abc/join", "collab_join"],
    ["POST", "/chat/abc/members", "collab_join"],
    ["POST", "/chat/abc/turns", "turn"],
    ["GET", "/chat/abc/events", "poll"],
    ["GET", "/cloud/ws", "connections"],
    ["GET", "/cloud/v1/runs/abc", "poll"],
    ["POST", "/shares", "shares"],
    ["GET", "/s/token", "shares"],
    ["POST", "/v1/reports", "reports"],
    ["POST", "/admin/ban", "admin"],
    ["GET", "/cloud/v1/models", "default"],
  ] as const)("classifies %s %s as %s", (method, path, expected) => {
    expect(rateLimitClassFor(method, path)).toBe(expected);
  });
});

function forbiddenDb(): Db {
  return new Proxy(
    {},
    {
      get() {
        throw new Error("route side effect reached forbidden DB");
      },
    },
  ) as unknown as Db;
}

function recordingLimiter(
  behavior: { allowed?: boolean; fail?: boolean } = {},
): RateLimiter & { calls: RateLimitConsume[] } {
  const calls: RateLimitConsume[] = [];
  return {
    calls,
    async consume(input) {
      calls.push(input);
      if (behavior.fail === true) throw new Error("store failed");
      return behavior.allowed === false
        ? { allowed: false, retryAfterSeconds: 17, scope: "uid" }
        : { allowed: true, retryAfterSeconds: 0, scope: "uid+ip" };
    },
  };
}

describe("gateway rate-limit registration", () => {
  const built: FastifyInstance[] = [];

  afterAll(async () => {
    while (built.length > 0) await built.pop()!.close();
  });

  function makeApp(
    limiter: RateLimiter,
    options: { onDegraded?: (error: unknown) => void } = {},
  ) {
    const tickets = stubTickets();
    const app = buildGateway({
      db: forbiddenDb(),
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets,
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      system: stubSystemBus(),
      rateLimiter: limiter,
      rateLimitInternalSecret: SECRET,
      trustedProxyCidrs: ["127.0.0.0/8"],
      clock: () => new Date(NOW),
      shares: { baseUrl: "https://shares.example.test" },
      reports: {},
      ...(options.onDegraded !== undefined
        ? { onRateLimitDegraded: options.onDegraded }
        : {}),
    });
    built.push(app);
    return { app, tickets };
  }

  it("registers every route class before route side effects", async () => {
    const limiter = recordingLimiter();
    const { app } = makeApp(limiter);
    const cases: ReadonlyArray<{
      method: "GET" | "POST" | "PATCH";
      url: string;
      className: RateLimitClass;
      authenticated?: boolean;
    }> = [
      { method: "POST", url: `/cloud/v1/sessions/${SESSION}/messages`, className: "send" },
      { method: "POST", url: "/cloud/v1/auth/ticket", className: "ticket" },
      { method: "POST", url: `/cloud/v1/sessions/${SESSION}/attachments`, className: "attachments" },
      { method: "PATCH", url: "/cloud/v1/mcp/connections/abc", className: "connections" },
      { method: "POST", url: "/cloud/v1/plugins/install", className: "plugin_source" },
      { method: "POST", url: "/cloud/v1/previews", className: "preview" },
      { method: "POST", url: "/cloud/v1/voice/transcriptions", className: "voice" },
      { method: "POST", url: "/cloud/v1/collab/rooms/abc/join", className: "collab_join" },
      { method: "POST", url: "/chat/abc/members", className: "collab_join" },
      { method: "POST", url: "/cloud/v1/collab/rooms/abc/turn", className: "turn" },
      { method: "GET", url: "/cloud/v1/collab/rooms/abc/poll", className: "poll" },
      { method: "POST", url: "/shares", className: "shares" },
      { method: "POST", url: "/v1/reports", className: "reports" },
      { method: "GET", url: "/cloud/v1/models", className: "default" },
    ];

    for (const testCase of cases) {
      await app.inject({
        method: testCase.method,
        url: testCase.url,
        headers: {
          ...authHeaders("route-classes"),
          "x-forwarded-for": "203.0.113.10",
        },
        remoteAddress: "127.0.0.1",
        payload: testCase.method === "GET" ? undefined : {},
      });
    }

    expect(limiter.calls.map((call) => call.class)).toEqual(
      cases.map((testCase) => testCase.className),
    );
    expect(limiter.calls.map((call) => call.uid)).toEqual(cases.map(() => "route-classes"));
    expect(limiter.calls.map((call) => call.ip)).toEqual(cases.map(() => "203.0.113.10"));
  });

  it("keeps admin authorization separate and classifies admin traffic", async () => {
    const limiter = recordingLimiter();
    const { app } = makeApp(limiter);
    app.post("/admin/probe", async (request, reply) => {
      if (request.headers.authorization !== "Bearer separate-admin-authorization") {
        return reply.code(403).send({ error: { code: "forbidden", message: "Forbidden." } });
      }
      return { ok: true };
    });

    const denied = await app.inject({ method: "POST", url: "/admin/probe" });
    expect(denied.statusCode).toBe(403);
    expect(limiter.calls.at(-1)?.class).toBe("admin");
    expect(limiter.calls.at(-1)?.uid).toBeUndefined();
    const allowed = await app.inject({
      method: "POST",
      url: "/admin/probe",
      headers: { authorization: "Bearer separate-admin-authorization" },
    });
    expect(allowed.statusCode).toBe(200);
    expect(limiter.calls.filter((call) => call.class === "admin")).toHaveLength(2);
  });

  it("a denied decision returns 429 with Retry-After and no ticket mint", async () => {
    const limiter = recordingLimiter({ allowed: false });
    const { app, tickets } = makeApp(limiter);
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/auth/ticket",
      headers: authHeaders("denied-ticket"),
    });

    expect(res.statusCode).toBe(429);
    expect(res.headers["retry-after"]).toBe("17");
    expect(res.json()).toEqual({
      error: { code: "rate_limited", message: "Too many requests. Try again shortly." },
    });
    expect(tickets.minted).toEqual([]);
  });

  it("a store failure is a degraded 503 and never a healthy allow", async () => {
    const degraded: unknown[] = [];
    const limiter = recordingLimiter({ fail: true });
    const { app, tickets } = makeApp(limiter, {
      onDegraded: (error) => degraded.push(error),
    });
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/auth/ticket",
      headers: authHeaders("degraded-ticket"),
    });

    expect(res.statusCode).toBe(503);
    expect(res.json().error.code).toBe("rate_limit_unavailable");
    expect(res.body).not.toContain("store failed");
    expect(tickets.minted).toEqual([]);
    expect(degraded).toHaveLength(1);
  });

  it("an untrusted peer cannot spoof the IP bucket through XFF", async () => {
    const limiter = recordingLimiter();
    const { app } = makeApp(limiter);
    await app.inject({
      method: "POST",
      url: "/cloud/v1/auth/ticket",
      headers: { ...authHeaders("xff-check"), "x-forwarded-for": "192.0.2.99" },
      remoteAddress: "203.0.113.9",
    });
    expect(limiter.calls[0]).toMatchObject({ uid: "xff-check", ip: "203.0.113.9" });
  });

  it("the signed internal consume endpoint verifies identity and emits only a decision", async () => {
    const limiter = recordingLimiter();
    const { app } = makeApp(limiter);
    const timestamp = String(Math.floor(NOW / 1000));
    const body = JSON.stringify({
      class: "send",
      ip: "203.0.113.88",
      requestId: "internal-request-1",
      authorization: "Bearer test:internal-user",
      appCheck: "app-check-stub",
    });
    const signature = createHmac("sha256", SECRET)
      .update(`POST\n/internal/rate-limits/consume\n${timestamp}\n${body}`)
      .digest("hex");

    const res = await app.inject({
      method: "POST",
      url: "/internal/rate-limits/consume",
      headers: {
        "content-type": "application/json",
        "x-ovid-timestamp": timestamp,
        "x-ovid-signature": signature,
      },
      payload: body,
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ allowed: true, retryAfterSeconds: 0, scope: "uid+ip" });
    expect(limiter.calls).toEqual([
      {
        class: "send",
        uid: "internal-user",
        ip: "203.0.113.88",
        requestId: "internal-request-1",
      },
    ]);
  });

  it("rejects a forged internal consume signature before consuming", async () => {
    const limiter = recordingLimiter();
    const { app } = makeApp(limiter);
    const res = await app.inject({
      method: "POST",
      url: "/internal/rate-limits/consume",
      headers: {
        "content-type": "application/json",
        "x-ovid-timestamp": String(Math.floor(NOW / 1000)),
        "x-ovid-signature": "00",
      },
      payload: { class: "send", ip: "203.0.113.88" },
    });
    expect(res.statusCode).toBe(401);
    expect(res.body).not.toContain(SECRET);
    expect(limiter.calls).toEqual([]);
  });

  it("does not expose any consume endpoint when the internal secret is not configured", async () => {
    const limiter = recordingLimiter();
    const app = buildGateway({
      db: forbiddenDb(),
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      system: stubSystemBus(),
      rateLimiter: limiter,
    });
    built.push(app);

    const res = await app.inject({
      method: "POST",
      url: "/internal/rate-limits/consume",
      payload: { class: "send", ip: "203.0.113.88" },
    });
    expect(res.statusCode).toBe(404);
    expect(limiter.calls).toEqual([]);
  });

  it("reuses a verified signed edge request id and network at the gateway", async () => {
    const limiter = recordingLimiter();
    const { app } = makeApp(limiter);
    const timestamp = String(Math.floor(NOW / 1000));
    const requestId = "edge-request-1";
    const className = "ticket";
    const ip = "198.51.100.88";
    const asn = "AS64500";
    const authorization = "Bearer test:edge-user";
    const appCheck = "app-check-stub";
    const signature = createHmac("sha256", SECRET)
      .update(
        `EDGE\n${timestamp}\n${requestId}\n${className}\n${ip}\n${asn}\n${authorization}\n${appCheck}`,
      )
      .digest("hex");

    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/auth/ticket",
      headers: {
        authorization,
        "x-firebase-appcheck": appCheck,
        "x-forwarded-for": "192.0.2.200",
        "x-ovid-edge-request-id": requestId,
        "x-ovid-edge-ip": ip,
        "x-ovid-edge-asn": asn,
        "x-ovid-edge-timestamp": timestamp,
        "x-ovid-edge-signature": signature,
      },
      remoteAddress: "127.0.0.1",
    });
    expect(res.statusCode).toBe(200);
    expect(limiter.calls[0]).toEqual({
      class: "ticket",
      uid: "edge-user",
      ip,
      requestId,
    });
  });
});
