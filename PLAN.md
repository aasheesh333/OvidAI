# Ovid AI ↔ DSH Web (deepseek-harness) — Parity, Bugs & Roadmap

> Mobile Flutter reimplementation of the DSH web IDE, written as our own original code.
> Branch: `ci/verified-android-build-20260827`
> Research base: 160+ `@deepseek-ai/dsh-*` packages on disk at `/home/ubuntu/dshweb/node_modules/.pnpm/`
> Status legend: DONE = done · HALF = partial · MISS = missing · BROKEN = broken · PLUS = Ovid-only (beyond DSH)
> Verify with: `export PATH="/home/ubuntu/sdk/flutter/bin:$PATH" && flutter analyze && flutter test`

---

## 0. Deep Code Audit — Round 2 (line-by-line)

A full read of `agent_service.dart` (6.8k lines), `chat_screen.dart` (4.6k lines), `state.dart`,
`commands.dart`, `mcp_service.dart`, `skills.dart`, `sandbox_service.dart` against the DSH behavior
specs in §2. Findings below are code-level defects, separate from the feature gaps in §3.

### Fixed in this pass

| # | Defect | Root cause | Fix |
|---|---|---|---|
| A1 | Model's whole reply discarded every 12th turn | soft turn budget `continue`d immediately after `_callLlm`, skipping tool-call processing, the final answer, and `_finalizeLive()`; the live bubble was orphaned as a permanent spinner | budget is recorded as `budgetBoundary` and applied at the END of the iteration |
| A2 | Stop during an approval hung the run forever | `cancelRun()` never completed `pendingApproval.completer`, so the awaiting tool never returned and `activeRunId` stayed set | `cancelRun()` resolves the pending completer with `false` |
| A3 | Every subagent hijacked global app hooks + leaked a timer | `AgentService._internal()` ran the full singleton constructor: re-pointed `onSessionDeleted`/`onSessionSwitched` at a child that gets disposed, started a 1s schedule timer per child, and had no `dispose()` | child constructor flag skips global wiring; `dispose()` cancels the timer |
| A4 | All earlier tool output was dropped from the request | history replay mapped `Message.content`, but tool rows keep text in `toolDetail` → a run of EMPTY assistant turns and zero memory of prior reads/edits | `_replayHistory()` renders tool rows as `[tool <name>] <summary>` + output, with per-kind budgets |
| A5 | Duplicate `repo_sync`/`repo_tree` in every request | added by `_coreTools` AND again by the `githubSync` gate | core loop skips repo tools; the gate is the only source |
| A6 | `schedule_create` crashed on `after_seconds: 0` | 0 passed validation then hit `Duration(seconds: every!)` on a null | explicit `after_seconds >= 1` check |
| A7 | Reminders were appended but never acted on | `_fireDueSchedules` called `sendMessage` and never `runTask`; also wrote `activeSessionId` directly, skipping persistence | appends + `selectSession` + `runTask`, and frames the reminder as untrusted data |
| A8 | Schedule `at` had no timezone story | naive local parse only | accepts local `YYYY-MM-DD HH:MM` and full ISO-8601 with offset/Z |
| A9 | `../` escaped the per-session workspace | every path was `'${work.path}/$rel'` with no normalization | `containedPath()` normalizes and refuses anything outside `work` |
| A10 | glob/grep could hang, OOM, or mis-count | `followLinks: true` (symlink cycles), unbounded `readAsString`, context lines eating the match cap, alphabetical order, O(n²) de-dupe, no include filter | `followLinks: false`, 2 MB skip, cap counts matches, mtime-desc order, `Set` de-dupe, `include` glob param, structured `SEARCH_BAD_PATTERN` |
| A11 | Background runs wrote into the foreground session | `_studio` and `browserTabs` resolved through `AppState.activeSession` instead of the run's session | both resolve through `_runSession` (run Zone) first |
| A12 | Copy button reported success and copied nothing | action row is shown for tool rows, whose `content` is always empty | `_copyText()` falls back to `toolName`/`toolSummary` + `toolDetail`; the button hides when there is nothing to copy |
| A13 | Plan card showed framing prose | it stripped Hinglish markers (`AI ka plan:`) the emitter no longer produces | `ApprovalRequest.planBody` carries the raw plan |
| A14 | "Change folder" lost the pinned folder on cancel | it cleared the folder BEFORE opening the picker | picker writes only on success |
| A15 | A permanent fake "Loading earlier…" spinner | the row rendered whenever `hidden > 0`, never consulting `_paging` | spinner only while paging; otherwise a scroll-up affordance with the hidden count |
| A16 | Retries/backoff were invisible | `AgentService.events` is rendered by no UI file, so "retrying in 9s" never reached the user | `_AgentRun.statusLine` + `statusFor(sessionId)` feed the typing row |
| A17 | Subagents were opaque and half-broken | a child ran on a second `AgentService` with its own throwaway message list: no transcript to open, `interrupt_agent` was a no-op (child `activeRunId` never set), follow-ups restarted from scratch, and children inherited the parent's run Zone so they could raise approvals in the parent's composer | rewritten: a subagent is a REAL `ChatSession` (own transcript/tool cards/streaming/workspace) run through `runTask`, `cancelRunFor(sessionId)` stops it, follow-ups continue the same transcript, and children auto-approve while user-facing tools are refused |

