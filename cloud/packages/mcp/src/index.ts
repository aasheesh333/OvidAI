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
export * from "./configParse.js";
// P5 Task 8: P9-aligned envelope crypto shim (deleted once P9's @ovid/escrow
// lands and call sites swap imports — see crypto.ts header).
export * from "./crypto.js";
// P5 Task 9: MCP OAuth — RFC 9728/8414 discovery + DCR, server-side PKCE
// flow with the sealed token store (Task 15's gateway routes consume
// createOAuthFlow from this root; the exports map blocks deep imports).
export * from "./oauth/discovery.js";
export * from "./oauth/flow.js";
// P5 Task 10: worker-side system bus (the gateway hub's counterpart on the
// sys:{uid}:out / sys:{uid}:in channels; Task 15/16 consume it from this
// root — same barrel rule). UserSystemBus is declared ONCE, here (F9):
// Task 3's permissive forward-ref placeholder in transports/native.js is
// shadowed by this EXPLICIT re-export (explicit beats star — the same
// discipline as WorkspaceFiles above; the worker seam adapts the cast).
export {
  APPROVAL_TIMEOUT_MS,
  createRedisSystemBus,
  type SystemEventKind,
  type SystemResponse,
  type UserSystemBus,
} from "./systemBus.js";
