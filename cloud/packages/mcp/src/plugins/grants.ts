// ── Capability grants (cloud port of lib/core/plugin_permissions.dart,
// §5.1 approval math — storage is Task 8's `pluginGrants` repo) ──────────────
//
// Grants are NEVER auto-approved: a plugin update whose manifest requests a
// capability the stored grant does not cover pauses activation until the
// delta is approved on the sheet. This module is the pure capability math;
// the manifest-digest binding (which exact manifest version was approved) is
// the installer's duty — Task 14 loads the stored grant BY digest, so a
// changed manifest never reaches these functions wearing an old grant.

import type { PluginCapability } from "./manifest.js";

/** The stored user approval the delta is computed against (null = never approved). */
export interface PluginGrantInput {
  capabilities: PluginCapability[];
  envNames: string[];
  manifestDigest: string;
  allowDependencyScripts: boolean;
}

/**
 * The NEW capabilities a manifest requests relative to a stored grant
 * (§5.1: "a later update requesting new capabilities pauses activation
 * until the delta is approved"). A null grant means everything is new
 * (first approval).
 */
export function capabilityDelta(
  requested: ReadonlySet<PluginCapability>,
  granted: PluginGrantInput | null,
): PluginCapability[] {
  if (granted === null) return [...requested];
  const approved = new Set(granted.capabilities);
  return [...requested].filter((c) => !approved.has(c));
}

/** True when the grant decides on every requested capability (delta empty). */
export function grantCovers(
  requested: ReadonlySet<PluginCapability>,
  granted: PluginGrantInput | null,
): boolean {
  return capabilityDelta(requested, granted).length === 0;
}

/**
 * One-line human copy per capability for the approval sheet (Dart
 * pluginCapabilityTitle parity, minus the device-era titles D5 removed).
 */
export const CAPABILITY_EXPLANATIONS: Record<PluginCapability, string> = {
  workspaceRead: "Read workspace files",
  workspaceWrite: "Change workspace files",
  shellExecute: "Run shell commands",
  networkConnect: "Connect to the internet",
  processSpawn: "Start background processes",
  environmentRead: "Read environment variable values",
  mcpRegister: "Add MCP servers",
  hooksObserve: "Watch agent activity",
  hooksBlock: "Block or change agent actions",
};
