// ── Plugin manifest normalization (cloud port of lib/core/plugin_manifest.dart
// + plugin_adapters.dart, reduced to the P5 cloud surface) ───────────────────
//
// Every supported source format (Claude-Code bundle, Codex tree, bare
// native plugin.json) adapts into ONE NormalizedPluginManifest: canonical
// `publisher/name` identity, explicit capability requests, and
// version-independent canonical contribution ids. Secrets never live here:
// MCP env/header VALUES are never resolved (the worker environment is never
// consulted at adaptation time — `${VAR}` stays literal for the credential
// gate) and only env NAMES travel in envNames.
//
// D5 removed the device-era capabilities (sessionRead/sessionWrite/
// deviceControl): a declaration naming them is stripped with a warning.

import { createHash } from "node:crypto";
import { stat as statFile } from "node:fs/promises";
import { join } from "node:path";
import type { ImportedMcp } from "../configParse.js";
import { adaptClaudeCode } from "./adapters/claudeCode.js";
import { adaptCodex } from "./adapters/codex.js";
import {
  adaptStandardTree,
  authorPublisher,
  canonicalPluginId,
  capabilitiesFromDeclaration,
  readJsonMapResult,
} from "./adapters/shared.js";

// The complete raw→canonical hook-event resolver, ported from
// agent-core's module-private normalizeEvent/EVENT_ALIASES so the manifest
// layer, the canonical contribution ids and the P3 engine share ONE
// mapping. Exported from the package barrel for the registry→engine wiring
// (Task 14 / P3 seam).
export {
  CLOUD_HOOK_EVENTS,
  canonicalHookEvent,
  isCloudHookEvent,
} from "./adapters/shared.js";
export type { CloudHookEvent } from "./adapters/shared.js";

/** Fixed capability vocabulary (spec §5.1, cloud/D5-reduced). */
export type PluginCapability =
  | "workspaceRead"
  | "workspaceWrite"
  | "shellExecute"
  | "networkConnect"
  | "processSpawn"
  | "environmentRead"
  | "mcpRegister"
  | "hooksObserve"
  | "hooksBlock";

/** The source format a manifest was adapted from. */
export type PluginFormat = "claudeCode" | "codex" | "native";

/** A slash command contributed by a plugin (markdown under `commands/`). */
export interface PluginCommand {
  name: string;
  description?: string;
  /** Source-relative path, e.g. `commands/review.md`. */
  file: string;
}

/** A skill contributed by a plugin (a `SKILL.md` bundle under `skills/`). */
export interface PluginSkill {
  name: string;
  description?: string;
  file: string;
}

/** An agent/persona contributed by a plugin (markdown under `agents/`). */
export interface PluginAgent {
  name: string;
  description?: string;
  file: string;
}

/** One ordered hook entry (cloud model: command hooks only). */
export interface PluginHook {
  /** Event name as declared (e.g. `PreToolUse`, `SessionStart`). */
  event: string;
  type: "command";
  command: string;
  canBlock: boolean;
  /** Manifest-order index WITHIN the event (part of the canonical id). */
  ordinal: number;
}

/** An MCP server contributed by a plugin (`.mcp.json` / config.toml / inline). */
export interface PluginMcpServerContribution {
  name: string;
  imported: ImportedMcp;
}

/** The single normalized artifact every adapter emits. */
export interface NormalizedPluginManifest {
  /** Canonical `publisher/name` (lowercase, [a-z0-9-_.]+ segments). */
  pluginId: string;
  version: string;
  format: PluginFormat;
  commands: PluginCommand[];
  skills: PluginSkill[];
  agents: PluginAgent[];
  hooks: PluginHook[];
  mcpServers: PluginMcpServerContribution[];
  /** Declared + inferred capabilities (see inferRequestedCapabilities). */
  capabilities: PluginCapability[];
  /** Environment variable NAMES the plugin needs (values stay sealed). */
  envNames: string[];
  /** Advisory findings: stripped declarations, skipped malformed entries. */
  warnings: string[];
  /** Filled at adaptation from the inspected directory; re-pointed at the
   *  jail path at install time (Task 14). */
  rootPath: string;
}

/** The source tree does not yield a valid plugin identity. */
export class ManifestError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ManifestError";
  }
}

/**
 * Registry id scheme (spec §4.4): `plugin:<id>/command:<name>` |
 * `…/skill:<name>` | `…/agent:<name>` | `…/hook:<event>:<ordinal>` |
 * `…/mcp:<name>` | `…/setting:<key>`. Version-independent by design — a
 * reinstall/upgrade re-registers the same ids.
 */
export function canonicalContributionId(
  pluginId: string,
  kind: "command" | "skill" | "agent" | "hook" | "mcp" | "setting",
  name: string,
  ordinal?: number,
): string {
  return kind === "hook"
    ? `plugin:${pluginId}/hook:${name}:${ordinal ?? 0}`
    : `plugin:${pluginId}/${kind}:${name}`;
}

// ── manifest digest (§5.1 grant binding) ────────────────────────────────────

/**
 * Deterministic JSON: object keys sorted recursively; arrays keep their
 * order (set-like fields are pre-sorted by the projection), so the digest
 * is stable across rebuilds that assemble the same content differently.
 */
function canonicalJson(node: unknown): string {
  if (Array.isArray(node)) {
    return `[${node.map(canonicalJson).join(",")}]`;
  }
  if (node !== null && typeof node === "object") {
    const keys = Object.keys(node as Record<string, unknown>).sort();
    return `{${keys
      .map((k) => `${JSON.stringify(k)}:${canonicalJson((node as Record<string, unknown>)[k])}`)
      .join(",")}}`;
  }
  return JSON.stringify(node) ?? "null";
}

