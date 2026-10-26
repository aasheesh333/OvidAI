import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  ADDITIVE_SUBAGENT_EVENT_TYPES,
  CONTRACT_VERSION,
  attachmentCreateContractSchema,
  attachmentUploadResponseContractSchema,
  compactionCompletedDiagnosticsSchema,
  mainCompactionDiagnosticsSchema,
  mcpConnectionsResponseContractSchema,
  structuredSubagentReportSchema,
  subagentCompactedPayloadSchema,
  subagentSessionProjectionSchema,
  subagentSummarySchema,
  subagentLifecycleEventSchema,
} from "./contracts.js";
import { mcpServerDtoSchema } from "./mcpRest.js";

function fixture(name: string): any {
  return JSON.parse(
    readFileSync(new URL(`../contracts/fixtures/${name}.json`, import.meta.url), "utf8"),
  );
}

describe("versioned attachment and connection contracts", () => {
  it("accepts legacy and typed attachment requests while keeping create bodies strict", () => {
    const attachments = fixture("attachments-v1");
    expect(CONTRACT_VERSION).toBe(1);
    expect(attachments.contractVersion).toBe(CONTRACT_VERSION);
    expect(attachmentCreateContractSchema.parse(attachments.create.legacy)).toEqual(
      attachments.create.legacy,
    );
    expect(attachmentCreateContractSchema.parse(attachments.create.typed)).toEqual(
      attachments.create.typed,
    );
    expect(() =>
      attachmentCreateContractSchema.parse({ ...attachments.create.typed, unexpected: true }),
    ).toThrow();
  });

  it("accepts old upload responses and additive signed headers without accepting unknown keys", () => {
    const responses = fixture("attachments-v1").uploadResponses;
    expect(attachmentUploadResponseContractSchema.parse(responses.legacy)).toEqual(responses.legacy);
    expect(attachmentUploadResponseContractSchema.parse(responses.typed)).toEqual(responses.typed);
    expect(attachmentUploadResponseContractSchema.parse(responses.typed).uploadHeaders).toEqual({
      "Content-Type": "application/pdf",
    });
    expect(() =>
      attachmentUploadResponseContractSchema.parse({ ...responses.typed, signedUrl: "do-not-add" }),
    ).toThrow();
  });

  it("keeps the legacy server array readable and parses the configured-connection envelope", () => {
    const connections = fixture("connections-v1");
    expect(connections.legacyListResponse).toHaveLength(1);
    expect(mcpServerDtoSchema.parse(connections.legacyListResponse[0])).toEqual(
      connections.legacyListResponse[0],
    );
    expect(mcpConnectionsResponseContractSchema.parse(connections.configuredResponse)).toEqual(
      connections.configuredResponse,
    );
    expect(connections.configuredResponse.items[0].agentEnabled).toBe(false);
    expect(connections.configuredResponse.items[0].healthState).toBe("never_checked");
    expect(JSON.stringify(connections.configuredResponse)).not.toContain("secrets_sealed");
    expect(() =>
      mcpConnectionsResponseContractSchema.parse({
        items: [{ ...connections.configuredResponse.items[0], plaintextSecret: "no" }],
      }),
    ).toThrow();
  });
});

