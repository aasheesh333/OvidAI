# Feature gaps — what does not work yet

**Audited:** 2026-10-22 against the current `lib/ui/v2/` tree and the adapters
in `lib/ui/v2/app/`. If a row is here, do not claim the feature works in a
release note, demo or store listing. Each row names the owner of the missing
piece and the file that proves the gap.

Severity: **P0** blocks a release claim; **P1** a shipped screen is visibly
incomplete; **P2** a designed/expected convenience is absent.

---

## A. Needs a backend endpoint (or server capability)

| # | Gap | Sev | Evidence (file) | What would make it true |
|---|---|---|---|---|
| A1 | **Live preview has no producer.** The screen always opens `unavailable`; there is no URL, frame, expiry or tunnel. | P1 | `lib/ui/v2/app/v2_studio_routes.dart:288` (`livePreviewDataFor` returns `V2PreviewStatus.unavailable` with `'Live preview is not connected yet.'`) | A preview service that returns a real URL + frame stream + expiry, and a client that reconnects. |
| A2 | **Studio Changes has no diff/commit client.** `changesDataFor` always returns `V2ChangesStatus.empty`; `openChanges` passes no commit/sync/copy handler. | P1 | `lib/ui/v2/app/v2_studio_routes.dart:96` and `:266` (`changesDataFor`) | `git status` / `git diff` / commit endpoints (or port methods) that return changed files, hunks and a commit result. |
| A3 | **Studio workspace change/sync counts are always 0.** `workspaceDataFor` says there is no git-status source. | P1 | `lib/ui/v2/app/v2_studio_routes.dart:147` | The same git-status source as A2, surfaced per workspace. |
| A4 | **Connector tool manifest is empty.** `v2ConnectorDetailForRow` never fills `tools`; the permissions screen can only list grants, not the tools each grant unlocks. | P1 | `lib/ui/v2/connectors/connector_detail_page.dart:870` (`V2ConnectorDetailData` with no `tools`) | MCP `tools/list` or a provider scope→tool map, persisted per connector. |
| A5 | **No collaboration turn queue.** `liveDataFor` sets `queueLabel: null` and leaves `turnQueue` empty; the banner can say whose turn it is but not who is waiting. | P1 | `lib/ui/v2/app/v2_collab_routes.dart:109`; `lib/ui/v2/collab/turn_banner.dart:90` ("Retained for callers that used to render the queue") | A server queue endpoint (ordered waiters + request/raise priority) and a state field for it. |
| A6 | **Account health has no devices or 2FA service.** The screen models only `active` / `deletionPending`; device review and two-step sign-in are absent, not disabled. | P1 | `lib/ui/v2/settings/account_health_page.dart:29` ("Device management and two-step sign-in have no endpoint") | A device/session list endpoint and a 2FA status endpoint, or a product decision to remove the claim. |
| A7 | **Response wait has no auto-extend or notify-at-limit.** The limit persists and the watchdog reads it, but nothing extends a quiet run or notifies at the limit. | P2 | `lib/ui/v2/settings_extra/response_wait_page.dart:1`; `lib/ui/v2/app/v2_settings_routes.dart:1049` | A watchdog consumer plus a notify/extend policy (and a field to carry it). |
| A8 | **No payment-history source.** `_plans` never passes `history`; the "Payment history" block is hidden even for paid accounts. | P2 | `lib/ui/v2/app/v2_settings_routes.dart:188` (no `history:` argument); `lib/ui/v2/settings/plan_billing_page.dart:667` | A Play/RevenueCat transaction-history endpoint mapped into `V2BillingHistoryEntry`. |
| A9 | **No artifact version history.** The detail screen has a `versionLabel` slot but no list of versions and no restore. | P2 | `lib/ui/v2/library/artifact_detail_page.dart:73` (`versionLabel` is never read) | `GET /artifacts/:id/versions` and a version list/restore UI. |
| A10 | **Browser cannot do history, upload, download or close-tab.** The live page removes those controls because the server cannot support them. | P1 | `lib/ui/v2/browser/browser_live_page.dart:30` ("Controls the server cannot support (history, upload, download, closing a tab)") | Browser-service commands + DTO fields for each action. |
| A11 | **No email-verification resend.** The account screen shows `verified`, but no route supplies a resend action. | P2 | `lib/ui/v2/settings/account_page.dart:52` (`verified`); `lib/ui/v2/app/v2_settings_routes.dart:152` (`_account` supplies no resend) | A Firebase `sendEmailVerification` action wired to the account row. |
| A12 | **Schedule "retry" re-runs the schedule, not the failed run.** The run timeline's retry calls `controller.runNow(schedule)`. | P2 | `lib/ui/v2/schedules/schedules_flow.dart:353` (`_retry` → `runNow`) | A per-run retry endpoint (`POST /schedules/:id/runs/:runId/retry`) or an explicit product decision that retry means "run now". |
| A13 | **"Crash reports" row leads to a page with no crash control.** The Settings hub row (`crash`) routes to Data control, but `DataControlPage` renders no consent row and ignores `crashReports`/`onCrashReportsChanged`; the adapter still passes both. | P1 | `lib/ui/v2/app/v2_app_shell.dart:1529` (`'crash'` row); `lib/ui/v2/app/v2_settings_routes.dart:102` (`case 'crash'` → `_DataControlLoader`); `lib/ui/v2/settings/data_control_page.dart:74` ("no longer renders rows for … crash reports") | Give the hub row its own consent sheet/toggle wired to `setCrashReports`, or remove the row. |
| A14 | **Share-fork needs the share backend.** The recipient path has a Fork action, but it only works when the collaboration/share service is configured. | P1 | `lib/ui/v2/app/v2_app_shell.dart:1959` (`_collabAvailable`), `:1967` (`_readOnlyAvailable`) | The share service deployed and reachable; no UI change needed once it is. |

