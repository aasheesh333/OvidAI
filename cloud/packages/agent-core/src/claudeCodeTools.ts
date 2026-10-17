// [CC] tool-name aliasing (port of lib/core/claude_code_tools.dart).
//
// Ovid's agent tools have their own names (`fs_edit`, `run_shell`, ...);
// [CC] plugins — hooks, agent `tools:` lists, skill `allowed-tools` — speak
// Claude Code's vocabulary (`Edit`, `Bash`, `Glob`, `Agent`/`Task`, ...).
// This module is the single translation table, used in both directions:
//
//   • native → CC: ccToolName — the tool name a hook matcher / stdin sees;
//   • CC → native: nativeToolsFor — the native tools a `tools:` entry
//     (CC name, permission-rule specifier, MCP pattern, prefix wildcard)
//     grants. Used by roster.ts's activeSkillScopes step.
//
// Pure functions only. The hook payload-shaping halves of the Dart module
// (ccToolInput / nativeToolInput) belong to the hooks task (T18) and are not
// re-ported here.

/// Native tools each [CC] tool name grants. EXACT port of Dart's
/// `_ccToNative` (Bash's order pinned by the plan brief). `multi_edit` and
/// `notebook_edit` take the [CC] input shape natively; Ovid has no LS tool,
/// so `LS` maps to `fs_glob`.
export const CC_TO_NATIVE: Readonly<Record<string, readonly string[]>> = {
  Bash: ["run_shell", "job_start", "job_output", "job_list", "job_kill"],
  PowerShell: ["run_shell"],
  Read: ["file_read", "read_image", "read_attachment"],
  Write: ["file_write"],
  Edit: ["fs_edit"],
  MultiEdit: ["multi_edit"],
  NotebookEdit: ["notebook_edit"],
  NotebookRead: ["file_read"],
  Glob: ["fs_glob"],
  LS: ["fs_glob"],
  Grep: ["fs_grep"],
  WebFetch: ["fetch_url"],
  WebSearch: ["web_search"],
  Agent: ["dispatch_agent"],
  Task: ["dispatch_agent"],
  Workflow: ["workflow"],
  TodoWrite: ["todo_write"],
  Skill: ["skill"],
  AskUserQuestion: ["ask_user_question"],
  ExitPlanMode: ["exit_plan_mode"],
  SendMessage: ["send_message"],
  TaskStop: ["interrupt_agent"],
  TaskOutput: ["job_output"],
};

/// True when [name] is a [CC] built-in tool name Ovid understands.
export function isCcToolName(name: string): boolean {
  return Object.prototype.hasOwnProperty.call(CC_TO_NATIVE, name);
}

/**
 * The [CC] name for native tool [native], or the native name itself when the
 * tool has no [CC] equivalent (MCP tools keep their `mcp__server__tool`
 * name, which already IS the [CC] name — Dart returns null there and every
 * caller falls back to the native name; this signature folds that fallback
 * in). `fs_edit` resolves per operation: `view` → Read, `create` → Write,
 * everything else → Edit ([CC]'s own create-vs-edit split).
 */
export function ccToolName(
  native: string,
  input?: Readonly<Record<string, unknown>>,
): string {
  switch (native) {
    case "run_shell":
    case "job_start":
      return "Bash";
    case "file_read":
    case "read_image":
      return "Read";
    case "file_write":
      return "Write";
    case "fs_edit":
      switch (input?.["command"]) {
        case "view":
          return "Read";
        case "create":
          return "Write";
        default:
          return "Edit";
      }
    case "multi_edit":
      return "MultiEdit";
    case "notebook_edit":
      return "NotebookEdit";
    case "fs_glob":
      return "Glob";
    case "fs_grep":
      return "Grep";
    case "fetch_url":
      return "WebFetch";
    case "web_search":
      return "WebSearch";
    case "dispatch_agent":
      return "Agent";
    case "workflow":
      return "Workflow";
    case "todo_write":
      return "TodoWrite";
    case "skill":
      return "Skill";
    case "ask_user_question":
      return "AskUserQuestion";
    case "exit_plan_mode":
      return "ExitPlanMode";
    case "send_message":
      return "SendMessage";
    case "interrupt_agent":
      return "TaskStop";
    default:
      return native;
  }
}

/**
 * Native tool names a `tools:` / `allowed-tools` [entry] grants.
 *
 * An entry may be (Dart `SubagentToolPolicy.entryMatches` parity):
 *  • a [CC] tool name (`Read`, `Edit`, `Agent`/`Task`, ...), expanded through
 *    CC_TO_NATIVE;
 *  • a native Ovid tool name (`fs_edit`, `plugin__x__y`, ...), which grants
 *    itself;
 *  • an MCP tool `mcp__<server>__<tool>` (exact), a server pattern
 *    `mcp__<server>` (→ `mcp__<server>__*`), `mcp__<server>__*`, `mcp__*` or
 *    bare `mcp__`;
 *  • any name with a trailing `*` (prefix pattern);
 *  • a permission-rule specifier such as `Bash(git push *)` — [CC]: a
 *    specifier still grants the WHOLE tool, so the base is expanded.
 *
 * Non-enumerable entries (wildcards, server patterns) come back as PATTERN
 * strings ending in `*`; callers match by prefix (roster.ts does exactly
 * that), which is why `mcp__srv` expands to `mcp__srv__*` rather than a
 * concrete list — the roster is only known at projection time.
 */
export function nativeToolsFor(entry: string): string[] {
  let base = entry.trim();
  // A permission-rule specifier scopes the whole tool: strip it.
  const paren = base.indexOf("(");
  if (paren > 0 && base.endsWith(")")) base = base.slice(0, paren).trim();
  if (base === "") return [];
  if (base === "*") return ["*"];
  if (base.startsWith("mcp__")) {
    if (base === "mcp__" || base === "mcp__*") return ["mcp__*"];
    if (base.endsWith("*")) return [base];
    // `mcp__<server>` (no tool segment) grants the whole server.
    if (!base.slice("mcp__".length).includes("__")) return [`${base}__*`];
    return [base];
  }
  const cc = CC_TO_NATIVE[base];
  if (cc) return [...cc];
  if (base.endsWith("*") && base.length > 1) return [base];
  // A native name grants itself (and an unknown name matches nothing
  // concrete unless the roster happens to carry it — same as Dart's
  // `base == native` check).
  return [base];
}
