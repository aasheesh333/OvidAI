/**
 * Legacy adapters (P3 Task 4): P2's worker shapes (ChatMessage/ModelTransport
 * with raw `arguments` strings, tools in the request, toolCalls in the
 * result) re-exported under the Legacy* names and bridged onto the P3
 * AgentTransport seam, so the worker's runProcessor keeps running unmodified
 * over agent-core. LegacyChatMessage/LegacyModelTransport are P2's landed
 * shapes VERBATIM — not the P1 v0 ones.
 */

import type { AgentRequest, AgentResponse, AgentStreamHandlers, AgentTransport, ToolCall } from "../types.js";
import { createOpenAiAgentTransport } from "./openai.js";

export interface LegacyChatMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string;
  /** role:"assistant" only — the calls this assistant turn requested. */
  toolCalls?: LegacyToolCall[];
  /** role:"tool" only — which call this result answers. */
  toolCallId?: string;
}

/** One model-requested function call; `arguments` is the raw JSON string from the model (P2's shape). */
export interface LegacyToolCall {
  id: string;
  name: string;
  arguments: string;
}

export interface LegacyStreamHandlers {
  onDelta(text: string): void;
}

/** The [OI] wire shape of one function tool (P2's ModelToolSpec). */
export interface LegacyModelToolSpec {
  type: "function";
  function: {
    name: string;
    description: string;
    parameters: Record<string, unknown>;
  };
}

export interface LegacyModelTransport {
  stream(
    req: {
      baseUrl: string;
      apiKey: string;
      model: string;
      messages: LegacyChatMessage[];
      tools?: LegacyModelToolSpec[];
    },
    h: LegacyStreamHandlers,
    signal: AbortSignal,
  ): Promise<{ finishReason: string | null; toolCalls: LegacyToolCall[] }>;
}

/**
 * AgentRequest → legacy request: system rows are prepended as leading
 * {role:"system"} rows, the remaining messages keep their roles and raw
 * argument strings (agent ToolCall.args objects re-serialize), and tools are
 * passed through unchanged (the canonical wire shape is already the [OI]
 * function-tool shape — LegacyModelToolSpec == ToolSpec in wire form).
 * onTextDelta → onDelta; the transport's toolCalls map straight through.
 */
export function adaptLegacyTransport(t: LegacyModelTransport): AgentTransport {
  return {
    apiFormat: "openai",
    async stream(req: AgentRequest, h: AgentStreamHandlers, signal: AbortSignal): Promise<AgentResponse> {
      const messages: LegacyChatMessage[] = req.system.map((m) => ({ role: m.role, content: m.content }));
      for (const m of req.messages) {
        if (m.role === "assistant" && m.toolCalls !== undefined) {
          messages.push({
            role: "assistant",
            content: m.content,
            toolCalls: m.toolCalls.map((c) => ({
              id: c.id,
              name: c.name,
              arguments: JSON.stringify(c.args),
            })),
          });
        } else if (m.role === "tool") {
          messages.push({ role: "tool", content: m.content, toolCallId: m.toolCallId });
        } else {
          messages.push({ role: m.role, content: m.content });
        }
      }
      // Canonical ToolSpec is flat; the legacy/wire ModelToolSpec wraps it in
      // {type:"function", function:{…}} — wrap here, unwrap on the way back.
      const tools =
        req.tools.length > 0
          ? req.tools.map((spec): LegacyModelToolSpec => ({ type: "function", function: spec }))
          : undefined;
      let content = "";
      const result = await t.stream(
        { baseUrl: req.baseUrl, apiKey: req.apiKey, model: req.model, messages, tools },
        {
          onDelta: (text) => {
            content += text;
            h.onTextDelta(text);
          },
        },
        signal,
      );
      return {
        content,
        thinking: "",
        toolCalls: result.toolCalls.map(
          (c): ToolCall => ({ id: c.id, name: c.name, args: JSON.parse(c.arguments) as Record<string, unknown> }),
        ),
        finishReason: result.finishReason,
        usage: null,
      };
    },
  };
}

/**
 * The P1/P2 createOpenAiTransport, rebuilt over createOpenAiAgentTransport:
 * the same ModelTransport the worker landed in P2 (tools in the request,
 * raw-arguments toolCalls in the result, model errors rethrown unwrapped) —
 * MUST satisfy P2's liteLlm.test.ts tool-call legs unchanged.
 *
 * P2-COMPAT DEFAULT (documented): unlike createOpenAiAgentTransport, this
 * legacy shim keeps `fetchImpl = fetch` so P2's suite and the worker's
 * re-export stay source-compatible unmodified (ruling R1). P3 production
 * composition (Task 16) passes the guarded egress into the FULL engine's
 * transports; this shim is only the bounded P2-compat path.
 */
export function createLegacyOpenAiTransport(fetchImpl: typeof fetch = fetch): LegacyModelTransport {
  const agent = createOpenAiAgentTransport(fetchImpl);
  return {
    async stream(req, h, signal) {
      const agentReq: AgentRequest = {
        model: req.model,
        baseUrl: req.baseUrl,
        apiKey: req.apiKey,
        system: [],
        messages: req.messages.map((m): AgentRequest["messages"][number] => {
          if (m.role === "assistant" && m.toolCalls !== undefined) {
            return {
              role: "assistant",
              content: m.content,
              toolCalls: m.toolCalls.map((c) => ({
                id: c.id,
                name: c.name,
                args: JSON.parse(c.arguments) as Record<string, unknown>,
              })),
            };
          }
          return { role: m.role, content: m.content, ...(m.role === "tool" ? { toolCallId: m.toolCallId } : {}) };
        }),
        tools: req.tools !== undefined ? req.tools.map((t) => t.function) : [],
        cacheMode: "none",
      };
      let content = "";
      const res = await agent.stream(agentReq, { onTextDelta: (t) => { content += t; h.onDelta(t); } }, signal);
      const legacyToolCalls: LegacyToolCall[] = res.toolCalls.map((c) => ({
        id: c.id,
        name: c.name,
        arguments: JSON.stringify(c.args),
      }));
      return { finishReason: res.finishReason, toolCalls: legacyToolCalls };
    },
  };
}
