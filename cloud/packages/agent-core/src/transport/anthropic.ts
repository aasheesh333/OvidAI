/**
 * Anthropic Messages native transport (P3 Task 5, BYOK): the Dart
 * `_callAnthropicOnce` leg re-homed onto the Task-1 AgentTransport seam.
 *
 * Wire differences handled here (agent_service.dart §"ANTHROPIC NATIVE"):
 *   • endpoint  POST {base}/v1/messages — x-api-key + anthropic-version
 *   • body      {model, max_tokens (REQUIRED, req.maxTokens ?? 8192), stream,
 *               system blocks, messages, tools [{name,description,input_schema,
 *               cache_control?}], thinking budget on effort "high"}
 *   • SSE       named events (message_start / content_block_* / message_delta /
 *               message_stop / error) — no [DONE], no choices
 *   • tool use  assistant tool_use blocks → user tool_result blocks
 *
 * Prompt-cache marks from Task 3 (AgentMessage.cacheControl /
 * MarkedToolSpec.cacheControl) serialize as wire `cache_control` — but only
 * when req.cacheMode is "anthropicNative" (Dart's `caps.marks` gating); with
 * caching off the marks never reach the wire. Volatile rows ride LAST and are
 * never marked, whatever marks they carry.
 *
 * Error taxonomy is P1's (./errors.ts): 429/5xx → Transient, other 4xx →
 * Terminal, stream ending without `message_stop` → Transient (truncation
 * parity), mid-stream SSE `error` events classified by their error.type.
 * Egress MUST be the EgressFetch param (SSRF-guarded, spec D3/§11) — never
 * raw fetch.
 */

import type {
  AgentMessage,
  AgentRequest,
  AgentResponse,
  AgentStreamHandlers,
  AgentTransport,
  ToolCall,
  ToolSpec,
} from "../types.js";
import type { EgressFetch } from "../ports.js";
import type { MarkedToolSpec } from "../promptCache.js";
import { TerminalModelError, TransientModelError } from "./errors.js";

export interface AnthropicBlock { type: "text" | "tool_use" | "tool_result" | "thinking"; [k: string]: unknown; }
export interface AnthropicMessage { role: "user" | "assistant"; content: AnthropicBlock[] | string; }

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/** AgentMessage.cacheControl → the wire shape (ttl omitted → provider 5m default). */
function wireCacheControl(cc: NonNullable<AgentMessage["cacheControl"]>): { type: "ephemeral"; ttl?: "5m" | "1h" } {
  return { type: "ephemeral", ...(cc.ttl !== undefined ? { ttl: cc.ttl } : {}) };
}

// ── request conversion ───────────────────────────────────────────────────────

interface ToolResultState {
  /** the trailing user message collecting tool_result blocks (Dart `_toolResults`) */
  message: AnthropicMessage;
  blocks: AnthropicBlock[];
}

/**
 * AgentMessages → Anthropic {system blocks, messages} (port of Dart
 * `_anthropicRequestMessages` + `_convertAnthropicRow`):
 * - system rows become top-level system BLOCKS; a run of consecutive system
 *   rows merges into one text block joined "\n\n" (Dart collapses all system
 *   entries into one string; blocks preserve the same order and text).
 * - assistant toolCalls → tool_use blocks (args object as `input`; the TS seam
 *   carries parsed args, so Dart's malformed-JSON degrade-to-{} can't occur —
 *   a non-object args value still degrades to {} defensively).
 * - tool rows → user-role messages with tool_result blocks; CONSECUTIVE tool
 *   rows share one user turn (the wire requires each turn's tool_results
 *   together — Dart parity).
 * - volatile rows land LAST, as user text turns, and are never cache-marked
 *   (including volatile system rows — Dart's `volatileAsUser` hoist, so they
 *   never sit inside the stable cached system prefix).
 * - cacheControl marks serialize as cache_control on the marked block: a
 *   marked message's content becomes block form with the mark on its LAST
 *   block; a marked system run carries the run's last mark on its merged block.
 *   `opts.cacheControl:false` suppresses every mark (the transport's cacheMode
 *   gate); rows without marks are unaffected.
 */