### Known, not yet fixed (tracked)

| # | Defect | Where | Note |
|---|---|---|---|
| C1 | Compaction cannot shrink the in-flight request | `msgs` built once; `forceCompact` only inserts a summary | overflow recovery grows the request; auto-compaction only helps the NEXT run |
| C5 | Session todos never clear at turn start | `_runTaskBody` resets nudge/produced, not `s.todos` | stale checklist persists |
| C6 | No cache-read/cache-write token buckets, no tok/s, TTFT is first-turn only | `_runTaskBody` metering | Usage/stats parity gap |
| C7 | `file_write` writes only to RepoCache; `fs_edit create` only to disk | split write paths | `file_write` then `run_shell cat` fails |
| C8 | No spill store / output retention notices | truncation is inline with a bare `…` | see Phase H |
| C9 | No checkpoints / `TOOL_OUTCOME_UNKNOWN` | no persistence barrier | a kill mid-tool leaves rows spinning forever |
| C10 | `web_search` is single-query DuckDuckGo scraping, no URLs | `_webSearch` | DSH does 1-4 concurrent queries with citations |
| C11 | MCP: JSON-RPC errors returned as results; timeout yields `'null'`; no dead-process watcher | `mcp_service.dart` | reliability gap |
| C12 | Dead `MsgKind` branches (`code`, `imageGen`, `turnTail`) never constructed | `chat_screen.dart` | image-gen placeholder (B3) is unreachable |

---

## 1. Bug & Issue List

| # | Sev | Issue | Location | Status |
|---|-----|-------|----------|--------|
| B1 | P0 | Marketplace catalog never loaded: `fetchMarketplaceCatalog` was only reachable from the agent command, never from the Plugins screen, and `addMarketplace` just appended a name. Now: registry persists (`ovid_marketplaces_v1`), the screen merges catalogs on open, has a refresh action, and the add sheet fetches + reports. | `lib/core/state.dart` marketplaces block · `lib/ui/plugins_screen.dart` | DONE |
| B2 | P1 | Copy button copied an empty string on tool/turn rows while still showing "Copied to clipboard". | `lib/ui/chat_screen.dart` `_copyText`/`_actionRow` | DONE |
| B3 | P1 | Image gen renders a dummy gradient placeholder and `_imageGenTool` produces no real image. Also unreachable — nothing constructs `MsgKind.imageGen`. | `chat_screen.dart` `_imageGen` · `agent_service.dart` `_imageGenTool` | BROKEN |
| B4 | P2 | Markdown tables overflowed (no horizontal scroll). Now `IntrinsicColumnWidth` + styled borders. | `chat_screen.dart` `_DshMarkdown` | DONE |
| B5 | P2 | Reasoning text too large/heavy vs DSH. Now 12.5px muted body via `_DshMarkdown(fontSize:, color:)`. | `chat_screen.dart` `_ReasoningCard` | DONE |
| B6 | P1 | Links not clickable, text not selectable. Now `selectable: true` + `onTapLink` (http(s) → in-app browser, others → `url_launcher`), user bubbles use `SelectableText`. | `pubspec.yaml` · `chat_screen.dart` | DONE |
| B7 | P2 | No Google sign-in (email/password only, no `google_sign_in` dep). | `lib/ui/auth_screen.dart` | MISS |
| B8 | P1 | No subagent UI: a child's work was invisible (one count in the folded turn strip). Now every subagent is a real session with its own screen — transcript, lineage breadcrumb, descendants menu, status strip, read-only one-shot vs continuable composer with an independent Stop — reachable from the card's Open link, the AppBar Agents badge, or `@` in the composer. | `lib/ui/subagent_screen.dart` · `chat_screen.dart` `ChatTranscript`/`_ToolCard` | DONE |
| B9 | P2 | Browser cookies/localStorage shared across sessions (tabs are per-session, the WebView profile is global). | `agent_service.dart` browser block | HALF |
| B10 | P2 | No browser viewport-resize tool. | `lib/ui/browser_screen.dart` | MISS |
| B11 | P1 | Attach sheet: removed 'Camera' (dead stub) and 'Pick folder'; kept Photos & videos / Document / Generate image. Folder pinning stays on the working-folder chip. | `chat_screen.dart` `_attachSheet` | DONE |
| B12 | P2 | Slash menu was prefix-only, never opened on a bare `/`, and listed only builtins + skills. Now: opens on `/`, fuzzy-ranked, grouped Commands / Skills / MCP tools / Plugins. | `chat_screen.dart` `_suggestions` | DONE |
| B13 | P2 | No post-clone workspace pick. Now Studio asks "sandbox or pick a folder" after a repo is bound + synced, with write probing and All-Files-Access retry. | `lib/ui/studio_screen.dart` `_offerWorkspaceFolder` | DONE |
| B14 | P3 | Usage screen has no charts and no live counter; stats line lacks cache-hit and tok/s and aggregates globally. | `lib/ui/usage_screen.dart` · `chat_screen.dart` `_StatsLine` | HALF |
| B15 | P3 | No cordis-style global approval overlay (badge / inventory / inspect). The approve/deny dock exists but does not lock the composer. | `chat_screen.dart` `_ApprovalDock` | HALF |
| B16 | P2 | Plan review had no "Chat about it" and re-parsed framing prose. Now three actions (Chat about it / Decline / Approve) and the refusal note is handed back to the model. | `chat_screen.dart` `_PlanReviewCard` · `agent_service.dart` `_handleExitPlanMode` | DONE |
| B17 | P2 | `/model` and `/permission` commands were missing (DSH has both, with a Full-access acknowledgement). | `lib/core/commands.dart` | DONE |