describe("subagent lifecycle and report contracts", () => {
  it("matches the shipped Web/Flutter SubagentSessionProjection and full summary shape", () => {
    const item = {
      requestId: "request-1",
      deferredRequestId: null,
      logicalWorkerId: "worker-1",
      childSessionId: "child-1",
      childRunId: "child-run-1",
      attemptId: "attempt-1",
      attemptNumber: 1,
      rootTaskRunId: "root-run-1",
      parentRunId: "root-run-1",
      batchId: "batch-1",
      agentType: "general-purpose",
      launchReason: "Independent work",
      schedulingReason: "Main selected it",
      prompt: "bounded prompt",
      promptTruncated: false,
      summary: "done",
      error: null,
      requestedAt: "2026-10-24T12:00:00.000Z",
      deferredAt: null,
      admittedAt: "2026-10-24T12:00:01.000Z",
      startedAt: "2026-10-24T12:00:02.000Z",
      endedAt: "2026-10-24T12:01:00.000Z",
      startKnown: true,
      status: "completed",
      lastActivity: "subagent_completed",
      lastActivityAt: "2026-10-24T12:01:00.000Z",
      lastCursor: null,
      structuredReport: {
        subagent_id: "child-1",
        status: "completed",
        files_modified: ["src/a.ts"],
        artifacts_created: [],
        key_findings: "Actual finding",
        error_if_any: null,
      },
      logAvailable: false,
      compaction: null,
      steps: [],
    } as const;
    const page = {
      counts: {
        total: 1,
        running: 0,
        awaiting_next_user_task: 0,
        completed: 1,
        failed: 0,
        cancelled: 0,
        timeout: 0,
      },
      items: [item],
      nextCursor: "opaque-after",
    } as const;
    expect(subagentSummarySchema.parse(item)).toEqual(item);
    expect(subagentSessionProjectionSchema.parse(page)).toEqual(page);
    expect(() => subagentSummarySchema.parse({ ...item, inventedAlias: true })).toThrow();
    expect(() => subagentSummarySchema.parse({ ...item, prompt: "x".repeat(201) })).toThrow();
    expect(() =>
      subagentSessionProjectionSchema.parse({ ...page, counts: { ...page.counts, total: 2 } }),
    ).not.toThrow();
  });

  it("declares exactly the six additive scheduling/control/compaction/finalization event names", () => {
    expect(ADDITIVE_SUBAGENT_EVENT_TYPES).toEqual([
      "subagent_requested",
      "subagent_deferred",
      "subagent_admitted",
      "subagent_controlled",
      "subagent_compacted",
      "root_finalized",
    ]);
  });

  it("parses every rich and minimal lifecycle fixture and retains unknown optional fields", () => {
    const events = fixture("subagents-v1").events;
    expect(events.map((event: { type: string }) => event.type)).toEqual([
      "subagent_requested",
      "subagent_deferred",
      "subagent_admitted",
      "subagent_started",
      "subagent_controlled",
      "subagent_completed",
      "root_finalized",
    ]);
    for (const event of events) {
      expect(subagentLifecycleEventSchema.parse(event)).toEqual(event);
    }
    const withFutureField = {
      ...events[0],
      futureOptionalField: { addedBy: "a-newer-server" },
    };
    expect(subagentLifecycleEventSchema.parse(withFutureField)).toEqual(withFutureField);
    expect(() => subagentLifecycleEventSchema.parse({ ...events[0], status: "queued" })).toThrow();
    expect(() => subagentLifecycleEventSchema.parse({ ...events[0], runId: undefined })).toThrow();
  });

  it("parses the exact current minimal started and completed producer payloads unchanged", () => {
    const legacy = fixture("subagents-v1").legacyCurrentEmissions;
    const started = {
      runId: "parent-run",
      childSessionId: "child-session",
      childRunId: "child-run",
      prompt: "Inspect the current contract fixture",
      agentType: "general-purpose",
    };
    const completed = {
      childRunId: "child-run",
      status: "completed",
      childSessionId: "child-session",
      agentType: "general-purpose",
      summary: "child answer",
    };
    expect(started).toEqual(legacy.started);
    expect(completed).toEqual(legacy.completed);
    for (const [type, payload] of [
      ["subagent_started", started],
      ["subagent_completed", completed],
    ] as const) {
      const event = { type, sessionId: "session-1", ...payload };
      expect(subagentLifecycleEventSchema.parse(event)).toEqual(event);
    }
  });

  it("allows omitted or null pre-admission IDs and null or omitted pre-start timestamps", () => {
    const [requested, deferred] = fixture("subagents-v1").events;
    const variants = [
      requested,
      deferred,
      { ...requested, childRunId: undefined, childSessionId: undefined },
      { ...deferred, childRunId: undefined, childSessionId: undefined },
      { ...requested, admittedAt: undefined, startedAt: undefined },
      { ...deferred, admittedAt: undefined, startedAt: undefined },
    ];
    for (const event of variants) {
      expect(subagentLifecycleEventSchema.parse(event)).toEqual(event);
    }
    for (const event of [requested, deferred]) {
      expect(() => subagentLifecycleEventSchema.parse({ ...event, childRunId: "premature-run" })).toThrow();
      expect(() => subagentLifecycleEventSchema.parse({ ...event, childSessionId: "premature-child" })).toThrow();
      expect(() => subagentLifecycleEventSchema.parse({ ...event, admittedAt: "2026-10-24T12:00:00Z" })).toThrow();
      expect(() => subagentLifecycleEventSchema.parse({ ...event, startedAt: "2026-10-24T12:00:00Z" })).toThrow();
      expect(() => subagentLifecycleEventSchema.parse({ ...event, childRunId: 42 })).toThrow();
      expect(() => subagentLifecycleEventSchema.parse({ ...event, childSessionId: 42 })).toThrow();
    }
  });

  it("validates known additive fields only when present and rejects conflicting terminal state", () => {
    const events = fixture("subagents-v1").events;
    const legacy = fixture("subagents-v1").legacyCurrentEmissions;
    const started = { type: "subagent_started", sessionId: "session-1", ...legacy.started };
    const completed = { type: "subagent_completed", sessionId: "session-1", ...legacy.completed };
    const malformed = [
      { ...events[0], capacity: undefined },
      { ...events[0], prompt: undefined },
      { ...events[3], startedAt: null },
      { ...events[3], admittedAt: null },
      { ...events[4], actorKind: "public_client" },
      { ...fixture("compaction-v1").worker.event, workerId: undefined },
      { ...started, batchId: 42 },
      { ...started, rootTaskRunId: 42 },
      { ...started, startedAt: 42 },
      { ...started, admittedAt: null },
      { ...started, attemptNumber: 0 },
      { ...started, status: "completed" },
      { ...completed, status: "running" },
      { ...completed, status: "queued" },
      { ...completed, endedAt: 42 },
      { ...completed, structuredReport: { status: "completed" } },
      { ...events[5], structuredReport: { ...events[5].structuredReport, status: "failed" } },
      { ...events[5], structuredReport: { ...events[5].structuredReport, subagent_id: "other-worker" } },
    ];
    for (const event of malformed) {
      expect(() => subagentLifecycleEventSchema.parse(event), event.type).toThrow();
    }
  });

  it("requires durable deferral status, ID, reason, and provenance", () => {
    const deferred = fixture("subagents-v1").events[1];
    const malformed = [
      { ...deferred, status: "running" },
      { ...deferred, deferredRequestId: undefined },
      { ...deferred, reason: undefined },
      { ...deferred, provenance: undefined },
    ];
    for (const event of malformed) {
      expect(() => subagentLifecycleEventSchema.parse(event)).toThrow();
    }
  });

  it("requires real admission time, actor, reason, and nonnegative slot counts", () => {
    const admitted = fixture("subagents-v1").events[2];
    const malformed = [
      { ...admitted, admittedAt: null },
      { ...admitted, schedulingReason: undefined },
      { ...admitted, decisionActorRunId: undefined },
      { ...admitted, availableSlotsBefore: undefined },
      { ...admitted, availableSlotsAfter: undefined },
      { ...admitted, availableSlotsBefore: -1 },
      { ...admitted, availableSlotsAfter: -1 },
    ];
    for (const event of malformed) {
      expect(() => subagentLifecycleEventSchema.parse(event)).toThrow();
    }
  });

  it("requires a settled epoch and exactly-one finalization record", () => {
    const finalized = fixture("subagents-v1").events[6];
    const malformed = [
      { ...finalized, executionEpoch: undefined },
      { ...finalized, activeWorkerCount: undefined },
      { ...finalized, activeWorkerCount: 1 },
      { ...finalized, reportsIncluded: undefined },
      { ...finalized, finalSynthesisCount: undefined },
      { ...finalized, finalSynthesisCount: 0 },
      { ...finalized, finalizedAt: undefined },
    ];
    for (const event of malformed) {
      expect(() => subagentLifecycleEventSchema.parse(event)).toThrow();
    }
  });

  it("accepts compacted events and future optional fields on every lifecycle variant", () => {
    const events = [...fixture("subagents-v1").events, fixture("compaction-v1").worker.event];
    for (const event of events) {
      const withFutureField = { ...event, futureOptionalField: { addedBy: "a-newer-server" } };
      expect(subagentLifecycleEventSchema.parse(withFutureField)).toEqual(withFutureField);
    }
  });

  it("keeps current compaction_completed diagnostics distinct and accepts additive metadata", () => {
    const compaction = fixture("compaction-v1");
    for (const current of [compaction.legacyDiagnostics.withRunId, compaction.legacyDiagnostics.withoutRunId]) {
      expect(compactionCompletedDiagnosticsSchema.parse(current)).toEqual(current);
      const withFutureField = { ...current, futureOptionalField: { retained: true } };
      expect(compactionCompletedDiagnosticsSchema.parse(withFutureField)).toEqual(withFutureField);
    }
    const rich = compaction.legacyDiagnostics.workerRichDiagnostic;
    expect(compactionCompletedDiagnosticsSchema.parse(rich)).toEqual(rich);
    for (const malformed of [
      { ...rich, folded: -1 },
      { ...rich, retained: "3" },
      { ...rich, narrative: "yes" },
      { ...rich, actorKind: "unknown" },
    ]) {
      expect(() => compactionCompletedDiagnosticsSchema.parse(malformed)).toThrow();
    }
  });

  it("requires exactly six report keys and a bounded key_findings string", () => {
    expect(Object.keys(structuredSubagentReportSchema.shape).sort()).toEqual(
      [
        "subagent_id",
        "status",
        "files_modified",
        "artifacts_created",
        "key_findings",
        "error_if_any",
      ].sort(),
    );
    const reports = fixture("subagents-v1").terminalReports;
    for (const report of reports) {
      expect(Object.keys(report)).toHaveLength(6);
      expect(structuredSubagentReportSchema.parse(report)).toEqual(report);
    }
    expect(() =>
      structuredSubagentReportSchema.parse({ ...reports[0], private_thoughts: "not-wire-data" }),
    ).toThrow();
    const { error_if_any: _omitted, ...missingKey } = reports[1];
    expect(() => structuredSubagentReportSchema.parse(missingKey)).toThrow();
    expect(() =>
      structuredSubagentReportSchema.parse({ ...reports[0], key_findings: "x".repeat(4001) }),
    ).toThrow();
    expect(() =>
      structuredSubagentReportSchema.parse({ ...reports[0], key_findings: ["not", "a", "string"] }),
    ).toThrow();
  });

  it("never gives one logical worker conflicting terminal outcomes", () => {
    const subagents = fixture("subagents-v1");
    const terminalStatuses = new Set(["completed", "failed", "cancelled", "timeout"]);
    const outcomes = new Map<string, string>();
    const record = (workerId: string, status: string) => {
      if (!terminalStatuses.has(status)) return;
      expect(outcomes.get(workerId) ?? status, workerId).toBe(status);
      outcomes.set(workerId, status);
    };
    for (const event of subagents.events) {
      record(event.logicalWorkerId ?? event.childSessionId, event.status);
    }
    for (const report of subagents.terminalReports) {
      record(report.subagent_id, report.status);
    }
  });

  it("keeps ordinary and self-described urgent messages non-preempting without invented progress", () => {
    const raw = readFileSync(
      new URL("../contracts/fixtures/subagents-v1.json", import.meta.url),
      "utf8",
    );
    const scenarios = fixture("subagents-v1").nonPreemption;
    expect(scenarios.map((scenario: { name: string }) => scenario.name)).toEqual([
      "ordinary",
      "self-described-urgent",
    ]);
    for (const scenario of scenarios) {
      expect(scenario.newRootAccepted).toBe(true);
      expect(scenario.rootCancelled).toBe(false);
      expect(scenario.cancelledWorkerIds).toEqual([]);
      expect(scenario.executionEpochChanged).toBe(false);
      expect(scenario.finalResponseEmitted).toBe(false);
    }
    expect(raw).not.toMatch(/"progress"\s*:\s*95/);
  });
});