export function convertMessagesToAnthropic(
  msgs: readonly AgentMessage[],
  opts?: { cacheControl?: boolean },
): { system: AnthropicBlock[]; messages: AnthropicMessage[] } {
  const serializeMarks = opts?.cacheControl !== false;
  const system: AnthropicBlock[] = [];
  const messages: AnthropicMessage[] = [];
  const volatileTail: AgentMessage[] = [];
  let openRun: { text: string[]; mark?: NonNullable<AgentMessage["cacheControl"]> } | null = null;
  let toolResultState: ToolResultState | null = null;

  const flushSystemRun = (): void => {
    if (openRun === null) return;
    const run = openRun;
    openRun = null;
    if (run.text.length === 0) return;
    system.push({
      type: "text",
      text: run.text.join("\n\n"),
      ...(run.mark !== undefined && serializeMarks ? { cache_control: wireCacheControl(run.mark) } : {}),
    });
  };

  /** Serialize a row's mark onto its wire message (last block; string content becomes a text block). */
  const applyMark = (wire: AnthropicMessage, m: AgentMessage): void => {
    if (m.cacheControl === undefined || !serializeMarks) return;
    const blocks: AnthropicBlock[] =
      typeof wire.content === "string"
        ? [{ type: "text", text: wire.content }]
        : [...wire.content];
    if (blocks.length === 0) return; // nothing content-bearing to mark (Task 3 never marks these)
    const last = blocks[blocks.length - 1]!;
    blocks[blocks.length - 1] = { ...last, cache_control: wireCacheControl(m.cacheControl) };
    wire.content = blocks;
  };

  for (const m of msgs) {
    if (m.volatile) {
      // Any volatile row rides the tail as an unmarked user turn.
      flushSystemRun();
      toolResultState = null;
      volatileTail.push(m);
      continue;
    }
    if (m.role === "system") {
      toolResultState = null;
      if (typeof m.content === "string" && m.content.trim() !== "") {
        if (openRun === null) openRun = { text: [] };
        openRun.text.push(m.content);
        if (m.cacheControl !== undefined) openRun.mark = m.cacheControl; // last mark in the run wins
      }
      continue;
    }
    flushSystemRun();
    if (m.role === "tool") {
      const block: AnthropicBlock = { type: "tool_result", tool_use_id: m.toolCallId ?? "", content: m.content };
      if (toolResultState !== null) {
        toolResultState.blocks.push(block);
        toolResultState.message.content = toolResultState.blocks;
      } else {
        const blocks: AnthropicBlock[] = [block];
        const message: AnthropicMessage = { role: "user", content: blocks };
        toolResultState = { message, blocks };
        messages.push(message);
      }
      if (m.cacheControl !== undefined) applyMark(toolResultState.message, m);
      continue;
    }
    toolResultState = null;
    if (m.role === "assistant") {
      const blocks: AnthropicBlock[] = [];
      if (m.content !== "") blocks.push({ type: "text", text: m.content });
      for (const c of m.toolCalls ?? []) {
        blocks.push({
          type: "tool_use",
          id: c.id,
          name: c.name,
          input:
            c.args !== null && typeof c.args === "object" && !Array.isArray(c.args)
              ? c.args
              : {}, // Dart's malformed-args degrade, defensive at this typed seam
        });
      }
      if (blocks.length === 0) continue; // empty assistant row → dropped (Dart parity)
      const wire: AnthropicMessage = { role: "assistant", content: blocks };
      applyMark(wire, m);
      messages.push(wire);
      continue;
    }
    // user — text passes through as a plain string unless the row is marked
    const wire: AnthropicMessage = { role: "user", content: m.content };
    applyMark(wire, m);
    messages.push(wire);
  }
  flushSystemRun();
  for (const m of volatileTail) {
    messages.push({ role: "user", content: m.content }); // never marked
  }
  return { system, messages };
}

