// Public surface: the pieces Task 10's e2e composes (main.ts stays out — it is
// the process entry point, not a library module). The PKG placeholder from the
// repo scaffold is dropped: nothing ever imported it.
//
// P2 Task 12: the tools/ modules join the public surface — Task 14's e2e and
// P3 import createToolRegistry + the tool shapes from here (the roster seam).
export * from "./approvalBridge.js";
export * from "./accountSweep.js";
export * from "./fileService.js";
// P9 Task 9: the server-side key resolver (also consumed by the money e2e).
export * from "./keyResolver.js";
export * from "./liteLlm.js";
export * from "./mcpRuntime.js";
// mcpTools exports its own `ToolResult` (the canonical P5 seam with optional
// artifacts); the worker barrel already re-exports P2's `ToolResult` from
// tools/types.ts. Re-export the P5 one under an explicit alias instead of
// colliding on the star.
export {
  CATALOG_AGENT_TOOLS,
  createCatalogTools,
  createMcpToolProvider,
  parsePluginSource,
  type CatalogAgentToolDef,
  type CatalogToolDeps,
  type McpAgentTool,
  type McpToolContext,
  type McpToolProvider,
  type PluginInstallQueue,
  type ToolResult as McpToolResult,
} from "./mcpTools.js";
export * from "./notify.js";
export * from "./pluginInstallProcessor.js";
export * from "./ptyBridge.js";
export * from "./runProcessor.js";
export * from "./sandboxAdapter.js";
export * from "./sandboxSeam.js";
export * from "./scheduleTools.js";
export * from "./schedulerMirror.js";
export * from "./schedulerSettle.js";
export * from "./schedulerTick.js";
export * from "./staleRuns.js";
export * from "./studioGit.js";
export * from "./studioGitQueue.js";
export * from "./subagentLogSink.js";
export * from "./tools/agentToolAdapter.js";
export * from "./tools/confinement.js";
export * from "./tools/fileTools.js";
export * from "./tools/registry.js";
export * from "./tools/shellTool.js";
export * from "./tools/systemPrompt.js";
export * from "./tools/types.js";
export * from "./unattended.js";