describe("lossless compaction contracts", () => {
  it("covers exact 79/80 percent boundaries for three model limits and both usage sources", () => {
    const boundaries = fixture("compaction-v1").thresholdBoundaries;
    expect(new Set(boundaries.map((row: { contextLimit: number }) => row.contextLimit))).toEqual(
      new Set([1000, 32000, 128000]),
    );
    expect(new Set(boundaries.map((row: { usageSource: string }) => row.usageSource))).toEqual(
      new Set(["measured", "deterministic_fallback"]),
    );
    for (const row of boundaries) {
      expect(row.beforeTokens * 100 >= row.contextLimit * 80).toBe(row.shouldCompact);
      expect(row.percent).toBe((row.beforeTokens * 100) / row.contextLimit);
    }
  });

  it("parses worker and main compaction with exact operational metadata and no thought payload", () => {
    const compaction = fixture("compaction-v1");
    expect(subagentCompactedPayloadSchema.parse(compaction.worker.event)).toEqual(
      compaction.worker.event,
    );
    expect(mainCompactionDiagnosticsSchema.parse(compaction.main.event)).toEqual(compaction.main.event);
    expect(compaction.worker.event.continuation).toBe("continuing_existing_task");
    expect(compaction.main.event.actorKind).toBe("main");
    expect(compaction.main.ordinaryChatEmitted).toBe(false);
    expect(compaction.worker.event.type).toBe("subagent_compacted");
    expect(() =>
      subagentCompactedPayloadSchema.parse({ ...compaction.worker.event, thoughts: "private" }),
    ).toThrow();
    expect(() =>
      subagentCompactedPayloadSchema.parse({ ...compaction.worker.event, beforeTokens: -1 }),
    ).toThrow();
  });

  it("keeps main/worker cursors isolated and validates approved exact recall chunks for both", async () => {
    const { exactRecallChunkSchema, exactRecallPageSchema } = await import("./contracts.js");
    const compaction = fixture("compaction-v1");
    expect(compaction.main.cursor.logicalWorkerId).toBeNull();
    expect(compaction.worker.cursor.logicalWorkerId).toBe("worker-1");
    expect(compaction.main.cursor.compactionId).not.toBe(compaction.worker.cursor.compactionId);
    for (const actor of [compaction.main, compaction.worker]) {
      expect(actor.cursor.continuation).toBe("continuing_existing_task");
      const page = exactRecallPageSchema.parse(actor.exactRecallPage);
      expect(page).toEqual(actor.exactRecallPage);
      expect(page.nextCursor).toBeNull();
      expect(page.chunks.map((chunk) => chunk.item.stableId)).toEqual([
        `${actor.cursor.actorKind}-message-1`,
        `${actor.cursor.actorKind}-tool-1`,
      ]);
      for (const chunk of page.chunks) {
        expect(exactRecallChunkSchema.parse(chunk)).toEqual(chunk);
        expect(chunk.offset).toBe(0);
        expect(chunk.nextOffset).toBeNull();
        expect(chunk.item.sessionId).toBe("session-1");
        expect(chunk.item.rootTaskRunId).toBe(actor.cursor.rootTaskRunId);
        expect(chunk.item.byteLength).toBe(Buffer.byteLength(chunk.data));
        const payloadForms = ["inlinePayload", "objectRef"].filter((key) =>
          Object.hasOwn(chunk.item, key),
        );
        expect(payloadForms).toHaveLength(1);
        if (payloadForms[0] === "inlinePayload") {
          expect(JSON.parse(chunk.data)).toEqual(chunk.item.inlinePayload);
        } else {
          expect(JSON.parse(chunk.data).toolCallId).toBe(chunk.item.stableId);
        }
      }
    }
  });

  it("enforces exactly one exact-history payload form and strict chunk fields", async () => {
    const { exactHistoryItemSchema, exactRecallChunkSchema, historyItemKindSchema } = await import(
      "./contracts.js"
    );
    const item = {
      stableId: "message-1",
      kind: "message",
      sessionId: "session-1",
      rootTaskRunId: "root-1",
      logicalWorkerId: null,
      attemptId: "attempt-1",
      eventCursor: "event-1",
      inlinePayload: { content: "exact" },
      byteLength: 18,
    };
    expect(exactHistoryItemSchema.parse(item)).toEqual(item);
    const { inlinePayload: _inline, ...withoutPayload } = item;
    const referenced = { ...withoutPayload, objectRef: "object:1" };
    expect(exactHistoryItemSchema.parse(referenced)).toEqual(referenced);
    expect(() => exactHistoryItemSchema.parse(withoutPayload)).toThrow();
    expect(() => exactHistoryItemSchema.parse({ ...item, objectRef: "object:1" })).toThrow();
    expect(() => exactHistoryItemSchema.parse({ ...item, payload: { content: "wrong" } })).toThrow();
    for (const kind of [
      "message",
      "tool_call",
      "approval",
      "artifact",
      "file",
      "logical_worker",
      "attempt",
      "checkpoint",
      "compaction",
      "event",
      "control",
    ]) {
      expect(historyItemKindSchema.parse(kind)).toBe(kind);
    }
    expect(() => historyItemKindSchema.parse("private_thoughts")).toThrow();
    const chunk = { item, offset: 0, data: '{"content":"exact"}', nextOffset: null };
    expect(exactRecallChunkSchema.parse(chunk)).toEqual(chunk);
    expect(() => exactRecallChunkSchema.parse({ ...chunk, data: undefined })).toThrow();
    expect(() => exactRecallChunkSchema.parse({ ...chunk, offset: -1 })).toThrow();
    expect(() => exactRecallChunkSchema.parse({ ...chunk, items: [item] })).toThrow();
  });
});
