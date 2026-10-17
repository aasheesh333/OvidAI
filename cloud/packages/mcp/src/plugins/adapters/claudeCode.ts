// ── Claude-Code plugin adapter (cloud port of Dart ClaudePluginAdapter) ─────
//
// Adapts a `.claude-plugin/plugin.json` tree: identity from name+author (a
// string or `{name, …}` object — anything else is a missing publisher →
// ManifestError), contributions from `commands/`, `skills/`, `agents/`,
// `hooks/hooks.json`, `.mcp.json` and the inline plugin.json declarations.
// Read-only: source files are parsed, never rewritten.

import { join } from "node:path";
import { ManifestError } from "../manifest.js";
import type { NormalizedPluginManifest } from "../manifest.js";
import {
  adaptStandardTree,
  authorPublisher,
  canonicalPluginId,
  capabilitiesFromDeclaration,
  readJsonMap,
} from "./shared.js";

export async function adaptClaudeCode(root: string): Promise<NormalizedPluginManifest> {
  const manifest = (await readJsonMap(join(root, ".claude-plugin", "plugin.json"))) ?? {};

  const name = typeof manifest.name === "string" ? manifest.name.trim() : "";
  const publisher = authorPublisher(manifest.author);
  if (publisher === "" || name === "") {
    throw new ManifestError(
      "Invalid plugin identity: .claude-plugin/plugin.json declares no publisher " +
        "(missing or malformed author), so the canonical id \"publisher/name\" " +
        "has an empty segment.",
    );
  }

  const declWarnings: string[] = [];
  const declared = capabilitiesFromDeclaration(manifest.capabilities, declWarnings);
  const tree = await adaptStandardTree(root, manifest, declared);

  return {
    pluginId: canonicalPluginId(publisher, name),
    version: typeof manifest.version === "string" ? manifest.version : "",
    format: "claudeCode",
    commands: tree.commands,
    skills: tree.skills,
    agents: tree.agents,
    hooks: tree.hooks,
    mcpServers: tree.mcpServers,
    capabilities: tree.capabilities,
    envNames: tree.envNames,
    warnings: [...declWarnings, ...tree.warnings],
    rootPath: root,
  };
}
