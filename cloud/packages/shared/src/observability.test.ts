import { describe, expect, it } from "vitest";
import {
  childCorrelation,
  correlationIds,
  createMetricRegistry,
  METRIC_NAMES,
  redactSensitiveText,
  safeLogRecord,
} from "./observability.js";

const KEY = "sk-live-canary";
const SIGNED_URL = `https://storage.example.test/private?X-Amz-Signature=${KEY}`;

describe("correlation ids", () => {
  it("links request, run, connection, provider, Studio/preview and collab without sensitive labels", () => {
    const ids = correlationIds({
      requestId: "request-1",
      runId: "run-parent",
      parentRunId: "run-root",
      connectionId: "connection-1",
      providerOperationId: "provider-op-1",
      studioId: "studio-1",
      previewId: "preview-1",
      collabTurnId: "turn-1",
      prompt: `private prompt ${KEY}`,
      token: KEY,
      signedUrl: SIGNED_URL,
      secret: KEY,
    });
    expect(ids).toEqual({
      requestId: "request-1",
      runId: "run-parent",
      parentRunId: "run-root",
      connectionId: "connection-1",
      providerOperationId: "provider-op-1",
      studioId: "studio-1",
      previewId: "preview-1",
      collabTurnId: "turn-1",
    });
    const text = JSON.stringify(ids);
    for (const forbidden of ["prompt", "token", "signedUrl", "secret", KEY, SIGNED_URL]) {
      expect(text).not.toContain(forbidden);
    }
  });

  it("derives a child run while retaining the original request and parent lineage", () => {
    const parent = correlationIds({ requestId: "request-1", runId: "run-parent", connectionId: "connection-1" });
    expect(childCorrelation(parent, "run-child")).toEqual({
      requestId: "request-1",
      runId: "run-child",
      parentRunId: "run-parent",
      connectionId: "connection-1",
    });
  });

  it("rejects URLs, signed parameters, key material and malformed ids without echoing them", () => {
    for (const value of [SIGNED_URL, KEY, "Bearer secret-token", "line one\nline two", "a".repeat(129)]) {
      let error: unknown;
      try {
        correlationIds({ providerOperationId: value });
      } catch (caught) {
        error = caught;
      }
      expect(error).toBeInstanceOf(TypeError);
      expect(String(error)).toBe("TypeError: invalid correlation id");
      expect(String(error)).not.toContain(value);
    }
  });
});

describe("metrics", () => {
  it("covers every required operational domain and the specific degraded/integrity measures", () => {
    expect(new Set(METRIC_NAMES.map((name) => name.split(".")[0]))).toEqual(new Set([
      "admission",
      "queue",
      "settlement",
      "events",
      "sockets",
      "approval",
      "connectors",
      "plugins",
      "subagents",
      "preview",
      "collab",
      "storage",
      "notifications",
    ]));
    expect(METRIC_NAMES).toEqual(expect.arrayContaining([
      "admission.accepted",
      "queue.oldest_age_seconds",
      "settlement.completed",
      "events.lost",
      "events.duplicates",
      "sockets.reconnects",
      "approval.age_seconds",
      "connectors.refresh_failures",
      "connectors.egress_refusals",
      "connectors.cap_hits",
      "plugins.lifecycle",
      "subagents.slots",
      "subagents.wake_duplicates",
      "subagents.cleanup",
      "preview.processes",
      "collab.leases",
      "collab.outbox",
      "collab.members",
      "storage.reservations",
      "notifications.registrations",
      "notifications.deliveries",
      "notifications.pruned",
    ]));
  });

  it("records validated finite samples with correlation and isolates snapshots", () => {
    const registry = createMetricRegistry();
    const ids = correlationIds({ requestId: "request-1", runId: "run-1" });
    registry.record({ name: "queue.oldest_age_seconds", value: 12.5, unit: "seconds", correlation: ids });
    registry.record({ name: "events.duplicates", value: 2, unit: "count" });
    expect(registry.snapshot()).toEqual([
      { name: "queue.oldest_age_seconds", value: 12.5, unit: "seconds", correlation: ids },
      { name: "events.duplicates", value: 2, unit: "count" },
    ]);

    const snapshot = registry.snapshot();
    snapshot[0]!.correlation!.requestId = "changed";
    expect(registry.snapshot()[0]!.correlation!.requestId).toBe("request-1");
  });

  it("refuses arbitrary metric labels, unknown measures and non-finite values", () => {
    const registry = createMetricRegistry();
    expect(() => registry.record({ name: "prompt", value: 1, unit: "count" })).toThrow("unknown metric");
    expect(() => registry.record({ name: "queue.oldest_age_seconds", value: Number.NaN, unit: "seconds" })).toThrow("invalid metric value");
    expect(registry.snapshot()).toEqual([]);
  });
});

describe("central redaction", () => {
  it("drops non-observability fields rather than serializing prompts, tokens, URLs or secrets", () => {
    const record = safeLogRecord({
      event: "provider.operation_completed",
      correlation: { requestId: "request-1", providerOperationId: "provider-op-1" },
      outcome: "succeeded",
      reason: "upstream_unavailable",
      prompt: `do not ship ${KEY}`,
      accessToken: KEY,
      signedUrl: SIGNED_URL,
      nested: { secret: KEY },
    });
    expect(record).toEqual({
      event: "provider.operation_completed",
      correlation: { requestId: "request-1", providerOperationId: "provider-op-1" },
      outcome: "succeeded",
      reason: "upstream_unavailable",
    });
    const text = JSON.stringify(record);
    for (const forbidden of ["prompt", "accessToken", "signedUrl", "nested", "secret", KEY, SIGNED_URL]) {
      expect(text).not.toContain(forbidden);
    }
  });

  it("redacts bearer/key/JWT credentials and complete URLs from unavoidable text", () => {
    const jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1MSJ9.c2lnbmF0dXJl";
    const redacted = redactSensitiveText(`Bearer ${KEY} key=${KEY} jwt=${jwt} url=${SIGNED_URL}`);
    expect(redacted).not.toContain(KEY);
    expect(redacted).not.toContain(jwt);
    expect(redacted).not.toContain("X-Amz-Signature");
    expect(redacted).toContain("[redacted]");
  });
});