---

## 2. DSH Web A-to-Z Feature Inventory


Every user-visible feature DSH web ships, derived from the installed package set.

| # | DSH feature | Owning package(s) | What the user sees |
|---|---|---|---|
| 1 | Sidebar shell | `ui-sidebar` | Brand row, New Session, 56px collapse rail, pinned Settings seat, pointer-affordance scrollbars |
| 2 | Workspace browser | `ui-workspace`, `workspace` | Workspaces grouping sessions, 5-row default + Show more, Manual/Last-updated ordering, drag reorder, rename/fork/archive/delete, debounced content search with snippets, status dots (waiting approval / running / unviewed completion) |
| 3 | Conversation shell | `ui-conversation` | Session header (title, lineage seat, actions), view tabs, sticky composer stack, empty-state dashed card opening the workspace picker |
| 4 | Streaming chat + Think row | `ui-conversation` | Grouped step summaries, streaming tail isolation, live reasoning-tail summary, retry rows with shimmer + countdown |
| 5 | Context meter + stats line | `ui-conversation`, `token-meter` | 14px occupancy ring, click-open breakdown (percent used, segmented bar), tokens / cache hit / TTFT avg / tok-s with tooltips |
| 6 | Todo dock | `tool-todo` | Collapsed strip: title + per-status counts, cleared at next turn start |
| 7 | Queue dock | `ui-conversation` | Collapsed "N queued messages", per-row edit / delete / strict-steer, Enter vs Cmd+Enter queue-or-steer |
| 8 | Plan mode | `plan-mode`, `ui-plan` | `/plan` toggle, amber "Plan x" chip, plan-task placeholder, `exit_plan_mode` review card with Chat about it / Refuse / Approve |
| 9 | Subagent lineage UI | `ui-subagent`, `tool-subagent` | Breadcrumb (current + ancestors), descendant-count dropdown, lazy catalog tree with keyboard nav, per-row mode/activity/tokens/live duration, read-only one-shot composer, continuable child composer with independent Stop, `@` mention of running subagents |
| 10 | Workflow run tree | `ui-workflow-run`, `tool-workflow`, `workflow` | Run → phase → member disclosure tree, state dots, auto-open running/failed, underlined running member opens child session |
| 11 | Ralph loop | `tool-ralph` | Fixed foreground loop of fresh child agents on one immutable objective, bounded handoff per round |
| 12 | Goal bar | `goal`, `tool-goal`, `ui-goal` | Goal strip in composer dock with edit / pause / resume / clear, `command-input` bubble for `/goal` runs, blocked_reason after N blocked rounds |
| 13 | Background jobs | `jobs`, `tool-jobs`, `ui-jobs` | Header trigger with running+stopping badge, popover rows (producer kind, label, status, per-second elapsed), `job_output/list/kill`, completion notices |
| 14 | Tool presentation | `ui-tool`, `agent-tool-presentation` | Recursive root/subcall call trees, render-intent cards (terminal, read, diff, search, web), lifecycle states, cwd-relative paths with `~`, ToolDetails inspector |
| 15 | Deliverables | `ui-deliverables` | Turn-tail "produced files" chip lane (up to 6 + "+N files"), Show in folder, clickable inline-code file references |
| 16 | Message feedback | `message-feedback`, `ui-message-feedback` | Like/Dislike in the assistant action row + note popover, CAS versioning, retract by re-click |
| 17 | User questions | `tool-ask-user`, `user-questions`, `ui-user-questions` | One-question-at-a-time card, single/multi select, recommendation badges, custom-answer textarea, Skip, plan-review approval card |
| 18 | Skills | `skill`, `tool-skill`, `ui-skill`, `skill-filesystem`, `skill-badge` | `/`-menu skill source with user-only markers, skill tool row with expandable Instructions card |
| 19 | Model selection | `ui-model-selection` | Composer trigger → two-level Model/Effort menu, provider-grouped, `/model` popupSelect, block row when no adapter routable |
| 20 | Permission presets | `permission-presets`, `ui-permission-presets` | `/permission` picker (title-cased preset names), General-settings default row, Full-access risk acknowledgement |
| 21 | Approval panel | `user-approval`, `ui-cordis`, `tool-cordis` | Composer takeover amber strip with Refuse/Allow, cordis badge, plugin inventory, inspect |
| 22 | Trajectory view | `ui-trajectory` | Event-ledger tab: User/Assistant/Tool/Subtool records, turn rules, per-record inspector (tokens, duration, Input, Output, Timing), timeline Overview with drag-focus + wheel zoom, older-page loader |
| 23 | Session log export | `session-log-export` | `/export` + header button → streamed ZIP (JSONL/zstd logs, descendants, attachments) |
| 24 | Directory picker | `host-directory-picker*`, `ui-directory-picker-*` | Native or browse picker, workspace-add flow with retryable "Choose again" dialog |
| 25 | Settings domain | `settings`, `ui-settings*` | Schema-driven pages: General, Models, Plugins, Plugin inventory, onboarding, revision-fenced single-field writes |
| 26 | Brand / connection | `brand`, `ui-brand-official`, `client-connection` | Brand mark + name, build label, connection status, reset handling |
| 27 | Theme | `ui-theme` | Light / dark mode |
| 28 | Locale | `client-locale` | i18n (English / Chinese) |
| 29 | Cross-session search | `session-query-sqlite` | FTS5 literal-phrase search with ranked snippets, metadata filters, opaque cursors |
| 30 | LLM session titles | `session-title-llm`, `session-title-first-prompt-llm` | Auto-generated titles from the first prompt, budgeted, language-aware, thinking disabled |
| 31 | Web search / fetch | `tool-web`, `web-search-deepseek` | `web_search` (1-4 concurrent queries, deduped merged citations), `web_fetch` (HTML → markdown) |
| 32 | Precise file editor | `tool-str-replace-editor`, `tool-fs` | `view` / `create` / `str_replace` / `insert` on absolute paths, tab + line-number preserving |
| 33 | Glob / grep | `tool-fs-search` | ripgrep-backed `glob` (mtime-ordered) and `grep` (rg --json), capped with spill |
| 34 | Compaction | `compaction`, `compaction-basic`, `command-compact`, `compaction-tool-result-pruner` | `/compact` + automatic pressure compaction, summary replacement node, replayable raw log |
| 35 | Scheduled reminders | `schedule` | `schedule_create/list/delete` — one-shot delay, absolute time, 5-min+ interval, timezone-explicit |
| 36 | Checkpoints / crash recovery | `session-checkpoint-policy`, `session-persistence-jsonl`, `atomic-write` | Checkpoint before each LLM request and side-effecting tool; recovery supplies `TOOL_OUTCOME_UNKNOWN` |
| 37 | Spill + output retention | `spill`, `spill-local`, `spill-policy`, `output-retention` | Oversized tool output stored out-of-context, head/tail preview + "read with offset/limit or grep this path" locator |
| 38 | FS observation policy | `fs-observation-policy` | Read-before-edit (`FS_NOT_OBSERVED`), CAS version guard (`FS_STALE_VERSION`) |
| 39 | Session stats projection | `session-stats`, `session-projection*` | Whole-log turn/step counts, LLM/decode/first-token/tool wall times |
| 40 | Sandbox / shell | `sandbox`, `sandbox-local`, `sandbox-policy`, `bash-local`, `bash-sandbox`, `terminal-bash`, `tool-bash-persistent`, `tmux-context` | Terminal panel, persistent bash, landlock sandboxing, policy fences |
| 41 | MCP client | `mcp-client` | External MCP servers advertising tools |
| 42 | Plugin inventory | `host-plugin-inventory`, `ui-settings-plugin-inventory` | Installed plugin list, enable/disable, marketplace-style registry |
| 43 | Code runtime | `code-runtime`, `code-runtime-worker-thread`, `tool-cordis` | `run_code` in a worker/vm, live runtime inspect/define/run/stop |
| 44 | Attachments | `attachment`, `attachment-local`, `ui-attachment` | Local file attachments referenced into a session |
| 45 | File references | `file-reference`, `session-reference`, `ui-reference` | `@file` and `@session` autocomplete with section headings, atomic inline chips, `@"path with spaces"` |
| 46 | Commands API | `commands`, `ui-commands` | `/` menu with fuzzy ranking, execute / popupSelect / leadingInput kinds, image-envelope enforcement |
| 47 | Credentials | `credentials`, `credentials-local`, `authorization` | Stored provider credentials, auth fences |
| 48 | Telemetry | `session-telemetry`, `session-telemetry-otel`, `anonymous-user-id` | Optional OTEL export |
| 49 | Persona / presets | `persona`, `agent-presets`, `ui-agent-preset` | Preset stacks (standard / minimal / cordis / code), seats, per-agent persona overrides |
| 50 | Timeouts / retries | `timeout`, `tool-call-timeout-policy`, `llm-retry`, `repeat-tool-reminder` | Per-tool timeout budgets, retry with countdown, repeated-tool reminders |

