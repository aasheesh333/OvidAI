# Task 19 — Delete `agent_service.dart` + test-suite triage

**Status:** DONE
**Branch:** `feat/ovid-cloud`
**Scope commit:** `refactor(app): delete agent_service.dart; type re-homing and test-suite triage`

## Scope landed

- `lib/core/agent_service.dart` (14,793 lines) deleted. It was the last local
  execution path; `CloudAgentFacade` is now the ONLY `AgentSurface`
  implementation.
- The surviving value types moved to `lib/core/cloud/models.dart`.
- `connection_service.dart` no longer imports the retired file: its
  reachability probe is a plain `HttpClient` GET (4 s timeout, 1 KiB drain,
  200/204 accepted) against the same fixed `generate_204` CDN URL. No
  redirect guard was ported: the target is fixed and public, while
  `HttpShim`'s redirect/SSRF policy existed for arbitrary agent fetches.
- Studio reset and per-account cache resets re-pointed (see mapping below).
- Every consumer/comment in `lib/` and `test/` now names `CloudAgentFacade`
  or "the retired local service"; the acceptance greps are empty.

## Type moves (verbatim except `control`)

Into `lib/core/cloud/models.dart`:

| Type | Change |
|---|---|
| `AgentMode` | `{safe, auto, drive, studio}` — `control` arm deleted |
| `AgentModeX` | `label`/`hint`/`icon`/`color`; all four `control` arms deleted |
| `modeOptionsForPicker()` | `control` filter deleted; `safe` still excluded from the picker |
| `ApprovalRequest` | verbatim (incl. `questions`, `planBody`, `answers`, `modeName`) |
| `UserQuestion`, `QuestionOption` | verbatim |
| `BgJob` | verbatim (imports `dart:io` for `Process`) |
| `SubagentInfo` | verbatim |
| `QueuedMessageSnapshot` | **added**: the brief's list omitted it, but `AgentSurface.takeQueuedMessages` cannot compile without it |

Consumer fixes for the retired `control` member:

- `lib/core/commands.dart` — dead `target == AgentMode.control` guard and its
  unreachable feedback string removed; `/permission` hint no longer lists
  `control`.
- `lib/core/cloud/cloud_agent_facade.dart` — `if (candidate == AgentMode.control)
  continue;` removed.
- `lib/core/state.dart` — `ChatSession.mode` doc no longer lists `control`.
- `test/play_distribution_test.dart` — asserts
  `AgentMode.values.map((m) => m.name)` does not contain `'control'` (the
  enum member no longer exists to reference).

Pure helpers that surviving UI still needs were re-homed rather than
re-creating a runtime:

- `ModelLimits.contextWindowFor` + `ModelLimits.effectiveContextWindow`
  (with the keyword table) moved into `lib/core/model_limits.dart`.
  `contextWindowForSession`/`contextOverrideAppliesTo` collapsed at their
  call sites onto `s.model` — the local run model snapshot no longer exists.
- `AgentService.toolIcon` → `toolIconFor` in
  `lib/ui/widgets/chat_tool_visuals.dart`.
- `AgentService.maxAttachments` → private `_maxChatAttachments` in
  `lib/ui/chat_screen.dart`.
- `AgentService.cleanTruncate` → `cleanTruncate` in `lib/core/format.dart`.

## `settings_state_integration` mapping (with proof)

| Retired call | Surviving owner | Proof |
|---|---|---|
| `AgentService.I.clearStudioStateForReset()` | `StudioRemoteClient.I.clearAll()` | `test/settings_actions_integration_test.dart` "reset clears drafts…" runs the canonical drafts store and verifies `StudioRemoteClient.I.noDrafts` is true after reset |
| `AgentService.I.studioDraftsEmpty` | `StudioRemoteClient.I.noDrafts` | same assertion; `reset_coordinator_test.dart` proves the canonical enumeration still includes the `drafts` store |
| `AgentService.I.sessionAccountChanged()` | `CloudAgentFacade.resetAccountStateIfInstalled()` | new `resetAccountState()` drops projections/subscriptions, queues, staged attachments, optimistic modes, error surfaces and test busy overrides. `settings_actions_integration_test.dart` "restore waits for pending setting writes and fences active work" seeds a facade run before the account transition and asserts `busyFor` is false afterwards. `resetAccountStateIfInstalled()` never constructs the facade just to clear it. |

