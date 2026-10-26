import { afterAll, beforeAll, describe, expect, it } from "vitest";

import type {
  AgentMessage,
  CompactionInput,
  CompactorWithManual,
  EventSink,
} from "@ovid/agent-core";
import { applyCheckpoint, foldBoundaryFor } from "@ovid/agent-core";
import {
  admitDispatches,
  createDb,
  eventMirror,
  messages,
  migrate,
  newId,
  readExactHistory,
  runs,
  sessionState,
  sessions,
  users,
  type CompactionActor,
  type CompactionOutcome,
  type Db,
  type FoldCheckpointInput,
} from "@ovid/db";
import {
  mainCompactionDiagnosticsSchema,
  subagentCompactedPayloadSchema,
  type SessionEventType,
} from "@ovid/shared";

import {
  createMigrationScratch,
  type MigrationScratch,
} from "../../../packages/db/src/migrationTestKit.js";
import {
  createWorkerCompactionRuntime,
  workerCompactionOutcomeFor,
  type CanonicalCompactionRequest,
  type WorkerCompactionBinding,
  type WorkerCompactionResolution,
} from "./compactionRuntime.js";
import {
  createCompactionContinuation,
  recoverPendingCompactionContinuations,
} from "./compactionContinuation.js";

// UNEXECUTED under HEAVY-COMMANDS-PAUSED.md. This suite was authored before the
// implementation as the regression source. No RED/GREEN, typecheck, migration,
// real-Postgres, or production evidence is claimed by this file.

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const FALLBACK = {
  contextLimit: 8_192,
  outputReserveTokens: 512,
  providerReserveTokens: 64,
};
const SAFE_BOUNDARY = {
  beforeModelRequest: true,
  toolCallsTerminal: true,
  approvalsTerminal: true,
} as const;
const NOW = new Date("2026-10-25T12:00:00.000Z");

interface Emitted {
  /** Present when a test double models the real session-scoped event sink. */
  sessionId?: string;
  type: SessionEventType;
  payload: Record<string, unknown>;
}

function history(count = 12, prefix = "message"): AgentMessage[] {
  return Array.from({ length: count }, (_, index) => ({
    role: index % 2 === 0 ? "user" : "assistant",
    content: `${prefix}-${index}`,
    id: `00000000-0000-7000-8000-${String(index + 1).padStart(12, "0")}`,
  }));
}

/** Exact provider-body fixture plus its independently checkable source rows. */
function canonicalRequest(
  model: string,
  sourceMessages: readonly AgentMessage[],
): CanonicalCompactionRequest {
  const snapshot = (rows: readonly AgentMessage[]) => ({
    sourceMessages: rows,
    body: {
      model,
      messages: rows.map((row) => ({ role: row.role, content: row.content })),
      tools: [],
    },
  });
  return {
    ...snapshot(sourceMessages),
    rebuild: snapshot,
  };
}

function folded(input: FoldCheckpointInput, id = "fold"): CompactionOutcome {
  const retained = input.messages.slice(-2);
  return {
    compacted: true,
    messages: [
      { role: "system", content: `<compacted-summary>${id}</compacted-summary>`, volatile: false },
      ...retained,
    ],
    foldBoundary: 1,
    compactionId: `${id}-compaction`,
    checkpointId: `${id}-checkpoint`,
    cutoffCursor: `${id}-cursor`,
    contextLimit: input.profile.contextLimit,
    beforeTokens: input.usage.beforeTokens,
    afterTokens: 24,
    usageSource: input.usage.usageSource,
    continuation: "continuing_existing_task",
  };
}

function mainActor(sessionId = "main-session", rootTaskRunId = "main-run"): CompactionActor {
  return { sessionId, rootTaskRunId, logicalWorkerId: null, attemptId: null, kind: "main" };
}

function workerActor(sessionId = "child-session"): CompactionActor {
  return {
    sessionId,
    rootTaskRunId: "main-run",
    logicalWorkerId: "worker-1",
    attemptId: "attempt-1",
    kind: "worker",
  };
}

function resolutionFor(
  call: { messages: AgentMessage[] },
  overrides: Partial<WorkerCompactionResolution> = {},
): WorkerCompactionResolution {
  const model = overrides.model ?? "provider/main";
  return {
    actor: mainActor(),
    runId: "main-run",
    eventSessionId: "main-session",
    model,
    catalog: [{
      model_name: model,
      model_info: {
        max_input_tokens: 1_000,
        max_output_tokens: 100,
        provider_reserve_tokens: 7,
      },
    }],
    requestMaxOutputTokens: 10,
    measuredInputTokens: 800,
    request: canonicalRequest(model, call.messages),
    boundary: SAFE_BOUNDARY,
    ...overrides,
  };
}

function captureBinding(
  resolve: WorkerCompactionBinding["resolve"],
  emitted: Emitted[] = [],
): WorkerCompactionBinding {
  return {
    resolve,
    now: () => NOW,
    sink: {
      async emit(type, payload) {
        emitted.push({ type, payload });
      },
    },
  };
}

function legacyBase(): CompactorWithManual {
  return {
    async maybeCompact(input) {
      return { compacted: false, messages: input.messages, foldBoundary: input.foldBoundary ?? 0 };
    },
    async compactNow(input) {
      return {
        compacted: false,
        messages: input.messages,
        narrative: false,
        foldBoundary: input.foldBoundary ?? 0,
        status: "legacy base outcome",
      };
    },
    async pruneOversizedToolResults(input) {
      return { pruned: 0, messages: input.messages };
    },
  };
}

const fakeDb = {
  $client: { async unsafe() { return []; } },
} as unknown as Db;

/**
 * Pure-level continuation double. The real projection is covered by the
 * isolated-Postgres suite; these tests only need the bound-fold gate satisfied.
 */
function stubContinuation(
  calls: Array<{ checkpointId: string; actor: CompactionActor }> = [],
): {
  sync(input: { checkpointId: string; actor: CompactionActor }): Promise<{
    status: "applied";
    checkpointId: string;
    summary: string;
    cutoffMessageId: string;
    compactedAtCount: number;
  }>;
  reconcile(): Promise<null>;
} {
  return {
    async sync(input) {
      calls.push(input);
      return {
        status: "applied",
        checkpointId: input.checkpointId,
        summary: "stub summary",
        cutoffMessageId: "stub-cutoff",
        compactedAtCount: 1,
      };
    },
    async reconcile() {
      return null;
    },
  };
}

