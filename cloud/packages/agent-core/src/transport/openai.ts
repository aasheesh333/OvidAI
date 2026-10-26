/**
 * [OI]-compatible AgentTransport (P3 Task 4): the P1/P2 worker SSE reader,
 * re-homed into agent-core and extended onto the Task-1 AgentTransport seam.
 *
 * The SSE reader itself is P1's byte-for-byte: buffer partial lines across
 * TCP chunks, skip `:` keep-alive comments and blank event boundaries, strip
 * ONE leading space after `data:`, stop at `data: [DONE]`, treat a stream
 * that ends without [DONE] as a truncated (transient) response. Garbage
 * (unparseable) data lines are skipped, never fatal.
 *
 * Error taxonomy is P1's, from ./errors.ts. Tool-call accumulation is P2's
 * landed semantics, re-homed: `choices[0].delta.tool_calls[]` fragments merge
 * by `index` (id/name set once, arguments concatenated in arrival order), and
 * the accumulated arguments string is JSON.parsed into ToolCall.args at the
 * end — malformed JSON → TerminalModelError naming the tool call.
 */

import type { EgressFetch } from "../ports.js";
import type {
  AgentMessage,
  AgentRequest,
  AgentResponse,
  AgentStreamHandlers,
  AgentTransport,
  ToolCall,
  ToolSpec,
  Usage,
} from "../types.js";
import { TerminalModelError, TransientModelError } from "./errors.js";

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/** One `delta.tool_calls[]` fragment, loosely typed (validated in the aggregator). */
interface ToolCallFragment {
  index?: unknown;
  id?: unknown;
  function?: { name?: unknown; arguments?: unknown } | null;
}

/** The include_usage trailer chunk, loosely typed (validated in readChunk). */
interface UsageFragment {
  prompt_tokens?: unknown;
  completion_tokens?: unknown;
  prompt_tokens_details?: { cached_tokens?: unknown } | null;
  /** LiteLLM's opt-in measured streaming cost (USD), never an estimate. */
  cost?: unknown;
}

/** Convert decimal text to fixed-point without binary arithmetic or rounding. */
function measuredCost(value: string): string | null {
  const match = /^(\d+)(?:\.(\d*))?(?:e([+-]?\d+))?$/i.exec(value);
  if (match === null) return null;
  const whole = match[1]!;
  const fraction = match[2] ?? "";
  const exponent = Number(match[3] ?? "0");
  if (!Number.isSafeInteger(exponent) || Math.abs(exponent) > 1_000) return null;
  const digits = `${whole}${fraction}`;
  const point = whole.length + exponent;
  let fixedWhole: string;
  let fixedFraction: string;
  if (point <= 0) {
    fixedWhole = "0";
    fixedFraction = `${"0".repeat(-point)}${digits}`;
  } else if (point >= digits.length) {
    fixedWhole = `${digits}${"0".repeat(point - digits.length)}`;
    fixedFraction = "";
  } else {
    fixedWhole = digits.slice(0, point);
    fixedFraction = digits.slice(point);
  }
  fixedWhole = fixedWhole.replace(/^0+(?=\d)/, "");
  fixedFraction = fixedFraction.replace(/0+$/, "");
  if (fixedWhole.length > 28 || fixedFraction.length > 10) return null;
  return fixedFraction === "" ? fixedWhole : `${fixedWhole}.${fixedFraction}`;
}

interface JsonRange { start: number; end: number; }

function skipJsonWhitespace(json: string, start: number): number {
  let index = start;
  while (index < json.length && /\s/.test(json[index]!)) index += 1;
  return index;
}

/** Return the index after a JSON string, or -1 for an unterminated value. */
function skipJsonString(json: string, start: number): number {
  if (json[start] !== '"') return -1;
  let index = start + 1;
  while (index < json.length) {
    if (json[index] === '"') return index + 1;
    index += json[index] === "\\" ? 2 : 1;
  }
  return -1;
}