/**
 * The MCP contribution projection for the digest: everything enforcing
 * except env/header VALUES — those are credentials (source literals stay
 * `${VAR}`-shaped and are replaced by sealed user config at activation), so
 * only their NAMES are hashed.
 */
function projectMcp(c: PluginMcpServerContribution): unknown {
  return {
    name: c.name,
    transport: c.imported.transport,
    command: c.imported.command ?? null,
    args: c.imported.args ?? null,
    cwd: c.imported.cwd ?? null,
    url: c.imported.url ?? null,
    envNames: Object.keys(c.imported.env ?? {}).sort(),
    headerNames: Object.keys(c.imported.headers ?? {}).sort(),
    oauth: c.imported.oauth ?? null,
  };
}

/**
 * Digest schema version, folded into the hashed projection. Bump ONLY when
 * the projection itself changes shape — and before the first real grants
 * persist (now: v1), so a later projection change is detectable and
 * migrateable instead of silently invalidating every stored approval
 * (Dart kManifestDigestSchemaVersion parity).
 */
const DIGEST_SCHEMA_VERSION = 1;

/**
 * sha256 over the canonical JSON of contributions + capabilities + envNames.
 * rootPath and version are EXCLUDED (the digest binds to plugin CONTENT, not
 * to where it currently lives or which version tag it carries — a grant
 * saved before the staging→install rename stays effective afterwards), and
 * so are `warnings` (advisory, parser-volatile — hashing them re-digested
 * every installed plugin on a parser update, the Dart regression pinned in
 * test/plugin_digest_stability_test.dart).
 */
export function pluginManifestDigest(m: NormalizedPluginManifest): string {
  const projection = {
    digestSchemaVersion: DIGEST_SCHEMA_VERSION,
    pluginId: m.pluginId,
    commands: m.commands.map((c) => [c.name, c.description ?? null, c.file]),
    skills: m.skills.map((s) => [s.name, s.description ?? null, s.file]),
    agents: m.agents.map((a) => [a.name, a.description ?? null, a.file]),
    hooks: m.hooks.map((h) => [h.event, h.type, h.command, h.canBlock, h.ordinal]),
    mcpServers: m.mcpServers.map(projectMcp),
    capabilities: [...m.capabilities].sort(),
    envNames: [...m.envNames].sort(),
  };
  return `sha256:${createHash("sha256")
    .update(canonicalJson(projection), "utf8")
    .digest("hex")}`;
}

// ── native adapter (bare plugin.json) ───────────────────────────────────────

/**
 * Adapt a bare root `plugin.json` — the Ovid-native manifest: identity from
 * name+author, an optional explicit `capabilities` declaration, the standard
 * component scans and inline declarations (same tree conventions as the
 * Claude-Code format).
 */
async function adaptNative(root: string): Promise<NormalizedPluginManifest> {
  const warnings: string[] = [];
  const manifestResult = await readJsonMapResult(join(root, "plugin.json"));
  if (manifestResult.status === "corrupt") {
    warnings.push("plugin.json is not valid JSON.");
  }
  const manifest = manifestResult.status === "ok" ? manifestResult.map : {};

  const name = typeof manifest.name === "string" ? manifest.name.trim() : "";
  const publisher = authorPublisher(manifest.author);
  if (publisher === "" || name === "") {
    throw new ManifestError(
      "Invalid plugin identity: plugin.json declares no publisher " +
        "(missing or malformed author), so the canonical id \"publisher/name\" " +
        "has an empty segment.",
    );
  }

  const declared = capabilitiesFromDeclaration(manifest.capabilities, warnings);
  const tree = await adaptStandardTree(root, manifest, declared);

  return {
    pluginId: canonicalPluginId(publisher, name),
    version: typeof manifest.version === "string" ? manifest.version : "",
    format: "native",
    commands: tree.commands,
    skills: tree.skills,
    agents: tree.agents,
    hooks: tree.hooks,
    mcpServers: tree.mcpServers,
    capabilities: tree.capabilities,
    envNames: tree.envNames,
    warnings: [...warnings, ...tree.warnings],
    rootPath: root,
  };
}

// ── adapter dispatch (Dart PluginAdapterRegistry parity) ────────────────────

async function exists(p: string): Promise<boolean> {
  try {
    await statFile(p);
    return true;
  } catch {
    return false;
  }
}

/**
 * Adapt the plugin tree at `rootDir` into the one normalized manifest,
 * picking the adapter matching the tree's markers:
 *
 *  - `.claude-plugin/plugin.json` (or `marketplace.json`) → Claude-Code;
 *  - Codex markers (`config.toml`, `.codex-plugin/plugin.json`, `AGENTS.md`,
 *    `.agents/`) → Codex;
 *  - bare `plugin.json` → native;
 *  - anything else → the Claude-Code adapter, which fails loudly with a
 *    ManifestError for a tree with no publisher identity (Dart's fallback).
 *
 * A missing publisher identity (author) is a ManifestError — inspection
 * fails BEFORE activation, never a silent install.
 */
export async function adaptPlugin(rootDir: string): Promise<NormalizedPluginManifest> {
  if (
    (await exists(join(rootDir, ".claude-plugin", "plugin.json"))) ||
    (await exists(join(rootDir, ".claude-plugin", "marketplace.json")))
  ) {
    return adaptClaudeCode(rootDir);
  }
  if (
    (await exists(join(rootDir, "config.toml"))) ||
    (await exists(join(rootDir, ".codex-plugin", "plugin.json"))) ||
    (await exists(join(rootDir, "AGENTS.md"))) ||
    (await exists(join(rootDir, ".agents")))
  ) {
    return adaptCodex(rootDir);
  }
  if (await exists(join(rootDir, "plugin.json"))) {
    return adaptNative(rootDir);
  }
  return adaptClaudeCode(rootDir);
}