function pureRuntime(foldCheckpoint: (input: FoldCheckpointInput) => Promise<CompactionOutcome>) {
  return createWorkerCompactionRuntime({
    db: fakeDb,
    repository: { foldCheckpoint },
    fallback: FALLBACK,
    continuation: stubContinuation(),
  });
}

describe("worker compaction runtime (UNEXECUTED pure regressions)", () => {
  it("preserves an unbound legacy fake/base compactor verbatim", () => {
    const base = legacyBase();
    const runtime = pureRuntime(async () => {
      throw new Error("production repository must not be called by the compatibility path");
    });
    expect(runtime.wrapCompactor(base)).toBe(base);
  });

  it("does not fold at 79% and folds with complete metadata at exactly 80%", async () => {
    const folds: FoldCheckpointInput[] = [];
    const emitted: Emitted[] = [];
    const runtime = pureRuntime(async (input) => {
      folds.push(input);
      return folded(input);
    });
    const compactor = runtime.wrapCompactor(legacyBase(), captureBinding(
      async (call) => ({ ...resolutionFor(call), measuredInputTokens: 790 }),
      emitted,
    ));
    const input: CompactionInput = {
      sessionId: "main-session",
      messages: history(),
      windowTokens: 100_000,
      foldBoundary: 0,
    };

    const below = await compactor.maybeCompact({
      ...input,
      messages: history(),
    });
    expect(below).toEqual({ compacted: false, messages: input.messages, foldBoundary: 0 });
    expect(folds).toHaveLength(0);

    // Change only exact provider usage: 790/1000 = 79%, 800/1000 = 80%.
    const at79 = runtime.wrapCompactor(legacyBase(), captureBinding(async (call) => ({
      ...resolutionFor(call),
      measuredInputTokens: 790,
    })));
    expect((await at79.maybeCompact(input)).compacted).toBe(false);
    expect(folds).toHaveLength(0);

    const at80Compactor = runtime.wrapCompactor(legacyBase(), captureBinding(
      async (call) => resolutionFor(call),
      emitted,
    ));
    const at80 = await at80Compactor.maybeCompact(input);
    expect(at80).toMatchObject({
      compacted: true,
      foldBoundary: 1,
      compactionId: "fold-compaction",
      checkpointId: "fold-checkpoint",
      cutoffCursor: "fold-cursor",
      contextLimit: 1_000,
      beforeTokens: 800,
      afterTokens: 24,
      usageSource: "measured",
      continuation: "continuing_existing_task",
    });
    expect(folds).toHaveLength(1);
    expect(folds[0]).toMatchObject({
      profile: {
        model: "provider/main",
        contextLimit: 1_000,
        outputReserveTokens: 10,
        providerReserveTokens: 7,
      },
      usage: { usageSource: "measured", beforeTokens: 800 },
      actor: mainActor(),
      foldBoundary: 0,
    });
    expect(emitted).toHaveLength(1);
  });

  it("uses each selected model's exact limit/reserves and never the legacy 100,000 cap", async () => {
    const folds: FoldCheckpointInput[] = [];
    const runtime = pureRuntime(async (input) => {
      folds.push(input);
      return folded(input, input.profile.model);
    });
    const rows = [{
      model_name: "provider/million",
      litellm_params: { model: "deployment/million" },
      model_info: { max_input_tokens: 1_000_000, max_output_tokens: 4_000, provider_reserve_tokens: 500 },
    }];
    const binding = captureBinding(async (call) => ({
      ...resolutionFor(call),
      model: "deployment/million",
      catalog: rows,
      request: canonicalRequest("deployment/million", call.messages),
      requestMaxOutputTokens: undefined,
      measuredInputTokens: 100_000,
    }));
    const compactor = runtime.wrapCompactor(legacyBase(), binding);
    const input: CompactionInput = {
      sessionId: "main-session",
      messages: history(),
      windowTokens: 100_000,
    };

    expect((await compactor.maybeCompact(input)).compacted).toBe(false);
    expect(folds).toHaveLength(0);

    const at80 = runtime.wrapCompactor(legacyBase(), captureBinding(async (call) => ({
      ...resolutionFor(call),
      model: "deployment/million",
      catalog: rows,
      request: canonicalRequest("deployment/million", call.messages),
      requestMaxOutputTokens: undefined,
      measuredInputTokens: 800_000,
    })));
    expect((await at80.maybeCompact(input)).compacted).toBe(true);
    expect(folds[0]!.profile).toEqual({
      model: "deployment/million",
      contextLimit: 1_000_000,
      outputReserveTokens: 4_000,
      providerReserveTokens: 500,
    });
  });

  it("re-resolves A → B → A instead of caching an auto route's context profile", async () => {
    const folds: FoldCheckpointInput[] = [];
    const runtime = pureRuntime(async (input) => {
      folds.push(input);
      return folded(input, `${input.profile.model}-${folds.length}`);
    });
    const selected = ["provider/a", "provider/b", "provider/a"];
    const compactor = runtime.wrapCompactor(legacyBase(), captureBinding(async (call) => {
      const model = selected[folds.length]!;
      const contextLimit = model === "provider/a" ? 8_192 : 262_144;
      return {
        ...resolutionFor(call),
        model,
        catalog: [{ model_name: model, model_info: { max_input_tokens: contextLimit } }],
        request: canonicalRequest(model, call.messages),
        measuredInputTokens: contextLimit,
      };
    }));

    for (let index = 0; index < 3; index += 1) {
      expect((await compactor.maybeCompact({
        sessionId: "main-session",
        messages: history(12, `route-${index}`),
        windowTokens: 1,
      })).compacted).toBe(true);
    }
    expect(folds.map((fold) => [fold.profile.model, fold.profile.contextLimit])).toEqual([
      ["provider/a", 8_192],
      ["provider/b", 262_144],
      ["provider/a", 8_192],
    ]);
  });

  it("uses deterministic whole-request usage when exact measured input is unavailable", async () => {
    const folds: FoldCheckpointInput[] = [];
    const runtime = pureRuntime(async (input) => {
      folds.push(input);
      return folded(input);
    });
    let expectedTokens = 0;
    const compactor = runtime.wrapCompactor(legacyBase(), captureBinding(async (call) => {
      const base = resolutionFor(call, { measuredInputTokens: null });
      expectedTokens = Buffer.byteLength(JSON.stringify(base.request.body), "utf8") + 4 + 4 * call.messages.length;
      return {
        ...base,
        catalog: [{ model_name: base.model, model_info: { max_input_tokens: expectedTokens } }],
        measuredInputTokens: null,
      };
    }));
    expect((await compactor.maybeCompact({
      sessionId: "main-session",
      messages: history(),
      windowTokens: 1,
    })).compacted).toBe(true);
    expect(folds[0]!.usage).toEqual({
      usageSource: "deterministic_fallback",
      beforeTokens: expectedTokens,
    });
    expect(folds[0]!.usage.beforeTokens).toBeGreaterThan(0);
  });

  it("keeps safe manual /compact at 80% and honestly declines a forced fold at 79%", async () => {
    const folds: FoldCheckpointInput[] = [];
    const runtime = pureRuntime(async (input) => {
      folds.push(input);
      return folded(input, "manual");
    });
    const makeCompactor = (beforeTokens: number) => runtime.wrapCompactor(
      legacyBase(),
      captureBinding(async (call) => ({ ...resolutionFor(call), measuredInputTokens: beforeTokens })),
    );
    const input = {
      sessionId: "main-session",
      messages: history(),
      windowTokens: 32_000,
      foldBoundary: 0,
    };

    const manual = await makeCompactor(800).compactNow(input);
    expect(manual).toMatchObject({
      compacted: true,
      narrative: false,
      foldBoundary: 1,
      compactionId: "manual-compaction",
      checkpointId: "manual-checkpoint",
      cutoffCursor: "manual-cursor",
      continuation: "continuing_existing_task",
    });
    expect(manual.status).toContain("Session compacted");

    const below = await makeCompactor(790).compactNow(input);
    expect(below.compacted).toBe(false);
    expect(below.status).toContain("80%");
    expect(folds).toHaveLength(1);
  });

  it("replays the same fold outcome without emitting the operational event twice", async () => {
    const emitted: Emitted[] = [];
    const runtime = pureRuntime(async (input) => folded(input, "replay"));
    const compactor = runtime.wrapCompactor(legacyBase(), captureBinding(
      async (call) => resolutionFor(call),
      emitted,
    ));
    const input = { sessionId: "main-session", messages: history(), windowTokens: 1_000 };

    const first = await compactor.maybeCompact(input);
    const replay = await compactor.maybeCompact(input);
    expect(replay).toEqual(first);
    expect(emitted).toHaveLength(1);
  });

  it("scopes dormant mirror replay lookup by parent session, event type, and compaction ID", async () => {
    const emitted: Emitted[] = [];
    const queries: Array<{ sql: string; params: unknown[] }> = [];
    const scopedDb = {
      $client: {
        async unsafe(sql: string, params: unknown[]) {
          queries.push({ sql, params });
          // Model an unrelated same-ID diagnostic. Only the correctly scoped
          // lookup may ignore it and allow the parent worker event.
          if (
            params.length === 3 &&
            params[0] === "parent-session" &&
            params[1] === "subagent_compacted" &&
            params[2] === "worker-compaction"
          ) return [];
          return [{ type: "compaction_completed" }];
        },
      },
    } as unknown as Db;
    const runtime = createWorkerCompactionRuntime({
      db: scopedDb,
      repository: { foldCheckpoint: async (input) => folded(input, "worker") },
      fallback: FALLBACK,
      continuation: stubContinuation(),
    });
    const compactor = runtime.wrapCompactor(legacyBase(), captureBinding(async (call) => ({
      ...resolutionFor(call),
      actor: workerActor(),
      runId: "current-child-turn",
      eventSessionId: "parent-session",
    }), emitted));

    await compactor.maybeCompact({
      sessionId: "child-session",
      messages: history(),
      windowTokens: 1_000,
    });

    expect(emitted.map((event) => event.type)).toEqual(["subagent_compacted"]);
    expect(queries).toHaveLength(1);
    expect(queries[0]!.params).toEqual([
      "parent-session",
      "subagent_compacted",
      "worker-compaction",
    ]);
    expect(queries[0]!.sql).toContain("session_id = $1");
    expect(queries[0]!.sql).toContain("type = $2");
    expect(queries[0]!.sql).toContain("payload->>'compactionId' = $3");
  });

  it("passes scoped identity to an optional idempotent sink without using the legacy sink or mirror shortcut", async () => {
    const identities: Array<{
      sessionId: string;
      type: SessionEventType;
      compactionId: string;
    }> = [];
    const legacyEmissions: Emitted[] = [];
    let mirrorLookups = 0;
    const scopedDb = {
      $client: {
        async unsafe() {
          mirrorLookups += 1;
          return [];
        },
      },
    } as unknown as Db;
    const runtime = createWorkerCompactionRuntime({
      db: scopedDb,
      repository: { foldCheckpoint: async (input) => folded(input, "worker") },
      fallback: FALLBACK,
      continuation: stubContinuation(),
    });
    const binding: WorkerCompactionBinding = {
      ...captureBinding(async (call) => ({
        ...resolutionFor(call),
        actor: workerActor(),
        runId: "current-child-turn",
        eventSessionId: "parent-session",
      }), legacyEmissions),
      idempotentSink: {
        async emitOnce(identity, payload) {
          identities.push(identity);
          expect(payload.runId).toBe("current-child-turn");
          return "emitted";
        },
      },
    };

    await runtime.wrapCompactor(legacyBase(), binding).maybeCompact({
      sessionId: "child-session",
      messages: history(),
      windowTokens: 1_000,
    });

    expect(identities).toEqual([{
      sessionId: "parent-session",
      type: "subagent_compacted",
      compactionId: "worker-compaction",
    }]);
    expect(legacyEmissions).toHaveLength(0);
    expect(mirrorLookups).toBe(0);
  });

  it("exposes a typed terminal outcome for canonical pre-request proof failure", async () => {
    const runtime = pureRuntime(async (input) => folded(input));
    const compactor = runtime.wrapCompactor(legacyBase(), captureBinding(async () => null));
    const error = await compactor.maybeCompact({
      sessionId: "main-session",
      messages: history(),
      windowTokens: 1_000,
    }).then(() => null).catch((caught: unknown) => caught);

    expect(workerCompactionOutcomeFor(error)).toEqual({
      code: "compaction_context_unavailable",
      kind: "context_proof_unavailable",
      terminal: true,
      providerRequest: "suppress",
      retrySameRequest: false,
      legacyFallback: "forbidden",
    });
    expect(workerCompactionOutcomeFor(new Error("unrelated infrastructure failure"))).toBeNull();
  });

  it("fails closed when actor lineage or canonical request provenance is unprovable", async () => {
    let foldCalls = 0;
    const emitted: Emitted[] = [];
    const runtime = pureRuntime(async (input) => {
      foldCalls += 1;
      return folded(input);
    });
    const input = { sessionId: "main-session", messages: history(), windowTokens: 1_000 };
    const invalid: Array<WorkerCompactionResolution | null> = [
      null,
      { ...resolutionFor({ messages: input.messages }), runId: "different-root" },
      { ...resolutionFor({ messages: input.messages }), actor: mainActor("another-session") },
      {
        ...resolutionFor({ messages: input.messages }),
        actor: { ...workerActor("main-session"), attemptId: null },
        runId: "child-run",
      },
      {
        ...resolutionFor({ messages: input.messages }),
        request: canonicalRequest("provider/main", history(12, "not-the-input")),
      },
      {
        ...resolutionFor({ messages: input.messages }),
        request: {
          ...canonicalRequest("provider/main", input.messages),
          body: {
            model: "provider/main",
            messages: [],
            apiKey: "not-a-provider-body",
            baseUrl: "https://internal.invalid",
          },
        },
      },
      { ...resolutionFor({ messages: input.messages }), model: "auto" },
    ];

    for (const candidate of invalid) {
      const compactor = runtime.wrapCompactor(legacyBase(), captureBinding(async () => candidate, emitted));
      await expect(compactor.maybeCompact(input)).rejects.toMatchObject({ code: expect.any(String) });
    }
    expect(foldCalls).toBe(0);
    expect(emitted).toHaveLength(0);
  });

  it("emits schema-valid main/worker operational metadata and no chat/thought payload", async () => {
    const emitted: Emitted[] = [];
    const runtime = pureRuntime(async (input) => folded(input, input.actor.kind));
    const main = runtime.wrapCompactor(legacyBase(), captureBinding(
      async (call) => resolutionFor(call),
      emitted,
    ));
    await main.maybeCompact({ sessionId: "main-session", messages: history(), windowTokens: 1 });

    const worker = runtime.wrapCompactor(legacyBase(), captureBinding(async (call) => ({
      ...resolutionFor(call),
      actor: workerActor(),
      runId: "child-run",
      eventSessionId: "parent-session",
    }), emitted));
    await worker.maybeCompact({ sessionId: "child-session", messages: history(), windowTokens: 1 });

    expect(emitted.map((event) => event.type)).toEqual(["compaction_completed", "subagent_compacted"]);
    const mainEvent = mainCompactionDiagnosticsSchema.parse({
      type: emitted[0]!.type,
      sessionId: "main-session",
      ...emitted[0]!.payload,
    });
    const workerEvent = subagentCompactedPayloadSchema.parse({
      type: emitted[1]!.type,
      sessionId: "parent-session",
      ...emitted[1]!.payload,
    });
    expect(mainEvent.actorKind).toBe("main");
    expect(workerEvent.sessionId).toBe("parent-session");
    expect(workerEvent.workerId).toBe("worker-1");
    expect(workerEvent.continuation).toBe("continuing_existing_task");
    for (const event of emitted) {
      expect(event.type).not.toBe("message_completed");
      expect(event.payload).not.toHaveProperty("thoughts");
      expect(event.payload).not.toHaveProperty("messages");
      expect(event.payload).not.toHaveProperty("prompt");
      expect(event.payload).not.toHaveProperty("apiKey");
      expect(JSON.stringify(event.payload)).not.toContain("message-0");
    }
  });

  it("preserves prune-only relief without folding or reusing stale measured usage", async () => {
    let foldCalls = 0;
    const runtime = pureRuntime(async (input) => {
      foldCalls += 1;
      return folded(input);
    });
    const base = legacyBase();
    base.pruneOversizedToolResults = async (input) => ({
      pruned: 1,
      messages: input.messages.map((row, index) => index === 0 ? { ...row, content: "short" } : row),
    });
    const compactor = runtime.wrapCompactor(base, captureBinding(async (call) => resolutionFor(call)));
    const result = await compactor.maybeCompact({
      sessionId: "main-session",
      messages: history(),
      windowTokens: 1_000,
    });
    expect(result.compacted).toBe(false);
    expect(result.messages[0]!.content).toBe("short");
    expect(foldCalls).toBe(0);
  });

  it("does not fold across a nonterminal tool/approval boundary", async () => {
    let foldCalls = 0;
    const runtime = pureRuntime(async (input) => {
      foldCalls += 1;
      return folded(input);
    });
    const compactor = runtime.wrapCompactor(legacyBase(), captureBinding(async (call) => ({
      ...resolutionFor(call),
      boundary: { ...SAFE_BOUNDARY, approvalsTerminal: false },
    })));
    const result = await compactor.maybeCompact({
      sessionId: "main-session",
      messages: history(),
      windowTokens: 1_000,
    });
    expect(result.compacted).toBe(false);
    expect(foldCalls).toBe(0);
  });

  it("fails closed when the rebuilt next request still exceeds the exact model budget", async () => {
    const runtime = pureRuntime(async (input) => ({
      ...folded(input, "oversized"),
      messages: [
        { role: "system" as const, content: "x".repeat(2_000), volatile: false },
        ...input.messages.slice(-2),
      ],
    }));
    const compactor = runtime.wrapCompactor(legacyBase(), captureBinding(async (call) => resolutionFor(call)));
    const error = await compactor.maybeCompact({
      sessionId: "main-session",
      messages: history(),
      windowTokens: 1_000,
    }).then(() => null).catch((caught: unknown) => caught);
    expect(workerCompactionOutcomeFor(error)).toEqual({
      code: "next_request_over_limit",
      kind: "context_limit_exceeded",
      terminal: true,
      providerRequest: "suppress",
      retrySameRequest: false,
      legacyFallback: "forbidden",
    });
  });

  it("refuses a production fold with missing metadata instead of inventing it", async () => {
    const emitted: Emitted[] = [];
    const runtime = pureRuntime(async (input) => ({
      compacted: true,
      messages: input.messages,
      foldBoundary: 1,
    }));
    const compactor = runtime.wrapCompactor(legacyBase(), captureBinding(
      async (call) => resolutionFor(call),
      emitted,
    ));
    await expect(compactor.maybeCompact({
      sessionId: "main-session",
      messages: history(),
      windowTokens: 1_000,
    })).rejects.toMatchObject({ code: "invalid_fold_outcome" });
    expect(emitted).toHaveLength(0);
  });

  it("fails closed when a committed fold has no continuation synchronizer bound", async () => {
    const emitted: Emitted[] = [];
    const runtime = createWorkerCompactionRuntime({
      db: fakeDb,
      repository: { foldCheckpoint: async (input) => folded(input) },
      fallback: FALLBACK,
    });
    const compactor = runtime.wrapCompactor(legacyBase(), captureBinding(
      async (call) => resolutionFor(call),
      emitted,
    ));
    // The DB cursor would advance unobserved: never return folded messages.
    await expect(compactor.maybeCompact({
      sessionId: "main-session",
      messages: history(),
      windowTokens: 1_000,
    })).rejects.toMatchObject({ code: "continuation_unprovable" });
    expect(emitted).toHaveLength(0);
  });

  it("projects the committed checkpoint before emitting and before returning folded history", async () => {
    const emitted: Emitted[] = [];
    const calls: Array<{ checkpointId: string; actor: CompactionActor }> = [];
    const runtime = createWorkerCompactionRuntime({
      db: fakeDb,
      repository: { foldCheckpoint: async (input) => folded(input) },
      fallback: FALLBACK,
      continuation: stubContinuation(calls),
    });
    const compactor = runtime.wrapCompactor(legacyBase(), captureBinding(
      async (call) => resolutionFor(call),
      emitted,
    ));
    const outcome = await compactor.maybeCompact({
      sessionId: "main-session",
      messages: history(),
      windowTokens: 1_000,
    });
    expect(outcome.compacted).toBe(true);
    expect(calls).toEqual([{ checkpointId: "fold-checkpoint", actor: mainActor() }]);
    expect(emitted).toHaveLength(1);
  });

  it("propagates a continuation failure instead of silently returning full history", async () => {
    const emitted: Emitted[] = [];
    const runtime = createWorkerCompactionRuntime({
      db: fakeDb,
      repository: { foldCheckpoint: async (input) => folded(input) },
      fallback: FALLBACK,
      continuation: {
        async sync() {
          throw new Error("legacy state is unavailable");
        },
        async reconcile() {
          return null;
        },
      },
    });
    const compactor = runtime.wrapCompactor(legacyBase(), captureBinding(
      async (call) => resolutionFor(call),
      emitted,
    ));
    await expect(compactor.maybeCompact({
      sessionId: "main-session",
      messages: history(),
      windowTokens: 1_000,
    })).rejects.toThrow("legacy state is unavailable");
    expect(emitted).toHaveLength(0);
  });
});