`lib/core/state.dart` was re-pointed the same way in
`transitionSessionAccount` and in the legacy reset path.

## Other mechanical re-points

- `lib/ui/session_actions.dart`, `sidebar.dart`, `chat_overflow_menu.dart`,
  `chat_screen.dart` — dual-path `_agent` getters collapsed to
  `CloudAgentFacade.I` (Task 20 does the wider flag collapse).
- `lib/core/commands.dart` — `busyFor`, `planMode`, `pendingAttachments`,
  `mode` now go through the facade; `/preset` re-implements only the
  surviving state mutation (preset id + plan/read-only coupling) because
  `applyPreset`'s local tool-roster work is server-owned.
- `lib/ui/link_safety.dart` — local workspace image resolution returns null;
  produced-file share is a no-op; `@file` listing is empty. These branches
  were already unreachable on the cloud arm and the local workspace no
  longer exists.
- `lib/core/state.dart` — local collaboration now unconditionally throws the
  cloud read-only notice; `_mountRuntimeSkills` is a no-op; run checkpoints
  are not restored locally.
- `CommandService.I` now lazily calls `registerBuiltins()` on first use. The
  retired service constructor used to do this; without it every slash
  command (including `/help`) disappeared from the UI.
- `CloudAgentFacade.liveBubbleTicksFor` returns a stable per-session tick
  notifier WITHOUT subscribing. A transcript bind used to call `_stateFor`,
  which opened a WS subscription (and reconnect timers) for every rendered
  session. Real runs and cache loads still create/subscribe the session
  state; the projection forwards its per-delta ticks into the stable
  notifier.
- `CloudAgentFacade.setMode` now writes `ChatSession.mode` (and clears plan
  mode) optimistically, reverting on PATCH failure — parity with the retired
  local setter, needed by the access-mode picker and `/permission`.

## Test triage

**Counts:** 32 test files deleted; 64 test files modified/ported; 216 tests
removed (1,915 → 1,699 passing). No whole file was deleted where only one
group referenced `AgentService`: the four mixed UI suites below kept every
surviving test and only dropped the local-loop cases.

### Deleted files (32) — local agent-loop / removed behavior (AG4)

| File | Why |
|---|---|
| `agent_double_response_test.dart` | local streaming + retry double-response |
| `agent_git_tools_test.dart` | local tool taxonomy (`toolTitleFor`, `toolsForTest`) |
| `agent_memory_context_integration_test.dart` | local request assembly/memory context |
| `agent_retry_diagnostics_test.dart` | local retry/error diagnostics |
| `agent_stop_fix_test.dart` | local stop + queue promotion |
| `agent_stream_history_performance_test.dart` | local streaming history performance |
| `agent_ui_map_test.dart` | local tool UI map |
| `agent_usage_attribution_test.dart` | local usage attribution |
| `anthropic_provider_control_test.dart` | local provider request shaping |
| `approval_dock_safety_test.dart` | local request-bound approval gate |
| `approval_ui_ready_test.dart` | local approval-UI mount counter |
| `composer_attachments_test.dart` | local attachment continuation/send pipeline |
| `image_edit_tasks_test.dart` | local image tool dispatch |
| `image_tools_integration_test.dart` | local image tool dispatch/approval |
| `p2_session_access_test.dart` | local session access control |
| `p6_token_efficiency_test.dart` | local token budgeting |
| `queue_continuation_test.dart` | local queue continuation |
| `queue_ids_test.dart` | local queue ids/steering |
| `readonly_command_security_test.dart` | local read-only shell classifier |
| `request_working_folder_test.dart` | local tool dispatch/folder picker |
| `self_source_block_test.dart` | local self-source guard/tool dispatch |
| `session_analytics_test.dart` | local cost-estimation static |
| `session_ledger_integration_test.dart` | local run + ledger integration |
| `session_naming_test.dart` | local title generation |
| `slash_command_args_test.dart` | local command argument substitution statics |
| `state_collab_gate_test.dart` | local collaboration turn |
| `stop_output_test.dart` | local stop/output semantics |
| `storage_privacy_fixes_test.dart` | local spill pruning (spill runtime deleted) |
| `subagent_ceiling_test.dart` | local subagent concurrency |
| `token_budget_test.dart` | local tool/context budget internals |
| `tool_fallback_false_positive_test.dart` | local LLM fallback detection |
| `vision_model_support_test.dart` | local vision-support statics |

