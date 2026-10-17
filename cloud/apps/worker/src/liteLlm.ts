/**
 * OpenAI-compatible streaming transport for worker model calls. LiteLLM speaks
 * the OpenAI SSE dialect, so this is a hand-rolled SSE reader over fetch():
 * buffer partial lines across TCP chunks, skip `:` keep-alive comments and
 * blank event boundaries, stop at `data: [DONE]`.
 *
 * Error taxonomy (spec §6.1, consumed by runProcessor's retry loop):
 * - TransientModelError: 429, 5xx, network/socket failures, mid-stream
 *   connection resets, truncated streams (ended without [DONE]) → retryable.
 * - TerminalModelError: any other 4xx → fail the run immediately.
 * An aborted AbortSignal rejects with the abort error itself (never wrapped),
 * so callers can distinguish "we gave up" from "the model failed".
 *
 * P2 Task 12 (additive, v0-compatible): tool support. delta.tool_calls[]
 * fragments are merged by `index` — id/name set once, arguments concatenated
 * in arrival order — so a call's arguments reassemble byte-identical even when
 * the model splits them mid-JSON across frames. Text-only streams yield
 * `toolCalls: []`; every other v0 behavior is untouched.
 */

import type { ModelToolSpec } from "./tools/types.js";

export interface ChatMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string;
  /** role:"assistant" only — the calls this assistant turn requested. */
  toolCalls?: ToolCall[];
  /** role:"tool" only — which call this result answers. */
  toolCallId?: string;
}

/** One model-requested function call; `arguments` is the raw JSON string from the model. */
export interface ToolCall {
  id: string;
  name: string;
  arguments: string;
}

export interface StreamHandlers {
  onDelta(text: string): void;
}

export interface ModelTransport {
  stream(
    req: {
      baseUrl: string;
      apiKey: string;
      model: string;
      messages: ChatMessage[];
      tools?: ModelToolSpec[];
    },
    h: StreamHandlers,
    signal: AbortSignal,
  ): Promise<{ finishReason: string | null; toolCalls: ToolCall[] }>;
}

export class TransientModelError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = "TransientModelError";
  }
}

export class TerminalModelError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = "TerminalModelError";
  }
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/** One `delta.tool_calls[]` fragment, loosely typed (validated in the aggregator). */
interface ToolCallFragment {
  index?: unknown;
  id?: unknown;
  function?: { name?: unknown; arguments?: unknown } | null;
}

/** One parsed `data:` payload; mutates nothing, returns the delta, tool-call fragments (if any) and finish_reason (if any). */
function readChunk(json: string): {
  delta: string | null;
  toolCallDeltas: ToolCallFragment[] | null;
  finishReason: string | null;
} {
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    return { delta: null, toolCallDeltas: null, finishReason: null }; // garbage line: skip, keep streaming
  }
  // The include_usage trailer chunk has an empty `choices` array — guard [0].
  const choice = (
    parsed as {
      choices?: Array<{
        delta?: { content?: unknown; tool_calls?: unknown };
        finish_reason?: unknown;
      }>;
    } | null
  )?.choices?.[0];
  const content = choice?.delta?.content;
  const toolCalls = choice?.delta?.tool_calls;
  const finish = choice?.finish_reason;
  return {
    delta: typeof content === "string" && content !== "" ? content : null,
    toolCallDeltas: Array.isArray(toolCalls) ? (toolCalls as ToolCallFragment[]) : null,
    finishReason: typeof finish === "string" && finish !== "" ? finish : null,
  };
}

/**
 * SSE tool-call aggregator: merges `delta.tool_calls[]` fragments by `index`
 * — id/name set once (first non-empty wins), arguments concatenated in
 * arrival order. finish() is index-sorted; a call that never carried an id
 * gets a stable synthesized one so the processor can always key results to
 * calls.
 */
function createToolCallAggregator(): {
  merge(fragments: ToolCallFragment[]): void;
  finish(): ToolCall[];
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
          arguments: e.args,
        }));
    },
  };
}

/**
 * ChatMessage → [OI] wire shape: assistant toolCalls map onto
 * message.tool_calls [{id, type:"function", function:{name, arguments}}];
 * role:"tool" maps onto {role:"tool", tool_call_id}. system/user pass through.
 */
function toWireMessages(messages: ChatMessage[]): Array<Record<string, unknown>> {
  return messages.map((m) => {
    if (m.role === "assistant" && m.toolCalls !== undefined) {
      return {
        role: "assistant",
        content: m.content,
        tool_calls: m.toolCalls.map((c) => ({
          id: c.id,
          type: "function",
          function: { name: c.name, arguments: c.arguments },
        })),
      };
    }
    if (m.role === "tool") {
      return { role: "tool", content: m.content, tool_call_id: m.toolCallId };
    }
    return { role: m.role, content: m.content };
  });
}

export function createOpenAiTransport(fetchImpl: typeof fetch = fetch): ModelTransport {
  return {
    async stream(req, h, signal) {
      const url = `${req.baseUrl.replace(/\/+$/, "")}/chat/completions`;

      let res: Response;
      try {
        res = await fetchImpl(url, {
          method: "POST",
          headers: {
            authorization: `Bearer ${req.apiKey}`,
            "content-type": "application/json",
            accept: "text/event-stream",
          },
          body: JSON.stringify({
            model: req.model,
            messages: toWireMessages(req.messages),
            // v0 body shape: the tools key is absent unless tools are passed.
            ...(req.tools !== undefined && req.tools.length > 0 ? { tools: req.tools } : {}),
            stream: true,
            stream_options: { include_usage: true },
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
        const { delta, toolCallDeltas, finishReason: fr } = readChunk(value);
        if (delta !== null) h.onDelta(delta);
        if (toolCallDeltas !== null) toolCalls.merge(toolCallDeltas);
        if (fr !== null) finishReason = fr;
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

      return { finishReason, toolCalls: toolCalls.finish() };
    },
  };
}
