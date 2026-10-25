/**
 * Canonical connection/tool-name normalization shared by DB, gateway, and MCP.
 * NFKC is applied before case folding; compatibility and canonical equivalents
 * therefore have one identity. Diacritics are not folded into different letters.
 */
export function normalizeMcpConnectionName(name: string): string {
  return name.normalize("NFKC").trim().toLowerCase().normalize("NFKC");
}

/** Model-facing server namespace: NFKC, lowercase, then existing safe-character rules. */
export function safeMcpServerName(name: string): string {
  return normalizeMcpConnectionName(name)
    .replace(/[^a-z0-9_-]+/g, "_")
    .replace(/^_+|_+$/g, "");
}