interface RealFixture {
  userId: string;
  /** Fold scope: main session or worker child session. */
  sessionId: string;
  /** Event/mirror scope: main session or the worker's parent session. */
  parentSessionId: string;
  rootTaskRunId: string;
  /** Current root/main run or current follow-up child-turn run. */
  runId: string;
  /** Immutable attempt run, when this is a worker follow-up fixture. */
  initialAttemptRunId: string | null;
  actor: CompactionActor;
}

const REAL_OUTPUT_RESERVE = 500;
const REAL_PROVIDER_RESERVE = 100;
const REAL_FOLDED_ROWS = 4;
const REAL_RETAINED_ROWS = 8;

async function seedMain(db: Db, label: string): Promise<RealFixture> {
  const userId = newId();
  await users.ensure(db, userId, null);
  const session = await sessions.create(db, userId, label);
  const prompt = await messages.append(db, { sessionId: session.id, role: "user", content: `${label}-root` });
  const root = await runs.create(db, { sessionId: session.id, promptMessageId: prompt.id });
  expect(await runs.claimNext(db, root.id)).toBe(true);
  return {
    userId,
    sessionId: session.id,
    parentSessionId: session.id,
    rootTaskRunId: root.id,
    runId: root.id,
    initialAttemptRunId: null,
    actor: mainActor(session.id, root.id),
  };
}

