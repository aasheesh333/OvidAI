import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import {
  ModelQuotaExceededError,
  type AgentRequest,
  type AgentResponse,
  type AgentTransport,
  type LegacyModelTransport,
} from "@ovid/agent-core";
import {
  RunQuotaService,
  createDb,
  messages,
  migrate,
  newId,
  runs,
  sessions,
  users,
  type Db,
  type ModelCallReservationInput,
  type QuotaBillingClass,
} from "@ovid/db";
import {
  createMigrationScratch,
  type MigrationScratch,
} from "../../../packages/db/src/migrationTestKit.js";
import {
  estimateAgentRequestTokens,
  withLegacyQuotaReservations,
  withUsageRecording,
  type UsageRecord,
} from "./usageRecorder.js";

// R1b regression source is UNEXECUTED under HEAVY-COMMANDS-PAUSED.md. No RED or
// GREEN result is claimed by this file or by its source-order authorship.

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

/** Drizzle wraps driver failures; the Postgres/trigger text lives on the cause. */
function errorMessage(error: unknown): string {
  const parts: string[] = [];
  let current: unknown = error;
  for (let depth = 0; depth < 6 && current !== null && current !== undefined; depth += 1) {
    if (current instanceof Error) {
      parts.push(current.message);
      current = (current as { cause?: unknown }).cause;
    } else {
      parts.push(String(current));
      break;
    }
  }
  return parts.join(" | ");
}

const REQ = {
  model: "auto",
  baseUrl: "http://litellm",
  apiKey: "sk",
  system: [],
  messages: [],
  tools: [],
  cacheMode: "none",
} as unknown as AgentRequest;

function transport(response: AgentResponse | Error): AgentTransport & { calls: number } {
  const t = {
    apiFormat: "openai" as const,
    calls: 0,
    async stream(_req: AgentRequest, h: { onTextDelta(text: string): void }) {
      t.calls++;
      h.onTextDelta("hi");
      if (response instanceof Error) throw response;
      return response;
    },
  };
  return t;
}

const response = (usage: AgentResponse["usage"]): AgentResponse => ({
  content: "hi",
  thinking: "",
  toolCalls: [],
  finishReason: "stop",
  usage,
});

const ctx = { userId: "u1", sessionId: "s1", runId: "r1" };

