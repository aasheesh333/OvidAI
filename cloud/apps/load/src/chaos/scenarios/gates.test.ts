import { describe, expect, it } from "vitest";
import { evaluateGatewayGate } from "./gatewayRestart.js";
import { evaluatePostgresGate } from "./postgresRestart.js";
import { evaluateRedisQGate } from "./redisQRestart.js";

/**
 * Scenario precondition units (fakes, no staging): Review Focus #3 pins that
 * each gate rejects the vacuous case — an empty queue, a run that already
 * finished, or a released mock gate.
 */

describe("evaluateRedisQGate", () => {
  const healthy = {
    waitingCount: 20,
    expectedWaiting: 20,
    workerAlive: false,
    healthStatus: "ok" as const,
    enqueueSettleMs: 2_500,
  };

  it("passes only with 20 waiting, worker stopped, health ok, settled >2s", () => {
    expect(evaluateRedisQGate(healthy).ok).toBe(true);
  });

  it("rejects an empty queue (the vacuous restart)", () => {
    const result = evaluateRedisQGate({ ...healthy, waitingCount: 0 });
    expect(result.ok).toBe(false);
    expect(result.detail).toContain("waiting == 0");
  });

  it("rejects a still-running worker", () => {
    expect(evaluateRedisQGate({ ...healthy, workerAlive: true }).ok).toBe(false);
  });

  it("rejects a degraded gateway", () => {
    expect(evaluateRedisQGate({ ...healthy, healthStatus: "degraded" }).ok).toBe(false);
  });

  it("rejects enqueues younger than the AOF tail-loss allowance", () => {
    const result = evaluateRedisQGate({ ...healthy, enqueueSettleMs: 500 });
    expect(result.ok).toBe(false);
    expect(result.detail).toContain("AOF");
  });
});

describe("evaluateGatewayGate", () => {
  const client = { runStarted: true, deltaSeen: true, terminal: false };
  const healthy = {
    clients: Array.from({ length: 10 }, () => ({ ...client })),
    gateReleased: false,
    healthStatus: "ok" as const,
  };

  it("passes with every run held mid-stream and the gate held", () => {
    expect(evaluateGatewayGate(healthy).ok).toBe(true);
  });

  it("rejects a run that already finished before the restart", () => {
    const clients = healthy.clients.map((entry, index) =>
      index === 3 ? { ...entry, terminal: true } : entry,
    );
    const result = evaluateGatewayGate({ ...healthy, clients });
    expect(result.ok).toBe(false);
    expect(result.detail).toContain("client 3");
  });

  it("rejects a released mock gate", () => {
    expect(evaluateGatewayGate({ ...healthy, gateReleased: true }).ok).toBe(false);
  });

  it("rejects a client that has not seen a streamed delta", () => {
    const clients = healthy.clients.map((entry, index) =>
      index === 0 ? { ...entry, deltaSeen: false } : entry,
    );
    expect(evaluateGatewayGate({ ...healthy, clients }).ok).toBe(false);
  });
});

describe("evaluatePostgresGate", () => {
  const client = { runStarted: true, deltaSeen: true, terminal: false };
  const healthy = {
    clients: Array.from({ length: 10 }, () => ({ ...client })),
    gateReleased: false,
    healthStatus: "ok" as const,
    workerAlive: true,
  };

  it("passes with runs held, worker alive and health ok", () => {
    expect(evaluatePostgresGate(healthy).ok).toBe(true);
  });

  it("rejects a dead worker", () => {
    expect(evaluatePostgresGate({ ...healthy, workerAlive: false }).ok).toBe(false);
  });

  it("rejects a degraded gateway", () => {
    expect(evaluatePostgresGate({ ...healthy, healthStatus: "degraded" }).ok).toBe(false);
  });

  it("rejects a run that already reached a terminal event", () => {
    const clients = healthy.clients.map((entry, index) =>
      index === 9 ? { ...entry, terminal: true } : entry,
    );
    expect(evaluatePostgresGate({ ...healthy, clients }).ok).toBe(false);
  });
});