## B. Needs a core model field

| # | Gap | Sev | Evidence (file) | What would make it true |
|---|---|---|---|---|
| B1 | **`BrowserState` drops `fps` and `headless`.** The server DTO carries both; the Dart model never parses or stores them, so the browser cannot show the live frame rate or headless badge. | P1 | `lib/core/cloud/browser_stream.dart:116` (constructor/fields have no `fps`/`headless`); server DTO `cloud/packages/shared/src/browser.ts:75` | Add `fps` and `headless` to `BrowserState` and parse them in `fromJson`. |
| B2 | **Subagent live progress fields are not modelled as a contract.** The page receives `stepLabel`, `paceLabel`, `goal`, `files`, `logLines` and `totalLogLines` but does not render them; there is no typed step/progress model. | P1 | `lib/ui/v2/runs/subagent_page.dart:34` (fields present, no widget reads); `lib/ui/v2/app/v2_run_routes.dart:134` | A typed subagent progress DTO (step, percent, files, log tail) and a renderer, or delete the fields and the claim. |
| B3 | **No artifact version or creator-run field.** The detail screen's `versionLabel`, `sourceChatTitle` and `previewHeadline` are constructor-only. The core row has `origin` and `sessionTitle`, but no version and no run id. | P2 | `lib/ui/v2/library/artifact_detail_page.dart:73-82`; `lib/core/cloud/artifact_vault.dart:50-63` (no `version`/`createdByRunId`) | `version` and `createdByRunId` on the artifact row, plus a version list if history ships. |
| B4 | **No avatar URL on the account model.** The profile header supports `onChangePhoto`, but no route supplies it and there is no avatar field to store. | P2 | `lib/ui/v2/settings/account_page.dart:84`; `lib/ui/v2/app/v2_settings_routes.dart:127` (no `onChangePhoto`) | An avatar URL/upload field on the account profile and a storage endpoint. |
| B5 | **No project sort/status fields.** The projects list has no sort key or status, so the designed chips cannot be built. | P2 | `lib/ui/v2/sidebar/projects_page.dart:14` (`V2ProjectsData` has only a list); `lib/ui/v2/app/v2_app_shell.dart` project adapter | `sortKey`/`status` on the project model (or a client-only sort decision). |
| B6 | **No per-schedule notification override.** The editor exposes one global notification path; the schedule model has no channel/quiet-hours override. | P2 | `lib/ui/v2/schedules/schedule_editor_page.dart:51` (`V2ScheduleEditorData`); `lib/core/cloud/schedule_client.dart` | A per-schedule `notify`/`quietHours` field. |
| B7 | **No collaboration queue/priority field.** Even with A5, the state model has no ordered waiter list or priority flag. | P1 | `lib/core/collaboration/models.dart` (`CollaborationState`); `lib/ui/v2/collab/turn_banner.dart:87` | Add `turnQueue` and `priority` to the collaboration projection. |