describe("withLegacyQuotaReservations", () => {
  it("reserves bounded legacy calls before the provider and releases genuinely unknown usage", async () => {
    const steps: string[] = [];
    const releaseModelCall = vi.fn(async () => {
      steps.push("release");
    });
    const reserveModelCall = vi.fn(async (_input: ModelCallReservationInput) => {
      steps.push("reserve");
      return { ok: true as const, reservationId: "legacy-reservation" };
    });
    let providerMaxTokens: number | undefined;
    const legacy: LegacyModelTransport = {
      async stream(req, _h, _signal) {
        providerMaxTokens = req.maxTokens;
        steps.push("provider");
        return { finishReason: "stop", toolCalls: [] };
      },
    };
    const wrapped = withLegacyQuotaReservations(legacy, {
      userId: "u1",
      runId: "legacy-run",
      billingClass: "byok",
      quota: { reserveModelCall, releaseModelCall },
      inputTokens: () => 9,
      reservationKey: () => "legacy-stable",
    });

    const result = await wrapped.stream(
      { baseUrl: "http://litellm", apiKey: "sk", model: "auto", messages: [] },
      { onDelta() {} },
      new AbortController().signal,
    );

    expect(result).toEqual({ finishReason: "stop", toolCalls: [] });
    expect(steps).toEqual(["reserve", "provider", "release"]);
    expect(providerMaxTokens).toBe(8_192);
    expect(reserveModelCall).toHaveBeenCalledWith({
      actorUserId: "u1",
      runId: "legacy-run",
      reservationKey: "legacy-stable",
      inputTokens: 9,
      maxOutputTokens: 8_192,
      requestedModel: "auto",
      billingClass: "byok",
    });
    expect(releaseModelCall).toHaveBeenCalledWith("legacy-reservation");
  });

  it("reuses legacy reservation identity on retry and releases after transport failure", async () => {
    const reservationKeys: string[] = [];
    const reservationIds = new Map<string, string>();
    const releaseModelCall = vi.fn(async () => {});
    let providerCalls = 0;
    const failure = new Error("legacy transport failed");
    const legacy: LegacyModelTransport = {
      async stream(_req, _h, _signal) {
        providerCalls++;
        if (providerCalls === 1) throw failure;
        return { finishReason: "stop", toolCalls: [] };
      },
    };
    const wrapped = withLegacyQuotaReservations(legacy, {
      userId: "u1",
      runId: "legacy-run",
      quota: {
        reserveModelCall: vi.fn(async (input: ModelCallReservationInput) => {
          reservationKeys.push(input.reservationKey);
          let id = reservationIds.get(input.reservationKey);
          if (id === undefined) {
            id = `legacy-reservation-${reservationIds.size + 1}`;
            reservationIds.set(input.reservationKey, id);
          }
          return { ok: true as const, reservationId: id };
        }),
        releaseModelCall,
      },
      inputTokens: () => 5,
    });
    const req = {
      baseUrl: "http://litellm",
      apiKey: "sk",
      model: "auto",
      messages: [],
      maxTokens: 31,
    };

    await expect(wrapped.stream(req, { onDelta() {} }, new AbortController().signal))
      .rejects.toBe(failure);
    await expect(wrapped.stream(req, { onDelta() {} }, new AbortController().signal))
      .resolves.toEqual({ finishReason: "stop", toolCalls: [] });

    expect(providerCalls).toBe(2);
    expect(reservationKeys).toHaveLength(2);
    expect(reservationKeys[1]).toBe(reservationKeys[0]);
    expect(releaseModelCall).toHaveBeenCalledTimes(2);
    expect(releaseModelCall).toHaveBeenNthCalledWith(1, "legacy-reservation-1");
    expect(releaseModelCall).toHaveBeenNthCalledWith(2, "legacy-reservation-1");
  });
});