---

## 3. Ovid ↔ DSH Comparison Matrix

| # | DSH feature | Ovid status | Evidence |
|---|---|---|---|
| 1 | Sidebar shell | HALF — sessions list, search, new, rename, delete; no 56px rail, no pinned settings seat | `sidebar.dart` |
| 2 | Workspace browser | MISS — no workspace grouping / archive / fork / drag-reorder / content search | — |
| 3 | Conversation shell | HALF — header + composer; no lineage seat, no view tabs, no workspace empty-state card | `chat_screen.dart` |
| 4 | Streaming + Think row | DONE — streaming, folded step summaries, live `_ReasoningCard`, and the typing row now shows the live run status (retry/backoff/compaction) instead of a fixed label | `chat_screen.dart` `_ReasoningCard`/`_TypingBubble`, `agent_service.dart` `statusFor` |
| 5 | Context meter + stats | HALF — `_StatsLine` occupancy ring (12px) + tooltip breakdown + Input/Output/decode/TTFT; no click-open panel with segmented bar, no cache-hit, no tok/s, TTFT is first-turn only, totals aggregate across sessions | `chat_screen.dart` `_StatsLine` · `usage_screen.dart` |
| 6 | Todo dock | DONE — `todo_write` + mid-run pending-todo nudge | `agent_service.dart:1719-1743,3255-3281` |
| 7 | Queue dock | DONE — queue + strict steer + drain | `agent_service.dart:236,448-533` |
| 8 | Plan mode | HALF — `/plan` toggle, `exit_plan_mode` gated on review, and a Chat about it / Decline / Approve card whose refusal note reaches the model; no composer "Plan x" chip, no plan-task placeholder, `planMode` is not persisted across restart | `agent_service.dart` `_handleExitPlanMode` · `chat_screen.dart` `_PlanReviewCard` |
| 9 | Subagent lineage UI | DONE — child sessions with full transcripts, breadcrumb to the root chat, descendants menu with state/elapsed/rows, read-only one-shot composer, continuable composer with independent Stop, `@` mention of this chat's agents, parent card links into the child; still no keyboard-nav catalog tree and no per-child token totals | `lib/ui/subagent_screen.dart`, `chat_screen.dart` |
| 10 | Workflow run tree | MISS — no run/phase/member tree | — |
| 11 | Ralph loop | MISS | — |
| 12 | Goal bar | HALF — `get_goal`/`create_goal`/`update_goal` tools; no GoalBar strip with pause/resume/clear | `agent_service.dart` goal cases |
| 13 | Background jobs | HALF — `job_start/output/list/kill` + `_BgJob`; no header badge + popover | `agent_service.dart:178` |
| 14 | Tool presentation | HALF — `_ToolCard` rows with lifecycle dots + terminal/diff detail intents; no recursive subcall tree, no read/search/web intent cards, no details inspector, paths not cwd-relative | `chat_screen.dart` `_ToolCard`/`_DetailBody` |
| 15 | Deliverables | HALF — turn-tail chip lane with 6-chip cap, "+N files" sheet, and tap-opens-that-file in Studio; no Show-in-folder, no clickable inline-code refs, not persisted per turn | `chat_screen.dart` `_ProducedFilesCard` |
| 16 | Message feedback | MISS — no like/dislike/note | — |
| 17 | User questions | DONE — `ask_user_question` + structured question card | `agent_service.dart:125-139,1750` |
| 18 | Skills | DONE — `skills.dart` + SkillsScreen + `/`-invocable skills | `skills.dart`, `settings_screen.dart:897,1041` |
| 19 | Model selection | HALF — AppBar picker with per-model effort variants + `/model` command; no composer-seat trigger, no routable-block row | `chat_screen.dart` `_ModelPickerSheet`, `commands.dart` |
| 20 | Permission presets | DONE — `AgentMode` presets + mode sheet + `/permission [preset]` with kebab-case names and a Full-access `confirm` acknowledgement | `commands.dart`, `chat_screen.dart` `_ModeChip` |
| 21 | Approval panel | MISS — auto-run toggle only | `settings_screen.dart:204` |
| 22 | Trajectory view | MISS — no event ledger tab | — |
| 23 | Session log export | HALF — Export chats (JSON); no ZIP with logs + attachments + descendants | `settings_screen.dart:799` |
| 24 | Directory picker | DONE — working-folder chip → `_pickFolderDirect` with All-Files-Access retry | `chat_screen.dart:3852` |
| 25 | Settings domain | DONE — full settings tree (account, providers, plugins, memory, reasoning, GitHub sync, auto-run, skills, privacy, theme, timeout, context/output, export, delete) | `settings_screen.dart` |
| 26 | Brand / connection | HALF — branding present; no connection-status chip / reset handling | — |
| 27 | Theme | DONE — dark default + light theme toggle | `settings_screen.dart:530` |
| 28 | Locale | MISS — English only | — |
| 29 | Cross-session search | HALF — sidebar title search + `session_search` tool; no FTS5 content search with snippets | `sidebar.dart:115`, `agent_service.dart` |
| 30 | LLM session titles | HALF — first-message heuristic `_autoTitle`; no LLM-generated title | `state.dart:1055-1081` |
| 31 | Web search / fetch | HALF — `web_search` is one DuckDuckGo query capped at 8 results with no URLs; `fetch_url` strips tags to plain text, not markdown; both are gated behind installed plugins | `agent_service.dart` `_webSearch`, `fetch_url` |
| 32 | Precise file editor | DONE — `fs_edit` view/create/str_replace/insert, numbered `view`, single-occurrence enforcement, read-before-edit, and workspace path containment | `agent_service.dart` `_handleFsEdit`, `containedPath` |
| 33 | Glob / grep | DONE — `fs_glob` (mtime-desc, capped, symlink-safe) + `fs_grep` (`include` glob, match-based cap, 2 MB skip, `SEARCH_BAD_PATTERN`); no ripgrep backend, no spill | `agent_service.dart` `_handleFsGlob`/`_handleFsGrep` |
| 34 | Compaction | DONE — `/compact` + `MsgKind.compact` row | `commands.dart:113-124` |
| 35 | Scheduled reminders | DONE — `schedule_create/list/delete`, one-shot + interval, ISO-with-offset accepted, delivery starts a real run and frames the reminder as untrusted data | `agent_service.dart` schedule block |
| 36 | Checkpoints / recovery | MISS — no checkpoint policy, no `TOOL_OUTCOME_UNKNOWN` semantics | — |
| 37 | Spill + retention | MISS — no spill store; outputs truncated inline without locator | — |
| 38 | FS observation policy | HALF — read-before-edit enforced with an `FS_NOT_OBSERVED` code; no version CAS, so `FS_STALE_VERSION` does not exist | `agent_service.dart` `_handleFsEdit` |
| 39 | Session stats projection | HALF — usage log aggregation; no turn/step/TTFT wall-time projection | `usage_screen.dart` |
| 40 | Sandbox / shell | DONE — native Linux sandbox, multi-terminal, per-session workspaces, `run_shell`, `job_start` | `sandbox_service.dart:92-124`, `studio_screen.dart:740` |
| 41 | MCP client | DONE — `McpService` JSON-RPC 2.0 (connect / tools-list / tools-call / disconnect) | `mcp_service.dart:15-158` |
| 42 | Plugin inventory | DONE — PluginsScreen + categories + MCP config import + persisted marketplace registry that merges catalogs on open and on refresh | `plugins_screen.dart`, `state.dart` marketplaces block |
| 43 | Code runtime | DONE — `run_code` + `preview` | `agent_service.dart` run_code |
| 44 | Attachments | DONE — attach files into session workspace + chips in chat | `agent_service.dart:1101`, `chat_screen.dart` `_attachmentChips` |
| 45 | File references | MISS — no `@file` / `@session` autocomplete | — |
| 46 | Commands API | HALF — `CommandService` builtins incl. `/model` + `/permission`; `/` menu opens on a bare slash with fuzzy ranking and Commands/Skills/MCP/Plugins groups; no popupSelect overlay, no image-envelope enforcement | `commands.dart`, `chat_screen.dart` `_suggestions` |
| 47 | Credentials | DONE — secure key storage per provider + GitHub token persistence | `providers_screen.dart:248`, `github_service.dart:110` |
| 48 | Telemetry | PLUS — health service instead of OTEL | `health_service.dart` |
| 49 | Persona / presets | MISS — single design, no preset stack or seats | — |
| 50 | Timeouts / retries | HALF — AI response timeout setting; no per-tool timeout budgets, no repeat-tool reminder | `settings_screen.dart:552` |

