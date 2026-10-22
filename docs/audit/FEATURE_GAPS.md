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
| A4 | **Connector tool manifest is empty.** `v2ConnectorDetailForRow` never fills `tools`; the detail page now says under Permissions that the tool list is not reported, and the permissions screen can only list grants. | P1 | `lib/ui/v2/connectors/connector_detail_page.dart:899` (`v2ConnectorDetailForRow` sets no `tools`); note at `connector-tools-unreported` (`:772`) | A client for the existing `GET /mcp/catalog` (`items[].tools` = name + optional description, keyed by `curatedId`) mapped into `V2ConnectorDetailData.tools`, or a live MCP `tools/list` per saved server. |
| A5 | **No collaboration turn queue.** `liveDataFor` sets `queueLabel: null` and leaves `turnQueue` empty; the banner can say whose turn it is but not who is waiting. | P1 | `lib/ui/v2/app/v2_collab_routes.dart:109`; `lib/ui/v2/collab/turn_banner.dart:90` ("Retained for callers that used to render the queue") | A server queue endpoint (ordered waiters + request/raise priority) and a state field for it. |
| A6 | **No device review and no two-step sign-in.** There is no device/session-list endpoint (only `POST`/`DELETE /devices` for the FCM token) and no 2FA status endpoint, so the account cannot show trusted devices or let someone turn on a second factor. Account health states only the four facts it can read — plan, today's usage, storage, deletion — and does not mention or imply either missing feature. | P2 | `lib/ui/v2/settings/account_health_page.dart` (four rows, no device/2FA copy); `lib/core/cloud/cloud_rest.dart:686` (push-token registration only) | A device/session list endpoint and a 2FA status endpoint, then new rows backed by them. |
| A7 | **Response wait has no auto-extend or notify-at-limit.** The limit persists and the watchdog reads it, but nothing extends a quiet run or notifies at the limit. | P2 | `lib/ui/v2/settings_extra/response_wait_page.dart:1`; `lib/ui/v2/app/v2_settings_routes.dart:1049` | A watchdog consumer plus a notify/extend policy (and a field to carry it). |
| A8 | **No payment-history source.** `_plans` never passes `history`; the "Payment history" block is hidden even for paid accounts. | P2 | `lib/ui/v2/app/v2_settings_routes.dart:188` (no `history:` argument); `lib/ui/v2/settings/plan_billing_page.dart:667` | A Play/RevenueCat transaction-history endpoint mapped into `V2BillingHistoryEntry`. |
| A9 | **No artifact version history.** The gateway has no version/revision route, so the detail screen has no version list and no restore. The unused `versionLabel` slot was removed rather than filled with a fake. | P2 | `cloud/apps/gateway/src/routes/artifactVault.ts` (`GET /artifacts` and `GET /artifacts/:id/url` only); `cloud/apps/gateway/src/routes/artifacts.ts` (session list + URL) | `GET /artifacts/:id/versions` plus a version list/restore UI fed by it. |
| A10 | **The browser viewer cannot do history, upload, download or close-tab.** The gateway accepts only five viewer ops for a browser attach — `browser_attach`, `browser_detach`, `browser_input`, `browser_takeover`, `browser_switch_tab` — and sends back only `browser_state`, which carries no history, download or transfer field. The agent can do all five with its own tools (`browser_back`, `browser_forward`, `browser_reload`, `browser_upload`, `browser_download`, `browser_close_tab`); the live page omits the viewer controls and its doc comment records why. | P1 | `lib/ui/v2/browser/browser_live_page.dart:30` (doc comment: the five viewer ops, each omitted control and its reason); `cloud/packages/shared/src/ws.ts:19-24` (viewer ops); `cloud/packages/shared/src/browser.ts:61` (`BrowserStateDto`: no history/download field) | Viewer ops for history/reload/upload/download/close, plus a download name + URL on `browser_state` (or a browser event the screen can attach to). |
| A12 | **Schedule "retry" re-runs the schedule, not the failed run.** The run timeline's retry calls `controller.runNow(schedule)`. | P2 | `lib/ui/v2/schedules/schedules_flow.dart:353` (`_retry` → `runNow`) | A per-run retry endpoint (`POST /schedules/:id/runs/:runId/retry`) or an explicit product decision that retry means "run now". |
| A13 | **"Crash reports" row now lands on a real consent switch.** | P2 | **Resolved 2026-10-22:** `DataControlPage._crashRow` renders the consent switch (`lib/ui/v2/settings/data_control_page.dart:316-360`), and the adapter passes `crashReports`/`onCrashReportsChanged` (`lib/ui/v2/app/v2_settings_routes.dart:739-753`). | — |
| A14 | **Share-fork needs the share backend.** The recipient path has a Fork action, but it only works when the collaboration/share service is configured. | P1 | `lib/ui/v2/app/v2_app_shell.dart:1959` (`_collabAvailable`), `:1967` (`_readOnlyAvailable`) | The share service deployed and reachable; no UI change needed once it is. |

