/**
 * Tool naming — Dart parity with `McpConnectedTool` (`_safe`, `legacyToolName`,
 * `canonicalId`). The published name is the model-facing, stable identifier
 * (`mcp__<safe server>__<tool>`); the canonical id is the provider-independent
 * `mcp:<serverId>/<tool>`.
 */

/**
 * Dart `_safe`: lowercase; every run of characters outside `[a-z0-9_-]`
 * collapses to one `_`; leading/trailing `_` are trimmed. An all-unsafe name
 * yields "" (Dart does the same — callers publish `mcp____<tool>` rather than
 * inventing an id).
 */
export function safeServerName(name: string): string {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, "_")
    .replace(/^_+|_+$/g, "");
}

/** The published (legacy) tool name: `mcp__<safe server>__<tool>`. */
export function toolNameFor(serverName: string, toolName: string): string {
  return `mcp__${safeServerName(serverName)}__${toolName}`;
}

/** The canonical tool id: `mcp:<serverId>/<tool>`. */
export function canonicalToolId(serverId: string, toolName: string): string {
  return `mcp:${serverId}/${toolName}`;
}