### Ported / updated files (64)

Facade-seam ports (assertions kept; only the seeding mechanism changed):

- `access_mode_confirm_test` — fake facade + REST that accepts the mode PATCH.
- `attachment_tiles_test`, `chat_layout_widget_test` — `stageAttachmentForTest`.
- `chat_data_loss_safety_test` — facade queue/approval; dropped the local
  "Regenerate removes tool/reasoning rows" run contract (1 test).
- `chat_dock_attachment_regression_test` — facade queue/attachments/approvals;
  dropped 4 local queue-admission/direct-submit tests.
- `chat_large_history_test`, `chat_scroll_anchor_test` — `setActiveRunForTest`.
- `chat_premium_regression_test` — facade busy/queue/approval.
- `chat_screen_bounded_test` — facade queue/attachments/approval; dropped 3
  local queue-send/cross-session-approval tests.
- `chat_screen_cloud_rewire_test` — facade `busyFor`.
- `queue_dock_layout_test` — facade `enqueueMessage`.
- `settings_actions_integration_test` — facade busy reset + `StudioRemoteClient.noDrafts`.
- `settings_controls_test` — `ModelLimits` context-window helpers.
- `sidebar_rebuild_scope_test` — facade busy seam + `notifyListeners`.
- `studio_rebuild_scope_test` — `CloudAgentFacade.notifyListeners`.

Type / contract / comment updates:

- `agent_surface_conformance_test` — dropped the `AgentService implements
  AgentSurface` case; kept the facade case.
- `cloud_agent_facade_test` — `AgentMode` now imported from `models.dart`.
- `cloud_session_store_test` — uses `subscribeForTest` (the tick bind no
  longer subscribes).
- `collaboration_reducer_test` — removed the now-vacuous forbidden literals
  `agent_service` / `AgentService` (the gate requires the grep to be empty;
  the import/identifier guards remain).
- `play_distribution_test` — `models.dart` import; enum-name assertion.
- `session_persistence_test`, `dsh_optional_features_test`,
  `workspace_folder_provenance_test` — removed source-read assertions that
  named the deleted file (the system-prompt wording and snapshot are
  server-owned now).

Hygiene-only ports (removed `debugPauseScheduleTimerForTest`, `clear*`,
`pendingApproval = null`, local LLM stubs; all assertions kept):

`agent_response_color`, `billing_play_flow`, `billing_release_gate`,
`chat_disclosure_widget`, `chat_message_actions_a11y`,
`chat_screen_distribution_gates`, `claude_style_chat`,
`cloud_catalog_recovery`, `cloud_connection_recovery`,
`conversation_share_sidebar`, `delete_row_actions`,
`firebase_appcheck_wiring`, `html_artifact_chat`, `link_safety`,
`mic_press_to_talk`, `offline_indicator`, `ovid_cloud_service`,
`play_billing`, `providers_cached_fetch`, `providers_compact`,
`providers_fetch_errors`, `providers_verify_fetch`, `recent_models`,
`release_legal_links`, `settings_data_deletion_ui`,
`settings_no_sync_collab_entries`, `shell_polish_regression`,
`sidebar_layout`, `sidebar_no_repo_labels`, `sidebar_recency_search`,
`ui_finish_03_account`, `ui_finish_07_billing`, `ui_finish_13_sharing`,
`ui_redesign/billing_screen`, `ui_redesign/chat_picker`,
`ui_redesign/image_receipt_panel`, `ui_redesign/providers_screen`,
`ui_redesign/settings_screen`, `ui_redesign/settings_sub`,
`worker_d_sidebar_fixes`.

Additional individual tests removed from mixed UI suites:

- `composer_io_scope_test` — 2 local `@file` workspace-listing tests (no
  local workspace on the thin client; the image-row test still passes).
- `workspace_folder_provenance_test` — 3 source-read tests.
- `chat_data_loss_safety_test` — 1 local run contract.
- `chat_dock_attachment_regression_test` — 4 local queue/submit contracts.
- `chat_screen_bounded_test` — 3 local queue/approval contracts.

## Gates (exact output)

Working tree:

```
$ flutter analyze --no-pub
No issues found! (ran in 19.9s)

$ flutter test --no-pub --reporter compact
01:45 +1699 ~2: All other tests passed!        # exit 0, 2 skipped

$ grep -rn "AgentService" lib/ test/
(empty)
$ grep -rn "agent_service" lib/ test/
(empty)

$ flutter build apk --debug
✓ Built build/app/outputs/flutter-apk/app-debug.apk    # exit 0
```

Committed tree (`git archive HEAD` → `/tmp/t19-post`):

```
$ flutter analyze --no-pub
No issues found! (ran in 7.1s)

$ flutter test --no-pub --reporter compact
01:45 +1699 ~2: All other tests passed!        # exit 0, 2 skipped

$ flutter build apk --debug
✓ Built build/app/outputs/flutter-apk/app-debug.apk    # exit 0
```

The pre-commit `git archive HEAD` copy (the T18 commit) also analyzed
`No issues found!`. One full-suite run on the archive hit the known
`sidebar_rebuild_scope_test` load flake ("Renamed chat" not visible); the
file passes 4/4 in isolation and the immediate full re-run was green. This
is the same load-flake class recorded in earlier task reports, not a
regression.

## Deviations / deferrals

1. `QueuedMessageSnapshot` was moved even though the brief did not list it:
   `AgentSurface` references it, so the file cannot be deleted otherwise.
2. Pure statics used by surviving UI were re-homed (`ModelLimits`,
   `chat_tool_visuals.toolIconFor`, `format.cleanTruncate`,
   `_maxChatAttachments`). This is relocation, not a re-added runtime.
3. `liveBubbleTicksFor` no longer subscribes on UI bind. Production still
   subscribes through `runTask` and the store's cache-load sink; the change
   removes accidental socket/reconnect timers from every rendered transcript
   (and fixed 4 widget-suite failures caused by pending reconnect timers).
4. `setMode` now persists `ChatSession.mode` and clears plan mode, matching
   the retired local setter and the access-mode picker's contract.
5. `Distribution.cloudExecution` branches unrelated to `AgentService` were
   left for Task 20's flag collapse.
6. No new local execution path or capability was added.

## Fix round 1 — over-deleted coverage

The T15 HIGH-3 class: four whole files were deleted even though only some of
their tests covered retired local-loop behaviour. Restored below, ported to the
surviving `CloudAgentFacade` surface. Nothing was re-added to `lib/` beyond
three small, real facade gaps found by the ported assertions.

### `test/session_analytics_test.dart` — 2 restored, 1 dropped

- Restored verbatim: "session analytics are isolated and persist through JSON"
  and "analytics accumulates each completed model request". `ChatSession`
  and `SessionAnalytics` survive (`lib/core/state.dart`).
- Dropped: "pricing estimates known models and refuses unknown models" —
  `estimatedCostForModel` died with the local service; pricing is the
  server's `/usage` authority.

### `test/queue_ids_test.dart` — 9 restored, 0 dropped

All nine cases ported to the facade queue (`queuedMessagesFor`,
`queuedMessageIdsFor`, `removeQueuedMessageById`, `editQueuedMessageById`,
`quickSendQueuedMessage`, `clearQueueForTest`):

- distinct stable ids; delete by id (no re-indexing); edit by id (ids
  preserved); quick-send no-op for unknown id/empty queue; idle-session
  quick-send steers but keeps the queue; edit-to-composer contract.
- "steer by id" maps onto `quickSendQueuedMessage(id)` — the retired
  `steerQueuedMessageById` no longer exists. On the test busy seam the stop
  resolves without a server run, so the steered order is what remains; the
  comment in the file says so.
- "ids survive a stop-and-continue" and "quick send … promotes it on stop"
  drive a real fake `CloudRestClient` + fake WS socket. The facade drains the
  queue head on the run's terminal event, so the tests emit
  `run_started` → `run_completed`, gate the promoted POST, and emit the
  promoted run's `run_started` so the facade does not recursively drain the
  remainder in the same pass. Assertions are unchanged: head promoted, rest
  keep their ids and order.
- Sessions are keyed by server id; with `store: null` the local id passes
  through, so `ChatSession.id` is the queue key (no store seeding needed).
- The `setActiveRunForTest` seam marks a session busy so enqueueing does not
  immediately drain — the surviving analogue of the retired
  `setRunSessionForTest`.