### Ovid-only features (beyond DSH web) — PLUS

| Feature | Evidence |
|---|---|
| Browser automation suite — `browser_navigate/click/evaluate/read/scroll/type/press_key/wait_for/snapshot/open/new_tab/list_tabs/switch_tab/close_tab` (DSH only has `web_fetch`) | `agent_service.dart:1291-1349`, `browser_screen.dart` |
| 16 mobile device tools — camera, photos, videos, audio, microphone, contacts, sms, phone, location, sensors, bluetooth, calendar, notifications, storage, activity_recognition, request_permission | `agent_service.dart` permission cases |
| Memory — `memory_save` / `memory_search` + Memory settings page | `agent_service.dart`, `settings_screen.dart:137` |
| GitHub integration — device-flow OAuth, repo list/bind/sync/commit, Studio IDE with file tree + editor + tabs | `github_service.dart`, `repo_cache.dart`, `studio_screen.dart` |
| Firebase auth — email/password account layer | `auth_screen.dart` |
| Usage & cost — provider-wise real tokens, Today, in/out banner, USD estimate | `usage_screen.dart` |
| Health screen — runtime diagnostics | `health_screen.dart`, `health_service.dart` |
| Agent notifications — Android notification service for background runs | `agent_notification_service.dart` |
| Catalog self-service tools — `catalog_add_provider/mcp/plugin/marketplace`, `agent_install_mcp`, `agent_install_plugin` | `agent_service.dart` catalog cases |
| Image generation tool | `agent_service.dart:2392` (placeholder rendering — B3) |