/** Skip one value without parsing its numbers; provider JSON remains the authority. */
function skipJsonValue(json: string, start: number, depth = 0): number {
  if (depth > 128) return -1;
  const index = skipJsonWhitespace(json, start);
  const first = json[index];
  if (first === '"') return skipJsonString(json, index);
  if (first !== "{" && first !== "[") {
    let end = index;
    while (end < json.length && !/[\s,\]}]/.test(json[end]!)) end += 1;
    return end === index ? -1 : end;
  }

  const object = first === "{";
  let cursor = skipJsonWhitespace(json, index + 1);
  if (json[cursor] === (object ? "}" : "]")) return cursor + 1;
  while (cursor < json.length) {
    if (object) {
      const keyEnd = skipJsonString(json, cursor);
      if (keyEnd < 0) return -1;
      cursor = skipJsonWhitespace(json, keyEnd);
      if (json[cursor] !== ":") return -1;
      cursor += 1;
    }
    cursor = skipJsonValue(json, cursor, depth + 1);
    if (cursor < 0) return -1;
    cursor = skipJsonWhitespace(json, cursor);
    const close = object ? "}" : "]";
    if (json[cursor] === close) return cursor + 1;
    if (json[cursor] !== ",") return -1;
    cursor = skipJsonWhitespace(json, cursor + 1);
  }
  return -1;
}

/** Decode only a property-name string; numeric values are never parsed here. */
function jsonPropertyName(raw: string): string | null {
  try {
    const parsed: unknown = JSON.parse(raw);
    return typeof parsed === "string" ? parsed : null;
  } catch {
    return null;
  }
}

/** Find a direct object property with JSON's exact last-duplicate semantics. */
function findJsonProperty(json: string, object: JsonRange, name: string): JsonRange | null {
  let cursor = skipJsonWhitespace(json, object.start);
  if (json[cursor] !== "{") return null;
  cursor += 1;
  let found: JsonRange | null = null;
  while (cursor < object.end) {
    cursor = skipJsonWhitespace(json, cursor);
    if (json[cursor] === "}") return found;
    const keyStart = cursor;
    const keyEnd = skipJsonString(json, cursor);
    if (keyEnd < 0 || keyEnd > object.end) return null;
    const key = jsonPropertyName(json.slice(keyStart, keyEnd));
    cursor = skipJsonWhitespace(json, keyEnd);
    if (json[cursor] !== ":") return null;
    const valueStart = skipJsonWhitespace(json, cursor + 1);
    const valueEnd = skipJsonValue(json, valueStart);
    if (valueEnd < 0 || valueEnd > object.end) return null;
    if (key === name) found = { start: valueStart, end: valueEnd };
    cursor = skipJsonWhitespace(json, valueEnd);
    if (json[cursor] === "}") return found;
    if (json[cursor] !== ",") return null;
    cursor += 1;
  }
  return null;
}

/** Capture usage.cost before JSON.parse can round a numeric token through IEEE754. */
function rawUsageCostToken(json: string): string | null {
  const usage = findJsonProperty(json, { start: 0, end: json.length }, "usage");
  if (usage === null) return null;
  const cost = findJsonProperty(json, usage, "cost");
  return cost === null ? null : json.slice(cost.start, cost.end);
}

function measuredCostToken(token: string | null, parsed: unknown): string | null {
  if (token === null) return null;
  if (token.startsWith('"')) {
    return typeof parsed === "string" ? measuredCost(parsed) : null;
  }
  return typeof parsed === "number" && Number.isFinite(parsed)
    ? measuredCost(token)
    : null;
}

function withMeasuredFacts(
  usage: Usage | null,
  providerModel: string | null,
  costUsd: string | null,
): Usage | null {
  if (usage === null) return null;
  return {
    ...usage,
    providerModel,
    costUsd,
    costSource: costUsd === null ? null : "litellm",
  };
}

