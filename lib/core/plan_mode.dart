/// ── Plan-mode policy (G7) ─────────────────────────────────────────────────
///
/// Plan mode used to be spread across a 20,000-line service: the allowlist,
/// the gate message, the prompt briefing, the tool schema, the handler, the
/// preset and the UI card each lived somewhere else. This module is the
/// single definition of **what planning may do**, so the two enforcement
/// points — the dispatch gate and the model-visible tool roster — can never
/// disagree with each other or with the briefing.
///
/// ## Model: opencode's `plan` agent
///
/// opencode's plan agent leaves `bash` ALLOWED and denies only `edit`; the
/// read-only rule inside the shell is carried by prompt text
/// (`session/prompt/plan.txt`), because a shell command's effect cannot be
/// decided from its name. Ovid mirrors that split exactly:
///
///   • **hard gate** for tools whose *identity* is mutating (`file_write`,
///     `fs_edit`, `commit`, `run_code`, `repo_sync`, `device_*`, plugin/MCP),
///     enforced at dispatch and hidden from the roster;
///   • **briefing** for shell commands, where the model is told which
///     commands are off-limits.
///
/// ## Where this differs from dsh
///
/// dsh's plan mode is *soft guidance only* — its sandbox and approval policy
/// enforce independently and never read plan state, so "every tool remains
/// available". For an on-device agent that has `run_shell`, `device_*` (tap /
/// type / screenshot on **other apps**) and arbitrary plugin/MCP tools, a
/// prompt-only plan mode would be a real hole. The hard gate stays.
library;

/// The plan-mode policy: allowlist, roster projection, briefing and the
/// settings catalogue. Static-only.
class PlanModePolicy {
  PlanModePolicy._();

  /// Tools that may run while planning. **DEFAULT-DENY**: anything not listed
  /// here — including any tool added in future, every plugin/MCP
  /// contribution, and the canonical `plugin:<id>/command:<name>` spellings —
  /// is refused by the gate and withheld from the roster.
  ///
  /// Deliberately EXCLUDED: every `device_*` tool (they act on other apps and
  /// capture their screens), all `plugin_*` / canonical plugin calls and MCP
  /// tools (arbitrary third-party code whose effect cannot be known here),
  /// `preview` / `generate_image` (they write files), the native content
  /// tools that can send (`sms`, `phone`, `contacts`, `calendar`), and every
  /// tool that writes the workspace or the repo.
  static const Set<String> allowedTools = {
    // ── reading the workspace ────────────────────────────────────────
    'file_read',
    'fs_view',
    'fs_glob',
    'fs_grep',
    'view',
    'read_attachment',
    'read_image',
    // ── reading repo state (GitHub API + local git) ──────────────────
    'repo_read',
    'repo_tree',
    'git_status',
    'git_log',
    'git_diff',
    // ── inspecting the workspace with the shell (opencode parity) ────
    // opencode's plan agent leaves `bash` ALLOWED and denies only `edit`, so
    // the planning agent can run `git log`, `find`, `wc`, `tree`, `cat`,
    // `grep`, `ls`, `sed -n` … to research the current directory. Read-only
    // intent is carried by [promptSection], not by the gate.
    'run_shell',
    // ── research ─────────────────────────────────────────────────────
    'fetch_url',
    'web_search',
    'memory_search',
    'memory_read',
    'session_search',
    'session_read',
    // ── reading the browser WITHOUT driving it ───────────────────────
    'browser_read',
    'browser_list_tabs',
    'browser_find',
    'browser_wait_for',
    'browser_snapshot',
    'browser_outline',
    // Screenshot is in the READ group, and that is deliberate: it captures
    // pixels and stages them as a vision message — nothing is written to disk
    // and no page state changes (unlike browser_click/type, which DRIVE the
    // page and are correctly excluded). Planning without it means a plan can
    // never be grounded in what a page actually LOOKS like, which is exactly
    // the research the plan agent is for.
    'browser_screenshot',
    // ── reading background state ─────────────────────────────────────
    'job_list',
    'job_output',
    'get_goal',
    'schedule_list',
    'catalog_get_provider',
    'catalog_list_mcp',
    'catalog_list_models',
    'catalog_list_plugins',
    'catalog_list_providers',
    // ── planning itself ──────────────────────────────────────────────
    // todo_write is the plan artifact: session-local UI state that never
    // touches disk, repo or network (same reasoning as Read-Only mode).
    'todo_write',
    'ask_user_question',
    'exit_plan_mode',
    'list_agents',
    'report',
    'skill',
  };