/**
 * The real cutoff retains toward 16% of the selected limit using len/4 + 4.
 * Twelve rows of 8%-of-limit characters make the newest eight rows reach that
 * target at cutoff four. Their raw retained content is about 64% of the limit,
 * leaving room for the checkpoint and both reserves in the post-fold budget.
 */
function foldableMessageChars(contextLimit: number): number {
  const chars = Math.ceil(contextLimit * 0.08);
  const retainedEstimate = REAL_RETAINED_ROWS * (Math.floor(chars / 4) + 4);
  expect(retainedEstimate).toBeGreaterThanOrEqual(Math.floor(contextLimit * 0.16));
  return chars;
}

async function appendCanonicalHistory(
  db: Db,
  fixture: RealFixture,
  label: string,
  contextLimit: number,
): Promise<AgentMessage[]> {
  const messageChars = foldableMessageChars(contextLimit);
  const rows: AgentMessage[] = [];
  for (let index = 0; index < REAL_FOLDED_ROWS + REAL_RETAINED_ROWS; index += 1) {
    const role = index % 2 === 0 ? "user" as const : "assistant" as const;
    const prefix = `${label}-${index}-exact-`;
    const content = `${prefix}${"x".repeat(messageChars - prefix.length)}`;
    expect(content).toHaveLength(messageChars);
    const row = await messages.append(db, {
      sessionId: fixture.sessionId,
      role,
      content,
    });
    rows.push({ id: row.id, role, content: row.content });
  }
  return rows;
}

