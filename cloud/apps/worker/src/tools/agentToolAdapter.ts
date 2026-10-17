import type { Tool, ToolContext as CoreToolContext, ToolResult as CoreToolResult } from "@ovid/agent-core";
import type { SandboxHandle } from "@ovid/sandbox";
import type { SessionEventType } from "@ovid/shared";

import type { AgentTool, ToolContext, ToolResult } from "./types.js";

/**
 * P2 AgentTool → canonical Tool adapter (ruling R1/R2): P3's tools are
 * ADDITIVE alongside P2's landed six (run_shell, read_file, write_file,
 * edit_file, glob_files, grep_files), which are NOT re-implemented — this
 * adapter is how the P2 roster joins the canonical seam.
 *
 * - spec = {name, description, parameters} from the AgentTool's own fields;
 * - timeoutMs = the tool's own clamp (run_shell max 600s) else 120s;
 * - the canonical ToolContext bridges onto P2's with callKey/signal/mode/
 *   planMode as ADDITIVE optional fields, so P2's own tests are unaffected;
 * - {content, isError} passes through; artifacts is left undefined.
 *
 * The timeout contract covers adapted P2 tools too: execute threads
 * ctx.callKey, so a dispatched run_shell is killable by callKey like any
 * canonical tool. Spill wrapping on adapted tools is the full-processor
 * path's business (Task 16); the P2-compat path keeps P2's own caps
 * byte-for-byte so its suite stays green.
 */

/** Dispatch-level budget: the Dart _toolTimeoutFor map (run_shell 10 min; default 2 min). */
const TOOL_TIMEOUT_MS: Record<string, number> = {
  run_shell: 600_000,
};
const DEFAULT_TIMEOUT_MS = 120_000;

export interface AgentToolAdapterDeps {
  /** The sandbox handle the run's tools execute in (P2 ToolContext.sandbox). */
  sandbox?: SandboxHandle;
  /**
   * P3 Task 16 additive: resolves the handle PER DISPATCH from the canonical
   * ctx. The full processor uses this to attach the right user's sandbox and
   * to thread `ctx.callKey` into a port-backed handle. Takes precedence over
   * `sandbox` when present.
   */
  sandboxFor?(ctx: CoreToolContext): SandboxHandle | Promise<SandboxHandle>;
  /**
   * The run's session event sink (P2 ToolContext.emitEvent).
   */
  emitEvent(type: SessionEventType, payload: Record<string, unknown>): Promise<void>;
  /**
   * P3 Task 16 additive: a per-dispatch sink factory, so a processor-wide
   * adapter can route events to the canonical ctx's session. Takes precedence
   * over `emitEvent` when present (existing 2-arg deps stay untouched).
   */
  emitEventFor?(ctx: CoreToolContext): (
    type: SessionEventType,
    payload: Record<string, unknown>,
  ) => Promise<void>;
}

export function adaptAgentTool(tool: AgentTool, deps: AgentToolAdapterDeps): Tool {
  return {
    spec: {
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters,
    },
    timeoutMs: TOOL_TIMEOUT_MS[tool.name] ?? DEFAULT_TIMEOUT_MS,
    async execute(args, ctx: CoreToolContext): Promise<CoreToolResult> {
      const sandbox = deps.sandboxFor !== undefined ? await deps.sandboxFor(ctx) : deps.sandbox;
      if (sandbox === undefined) {
        throw new Error("agentToolAdapter: no sandbox handle for dispatch");
      }
      const emitEvent =
        deps.emitEventFor !== undefined ? deps.emitEventFor(ctx) : deps.emitEvent;
      const bridged: ToolContext = {
        sandbox,
        userId: ctx.userId,
        sessionId: ctx.sessionId,
        runId: ctx.runId,
        emitEvent,
        // additive fields (ruling R2)
        callKey: ctx.callKey,
        signal: ctx.signal,
        mode: ctx.mode,
        planMode: ctx.planMode,
      };
      const res: ToolResult = await tool.execute(args, bridged);
      return { content: res.content, isError: res.isError }; // artifacts stay undefined
    },
  };
}

export function adaptAgentTools(
  tools: readonly AgentTool[],
  deps: AgentToolAdapterDeps,
): Tool[] {
  return tools.map((t) => adaptAgentTool(t, deps));
}