  /// The harness itself — orchestration and session bookkeeping — stays
  /// available in every mode; it is not a capability being gated. Kept here
  /// as the single definition (presets re-export it).
  static const Set<String> harnessTools = {
    'dispatch_agent',
    'report',
    'update_goal',
    'get_goal',
    'create_goal',
    'memory_save',
  };

  /// [allowedTools] plus [harnessTools] — what the model may still SEE while
  /// planning. Used by the roster projection in `AgentService._tools`, so a
  /// planning model is not billed for (and cannot be tempted by) tools the
  /// gate would refuse anyway.
  static final Set<String> rosterTools = {
    ...allowedTools,
    ...harnessTools,
  };

  /// True when [name] may run while planning under [policy]. [policy] is the
  /// per-preset override (G5): a custom preset may carry its own plan
  /// allowlist; when it is empty the built-in [allowedTools] applies.
  static bool allows(String name, {Set<String>? policy}) =>
      (policy ?? allowedTools).contains(name);

  /// True when [name] should still be VISIBLE to a planning model under
  /// [policy] — the roster projection of [allows].
  static bool rosterAllows(String name, {Set<String>? policy}) {
    if (harnessTools.contains(name)) return true;
    return allows(name, policy: policy);
  }

  /// The read-only briefing injected while plan mode is active. This is the
  /// `session/prompt/plan.txt` equivalent: it is what makes "shell is
  /// allowed" safe, because a command's effect cannot be decided from its
  /// name. Injected for EVERY entry point (`/plan`, the Plan chip, the `plan`
  /// preset), so no path can enter plan mode without the rule.
  static const String promptSection = '''
PLAN MODE — READ-ONLY RESEARCH PHASE (opencode plan-agent parity):
You are the PLAN agent. Your job is to RESEARCH and PROPOSE, not to change
anything.
WORKING DIRECTORY: {PLAN_ROOT}
{PLAN_SCOPE}Paths outside it are refused outright — no card, no retry — in
EVERY access mode, Full Access and Studio included. Use relative paths inside
the working directory for all research. If the answer genuinely lives outside
it, write that into the plan as a step for the user to approve instead of
reaching for the path.
Investigate the working directory thoroughly before you propose:
read files, glob and grep, inspect git history and diffs, and run read-only
shell commands (ls, cat, find, wc, tree, git log/diff/status, `sed -n`).
CRITICAL: you are in the READ-ONLY phase. Do NOT use shell commands that
modify anything — no redirects into files (`>`, `>>`), no `tee`, `sed -i`,
`mv`, `rm`, `mkdir`, `touch`, no `git add/commit/checkout`, no installs.
Do not use file_write, fs_edit, commit, or any device_* tool. If something
looks like it needs a change, write the change down instead of making it.
The plan is NOT a card and NOT a tool argument: write it out as a normal
message — a numbered list of concrete steps naming the exact files and
commands involved — and only THEN call exit_plan_mode, which asks the user
one yes/no question: switch to the build agent and start implementing?
Keep the plan tight and grounded in what you actually read.
You are NEVER asked for a permission while planning: read-only shell commands
run silently, and every mutating call is refused outright with the reason —
so do not "try it and see" (a denied write/delete/install costs a turn and
changes nothing). If a step needs a change, write the change down.
''';

  /// The placeholder in [promptSection] that carries the session's working
  /// directory.
  static const String rootPlaceholder = '{PLAN_ROOT}';

