// ── Capability inference (cloud port of lib/core/plugin_permissions.dart's
// inferRequestedCapabilities — P20 single source of truth) ──────────────────
//
// The minimum capability set derived from what a manifest actually declares —
// never a blanket grant. `workspaceWrite` (and, historically, the device-era
// sessionRead/sessionWrite/deviceControl that D5 removed) is NOT derivable
// from the contribution shape: hooks and MCP declarations say nothing about
// what a server's tools do to the workspace, so inferring it would
// over-grant. Explicitly declared capabilities are always retained.

import type {
  NormalizedPluginManifest,
  PluginCapability,
} from "./manifest.js";

/** The fixed capability vocabulary (spec §5.1, cloud/D5-reduced). */
export const PLUGIN_CAPABILITIES: readonly PluginCapability[] = [
  "workspaceRead",
  "workspaceWrite",
  "shellExecute",
  "networkConnect",
  "processSpawn",
  "environmentRead",
  "mcpRegister",
  "hooksObserve",
  "hooksBlock",
];

/**
 * Derive the minimum requested capability set from the normalized manifest:
 * any file contribution → workspaceRead; hooks → hooksObserve (+hooksBlock
 * when the hook may block, +shellExecute for command hooks); mcpServers →
 * mcpRegister (+processSpawn for stdio, +networkConnect for http/sse);
 * envNames → environmentRead. Declared capabilities are unioned in.
 */
export function inferRequestedCapabilities(
  m: NormalizedPluginManifest,
): Set<PluginCapability> {
  const caps = new Set<PluginCapability>(m.capabilities);
  if (
    m.commands.length > 0 ||
    m.skills.length > 0 ||
    m.agents.length > 0
  ) {
    caps.add("workspaceRead");
  }
  for (const h of m.hooks) {
    caps.add("hooksObserve");
    if (h.type === "command") caps.add("shellExecute");
    if (h.canBlock) caps.add("hooksBlock");
  }
  for (const s of m.mcpServers) {
    caps.add("mcpRegister");
    if (s.imported.transport === "stdio") caps.add("processSpawn");
    if (s.imported.transport === "http" || s.imported.transport === "sse") {
      caps.add("networkConnect");
    }
  }
  if (m.envNames.length > 0) caps.add("environmentRead");
  return caps;
}
