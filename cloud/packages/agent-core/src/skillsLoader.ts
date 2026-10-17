// SKILL.md loader (port of lib/core/skills.dart, narrowed to the cloud
// workspace catalog per the P3 Task 17 brief).
//
// DISCOVERY (plan L709): `.dsh/skills/<name>/SKILL.md` (bundle) and
// `.dsh/skills/<name>.md` (flat). Dart scans a wider root list
// (`.agents/skills`, `.claude/skills`, `.codex/...`, user-global docs and
// plugin mounts); those are a Dart superset and are deliberately NOT ported
// here — the cloud catalog is workspace-files only.
//
// HOT RELOAD: every list()/load() call re-reads the workspace through the
// SandboxPort — there is no cache generation counter to invalidate (Dart
// `isSessionCatalogStale` / `invalidateSession` collapse to "always fresh").
// An edited SKILL.md is picked up on the next load.
//
// COLLISIONS: a bundle beats a flat `<name>.md`; otherwise first-wins in a
// deterministic scan order (Dart `_sourceIdentity` dedupe +
// `publishSessionCatalog` first-wins). Cloud discovery has a single root, so
// the cross-root ambiguity branch of Dart's `resolveForSession` cannot arise
// and is deleted-with-comment.
//
// DELETED-WITH-COMMENT (AG4): supporting files (`readSupportingFile`,
// `supportingFilesFor`, `scanBundleFiles`, the 64 KiB cap and the
// 8 KiB/32 KiB inline caps), plugin mounts / canonical §4.4 ids / session
// activation scoping (P5), AGENT.md agent-kind discovery (cloud `Skill` has
// no agent kind), and symlink-refusal walks (the SandboxPort exposes no
// symlink/stat surface; the P2 adapter confines every path to the workspace).

import { nativeToolsFor } from "./claudeCodeTools.js";
import type { SandboxPort, Skill, SkillCatalog, SkillSummary } from "./ports.js";

/** Dart `kBundleScanMaxDepth`. */
export const kBundleScanMaxDepth = 12;

/** Dart `kNonSkillRootDocs`: never skills when found at a scanned ROOT. */
export const kNonSkillRootDocs: ReadonlySet<string> = new Set([
  "AGENTS.md",
  "README.md",
  "CHANGELOG.md",
  "CONTRIBUTING.md",
  "CODE_OF_CONDUCT.md",
  "LICENSE.md",
  "SECURITY.md",
]);

/** The single cloud discovery root, workspace-relative. */
export const SKILL_ROOT = ".dsh/skills";

interface ParsedSkill {
  skill: Skill;
  modelInvocable: boolean;
  userInvocable: boolean;
  /** Bundle skills beat flat `<name>.md` skills on a name collision. */
  bundle: boolean;
}

/**
 * Parse a `---`-fenced YAML-lite frontmatter block.
 *
 * Exact port of Dart `_parseFrontmatter` + `_unquote` + the fence rule in
 * `stripMarkdownFrontmatter`: the fence must start at byte 0 and close at the
 * first `\n---` after offset 3. A malformed/absent fence yields `attrs: {}`
 * and leaves the body unchanged (Dart returns `raw` in that case).
 *
 * Supported: `key: value` (values may contain colons), quoted values, folded
 * (`>`/`>-`/`>+`) and literal (`|`/`|-`/`|+`) block scalars, and a bare
 * `key:` followed by an indented `- item` block list (items joined with
 * newlines, matching Dart's split-on-whitespace consumers).
 */
export function parseSkillFrontmatter(md: string): {
  attrs: Record<string, string>;
  body: string;
} {
  if (!md.startsWith("---")) return { attrs: {}, body: md };
  const end = md.indexOf("\n---", 3);
  if (end <= 0) return { attrs: {}, body: md };
  return {
    attrs: parseFrontmatterBlock(md.slice(3, end)),
    body: md.slice(end + 4).trim(),
  };
}

function parseFrontmatterBlock(block: string): Record<string, string> {
  const result: Record<string, string> = {};
  const lines = block.split("\n");
  let index = 0;
  while (index < lines.length) {
    const line = lines[index]!;
    index += 1;
    if (line.trim() === "") continue;
    // Dart: ^([^:\s][^:]*):(.*)$ — the key cannot contain whitespace/colons.
    const match = /^([^:\s][^:]*):(.*)$/.exec(line);
    if (match === null) continue;
    const key = match[1]!.trim();
    const rest = match[2]!.trim();
    const folded = rest === ">" || rest === ">-" || rest === ">+";
    const literal = rest === "|" || rest === "|-" || rest === "|+";
    if (folded || literal) {
      const collected: string[] = [];
      while (index < lines.length) {
        const next = lines[index]!;
        if (next.trim() === "") {
          collected.push("");
          index += 1;
          continue;
        }
        if (!next.startsWith(" ") && !next.startsWith("\t")) break;
        collected.push(next.replace(/^[ \t]+/, ""));
        index += 1;
      }
      while (collected.length > 0 && collected[collected.length - 1] === "") {
        collected.pop();
      }
      result[key] = literal
        ? collected.join("\n")
        : collected.filter((entry) => entry !== "").join(" ");
      continue;
    }
    if (rest === "") {
      const items: string[] = [];
      const resume = index;
      while (index < lines.length) {
        const item = /^\s+-\s+(.*)$/.exec(lines[index]!);
        if (item === null) break;
        items.push(unquote(item[1]!.trim()));
        index += 1;
      }
      if (items.length > 0) {
        result[key] = items.join("\n");
        continue;
      }
      index = resume;
    }
    result[key] = unquote(rest);
  }
  return result;
}