  /// Placeholder for the mode-specific sentence about where that directory
  /// comes from, so the briefing explains its own boundary.
  static const String scopePlaceholder = '{PLAN_SCOPE}';

  /// [promptSection] with the working directory and its provenance filled in.
  ///
  /// Both placeholders are ALWAYS resolved: a literal `{PLAN_ROOT}` in a system
  /// prompt is worse than no path at all, because the model would repeat it
  /// back to the user as if it were a real directory.
  static String promptSectionFor({String? root, required String modeName}) {
    final r = (root ?? '').trim();
    final scope = switch (modeName) {
      'studio' =>
        'This is the repo folder selected for this session (or where you '
            'cloned to) — the whole repo is in scope, nothing outside it is.\n',
      'drive' =>
        'Full Access does NOT widen plan mode: research stays inside this one '
            'directory until the user approves the build phase.\n',
      _ =>
        'This is the session-isolated workspace for this chat — other '
            'sessions\' folders are not yours to read.\n',
    };
    final dir = r.isEmpty
        ? 'this session\'s workspace (run `pwd` to resolve it)'
        : r;
    return promptSection
        .replaceAll(rootPlaceholder, dir)
        .replaceAll(scopePlaceholder, scope);
  }

  /// The tools offered in the preset editor's plan-allowlist picker (G5):
  /// the built-in policy plus the mutating tools a user may deliberately
  /// choose to allow while planning.
  static const List<String> catalogue = [
    'ask_user_question',
    'browser_find',
    'browser_list_tabs',
    'browser_outline',
    'browser_read',
    'browser_screenshot',
    'browser_snapshot',
    'browser_wait_for',
    'catalog_get_provider',
    'catalog_list_mcp',
    'catalog_list_models',
    'catalog_list_plugins',
    'catalog_list_providers',
    'commit',
    'exit_plan_mode',
    'fetch_url',
    'file_read',
    'file_write',
    'fs_edit',
    'fs_glob',
    'fs_grep',
    'fs_view',
    'get_goal',
    'git_diff',
    'git_log',
    'git_status',
    'job_list',
    'job_output',
    'list_agents',
    'memory_search',
    'memory_read',
    'read_attachment',
    'read_image',
    'repo_read',
    'repo_sync',
    'repo_tree',
    'report',
    'run_code',
    'run_shell',
    'schedule_list',
    'session_search',
    'session_read',
    'skill',
    'todo_write',
    'view',
    'web_search',
  ];

  /// The subset of [catalogue] that Read-Only mode refuses ANYWAY, even when a
  /// custom preset's plan allowlist (G5) lists it.
  ///
  /// The plan policy is user-authorable and may widen past what planning needs
  /// — but the `plan` preset forces `mode = safe`, and `AgentService.
  /// _readOnlyBlock` independently refuses these tools whenever the session is
  /// Read-Only. So ticking e.g. `file_write` here would advertise it to the
  /// model and then have the dispatch gate reject it: exactly the roster/gate
  /// drift this module exists to remove. The editor must therefore SAY SO
  /// (the `*` suffix and footnote in Settings) rather than imply these will
  /// run. Kept here, beside [catalogue], so the label can never drift from the
  /// gate — see `_readOnlyBlock`'s switch in `agent_service.dart`.
  ///
  /// `fs_edit` is refused for every use this picker advertises: `_readOnlyBlock`
  /// lets it through only for its `view` subcommand, and the catalogue entry IS
  /// the editing use.
  ///
  /// `run_shell` is deliberately NOT listed: `_readOnlyBlock` runs a read-only
  /// command (`_isReadOnlyCommand`) and refuses only the mutating ones, so
  /// ticking it in a custom plan policy genuinely takes effect and marking it
  /// would be a lie in the other direction.
  static const Set<String> readOnlyBlocked = {
    'commit',
    'file_write',
    'fs_edit',
    'run_code',
  };
}
