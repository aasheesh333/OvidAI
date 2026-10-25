import { describe, expect, it } from "vitest";
import {
  childCorrelation,
  correlationIds,
  METRIC_NAMES,
  type MetricSample,
  type SafeLogRecord,
} from "../../../packages/shared/src/observability.js";
import {
  createGatewayObservabilityComposition,
  type GatewayOperationalHealthChecks,
  type GatewayOperationalHealthProbes,
} from "./observabilityComposition.js";

/**
 * UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
 * These tests are authored for later focused Vitest execution; no result is claimed.
 */

const SECRET = "sk-live-composition-canary";
const SIGNED_URL = `https://files.example.test/private?signature=${SECRET}`;
const ALL_IDS = {
  requestId: "request-1",
  runId: "run-parent",
  parentRunId: "run-root",
  childRunId: "run-first-child",
  connectionId: "connection-1",
  providerOperationId: "provider-op-1",
  studioId: "studio-1",
  previewId: "preview-1",
  collabTurnId: "turn-1",
} as const;

interface HarnessOptions {
  health?: GatewayOperationalHealthProbes;
}

function harness(options: HarnessOptions = {}) {
  const exportedMetrics: MetricSample[] = [];
  const exportedLogs: SafeLogRecord[] = [];
  const gateway = createGatewayObservabilityComposition({
    exporter: {
      metric(sample) {
        exportedMetrics.push(sample);
      },
      log(record) {
        exportedLogs.push(record);
      },
    },
    ...(options.health === undefined ? {} : { health: options.health }),
  });
  return { gateway, exportedMetrics, exportedLogs };
}