function unquote(value: string): string {
  if (value.length >= 2) {
    if (value.startsWith('"') && value.endsWith('"')) {
      return value.slice(1, -1);
    }
    if (value.startsWith("'") && value.endsWith("'")) {
      return value.slice(1, -1);
    }
  }
  return value;
}

/** Dart `_parseToolList`: trim, strip `[...]`, split on commas/whitespace. */
export function parseToolList(value: string): string[] {
  let body = value.trim();
  if (body.startsWith("[") && body.endsWith("]")) body = body.slice(1, -1);
  return body
    .split(/[,\s]+/)
    .map((entry) => entry.trim().replaceAll('"', "").replaceAll("'", ""))
    .filter((entry) => entry !== "");
}

function basename(path: string): string {
  const idx = path.lastIndexOf("/");
  return idx < 0 ? path : path.slice(idx + 1);
}

function basenameNoExt(path: string): string {
  const name = basename(path);
  return name.endsWith(".md") ? name.slice(0, -3) : name;
}

/**
 * Parse one SKILL.md/flat `.md` body into the cloud `Skill` shape.
 * `declaredPath` is the workspace-relative declaring path (a bundle DIRECTORY
 * for `<dir>/SKILL.md`, the file for a flat skill), matching Dart's
 * `Skill.path`/`providerId`.
 */
function parseSkillFile(
  raw: string,
  o: { declaredPath: string; defaultName: string; bundle: boolean },
): ParsedSkill | null {
  const { attrs, body } = parseSkillFrontmatter(raw);
  // Dart: content.trim().isEmpty ⇒ skill discarded.
  if (body.trim() === "") return null;

  let name = o.defaultName;
  let description = "";
  let whenToUse = "";
  let modelInvocable = true;
  let userInvocable = true;
  let allowedTools: string[] = [];

  for (const [key, value] of Object.entries(attrs)) {
    switch (key) {
      case "name":
        if (value !== "") name = value;
        break;
      case "description":
        description = value;
        break;
      case "whenToUse":
        whenToUse = value;
        break;
      case "disable-model-invocation":
        // A frontmatter `true` means the MODEL may not invoke it.
        modelInvocable = value.toLowerCase() !== "true";
        break;
      case "user-invocable":
        userInvocable = value.toLowerCase() === "true";
        break;
      case "allowed-tools":
      case "allowed_tools":
      case "tools":
        allowedTools = parseToolList(value);
        break;
      default:
        // argument-hint/model and unknown keys stay in the frontmatter map
        // only; the cloud Skill port has no field for them.
        break;
    }
  }

  return {
    skill: {
      name,
      description,
      whenToUse,
      content: body,
      path: o.declaredPath,
      allowedTools,
    },
    modelInvocable,
    userInvocable,
    bundle: o.bundle,
  };
}

async function tryRead(
  sandbox: SandboxPort,
  userId: string,
  path: string,
): Promise<string | null> {
  try {
    return await sandbox.readFile(userId, path);
  } catch {
    return null;
  }
}

async function tryList(
  sandbox: SandboxPort,
  userId: string,
  path: string,
): Promise<string[] | null> {
  try {
    return await sandbox.listDir(userId, path);
  } catch {
    return null;
  }
}

/**
 * Walk the workspace skill root. A directory containing `SKILL.md` is one
 * bundle and is NOT recursed into (Dart `_scanDir`); other directories are
 * walked up to `kBundleScanMaxDepth`. `.md` files become flat skills; at
 * depth 0 the `kNonSkillRootDocs` allowlist is skipped, below it is not.
 */