## C. Needs a product decision

| # | Gap | Sev | Evidence (file) | Decision needed |
|---|---|---|---|---|
| C1 | **English-only UI.** 101 `TODO(l10n)` markers; the language picker is a voice/assistant preference, not app localization. | P1 | `lib/ui/v2/**` (`TODO(l10n)`), e.g. `lib/ui/v2/chat/chat_page.dart:21` | Ship English-only and say so, or fund the ARB extraction pass. |
| C2 | **`model_chip` is gallery-only.** The shell opens the full model picker from the chip; the quick menu has no production route. | P2 | `lib/ui/v2/v2_registry.dart:124`; no `V2ModelChipMenu` in `lib/ui/v2/app/` | Wire the menu or remove the registry entry. |
| C3 | **`system_states` is gallery-only.** Chat renders inline plan/offline/error states; the dedicated state page is unreachable. | P2 | `lib/ui/v2/v2_registry.dart:137`; no `V2SystemStatesPage` in `lib/ui/v2/app/` | Route blocking conditions to this page, or remove the entry. |
| C4 | **`share_sheet` is gallery-only.** Production uses `share_chat` for both creator and recipient. | P2 | `lib/ui/v2/v2_registry.dart:302`; `lib/ui/v2/app/v2_app_shell.dart:2232` (`ShareChatSheet`) | Delete the duplicate or route it for non-chat shares. |
| C5 | **Projects have no sort/status chips.** The designed filter row is absent. | P2 | `lib/ui/v2/sidebar/projects_page.dart:14` | Build the chips (needs B5) or drop them from the design. |
| C6 | **Memory has no accuracy card.** The designed "what Ovid got right/wrong" surface is absent. | P2 | `lib/ui/v2/settings/memory_page.dart:147` (`V2MemoryPageData` has no accuracy fields) | Build it on real correction events, or drop it. |
| C7 | **Connectors have no installed/available tabs.** One list with a filter menu replaces the designed tabs. | P2 | `lib/ui/v2/connectors/connectors_page.dart:23` (`V2ConnectorsData` single list) | Add tabs or keep the single list and update the design. |
| C8 | **Schedules have no total/CTA card and no upcoming queue.** The list is cards only. | P2 | `lib/ui/v2/schedules/schedules_page.dart:89` (`V2SchedulesData`) | Build the summary card/queue or drop it. |
| C9 | **Runs have no stat tiles or upcoming queue.** The trajectory page is a timeline only. | P2 | `lib/ui/v2/runs/run_trajectory_page.dart:122` (`V2RunTrajectoryPageData` after the header removal) | Decide whether runs need aggregate stats. |
| C10 | **No collab "raise priority" control.** The queue is absent (A5) and there is no priority action. | P2 | `lib/ui/v2/collab/turn_banner.dart:92` | Build with A5/B7 or remove from the design. |
| C11 | **No notification/avatar entry point in the top bars.** Settings owns both; the chat header has no bell/avatar. | P2 | `lib/ui/v2/chat/chat_page.dart` (top bar callbacks), `lib/ui/v2/app/v2_app_shell.dart` | Add the entry point or keep it settings-only. |
| C12 | **Live chat has no message edit/branch/regenerate.** The transcript is read-only apart from copy/retry actions. | P2 | `lib/ui/v2/chat/live_chat_page.dart`; `lib/ui/v2/chat/transcript_actions.dart` | Decide whether branching/regeneration is in scope. |
| C13 | **Model picker has no live latency/price.** Speed and cost hints are catalogue copy. | P2 | `lib/ui/v2/chat/model_picker_sheet.dart:53` (`V2ModelOption` strings) | Add telemetry or label the hints as estimates. |
| C14 | **Artifact documents are metadata-only.** No embedded document renderer; "Open externally" is the only path. | P2 | `lib/ui/v2/library/artifact_preview.dart:34` (`V2ArtifactPreviewType.document`) | Keep external-only (recommended) or add a renderer. |
| C15 | **Free-plan USD allowance vs token cap.** `free_daily_usd = 0.15` still gates before the 50M token cap. | P0 | `server/billing` / `TODO.md` P0; plan table `lib/ui/v2/settings/usage_page.dart` | Raise/remove the USD allowance so the token cap is the real gate. |
| C16 | **Yearly billing is a product choice, not just a SKU.** The code can attempt a yearly product, but no yearly product exists in Play/RevenueCat. | P1 | `lib/core/billing_products.dart:28`; `lib/ui/v2/app/v2_settings_actions.dart:174` | Create the products (D2) or remove the yearly toggle. |
| C17 | **Usage has no request/image counters.** `requestsLabel`/`imagesLabel` exist only to decide whether the screen has data; the rendered page shows tokens, not request or image counts. | P2 | `lib/ui/v2/settings/usage_page.dart:130-136` (`hasData`), `:195-197` | Render the counters from real telemetry, or delete the fields and the `hasData` dependence. |
| C18 | **Usage model split is gallery-only.** `V2ModelShareChart` is mounted only by `v2_registry_web.dart`; the live Usage page never shows it. `V2UsageData.models` only feeds `hasData`, so it can make the page look non-empty without displaying a model. | P2 | `lib/ui/v2/settings/usage_charts.dart:220`; `lib/ui/v2/v2_registry_web.dart:1140`; `lib/ui/v2/settings/usage_page.dart:130-136` | Mount the chart on the live page with real slices, or delete it and the `models` field. |

