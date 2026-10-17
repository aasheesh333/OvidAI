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

import { createLegacyOpenAiTransport } from "@ovid/agent-core";

export { TerminalModelError, TransientModelError } from "@ovid/agent-core";
export type {
  LegacyChatMessage as ChatMessage,
  LegacyStreamHandlers as StreamHandlers,
  LegacyModelTransport as ModelTransport,
  LegacyToolCall as ToolCall,
} from "@ovid/agent-core";

export const createOpenAiTransport = createLegacyOpenAiTransport;