---

## 4. Architecture Compliance Verdict

DSH stack: SPA frontend (`apps/web` over `dsh-client-web`) → host server (`dsh --profile web`, `dsh-host-webserver`, `dsh-api-gateway`) → agent core (`dsh-agent`, `dsh-agent-loop`) → capability seams (`ctx.fs`, `ctx.jobs`, `ctx.web`, `ctx.subagents`, `ctx.spillStore`, ...) with a Service-Definition / Provider / Consumer package split.

| Layer | DSH | Ovid | Verdict |
|---|---|---|---|
| Frontend | React SPA + Cordis client plugins | Flutter widgets | HALF — reimplemented, not the same stack |
| Host server | webserver + api-gateway + trust fence | none — agent loop in-app | DONE — correctly adapted for mobile |
| Agent core | `dsh-agent-loop`, `dsh-agent-instructions` | `agent_service.dart` run loop + system prompt | DONE |
| Tool registry | ~40 tool packages over seams | ~70 tool cases in one switch | DONE functionally, HALF architecturally (monolith vs plugins) |
| Session model | event-sourced log + projections | `AppState` sessions + SharedPreferences | HALF — no event sourcing, no projections, no checkpoints |
| Sandbox | landlock + policy layers | native Linux sandbox + per-session workspaces | DONE |
| Capability seams | `ctx.*` service definitions | direct service singletons | HALF — no seam indirection (harder to swap providers) |
| Context engineering | token-meter + compaction + spill + retention | compaction only | HALF — spill/retention/meter missing |
| Presets / persona | preset stacks + seats + persona rows | single fixed design | MISS |
| Approval / permission | user-approval + presets + cordis overlay | AgentMode enum + auto-run toggle | HALF |

