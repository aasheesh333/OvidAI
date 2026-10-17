// ── Shared adapter internals (cloud port of lib/core/plugin_adapters.dart) ──
//
// Field-by-field port of the Dart scanning/parsing helpers the Claude-Code,
// Codex and native adapters share: depth-bounded symlink-refusing directory
// scans, markdown frontmatter, the hooks.json event-map normalization, the
// Codex inline `[[hooks.<Event>]]` TOML tables, sanitized component
// pointers, and capability-declaration stripping. NOT exported from the
// package barrel — adaptPlugin (manifest.ts) is the only entry point.

import { readdir, readFile, stat } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { parseMcpConfig } from "../../configParse.js";
import { inferRequestedCapabilities, PLUGIN_CAPABILITIES } from "../capabilities.js";
import type {
  NormalizedPluginManifest,
  PluginAgent,
  PluginCapability,
  PluginCommand,
  PluginHook,
  PluginMcpServerContribution,
  PluginSkill,
} from "../manifest.js";

/** Dart parity (skills.dart kBundleScanMaxDepth). */
export const SCAN_MAX_DEPTH = 12;

// ── identity / naming ───────────────────────────────────────────────────────

/**
 * Slug for contribution names and id segments: lowercase, characters outside
 * [a-z0-9._-] collapsed to `-`, edge dashes stripped — canonical ids stay
 * stable and shell-safe (spec §4.4).
 */
export function slug(value: string): string {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

/** Canonical `publisher/name` identity from the two declared parts. */
export function canonicalPluginId(publisher: string, name: string): string {
  return `${slug(publisher)}/${slug(name)}`;
}

/**
 * The publisher from a manifest `author` field: a string or a
 * `{name, email, …}` object. Anything else (list, number, boolean) yields ""
 * so a malformed author degrades to a missing-publisher ManifestError
 * instead of a cast throw (Dart parity).
 */
export function authorPublisher(author: unknown): string {
  if (typeof author === "string") return author.trim();
  if (isRecord(author) && typeof author.name === "string") {
    return author.name.trim();
  }
  return "";
}

// ── json / frontmatter ──────────────────────────────────────────────────────

export function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/** Read-a-JSON-object-file outcome: missing, parsed, or present-but-corrupt. */
export type JsonMapResult =
  | { status: "missing" }
  | { status: "ok"; map: Record<string, unknown> }
  | { status: "corrupt" };

/**
 * Read a JSON object file, distinguishing MISSING from CORRUPT: a broken
 * hooks.json or plugin manifest must be loud (a warning the installer
 * surfaces), never a silently-disabled contribution set.
 */
export async function readJsonMapResult(file: string): Promise<JsonMapResult> {
  let text: string;
  try {
    text = await readFile(file, "utf8");
  } catch {
    return { status: "missing" };
  }
  try {
    const decoded: unknown = JSON.parse(text);
    if (!isRecord(decoded)) return { status: "corrupt" };
    return { status: "ok", map: decoded };
  } catch {
    return { status: "corrupt" };
  }
}

/**
 * Back-compat shim: the map, or null when missing OR corrupt (callers that
 * need the distinction use readJsonMapResult and push their own warning).
 */
export async function readJsonMap(
  file: string,
): Promise<Record<string, unknown> | null> {
  const r = await readJsonMapResult(file);
  return r.status === "ok" ? r.map : null;
}

/**
 * Minimal YAML frontmatter for markdown contributions: scalar `key: value`
 * lines between leading `---` fences. Only the strings the normalized
 * models consume (name, description) are read; everything else is ignored.
 */
export function parseFrontmatter(text: string): Record<string, string> {
  const lines = text.split(/\r?\n/);
  if (lines[0]?.trim() !== "---") return {};
  const out: Record<string, string> = {};
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i]!;
    if (line.trim() === "---") break;
    const m = /^([A-Za-z0-9_-]+)\s*:\s*(.*)$/.exec(line);
    if (m) {
      let v = m[2]!.trim();
      if (
        v.length >= 2 &&
        ((v.startsWith('"') && v.endsWith('"')) ||
          (v.startsWith("'") && v.endsWith("'")))
      ) {
        v = v.slice(1, -1);
      }
      out[m[1]!] = v;
    }
  }
  return out;
}