/** One parsed `data:` payload; mutates nothing, returns the deltas and finish_reason (if any). */
function readChunk(json: string): {
  delta: string | null;
  thinking: string | null;
  toolCallDeltas: ToolCallFragment[] | null;
  finishReason: string | null;
  usage: Usage | null;
  providerModel: string | null;
  costUsd: string | null;
} {
  const rawCostToken = rawUsageCostToken(json);
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    return { delta: null, thinking: null, toolCallDeltas: null, finishReason: null, usage: null, providerModel: null, costUsd: null }; // garbage line: skip, keep streaming
  }
  const obj = parsed as { choices?: unknown[]; usage?: unknown; model?: unknown } | null;
  // The include_usage trailer chunk has an empty `choices` array — guard [0].
  const choice = (
    obj?.choices as Array<{
      delta?: { content?: unknown; reasoning_content?: unknown; tool_calls?: unknown };
      finish_reason?: unknown;
    }> | undefined
  )?.[0];
  const content = choice?.delta?.content;
  const reasoning = choice?.delta?.reasoning_content;
  const toolCalls = choice?.delta?.tool_calls;
  const finish = choice?.finish_reason;
  const usageRaw = obj?.usage;
  let usage: Usage | null = null;
  let costUsd: string | null = null;
  if (usageRaw !== null && typeof usageRaw === "object") {
    const u = usageRaw as UsageFragment;
    const input = u.prompt_tokens;
    const output = u.completion_tokens;
    costUsd = measuredCostToken(rawCostToken, u.cost);
    if (typeof input === "number" && typeof output === "number") {
      const cached = u.prompt_tokens_details?.cached_tokens;
      usage = {
        inputTokens: input,
        outputTokens: output,
        ...(typeof cached === "number" ? { cacheReadTokens: cached } : {}),
      };
    }
  }
  return {
    delta: typeof content === "string" && content !== "" ? content : null,
    thinking: typeof reasoning === "string" && reasoning !== "" ? reasoning : null,
    toolCallDeltas: Array.isArray(toolCalls) ? (toolCalls as ToolCallFragment[]) : null,
    finishReason: typeof finish === "string" && finish !== "" ? finish : null,
    usage,
    providerModel:
      typeof obj?.model === "string" && obj.model.trim() !== "" ? obj.model : null,
    costUsd,
  };
}

/**
 * SSE tool-call aggregator: merges `delta.tool_calls[]` fragments by `index`
 * — id/name set once (first non-empty wins), arguments concatenated in
 * arrival order. finish() is index-sorted; a call that never carried an id
 * gets a stable synthesized one so the caller can always key results to
 * calls. (P2's landed semantics, re-homed verbatim.)
 */
function createToolCallAggregator(): {
  merge(fragments: ToolCallFragment[]): void;
  finish(): Array<{ id: string; name: string; args: string }>;
} {
  const acc = new Map<number, { id?: string; name?: string; args: string }>();
  return {
    merge(fragments) {
      for (const f of fragments) {
        const index = typeof f.index === "number" && Number.isInteger(f.index) ? f.index : 0;
        let entry = acc.get(index);
        if (entry === undefined) {
          entry = { args: "" };
          acc.set(index, entry);
        }
        if (typeof f.id === "string" && f.id !== "" && entry.id === undefined) entry.id = f.id;
        const fn = f.function;
        if (fn !== null && fn !== undefined) {
          if (typeof fn.name === "string" && fn.name !== "" && entry.name === undefined) {
            entry.name = fn.name;
          }
          if (typeof fn.arguments === "string") entry.args += fn.arguments;
        }
      }
    },
    finish() {
      return [...acc.entries()]
        .sort(([a], [b]) => a - b)
        .map(([index, e]) => ({
          id: e.id ?? `call_${index}`,
          name: e.name ?? "",
          args: e.args,
        }));
    },
  };
}

