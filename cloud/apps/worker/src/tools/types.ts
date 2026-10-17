import type { SandboxHandle } from "@ovid/sandbox";
import type { SessionEventType } from "@ovid/shared";

/**
 * The P2/P3 tool seam (plan Task 12; canonical for P3/P5/P6 per the parent
 * ledger's R2 ruling). An AgentTool validates its own input (zod) and NEVER
 * throws for user errors — invalid input is an isError ToolResult.
 */

export interface ToolResult {
  content: string;
  isError: boolean;
}

/**
 * The [OI] wire shape of one function tool. Defined ONCE here: liteLlm.ts
 * (request building) and registry.ts (specs()) both import it.
 */
export interface ModelToolSpec {
  type: "function";
  function: {
    name: string;
    description: string;
    parameters: Record<string, unknown>;
  };
}

/** Everything a tool execution is allowed to touch: ONE sandbox handle + the session event stream. */
export interface ToolContext {
  sandbox: SandboxHandle;
  userId: string;
  sessionId: string;
  runId: string;
  emitEvent(type: SessionEventType, payload: Record<string, unknown>): Promise<void>;
}

export interface AgentTool {
  readonly name: string;
  readonly description: string;
  /** JSON Schema object sent to the model. */
  readonly parameters: Record<string, unknown>;
  /**
   * Validates input itself (zod). Invalid input →
   * {content: "invalid_input: …", isError: true}; never throws for user
   * errors. Infrastructure errors may propagate (the processor fails the
   * job loudly, same as the v0 unknown-error path).
   */
  execute(input: unknown, ctx: ToolContext): Promise<ToolResult>;
}

/** Formats a zod failure as the pinned invalid_input result. */
export function invalidInput(err: Error): ToolResult {
  return { content: `invalid_input: ${err.message}`, isError: true };
}