**Verdict:** Ovid follows DSH's agent-core and tool-surface architecture faithfully — run loop, streaming, queue, todos, plan mode, ask-user, compaction, jobs, skills, MCP, web search, fs tools, glob/grep, goals, schedule, subagent dispatch, and sandbox are all present and behave like DSH. Ovid also exceeds DSH on mobile: full browser automation, 16 device tools, memory, GitHub/Studio, usage costing.

What Ovid does **not** yet follow is DSH's **session-domain and presentation depth**: event-sourced projections (trajectory, session stats, checkpoints), context engineering (spill, retention, cache-aware metering), and parts of the presentation layer (workspaces, feedback, subagent lineage, workflow tree, jobs popover, recursive tool call-trees, `@` references, approval takeover, presets).

**A-to-Z coverage after this pass: roughly 68% overall — core ~92%, presentation/session-domain ~45%.**
(Was ~60% / ~90% / ~35% before the round-2 audit fixes.)

---

## 5. Roadmap

### Phase A — Functional core fixes (DONE)
1. **B11** attach sheet cleaned (Camera + Pick folder removed; Photos/Document/Generate image kept).
2. **B13** post-repo workspace pick in Studio (sandbox or a real folder, with write probing).
3. **B12** `/` menu opens on a bare slash, fuzzy-ranked, grouped Commands / Skills / MCP tools / Plugins.
4. **B1** marketplace registry persists, merges catalogs on screen open, refresh action, add-sheet fetches and reports.
5. **B17** `/model` and `/permission` commands (Full access needs an explicit `confirm`).
6. Audit fixes A1-A16 in section 0 (run loop, cancel, subagents, history replay, fs containment, glob/grep, session scoping, copy, plan card, spinner, status line).

### Phase B — Rendering / text / images / copy (mostly DONE)
7. **B5** DONE — reasoning body is 12.5px muted.
8. **B4** DONE — tables use intrinsic columns inside a horizontal scroller.
9. **B6** DONE — selectable prose, clickable links (in-app browser for http(s), `url_launcher` otherwise).
10. **B2** DONE — copy falls back to tool name/summary/detail and hides when empty.
11. **B3** Real generated image in-chat, and construct `MsgKind.imageGen` so the branch is reachable at all.