// ── directory scans ─────────────────────────────────────────────────────────

interface FoundFile {
  abs: string;
  rel: string; // root-relative, forward slashes
}

/**
 * Recursively collect files matching `test` under `dir`, depth-bounded and
 * refusing symlinks so an untrusted tree cannot escape itself (Dart
 * `_filesUnder` parity, minus the redundant realpath re-check — without
 * symlinks there is no traversal). Sorted by path for deterministic order.
 */
async function filesUnder(
  root: string,
  dir: string,
  test: (name: string) => boolean,
): Promise<FoundFile[]> {
  const out: FoundFile[] = [];

  async function walk(current: string, depth: number): Promise<void> {
    if (depth > SCAN_MAX_DEPTH) return;
    let entries;
    try {
      entries = await readdir(current, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      if (e.isSymbolicLink()) continue;
      const abs = join(current, e.name);
      if (e.isDirectory()) {
        await walk(abs, depth + 1);
      } else if (e.isFile() && test(e.name)) {
        out.push({ abs, rel: relativeTo(root, abs) });
      }
    }
  }

  try {
    const s = await stat(dir);
    if (!s.isDirectory()) return out;
  } catch {
    return out; // missing component directory: skipped silently (Dart parity)
  }
  await walk(dir, 0);
  out.sort((a, b) => (a.rel < b.rel ? -1 : a.rel > b.rel ? 1 : 0));
  return out;
}

/** Root-relative path with forward slashes (manifest `file` fields). */
function relativeTo(root: string, abs: string): string {
  const base = resolve(root);
  const full = resolve(abs);
  if (full === base) return "";
  if (full.startsWith(base + "/") || full.startsWith(base + "\\")) {
    return full.slice(base.length + 1).replaceAll("\\", "/");
  }
  return basename(full);
}

/**
 * The Claude-Code-namespaced name for a command/agent markdown under its
 * scan root: sub-directory segments joined with the leaf (frontmatter
 * `name` when present, else the basename sans `.md`), so
 * `commands/git/commit.md` → `git/commit` (slugged to `git-commit`).
 */
function namespacedName(scanDir: string, file: FoundFile, frontmatterName: string): string {
  const dirPath = resolve(scanDir).replaceAll("\\", "/");
  const filePath = resolve(file.abs).replaceAll("\\", "/");
  let relToDir = filePath.startsWith(dirPath + "/")
    ? filePath.slice(dirPath.length + 1)
    : basename(filePath);
  const slashIdx = relToDir.lastIndexOf("/");
  const subdirs = slashIdx >= 0 ? relToDir.slice(0, slashIdx) : "";
  const hasExplicitName = frontmatterName.trim() !== "";
  const leaf = hasExplicitName
    ? frontmatterName
    : basename(filePath).replace(/\.md$/, "");
  return subdirs === "" ? leaf : `${subdirs}/${leaf}`;
}

/** Scan markdown files under `<dir>` into command or agent contributions. */
export async function scanMarkdown(
  root: string,
  dir: string,
  asAgent: boolean,
): Promise<{ commands: PluginCommand[]; agents: PluginAgent[] }> {
  const commands: PluginCommand[] = [];
  const agents: PluginAgent[] = [];
  for (const f of await filesUnder(root, dir, (n) => n.endsWith(".md"))) {
    const fm = parseFrontmatter(await readFile(f.abs, "utf8"));
    const name = slug(namespacedName(dir, f, fm.name ?? ""));
    if (name === "") continue;
    const entry = {
      name,
      ...(fm.description !== undefined && fm.description !== ""
        ? { description: fm.description }
        : {}),
      file: f.rel,
    };
    if (asAgent) agents.push(entry);
    else commands.push(entry);
  }
  return { commands, agents };
}

/** Scan `<dir>` for `SKILL.md` bundles (name from frontmatter or the directory). */
export async function scanSkills(
  root: string,
  dir: string,
): Promise<PluginSkill[]> {
  const skills: PluginSkill[] = [];
  for (const f of await filesUnder(root, dir, (n) => n === "SKILL.md")) {
    const fm = parseFrontmatter(await readFile(f.abs, "utf8"));
    const name = slug(fm.name !== undefined && fm.name !== "" ? fm.name : basename(dirname(f.abs)));
    if (name === "") continue;
    skills.push({
      name,
      ...(fm.description !== undefined && fm.description !== ""
        ? { description: fm.description }
        : {}),
      file: f.rel,
    });
  }
  return skills;
}

// ── hooks (hooks.json event-map normalization — Dart _addHooks parity) ──────

// ── hook event normalization (ported from agent-core/src/hooks.ts so the
// manifest layer and the P3 engine share ONE raw→canonical mapping) ─────────

/** The canonical hook events the P3 cloud engine dispatches on. */
export const CLOUD_HOOK_EVENTS = [
  "session_start",
  "user_prompt_submit",
  "pre_request",
  "post_request",
  "pre_tool",
  "post_tool",
  "stop",
  "subagent_stop",
  "notification",
] as const;

export type CloudHookEvent = (typeof CLOUD_HOOK_EVENTS)[number];

const CLOUD_EVENT_SET: ReadonlySet<string> = new Set(CLOUD_HOOK_EVENTS);

/**
 * Dart `canonicalHookEvent` aliases accepted at the source layer, ported
 * verbatim from agent-core's EVENT_ALIASES plus the Dart-canonical events
 * the cloud engine cut (session_end, pre_compact, post_compact,
 * subagent_start, permission_request) — those still RESOLVE so the adapter
 * can skip them with a specific loud warning instead of a generic one.
 */
const EVENT_ALIASES: Readonly<Record<string, string>> = {
  // Legacy Ovid aliases.
  on_session_start: "session_start",
  on_session_end: "session_end",
  on_pre_request: "pre_request",
  on_pre_tool: "pre_tool",
  on_post_tool: "post_tool",
  on_turn_start: "user_prompt_submit",
  on_turn_end: "stop",
  // [CC] PascalCase names.
  SessionStart: "session_start",
  SessionEnd: "session_end",
  UserPromptSubmit: "user_prompt_submit",
  PreToolUse: "pre_tool",
  PostToolUse: "post_tool",
  PostToolUseFailure: "post_tool",
  Stop: "stop",
  SubagentStart: "subagent_start",
  SubagentStop: "subagent_stop",
  Notification: "notification",
  PreCompact: "pre_compact",
  PostCompact: "post_compact",
  PermissionRequest: "permission_request",
  // Dart canonical spellings for events the cloud renamed or kept.
  subagent_end: "subagent_stop",
  permission_request: "permission_request",
};

const KNOWN_EVENTS: ReadonlySet<string> = new Set([
  ...CLOUD_EVENT_SET,
  "session_end",
  "pre_compact",
  "post_compact",
  "subagent_start",
  "permission_request",
]);

/**
 * The complete raw→canonical hook-event resolver (the manifest layer's
 * public port of agent-core's module-private normalizeEvent). Returns the
 * canonical event name, or null when the name maps to nothing any Ovid
 * runtime can fire. Canonical ids and the P3 engine both key on the
 * CANONICAL form, so a respelled declaration yields the same id.
 */
export function canonicalHookEvent(raw: string): string | null {
  const key = raw.trim();
  if (key === "") return null;
  if (CLOUD_EVENT_SET.has(key)) return key;
  if (KNOWN_EVENTS.has(key)) return key;
  return EVENT_ALIASES[key] ?? null;
}

/** True when the P3 cloud engine dispatches on this canonical event. */
export function isCloudHookEvent(event: string): event is CloudHookEvent {
  return CLOUD_EVENT_SET.has(event);
}

/**
 * Events whose hooks may deny an action. The cloud engine cut
 * permission_request, so `pre_tool` is the ONLY blocking gate — a hook
 * deny still wins there (agent-core hooks.ts header).
 */
export function hookCanBlock(canonicalEvent: string): boolean {
  return canonicalEvent === "pre_tool";
}

/**
 * Normalize a `{"hooks": {Event: …}}` map into ordered PluginHooks.
 * Event names are resolved to their CANONICAL form (canonicalHookEvent), so
 * canonical ids and the P3 engine agree regardless of the declared
 * spelling. Handles the string shorthand, a single matcher-object (wrapped,
 * not dropped) and matcher-group arrays. Ordinals are the manifest-order
 * index WITHIN the canonical event. Only `command` hooks survive into the
 * cloud model; prompt/agent hooks, unsupported events and malformed
 * declarations are skipped with a warning.
 */
export function parseHooksEventMap(
  hooksJson: Record<string, unknown>,
  warnings: string[],
): PluginHook[] {
  const hooks: PluginHook[] = [];
  const ordinals = new Map<string, number>();
  const events = hooksJson.hooks;
  if (!isRecord(events)) return hooks;

  const add = (event: string, command: string): void => {
    const ordinal = ordinals.get(event) ?? 0;
    ordinals.set(event, ordinal + 1);
    hooks.push({
      event,
      type: "command",
      command,
      canBlock: hookCanBlock(event),
      ordinal,
    });
  };

  for (const [rawEvent, value] of Object.entries(events)) {
    const canonical = canonicalHookEvent(rawEvent);
    if (canonical === null) {
      warnings.push(
        `Hook event "${rawEvent}" is not supported by Ovid and was skipped.`,
      );
      continue;
    }
    if (canonical === "permission_request") {
      // The P3 cloud engine cut permission_request (agent-core hooks.ts):
      // a declaration here would be approved as blocking and then silently
      // never fire. The pre_tool gate is the supported alternative — a
      // hook deny still wins there.
      warnings.push(
        `Hook event "${rawEvent}" (permission_request) is not fired by the ` +
          "cloud engine and was skipped; declare a pre_tool hook instead — " +
          "a hook deny still wins at the pre_tool gate.",
      );
      continue;
    }
    if (!isCloudHookEvent(canonical)) {
      warnings.push(
        `Hook event "${rawEvent}" (${canonical}) is not fired by the cloud ` +
          "engine and was skipped.",
      );
      continue;
    }
    // Shorthand: "event": "command string".
    if (typeof value === "string") {
      if (value.trim() !== "") add(canonical, value);
      continue;
    }
    // A single matcher-object is wrapped rather than dropped.
    const groups: unknown[] = isRecord(value) ? [value] : Array.isArray(value) ? value : [];
    if (groups.length === 0 && !isRecord(value) && !Array.isArray(value)) {
      warnings.push(`Hook event "${rawEvent}" has an unsupported shape and was skipped.`);
      continue;
    }
    for (const group of groups) {
      if (!isRecord(group)) continue;
      const rawMatcher = group.matcher;
      if (rawMatcher !== undefined && typeof rawMatcher !== "string") {
        warnings.push(`Hook matcher for "${rawEvent}" must be a string; group skipped.`);
        continue;
      }
      const inner = group.hooks;
      if (!Array.isArray(inner)) continue;
      for (const hook of inner) {
        if (!isRecord(hook)) continue;
        const type = hook.type;
        const command = hook.command;
        const prompt = hook.prompt;
        const timeout = hook.timeout;
        if (
          (type !== undefined && typeof type !== "string") ||
          (command !== undefined && typeof command !== "string") ||
          (prompt !== undefined && typeof prompt !== "string") ||
          (timeout !== undefined && typeof timeout !== "number")
        ) {
          warnings.push(
            `Malformed hook declaration skipped; type/payload must be strings and timeout numeric (${rawEvent}).`,
          );
          continue;
        }
        const explicitType = type?.trim();
        const hasCommand = typeof command === "string" && command.trim() !== "";
        const hasPrompt = typeof prompt === "string" && prompt.trim() !== "";
        // An explicit type wins; a prompt payload is never coerced into a
        // shell command (Dart parity).
        const resolved =
          explicitType !== undefined && explicitType !== ""
            ? explicitType
            : hasCommand
              ? "command"
              : hasPrompt
                ? "prompt"
                : "command";
        if (resolved !== "command") {
          if (resolved === "prompt" || resolved === "agent") {
            warnings.push(
              `Only command hooks can execute; ${resolved} hook on "${rawEvent}" was skipped.`,
            );
          } else {
            warnings.push(
              `Unsupported hook type "${resolved}" on "${rawEvent}" was skipped.`,
            );
          }
          continue;
        }
        const payload = command ?? "";
        if (payload.trim() === "") {
          warnings.push(`Hook on "${rawEvent}" has no payload and was skipped.`);
          continue;
        }
        add(canonical, payload);
      }
    }
  }
  return hooks;
}

// ── Codex inline hooks ([[hooks.<Event>]] TOML tables) ──────────────────────

/** Strip surrounding TOML quotes from a scalar value. */
export function unquoteToml(v: string): string {
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

function tomlScalar(value: string): unknown {
  const v = value.trim();
  if (v === "true") return true;
  if (v === "false") return false;
  const n = /^-?\d+$/.test(v) ? Number(v) : undefined;
  return n !== undefined && Number.isSafeInteger(n) ? n : unquoteToml(v);
}

/**
 * Parse Codex inline `[[hooks.<Event>]]` / `[[hooks.<Event>.hooks]]` tables
 * into the `{"hooks": {…}}` shape the shared event-map normalizer expects
 * (Dart _parseCodexInlineHooks parity: quoted and hyphenated event names,
 * comments, non-hook tables ending the group context).
 */
export function parseCodexInlineHooks(config: string): Record<string, unknown> {
  const handlerHeader =
    /^\[\[\s*hooks\s*\.\s*(?:"([^"]+)"|([A-Za-z0-9_-]+))\s*\.\s*hooks\s*\]\]$/;
  const eventHeader =
    /^\[\[\s*hooks\s*\.\s*(?:"([^"]+)"|([A-Za-z0-9_-]+))\s*\]\]$/;
  const assignment = /^([A-Za-z0-9_]+)\s*=\s*(.+)$/;
  const events = new Map<string, Record<string, unknown>[]>();
  let group: Record<string, unknown> | null = null;
  let handler: Record<string, unknown> | null = null;
  for (const rawLine of config.split("\n")) {
    const line = rawLine.trim();
    if (line === "" || line.startsWith("#")) continue;
    if (handlerHeader.test(line)) {
      if (group === null) continue;
      handler = {};
      (group.hooks as Record<string, unknown>[]).push(handler);
      continue;
    }
    const eventMatch = eventHeader.exec(line);
    if (eventMatch !== null) {
      const event = eventMatch[1] ?? eventMatch[2];
      if (event === undefined) continue;
      group = { hooks: [] };
      const list = events.get(event) ?? [];
      list.push(group);
      events.set(event, list);
      handler = null;
      continue;
    }
    if (line.startsWith("[")) {
      group = null;
      handler = null;
      continue;
    }
    const assignmentMatch = assignment.exec(line);
    const target = handler ?? group;
    if (assignmentMatch === null || target === null) continue;
    target[assignmentMatch[1]!] = tomlScalar(assignmentMatch[2]!);
  }
  if (events.size === 0) return {};
  const hooks: Record<string, unknown> = {};
  for (const [event, list] of events) {
    hooks[event] = list.map((g) => ({ ...g }));
  }
  return { hooks };
}

// ── MCP contributions ───────────────────────────────────────────────────────

/**
 * Parse a `mcpServers`-shaped map into ImportedMcp entries. The worker
 * environment is NEVER consulted: `env` is pinned empty so interpolated
 * `${VAR}` credentials stay literal for the credential gate (Task 14's
 * user_config substitution happens at activation, not adaptation).
 */
export async function mcpFromMap(
  servers: Record<string, unknown>,
  sourcePath: string,
  warnings: string[],
): Promise<{ servers: PluginMcpServerContribution[]; envNames: Set<string> }> {
  const out: PluginMcpServerContribution[] = [];
  const envNames = new Set<string>();
  for (const [name, v] of Object.entries(servers)) {
    if (!isRecord(v)) continue;
    // Per-entry parse (JSON round-trip through the one authoritative
    // parser) so one malformed entry degrades to a warning instead of
    // failing the whole plugin (Dart parity for inline declarations).
    try {
      const parsed = parseMcpConfig(
        JSON.stringify({ mcpServers: { [name]: v } }),
        { env: {} },
      );
      for (const imported of parsed) {
        out.push({ name: imported.name, imported });
        for (const k of Object.keys(imported.env ?? {})) envNames.add(k);
      }
    } catch {
      warnings.push(
        `Malformed MCP server declaration "${name}" in ${sourcePath} was skipped.`,
      );
    }
  }
  return { servers: out, envNames };
}

/** Parse an MCP config file (`.mcp.json` or a pointed-at file) by content. */
export function mcpFromFileContent(
  content: string,
  sourcePath: string,
): { servers: PluginMcpServerContribution[]; envNames: Set<string> } {
  const parsed = parseMcpConfig(content, { env: {} });
  const out = parsed.map((imported): PluginMcpServerContribution => ({
    name: imported.name,
    imported,
  }));
  const envNames = new Set<string>();
  for (const s of parsed) {
    for (const k of Object.keys(s.env ?? {})) envNames.add(k);
  }
  return { servers: out, envNames };
}

// ── sanitized component pointers (plugin.json inline declarations) ──────────

/**
 * Clean a manifest component pointer: strip a leading `./` and trailing `/`,
 * refuse `..` segments (no escaping the plugin tree) and absolute paths.
 * Returns null for anything unsafe or empty.
 */
export function cleanPointer(pointer: string): string | null {
  const cleaned = pointer
    .trim()
    .replace(/^\.?\//, "")
    .replace(/\/+$/, "");
  if (cleaned === "") return null;
  if (cleaned.split("/").includes("..")) return null;
  return cleaned;
}

/** A component pointer may be a string OR an array of strings. */
export function pointerList(decl: unknown): string[] {
  if (typeof decl === "string" && decl.trim() !== "") return [decl];
  if (Array.isArray(decl)) {
    return decl.filter((s): s is string => typeof s === "string" && s.trim() !== "");
  }
  return [];
}

// ── capability declarations ─────────────────────────────────────────────────

/** Device-era capabilities D5 removed from the cloud vocabulary. */
const REMOVED_CAPABILITIES = new Set([
  "sessionRead",
  "sessionWrite",
  "deviceControl",
]);

/**
 * Read a manifest `capabilities` declaration: known names are kept, the
 * device-era trio and unknown names are stripped with a warning (they can
 * never inflate an approval — Dart pluginCapabilitiesFromNames parity).
 */
export function capabilitiesFromDeclaration(
  raw: unknown,
  warnings: string[],
): PluginCapability[] {
  if (!Array.isArray(raw)) return [];
  const out: PluginCapability[] = [];
  const seen = new Set<string>();
  for (const e of raw) {
    if (typeof e !== "string") {
      warnings.push("Non-string capability declaration was skipped.");
      continue;
    }
    const name = e.trim();
    if (name === "" || seen.has(name)) continue;
    seen.add(name);
    if ((PLUGIN_CAPABILITIES as readonly string[]).includes(name)) {
      out.push(name as PluginCapability);
    } else if (REMOVED_CAPABILITIES.has(name)) {
      warnings.push(
        `Capability "${name}" is a device-era capability removed by D5 and was stripped.`,
      );
    } else {
      warnings.push(`Capability declaration "${name}" is not recognized and was stripped.`);
    }
  }
  return out;
}

// ── the shared standard-tree adaptation (CC + native formats) ───────────────

export interface StandardTreeResult {
  commands: PluginCommand[];
  skills: PluginSkill[];
  agents: PluginAgent[];
  hooks: PluginHook[];
  mcpServers: PluginMcpServerContribution[];
  capabilities: PluginCapability[];
  envNames: string[];
  warnings: string[];
}

/**
 * Adapt the standard plugin tree layout both the Claude-Code and native
 * formats share: `commands/`, `skills/`, `agents/` scans; `hooks/hooks.json`;
 * a root `.mcp.json`; and the inline `plugin.json` component declarations
 * (inline hooks map / file pointer, inline mcpServers map / `.mcp.json`
 * pointer, additive component-directory pointers).
 */
export async function adaptStandardTree(
  root: string,
  manifest: Record<string, unknown>,
  declaredCapabilities: PluginCapability[],
): Promise<StandardTreeResult> {
  const warnings: string[] = [];
  const commands: PluginCommand[] = [];
  const skills: PluginSkill[] = [];
  const agents: PluginAgent[] = [];
  const hooks: PluginHook[] = [];
  const mcpServers: PluginMcpServerContribution[] = [];
  const envNames = new Set<string>();

  const scannedDirs = new Set<string>();

  const scanInto = async (
    dirRel: string,
    kind: "commands" | "skills" | "agents",
  ): Promise<void> => {
    const abs = join(root, dirRel);
    const key = resolve(abs);
    if (scannedDirs.has(key)) return;
    scannedDirs.add(key);
    if (kind === "skills") {
      skills.push(...(await scanSkills(root, abs)));
    } else {
      const r = await scanMarkdown(root, abs, kind === "agents");
      commands.push(...r.commands);
      agents.push(...r.agents);
    }
  };

  await scanInto("commands", "commands");
  await scanInto("skills", "skills");
  await scanInto("agents", "agents");

  // hooks/hooks.json (the conventional location). A corrupt file is LOUD —
  // hooks silently disabled is exactly the failure mode the installer must
  // surface, not swallow.
  const hooksJsonResult = await readJsonMapResult(join(root, "hooks", "hooks.json"));
  if (hooksJsonResult.status === "corrupt") {
    warnings.push("hooks/hooks.json is not valid JSON — hooks were skipped.");
  } else if (hooksJsonResult.status === "ok") {
    hooks.push(...parseHooksEventMap(hooksJsonResult.map, warnings));
  }

  // Root .mcp.json.
  const mcpFile = join(root, ".mcp.json");
  const mcpContent = await readFile(mcpFile, "utf8").catch(() => null);
  if (mcpContent !== null) {
    try {
      const r = mcpFromFileContent(mcpContent, ".mcp.json");
      mcpServers.push(...r.servers);
      for (const k of r.envNames) envNames.add(k);
    } catch {
      warnings.push("Root .mcp.json could not be parsed and was skipped.");
    }
  }
  // Inline manifest declarations.
  // hooks: an inline event map, or a string pointing at a hooks file (with
  // the legacy "directory containing hooks.json" fallback).
  const hooksDecl = manifest.hooks;
  if (isRecord(hooksDecl)) {
    hooks.push(...parseHooksEventMap({ hooks: hooksDecl }, warnings));
  } else if (typeof hooksDecl === "string" && hooksDecl.trim() !== "") {
    const filePointer = cleanPointer(hooksDecl);
    let loaded: Record<string, unknown> | null = null;
    if (filePointer !== null) {
      const asFile = await readJsonMapResult(join(root, filePointer));
      if (asFile.status === "corrupt") {
        warnings.push(`Hooks file "${filePointer}" is not valid JSON — hooks were skipped.`);
      } else if (asFile.status === "ok") {
        loaded = asFile.map;
      } else {
        const asDir = await readJsonMapResult(join(root, filePointer, "hooks.json"));
        if (asDir.status === "corrupt") {
          warnings.push(`Hooks file "${filePointer}/hooks.json" is not valid JSON — hooks were skipped.`);
        } else if (asDir.status === "ok") {
          loaded = asDir.map;
        }
      }
    }
    if (loaded !== null) {
      hooks.push(...parseHooksEventMap(loaded, warnings));
    }
  }

  // mcpServers: an inline map (parsed per-entry like .mcp.json entries), or
  // a string pointer at an MCP config file (the `"./.mcp.json"` form).
  const mcpDecl = manifest.mcpServers;
  if (isRecord(mcpDecl) && Object.keys(mcpDecl).length > 0) {
    const r = await mcpFromMap(
      mcpDecl,
      "plugin.json#mcpServers",
      warnings,
    );
    mcpServers.push(...r.servers);
    for (const k of r.envNames) envNames.add(k);
  } else if (typeof mcpDecl === "string" && mcpDecl.trim() !== "") {
    const cleaned = cleanPointer(mcpDecl);
    if (cleaned !== null) {
      const content = await readFile(join(root, cleaned), "utf8").catch(() => null);
      if (content !== null) {
        try {
          const r = mcpFromFileContent(content, cleaned);
          mcpServers.push(...r.servers);
          for (const k of r.envNames) envNames.add(k);
        } catch {
          warnings.push(
            `Pointed-at MCP config "${cleaned}" could not be parsed and was skipped.`,
          );
        }
      }
    }
  }

  // Custom component directories (additive with the default scans; a
  // pointer resolving to an already-scanned directory is not scanned twice).
  for (const pointer of pointerList(manifest.commands)) {
    const cleaned = cleanPointer(pointer);
    if (cleaned !== null) await scanInto(cleaned, "commands");
  }
  for (const pointer of pointerList(manifest.skills)) {
    const cleaned = cleanPointer(pointer);
    if (cleaned !== null) await scanInto(cleaned, "skills");
  }
  for (const pointer of pointerList(manifest.agents)) {
    const cleaned = cleanPointer(pointer);
    if (cleaned !== null) await scanInto(cleaned, "agents");
  }

  const base: NormalizedPluginManifest = {
    pluginId: "",
    version: "",
    format: "native",
    commands,
    skills,
    agents,
    hooks,
    // Dedupe by server name (first declaration wins): a plugin.json
    // `"mcpServers": "./.mcp.json"` pointer alongside the conventional root
    // `.mcp.json` parses the same file twice, and two contributions sharing
    // one canonical id would make register() throw on reinstall.
    mcpServers: dedupeMcpByName(mcpServers),
    capabilities: declaredCapabilities,
    envNames: [...envNames],
    warnings,
    rootPath: root,
  };
  const capabilities = [
    ...new Set([...declaredCapabilities, ...inferRequestedCapabilities(base)]),
  ];

  return {
    commands: dedupeByName(commands),
    skills: dedupeByName(skills),
    agents: dedupeByName(agents),
    hooks,
    mcpServers: base.mcpServers,
    capabilities,
    envNames: [...envNames],
    warnings,
  };
}

/** First declaration wins, keyed by name (canonical ids are name-based). */
export function dedupeByName<T extends { name: string }>(items: T[]): T[] {
  const seen = new Set<string>();
  const out: T[] = [];
  for (const item of items) {
    if (seen.has(item.name)) continue;
    seen.add(item.name);
    out.push(item);
  }
  return out;
}

/** First declaration wins, keyed by server name. */
function dedupeMcpByName(
  servers: PluginMcpServerContribution[],
): PluginMcpServerContribution[] {
  const seen = new Set<string>();
  const out: PluginMcpServerContribution[] = [];
  for (const s of servers) {
    if (seen.has(s.name)) continue;
    seen.add(s.name);
    out.push(s);
  }
  return out;
}
