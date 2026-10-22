# UI v2 → live data wiring map

The v2 widgets are presentational. This map is the contract for the wiring pass:
which existing source feeds each screen and which callback goes back. Nothing
here is invented; every source exists in `lib/core/`.

## Global

| Concern | Source |
|---|---|
| Theme mode | `AppState.I.themeMode`, `setThemeMode()`; `OTheme.modeFor` |
| Account / plan tier | `AppState.I.ovidCloudTier`, `ovidCloudIsPaid`; `PlayBilling` |
| Sessions | `AppState.I.sessions`, `rootSessionsByRecency`, `activeSession` |
| Send | `CloudAgentFacade.I.runTask(text, sessionId: …)` |
| Stop / queue | `CloudAgentFacade.I.stopRequested(sessionId: …, dispatchQueued: true)` |
| Busy / status | `busyFor`, `statusFor`, `activityFor`, `writingFor`, `stalledFor` |
| Queued message | `pendingStateOf(message)`, `retryPendingSend`, `discardPendingSend` |
| Approvals | `CloudAgentFacade.I.approveRequest`, `approveAlwaysRequest` |
| Memory toggles | `AppState.I.memoryEnabled`, `effectiveShareSessionMemory` |
| Response wait | `AppState.I.responseTimeoutSec` |
| Chat text size | `AppState.I.chatFontScale` |
| Push | `PushService.I.onOpenRoute`, `BackgroundNotifier.I` |
| Share links | `ShareLinkResolver`, `ConversationShareService` |

## Screens

| Screen | Read | Write / callbacks |
|---|---|---|
| `chat/chat_page.dart` | `activeSession.messages`, `busyFor`, `statusFor`, `pendingStateOf`, plan allowance | `runTask`, `stopRequested(dispatchQueued: true)`, attach picker, mic |
| `chat/live_chat_page.dart` | same transcript + `liveBubbleTicksFor`, `writingFor`, `stalledFor` | stop, approve, open artifact |
| `chat/model_picker_sheet.dart` | `AppState.I.providers`, selected model, tier | `selectModel`, upgrade CTA |
| `chat/model_chip_menu.dart` | selected model + tier | same |
| `sidebar/sidebar.dart` | `rootSessionsByRecency`, pins, profile, tier | new chat, select session, open search/projects/settings |
| `sidebar/projects_page.dart` | `ProjectsController` (list, counts, storage, shared) | create/rename/delete, open project |
| `sidebar/search_page.dart` | local session index first, then `CloudSessionStore` search | open result |
| `sidebar/session_actions_sheet.dart` | selected `ChatSession` | pin, rename, move, share, duplicate, export, delete |
| `settings/settings_hub.dart` | counts only (connectors, memory files) | navigate callbacks |
| `settings/account_page.dart` | Firebase user, `AppState` profile, connected providers | save, sign out, delete account |
| `settings/plan_billing_page.dart` | `PlayBilling` products + entitlement | purchase, restore |
| `settings/usage_page.dart` | `UsageToday`, `UsageHistoryStore`, 50M/1.5B limits | range tabs, refresh |
| `settings/memory_page.dart` | `memoryEnabled`, `effectiveShareSessionMemory`, memory file list | toggle, edit, export, reset |
| `settings/data_control_page.dart` | export/import job state, storage usage | export, import, delete, reset |
| `settings/storage_page.dart` | storage breakdown from cloud usage | clear previews, delete old chats |
| `settings/appearance_page.dart` | `themeMode`, `chatFontScale`, reduce motion (OS) | `setThemeMode`, `setChatFontScale` |
| `settings/credentials_page.dart` | connected Google/GitHub, masked token state | add/revoke |
| `settings/account_health_page.dart` | security check, devices, service status | revoke device |
| `studio/repo_picker_page.dart` | GitHub connection, repo list from cloud | connect, pick repo |
| `studio/studio_workspace_page.dart` | `StudioDraftStore`, bound repo/branch, tree, dirty state | sync, save, commit, preview |
| `studio/branch_picker_sheet.dart` | branches from cloud | select/create branch |
| `studio/changes_page.dart` | diff from studio service | commit & push, sync first |
| `studio/live_preview_page.dart` | preview URL/expiry from studio service | refresh, share, stop |
| `browser/browser_page.dart` | browser session stream (4 fps), tabs, agent state | take control, stop |
| `browser/take_control_sheet.dart` | pause countdown | start control, stay watching |
| `connectors/connectors_page.dart` | connector catalog + installed set | toggle, open, add |
| `connectors/connector_detail_page.dart` | connector + permissions + usage | disconnect |
| `connectors/add_connector_page.dart` | catalog + plan limit | test, save |
| `library/artifacts_page.dart` | `ArtifactVaultController`, session artifacts | filter, open, create |
| `library/artifact_detail_page.dart` | artifact metadata + signed URL | download, share, open studio |
| `schedules/schedules_page.dart` | `ScheduleClient` list + `ScheduleLiveFeed` | toggle, open, create |
| `schedules/schedule_editor_page.dart` | schedule draft + timezone | save |
| `schedules/schedule_runs_page.dart` | `ScheduleRunDto` history | retry, open chat |
| `share/share_sheet.dart` | creator link surface, composed by `share_chat_sheet.dart` | create/stop link, copy |
| `share/share_chat_sheet.dart` | same + fork eligibility | fork into account |
| `collab/collab_live_page.dart` | collaboration session, members, turn lock | send (disabled unless turn), leave |
| `collab/collab_members_page.dart` | member list + roles + creator storage | remove, leave |
| `runs/run_trajectory_page.dart` | run events / trajectory projection | expand, share |
| `runs/subagent_page.dart` | child `ChatSession` (`isSubagent`), log URL, state | stop, view log |
| `states/system_states_page.dart` | static states | retry / see plans / dismiss |

## Rules for the wiring pass

1. No screen imports `AppState` directly. Each group gets an adapter in
   `lib/ui/v2/<group>/<screen>_adapter.dart` that listens to the source and
   builds the presentational widget. This keeps widget tests hermetic.
2. Adapters own `AnimatedBuilder`/`ListenableBuilder` subscriptions and dispose
   them. Screens stay dumb.
3. Empty is a real state: if a source is not connected (GitHub, browser,
   collab), show the screen's empty/connect state, never demo data.
4. Destructive callbacks must return a result the adapter can surface as a
   snackbar; the screen does not show its own snackbar.
5. The gallery (`v2_gallery.dart`) is the only place allowed to inject demo
   data. Production adapters never import the demo file.
