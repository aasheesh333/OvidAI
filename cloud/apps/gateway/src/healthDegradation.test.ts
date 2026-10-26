import { describe, expect, it } from "vitest";
import type { Db } from "@ovid/db";
import type { QueueServices } from "@ovid/queue";
import { buildGateway } from "./app.js";
import { noopEvents, stubKeys, stubMint, stubSystemBus, stubTickets, stubVerifier } from "./test/stubs.js";

function healthChecks(overrides: Record<string, boolean>) {
  return {
    db: true,
    redisQ: true,
    anomaly: false,
    mail: false,
    reservation: false,
    notification: false,
    ...overrides,
  };
}

/**
 * Graceful degradation + honest health contract.
 *
 * Every dependency is failed INDEPENDENTLY and the response must still arrive
 * (no hang, no 500 storm) with the dependency that is actually broken marked
 * broken. A healthy answer therefore requires every probe to have really
 * succeeded — nothing is defaulted to "ok".
 */

const okDb = { $client: { unsafe: async () => [{ ok: 1 }] } } as unknown as Db;
const failDb = {
  $client: {
    unsafe: async () => {
      throw new Error("connect ECONNREFUSED 10.0.0.5:5432");
    },
  },
} as unknown as Db;
const hangDb = { $client: { unsafe: () => new Promise(() => {}) } } as unknown as Db;
const brokenDb = {} as unknown as Db;

const okQueues = {
  agentRuns: {
    client: Promise.resolve({ ping: async () => "PONG" }),
    getWorkersCount: async () => 3,
  },
} as unknown as QueueServices;
const redisDownQueues = {
  agentRuns: {
    // Getters keep the rejection inside the probe instead of creating an
    // unhandled rejection at module load.
    get client(): Promise<never> {
      return Promise.reject(new Error("redis connection refused"));
    },
    getWorkersCount: async () => {
      throw new Error("redis connection refused");
    },
  },
} as unknown as QueueServices;
const pingDownQueues = {
  agentRuns: {
    client: Promise.resolve({
      ping: async () => {
        throw new Error("redis ping failed");
      },
    }),
    getWorkersCount: async () => {
      throw new Error("redis ping failed");
    },
  },
} as unknown as QueueServices;
const hangQueues = { agentRuns: { client: new Promise(() => {}) } } as unknown as QueueServices;

function app(db: Db, queues: QueueServices, extra: Record<string, unknown> = {}) {
  return buildGateway({
    system: stubSystemBus(),
    db,
    queues,
    verifier: stubVerifier(),
    tickets: stubTickets(),
    keys: stubKeys(),
    mint: stubMint(),
    events: noopEvents,
    ...extra,
  });
}

async function get(db: Db, queues: QueueServices, url: string, extra: Record<string, unknown> = {}) {
  const instance = app(db, queues, extra);
  try {
    const started = Date.now();
    const res = await instance.inject({ method: "GET", url });
    return { res, elapsed: Date.now() - started };
  } finally {
    await instance.close();
  }
}

