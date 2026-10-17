import { describe, expect, it } from "vitest";
import {
  assertLiveUnaffected,
  runChaosScenario,
  type ChaosContext,
  type ChaosScenario,
  type LiveSnapshot,
  type ReportWriter,
  type ScenarioResult,
  type StagingHandles,
} from "./runner.js";

/**
 * Review Focus #3: a chaos scenario must never pass vacuously. These tests pin
 * the runner mechanics with fakes — the real scenarios run only against the
 * staging composition, never here.
 */

function healthySnapshot(overrides: Partial<LiveSnapshot> = {}): LiveSnapshot {
  return {
    capturedAt: "2026-10-17T00:00:00.000Z",
    healthzStatus: 200,
    containers: [
      {
        name: "ovid-gateway-gateway-1",
        status: "Up 3 hours",
        startedAt: "2026-10-16T20:00:00.000000000Z",
      },
      {
        name: "ovid-gateway-redis-1",
        status: "Up 3 hours",
        startedAt: "2026-10-16T20:00:01.000000000Z",
      },
    ],
    ...overrides,
  };
}

function fakeStaging(): StagingHandles {
  const noop = async (): Promise<void> => {};
  return {
    composeRun: async () => "",
    restart: noop,
    workerStart: noop,
    workerKill: noop,
    workerStopGraceful: noop,
    pressureMount: async () => "",
    pressureUnmount: noop,
    workerAlive: async () => true,
  };
}

interface MemoryReport extends ReportWriter {
  scenarios: Array<{ result: ScenarioResult; liveBefore: LiveSnapshot; liveAfter?: LiveSnapshot }>;
}

function memoryReport(): MemoryReport {
  const scenarios: MemoryReport["scenarios"] = [];
  return {
    scenarios,
    async append() {},
    async writeScenario(result, extras) {
      scenarios.push({ result, ...extras });
    },
  };
}

function fakeContext(snapshots: LiveSnapshot[] = []): {
  ctx: ChaosContext;
  report: MemoryReport;
} {
  const report = memoryReport();
  let index = 0;
  const ctx: ChaosContext = {
    staging: fakeStaging(),
    env: {},
    mockArm: () => ({ release: () => {} }),
    async liveCheckPoint() {
      const snapshot = snapshots[Math.min(index, snapshots.length - 1)] ?? healthySnapshot();
      index += 1;
      return snapshot;
    },
    report,
  };
  return { ctx, report };
}

function fakeScenario(
  gateOk: boolean,
  counters: { injected: number },
  options: { injectThrows?: boolean; verifyFails?: boolean } = {},
): ChaosScenario {
  return {
    name: "redis-q-restart",
    precondition: "20 runs waiting in the queue and the worker stopped",
    async prepare() {
      return {};
    },
    async gate() {
      return { ok: gateOk, detail: gateOk ? "waiting == 20" : "waiting == 0" };
    },
    async inject() {
      counters.injected += 1;
      if (options.injectThrows === true) throw new Error("injection exploded");
    },
    async verify() {
      return [
        { name: "recovered", passed: options.verifyFails !== true, detail: "detail" },
      ];
    },
  };
}