## B. Needs a core model field

| # | Gap | Sev | Evidence (file) | What would make it true |
|---|---|---|---|---|
| B1 | **`BrowserState` carries `fps` and `headless`.** | P2 | **Resolved 2026-10-22:** `BrowserState` stores and parses both (`lib/core/cloud/browser_stream.dart:124-198`), the live page passes them (`lib/ui/v2/browser/browser_live_page.dart:575-576`), and the status pill renders the real frame rate / headless badge only when the server reported them (`lib/ui/v2/browser/browser_page.dart:289-301`). | — |
| B3 | **No artifact version or creator-run field.** The artifact row has `origin` and `sessionTitle` (the detail screen now shows the origin chat), but no version and no run id, so the screen cannot say "version 3" or who ran it. | P2 | `lib/core/cloud/artifact_vault.dart:50-63` (no `version`/`createdByRunId`) | `version` and `createdByRunId` on the artifact row, plus a version list if history ships (A9). |
| B4 | **No avatar upload.** The account avatar renders the real Firebase Auth `photoURL` (with an initials fallback), but there is no storage endpoint, so no change-photo control is drawn. | P2 | `lib/ui/v2/settings/account_page.dart` (`V2AccountProfile.photoUrl`, `_ProfileAvatar`); `lib/ui/v2/app/v2_settings_routes.dart` (`_account` passes `firebase.photoUrl`) | An upload endpoint that writes the avatar and updates `photoURL`, then a change-photo action. |
| B5 | **No project sort/status fields.** The projects list had no sort key or status, so the designed chips could not be built. | P2 | `lib/ui/v2/sidebar/projects_page.dart` (`V2ProjectsData` / `V2Project`); `lib/ui/v2/app/v2_app_shell.dart` project adapter | **Resolved 2026-10-22 (sort):** `V2Project.updatedAt` (from the DTO's `updatedAt`) feeds a client-only sort — `Recent` / `Name` / `Chats` — held in page state, so no `sortKey` field was needed. No `status` field: there is no project status anywhere in the product, so that half is a design change, not a code gap. |
| B6 | **No per-schedule notification override.** The editor exposes one global notification path; the schedule model has no channel/quiet-hours override. | P2 | `lib/ui/v2/schedules/schedule_editor_page.dart:51` (`V2ScheduleEditorData`); `lib/core/cloud/schedule_client.dart` | A per-schedule `notify`/`quietHours` field. |
| B7 | **No collaboration queue/priority field.** Even with A5, the state model has no ordered waiter list or priority flag. | P1 | `lib/core/collaboration/models.dart` (`CollaborationState`); `lib/ui/v2/collab/turn_banner.dart:87` | Add `turnQueue` and `priority` to the collaboration projection. |

## C. Needs a product decision

| # | Gap | Sev | Evidence (file) | Decision needed |
|---|---|---|---|---|
| C1 | **English-only UI.** 101 `TODO(l10n)` markers; the language picker is a voice/assistant preference, not app localization. | P1 | `lib/ui/v2/**` (`TODO(l10n)`), e.g. `lib/ui/v2/chat/chat_page.dart:21` | Ship English-only and say so, or fund the ARB extraction pass. |
| C2 | **`model_chip` is gallery-only.** The shell opens the full model picker from the chip; the quick menu has no production route. | P2 | `lib/ui/v2/v2_registry.dart:124`; no `V2ModelChipMenu` in `lib/ui/v2/app/` | Wire the menu or remove the registry entry. |
| C3 | **`system_states` is gallery-only.** Chat renders inline plan/offline/error states; the dedicated state page is unreachable. | P2 | `lib/ui/v2/v2_registry.dart:137`; no `V2SystemStatesPage` in `lib/ui/v2/app/` | Route blocking conditions to this page, or remove the entry. |
| C4 | **`share_sheet` was a duplicate gallery screen.** `ShareSheet` is not a screen: production's `ShareChatSheet` composes it as the creator link surface, and covers the recipient path itself. | P2 | `lib/ui/v2/v2_registry.dart` (no `share_sheet` entry); `lib/ui/v2/share/share_chat_sheet.dart:296` (`ShareSheet` as the owner body); `lib/ui/v2/app/v2_app_shell.dart:2295` (`ShareChatSheet`) | **Resolved 2026-10-22:** the registry row, its web-gallery row and the reachability row were removed. The widget stays because it is the creator surface, not a second screen. |
| C5 | **Projects have no sort/status chips.** The designed filter row is absent. | P2 | `lib/ui/v2/sidebar/projects_page.dart` (`V2ProjectSort`, `_SortChip`) | **Resolved 2026-10-22 (sort):** one chip row — `Recent`, `Name`, `Chats` — renders at 4+ projects and behaves as a radio group. The `status` chip is dropped from the design: the product has no project status. |
| C6 | **Memory has no accuracy card.** The designed "what Ovid got right/wrong" surface is absent. | P2 | `lib/ui/v2/settings/memory_page.dart:147` (`V2MemoryPageData` has no accuracy fields) | Build it on real correction events, or drop it. |
| C7 | **Connectors have no installed/available tabs.** One list with a filter menu replaces the designed tabs. | P2 | `lib/ui/v2/connectors/connectors_page.dart:23` (`V2ConnectorsData` single list) | **Resolved 2026-10-22:** the screen now shows `Installed (n)` / `Available (n)` tabs over the same rows. Available is the built-in catalogue (168 entries) with a one-line description and an `Add` action per row that opens `AddConnectorPage` with the entry preset; search and the kind filter apply to the active tab; the empty states are `No connectors yet` (Installed) and `Nothing matches` (search/filter). Tabs announce their selected state and the panel is labelled. |
| C8 | **Schedules have no total/CTA card and no upcoming queue.** The list is cards only. | P2 | `lib/ui/v2/schedules/schedules_page.dart:89` (`V2SchedulesData`) | **Resolved 2026-10-22:** one summary line above the list — `3 schedules · next in 4h`, or `3 schedules · all paused` when nothing is enabled — built from `V2SchedulesData.summary` (count = `schedules.length`, next = earliest `nextOccurrence` among enabled rows). The list is now ordered next-to-run first, then by title, paused last (`V2SchedulesData.ordered`). No separate upcoming section: it would duplicate the cards. |
| C9 | **Runs have no upcoming queue; stats are one line, not tiles.** The trajectory page now carries a muted summary line above the timeline (`12 steps · 3 tools · 2 subagents · 41s`), but the session records no queued work, so no upcoming queue exists. | P2 | `lib/ui/v2/runs/run_trajectory_page.dart` (`V2RunTrajectoryPageData.statStripLabel`); `lib/ui/v2/app/v2_run_routes.dart:121` (`trajectoryDataFor` passes the session's own start/end) | **Decided 2026-10-22:** keep the strip as one flat line — tiles would be cards, which the design system does not use. A running run reads `12 steps so far` with no duration; an unknown end reads `—`. The queue stays out until the runtime records queued work. |
| C10 | **No collab "raise priority" control.** The queue is absent (A5) and there is no priority action. | P2 | `lib/ui/v2/collab/turn_banner.dart:92` | Build with A5/B7 or remove from the design. |
| C11 | **No notification/avatar entry point in the top bars.** Settings owns both; the chat header has no bell/avatar. | P2 | `lib/ui/v2/chat/chat_page.dart` (top bar callbacks), `lib/ui/v2/app/v2_app_shell.dart` | Add the entry point or keep it settings-only. |
| C12 | **Live chat has no message edit/branch/regenerate.** The transcript is read-only apart from copy/retry actions. | P2 | `lib/ui/v2/chat/live_chat_page.dart`; `lib/ui/v2/chat/transcript_actions.dart` | **Resolved 2026-10-22 (client):** each stored assistant answer has one quiet `Message actions` menu — `Copy`, `Branch from here` (any answer) and `Regenerate` (the newest stored answer of a settled run only; it confirms and names the later-message count first). Branch navigates to the new session and reports the real outcome; a failure shows the server's own copy and nothing is removed before the server confirms. The gateway routes are still release-gated (`history_actions_unavailable`, `cloud/apps/gateway/src/routes/messages.ts:72`), so a tap surfaces that message instead of editing history. |
| C13 | **Model picker states no unmeasured speed or price.** `V2ModelOption` carries no speed field, and a row's cost is one of `Included` (the plan covers the model), `Your key` (a connected provider key), or absent on a gated row. | P2 | `lib/ui/v2/chat/model_picker_sheet.dart` (`V2ModelOption`); `lib/ui/v2/app/v2_app_shell.dart:760` (`_openModelPicker`) | **Resolved 2026-10-22:** `speed` was removed from the model contract, the search filter and the preview data, because the app holds no per-model latency or tokens-per-second value (only the running session's analytics). The blanket `Included` hint was replaced by the plan fact the row can honour. Re-add a speed hint only with measured per-model telemetry. |
| C14 | **Artifact documents are metadata-only.** No embedded document renderer; "Open externally" is the only path. | P2 | `lib/ui/v2/library/artifact_preview.dart:34` (`V2ArtifactPreviewType.document`) | Keep external-only (recommended) or add a renderer. |
| C15 | **Free-plan USD allowance vs token cap.** `free_daily_usd = 0.15` still gates before the 50M token cap. | P0 | `server/billing` / `TODO.md` P0; plan table `lib/ui/v2/settings/usage_page.dart` | Raise/remove the USD allowance so the token cap is the real gate. |
| C16 | **Yearly billing is a product choice, not just a SKU.** The code can attempt a yearly product, but no yearly product exists in Play/RevenueCat. | P1 | `lib/core/billing_products.dart:28`; `lib/ui/v2/app/v2_settings_actions.dart:174` | Create the products (D2) or remove the yearly toggle. |
| C17 | **Usage has no request/image counters.** `requestsLabel`/`imagesLabel` exist only to decide whether the screen has data; the rendered page shows tokens, not request or image counts. | P2 | `lib/ui/v2/settings/usage_page.dart:103` (`hasData`), `:135` (`countersText`), `:346` (render) | **Resolved 2026-10-22:** the hero ends with one caption line built from real counters — `42 requests · 86 images today` — sourced from `/usage`'s `today.requests` / `today.images` (`cloud/apps/mint/src/usage.ts:71-78`). `/usage/history` carries `runs`/`modelCalls` but **no image counter** (`cloud/apps/gateway/src/routes/usageHistory.ts:71-80`), so when `/usage` is unavailable the request count falls back to the ledger's *today* bucket `modelCalls` (`v2_settings_routes.dart:_usage`) and the image count is omitted rather than faked as 0. Dead fields were deleted from `V2UsageData` (`dailyCapLabel`, `monthlyCapLabel`, `billingNote`, `monthlyFraction`, `monthlyPercentLabel`, `imagesDetail`, `selectedDayId`, `selectedDayLabel`, `showFreePlanNote`, `storageUsedLabel`, `storageFraction`, `upgradeTitle`/`upgradeMessage`/`upgradeLabel`, `onDaySelected`), with their write sites in `_usage`, plus `V2UsageDay.imageCount` and `V2UsageModel.providerLabel`/`isCustomProvider`. `V2UsageData.models` stays: it is C18's data. |
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
Fields marked *never constructed* are only defaults in the data class. The
`V2UsageData` row was cleared by C17, which deleted those fields and their write
sites.

| Data class (declaration) | Dead fields | Constructed in |
|---|---|---|
| `V2ComposerPlusData` (`lib/ui/v2/chat/composer_plus_sheet.dart`) | `customConnectorsUsed` (read only by the unused `connectorsStateLabel`) | `lib/ui/v2/chat/chat_page.dart`, `lib/ui/v2/chat/live_chat_page.dart` |
| `V2CollabLivePageData` (`lib/ui/v2/collab/collab_live_page.dart`) | `participants`, `typingName`, `creatorPaysStorage` | `lib/ui/v2/app/v2_collab_routes.dart` |
| `V2CollabMembersPageData` (`lib/ui/v2/collab/collab_members_page.dart`) | `chatName`, `creatorName`, `storageUsedLabel`, `storageTotalLabel`, `storageFreeLabel`, `storagePercent` | `lib/ui/v2/app/v2_collab_routes.dart` |
| `V2CollabTurnBannerData` (`lib/ui/v2/collab/turn_banner.dart`) | `timeLeftFraction` (assert-only), `maxVisibleQueue` (read only by the unused `visibleQueue`/`hiddenQueueCount`) | `lib/ui/v2/collab/collab_live_page.dart` |
| `V2ConnectorDetailData` (`lib/ui/v2/connectors/connector_detail_page.dart`) | `syncedLabel`, `agents`, `safetyNote` | `lib/ui/v2/connectors/connector_detail_page.dart` (`v2ConnectorDetailForRow`, called from `connectors_page.dart`) |
| `V2ArtifactsData` (`lib/ui/v2/library/artifacts_page.dart`) | `totalSizeLabel` (never constructed) | — |
| `V2SubagentPageData` (`lib/ui/v2/runs/subagent_page.dart`) | `instanceLabel`, `progressKnown`, `progress`, `timeLimitLabel`, `remainingLabel` | `lib/ui/v2/app/v2_run_routes.dart` |
| `V2ScheduleRunsData` (`lib/ui/v2/schedules/schedule_runs_page.dart`) | `avgRuntimeLabel` | `lib/ui/v2/schedules/schedules_flow.dart` |
| `V2AppearancePageData` (`lib/ui/v2/settings/appearance_page.dart`) | `shareSessionMemory`, `onMemoryFilesTap` | `lib/ui/v2/app/v2_settings_routes.dart` |
| `V2CredentialsPageData` (`lib/ui/v2/settings/credentials_page.dart`) | `cloudKeyStatusLabel`, `cloudKeyStatusDetail`, `onAddToken` | `lib/ui/v2/app/v2_settings_routes.dart` |
| `V2DataControlPageData` (`lib/ui/v2/settings/data_control_page.dart`) | `onExportImport`, `onPermissions`, `onStorage`, `onResetMemory`, `crashReports`, `onCrashReportsChanged`, `permissionSummary`, `storageUsedLabel`, `storageFreeLabel`, `storageFraction` | `lib/ui/v2/app/v2_settings_routes.dart` |
| `V2MemoryPageData` (`lib/ui/v2/settings/memory_page.dart`) | `shareSessionMemory`, `globalVersionLabel`, `onShareSessionMemoryChanged`, `onFileDownload` | `lib/ui/v2/app/v2_settings_routes.dart` |
| `V2StoragePageData` (`lib/ui/v2/settings/storage_page.dart`) | `quotaLabel`, `previewSizeLabel`, `trashItems`, `trashSizeLabel`, `largestItems`, `offlineLabel`, `onClearPreviews`, `onDeleteOldChats`, `onEmptyTrash`, `onLargestItemTap` | `lib/ui/v2/app/v2_settings_routes.dart` (only `quotaLabel` is written; the rest are never constructed) |
| `V2AboutPageData` (`lib/ui/v2/settings_extra/about_page.dart`) | `systemStatus`, `onContactSupport`, `onSystemStatus`, `onRetrySystemStatus` | `lib/ui/v2/app/v2_settings_routes.dart` |
| `V2MemoryFilesPageData` (`lib/ui/v2/settings_extra/memory_files_page.dart`) | `totalSizeLabel`, `onExportAll` | `lib/ui/v2/settings_extra/memory_files_page.dart` (`MemoryFilesPage.live`) |
| `V2NotificationsPageData` (`lib/ui/v2/settings_extra/notifications_page.dart`) | `vibration`, `quietHoursLabel` | `lib/ui/v2/app/v2_settings_routes.dart` |
| `V2SharedMemoryPageData` (`lib/ui/v2/settings_extra/shared_memory_page.dart`) | `retentionLabel` | `lib/ui/v2/app/v2_settings_routes.dart` |
| `V2ShareSheetData` (`lib/ui/v2/share/share_sheet.dart`) | `anyoneCanView`, `showName`, `creatorPaysStorage` | `lib/ui/v2/share/share_chat_sheet.dart` (`_buildOwner`); the three fields are never set |
| `V2CommitSheetData` (`lib/ui/v2/studio/commit_sheet.dart`) | `protectedBranch` | `lib/ui/v2/studio/changes_page.dart` |
| `V2StudioWorkspaceData` (`lib/ui/v2/studio/studio_workspace_page.dart`) | `filesChanged` (never constructed; stays at the default `0`) | `lib/ui/v2/app/v2_studio_routes.dart` |

**Totals:** 21 data classes, 68 dead fields. The biggest clusters are
`V2StoragePageData` (10) and `V2DataControlPageData` (10) — those screens were
trimmed but their data classes were left behind. `V2UsageData` is no longer on
this list: C17 deleted its 15 dead fields and the page now renders its
request/image counters. `V2SubagentPageData` now renders its step, goal, files
and log tail; the five fields still listed above are the remainder.
