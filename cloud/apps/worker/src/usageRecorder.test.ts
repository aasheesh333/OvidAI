import { describe, expect, it, vi } from "vitest";
import type { AgentRequest, AgentResponse, AgentTransport } from "@ovid/agent-core";
import { withUsageRecording, type UsageRecord } from "./usageRecorder.js";

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
