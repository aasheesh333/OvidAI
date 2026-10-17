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