describe("withUsageRecording", () => {
  it("records the requested model and every token count, then returns the response untouched", async () => {
    const recorded: UsageRecord[] = [];
    const res = response({ inputTokens: 100, outputTokens: 20, cacheReadTokens: 64, cacheWriteTokens: 8 });
    const base = transport(res);
    const wrapped = withUsageRecording(base, { ...ctx, record: async (r) => void recorded.push(r) });
    expect(wrapped.apiFormat).toBe("openai");
    const deltas: string[] = [];
    const out = await wrapped.stream(REQ, { onTextDelta: (t) => deltas.push(t) }, new AbortController().signal);
    expect(out).toBe(res);
    expect(deltas).toEqual(["hi"]);
    expect(recorded).toEqual([
      {
        userId: "u1",
        sessionId: "s1",
        runId: "r1",
        model: "auto",
        inputTokens: 100,
        outputTokens: 20,
        cacheReadTokens: 64,
        cacheWriteTokens: 8,
      },
    ]);
  });

  it("missing cache counts record as 0; null usage records nothing", async () => {
    const recorded: UsageRecord[] = [];
    const record = async (r: UsageRecord) => void recorded.push(r);
    await withUsageRecording(transport(response({ inputTokens: 1, outputTokens: 2 })), { ...ctx, record }).stream(
      REQ,
      { onTextDelta() {} },
      new AbortController().signal,
    );
    await withUsageRecording(transport(response(null)), { ...ctx, record }).stream(
      REQ,
      { onTextDelta() {} },
      new AbortController().signal,
    );
    expect(recorded).toHaveLength(1);
    expect(recorded[0]).toMatchObject({ cacheReadTokens: 0, cacheWriteTokens: 0 });
  });

  it("a failing recorder never fails the model call (logged, swallowed)", async () => {
    const log = vi.fn();
    const res = response({ inputTokens: 1, outputTokens: 1 });
    const out = await withUsageRecording(transport(res), {
      ...ctx,
      record: async () => {
        throw new Error("db down");
      },
      log,
    }).stream(REQ, { onTextDelta() {} }, new AbortController().signal);
    expect(out).toBe(res);
    expect(log).toHaveBeenCalledTimes(1);
  });

  it("a transport error propagates and records nothing", async () => {
    const record = vi.fn();
    await expect(
      withUsageRecording(transport(new Error("boom")), { ...ctx, record }).stream(
        REQ,
        { onTextDelta() {} },
        new AbortController().signal,
      ),
    ).rejects.toThrow("boom");
    expect(record).not.toHaveBeenCalled();
  });

  it("reserves before the provider call and settles actual usage without a second legacy charge", async () => {
    const steps: string[] = [];
    const reserveModelCall = vi.fn(async (input: ModelCallReservationInput) => {
      steps.push("reserve");
      expect(input).toMatchObject({
        actorUserId: "u1",
        runId: "r1",
        reservationKey: "stable-call",
        inputTokens: 17,
        maxOutputTokens: 23,
        requestedModel: "auto",
      });
      return { ok: true as const, reservationId: "reservation-1" };
    });
    const settleModelCall = vi.fn(async () => {
      steps.push("settle");
    });
    const legacyRecord = vi.fn(async () => {});
    const base: AgentTransport = {
      apiFormat: "openai",
      async stream(_req, h) {
        steps.push("provider");
        h.onTextDelta("hi");
        return response({ inputTokens: 100, outputTokens: 20, cacheReadTokens: 64, cacheWriteTokens: 8 });
      },
    };
    const wrapped = withUsageRecording(base, {
      ...ctx,
      record: legacyRecord,
      quota: { reserveModelCall, settleModelCall, releaseModelCall: vi.fn(async () => {}) },
      inputTokens: () => 17,
      reservationKey: () => "stable-call",
    });

    const out = await wrapped.stream(
      { ...REQ, maxTokens: 23 },
      { onTextDelta() {} },
      new AbortController().signal,
    );

    expect(out.content).toBe("hi");
    expect(steps).toEqual(["reserve", "provider", "settle"]);
    expect(settleModelCall).toHaveBeenCalledWith({
      reservationId: "reservation-1",
      usage: {
        inputTokens: 100,
        outputTokens: 20,
        cacheReadTokens: 64,
        cacheWriteTokens: 8,
        requestedModel: "auto",
        billingClass: "ovid_allowance",
      },
    });
    expect(legacyRecord).not.toHaveBeenCalled();
  });

  it("settles observed overage with exact billing, requested/provider model, cache, and cost facts", async () => {
    const settleModelCall = vi.fn(async () => {});
    const releaseModelCall = vi.fn(async () => {});
    const reserveModelCall = vi.fn(async () => ({ ok: true as const, reservationId: "over-reservation" }));
    const legacyRecord = vi.fn(async () => {});
    const res = response({
      inputTokens: 100,
      outputTokens: 9_000,
      cacheReadTokens: 61,
      cacheWriteTokens: 7,
      providerModel: "served-model",
      costUsd: "0.0123456789",
      costSource: "litellm",
    });

    await withUsageRecording(transport(res), {
      ...ctx,
      billingClass: "byok",
      record: legacyRecord,
      quota: { reserveModelCall, settleModelCall, releaseModelCall },
      inputTokens: () => 10,
    }).stream({ ...REQ, maxTokens: 8_192 }, { onTextDelta() {} }, new AbortController().signal);

    expect(reserveModelCall).toHaveBeenCalledWith(expect.objectContaining({
      requestedModel: "auto",
      billingClass: "byok",
    }));
    expect(settleModelCall).toHaveBeenCalledWith({
      reservationId: "over-reservation",
      usage: {
        inputTokens: 100,
        outputTokens: 9_000,
        cacheReadTokens: 61,
        cacheWriteTokens: 7,
        requestedModel: "auto",
        providerModel: "served-model",
        costUsd: "0.0123456789",
        costSource: "litellm",
        billingClass: "byok",
      },
    });
    expect(releaseModelCall).not.toHaveBeenCalled();
    expect(legacyRecord).not.toHaveBeenCalled();
  });

  it("releases after transport failure without settling or inventing usage", async () => {
    const steps: string[] = [];
    const failure = new Error("transport failed");
    const settleModelCall = vi.fn(async () => {});
    const releaseModelCall = vi.fn(async () => {
      steps.push("release");
    });
    const base: AgentTransport = {
      apiFormat: "openai",
      async stream() {
        steps.push("provider");
        throw failure;
      },
    };

    await expect(withUsageRecording(base, {
      ...ctx,
      record: vi.fn(async () => {}),
      quota: {
        reserveModelCall: vi.fn(async () => {
          steps.push("reserve");
          return { ok: true as const, reservationId: "reservation-failed" };
        }),
        settleModelCall,
        releaseModelCall,
      },
    }).stream(REQ, { onTextDelta() {} }, new AbortController().signal)).rejects.toBe(failure);

    expect(steps).toEqual(["reserve", "provider", "release"]);
    expect(releaseModelCall).toHaveBeenCalledWith("reservation-failed");
    expect(settleModelCall).not.toHaveBeenCalled();
  });

  it("releases genuinely missing usage without a zero charge or legacy record", async () => {
    const settleModelCall = vi.fn(async () => {});
    const releaseModelCall = vi.fn(async () => {});
    const legacyRecord = vi.fn(async () => {});
    const res = response(null);

    const out = await withUsageRecording(transport(res), {
      ...ctx,
      record: legacyRecord,
      quota: {
        reserveModelCall: vi.fn(async () => ({ ok: true as const, reservationId: "unknown-usage" })),
        settleModelCall,
        releaseModelCall,
      },
    }).stream(REQ, { onTextDelta() {} }, new AbortController().signal);

    expect(out).toBe(res);
    expect(releaseModelCall).toHaveBeenCalledWith("unknown-usage");
    expect(settleModelCall).not.toHaveBeenCalled();
    expect(legacyRecord).not.toHaveBeenCalled();
  });

  it("keeps a consumed reservation and surfaces an ambiguous settlement failure", async () => {
    const failure = new Error("temporary settlement outage");
    const releaseModelCall = vi.fn(async () => {});
    const legacyRecord = vi.fn(async () => {});
    const log = vi.fn();

    await expect(withUsageRecording(transport(response({ inputTokens: 10, outputTokens: 2 })), {
      ...ctx,
      record: legacyRecord,
      log,
      quota: {
        reserveModelCall: vi.fn(async () => ({ ok: true as const, reservationId: "settlement-pending" })),
        settleModelCall: vi.fn(async () => {
          throw failure;
        }),
        releaseModelCall,
      },
    }).stream(REQ, { onTextDelta() {} }, new AbortController().signal)).rejects.toBe(failure);

    expect(releaseModelCall).not.toHaveBeenCalled();
    expect(legacyRecord).not.toHaveBeenCalled();
    expect(log).toHaveBeenCalledWith(expect.stringContaining("settlement pending"));
  });

  it("blocks the provider when the per-call reservation is exhausted", async () => {
    const exhausted = transport(response({ inputTokens: 1, outputTokens: 1 }));
    const resetsAt = new Date("2026-10-25T00:00:00Z");

    const error = await withUsageRecording(exhausted, {
      ...ctx,
      record: vi.fn(async () => {}),
      quota: {
        reserveModelCall: vi.fn(async () => ({ ok: false as const, window: "day" as const, resetsAt })),
        settleModelCall: vi.fn(async () => {}),
        releaseModelCall: vi.fn(async () => {}),
      },
    }).stream(REQ, { onTextDelta() {} }, new AbortController().signal).then(
      () => null,
      (reason: unknown) => reason,
    );

    expect(error).toBeInstanceOf(ModelQuotaExceededError);
    expect(error).toMatchObject({ name: "ModelQuotaExceededError", window: "day", resetsAt });
    expect(exhausted.calls).toBe(0);
  });

  it("reads live current actor/session/run/billing identity on every call", async () => {
    let current: {
      userId: string;
      sessionId: string;
      runId: string;
      billingClass?: QuotaBillingClass;
    } = { userId: "root-actor", sessionId: "root-session", runId: "root-run" };
    const identities: unknown[] = [];
    const reserveModelCall = vi.fn(async () => ({ ok: true as const, reservationId: "current-reservation" }));
    const settleModelCall = vi.fn(async () => {});
    const wrapped = withUsageRecording(transport(response({ inputTokens: 3, outputTokens: 4 })), {
      ...ctx,
      billingClass: "byok",
      current: () => current,
      record: vi.fn(async () => {}),
      quota: { reserveModelCall, settleModelCall, releaseModelCall: vi.fn(async () => {}) },
      inputTokens: () => 3,
      reservationKey: (_req, identity) => {
        identities.push(identity);
        return `${identity.runId}:stable`;
      },
    });

    await wrapped.stream({ ...REQ, model: "root-model" }, { onTextDelta() {} }, new AbortController().signal);
    current = {
      userId: "participant",
      sessionId: "child-session",
      runId: "child-run",
      billingClass: "ovid_allowance",
    };
    await wrapped.stream({ ...REQ, model: "child-model" }, { onTextDelta() {} }, new AbortController().signal);

    expect(identities).toEqual([
      { userId: "root-actor", sessionId: "root-session", runId: "root-run", billingClass: "byok" },
      {
        userId: "participant",
        sessionId: "child-session",
        runId: "child-run",
        billingClass: "ovid_allowance",
      },
    ]);
    expect(reserveModelCall).toHaveBeenNthCalledWith(1, expect.objectContaining({
      actorUserId: "root-actor",
      runId: "root-run",
      requestedModel: "root-model",
      billingClass: "byok",
    }));
    expect(reserveModelCall).toHaveBeenNthCalledWith(2, expect.objectContaining({
      actorUserId: "participant",
      runId: "child-run",
      requestedModel: "child-model",
      billingClass: "ovid_allowance",
    }));
    expect(settleModelCall).toHaveBeenNthCalledWith(1, expect.objectContaining({
      usage: expect.objectContaining({ requestedModel: "root-model", billingClass: "byok" }),
    }));
    expect(settleModelCall).toHaveBeenNthCalledWith(2, expect.objectContaining({
      usage: expect.objectContaining({ requestedModel: "child-model", billingClass: "ovid_allowance" }),
    }));
  });

  it("reuses default reservation identity for a logical retry and separates a later request", async () => {
    const reservationKeys: string[] = [];
    const reservationIds = new Map<string, string>();
    const releaseModelCall = vi.fn(async () => {});
    let providerCalls = 0;
    const base: AgentTransport = {
      apiFormat: "openai",
      async stream() {
        providerCalls++;
        if (providerCalls === 1) throw new Error("retry transport");
        return response({ inputTokens: 2, outputTokens: 3 });
      },
    };
    const wrapped = withUsageRecording(base, {
      ...ctx,
      record: vi.fn(async () => {}),
      quota: {
        reserveModelCall: vi.fn(async (input: ModelCallReservationInput) => {
          reservationKeys.push(input.reservationKey);
          let id = reservationIds.get(input.reservationKey);
          if (id === undefined) {
            id = `reservation-${reservationIds.size + 1}`;
            reservationIds.set(input.reservationKey, id);
          }
          return { ok: true as const, reservationId: id };
        }),
        settleModelCall: vi.fn(async () => {}),
        releaseModelCall,
      },
      inputTokens: () => 2,
    });
    const req = { ...REQ, maxTokens: 29 };

    await expect(wrapped.stream(req, { onTextDelta() {} }, new AbortController().signal))
      .rejects.toThrow("retry transport");
    await wrapped.stream(req, { onTextDelta() {} }, new AbortController().signal);
    await wrapped.stream({ ...req }, { onTextDelta() {} }, new AbortController().signal);

    expect(providerCalls).toBe(3);
    expect(reservationKeys).toHaveLength(3);
    expect(reservationKeys[1]).toBe(reservationKeys[0]);
    expect(reservationKeys[2]).not.toBe(reservationKeys[0]);
    expect(releaseModelCall).toHaveBeenCalledTimes(1);
    expect(releaseModelCall).toHaveBeenCalledWith("reservation-1");
  });

  it("uses a conservative input bound and applies the default output bound to reservation and provider", async () => {
    const unicodeRequest = {
      ...REQ,
      messages: [{ role: "user" as const, content: "🙂🙂🙂🙂 punctuation !@#$%^&*()" }],
    };
    const serialized = JSON.stringify({
      system: unicodeRequest.system,
      messages: unicodeRequest.messages,
      tools: unicodeRequest.tools,
    });
    expect(estimateAgentRequestTokens(unicodeRequest)).toBeGreaterThanOrEqual(Buffer.byteLength(serialized, "utf8"));
    expect(estimateAgentRequestTokens(unicodeRequest)).toBeGreaterThan(Math.floor(serialized.length / 4) + 4);

    let providerMaxTokens: number | undefined;
    const reserveModelCall = vi.fn(async (_input: ModelCallReservationInput) => ({
      ok: true as const,
      reservationId: "bounded-reservation",
    }));
    const base: AgentTransport = {
      apiFormat: "openai",
      async stream(req) {
        providerMaxTokens = req.maxTokens;
        return response({ inputTokens: 1, outputTokens: 1 });
      },
    };
    await withUsageRecording(base, {
      ...ctx,
      record: vi.fn(async () => {}),
      quota: { reserveModelCall, settleModelCall: vi.fn(async () => {}), releaseModelCall: vi.fn(async () => {}) },
    }).stream(unicodeRequest, { onTextDelta() {} }, new AbortController().signal);

    expect(reserveModelCall).toHaveBeenCalledWith(expect.objectContaining({
      inputTokens: estimateAgentRequestTokens(unicodeRequest),
      maxOutputTokens: 8_192,
    }));
    expect(providerMaxTokens).toBe(8_192);
  });

  it("preserves default no-quota recording, live identity, and request shape between calls", async () => {
    let current = { userId: "first-user", sessionId: "first-session", runId: "first-run" };
    const recorded: UsageRecord[] = [];
    const providerRequests: AgentRequest[] = [];
    const base: AgentTransport = {
      apiFormat: "openai",
      async stream(req) {
        providerRequests.push(req);
        return response({ inputTokens: 1, outputTokens: 2 });
      },
    };
    const wrapped = withUsageRecording(base, {
      ...ctx,
      current: () => current,
      record: async (row) => void recorded.push(row),
    });
    const first = { ...REQ, model: "first-model" };
    const second = { ...REQ, model: "second-model" };

    await wrapped.stream(first, { onTextDelta() {} }, new AbortController().signal);
    current = { userId: "second-user", sessionId: "second-session", runId: "second-run" };
    await wrapped.stream(second, { onTextDelta() {} }, new AbortController().signal);

    expect(providerRequests[0]).toBe(first);
    expect(providerRequests[1]).toBe(second);
    expect(providerRequests[0]).not.toHaveProperty("maxTokens");
    expect(providerRequests[1]).not.toHaveProperty("maxTokens");
    expect(recorded).toEqual([
      {
        userId: "first-user",
        sessionId: "first-session",
        runId: "first-run",
        model: "first-model",
        inputTokens: 1,
        outputTokens: 2,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
      },
      {
        userId: "second-user",
        sessionId: "second-session",
        runId: "second-run",
        model: "second-model",
        inputTokens: 1,
        outputTokens: 2,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
      },
    ]);
  });

  it("forwards onThinkingDelta only when the caller provides it", async () => {
    let seen: unknown = "unset";
    const base: AgentTransport = {
      apiFormat: "anthropic",
      async stream(_req, h) {
        seen = h.onThinkingDelta;
        return response(null);
      },
    };
    const wrapped = withUsageRecording(base, { ...ctx, record: async () => {} });
    await wrapped.stream(REQ, { onTextDelta() {} }, new AbortController().signal);
    expect(seen).toBeUndefined();
    const thinking = vi.fn();
    await wrapped.stream(REQ, { onTextDelta() {}, onThinkingDelta: thinking }, new AbortController().signal);
    expect(seen).toBe(thinking);
  });
});

