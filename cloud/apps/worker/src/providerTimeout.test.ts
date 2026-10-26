import { describe, expect, it } from "vitest";
import type { AgentRequest, AgentStreamHandlers, AgentResponse, AgentTransport } from "@ovid/agent-core";
import { TransientModelError } from "@ovid/agent-core";
import { withAgentStreamIdleTimeout } from "./liteLlm.js";

/**
 * A provider that never sends another SSE chunk must surface as the typed
 * retryable error — never as a hung promise, a raw AbortError leaking out of
 * the engine, or an unhandled rejection that kills the worker.
 */

const REQUEST: AgentRequest = {
  model: "test-model",
  baseUrl: "http://127.0.0.1:1",
  apiKey: "test-key",
  system: [],
  messages: [],
  tools: [],
} as unknown as AgentRequest;

const HANDLERS: AgentStreamHandlers = { onTextDelta() {} };

describe("provider timeout is a typed error, not an unhandled rejection", () => {
  it("a stalled stream aborts and rejects with TransientModelError", async () => {
    const unhandled: unknown[] = [];
    const onUnhandled = (reason: unknown): void => {
      unhandled.push(reason);
    };
    process.on("unhandledRejection", onUnhandled);
    try {
      const stalled: AgentTransport = {
        apiFormat: "openai",
        stream(_req, _h, signal): Promise<AgentResponse> {
          // Exactly what a hung provider looks like: a promise that only
          // settles when the watchdog aborts the signal.
          return new Promise((_resolve, reject) => {
            signal.addEventListener("abort", () => reject(signal.reason), { once: true });
          });
        },
      };
      const transport = withAgentStreamIdleTimeout(stalled, 25);
      const started = Date.now();
      await expect(transport.stream(REQUEST, HANDLERS, new AbortController().signal)).rejects.toBeInstanceOf(
        TransientModelError,
      );
      expect(Date.now() - started).toBeLessThan(2_000);
      // Let the microtask queue drain so a stray rejection would be observed.
      await new Promise((resolve) => setTimeout(resolve, 20));
      expect(unhandled).toEqual([]);
    } finally {
      process.off("unhandledRejection", onUnhandled);
    }
  });

  it("keeps the retryable classification distinct from a caller cancel", async () => {
    const controller = new AbortController();
    const transport = withAgentStreamIdleTimeout({
      apiFormat: "openai",
      stream(_req, _h, signal): Promise<AgentResponse> {
        return new Promise((_resolve, reject) => {
          signal.addEventListener("abort", () => reject(signal.reason), { once: true });
        });
      },
    }, 5_000);

    const pending = transport.stream(REQUEST, HANDLERS, controller.signal);
    controller.abort(new Error("user cancelled"));
    const error = await pending.catch((err: unknown) => err);
    // A cancel is NOT retried as a provider failure.
    expect(error).not.toBeInstanceOf(TransientModelError);
  });
});
