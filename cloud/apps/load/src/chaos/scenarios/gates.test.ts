import { describe, expect, it } from "vitest";
import { AGENT_RUNS_DEFAULT_CONCURRENCY } from "@ovid/queue";
import { CLIENTS as GATEWAY_CLIENTS, evaluateGatewayGate } from "./gatewayRestart.js";
import {
  CLIENTS as POSTGRES_CLIENTS,
  crossCheckRunStatuses,
  evaluatePostgresGate,
} from "./postgresRestart.js";
import { evaluateRedisQGate } from "./redisQRestart.js";

/**
 * Scenario precondition units (fakes, no staging): Review Focus #3 pins that
 * each gate rejects the vacuous case — an empty queue, a run that already
 * finished, or a released mock gate. H1 pins the client count to the worker's
 * real concurrency so a gate can never demand more in-flight runs than the
 * worker can hold.
 */

describe("client count vs worker concurrency (H1)", () => {
  it("gateway-restart prepares exactly the worker's concurrency", () => {
    expect(GATEWAY_CLIENTS).toBe(AGENT_RUNS_DEFAULT_CONCURRENCY);
  });

  it("postgres-restart prepares exactly the worker's concurrency", () => {
    expect(POSTGRES_CLIENTS).toBe(AGENT_RUNS_DEFAULT_CONCURRENCY);
  });
});

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
  const clients = Array.from({ length: GATEWAY_CLIENTS }, () => ({ ...client }));
  const healthy = {
    clients,
    expectedClients: GATEWAY_CLIENTS,
    gateReleased: false,
    healthStatus: "ok" as const,
  };

  it("passes with every run held mid-stream and the gate held", () => {
    const result = evaluateGatewayGate(healthy);
    expect(result.ok).toBe(true);
    expect(result.detail).toContain(`${GATEWAY_CLIENTS} run(s) provably in-flight`);
  });

  it("rejects a client count that does not match the worker concurrency", () => {
    const short = {
      ...healthy,
      clients: clients.slice(0, GATEWAY_CLIENTS - 1),
    };
    const result = evaluateGatewayGate(short);
    expect(result.ok).toBe(false);
    expect(result.detail).toContain(`expected exactly ${GATEWAY_CLIENTS}`);
  });

  it("rejects a run that already finished before the restart", () => {
    const withTerminal = clients.map((entry, index) =>
      index === 3 ? { ...entry, terminal: true } : entry,
    );
    const result = evaluateGatewayGate({ ...healthy, clients: withTerminal });
    expect(result.ok).toBe(false);
    expect(result.detail).toContain("client 3");
  });

  it("rejects a released mock gate", () => {
    expect(evaluateGatewayGate({ ...healthy, gateReleased: true }).ok).toBe(false);
  });

  it("rejects a client that has not seen a streamed delta", () => {
    const withoutDelta = clients.map((entry, index) =>
      index === 0 ? { ...entry, deltaSeen: false } : entry,
    );
    expect(evaluateGatewayGate({ ...healthy, clients: withoutDelta }).ok).toBe(false);
  });

  it("rejects zero in-flight even when the array has the expected length", () => {
    const allFinished = clients.map((entry) => ({ ...entry, terminal: true }));
    expect(evaluateGatewayGate({ ...healthy, clients: allFinished }).ok).toBe(false);
  });
});

describe("evaluatePostgresGate", () => {
  const client = { runStarted: true, deltaSeen: true, terminal: false };
  const clients = Array.from({ length: POSTGRES_CLIENTS }, () => ({ ...client }));
  const healthy = {
    clients,
    expectedClients: POSTGRES_CLIENTS,
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
    const withTerminal = clients.map((entry, index) =>
      index === POSTGRES_CLIENTS - 1 ? { ...entry, terminal: true } : entry,
    );
    expect(evaluatePostgresGate({ ...healthy, clients: withTerminal }).ok).toBe(false);
  });

  it("rejects a prepared client count that exceeds worker concurrency", () => {
    const tooMany = [...clients, { ...client }];
    expect(evaluatePostgresGate({ ...healthy, clients: tooMany }).ok).toBe(false);
  });
});

describe("crossCheckRunStatuses (M4)", () => {
  it("passes when terminal events match the durable run rows", () => {
    const statuses = new Map([
      ["run-1", "completed"],
      ["run-2", "failed"],
    ]);
    expect(crossCheckRunStatuses(statuses, ["run-1"], ["run-2"])).toEqual([]);
  });

  it("flags a run_completed whose row is still running (torn status flip)", () => {
    const mismatches = crossCheckRunStatuses(
      new Map([["run-1", "running"]]),
      ["run-1"],
      [],
    );
    expect(mismatches).toHaveLength(1);
    expect(mismatches[0]).toContain("run_completed but row=running");
  });

  it("flags a run_failed whose row is completed", () => {
    const mismatches = crossCheckRunStatuses(
      new Map([["run-1", "completed"]]),
      [],
      ["run-1"],
    );
    expect(mismatches[0]).toContain("run_failed but row=completed");
  });

  it("flags a missing row", () => {
    const mismatches = crossCheckRunStatuses(new Map(), ["run-1"], []);
    expect(mismatches[0]).toContain("row=missing");
  });
});
