// ── Codex plugin adapter (cloud port of Dart CodexPluginAdapter) ────────────
//
// Adapts a Codex-shaped tree: `config.toml` (root-table name/publisher/
// version scalars, `[mcp_servers.*]`, `[environment]`, inline
// `[[hooks.<Event>]]` tables) plus `.codex-plugin/plugin.json` when present
// (identity, `skills` pointer, `hooks` map). Stock configs declaring no
// name/publisher derive a stable identity from the directory name instead
// of failing.

import { readFile, stat } from "node:fs/promises";
import { basename, join, resolve } from "node:path";
import { parseMcpConfig } from "../../configParse.js";
import { inferRequestedCapabilities } from "../capabilities.js";
import type { NormalizedPluginManifest } from "../manifest.js";
import {
  authorPublisher,
  canonicalPluginId,
  capabilitiesFromDeclaration,
  cleanPointer,
  dedupeByName,
  isRecord,
  mcpFromFileContent,
  parseCodexInlineHooks,
  parseHooksEventMap,
  readJsonMap,
  scanMarkdown,
  scanSkills,
  slug,
} from "./shared.js";
import type {
  PluginAgent,
  PluginCommand,
  PluginHook,
  PluginMcpServerContribution,
  PluginSkill,
} from "../manifest.js";

/** Strip surrounding TOML quotes from a scalar value. */
function unquoteToml(v: string): string {
  let s = v.trim();
  if (s.length >= 2) {
    const f = s[0]!;
    const l = s[s.length - 1]!;
    if ((f === '"' && l === '"') || (f === "'" && l === "'")) {
      s = s.slice(1, -1);
    } else if (f === '"' || f === "'") {
      s = s.slice(1);
    }
  }
  return s;
}

/** A root-table scalar from config.toml (only the root table may name the plugin). */
function tomlScalarAt(rootConfig: string, key: string): string {
  const m = new RegExp(`^\\s*${key}\\s*=\\s*(.+)$`, "m").exec(rootConfig);
  return m === null ? "" : unquoteToml(m[1]!.trim());
}

async function dirExists(p: string): Promise<boolean> {
  try {
    return (await stat(p)).isDirectory();
  } catch {
    return false;
  }
}