## D. Needs a Play Console action (or store-account action)

| # | Gap | Sev | Evidence (file) | Action |
|---|---|---|---|---|
| D1 | **Monthly subscriptions do not exist in Play.** `ovid_plus_monthly`, `ovid_pro_monthly`, `ovid_max_monthly` are mapped in code but not created/attached in Play + RevenueCat. | P0 | `lib/core/billing_products.dart:27`; `TODO.md` "Play + RevenueCat setup state" | Create the three subscriptions in Play Console, add them to RevenueCat, attach to the `go`/`plus`/`pro` entitlements. |
| D2 | **Yearly subscriptions do not exist.** `ovid_plus_yearly`, `ovid_pro_yearly`, `ovid_max_yearly` are code-only. | P1 | `lib/core/billing_products.dart:28`; `lib/core/revenuecat_billing.dart:439` | Create yearly base plans/products and map them in RevenueCat, or remove the yearly toggle (C16). |
| D3 | **Production track is empty.** Internal testing is live; the public app is not. | P0 | `TODO.md` "Play + RevenueCat setup state" | Upload a signed AAB, complete the production track and rollout. |
| D4 | **RevenueCat credentials are not validated end to end.** | P0 | `TODO.md` "Remaining P0" | Validate the Play service-account key/permissions with a real purchase in an internal-test build. |
| D5 | **Data safety / store listing must match the 24 h deletion grace.** Code and `docs/play/DATA-SAFETY.md` say 24 h; re-check the Play form before submission. | P0 | `docs/play/DATA-SAFETY.md:71`; `lib/core/firebase_service.dart` deletion receipt | Confirm the Play Data safety answers and listing copy say 24 h, cancellable. |
| D6 | **Release keystore is owner-blocked.** A signed AAB needs the keystore password/alias/cert SHA-256. | P0 | `TODO.md` "Blocked on the owner" | Owner supplies the keystore credentials; then build/sign/upload. |
| D7 | **Subscription centre deep link needs the real product ids.** `playSubscriptionCenterUri` is correct in code but untested against the live catalogue. | P1 | `lib/core/billing_products.dart` (`playSubscriptionCenterUri`) | Test "Manage subscription" from a real subscribed account after D1/D2. |

