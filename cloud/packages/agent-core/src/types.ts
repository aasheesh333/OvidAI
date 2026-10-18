// Domain types for the agent core. The interfaces here are the canonical seam
// for every P3 task — copy-verbatim contract; do not rename or reshape fields
// additively consumed by later tasks (see the P3 plan briefs).

export type SessionMode = "safe" | "auto" | "drive" | "studio";
export interface ToolCall { id: string; name: string; args: Record<string, unknown>; }
/**
 * One image attached to a user message (owner directive 2026-10-18).
 *
 * Only user messages carry images: the model sees them once, with the prompt
 * that referenced them. `dataBase64` is the raw image bytes; the transports
 * turn it into the provider's own content-part shape.
 */
export interface AgentImage {
  /** e.g. "image/png", "image/jpeg", "image/webp", "image/gif". */
  mimeType: string;
  dataBase64: string;
}

export interface AgentMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string;
  /**
   * Images the model must SEE with this message. Absent on every message the
   * agent produced itself. A provider that cannot take images must never
   * receive one — the worker checks the model's capability BEFORE the run
   * starts (see modelCapabilities.ts).
   */
  images?: readonly AgentImage[];
  /**
   * Durable message-row id, when this row was rebuilt from `messages` (P3 fix
   * round I-3). Additive and never serialized to a provider: the compaction
   * ledger uses it as its durable fold boundary (`cutoffMessageId`), because
   * the ledger's in-memory `foldedMessages` count includes tool rows that are
   * never persisted and therefore cannot index a DB-rebuilt window.
   */
  id?: string;
  toolCallId?: string;        // role:"tool" — the ToolCall.id this answers
  toolCalls?: ToolCall[];     // role:"assistant"
  volatile?: boolean;         // true → never cache-marked, rides last (Task 3/7)
  cacheControl?: { type: "ephemeral"; ttl?: "5m" | "1h" };   // the typed home for Task 3's CacheMark — set ONLY by markCacheBreakpoints, serialized by the transports (Task 5 anthropic blocks; Task 15 wiring)
}
export interface ToolSpec { name: string; description: string; parameters: Record<string, unknown>; } // JSON Schema object
// CANONICAL TOOL SEAM (ruling R2 — binding P3/P5/P6): P2's AgentTool, additively extended.
// The result carries {content, isError?, artifacts?} — artifacts is the optional additive channel for
// browser/file outputs (P6 BrowserToolDef adapts onto this; P5 MCP tools register through it).
export interface ToolResult { content: string; isError?: boolean; artifacts?: unknown[]; }
export interface ToolContext {
  sessionId: string; runId: string; userId: string;
  mode: SessionMode; planMode: boolean; isSubagent: boolean; depth: number;
  unattended: boolean; callKey: string; signal: AbortSignal;
}
export interface Tool { spec: ToolSpec; timeoutMs: number; execute(args: Record<string, unknown>, ctx: ToolContext): Promise<ToolResult>; }
// tool factories below return ToolResult; where a test pins a plain string it means result.content
export interface ToolRegistry { get(name: string): Tool | undefined; all(): readonly Tool[]; }
export function createToolRegistry(tools: readonly Tool[]): ToolRegistry {
  const byName = new Map<string, Tool>();
  for (const tool of tools) byName.set(tool.spec.name, tool);
  return {
    get(name: string): Tool | undefined {
      return byName.get(name);
    },
    all(): readonly Tool[] {
      return [...byName.values()];
    },
  };
}
export interface Usage { inputTokens: number; outputTokens: number; cacheReadTokens?: number; cacheWriteTokens?: number; }
// Defined HERE in types.ts (Tasks 3/5/6 consume — do NOT redefine in promptCache.ts).
export type PromptCacheMode = "none" | "implicit" | "openaiBlocks" | "anthropicNative";
export interface AgentRequest {
  model: string; baseUrl: string; apiKey: string;
  system: AgentMessage[]; messages: AgentMessage[]; tools: ToolSpec[];
  maxTokens?: number; temperature?: number; effort?: "low" | "medium" | "high";
  cacheMode: PromptCacheMode;
  // P3 Task 15 (ruling R3, additive): the openai-format prompt-cache key. The
  // loop stamps the session id so consecutive turns of one session share
  // LiteLLM's stable-prefix cache; createOpenAiAgentTransport sends it as the
  // `prompt_cache_key` request header. The anthropic leg ignores it (native
  // cache_control blocks carry the marks instead).
  promptCacheKey?: string;
}
export interface AgentStreamHandlers { onTextDelta(text: string): void; onThinkingDelta?(text: string): void; }
export interface AgentResponse { content: string; thinking: string; toolCalls: ToolCall[]; finishReason: string | null; usage: Usage | null; }
export interface AgentTransport { readonly apiFormat: "openai" | "anthropic"; stream(req: AgentRequest, h: AgentStreamHandlers, signal: AbortSignal): Promise<AgentResponse>; }