export async function adaptCodex(root: string): Promise<NormalizedPluginManifest> {
  const warnings: string[] = [];
  const commands: PluginCommand[] = [];
  const skills: PluginSkill[] = [];
  const agents: PluginAgent[] = [];
  const hooks: PluginHook[] = [];
  const mcpServers: PluginMcpServerContribution[] = [];
  const envNames = new Set<string>();

  const configFile = join(root, "config.toml");
  let config = "";
  try {
    config = await readFile(configFile, "utf8");
  } catch {
    config = "";
  }
  // Only the root TOML table may name the plugin: a `name` nested inside an
  // `[mcp_servers.*]` (or any other) table must not spoof the identity.
  const rootConfig = config.split(/^\[/m)[0] ?? "";

  // .codex-plugin/plugin.json: read BEFORE building the identity so a
  // manifest-declared name/publisher wins over the config.toml fallback
  // when config.toml names nothing.
  const codexManifest =
    (await readJsonMap(join(root, ".codex-plugin", "plugin.json"))) ?? {};
  const manifestName =
    typeof codexManifest.name === "string" ? codexManifest.name.trim() : "";
  const manifestPublisher = authorPublisher(codexManifest.author);

  // Stock Codex configs declare no name/publisher; derive a stable,
  // slug-safe identity from the source directory instead of failing.
  const sourceId = slug(basename(resolve(root)));
  const fallbackName = sourceId === "" ? "plugin" : sourceId;
  const explicitName = tomlScalarAt(rootConfig, "name");
  const explicitPublisher = tomlScalarAt(rootConfig, "publisher");
  const name =
    explicitName !== ""
      ? explicitName
      : manifestName !== ""
        ? manifestName
        : fallbackName;
  const publisher =
    explicitPublisher !== ""
      ? explicitPublisher
      : manifestPublisher !== ""
        ? manifestPublisher
        : "codex";

  // Contributions — the .agents layout, the plain top-level layout (CODEX
  // PARITY 2026-09-24: a Codex tree using the Claude layout must contribute
  // the same as an identical Claude tree), then the manifest `skills`
  // pointer (additively; an already-scanned directory is not scanned twice).
  const scannedSkillDirs = new Set<string>();

  const scanSkillsDir = async (dirRel: string): Promise<void> => {
    const abs = join(root, dirRel);
    const key = resolve(abs);
    if (scannedSkillDirs.has(key)) return;
    scannedSkillDirs.add(key);
    skills.push(...(await scanSkills(root, abs)));
  };

  if (await dirExists(join(root, ".agents", "skills"))) {
    await scanSkillsDir(".agents/skills");
  }
  if (await dirExists(join(root, ".agents", "personas"))) {
    const r = await scanMarkdown(root, join(root, ".agents", "personas"), true);
    agents.push(...r.agents);
  }
  {
    const r = await scanMarkdown(root, join(root, "commands"), false);
    commands.push(...r.commands);
  }
  {
    const r = await scanMarkdown(root, join(root, "agents"), true);
    agents.push(...r.agents);
  }
  await scanSkillsDir("skills");

  const skillsPointer = codexManifest.skills;
  if (typeof skillsPointer === "string" && skillsPointer.trim() !== "") {
    const cleaned = cleanPointer(skillsPointer);
    if (cleaned !== null) await scanSkillsDir(cleaned);
  }

  // Lifecycle hooks: inline [[hooks.<Event>]] tables, plugin-bundled
  // hooks/hooks.json, and the manifest-declared `hooks` map — all
  // normalized through the shared event-map parser.
  hooks.push(...parseHooksEventMap(parseCodexInlineHooks(config), warnings));
  const hooksJson = await readJsonMap(join(root, "hooks", "hooks.json"));
  if (hooksJson !== null) {
    hooks.push(...parseHooksEventMap(hooksJson, warnings));
  }
  const manifestHooks = codexManifest.hooks;
  if (isRecord(manifestHooks) && Object.keys(manifestHooks).length > 0) {
    hooks.push(...parseHooksEventMap({ hooks: manifestHooks }, warnings));
  }

  // MCP servers from config.toml (worker env never consulted — ${VAR}
  // credentials stay literal for the credential gate).
  if (config !== "") {
    try {
      const r = mcpFromFileContent(config, "config.toml");
      mcpServers.push(...r.servers);
      for (const k of r.envNames) envNames.add(k);
    } catch {
      warnings.push("config.toml MCP servers could not be parsed and were skipped.");
    }
    // `[environment]` names are read by the plugin at runtime; values are
    // secrets and are never captured.
    let inEnvironment = false;
    for (const line of config.split("\n")) {
      const trimmed = line.trim();
      if (trimmed.startsWith("[")) {
        inEnvironment = trimmed === "[environment]";
        continue;
      }
      if (inEnvironment) {
        const m = /^([A-Za-z0-9_]+)\s*=/.exec(trimmed);
        if (m !== null) envNames.add(m[1]!);
      }
    }
  }

  const versionScalar = tomlScalarAt(rootConfig, "version");
  const manifestVersion = codexManifest.version;
  const version =
    versionScalar !== ""
      ? versionScalar
      : typeof manifestVersion === "string"
        ? manifestVersion
        : typeof manifestVersion === "number"
          ? String(manifestVersion)
          : "";

  const declared = capabilitiesFromDeclaration(codexManifest.capabilities, warnings);
  const base: NormalizedPluginManifest = {
    pluginId: canonicalPluginId(publisher, name),
    version,
    format: "codex",
    // Dedupe by name (first declaration wins): contributions from the
    // `.agents` layout, the top-level parity layout and the manifest
    // `skills` pointer can overlap, and two contributions sharing one
    // canonical id would make register() throw on reinstall.
    commands: dedupeByName(commands),
    skills: dedupeByName(skills),
    agents: dedupeByName(agents),
    hooks,
    mcpServers: dedupeByName(mcpServers),
    capabilities: declared,
    envNames: [...envNames],
    warnings,
    rootPath: root,
  };
  return {
    ...base,
    capabilities: [
      ...new Set([...declared, ...inferRequestedCapabilities(base)]),
    ],
  };
}