### `test/approval_dock_safety_test.dart` — 4 restored, 1 group dropped

- Restored: stale-tap never resolves request B, double-tap guard, 40-line
  detail reachable, 48dp tap targets at 320dp/1.3x. `_ApprovalDock` still
  exists and reads `CloudAgentFacade.pendingApproval`.
- `AgentService.I.pendingApproval = x` became
  `CloudAgentFacade.I.pendingApprovalForTest = x`; the facade is installed in
  `setUp` and disposed/reset in `tearDown`; the retired
  `debugPauseScheduleTimerForTest`/queue resets were removed (the facade's
  `clearQueueForTest` is used).
- Dropped: the `AgentService request-bound approvals` group (retired service
  semantics).
- The tests use a test-only `CloudAgentFacade` subclass for the two approval
  entry points. Production's P3 approval path is inert (`approveRequest`
  returns false), so a double is needed to observe *which* request a tap
  reaches. It is request-bound exactly like the retired service: a stale tap
  carrying an older request does not resolve anything.

### `test/composer_attachments_test.dart` — 10 restored, 6 dropped

Restored:

1. the 21st file is rejected with a limit explanation;
2. concurrent selections reserve slots (adapted: the facade stages source
   paths, not copies, so the assertion counts 20 staged entries rather than
   unique paths);
3. same-name files keep both contents and stay in the session, including
   per-session isolation (adapted to distinct source files, because the cloud
   path stages the source path);
4. removing one same-name attachment keeps the other;
5. picked filename cannot escape the workspace;
6. picker completion stays with its originating session (asserts the
   originating session's staged path; the facade does not copy into a local
   workspace);
7. failed send preserves composer attachments (fake REST throws
   `CloudApiException`);
8. accepted send clears only the sent snapshot;
9. stored paths survive reload (pure `Message.fromJson`; the
   `buildRequestMessages`/`read_image` tail is gone — request assembly is
   server-side);
10. path-only metadata updates are written to session storage (same
    adaptation: the final request-builder assertion was dropped).

Dropped (retired local run loop / local workspace):

- "provider setup rejection leaves attachments available" — provider
  selection is server-owned; there is no local setup step.
- "cancelled send preserves its attachments" — the cloud send is one POST;
  there is no client-side provider call to cancel mid-flight.
- "successful send persists exact paths that tools can resolve" — local
  `dispatchForTest`/request assembly are gone.
- "attached image path supports vision without raising the image cap" — local
  `read_image`/vision message assembly is gone.
- "queued composer references and attachment snapshots travel together" —
  facade queue rows are id+text only; `takeQueuedMessages` synthesizes empty
  attachment lists and `userReferences: true`, and reference expansion is
  server-side. Expressing this would require inventing production queue API.
- "busy send carries attachments; queued provider failure" — local run loop
  and `llmOnceForTest`.

### Facade gaps found by the ported assertions (fixed)

1. **20-file cap missing** — `attachFile` accepted unlimited files. Added
   `_maxAttachments = 20` plus a per-session reservation counter taken before
   the first `await`, so concurrent picker bursts cannot all pass the check
   (the retired service's `_attachmentCopies` contract). The error text is the
   same "up to 20 files per message" explanation.
2. **Filename-escape validation missing** — added the retired service's
   rejection of empty/`.`/`..` names and names containing `/`, `\` or NUL,
   returning `invalid attachment filename`.
3. **Accepted send cleared ALL staged attachments** — `runTask` did
   `_attachments.remove(id)`, dropping files staged while the POST was in
   flight. It now removes only the sent snapshot (multiset match on
   name+path+size) and keeps later picks for the next message.

No other gap surfaced; no assertion was weakened.

### Gates (exact output)

```
$ flutter analyze --no-pub
No issues found! (ran in 20.3s)

$ flutter test --no-pub test/session_analytics_test.dart test/queue_ids_test.dart \
    test/approval_dock_safety_test.dart test/composer_attachments_test.dart
... +25: All tests passed!

$ flutter test --no-pub --reporter compact
01:47 +1724 ~2: All other tests passed!        # exit 0, 2 skipped

$ grep -rn "AgentService\|agent_service" lib/ test/
(empty)
```

Full-suite count: 1,724 passed / 2 skipped / 0 failed (baseline 1,701 total
including the 2 skipped; the four files add 25 tests).