describe("createGatewayObservabilityComposition (UNEXECUTED)", () => {
  it("forwards every closed metric name through the shared registry to the exporter", () => {
    const { gateway, exportedMetrics } = harness();

    for (const name of METRIC_NAMES) gateway.metric(name, 1, "count");

    expect(gateway.metrics.snapshot().map((sample) => sample.name)).toEqual([...METRIC_NAMES]);
    expect(exportedMetrics).toEqual(gateway.metrics.snapshot());
  });

  it("preserves all operational correlation fields and shared child-run lineage", () => {
    const { gateway, exportedMetrics } = harness();
    const ids = correlationIds(ALL_IDS);
    const rawIds = {
      ...ids,
      prompt: `private prompt ${SECRET}`,
      token: SECRET,
      signedUrl: SIGNED_URL,
    };
    const child = childCorrelation(ids, "run-second-child");

    gateway.metric("subagents.slots", 1, "gauge", rawIds);
    gateway.metric("subagents.slots", 1, "gauge", child);

    expect(exportedMetrics[0]?.correlation).toEqual(ALL_IDS);
    expect(exportedMetrics[1]?.correlation).toEqual({
      requestId: "request-1",
      runId: "run-second-child",
      parentRunId: "run-parent",
      connectionId: "connection-1",
      providerOperationId: "provider-op-1",
      studioId: "studio-1",
      previewId: "preview-1",
      collabTurnId: "turn-1",
    });
    const text = JSON.stringify(exportedMetrics);
    for (const forbidden of ["prompt", "token", "signedUrl", SECRET, SIGNED_URL]) {
      expect(text).not.toContain(forbidden);
    }
  });

  it("refuses unknown metrics and every non-finite value before export", () => {
    const { gateway, exportedMetrics } = harness();

    expect(() => gateway.metric("prompt.contents", 1, "count")).toThrow("unknown metric");
    for (const value of [Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY]) {
      expect(() => gateway.metric("queue.waiting", value, "gauge")).toThrow("invalid metric value");
    }

    expect(gateway.metrics.snapshot()).toEqual([]);
    expect(exportedMetrics).toEqual([]);
  });

  it("drops non-operational and secret log fields before the exporter sink", () => {
    const { gateway, exportedLogs } = harness();

    gateway.log({
      event: "provider.operation_completed",
      correlation: {
        requestId: "request-1",
        providerOperationId: "provider-op-1",
        studioId: "studio-1",
        previewId: "preview-1",
        collabTurnId: "turn-1",
      },
      outcome: "succeeded",
      reason: "upstream_unavailable",
      prompt: `do not ship ${SECRET}`,
      accessToken: SECRET,
      signedUrl: SIGNED_URL,
      nested: { secret: SECRET },
    });

    expect(exportedLogs).toEqual([{
      event: "provider.operation_completed",
      correlation: {
        requestId: "request-1",
        providerOperationId: "provider-op-1",
        studioId: "studio-1",
        previewId: "preview-1",
        collabTurnId: "turn-1",
      },
      outcome: "succeeded",
      reason: "upstream_unavailable",
    }]);
    const text = JSON.stringify(exportedLogs);
    for (const forbidden of ["prompt", "accessToken", "signedUrl", "nested", "secret", SECRET, SIGNED_URL]) {
      expect(text).not.toContain(forbidden);
    }
  });

  it("rejects secret-shaped correlation IDs without exporting a metric or log", () => {
    const { gateway, exportedMetrics, exportedLogs } = harness();
    const correlation = { providerOperationId: SIGNED_URL };

    expect(() => gateway.metric("admission.accepted", 1, "count", correlation)).toThrow(
      "invalid correlation id",
    );
    expect(() => gateway.log({
      event: "provider.operation_completed",
      correlation,
      outcome: "failed",
    })).toThrow("invalid correlation id");

    expect(gateway.metrics.snapshot()).toEqual([]);
    expect(exportedMetrics).toEqual([]);
    expect(exportedLogs).toEqual([]);
  });

  it("isolates registry snapshots from caller, exporter, and prior-snapshot mutations", () => {
    const { gateway, exportedMetrics } = harness();
    const correlation = { requestId: "request-1" };

    gateway.metric("queue.oldest_age_seconds", 4.5, "seconds", correlation);
    correlation.requestId = "caller-mutated";
    exportedMetrics[0]!.correlation!.requestId = "exporter-mutated";

    const first = gateway.metrics.snapshot();
    expect(first).toEqual([{
      name: "queue.oldest_age_seconds",
      value: 4.5,
      unit: "seconds",
      correlation: { requestId: "request-1" },
    }]);
    first[0]!.value = 99;
    first[0]!.correlation!.requestId = "snapshot-mutated";
    first.length = 0;

    expect(gateway.metrics.snapshot()).toEqual([{
      name: "queue.oldest_age_seconds",
      value: 4.5,
      unit: "seconds",
      correlation: { requestId: "request-1" },
    }]);
  });

  it("publishes only literal boolean operational health facts", async () => {
    const { gateway } = harness({
      health: {
        anomaly: () => true,
        mail: async () => false,
        reservation: () => Promise.resolve(true),
        notification: () => false,
      },
    });

    const checks = await gateway.healthChecks();
    expect(checks).toEqual({
      anomaly: true,
      mail: false,
      reservation: true,
      notification: false,
    });
    for (const value of Object.values(checks)) expect(typeof value).toBe("boolean");
  });

  it.each([
    "anomaly",
    "mail",
    "reservation",
    "notification",
  ] as const)("omits malformed %s facts instead of coercing them to booleans", async (fact) => {
    for (const value of [undefined, "true", "false", 1, 0, null, {}, []]) {
      const { gateway } = harness({
        health: {
          anomaly: () => true,
          mail: () => true,
          reservation: () => true,
          notification: () => true,
          [fact]: () => value,
        },
      });
      const expected: GatewayOperationalHealthChecks = {
        anomaly: true,
        mail: true,
        reservation: true,
        notification: true,
      };
      delete expected[fact];

      expect(await gateway.healthChecks()).toEqual(expected);
    }
  });

  it("omits missing, malformed, and failed health probes without leaking errors", async () => {
    const { gateway } = harness({
      health: {
        mail: () => {
          throw new Error(SECRET);
        },
        reservation: async () => {
          throw new Error(SIGNED_URL);
        },
        notification: "yes" as unknown as () => unknown,
      },
    });

    const checks = await gateway.healthChecks();
    expect(checks).toEqual({});
    expect(JSON.stringify(checks)).not.toContain(SECRET);
    expect(JSON.stringify(checks)).not.toContain(SIGNED_URL);
    expect(await harness().gateway.healthChecks()).toEqual({});
  });

  it("does not retain a formerly healthy health value after a probe becomes malformed", async () => {
    let anomaly: unknown = true;
    const { gateway } = harness({
      health: {
        anomaly: () => anomaly,
        mail: () => true,
      },
    });

    const first = await gateway.healthChecks();
    expect(first).toEqual({ anomaly: true, mail: true });
    first.anomaly = false;
    anomaly = "true";

    expect(await gateway.healthChecks()).toEqual({ mail: true });
  });
});