/** ToolSpec (canonical seam) → the Anthropic wire shape; MarkedToolSpec marks serialize. */
function toAnthropicTools(
  tools: readonly ToolSpec[],
  serializeMarks: boolean,
): Array<Record<string, unknown>> {
  return tools.map((t) => {
    const mark = (t as MarkedToolSpec).cacheControl;
    return {
      name: t.name,
      description: t.description,
      input_schema: t.parameters,
      ...(mark !== undefined && serializeMarks ? { cache_control: wireCacheControl(mark) } : {}),
    };
  });
}

// ── SSE stream reading ───────────────────────────────────────────────────────

/** One in-flight tool_use block: id/name from content_block_start, args accumulated from input_json_delta. */
interface ToolBlockBuffer { id: string; name: string; args: string; }

/** Accumulated args → ToolCall.args; malformed/non-object JSON → TerminalModelError naming the call. */
function finalizeToolCall(buf: ToolBlockBuffer): ToolCall {
  const label = buf.name !== "" ? buf.name : buf.id;
  if (buf.args.trim() === "") return { id: buf.id, name: buf.name, args: {} }; // no fragments → no-arg call
  let args: unknown;
  try {
    args = JSON.parse(buf.args);
  } catch {
    throw new TerminalModelError(`tool call "${label}" returned malformed JSON arguments`);
  }
  if (args === null || typeof args !== "object" || Array.isArray(args)) {
    throw new TerminalModelError(`tool call "${label}" returned non-object JSON arguments`);
  }
  return { id: buf.id, name: buf.name, args: args as Record<string, unknown> };
}

/** message_delta stop_reason → AgentResponse.finishReason (end_turn/max_tokens/tool_use; others pass through raw). */
function mapStopReason(reason: string): string {
  if (reason === "end_turn") return "stop";
  if (reason === "tool_use") return "tool_calls";
  if (reason === "max_tokens") return "length";
  return reason;
}

/** Merged Anthropic usage fields across message_start/message_delta. */
interface UsageState {
  input?: number;
  output?: number;
  cacheRead?: number;
  cacheWrite?: number;
}

function mergeUsage(state: UsageState, raw: unknown): void {
  if (raw === null || typeof raw !== "object") return;
  const u = raw as Record<string, unknown>;
  if (typeof u.input_tokens === "number") state.input = u.input_tokens;
  if (typeof u.output_tokens === "number") state.output = u.output_tokens;
  if (typeof u.cache_read_input_tokens === "number") state.cacheRead = u.cache_read_input_tokens;
  if (typeof u.cache_creation_input_tokens === "number") state.cacheWrite = u.cache_creation_input_tokens;
}

/**
 * Anthropic usage → Usage, Dart `_normalizeAnthropicUsage` parity: inputTokens
 * sums input + cache reads + writes so the metering matches the [OI] leg's
 * prompt_tokens (which includes cached tokens); the breakdown rides the
 * optional cache* fields.
 */
function normalizeUsage(state: UsageState): { input: number; output: number; cacheRead?: number; cacheWrite?: number } | null {
  const hasInput = state.input !== undefined || state.cacheRead !== undefined || state.cacheWrite !== undefined;
  if (!hasInput && state.output === undefined) return null;
  return {
    input: (state.input ?? 0) + (state.cacheRead ?? 0) + (state.cacheWrite ?? 0),
    output: state.output ?? 0,
    cacheRead: state.cacheRead,
    cacheWrite: state.cacheWrite,
  };
}

/** Mid-stream `event: error` classification: 429/5xx/529-class error types retry, other 4xx-class fail. */
function throwStreamError(errRaw: unknown): never {
  const err = (errRaw ?? {}) as { type?: unknown; message?: unknown };
  const type = typeof err.type === "string" ? err.type : "unknown";
  const detail = typeof err.message === "string" && err.message !== "" ? err.message : "Anthropic stream error";
  const message = `anthropic stream error (${type}): ${detail}`;
  if (type === "overloaded_error" || type === "api_error" || type === "rate_limit_error") {
    throw new TransientModelError(message);
  }
  throw new TerminalModelError(message);
}

