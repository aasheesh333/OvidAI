/**
 * P3 Task 4: liteLlm.ts is now a re-export shim over @ovid/agent-core. P2's
 * implementation (SSE reader, tool-call aggregation, error taxonomy) moved
 * to agent-core's transport/ — same names, same taxonomy, same wire shape —
 * so runProcessor, main.ts and liteLlm.test.ts (P1 cases AND P2's tool-call
 * additions) keep running unchanged.
 *
 * Names P2's liteLlm.ts exported (enumerated from the live file before the
 * flip): ChatMessage, ToolCall, StreamHandlers, ModelTransport,
 * TransientModelError, TerminalModelError, createOpenAiTransport.
 * The legacy shapes live in agent-core under the Legacy* names; ToolCall is
 * the RAW-arguments legacy shape (P2's), NOT agent-core's parsed-args
 * ToolCall — runProcessor and the tests read `call.arguments` as a string.
 */

import {
  createLegacyOpenAiTransport,
  TransientModelError,
  type AgentRequest,
  type AgentResponse,
  type AgentStreamHandlers,
  type AgentTransport,
  type LegacyModelTransport,
} from "@ovid/agent-core";

export { TerminalModelError, TransientModelError } from "@ovid/agent-core";
export type {
  LegacyChatMessage as ChatMessage,
  LegacyStreamHandlers as StreamHandlers,
  LegacyModelTransport as ModelTransport,
  LegacyToolCall as ToolCall,
} from "@ovid/agent-core";

export const createOpenAiTransport = createLegacyOpenAiTransport;

/** P10 Task 2: default "no SSE chunk for this long ⇒ abort" deadline. */
export const DEFAULT_STREAM_IDLE_TIMEOUT_MS = 120_000;

/**
 * Runs one stream call under a per-chunk idle watchdog.
 *
 * The timer is armed before the call and re-armed on every delta (an SSE
 * line). If it fires, the child AbortSignal is aborted (releasing the
 * underlying fetch/socket) and the call rejects as a TransientModelError —
 * so the caller's existing 3/9/27/60 s retry ladder applies. A fresh child
 * controller (and fresh timer) is created per stream() call, which is what
 * makes each retry a fresh arm.
 */
async function streamWithIdleGuard<T>(
  idleTimeoutMs: number,
  parentSignal: AbortSignal,
  call: (signal: AbortSignal, bump: () => void) => Promise<T>,
): Promise<T> {
  if (!Number.isFinite(idleTimeoutMs) || idleTimeoutMs <= 0) {
    return call(parentSignal, () => {});
  }

  const controller = new AbortController();
  const forwardAbort = (): void => controller.abort(parentSignal.reason);
  if (parentSignal.aborted) forwardAbort();
  else parentSignal.addEventListener("abort", forwardAbort, { once: true });

  let idleFired = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const bump = (): void => {
    if (timer !== undefined) clearTimeout(timer);
    timer = setTimeout(() => {
      idleFired = true;
      controller.abort(new Error("model stream idle timeout"));
    }, idleTimeoutMs);
    timer.unref?.();
  };
  bump();

  try {
    const result = await call(controller.signal, bump);
    if (idleFired) {
      throw new TransientModelError(`model stream idle for ${idleTimeoutMs} ms`);
    }
    return result;
  } catch (err) {
    if (idleFired) {
      throw new TransientModelError(`model stream idle for ${idleTimeoutMs} ms`, {
        cause: err,
      });
    }
    throw err;
  } finally {
    if (timer !== undefined) clearTimeout(timer);
    parentSignal.removeEventListener("abort", forwardAbort);
  }
}

/** Legacy (P1/P2 worker) transport wrapper — see streamWithIdleGuard. */
export function withLegacyStreamIdleTimeout(
  transport: LegacyModelTransport,
  idleTimeoutMs: number = DEFAULT_STREAM_IDLE_TIMEOUT_MS,
): LegacyModelTransport {
  return {
    stream(req, h, signal) {
      return streamWithIdleGuard(idleTimeoutMs, signal, (childSignal, bump) =>
        transport.stream(
          req,
          {
            onDelta(text) {
              bump();
              h.onDelta(text);
            },
          },
          childSignal,
        ),
      );
    },
  };
}

/** Canonical agent-core transport wrapper — see streamWithIdleGuard. */
export function withAgentStreamIdleTimeout(
  transport: AgentTransport,
  idleTimeoutMs: number = DEFAULT_STREAM_IDLE_TIMEOUT_MS,
): AgentTransport {
  return {
    apiFormat: transport.apiFormat,
    stream(req: AgentRequest, h: AgentStreamHandlers, signal: AbortSignal): Promise<AgentResponse> {
      return streamWithIdleGuard(idleTimeoutMs, signal, (childSignal, bump) =>
        transport.stream(
          req,
          {
            onTextDelta(text) {
              bump();
              h.onTextDelta(text);
            },
            ...(h.onThinkingDelta !== undefined
              ? {
                  onThinkingDelta(text: string) {
                    bump();
                    h.onThinkingDelta?.(text);
                  },
                }
              : {}),
          },
          childSignal,
        ),
      );
    },
  };
}
