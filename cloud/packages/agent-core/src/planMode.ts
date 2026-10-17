// Plan-mode policy (port of lib/core/plan_mode.dart — the static policy part).
//
// Plan mode is DEFAULT-DENY: anything not on the allowlist — including any
// tool added in future, every plugin/MCP contribution — is refused by the
// dispatch gate AND withheld from the model-visible roster. The two
// enforcement points (Task 15's gate and roster.ts's computeToolRoster)
// read these same sets, so they can never disagree.
//
// The model follows opencode's `plan` agent: the shell stays ALLOWED (a
// command's effect cannot be decided from its name) and read-only intent is
// carried by the briefing (systemPrompt.ts planBriefing, Task 7); tools whose
// IDENTITY is mutating (`file_write`, `fs_edit`, `commit`, `run_code`,
// `device_*`, plugin/MCP classes) are hard-gated.
//
// The prompt briefing (promptSection/promptSectionFor) is NOT re-ported here:
// Task 7's systemPrompt.ts already owns the plan section splice.

/// Tools that may run while planning. EXACT port of Dart's
/// `PlanModePolicy.allowedTools` — member for member; do not "improve" it here
/// without re-porting (it is the contract). DEFAULT-DENY: anything else is
/// refused by the gate and withheld from the roster.
export const PLAN_ALLOWED_TOOLS: ReadonlySet<string> = new Set([
  // ── reading the workspace ────────────────────────────────────────
  "file_read",
  "fs_view",
  "fs_glob",
  "fs_grep",
  "view",
  "read_attachment",
  "read_image",
  // ── reading repo state (GitHub API + local git) ──────────────────
  "repo_read",
  "repo_tree",
  "git_status",
  "git_log",
  "git_diff",
  // ── inspecting the workspace with the shell (opencode parity) ────
  // opencode's plan agent leaves `bash` ALLOWED and denies only `edit`;
  // read-only intent is carried by the briefing, not by the gate.
  "run_shell",
  // ── research ─────────────────────────────────────────────────────
  "fetch_url",
  "web_search",
  "memory_search",
  "memory_read",
  "session_search",
  "session_read",
  // ── reading the browser WITHOUT driving it ───────────────────────
  "browser_read",
  "browser_list_tabs",
  "browser_find",
  "browser_wait_for",
  "browser_snapshot",
  "browser_outline",
  // Screenshot is in the READ group deliberately: it captures pixels and
  // stages them as a vision message — nothing is written to disk and no page
  // state changes (unlike browser_click/type, which DRIVE the page).
  "browser_screenshot",
  // ── reading background state ─────────────────────────────────────
  "job_list",
  "job_output",
  "get_goal",
  "schedule_list",
  "catalog_get_provider",
  "catalog_list_mcp",
  "catalog_list_models",
  "catalog_list_plugins",
  "catalog_list_providers",
  // ── planning itself ──────────────────────────────────────────────
  // todo_write is the plan artifact: session-local UI state that never
  // touches disk, repo or network.
  "todo_write",
  "ask_user_question",
  "exit_plan_mode",
  "list_agents",
  "report",
  "skill",
]);

/// The harness itself — orchestration and session bookkeeping — survives the
/// `!memoryEnabled` drop (memory_save is a member: `memoryEnabled:false`
/// drops memory_search but KEEPS memory_save) and every preset-ALLOWLIST
/// intersection (orchestration is the harness, not a capability being
/// gated). It does NOT survive the plan-mode projection: while planning the
/// roster is allowlist-only (Dart G4 — `dispatch_agent` is a deliberate
/// escape hatch OUT of plan mode: a child session starts planMode:false and
/// would get the full mutating roster, voiding the read-only contract; Dart
/// pins the union as "the drift", plan_mode_policy_test.dart:362–367).
/// Consequence (Dart parity, accepted): memory_save, update_goal and
/// create_goal also drop while planning; report and get_goal stay — they are
/// allowlist members. EXACT port of Dart's `PlanModePolicy.harnessTools`;
/// presets re-export it as their always-allowed set.
export const HARNESS_TOOLS: ReadonlySet<string> = new Set([
  "dispatch_agent",
  "report",
  "update_goal",
  "get_goal",
  "create_goal",
  "memory_save",
]);

/// Identity-mutating / third-party tool classes: hard gate in plan mode,
/// never resolved by prompt text. (Cloud drops `device_*` outright in every
/// mode — D5, no Control mode — so the `device_` prefix here is belt and
/// braces for the plan projection.)
export const PLAN_HARD_DENIED_PREFIXES = ["device_", "plugin_", "mcp__"] as const;

/// P2's read-only tool spellings (ruling R1: P2's landed roster — run_shell,
/// read_file, write_file, edit_file, glob_files, grep_files — joins the
/// canonical seam alongside P3's tools). The read-only trio is admitted in
/// plan mode next to its P3 counterparts so a planning model sees both
/// spellings; the write/spellings are NOT (they mutate).
export const PLAN_ALIAS_TOOLS: ReadonlySet<string> = new Set([
  "read_file",
  "glob_files",
  "grep_files",
]);

/// What the plan-mode projection keeps: the allowlist plus P2's read-only
/// aliases (ruling R1) — and NOTHING else. Allowlist-only by design (Dart's
/// shipped gate AND roster both refuse `dispatch_agent` while planning; the
/// harness union is the drift Dart's G4 test explicitly rejects — cloud
/// child sessions start planMode:false, so admitting the spawner would be a
/// mutation escape hatch out of read-only planning). Harness members that
/// are also allowlist members (`report`, `get_goal`) stay.
export function planRosterAdmits(name: string): boolean {
  if (PLAN_HARD_DENIED_PREFIXES.some((p) => name.startsWith(p))) return false;
  return PLAN_ALLOWED_TOOLS.has(name) || PLAN_ALIAS_TOOLS.has(name);
}