export function createAnthropicTransport(egress: EgressFetch): AgentTransport {
  return {
    apiFormat: "anthropic",
    async stream(req: AgentRequest, h: AgentStreamHandlers, signal: AbortSignal): Promise<AgentResponse> {
      const url = `${req.baseUrl.replace(/\/+$/, "")}/v1/messages`;
      const serializeMarks = req.cacheMode === "anthropicNative";
      const converted = convertMessagesToAnthropic([...req.system, ...req.messages], {
        cacheControl: serializeMarks,
      });
      const thinkingOn = req.effort === "high";

      let res: Response;
      try {
        res = await egress(url, {
          method: "POST",
          headers: {
            "x-api-key": req.apiKey,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
            accept: "text/event-stream",
          },
          body: JSON.stringify({
            model: req.model,
            max_tokens: req.maxTokens ?? 8192, // Anthropic REQUIRES it
            stream: true,
            ...(converted.system.length > 0 ? { system: converted.system } : {}),
            messages: converted.messages,
            ...(req.tools.length > 0 ? { tools: toAnthropicTools(req.tools, serializeMarks) } : {}),
            ...(thinkingOn ? { thinking: { type: "enabled", budget_tokens: 4096 } } : {}),
            // the API rejects temperature alongside a thinking budget
            ...(req.temperature !== undefined && !thinkingOn ? { temperature: req.temperature } : {}),
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
        if (res.status === 429 || res.status >= 500) throw new TransientModelError(message); // 529 ≥ 500
        throw new TerminalModelError(message);
      }
      if (res.body === null) {
        throw new TransientModelError("model response has no body");
      }

      let finishReason: string | null = null;
      let sawMessageStop = false;
      let content = "";
      let thinking = "";
      const usageState: UsageState = {};
      const openBlocks = new Map<number, ToolBlockBuffer>(); // tool_use buffers between start and stop
      const finishedCalls = new Map<number, ToolCall>(); // finalized calls, by content-block index
      const decoder = new TextDecoder(); // streaming mode: splits multi-byte chars across chunks safely
      const reader = res.body.getReader();

      // SSE event assembly: `event:` sets the pending name, `data:` lines
      // accumulate (joined "\n"), a blank line dispatches. The payload's own
      // `type` field is the fallback when no `event:` line preceded it.
      let pendingEvent: string | null = null;
      let pendingData: string[] = [];

      const dispatchEvent = (): void => {
        const name = pendingEvent;
        const data = pendingData.join("\n");
        pendingEvent = null;
        pendingData = [];
        if (data === "") return; // event with no data (or stray boundary) — ignore
        let payload: unknown;
        try {
          payload = JSON.parse(data);
        } catch {
          return; // garbage line: skip, keep streaming
        }
        if (payload === null || typeof payload !== "object" || Array.isArray(payload)) return;
        const p = payload as Record<string, unknown>;
        const type =
          typeof name === "string" && name !== ""
            ? name
            : typeof p.type === "string" && p.type !== ""
              ? p.type
              : "";
        const index = typeof p.index === "number" && Number.isInteger(p.index) ? p.index : 0;
        switch (type) {
          case "message_start": {
            const message = p.message;
            if (message !== null && typeof message === "object") {
              mergeUsage(usageState, (message as Record<string, unknown>).usage);
            }
            break;
          }
          case "content_block_start": {
            const block = p.content_block;
            if (block !== null && typeof block === "object") {
              const b = block as Record<string, unknown>;
              if (b.type === "tool_use") {
                openBlocks.set(index, {
                  id: typeof b.id === "string" && b.id !== "" ? b.id : `call_${index}`,
                  name: typeof b.name === "string" ? b.name : "",
                  args: "",
                });
              }
              // thinking blocks need no open state: their deltas arrive as thinking_delta
            }
            break;
          }
          case "content_block_delta": {
            const delta = p.delta;
            if (delta === null || typeof delta !== "object") break;
            const d = delta as Record<string, unknown>;
            if (d.type === "text_delta" && typeof d.text === "string" && d.text !== "") {
              content += d.text;
              h.onTextDelta(d.text);
            } else if (d.type === "thinking_delta" && typeof d.thinking === "string" && d.thinking !== "") {
              thinking += d.thinking;
              h.onThinkingDelta?.(d.thinking);
            } else if (d.type === "input_json_delta" && typeof d.partial_json === "string") {
              let buf = openBlocks.get(index);
              if (buf === undefined) {
                // delta before start (defensive): synthesize the buffer Dart's putIfAbsent creates
                buf = { id: `call_${index}`, name: "", args: "" };
                openBlocks.set(index, buf);
              }
              buf.args += d.partial_json;
            }
            // signature_delta and future delta types: ignored
            break;
          }
          case "content_block_stop": {
            // finalize the tool call — malformed accumulated JSON is terminal
            const buf = openBlocks.get(index);
            if (buf !== undefined) {
              openBlocks.delete(index);
              finishedCalls.set(index, finalizeToolCall(buf));
            }
            break;
          }
          case "message_delta": {
            const delta = p.delta;
            if (delta !== null && typeof delta === "object") {
              const stop = (delta as Record<string, unknown>).stop_reason;
              if (typeof stop === "string" && stop !== "") finishReason = mapStopReason(stop);
            }
            mergeUsage(usageState, p.usage);
            break;
          }
          case "message_stop": {
            sawMessageStop = true;
            break;
          }
          case "error": {
            throwStreamError(p.error);
            break;
          }
          default:
            break; // ping and unknown event types: ignored
        }
      };

      // Handles one complete SSE line (without its terminator).
      const handleLine = (rawLine: string): void => {
        const line = rawLine.endsWith("\r") ? rawLine.slice(0, -1) : rawLine; // CRLF endings
        if (line === "") {
          dispatchEvent(); // event boundary
          return;
        }
        if (line.startsWith(":")) return; // keep-alive comment
        if (line.startsWith("event:")) {
          pendingEvent = line.slice("event:".length).replace(/^ /, ""); // strip ONE leading space
          return;
        }
        if (line.startsWith("data:")) {
          pendingData.push(line.slice("data:".length).replace(/^ /, ""));
          return;
        }
        // id:/retry: fields — unused here
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
            if (sawMessageStop) break readLoop; // ignore any trailing bytes after message_stop
          }
        }
        if (!sawMessageStop) {
          // Flush a final unterminated line, then dispatch the pending event it
          // may have completed, before deciding the stream was truncated.
          buffer += decoder.decode();
          if (buffer !== "") handleLine(buffer);
          dispatchEvent();
          if (!sawMessageStop) {
            // Clean EOF or hard reset without the terminal message_stop: truncated
            // response — retryable, never a partial-success (P1 parity).
            throw new TransientModelError("model stream ended before message_stop");
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
        // remaining body when we stopped early at message_stop or on error.
        await reader.cancel().catch(() => {});
      }

      // A buffer still open at message_stop never got its content_block_stop —
      // anomalous, but salvage what accumulated (malformed args stay terminal).
      for (const [index, buf] of openBlocks) {
        finishedCalls.set(index, finalizeToolCall(buf));
      }

      const usage = normalizeUsage(usageState);
      return {
        content,
        thinking,
        toolCalls: [...finishedCalls.entries()]
          .sort(([a], [b]) => a - b)
          .map(([, call]) => call),
        finishReason,
        usage:
          usage === null
            ? null
            : {
                inputTokens: usage.input,
                outputTokens: usage.output,
                ...(usage.cacheRead !== undefined ? { cacheReadTokens: usage.cacheRead } : {}),
                ...(usage.cacheWrite !== undefined ? { cacheWriteTokens: usage.cacheWrite } : {}),
              },
      };
    },
  };
}
