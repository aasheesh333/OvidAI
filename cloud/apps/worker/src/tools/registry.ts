import { createEditFileTool, createGlobFilesTool, createGrepFilesTool, createReadFileTool, createWriteFileTool } from "./fileTools.js";
import { createRunShellTool } from "./shellTool.js";
import type { AgentTool, ModelToolSpec } from "./types.js";

/**
 * The v1 tool registry (plan Task 12) — THE P3 ROSTER SEAM. P3 extends the
 * roster (and later swaps the loop's engine mode); it imports these shapes
 * verbatim. specs() is sorted by name so the tool block in every model request
 * is byte-stable across runs (prompt-cache-stable prefix, spec §6.1).
 */

export interface ToolRegistry {
  readonly tools: AgentTool[];
  get(name: string): AgentTool | undefined;
  specs(): ModelToolSpec[];
}

/** v1 roster, EXACTLY: run_shell + the five host-side file tools. */
export function createToolRegistry(): ToolRegistry {
  const tools: AgentTool[] = [
    createRunShellTool(),
    createReadFileTool(),
    createWriteFileTool(),
    createEditFileTool(),
    createGlobFilesTool(),
    createGrepFilesTool(),
  ];
  const byName = new Map(tools.map((t) => [t.name, t]));
  return {
    tools,
    get: (name) => byName.get(name),
    specs: () =>
      [...tools]
        .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
        .map((t) => ({
          type: "function" as const,
          function: { name: t.name, description: t.description, parameters: t.parameters },
        })),
  };
}