async function scanDir(
  sandbox: SandboxPort,
  userId: string,
  dir: string,
  depth: number,
  out: ParsedSkill[],
): Promise<void> {
  if (depth > kBundleScanMaxDepth) return;
  const entries = await tryList(sandbox, userId, dir);
  if (entries === null) return;
  entries.sort();

  const childDirs: string[] = [];
  for (const entry of entries) {
    const child = `${dir}/${entry}`;
    // Bundle: <dir>/<name>/SKILL.md — probed first so a bundle always beats a
    // flat sibling of the same name regardless of readdir order.
    const bundleRaw = await tryRead(sandbox, userId, `${child}/SKILL.md`);
    if (bundleRaw !== null) {
      const parsed = parseSkillFile(bundleRaw, {
        declaredPath: child,
        defaultName: basename(child),
        bundle: true,
      });
      if (parsed !== null) out.push(parsed);
      continue;
    }
    // AGENT.md is deliberately not discovered: the cloud `Skill` port has no
    // agent kind (Dart's agent contributions are P6/T20 personas). Dart
    // consumes such a directory as an agent and does not recurse into it —
    // mirror that so AGENT.md never falls through as a flat skill.
    if ((await tryRead(sandbox, userId, `${child}/AGENT.md`)) !== null) {
      continue;
    }
    if (entry.endsWith(".md")) {
      if (entry === "AGENT.md") continue;
      if (depth === 0 && kNonSkillRootDocs.has(entry)) continue;
      const raw = await tryRead(sandbox, userId, child);
      if (raw === null) continue;
      const parsed = parseSkillFile(raw, {
        declaredPath: child,
        // Dart `_parse`: a file literally named SKILL.md defaults to its
        // PARENT directory's name, not "SKILL".
        defaultName:
          entry === "SKILL.md" ? basename(dir) : basenameNoExt(child),
        bundle: false,
      });
      if (parsed !== null) out.push(parsed);
      continue;
    }
    childDirs.push(child);
  }
  for (const child of childDirs) {
    await scanDir(sandbox, userId, child, depth + 1, out);
  }
}

/**
 * Discover every skill for [userId]'s workspace. Bundles sort before flats,
 * then first-wins by case-insensitive name (Dart's find is case-insensitive;
 * a bundle wins the same-name collision), then stable by declaring path.
 */
async function discover(
  sandbox: SandboxPort,
  userId: string,
): Promise<ParsedSkill[]> {
  const all: ParsedSkill[] = [];
  await scanDir(sandbox, userId, SKILL_ROOT, 0, all);
  const ordered = [
    ...all.filter((s) => s.bundle),
    ...all.filter((s) => !s.bundle),
  ];
  const seen = new Set<string>();
  const unique: ParsedSkill[] = [];
  for (const parsed of ordered) {
    const key = parsed.skill.name.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    unique.push(parsed);
  }
  unique.sort((a, b) => a.skill.path.localeCompare(b.skill.path));
  return unique;
}

/**
 * The workspace SKILL.md catalog (Task 17).
 *
 * The cloud workspace is per USER (the SandboxPort attaches by userId), so
 * the `sessionId` argument does not scope file discovery: every session of a
 * user sees the same workspace catalog. Dart's per-session snapshots exist to
 * scope plugin activation (P5), which the cloud catalog does not implement.
 */
export function createSkillCatalog(deps: {
  sandbox: SandboxPort;
  /**
   * Owner of the sandbox workspace. The Task-1 `SkillCatalog` interface
   * carries only a sessionId (the skill tool's ctx has the userId, the
   * catalog API does not), so callers construct the catalog per user and
   * pass it here; a user-bound SandboxPort wrapper may omit it.
   */
  userId?: string;
}): SkillCatalog {
  const { sandbox } = deps;
  const userId = deps.userId ?? "";
  return {
    async list(sessionId: string): Promise<SkillSummary[]> {
      void sessionId;
      const skills = await discover(sandbox, userId);
      return skills.map((s) => ({
        name: s.skill.name,
        description: s.skill.description,
        whenToUse: s.skill.whenToUse,
        userInvocable: s.userInvocable,
        modelInvocable: s.modelInvocable,
      }));
    },
    async load(name: string, sessionId: string): Promise<Skill | null> {
      void sessionId;
      const needle = name.trim().toLowerCase();
      const skills = await discover(sandbox, userId);
      const found = skills.find((s) => s.skill.name.toLowerCase() === needle);
      return found === undefined ? null : found.skill;
    },
  };
}

/**
 * Expand a skill's parsed `allowed-tools` entries into the native tool names
 * the roster gate understands (Task 8's `nativeToolsFor`): CC names
 * (`Bash` → run_shell + job_*; `Edit` → fs_edit), MCP patterns
 * (`mcp__srv` → `mcp__srv__*`), permission-rule specifiers and prefix
 * wildcards. Duplicates collapse in first-seen order.
 *
 * Cloud ruling C2: the scope is EXPANDED (native names), unlike Dart's raw
 * containment (`skillTools.contains(name)`); roster.test.ts pins this
 * contract.
 */
export function skillAllowedTools(skill: Skill): string[] {
  const out: string[] = [];
  for (const entry of skill.allowedTools) {
    for (const granted of nativeToolsFor(entry)) {
      if (!out.includes(granted)) out.push(granted);
    }
  }
  return out;
}
