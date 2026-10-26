import { describe, expect, it } from "vitest";
import type { Db } from "@ovid/db";
import type { QueueServices } from "@ovid/queue";
import {
  createGatewayObservabilityComposition,
  type GatewayObservabilityExporter,
} from "./observabilityComposition.js";
import { buildGateway } from "./app.js";
import {
  noopEvents,
  stubKeys,
  stubMint,
  stubSystemBus,
  stubTickets,
  stubVerifier,
} from "./test/stubs.js";

const okDb = { $client: { unsafe: async () => [{ ok: 1 }] } } as unknown as Db;
const okQueues = {
  agentRuns: { client: Promise.resolve({ ping: async () => "PONG" }) },
} as unknown as QueueServices;

function composedApp(exporter: GatewayObservabilityExporter) {
  const observability = createGatewayObservabilityComposition({ exporter });
  const app = buildGateway(
    {
      system: stubSystemBus(),
      db: okDb,
      queues: okQueues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      observability,
    },
    { logger: false },
  );
  // A test route exercises the composed observability boundary inside the
  // gateway, without adding any production-only routes.
  app.get("/test/observability", async () => {
    observability.metric("admission.accepted", 1, "count");
    observability.log({ event: "observability.test", outcome: "succeeded" });
    return { ok: true };
  });
  return { app, observability };
}

describe("gateway observability integration", () => {
  it("a metric and a log reach the sink in a composed gateway", async () => {
    const metrics: unknown[] = [];
    const logs: unknown[] = [];
    const { app } = composedApp({
      metric: (sample) => metrics.push(sample),
      log: (record) => logs.push(record),
    });
    try {
      const res = await app.inject({ method: "GET", url: "/test/observability" });
      expect(res.statusCode).toBe(200);
      expect(metrics).toHaveLength(1);
      expect(metrics[0]).toMatchObject({
        name: "admission.accepted",
        value: 1,
        unit: "count",
      });
      expect(logs).toHaveLength(1);
      expect(logs[0]).toMatchObject({
        event: "observability.test",
        outcome: "succeeded",
      });
    } finally {
      await app.close();
    }
  });

  it("redaction still holds on the composed path", async () => {
    const metrics: unknown[] = [];
    const logs: unknown[] = [];
    const { app, observability } = composedApp({
      metric: (sample) => metrics.push(sample),
      log: (record) => logs.push(record),
    });
    try {
      const secret = "ghp_AbCdEf0123456789AbCdEf0123456789AbCd";
      // Attempt to smuggle a secret as a correlation id and a log reason.
      expect(() =>
        observability.metric("admission.accepted", 1, "count", { runId: secret }),
      ).toThrow("invalid correlation id");
      expect(() =>
        observability.log({ event: "test.secret", reason: secret }),
      ).toThrow("invalid log reason");
      // The sink never receives the secret.
      const sinkText = JSON.stringify({ metrics, logs });
      expect(sinkText).not.toContain("ghp_");
      expect(sinkText).not.toContain(secret);
      expect(metrics).toHaveLength(0);
      expect(logs).toHaveLength(0);
    } finally {
      await app.close();
    }
  });

  it("a throwing exporter does not fail the request", async () => {
    const { app } = composedApp({
      metric: () => {
        throw new Error("metric sink exploded");
      },
      log: () => {
        throw new Error("log sink exploded");
      },
    });
    try {
      const res = await app.inject({ method: "GET", url: "/test/observability" });
      expect(res.statusCode).toBe(200);
    } finally {
      await app.close();
    }
  });
});
