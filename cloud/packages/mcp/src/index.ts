// The @ovid/mcp barrel. Cross-package consumers import ONLY from "." (the
// exports map exposes the package root alone) — deep-importing any module
// below fails with ERR_PACKAGE_PATH_NOT_EXPORTED, so every public surface
// must be re-exported here.
export * from "./jsonrpc.js";
export * from "./transport.js";
export * from "./client.js";
export * from "./backoff.js";
export * from "./ssrf.js";
export * from "./transports/http.js"; // incl. McpAuthRequiredError / McpSessionExpiredError
export * from "./transports/sse.js";
export * from "./transports/stdio.js";
export * from "./transports/native.js";
// Native in-process handlers (Task 5). WorkspaceFiles is re-exported
// explicitly (explicit beats star): transports/native.js still star-exports
// the permissive placeholder — R6: the worker seam (Task 16) adapts
// @ovid/sandbox to the real surface defined in workspace.ts.
export { WORKSPACE_ROOT, resolveWorkspacePath } from "./workspace.js";
export type { WorkspaceEntry, WorkspaceFiles } from "./workspace.js";
export * from "./native/github.js";
export * from "./native/filesystem.js";
export * from "./native/fetch.js";
export * from "./native/memory.js";