describe("runChaosScenario — precondition gate (Review Focus #3)", () => {
  it("precondition failure marks scenario failed without injection", async () => {
    const counters = { injected: 0 };
    const { ctx } = fakeContext();
    const result = await runChaosScenario(
      "redis-q-restart",
      ctx,
      [fakeScenario(false, counters)],
    );

    expect(counters.injected).toBe(0);
    expect(result.passed).toBe(false);
    expect(result.precondition).toContain("20 runs waiting");
    expect(result.assertions[0]).toMatchObject({
      name: "precondition",
      passed: false,
    });
  });

  it("injects only after the gate passes", async () => {
    const counters = { injected: 0 };
    const { ctx } = fakeContext();
    const result = await runChaosScenario(
      "redis-q-restart",
      ctx,
      [fakeScenario(true, counters)],
    );

    expect(counters.injected).toBe(1);
    expect(result.passed).toBe(true);
    expect(result.assertions.map((a) => a.name)).toEqual([
      "precondition",
      "inject",
      "recovered",
      "live-unaffected-after",
    ]);
  });

  it("a failed verification assertion fails the scenario", async () => {
    const counters = { injected: 0 };
    const { ctx } = fakeContext();
    const result = await runChaosScenario(
      "redis-q-restart",
      ctx,
      [fakeScenario(true, counters, { verifyFails: true })],
    );

    expect(result.passed).toBe(false);
    expect(result.assertions.find((a) => a.name === "recovered")?.passed).toBe(false);
  });

  it("an injection exception fails the scenario instead of escaping", async () => {
    const counters = { injected: 0 };
    const { ctx } = fakeContext();
    const result = await runChaosScenario(
      "redis-q-restart",
      ctx,
      [fakeScenario(true, counters, { injectThrows: true })],
    );

    expect(result.passed).toBe(false);
    expect(result.assertions.find((a) => a.name === "inject")?.passed).toBe(false);
  });

  it("records the live snapshot pair for the report", async () => {
    const counters = { injected: 0 };
    const { ctx, report } = fakeContext([healthySnapshot(), healthySnapshot()]);
    await runChaosScenario("redis-q-restart", ctx, [fakeScenario(true, counters)]);

    expect(report.scenarios).toHaveLength(1);
    expect(report.scenarios[0]!.liveBefore.healthzStatus).toBe(200);
    expect(report.scenarios[0]!.liveAfter?.healthzStatus).toBe(200);
  });
});

describe("assertLiveUnaffected", () => {
  it("passes when healthz is 200 and every container is Up with an unchanged StartedAt", async () => {
    const before = healthySnapshot();
    await expect(
      assertLiveUnaffected(before, async () => healthySnapshot()),
    ).resolves.toBeUndefined();
  });

  it("throws on StartedAt drift naming the container", async () => {
    const before = healthySnapshot();
    const after = healthySnapshot({
      containers: [
        {
          name: "ovid-gateway-gateway-1",
          status: "Up 1 second",
          startedAt: "2026-10-17T00:01:00.000000000Z",
        },
        before.containers[1]!,
      ],
    });

    await expect(
      assertLiveUnaffected(before, async () => after),
    ).rejects.toThrow(/ovid-gateway-gateway-1.*StartedAt/);
  });

  it("throws when a live container is no longer Up", async () => {
    const before = healthySnapshot();
    const after = healthySnapshot({
      containers: [
        { ...before.containers[0]!, status: "Exited (1) 2 seconds ago" },
        before.containers[1]!,
      ],
    });

    await expect(
      assertLiveUnaffected(before, async () => after),
    ).rejects.toThrow(/ovid-gateway-gateway-1/);
  });

  it("throws when the live healthz is not 200", async () => {
    const before = healthySnapshot();
    await expect(
      assertLiveUnaffected(before, async () => healthySnapshot({ healthzStatus: 503 })),
    ).rejects.toThrow(/healthz/);
  });

  it("refuses an unhealthy baseline before any injection", async () => {
    const counters = { injected: 0 };
    const { ctx } = fakeContext([
      healthySnapshot({ healthzStatus: 503 }),
      healthySnapshot(),
    ]);
    const result = await runChaosScenario(
      "redis-q-restart",
      ctx,
      [fakeScenario(true, counters)],
    );

    expect(counters.injected).toBe(0);
    expect(result.passed).toBe(false);
    expect(result.assertions[0]).toMatchObject({ name: "live-unaffected-before", passed: false });
  });

  it("fails the scenario when the live stack drifts during it", async () => {
    const counters = { injected: 0 };
    const drifted = healthySnapshot({
      containers: [
        {
          name: "ovid-gateway-gateway-1",
          status: "Up 1 second",
          startedAt: "2026-10-17T00:01:00.000000000Z",
        },
        healthySnapshot().containers[1]!,
      ],
    });
    const { ctx } = fakeContext([healthySnapshot(), drifted]);
    const result = await runChaosScenario(
      "redis-q-restart",
      ctx,
      [fakeScenario(true, counters)],
    );

    expect(result.passed).toBe(false);
    expect(
      result.assertions.find((a) => a.name === "live-unaffected-after"),
    ).toMatchObject({ passed: false });
  });
});