describe.skipIf(!TEST_DATABASE_URL).sequential("withUsageRecording and real RunQuotaService (UNEXECUTED)", () => {
  let scratch: MigrationScratch;
  let db: Db;

  beforeAll(async () => {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "usage_recording_r1b");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 4 });
  }, 180_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await scratch?.close();
  }, 30_000);

  async function seedRun() {
    const actorUserId = newId();
    await users.ensure(db, actorUserId, null);
    const session = await sessions.create(db, actorUserId, "usage recording R1b");
    const prompt = await messages.append(db, {
      sessionId: session.id,
      role: "user",
      content: "usage recording R1b",
    });
    const run = await runs.create(db, { sessionId: session.id, promptMessageId: prompt.id });
    return { actorUserId, session, run };
  }

  it("persists exact actual facts through the real service and blocks the next call after mid-run exhaustion", async () => {
    const { actorUserId, session, run } = await seedRun();
    const quota = new RunQuotaService(db, {
      tokenCaps: { perDay: 10, perMonth: 100 },
      usdCaps: { perDay: null, perMonth: null },
    });
    const record = vi.fn(async () => {});
    let providerCalls = 0;
    const base: AgentTransport = {
      apiFormat: "openai",
      async stream() {
        providerCalls++;
        return response({
          inputTokens: 4,
          outputTokens: 6,
          cacheReadTokens: 2,
          cacheWriteTokens: 1,
          providerModel: "provider/actual",
          costUsd: "0.0123456789",
          costSource: "litellm",
        });
      },
    };
    const wrapped = withUsageRecording(base, {
      userId: actorUserId,
      sessionId: session.id,
      runId: run.id,
      record,
      quota,
      inputTokens: () => 1,
    });

    await wrapped.stream({ ...REQ, maxTokens: 1 }, { onTextDelta() {} }, new AbortController().signal);

    const staged = await db.$client`
      SELECT id, state, actual_input_tokens::int, actual_output_tokens::int,
             actual_cache_read_tokens::int, actual_cache_write_tokens::int,
             requested_model, provider_model, cost_usd::text, cost_source, billing_class
        FROM usage_quota_reservations
       WHERE actor_user_id = ${actorUserId} AND run_id = ${run.id}`;
    expect(staged).toHaveLength(1);
    expect(staged[0]).toMatchObject({
      state: "settled",
      actual_input_tokens: 4,
      actual_output_tokens: 6,
      actual_cache_read_tokens: 2,
      actual_cache_write_tokens: 1,
      requested_model: "auto",
      provider_model: "provider/actual",
      cost_usd: "0.0123456789",
      cost_source: "litellm",
      billing_class: "ovid_allowance",
    });
    expect(await db.$client`
      SELECT user_id, session_id::text, run_id::text, model, requested_model, provider_model,
             input_tokens::int, output_tokens::int, cache_read_tokens::int,
             cache_write_tokens::int, cost_usd::text, cost_source, billing_class
        FROM run_usage WHERE quota_reservation_id = ${staged[0]!.id}`)
      .toEqual([{
        user_id: actorUserId,
        session_id: session.id,
        run_id: run.id,
        model: "auto",
        requested_model: "auto",
        provider_model: "provider/actual",
        input_tokens: 4,
        output_tokens: 6,
        cache_read_tokens: 2,
        cache_write_tokens: 1,
        cost_usd: "0.0123456789",
        cost_source: "litellm",
        billing_class: "ovid_allowance",
      }]);
    expect(record).not.toHaveBeenCalled();

    await expect(wrapped.stream(
      { ...REQ, maxTokens: 1 },
      { onTextDelta() {} },
      new AbortController().signal,
    )).rejects.toMatchObject({ name: "ModelQuotaExceededError", window: "day" });
    expect(providerCalls).toBe(1);
    expect(await db.$client`
      SELECT window_kind, used_tokens::int, reserved_tokens::int
        FROM usage_quota_counters WHERE actor_user_id = ${actorUserId}
       ORDER BY window_kind`).toEqual([
      { window_kind: "day", used_tokens: 10, reserved_tokens: 0 },
      { window_kind: "month", used_tokens: 10, reserved_tokens: 0 },
    ]);
  });

  it("retains staged actual facts after an ambiguous ledger failure and recovers without another provider call", async () => {
    const { actorUserId, session, run } = await seedRun();
    const quota = new RunQuotaService(db, {
      tokenCaps: { perDay: 1_000, perMonth: 10_000 },
      usdCaps: { perDay: null, perMonth: null },
    });
    let providerCalls = 0;
    const base: AgentTransport = {
      apiFormat: "openai",
      async stream() {
        providerCalls++;
        return response({
          inputTokens: 3,
          outputTokens: 4,
          providerModel: "provider/recovered",
          costUsd: "0.0000000007",
          costSource: "provider",
        });
      },
    };
    const wrapped = withUsageRecording(base, {
      userId: actorUserId,
      sessionId: session.id,
      runId: run.id,
      record: vi.fn(async () => {}),
      quota,
      inputTokens: () => 1,
      reservationKey: () => "ambiguous-real-settlement",
    });

    await db.$client`
      CREATE FUNCTION fail_r1b_run_usage_insert() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'ambiguous settlement commit blocked';
      END;
      $$ LANGUAGE plpgsql`;
    await db.$client`
      CREATE TRIGGER fail_r1b_run_usage_insert
      BEFORE INSERT ON run_usage FOR EACH ROW
      EXECUTE FUNCTION fail_r1b_run_usage_insert()`;
    const outcome = await wrapped.stream(
      { ...REQ, maxTokens: 10 },
      { onTextDelta() {} },
      new AbortController().signal,
    ).then(
      () => ({ error: null as unknown }),
      (error: unknown) => ({ error }),
    );
    await db.$client`DROP TRIGGER fail_r1b_run_usage_insert ON run_usage`;
    await db.$client`DROP FUNCTION fail_r1b_run_usage_insert()`;

    expect(outcome.error).toBeInstanceOf(Error);
    expect(errorMessage(outcome.error)).toContain("ambiguous settlement commit blocked");
    const pending = await db.$client`
      SELECT id, state, actual_input_tokens::int, actual_output_tokens::int,
             requested_model, provider_model, cost_usd::text, cost_source
        FROM usage_quota_reservations
       WHERE actor_user_id = ${actorUserId} AND reservation_key = 'ambiguous-real-settlement'`;
    expect(pending).toHaveLength(1);
    const pendingReservationId = String(pending[0]!.id);
    expect(pending).toEqual([{
      id: pendingReservationId,
      state: "reserved",
      actual_input_tokens: 3,
      actual_output_tokens: 4,
      requested_model: "auto",
      provider_model: "provider/recovered",
      cost_usd: "0.0000000007",
      cost_source: "provider",
    }]);
    expect(await db.$client`
      SELECT count(*)::int AS count FROM run_usage WHERE quota_reservation_id = ${pendingReservationId}`)
      .toEqual([{ count: 0 }]);
    await expect(quota.releaseModelCall(pendingReservationId))
      .rejects.toMatchObject({ code: "usage_settlement_pending" });

    await quota.settleModelCall({
      reservationId: pendingReservationId,
      usage: {
        inputTokens: 3,
        outputTokens: 4,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        requestedModel: "auto",
        providerModel: "provider/recovered",
        costUsd: "0.0000000007",
        costSource: "provider",
        billingClass: "ovid_allowance",
      },
    });

    expect(providerCalls).toBe(1);
    expect(await db.$client`
      SELECT state FROM usage_quota_reservations WHERE id = ${pendingReservationId}`)
      .toEqual([{ state: "settled" }]);
    expect(await db.$client`
      SELECT input_tokens::int, output_tokens::int, provider_model, cost_usd::text, cost_source
        FROM run_usage WHERE quota_reservation_id = ${pendingReservationId}`)
      .toEqual([{
        input_tokens: 3,
        output_tokens: 4,
        provider_model: "provider/recovered",
        cost_usd: "0.0000000007",
        cost_source: "provider",
      }]);
  });
});
