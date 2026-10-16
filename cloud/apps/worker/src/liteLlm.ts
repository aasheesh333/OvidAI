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
 */

export interface ChatMessage {
  role: "system" | "user" | "assistant";
  content: string;
}

export interface StreamHandlers {
  onDelta(text: string): void;
}

export interface ModelTransport {
  stream(
    req: { baseUrl: string; apiKey: string; model: string; messages: ChatMessage[] },
    h: StreamHandlers,
    signal: AbortSignal,
  ): Promise<{ finishReason: string | null }>;
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

/** One parsed `data:` payload; mutates nothing, returns the delta (if any) and finish_reason (if any). */
function readChunk(json: string): { delta: string | null; finishReason: string | null } {
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    return { delta: null, finishReason: null }; // garbage line: skip, keep streaming
  }
  // The include_usage trailer chunk has an empty `choices` array — guard [0].
  const choice = (
    parsed as {
      choices?: Array<{ delta?: { content?: unknown }; finish_reason?: unknown }>;
    } | null
  )?.choices?.[0];
  const content = choice?.delta?.content;
  const finish = choice?.finish_reason;
  return {
    delta: typeof content === "string" && content !== "" ? content : null,
    finishReason: typeof finish === "string" && finish !== "" ? finish : null,
  };
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
            messages: req.messages,
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
        const { delta, finishReason: fr } = readChunk(value);
        if (delta !== null) h.onDelta(delta);
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

      return { finishReason };
    },
  };
}
