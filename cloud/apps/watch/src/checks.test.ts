import { describe, expect, it } from "vitest";
import {
  collectChecks,
  DEFAULT_THRESHOLDS,
  type CheckResult,
  type WatchDeps,
} from "./checks.js";

/**
 * Task 11 Step 1 — check arithmetic. Every case pins the exact default
 * threshold from the plan: queue waiting 50, worker lag 300 s, disk 80 %,
 * redis memory 80 % of maxmemory, spend drift max(100 ¢, 2 %).
 *
 * The deps are injected; nothing here touches a real redis/postgres/disk.
 */

function deps(overrides: Partial<WatchDeps> = {}): WatchDeps {
  return {
    fetchJson: async () => ({ status: "ok", checks: { db: true, redisQ: true } }),
    redisInfo: async () => ({ used_memory: "100", maxmemory: "1000" }),
    queueWaiting: async () => 0,
    queueOldestWaitingAgeS: async () => 0,
    sql: async () => [],
    dfPct: async () => 10,
    now: () => new Date("2026-10-17T12:00:00.000Z"),
    mintSpendCents: async () => [],
    ...overrides,
  };
}

function result(results: CheckResult[], name: CheckResult["name"]): CheckResult {
  const found = results.find((r) => r.name === name);
  if (found === undefined) {
    throw new Error(`check ${name} missing from ${results.map((r) => r.name).join(",")}`);
  }
  return found;
}

/** Generic-stub helper for the `sql<T>` seam (LiteLLM_SpendLogs rows). */
function sqlRows(rows: Array<{ uid: string; cents: number }>): WatchDeps["sql"] {
  return (async () => rows) as unknown as WatchDeps["sql"];
}