---

## Deliberately not gaps (so nobody "fixes" them)

- **No email/password or Apple sign-in.** The product has two providers; the
  email form and Apple hook were removed rather than faked
  (`lib/ui/v2/onboarding/sign_in_page.dart:35`).
- **No document renderer in artifact preview.** Documents show metadata and an
  external-open action by design (`lib/ui/v2/library/artifact_preview.dart:34`).
- **No OS share-target grid.** Sharing to another app is the operating system's
  job (`lib/ui/v2/share/share_sheet.dart:30`).
- **No "coming soon" controls.** A control with no service is removed, not
  disabled (`docs/design/MINIMAL_UI_CONTRACT.md` §8;
  `test/v2/no_dead_controls_test.dart`).

---

## Appendix — dead data (no widget reads)

These `V2*Data` fields are still declared and (in most cases) constructed, but
no widget reads them. "No widget reads" means: no `data.<field>` access in any
screen, adapter or helper outside the registry/gallery/preview harness, and no
getter that a widget uses. A field read only by another unrendered getter is
listed here too.

This pass **does not delete anything**. Each row names the file that constructs
the data so the next change can remove the field and its write site together.
Fields marked *never constructed* are only defaults in the data class.

| Data class (declaration) | Dead fields | Constructed in |
|---|---|---|
| `V2ComposerPlusData` (`lib/ui/v2/chat/composer_plus_sheet.dart`) | `customConnectorsUsed` (read only by the unused `connectorsStateLabel`) | `lib/ui/v2/chat/chat_page.dart`, `lib/ui/v2/chat/live_chat_page.dart` |
| `V2CollabLivePageData` (`lib/ui/v2/collab/collab_live_page.dart`) | `participants`, `typingName`, `creatorPaysStorage` | `lib/ui/v2/app/v2_collab_routes.dart` |
| `V2CollabMembersPageData` (`lib/ui/v2/collab/collab_members_page.dart`) | `chatName`, `creatorName`, `storageUsedLabel`, `storageTotalLabel`, `storageFreeLabel`, `storagePercent` | `lib/ui/v2/app/v2_collab_routes.dart` |
| `V2CollabTurnBannerData` (`lib/ui/v2/collab/turn_banner.dart`) | `timeLeftFraction` (assert-only), `maxVisibleQueue` (read only by the unused `visibleQueue`/`hiddenQueueCount`) | `lib/ui/v2/collab/collab_live_page.dart` |
| `V2ConnectorDetailData` (`lib/ui/v2/connectors/connector_detail_page.dart`) | `syncedLabel`, `agents`, `safetyNote` | `lib/ui/v2/connectors/connector_detail_page.dart` (`v2ConnectorDetailForRow`, called from `connectors_page.dart`) |
| `V2ArtifactDetailData` (`lib/ui/v2/library/artifact_detail_page.dart`) | `versionLabel`, `sourceChatTitle`, `previewHeadline` | `lib/ui/v2/app/v2_work_routes.dart` |
| `V2ArtifactsData` (`lib/ui/v2/library/artifacts_page.dart`) | `totalSizeLabel` (never constructed) | — |
| `V2SubagentPageData` (`lib/ui/v2/runs/subagent_page.dart`) | `instanceLabel`, `progressKnown`, `progress`, `files`, `paceLabel`, `goal`, `timeLimitLabel`, `remainingLabel`, `logLines`, `totalLogLines` | `lib/ui/v2/app/v2_run_routes.dart` |
| `V2ScheduleRunsData` (`lib/ui/v2/schedules/schedule_runs_page.dart`) | `avgRuntimeLabel` | `lib/ui/v2/schedules/schedules_flow.dart` |
| `V2AppearancePageData` (`lib/ui/v2/settings/appearance_page.dart`) | `shareSessionMemory`, `onMemoryFilesTap` | `lib/ui/v2/app/v2_settings_routes.dart` |
| `V2CredentialsPageData` (`lib/ui/v2/settings/credentials_page.dart`) | `cloudKeyStatusLabel`, `cloudKeyStatusDetail`, `onAddToken` | `lib/ui/v2/app/v2_settings_routes.dart` |
| `V2DataControlPageData` (`lib/ui/v2/settings/data_control_page.dart`) | `onExportImport`, `onPermissions`, `onStorage`, `onResetMemory`, `crashReports`, `onCrashReportsChanged`, `permissionSummary`, `storageUsedLabel`, `storageFreeLabel`, `storageFraction` | `lib/ui/v2/app/v2_settings_routes.dart` |
| `V2MemoryPageData` (`lib/ui/v2/settings/memory_page.dart`) | `shareSessionMemory`, `globalVersionLabel`, `onShareSessionMemoryChanged`, `onFileDownload` | `lib/ui/v2/app/v2_settings_routes.dart` |
| `V2StoragePageData` (`lib/ui/v2/settings/storage_page.dart`) | `quotaLabel`, `previewSizeLabel`, `trashItems`, `trashSizeLabel`, `largestItems`, `offlineLabel`, `onClearPreviews`, `onDeleteOldChats`, `onEmptyTrash`, `onLargestItemTap` | `lib/ui/v2/app/v2_settings_routes.dart` (only `quotaLabel` is written; the rest are never constructed) |
| `V2UsageData` (`lib/ui/v2/settings/usage_page.dart`) | `dailyCapLabel`, `monthlyCapLabel`, `monthlyFraction`, `monthlyPercentLabel`, `billingNote`, `selectedDayId`, `selectedDayLabel`, `showFreePlanNote`, `imagesDetail`, `storageUsedLabel`, `storageFraction`, `upgradeTitle`, `upgradeMessage`, `upgradeLabel`, `onDaySelected` | `lib/ui/v2/app/v2_settings_routes.dart` |
| `V2AboutPageData` (`lib/ui/v2/settings_extra/about_page.dart`) | `systemStatus`, `onContactSupport`, `onSystemStatus`, `onRetrySystemStatus` | `lib/ui/v2/app/v2_settings_routes.dart` |
| `V2MemoryFilesPageData` (`lib/ui/v2/settings_extra/memory_files_page.dart`) | `totalSizeLabel`, `onExportAll` | `lib/ui/v2/settings_extra/memory_files_page.dart` (`MemoryFilesPage.live`) |
| `V2NotificationsPageData` (`lib/ui/v2/settings_extra/notifications_page.dart`) | `vibration`, `quietHoursLabel` | `lib/ui/v2/app/v2_settings_routes.dart` |
| `V2SharedMemoryPageData` (`lib/ui/v2/settings_extra/shared_memory_page.dart`) | `retentionLabel` | `lib/ui/v2/app/v2_settings_routes.dart` |
| `V2ShareSheetData` (`lib/ui/v2/share/share_sheet.dart`) | `anyoneCanView`, `showName`, `creatorPaysStorage` | Gallery only: `lib/ui/v2/v2_preview_data.dart` / `v2_registry.dart` (no production route) |
| `V2CommitSheetData` (`lib/ui/v2/studio/commit_sheet.dart`) | `protectedBranch` | `lib/ui/v2/studio/changes_page.dart` |
| `V2StudioWorkspaceData` (`lib/ui/v2/studio/studio_workspace_page.dart`) | `filesChanged` (never constructed; stays at the default `0`) | `lib/ui/v2/app/v2_studio_routes.dart` |

**Totals:** 22 data classes, 88 dead fields. The biggest clusters are
`V2UsageData` (15), `V2StoragePageData` (10), `V2DataControlPageData` (10) and
`V2SubagentPageData` (10) — all four screens were trimmed but their data
classes were left behind.