### Phase C — Browser / session / subagents / usage / auth
12. **B10** Browser viewport-resize tool.
13. **B9** Per-session cookie isolation (research WebView profile limits; document or accept).
14. **B8** Subagents screen over `_BgSubagent`.
15. **B14** Live token counter + charts in Usage; per-session (not global) stats line.
16. **B7** Google sign-in (`google_sign_in` + `FirebaseAuth.signInWithCredential`).
17. **C1** Make compaction prune the in-flight request (today overflow recovery grows it).
18. **C2/C3/C4** Subagent lifecycle: real interrupt, continuable children with history, no child-raised approvals.
19. **C5** Clear session todos at turn start.
20. **C7** One write path for `file_write` / `fs_edit create` (disk + repo cache).

### Phase D — DSH parity: chat UX (highest user value)
21. **Deliverables** — DONE chip lane; still missing Show-in-folder, clickable inline-code refs, per-turn persistence.
22. **Message feedback** — like/dislike + note popover per finalized assistant message.
23. **Context meter** — click-open breakdown panel with segmented bar; cache-hit + tok/s + TTFT average.
24. **LLM session titles** — async title generation from the first prompt (budgeted, thinking disabled).
25. **Session log export** — `/export` → ZIP with session JSONL + attachments + descendants.
26. **Tool call-trees** — recursive subcall rendering + read/search/web render-intent cards + details inspector + cwd-relative paths.

### Phase E — DSH parity: subagents & workflows
22. Subagent lineage breadcrumb + descendant dropdown + catalog tree (mode, activity, tokens, live duration).
23. Read-only one-shot child composer + continuable child composer with independent Stop.
24. `@` reference of running subagents in the composer.
25. Workflow run tree card (run → phase → member, auto-open running/failed, tap member → open child session).
26. Jobs header badge + popover (producer, label, status, per-second elapsed).
27. Goal bar strip with edit / pause / resume / clear.

### Phase F — DSH parity: input & commands
33. Fuzzy `/` matcher — DONE (prefix-first, subsequence, gap/adjacency ranking, grouped sources).
34. `/model` + `/permission` — DONE as commands; still no popupSelect overlay picker.
35. `@file` and `@session` autocomplete with section headings, atomic inline chips, `@"path with spaces"`, directory descent.
36. Image paste/drop into the composer with drop overlay + limit banners.
37. Strict-steer queue rows + Enter vs Cmd+Enter queue-or-steer.
38. Approval panel — composer takeover with Refuse/Allow + badge + inventory (today it is a dock that leaves the composer live).

### Phase G — DSH parity: session domain
39. Workspace registry — group sessions by workspace, rename/fork/archive/delete, drag reorder, Show more, status dots.
40. FTS5 cross-session content search with ranked snippets and cursors.
41. Trajectory tab — event ledger with per-record inspector (tokens, duration, input, output, timing) + timeline overview.
42. Checkpoint policy — save before each LLM request and side-effecting tool; `TOOL_OUTCOME_UNKNOWN` on recovery (C9).
43. Session stats projection — turn/step counts, TTFT, decode wall times.
44. Conversation shell — session title in the header, lineage seat, Chat/Trajectory tabs.

### Phase H — DSH parity: context engineering
45. Spill store — persist oversized tool output to the session workspace; return head/tail preview + locator hint (C8).
46. Output retention — head/tail truncation with exact omission notices for glob/grep/shell/web tools.
47. FS observation CAS — version guard with `FS_STALE_VERSION` retry (read-before-edit already enforced).
48. Per-tool timeout budgets + repeat-tool reminder; timeouts on approval/question waits.
49. `web_search` — concurrent queries, dedupe, real citation URLs; `fetch_url` → markdown (C10).
50. MCP reliability — surface JSON-RPC errors as errors, watch for dead processes, honour `tools/list_changed` (C11).

### Phase I — Polish
51. Locale support (English + Hindi).
52. Presets / persona (optional — evaluate whether mobile needs preset stacks).
53. Ralph loop tool (optional, gated on explicit user request like DSH).

**Verification gate after every phase:** `flutter analyze` (0 issues) + `flutter test` (104 tests) + commit + push + CI green on `ci/verified-android-build-20260827`.

---

## 6. Open Questions
1. Roadmap order — Phase D (chat UX: deliverables, feedback, context meter, titles, export) before Phase E (subagents / workflows)? Current draft assumes yes.
2. FTS5 search needs `sqlite3_flutter_libs` (~2 MB APK). Acceptable?
3. Trajectory ledger implies event-sourced session history — a full rewrite is risky. Ship an inspector-only view over the existing message list first?
4. Presets / persona and Ralph — worth it on mobile, or intentionally skip?
5. Per-session browser cookie isolation may be impossible with a single WebView profile. Accept the limitation and document it?