describe("collectChecks", () => {
  it("gateway-health fails when the health body is not ok", async () => {
    const failing = await collectChecks(
      deps({ fetchJson: async () => ({ status: "degraded", checks: { db: false } }) }),
    );
    expect(result(failing, "gateway-health")).toMatchObject({
      ok: false,
      value: 0,
      threshold: 1,
    });

    const healthy = await collectChecks(deps());
    expect(result(healthy, "gateway-health").ok).toBe(true);
  });

  it("gateway-health fails (never throws) when the fetch rejects", async () => {
    const results = await collectChecks(
      deps({
        fetchJson: async () => {
          throw new Error("ECONNREFUSED");
        },
      }),
    );
    const check = result(results, "gateway-health");
    expect(check.ok).toBe(false);
    expect(check.detail).toContain("ECONNREFUSED");
  });

  it("queue-depth fails at threshold: waiting 51 vs 50", async () => {
    const results = await collectChecks(deps({ queueWaiting: async () => 51 }));
    expect(result(results, "queue-depth")).toMatchObject({
      ok: false,
      value: 51,
      threshold: 50,
    });

    const atThreshold = await collectChecks(deps({ queueWaiting: async () => 50 }));
    expect(result(atThreshold, "queue-depth").ok).toBe(true);
  });

  it("queue-depth takes the worst of the configured queues", async () => {
    const waiting: Record<string, number> = { "agent-runs": 10, schedules: 51 };
    const results = await collectChecks(
      deps({
        config: { queueNames: ["agent-runs", "schedules"] },
        queueWaiting: async (name) => waiting[name] ?? 0,
      }),
    );
    const check = result(results, "queue-depth");
    expect(check.ok).toBe(false);
    expect(check.value).toBe(51);
    expect(check.detail).toContain("schedules");
  });

  it("worker-lag fails at 301 s", async () => {
    const results = await collectChecks(deps({ queueOldestWaitingAgeS: async () => 301 }));
    expect(result(results, "worker-lag")).toMatchObject({
      ok: false,
      value: 301,
      threshold: 300,
    });

    const atThreshold = await collectChecks(deps({ queueOldestWaitingAgeS: async () => 300 }));
    expect(result(atThreshold, "worker-lag").ok).toBe(true);
  });

  it("redis-mem ratio math: 0.81 fails, 0.79 passes (computed from INFO)", async () => {
    const over = await collectChecks(
      deps({ redisInfo: async () => ({ used_memory: "810", maxmemory: "1000" }) }),
    );
    expect(result(over, "redis-mem-80")).toMatchObject({
      ok: false,
      value: 81,
      threshold: 80,
    });

    const under = await collectChecks(
      deps({ redisInfo: async () => ({ used_memory: "790", maxmemory: "1000" }) }),
    );
    expect(result(under, "redis-mem-80").ok).toBe(true);
  });

  it("redis-mem reads the real maxmemory (1400 MiB prod value, not a hardcode)", async () => {
    // 1400 MiB = 1468006400 bytes; 81 % used.
    const used = Math.floor(1468006400 * 0.81);
    const results = await collectChecks(
      deps({
        redisInfo: async () => ({
          used_memory: String(used),
          maxmemory: "1468006400",
        }),
      }),
    );
    expect(result(results, "redis-mem-80").ok).toBe(false);
  });

  it("redis-mem with maxmemory=0 is not computable and stays ok (detail says why)", async () => {
    const results = await collectChecks(
      deps({ redisInfo: async () => ({ used_memory: "999999", maxmemory: "0" }) }),
    );
    const check = result(results, "redis-mem-80");
    expect(check.ok).toBe(true);
    expect(check.detail).toMatch(/maxmemory/i);
  });

  it("disk-80 fails at 81 % and passes at 80 %", async () => {
    const over = await collectChecks(deps({ dfPct: async () => 81 }));
    expect(result(over, "disk-80")).toMatchObject({
      ok: false,
      value: 81,
      threshold: 80,
    });

    const at = await collectChecks(deps({ dfPct: async () => 80 }));
    expect(result(at, "disk-80").ok).toBe(true);
  });

  it("spend-parity drift: mint 1050¢ vs LiteLLM 1200¢ (150¢ > max(100¢, 2%)) fails", async () => {
    const results = await collectChecks(
      deps({
        mintSpendCents: async () => [{ uid: "u1", cents: 1050 }],
        sql: sqlRows([{ uid: "u1", cents: 1200 }]),
      }),
    );
    expect(result(results, "spend-parity")).toMatchObject({
      ok: false,
      value: 150,
      threshold: 100,
    });
  });

  it("spend-parity drift: mint 1050¢ vs LiteLLM 1100¢ (50¢ < 100¢) passes", async () => {
    const results = await collectChecks(
      deps({
        mintSpendCents: async () => [{ uid: "u1", cents: 1050 }],
        sql: sqlRows([{ uid: "u1", cents: 1100 }]),
      }),
    );
    expect(result(results, "spend-parity")).toMatchObject({
      ok: true,
      value: 50,
    });
  });

  it("spend-parity uses the greater of 100¢ and 2 % of the mint ledger", async () => {
    // 2 % of 10 000¢ = 200¢; a 250¢ drift exceeds it (100¢ alone would not).
    const results = await collectChecks(
      deps({
        mintSpendCents: async () => [{ uid: "big", cents: 10_000 }],
        sql: sqlRows([{ uid: "big", cents: 10_250 }]),
      }),
    );
    const check = result(results, "spend-parity");
    expect(check.ok).toBe(false);
    expect(check.value).toBe(250);
    expect(check.threshold).toBe(200);
  });

  it("spend-parity handles users present on only one side as a full drift", async () => {
    const results = await collectChecks(
      deps({
        mintSpendCents: async () => [{ uid: "only-mint", cents: 500 }],
        sql: sqlRows([{ uid: "only-litellm", cents: 900 }]),
      }),
    );
    expect(result(results, "spend-parity").ok).toBe(false);
  });

  it("spend-parity is loud when the mint ledger seam is not wired", async () => {
    const results = await collectChecks(deps({ mintSpendCents: undefined }));
    const check = result(results, "spend-parity");
    expect(check.ok).toBe(false);
    expect(check.detail).toMatch(/mint ledger/i);
  });

  it("spend-parity can be explicitly disabled (detail records the reason)", async () => {
    const results = await collectChecks(
      deps({ config: { spendParity: false }, mintSpendCents: undefined }),
    );
    const check = result(results, "spend-parity");
    expect(check.ok).toBe(true);
    expect(check.detail).toMatch(/disabled/i);
  });

  it("a throwing dependency degrades that check to ok:false, never the whole pass", async () => {
    const results = await collectChecks(
      deps({
        queueWaiting: async () => {
          throw new Error("redis down");
        },
        dfPct: async () => 12,
      }),
    );
    const queue = result(results, "queue-depth");
    expect(queue.ok).toBe(false);
    expect(queue.detail).toContain("redis down");
    // The other checks still ran.
    expect(result(results, "disk-80").ok).toBe(true);
  });

  it("pins the plan's default thresholds", () => {
    expect(DEFAULT_THRESHOLDS).toEqual({
      queueWaiting: 50,
      workerLagS: 300,
      diskPct: 80,
      redisMemPct: 80,
      spendDriftCents: 100,
      spendDriftPct: 2,
    });
  });
});