function expectRealPostFoldBudget(
  model: string,
  contextLimit: number,
  outcome: CompactionOutcome,
  originalWindow: readonly AgentMessage[],
): void {
  expect(outcome.compacted).toBe(true);
  expect(outcome.messages).toHaveLength(1 + REAL_RETAINED_ROWS);
  expect(outcome.messages.slice(1)).toEqual(originalWindow.slice(REAL_FOLDED_ROWS));
  const body = canonicalRequest(model, outcome.messages).body;
  const afterUsage = Buffer.byteLength(JSON.stringify(body), "utf8") + 4 + 4 * outcome.messages.length;
  expect(afterUsage + REAL_OUTPUT_RESERVE + REAL_PROVIDER_RESERVE).toBeLessThanOrEqual(contextLimit);
}

async function seedWorker(db: Db, label: string): Promise<RealFixture> {
  const parent = await seedMain(db, `${label}-parent`);
  const [admitted] = await admitDispatches(db, [{
    requestId: newId(),
    index: 0,
    sessionId: parent.sessionId,
    userId: parent.userId,
    rootTaskRunId: parent.rootTaskRunId,
    parentRunId: parent.rootTaskRunId,
    batchId: newId(),
    prompt: `${label}-child-task`,
    requestedAt: new Date(),
    provenance: "server",
    modelContext: {
      requestedModel: null,
      byokKeyId: null,
      temperature: null,
      actorUserId: parent.userId,
    },
  }]);
  expect(admitted).toMatchObject({ admission: "admitted" });
  // admitDispatches already records the running attempt (status + startedAt);
  // the attempt's child run remains the lineage anchor for later turns.
  await runs.finish(db, admitted!.childRunId!, "completed");

  const followUpPrompt = await messages.append(db, {
    sessionId: admitted!.childSessionId!,
    role: "user",
    content: `${label}-current-follow-up`,
  });
  const followUp = await runs.create(db, {
    sessionId: admitted!.childSessionId!,
    promptMessageId: followUpPrompt.id,
  });
  expect(await runs.claimNext(db, followUp.id)).toBe(true);

  return {
    userId: parent.userId,
    sessionId: admitted!.childSessionId!,
    parentSessionId: parent.sessionId,
    rootTaskRunId: parent.rootTaskRunId,
    runId: followUp.id,
    initialAttemptRunId: admitted!.childRunId!,
    actor: {
      sessionId: admitted!.childSessionId!,
      rootTaskRunId: parent.rootTaskRunId,
      logicalWorkerId: admitted!.logicalWorkerId!,
      attemptId: admitted!.attemptId!,
      kind: "worker",
    },
  };
}

