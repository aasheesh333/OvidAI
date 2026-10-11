# RESUME — continue exactly from where the cloud session stopped

> Temporary, removable (`git rm -r docs/screen-review`). Not used by the build.
> Snapshot taken 2026-10-11 after the user asked to stop all work.

## 1. Where everything stands

| Branch | Head | State |
|---|---|---|
| `hoplite/gortyn-77773150` | `2ac8936` | Base branch for all work. Untouched. |
| `fix/model-catalog-recovery` | `8921228` | **DONE, not deployed.** Server `/v1/models` no longer swallows a rejected key into 503 (401 `key_invalid` / 402 budget / 429). App re-mints once when the catalog rejects the key. Tests: server 59 pass, app 227 pass, `flutter analyze` clean. CI has not run (branch name not in the workflow's push list). No PR yet. |
| `perf/streaming-rebuilds` | `394a331` | **DONE.** Stream tokens tick `AgentService.liveBubbleTicks` instead of `AppState.refresh()`, so only the live bubble repaints. `_ChatTextScaler` has value equality. Full suite: 465/467 pass. The 2 failures (`ovid_pkg_test`, `parallel_packages_graph_test`) are mawk "eval stack size=1024" in the cloud container, not caused by this change. No PR yet. |
| `review/screen-audit` | `2222455`+ | **PAUSED mid-way.** 8-group full-read screen review. Files `01`–`08` are partial. Every commit uses `[skip ci]`. |

Master plan (approved): `docs/screen-review/00-master-plan.md`, phases 0–5 plus PR order.

Review progress at pause:
| File | Covered so far | Remaining |
|---|---|---|
| 01-chat-core.md | header only (the source had been read; nothing written) | everything in scope |
| 02-chat-messages.md | sections 1–7 (… composer, slash/@-mentions, attach sheet, mic) | goal editor, working-folder sheet, inline approval/question cards, control-mode consent dialogs, image viewer / artifact view if not yet covered, group summary |
| 03-plugins-mcp.md | sections 1–7 (… PluginCard, PluginDetail, McpCard, McpDetail + JSON editor) | `plugin_settings_panel`, `plugin_install_progress`, `plugin_permission_sheet`, `mcp_oauth_sheet`, group summary |
| 04-settings.md | sections 1–12 (… presets, keep-alive/telemetry, reset, backup) | `settings_health_screen`, `health_screen` (confirm unreachable), `permissions_screen`, `memory_screen` if not covered, group summary |
| 05-account-billing.md | login gate, auth methods, phone dialog, account screen, deletion panel | `billing_screen`, `usage_screen`, `cloud_usage_status`, `image_receipt_panel`, `providers_screen`, `profile_avatar`, group summary |
| 06-studio.md | sections 1–5 (… commit dialog, pickers, editor, file tree) | `studio_terminal_tabs`, `studio_layout`, `studio_errors`, `sandbox_setup`, `github_login_sheet`, group summary |
| 07-shell-nav-tools.md | sections 1–5 (… shell, sidebar, startup panel, browser) | `schedule_screen`, `trajectory_screen`, `subagent_screen`, group summary |
| 08-sharing-sync-design.md | sections 1–7 (… private sync, private conversation/activity, collaboration) | `widgets/aether_primitives`, `widgets/ovid_mark`, `lib/core/theme.dart` (contrast math, typography, tap targets, l10n readiness), group summary |

Not started: VPS Phase 1B (see `VPS_HANDOFF_PROMPT.md`), the SQLite history migration, MCP/plugin parity, security fixes, UX fixes.

## 2. Set up on your machine (Claude Code CLI)

```bash
git clone https://github.com/aasheesh333/OvidAI.git && cd OvidAI
git fetch origin review/screen-audit fix/model-catalog-recovery perf/streaming-rebuilds hoplite/gortyn-77773150
git checkout review/screen-audit
# Toolchain used for verification (match CI):
#   Flutter 3.47.4 stable  ->  flutter pub get
#   Python 3 + pip install -r server/images/requirements.txt pytest
claude
```

## 3. Paste this into Claude Code to resume

```text
Resume the Ovid work exactly where the previous session stopped. Read
docs/screen-review/RESUME.md, README.md and 00-master-plan.md first.

Step 1: finish the paused screen review on branch review/screen-audit.
For each file 01..08 in docs/screen-review/, launch one background agent
(8 in parallel). Give each agent this brief:
  "Read docs/screen-review/README.md (format/goal) and your file
  docs/screen-review/<NN-name>.md. Work out which screens are already
  covered, then continue with the uncovered items in your group's scope
  (README.md scope table, plus RESUME.md section 1 'Remaining'). Read the
  source files IN FULL (Read with offset/limit, ~400 lines at a time),
  not excerpts. Append each screen's section to your file as soon as it is
  reviewed (incremental writes). Every finding: P0/P1/P2 · category ·
  file:line · problem · user impact · concrete fix. Finish with a 'Group
  summary' (top 10 fixes, effort S/M/L) and set Status to complete. Only
  edit your own file; no git, no flutter, no other file changes."
While the agents run, commit and push docs/screen-review after each agent
finishes. Use commit messages ending in [skip ci]. Never commit app code on
this branch.

Step 2: when all 8 are complete, write docs/screen-review/09-consolidated.md:
every P0/P1 across groups, de-duplicated and ordered into PRs. Commit and push.

Step 3: stop and show me the summary. Do NOT start code changes, open PRs
or deploy anything until I say so.
```

## 4. After the review (only when the user says)
1. Open PRs for `fix/model-catalog-recovery` and `perf/streaming-rebuilds` (base `hoplite/gortyn-77773150`), or run the "Validate and Build Android" workflow manually on them.
2. VPS: run Claude Code on the server (`claude remote-control` inside `tmux`, in `/opt/ovid-gateway`) and paste `VPS_HANDOFF_PROMPT.md`.
3. Continue the master plan PR order: SQLite history → MCP/plugin parity + usage tracking → security → UX/l10n → remaining parity and features.

## 5. Security reminder
The VPS root password was shared in a chat. Rotate it and switch SSH to key-only login.
