import { describe, expect, it } from "vitest";
import type { Db } from "@ovid/db";
import type { QueueServices } from "@ovid/queue";
import { createQueues } from "@ovid/queue";
import { buildGateway } from "../app.js";
import { openTestDb, closeDb, TEST_DATABASE_URL, } from "../test/db.js";
import { stubKeys, stubMint, stubTickets, stubVerifier } from "../test/stubs.js";

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

// Stub shapes mirroring exactly what the health route touches:
// db → $client.unsafe("SELECT 1"); redisQ → queues.agentRuns.client → ping().
const okDb = { $client: { unsafe: async () => [{ ok: 1 }] } } as unknown as Db;
const failDb = {
  $client: {
    unsafe: async () => {
      throw new Error("connection refused");
    },
  },
} as unknown as Db;
const hangDb = {
  $client: { unsafe: () => new Promise(() => {}) }, // never settles → must time out
} as unknown as Db;
// No $client at all → the probe must catch the TypeError, never 500.
const brokenDb = {} as unknown as Db;

const okQueues = {
  agentRuns: { client: Promise.resolve({ ping: async () => "PONG" }) },
} as unknown as QueueServices;
const failQueues = {
  agentRuns: {
    client: Promise.resolve({
      ping: async () => {
        throw new Error("redis down");
      },
    }),
  },
} as unknown as QueueServices;
const hangQueues = {
  agentRuns: { client: new Promise(() => {}) }, // never ready → must time out
} as unknown as QueueServices;

function healthApp(db: Db, queues: QueueServices) {
  return buildGateway({
    db,
    queues,
    verifier: stubVerifier(),
    tickets: stubTickets(),
    keys: stubKeys(),
    mint: stubMint(),
  });
}

async function getHealth(db: Db, queues: QueueServices) {
  const app = healthApp(db, queues);
  try {
    // Deliberately WITHOUT auth headers: health must not require auth.
    const res = await app.inject({ method: "GET", url: "/cloud/v1/health" });
    return res;
  } finally {
    await app.close();
  }
}

describe("GET /cloud/v1/health", () => {
  it("all checks pass → 200 {status:'ok'} without any auth headers", async () => {
    const res = await getHealth(okDb, okQueues);
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ status: "ok", checks: { db: true, redisQ: true } });
  });

  it("failing db check → 503 degraded, redisQ still reported", async () => {
    const res = await getHealth(failDb, okQueues);
    expect(res.statusCode).toBe(503);
    expect(res.json()).toEqual({ status: "degraded", checks: { db: false, redisQ: true } });
  });

  it("failing redisQ check → 503 degraded", async () => {
    const res = await getHealth(okDb, failQueues);
    expect(res.statusCode).toBe(503);
    expect(res.json()).toEqual({ status: "degraded", checks: { db: true, redisQ: false } });
  });

  it("broken dep objects degrade instead of throwing (503, never 500)", async () => {
    const res = await getHealth(brokenDb, {} as unknown as QueueServices);
    expect(res.statusCode).toBe(503);
    expect(res.json()).toEqual({ status: "degraded", checks: { db: false, redisQ: false } });
  });

  it("hung backends hit the ~1s probe timeout instead of hanging the request", async () => {
    const started = Date.now();
    const res = await getHealth(hangDb, hangQueues);
    const elapsed = Date.now() - started;
    expect(res.statusCode).toBe(503);
    expect(res.json()).toEqual({ status: "degraded", checks: { db: false, redisQ: false } });
    expect(elapsed).toBeGreaterThanOrEqual(900); // both probes ran concurrently ~1s
    expect(elapsed).toBeLessThan(4000);
  });

  it.skipIf(!TEST_DATABASE_URL)("db check passes against real postgres (SELECT 1)", async () => {
    const db = await openTestDb();
    try {
      const res = await getHealth(db, okQueues);
      expect(res.statusCode).toBe(200);
      expect(res.json()).toEqual({ status: "ok", checks: { db: true, redisQ: true } });
    } finally {
      await closeDb(db);
    }
  }, 60_000);

  it.skipIf(!TEST_REDIS_URL)("redisQ check passes against a real BullMQ queue connection", async () => {
    // NOTE: createQueues takes a connection OPTIONS OBJECT ({url}) — a bare
    // string would be spread into garbage opts by withBlockingSafeRetries
    // (same shape Task 5's queues.test.ts uses).
    const queues = createQueues({ url: TEST_REDIS_URL! });
    try {
      const res = await getHealth(okDb, queues);
      expect(res.statusCode).toBe(200);
      expect(res.json()).toEqual({ status: "ok", checks: { db: true, redisQ: true } });
    } finally {
      await queues.agentRuns.close();
    }
  }, 30_000);
});