describe("Redis down — the API still answers with an honest verdict", () => {
  it.each([
    ["client promise rejects", redisDownQueues],
    ["ping rejects", pingDownQueues],
  ])("/health is a truthful 503 degraded, not a 500 (%s)", async (_label, queues) => {
    const { res } = await get(okDb, queues, "/cloud/v1/health");
    expect(res.statusCode).toBe(503);
    expect(res.json()).toEqual({ status: "degraded", checks: healthChecks({ redisQ: false }) });
    expect(res.body).not.toContain("ECONNREFUSED");
  });

  it("/health/status keeps its 200 body contract and marks queue down", async () => {
    const { res } = await get(okDb, redisDownQueues, "/cloud/v1/health/status", {
      modelCatalog: async () => ["auto"],
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().checks.queue).toBe("down");
    expect(res.json().status).toBe("down");
  });

  it("a rate-limit store outage cannot rewrite health as a false outage", async () => {
    const rateLimiter = {
      consume: async () => {
        throw new Error("redis down");
      },
    };
    const health = await get(okDb, okQueues, "/cloud/v1/health", {
      rateLimiter,
      modelCatalog: async () => ["auto"],
    });
    expect(health.res.statusCode).toBe(200);
    expect(health.res.json()).toEqual({ status: "ok", checks: healthChecks({}) });

    const status = await get(okDb, okQueues, "/cloud/v1/health/status", {
      rateLimiter,
      modelCatalog: async () => ["auto"],
    });
    expect(status.res.statusCode).toBe(200);
    expect(status.res.json().status).toBe("ok");

    // A normal route still answers with a typed 503 — the gateway degrades,
    // it does not crash or hang.
    const normal = await get(
      okDb,
      okQueues,
      "/cloud/v1/mcp/oauth/callback?state=x&code=y",
      { rateLimiter },
    );
    expect(normal.res.statusCode).toBe(503);
    expect(normal.res.json().error.code).toBe("rate_limit_unavailable");
  });

  it("health is still rate-limited when the store works (no bypass)", async () => {
    const rateLimiter = {
      consume: async () => ({ allowed: false, retryAfterSeconds: 30 }),
    };
    const { res } = await get(okDb, okQueues, "/cloud/v1/health", { rateLimiter });
    expect(res.statusCode).toBe(429);
    expect(res.headers["retry-after"]).toBe("30");
  });
});

describe("Postgres down — reported, never a hang", () => {
  it("/health answers within the probe deadline with db:false", async () => {
    const { res, elapsed } = await get(hangDb, okQueues, "/cloud/v1/health");
    expect(res.statusCode).toBe(503);
    expect(res.json()).toEqual({ status: "degraded", checks: healthChecks({ db: false }) });
    expect(elapsed).toBeLessThan(4_000);
  });

  it("/health/status reports storage down, queue still ok, and leaks no host", async () => {
    const { res } = await get(failDb, okQueues, "/cloud/v1/health/status", {
      modelCatalog: async () => ["auto"],
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().checks).toMatchObject({ api: "ok", storage: "down", queue: "ok", agents: "ok" });
    expect(res.json().status).toBe("down");
    expect(res.body).not.toContain("10.0.0.5");
    expect(res.body).not.toContain("ECONNREFUSED");
  });

  it("both backends hung → one bounded answer, never two sequential 1 s stalls", async () => {
    const { res, elapsed } = await get(hangDb, hangQueues, "/cloud/v1/health/status");
    expect(res.statusCode).toBe(200);
    expect(res.json().status).toBe("down");
    expect(elapsed).toBeLessThan(4_000);
  });

  it("a structurally broken dependency object degrades instead of throwing", async () => {
    const { res } = await get(brokenDb, {} as unknown as QueueServices, "/cloud/v1/health");
    expect(res.statusCode).toBe(503);
    expect(res.json()).toEqual({ status: "degraded", checks: healthChecks({ db: false, redisQ: false }) });
  });
});

describe("health contract — 'ok' requires every dependency to be genuinely ok", () => {
  it("is ok only when all five capabilities are ok", async () => {
    const { res } = await get(okDb, okQueues, "/cloud/v1/health/status", {
      modelCatalog: async () => ["auto"],
    });
    expect(res.json()).toEqual({
      status: "ok",
      checks: { api: "ok", storage: "ok", queue: "ok", agents: "ok", models: "ok" },
      checkedAt: expect.any(String),
    });
  });

  const cases: Array<{
    label: string;
    db?: Db;
    queues?: QueueServices;
    extra?: Record<string, unknown>;
    expect: Record<string, string>;
    status: string;
  }> = [
    { label: "db down", db: failDb, expect: { storage: "down" }, status: "down" },
    { label: "redis down", queues: redisDownQueues, expect: { queue: "down" }, status: "down" },
    {
      label: "no queue consumers",
      queues: { agentRuns: { client: Promise.resolve({ ping: async () => "PONG" }), getWorkersCount: async () => 0 } } as unknown as QueueServices,
      expect: { agents: "down" },
      status: "down",
    },
    {
      label: "consumer count unknowable",
      queues: { agentRuns: { client: Promise.resolve({ ping: async () => "PONG" }) } } as unknown as QueueServices,
      expect: { agents: "unknown" },
      status: "degraded",
    },
    { label: "model catalog missing", extra: { modelCatalog: undefined }, expect: { models: "unknown" }, status: "degraded" },
    {
      label: "model catalog empty",
      extra: { modelCatalog: async () => [] },
      expect: { models: "degraded" },
      status: "degraded",
    },
    {
      label: "model catalog throws",
      extra: { modelCatalog: async () => { throw new Error("mint down"); } },
      expect: { models: "degraded" },
      status: "degraded",
    },
  ];

  it.each(cases)("$label → never ok ($status)", async (c) => {
    const { res } = await get(c.db ?? okDb, c.queues ?? okQueues, "/cloud/v1/health/status", {
      modelCatalog: async () => ["auto"],
      ...c.extra,
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().checks).toMatchObject(c.expect);
    expect(res.json().status).toBe(c.status);
    expect(res.json().status).not.toBe("ok");
  });

  it("never reports api:ok from a default — the route only answers because it ran", async () => {
    // api is the only self-evident fact; every other field is probed.
    const { res } = await get(okDb, okQueues, "/cloud/v1/health/status");
    const checks = res.json().checks;
    for (const key of ["storage", "queue", "agents", "models"]) {
      expect(["ok", "degraded", "down", "unknown"]).toContain(checks[key]);
    }
    // Without a catalog the overall verdict cannot be ok.
    expect(res.json().status).toBe("degraded");
  });
});