/** Accumulated raw arguments → ToolCall.args; malformed JSON → TerminalModelError naming the call. */
function parseToolCalls(raw: Array<{ id: string; name: string; args: string }>): ToolCall[] {
  return raw.map((c) => {
    let args: unknown;
    try {
      args = JSON.parse(c.args);
    } catch {
      throw new TerminalModelError(
        `tool call "${c.name !== "" ? c.name : c.id}" returned malformed JSON arguments`,
      );
    }
    if (args === null || typeof args !== "object" || Array.isArray(args)) {
      throw new TerminalModelError(
        `tool call "${c.name !== "" ? c.name : c.id}" returned non-object JSON arguments`,
      );
    }
    return { id: c.id, name: c.name, args: args as Record<string, unknown> };
  });
}

/** ToolSpec (canonical seam) → the [OI] wire shape. */
function toWireTool(spec: ToolSpec): { type: "function"; function: ToolSpec } {
  return { type: "function", function: spec };
}

/**
 * AgentMessage → [OI] wire shape: assistant toolCalls (parsed args) serialize
 * back onto message.tool_calls [{id, type:"function", function:{name,
 * arguments}}] with arguments as the raw JSON string; role:"tool" maps onto
 * {role:"tool", tool_call_id}. system/user pass through. volatile and
 * cacheControl are prompt-cache metadata, never sent on the openai wire.
 */
function toWireMessages(messages: AgentMessage[]): Array<Record<string, unknown>> {
  return messages.map((m) => {
    if (m.role === "assistant" && m.toolCalls !== undefined) {
      return {
        role: "assistant",
        content: m.content,
        tool_calls: m.toolCalls.map((c) => ({
          id: c.id,
          type: "function",
          function: { name: c.name, arguments: JSON.stringify(c.args) },
        })),
      };
    }
    if (m.role === "tool") {
      return { role: "tool", content: m.content, tool_call_id: m.toolCallId };
    }
    if (m.role === "user" && m.images !== undefined && m.images.length > 0) {
      // Multimodal user turn: [OI]-compatible content parts. Text first so a
      // provider that only renders the first part still sees the prompt.
      return {
        role: "user",
        content: [
          { type: "text", text: m.content },
          ...m.images.map((img) => ({
            type: "image_url",
            image_url: { url: `data:${img.mimeType};base64,${img.dataBase64}` },
          })),
        ],
      };
    }
    return { role: m.role, content: m.content };
  });
}

/**
 * T5-I1 (binding): NO raw-`fetch` default. Every construction site must pass
 * the SSRF-guarded egress (`createGuardedEgressFetch`, ssrf.ts) explicitly —
 * a silent default would bypass spec D3/§11. Tests that need a plain client
 * pass `fetch` themselves; the P2-compat shim (transport/legacy.ts) keeps its
 * own documented default so P2's suite stays unmodified.
 */
