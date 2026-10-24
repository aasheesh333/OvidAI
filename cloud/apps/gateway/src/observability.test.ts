import { describe, expect, it } from "vitest";
import {
  correlationIds,
  createMetricRegistry,
  safeLogRecord,
} from "../../../packages/shared/src/observability.js";
import { createGatewayObservability, type GatewayLogRecord } from "./observability.js";

function harness() {
  const metrics = createMetricRegistry();
  const logs: GatewayLogRecord[] = [];
  const gateway = createGatewayObservability({
    recordMetric: (sample) => metrics.record(sample),
    sanitizeLog: (record) => safeLogRecord(record),
    emitLog: (record) => { logs.push(record); },
  });
  return { gateway, metrics, logs };
}

describe("createGatewayObservability", () => {
  it("emits correlated admission/queue/settlement/event/socket/provider metrics", () => {
    const { gateway, metrics } = harness();
    const ids = correlationIds({
      requestId: "request-1",
      runId: "run-1",
      connectionId: "connection-1",
      providerOperationId: "provider-op-1",
      previewId: "preview-1",
      collabTurnId: "turn-1",
    });
    gateway.metric("admission.accepted", 1, "count", ids);
    gateway.metric("queue.oldest_age_seconds", 4.5, "seconds", ids);
    gateway.metric("settlement.completed", 1, "count", ids);
    gateway.metric("events.lost", 0, "count", ids);
    gateway.metric("sockets.reconnects", 1, "count", ids);

    expect(metrics.snapshot()).toHaveLength(5);
    for (const sample of metrics.snapshot()) expect(sample.correlation).toEqual(ids);
  });

  it("carries connector/plugin/subagent/preview/collab/storage/notification measures through the same boundary", () => {
    const { gateway, metrics } = harness();
    for (const [name, unit] of [
      ["connectors.refresh_failures", "count"],
      ["plugins.lifecycle", "count"],
      ["subagents.slots", "gauge"],
      ["preview.processes", "gauge"],
      ["collab.outbox", "gauge"],
      ["storage.reservations", "count"],
      ["notifications.pruned", "count"],
    ] as const) {
      gateway.metric(name, 1, unit);
    }
    expect(metrics.snapshot().map((sample) => sample.name)).toEqual([
      "connectors.refresh_failures",
      "plugins.lifecycle",
      "subagents.slots",
      "preview.processes",
      "collab.outbox",
      "storage.reservations",
      "notifications.pruned",
    ]);
  });

  it("uses central log sanitization before the gateway sink sees a record", () => {
    const { gateway, logs } = harness();
    gateway.log({
      event: "collab.turn_completed",
      correlation: { requestId: "request-1", collabTurnId: "turn-1" },
      outcome: "succeeded",
      prompt: "private prompt",
      signedUrl: "https://files.example.test/private?signature=secret",
    });
    expect(logs).toEqual([{
      event: "collab.turn_completed",
      correlation: { requestId: "request-1", collabTurnId: "turn-1" },
      outcome: "succeeded",
    }]);
    expect(JSON.stringify(logs)).not.toContain("private prompt");
    expect(JSON.stringify(logs)).not.toContain("signature=secret");
  });
});
