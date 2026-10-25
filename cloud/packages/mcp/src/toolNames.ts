import { safeMcpServerName } from "@ovid/shared";

/**
 * Tool naming — canonical NFKC normalization followed by the existing Dart
 * `_safe` ASCII projection. The published name is the model-facing, stable
 * identifier (`mcp__<safe server>__<tool>`); the canonical id is the
 * provider-independent `mcp:<serverId>/<tool>`.
 */

/**
 * Canonical policy: NFKC before case folding, then Dart `_safe` sanitization.
 * Every run of characters outside `[a-z0-9_-]` collapses to one `_`;
 * leading/trailing `_` are trimmed. An all-unsafe name yields "".
 */
export function safeServerName(name: string): string {
  return safeMcpServerName(name);
}

/** The published (legacy) tool name: `mcp__<safe server>__<tool>`. */
export function toolNameFor(serverName: string, toolName: string): string {
  return `mcp__${safeServerName(serverName)}__${toolName}`;
}

/** The canonical tool id: `mcp:<serverId>/<tool>`. */
export function canonicalToolId(serverId: string, toolName: string): string {
  return `mcp:${serverId}/${toolName}`;
}