export function createOpenAiAgentTransport(fetchImpl: EgressFetch): AgentTransport {
  return {
    apiFormat: "openai",
    async stream(req: AgentRequest, h: AgentStreamHandlers, signal: AbortSignal): Promise<AgentResponse> {
      const url = `${req.baseUrl.replace(/\/+$/, "")}/chat/completions`;

      let res: Response;
      try {
        res = await fetchImpl(url, {
          method: "POST",
          headers: {
            authorization: `Bearer ${req.apiKey}`,
            "content-type": "application/json",
            accept: "text/event-stream",
            // Ruling R3: consecutive turns of one session share LiteLLM's
            // stable-prefix cache. Only the openai-format leg sends it.
            ...(req.promptCacheKey !== undefined
              ? { prompt_cache_key: req.promptCacheKey }
              : {}),
          },
          body: JSON.stringify({
            model: req.model,
            messages: toWireMessages([...req.system, ...req.messages]),
            // v0 body shape: the tools key is absent unless tools are passed.
            ...(req.tools.length > 0 ? { tools: req.tools.map(toWireTool) } : {}),
            stream: true,
            stream_options: { include_usage: true },
            ...(req.temperature !== undefined ? { temperature: req.temperature } : {}),
            ...(req.maxTokens !== undefined ? { max_tokens: req.maxTokens } : {}),
            // The router already derived the inherited effort (preset model
            // suffix or the root snapshot); the transport only puts it on the
            // wire. Absent = the provider's own default, never a guess.
            ...(req.effort !== undefined ? { reasoning_effort: req.effort } : {}),
          }),
          signal,
        });
      } catch (err) {
        if (signal.aborted) throw err; // caller-initiated abort: reject as-is
        throw new TransientModelError(`model request failed: ${errorMessage(err)}`, {
          cause: err,
        });
      }

      if (!res.ok) {
        const body = (await res.text().catch(() => "")).trim().slice(0, 300);
        const message = `model HTTP ${res.status}${body === "" ? "" : `: ${body}`}`;
        if (res.status === 429 || res.status >= 500) throw new TransientModelError(message);
        throw new TerminalModelError(message);
      }
      if (res.body === null) {
        throw new TransientModelError("model response has no body");
      }

      let finishReason: string | null = null;
      let sawDone = false;
      let content = "";
      let thinking = "";
      let usage: Usage | null = null;
      let providerModel: string | null = null;
      let costUsd: string | null = null;
      const toolCalls = createToolCallAggregator();
      const decoder = new TextDecoder(); // streaming mode: splits multi-byte chars across chunks safely
      const reader = res.body.getReader();

      // Handles one complete SSE line (without its terminator).
      const handleLine = (rawLine: string): void => {
        const line = rawLine.endsWith("\r") ? rawLine.slice(0, -1) : rawLine; // CRLF endings
        if (line === "" || line.startsWith(":")) return; // event boundary / keep-alive comment
        if (!line.startsWith("data:")) return; // event:/id:/retry: fields — unused here
        const value = line.slice("data:".length).replace(/^ /, ""); // SSE: strip ONE leading space
        if (value === "[DONE]") {
          sawDone = true;
          return;
        }
        const { delta, thinking: thinkDelta, toolCallDeltas, finishReason: fr, usage: u, providerModel: served, costUsd: measured } = readChunk(value);
        if (delta !== null) {
          content += delta;
          h.onTextDelta(delta);
        }
        if (thinkDelta !== null) {
          thinking += thinkDelta;
          h.onThinkingDelta?.(thinkDelta);
        }
        if (toolCallDeltas !== null) toolCalls.merge(toolCallDeltas);
        if (fr !== null) finishReason = fr;
        if (u !== null) usage = u;
        if (served !== null) providerModel = served;
        if (measured !== null) costUsd = measured;
      };

      try {
        let buffer = "";
        readLoop: while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          let nl: number;
          while ((nl = buffer.indexOf("\n")) >= 0) {
            const line = buffer.slice(0, nl);
            buffer = buffer.slice(nl + 1);
            handleLine(line);
            if (sawDone) break readLoop; // ignore any trailing bytes after [DONE]
          }
        }
        if (!sawDone) {
          // Flush a final unterminated line (e.g. `data:[DONE]` with no trailing
          // newline) before deciding the stream was truncated.
          buffer += decoder.decode();
          if (buffer !== "") handleLine(buffer);
          if (!sawDone) {
            // Clean EOF or hard reset without the terminal [DONE]: truncated
            // response — retryable, never a partial-success.
            throw new TransientModelError("model stream ended before [DONE]");
          }
        }
      } catch (err) {
        if (signal.aborted) throw err; // AbortError passes through unwrapped
        if (err instanceof TransientModelError || err instanceof TerminalModelError) throw err;
        // Mid-stream socket errors (undici surfaces these as TypeError
        // "terminated" / network errors): connection reset → transient.
        throw new TransientModelError(`model stream failed mid-response: ${errorMessage(err)}`, {
          cause: err,
        });
      } finally {
        // Release the connection: no-op after a clean EOF, cancels the
        // remaining body when we stopped early at [DONE] or on error.
        await reader.cancel().catch(() => {});
      }

      return {
        content,
        thinking,
        toolCalls: parseToolCalls(toolCalls.finish()),
        finishReason,
        usage: withMeasuredFacts(usage, providerModel, costUsd),
      };
    },
  };
}