describe.skipIf(!TEST_DATABASE_URL).sequential("worker compaction runtime on isolated real Postgres (UNEXECUTED)", () => {
  let scratch: MigrationScratch;
  let db: Db;

  beforeAll(async () => {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "worker_compaction_runtime");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 8 });
  }, 180_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await scratch?.close();
  }, 30_000);

  function realBinding(options: {
    fixture: RealFixture;
    eventSessionId: string;
    model?: string;
    contextLimit?: number;
    beforeTokens: () => number;
    emitted: Emitted[];
  }): WorkerCompactionBinding {
    const model = options.model ?? "provider/real";
    const contextLimit = options.contextLimit ?? 100_000;
    let mirrorSub = 0;
    const sink: EventSink = {
      emit: async (type, payload) => {
        options.emitted.push({ sessionId: options.eventSessionId, type, payload });
        await eventMirror.put(db, {
          sessionId: options.eventSessionId,
          seq: `${Date.now()}-${mirrorSub++}`,
          type,
          payload,
          ts: NOW.toISOString(),
        });
      },
    };
    return {
      sink,
      now: () => NOW,
      resolve: async (call) => ({
        actor: options.fixture.actor,
        runId: options.fixture.runId,
        eventSessionId: options.eventSessionId,
        model,
        catalog: [{
          model_name: model,
          model_info: {
            max_input_tokens: contextLimit,
            max_output_tokens: 1_000,
            provider_reserve_tokens: REAL_PROVIDER_RESERVE,
          },
        }],
        requestMaxOutputTokens: REAL_OUTPUT_RESERVE,
        measuredInputTokens: options.beforeTokens(),
        request: canonicalRequest(model, call.messages),
        boundary: SAFE_BOUNDARY,
      }),
    };
  }

  async function counts(fixture: RealFixture) {
    const [row] = await scratch.client`
      SELECT
        (SELECT count(*)::int FROM compaction_cursors WHERE session_id = ${fixture.sessionId}) AS cursors,
        (SELECT count(*)::int FROM compaction_checkpoints WHERE session_id = ${fixture.sessionId}) AS checkpoints,
        (SELECT count(*)::int FROM messages WHERE session_id = ${fixture.sessionId}) AS messages`;
    return row!;
  }

  async function mirrored(sessionId: string) {
    return scratch.client`
      SELECT session_id AS "sessionId", type, payload
        FROM session_event_mirror WHERE session_id = ${sessionId}
        ORDER BY seq`;
  }

  /**
   * Rebuild the next run's request context exactly as agent-core's loop does
   * (`loop.ts:751-772`): newest-100 durable rows, then applyCheckpoint with the
   * durable fold boundary. This is the real context, not a compactor call.
   */
  async function nextRunContext(fixture: RealFixture) {
    const { rows } = await messages.page(db, fixture.sessionId, { limit: 100 });
    const history: AgentMessage[] = [];
    for (let index = rows.length - 1; index >= 0; index -= 1) {
      const row = rows[index]!;
      if (row.role === "user" || row.role === "assistant" || row.role === "system") {
        history.push({ role: row.role, content: row.content, id: row.id });
      }
    }
    const state = await sessionState.get(db, fixture.sessionId);
    const boundary = foldBoundaryFor(state.compaction, history);
    return {
      state,
      boundary,
      messages: applyCheckpoint(state.compaction, history, boundary),
    };
  }

  it("keeps 79% untouched, folds/replays main at 80%, dedupes diagnostics, and writes no ordinary chat row", async () => {
    const contextLimit = 100_000;
    const fixture = await seedMain(db, "main-replay");
    const window = await appendCanonicalHistory(db, fixture, "main-replay", contextLimit);
    const input = { sessionId: fixture.sessionId, messages: window, windowTokens: 100_000, foldBoundary: 0 };
    const before = await counts(fixture);
    let usage = 79_000;
    const emitted: Emitted[] = [];
    const runtime = createWorkerCompactionRuntime({
      db,
      fallback: FALLBACK,
      continuation: createCompactionContinuation({ db }),
    });
    const binding = realBinding({
      fixture,
      eventSessionId: fixture.parentSessionId,
      beforeTokens: () => usage,
      emitted,
    });
    const compactor = runtime.wrapCompactor(legacyBase(), binding);

    expect((await compactor.maybeCompact(input)).compacted).toBe(false);
    expect(await counts(fixture)).toEqual(before);

    usage = 80_000;
    const first = await compactor.maybeCompact(input);
    expect(first).toMatchObject({
      compacted: true,
      foldBoundary: 1,
      contextLimit,
      beforeTokens: 80_000,
      usageSource: "measured",
      continuation: "continuing_existing_task",
    });
    expect(first.compactionId).toEqual(expect.any(String));
    expect(first.checkpointId).toEqual(expect.any(String));
    expect(first.cutoffCursor).toEqual(expect.any(String));
    expect(first.afterTokens).toEqual(expect.any(Number));
    expectRealPostFoldBudget("provider/real", contextLimit, first, window);

    // A fresh wrapper has no process-local emission cache. Sequential durable
    // mirror dedupe suppresses replay only after the scoped event is visible.
    const replay = runtime.wrapCompactor(legacyBase(), binding).maybeCompact(input);
    expect(await replay).toEqual(first);
    expect(emitted).toHaveLength(1);
    expect(await counts(fixture)).toEqual({
      ...before,
      cursors: 1,
      checkpoints: 1,
    });
    expect(emitted[0]).toMatchObject({
      sessionId: fixture.parentSessionId,
      type: "compaction_completed",
    });
    expect(mainCompactionDiagnosticsSchema.parse({
      type: emitted[0]!.type,
      sessionId: fixture.parentSessionId,
      ...emitted[0]!.payload,
    })).toMatchObject({ actorKind: "main", runId: fixture.runId });
    expect(await mirrored(fixture.parentSessionId)).toHaveLength(1);
  });

  it("folds the child but emits manual worker metadata on the parent stream for the current follow-up run", async () => {
    const contextLimit = 100_000;
    const fixture = await seedWorker(db, "worker-manual");
    expect(fixture.runId).not.toBe(fixture.initialAttemptRunId);
    const window = await appendCanonicalHistory(db, fixture, "worker-manual", contextLimit);
    const input = { sessionId: fixture.sessionId, messages: window, windowTokens: 100_000, foldBoundary: 0 };
    const emitted: Emitted[] = [];
    const runtime = createWorkerCompactionRuntime({
      db,
      fallback: FALLBACK,
      continuation: createCompactionContinuation({ db }),
    });
    const binding = realBinding({
      fixture,
      eventSessionId: fixture.parentSessionId,
      beforeTokens: () => 80_000,
      emitted,
    });
    const compactor = runtime.wrapCompactor(legacyBase(), binding);

    const first = await compactor.compactNow(input);
    // Use a fresh wrapper so the sequential parent-mirror lookup, not merely
    // the first wrapper's local Set, is part of the intended replay assertion.
    const replay = await runtime.wrapCompactor(legacyBase(), binding).compactNow(input);
    expect(first.compacted).toBe(true);
    expect(first.status).toContain("Session compacted");
    expectRealPostFoldBudget("provider/real", contextLimit, first, window);
    expect(replay).toEqual(first);
    expect(emitted).toHaveLength(1);
    expect(emitted[0]).toMatchObject({
      sessionId: fixture.parentSessionId,
      type: "subagent_compacted",
    });
    const event = subagentCompactedPayloadSchema.parse({
      type: emitted[0]!.type,
      sessionId: fixture.parentSessionId,
      ...emitted[0]!.payload,
    });
    expect(event).toMatchObject({
      sessionId: fixture.parentSessionId,
      workerId: fixture.actor.logicalWorkerId,
      runId: fixture.runId,
      contextLimit,
      beforeTokens: 80_000,
      continuation: "continuing_existing_task",
    });
    expect(event.runId).not.toBe(fixture.initialAttemptRunId);

    const childCounts = await counts(fixture);
    expect(childCounts.checkpoints).toBe(1);
    expect(childCounts.cursors).toBe(1);
    // Initial child prompt + follow-up prompt + twelve canonical rows; the
    // fold and operational event never append an ordinary chat message.
    expect(childCounts.messages).toBe(14);
    const [checkpoint] = await scratch.client`
      SELECT session_id AS "sessionId", root_task_run_id AS "rootTaskRunId",
        actor_kind AS "actorKind", logical_worker_id AS "logicalWorkerId",
        attempt_id AS "attemptId"
      FROM compaction_checkpoints WHERE checkpoint_id = ${first.checkpointId!}`;
    expect(checkpoint).toEqual({
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      actorKind: "worker",
      logicalWorkerId: fixture.actor.logicalWorkerId,
      attemptId: fixture.actor.attemptId,
    });
    expect(await mirrored(fixture.parentSessionId)).toHaveLength(1);
    expect(await mirrored(fixture.sessionId)).toHaveLength(0);
  });

  it("persists model-specific context and reserve values rather than windowTokens", async () => {
    const contextLimit = 1_000_000;
    const fixture = await seedMain(db, "model-profile");
    const window = await appendCanonicalHistory(db, fixture, "model-profile", contextLimit);
    const runtime = createWorkerCompactionRuntime({
      db,
      fallback: FALLBACK,
      continuation: createCompactionContinuation({ db }),
    });
    const compactor = runtime.wrapCompactor(legacyBase(), realBinding({
      fixture,
      eventSessionId: fixture.parentSessionId,
      model: "provider/million",
      contextLimit,
      beforeTokens: () => 800_000,
      emitted: [],
    }));
    const outcome = await compactor.maybeCompact({
      sessionId: fixture.sessionId,
      messages: window,
      windowTokens: 100_000,
    });
    expect(outcome.contextLimit).toBe(contextLimit);
    expectRealPostFoldBudget("provider/million", contextLimit, outcome, window);
    const [checkpoint] = await scratch.client`
      SELECT model, context_limit::int AS "contextLimit",
        output_reserve_tokens::int AS "outputReserveTokens",
        provider_reserve_tokens::int AS "providerReserveTokens"
      FROM compaction_checkpoints WHERE checkpoint_id = ${outcome.checkpointId!}`;
    expect(checkpoint).toEqual({
      model: "provider/million",
      contextLimit,
      outputReserveTokens: REAL_OUTPUT_RESERVE,
      providerReserveTokens: REAL_PROVIDER_RESERVE,
    });
  });

  it("reaches actor validation with a foldable window and denies a wrong root without side effects", async () => {
    const contextLimit = 100_000;
    const fixture = await seedMain(db, "lineage-denial");
    const other = await seedMain(db, "lineage-other");
    const window = await appendCanonicalHistory(db, fixture, "lineage-denial", contextLimit);
    const before = await counts(fixture);
    const emitted: Emitted[] = [];
    const runtime = createWorkerCompactionRuntime({
      db,
      fallback: FALLBACK,
      continuation: createCompactionContinuation({ db }),
    });
    const binding = realBinding({
      fixture,
      eventSessionId: fixture.parentSessionId,
      beforeTokens: () => 80_000,
      emitted,
    });
    const originalResolve = binding.resolve;
    binding.resolve = async (call) => ({
      ...(await originalResolve(call)),
      actor: { ...fixture.actor, rootTaskRunId: other.rootTaskRunId },
      runId: other.rootTaskRunId,
    });
    const compactor = runtime.wrapCompactor(legacyBase(), binding);

    // A no-fold result would hide the intended gate: the sized window reaches
    // cutoff four, so validateActor must reject the cross-session root.
    await expect(compactor.maybeCompact({
      sessionId: fixture.sessionId,
      messages: window,
      windowTokens: 100_000,
    })).rejects.toMatchObject({ code: "actor_mismatch" });
    expect(await counts(fixture)).toEqual(before);
    expect(emitted).toHaveLength(0);
    expect(await mirrored(fixture.parentSessionId)).toHaveLength(0);
  });

  it("resumes a fold interrupted before continuation without duplicating or losing history, and the next run consumes the compacted context", async () => {
    const contextLimit = 100_000;
    const fixture = await seedMain(db, "crash-resume");
    const window = await appendCanonicalHistory(db, fixture, "crash-resume", contextLimit);
    const input = {
      sessionId: fixture.sessionId,
      messages: window,
      windowTokens: 100_000,
      foldBoundary: 0,
    };
    const emitted: Emitted[] = [];
    const binding = realBinding({
      fixture,
      eventSessionId: fixture.parentSessionId,
      beforeTokens: () => 80_000,
      emitted,
    });
    const before = await counts(fixture);

    // 1. The fold commits, then the process dies before the legacy projection
    //    (models a crash between the checkpoint/cursor commit and sync).
    const crashing = createWorkerCompactionRuntime({
      db,
      fallback: FALLBACK,
      continuation: {
        async sync() {
          throw new Error("simulated crash after fold commit");
        },
        async reconcile() {
          return null;
        },
      },
    });
    await expect(crashing.wrapCompactor(legacyBase(), binding).maybeCompact(input))
      .rejects.toThrow("simulated crash after fold commit");

    const afterCrash = await counts(fixture);
    expect(afterCrash).toEqual({ ...before, cursors: 1, checkpoints: 1 });
    expect((await sessionState.get(db, fixture.sessionId)).compaction).toBeNull();
    // The projection precedes the diagnostic: a crash there emits nothing.
    expect(emitted).toHaveLength(0);
    const [committed] = await scratch.client`
      SELECT checkpoint_id AS "checkpointId", compaction_id AS "compactionId",
        request_digest AS "requestDigest", cutoff_message_id AS "cutoffMessageId",
        summary, ledger_version AS "ledgerVersion"
      FROM compaction_checkpoints WHERE session_id = ${fixture.sessionId}`;
    expect(committed!.requestDigest).toMatch(/^[0-9a-f]{64}$/);
    expect(committed!.cutoffMessageId).toBe(window[REAL_FOLDED_ROWS - 1]!.id);

    // 2. Recovery: the scheduler tick's bounded replay patches the projection.
    expect(await recoverPendingCompactionContinuations({ db })).toEqual({
      recovered: 1,
      failed: 0,
    });
    // A second pass is a no-op (idempotent, no count inflation).
    expect(await recoverPendingCompactionContinuations({ db })).toEqual({
      recovered: 0,
      failed: 0,
    });
    const projected = (await sessionState.get(db, fixture.sessionId)).compaction!;
    expect(projected).toMatchObject({
      ledger: null,
      compactedAtCount: 1,
      cutoffMessageId: window[REAL_FOLDED_ROWS - 1]!.id,
      summary: committed!.summary,
    });

    // 3. The NEXT RUN's actual context: checkpoint row + unfolded tail.
    const next = await nextRunContext(fixture);
    expect(next.boundary).toBe(REAL_FOLDED_ROWS + 1);
    expect(next.messages).toHaveLength(1 + REAL_RETAINED_ROWS);
    expect(next.messages[0]).toMatchObject({ role: "system", volatile: false });
    expect(next.messages[0]!.content).toContain("<compacted-summary>");
    expect(next.messages.slice(1).map((message) => message.content))
      .toEqual(window.slice(REAL_FOLDED_ROWS).map((message) => message.content));
    for (const folded of window.slice(0, REAL_FOLDED_ROWS)) {
      expect(next.messages.some((message) => message.content === folded.content)).toBe(false);
    }

    // 4. No history loss: every folded row is exactly once in exact recall and
    //    every retained row is still a durable message.
    const page = await readExactHistory(db, { sessionId: fixture.sessionId, limit: 100 });
    for (const row of window.slice(0, REAL_FOLDED_ROWS)) {
      expect(page.items.filter((item) => item.item.stableId === row.id)).toHaveLength(1);
    }
    const durable = await scratch.client`
      SELECT count(*)::int AS "count" FROM messages WHERE session_id = ${fixture.sessionId}`;
    expect(durable[0]).toEqual({ count: REAL_FOLDED_ROWS + REAL_RETAINED_ROWS + 1 });

    // 5. Replaying the same canonical request returns the identical checkpoint
    //    (durable digest replay): no new rows, no double projection, and the
    //    skipped diagnostic is emitted exactly once.
    const runtime = createWorkerCompactionRuntime({
      db,
      fallback: FALLBACK,
      continuation: createCompactionContinuation({ db }),
    });
    const replay = await runtime.wrapCompactor(legacyBase(), binding).maybeCompact(input);
    expect(replay).toMatchObject({
      compacted: true,
      checkpointId: committed!.checkpointId,
      compactionId: committed!.compactionId,
      cutoffCursor: expect.any(String),
      continuation: "continuing_existing_task",
    });
    expect(replay.messages[0]!.content).toBe(next.messages[0]!.content);
    expect(await counts(fixture)).toEqual(afterCrash);
    const [replayed] = await scratch.client`
      SELECT request_digest AS "requestDigest", cutoff_message_id AS "cutoffMessageId"
      FROM compaction_checkpoints WHERE checkpoint_id = ${committed!.checkpointId}`;
    expect(replayed).toEqual({
      requestDigest: committed!.requestDigest,
      cutoffMessageId: committed!.cutoffMessageId,
    });
    expect((await sessionState.get(db, fixture.sessionId)).compaction!.compactedAtCount).toBe(1);
    expect(emitted).toHaveLength(1);
    expect(emitted[0]).toMatchObject({
      sessionId: fixture.parentSessionId,
      type: "compaction_completed",
    });
    const historyRows = await scratch.client`
      SELECT kind, count(*)::int AS "count"
      FROM compaction_history_items WHERE session_id = ${fixture.sessionId}
      GROUP BY kind ORDER BY kind`;
    // Exact history records the FOLDED span only (one reference per folded
    // row); the retained tail stays canonical and is registered at its own
    // fold. Nothing is dropped: the four folded rows are exactly four items.
    expect(historyRows).toEqual([
      { kind: "checkpoint", count: 1 },
      { kind: "compaction", count: 1 },
      { kind: "message", count: REAL_FOLDED_ROWS },
    ]);
  });
});
