# Task 14 — Schedule screen → P4 REST

Status: IN PROGRESS

## Scope
- New: `lib/core/cloud/schedule_client.dart`, `test/cloud_schedule_client_test.dart`
- Rewritten data bindings: `lib/ui/schedule_screen.dart`
- Deleted: `lib/core/schedule_coordinator.dart`, `android/.../ScheduleAlarmReceiver.kt`,
  `ScheduleFallbackJob.kt`, `BackgroundStopLatch.kt` (+ test), exact-alarm manifest
  entries, `ChatSession.schedules`, schedule-runtime members in `agent_service.dart`.
- Modified: `lib/main.dart`, `lib/core/state.dart`, `lib/core/agent_service.dart`,
  `lib/core/plan_mode.dart`, `lib/core/cloud/cloud_rest.dart` (DELETE verb).

## Server-shape reconciliation (built P4 code is the contract)
- `GET /schedules` answers `Page<ScheduleDto>` (`{items, nextCursor}`), not a bare list.
- `ScheduleDto.sessionId` is non-nullable; `trigger` is a discriminated union with
  server keys `{kind:'at',at}`, `{kind:'every',seconds}`, `{kind:'daily_at',time,tz}`,
  `{kind:'cron',expr,tz}` — NOT the brief's `everySeconds`/`dailyAt`/`cron`.
- `lastResult` is `ScheduleLastResult {status,code,message,finishedAt,ranLate}` —
  there is no `summary`; the summary-equivalent is `message`.
- `ScheduleRunDto` is `{id,scheduleId,scheduledFor,runId,status,attempt,ranLate,error,startedAt,finishedAt}`
  — no `summary`.
- `create` defaults `maxRetries` to 0 (server service default), not the brief's 1.
- `DELETE /schedules/:id` answers 204 with an empty body; `CloudRestClient` had no
  DELETE verb, so a minimal `delete()` was added.
- `parseDate` keeps the coordinator's exact regexes AND its throwing semantics
  (`DateTime parseDate`, `FormatException`); the brief's `DateTime?` signature was
  not adopted because AG4 pins verbatim semantics and the screen relies on throws.
- `list()` follows `nextCursor` pages; the screen requests `includeCancelled: true`
  to preserve the cancelled-history view the old local list had.
- `daily_at` / `cron` need an IANA zone; Dart only exposes an abbreviation, so
  `ScheduleClient.deviceTimeZone()` reads `TimeZone.getDefault().id` over the
  existing `ovid/native` channel (new `timeZoneId` case) and falls back to UTC.
- `ChatSession.schedules` was DELETED (not kept as a cache): the screen owns
  its own server list, and no other consumer remained. The persistence
  signature now covers `compactionState`, which the ported nested-mutation
  tests exposed as missing.
- New UI copy went to `lib/l10n/app_en.arb` (10 keys) and `app_localizations*`
  was regenerated; the hard-coded-literal ratchet for the screen is 21 (was 24).

## Gates
- `flutter analyze` → **No issues found!**
- `flutter test test/cloud_schedule_client_test.dart` → **16/16 passed**
- Schedule UI suites (`ui_redesign/schedule_screen_test`, `schedule_ui_test`,
  `schedule_premium_test`, `schedule_pickers_test`,
  `ui_finish_05_schedule_test`) → **48/48 passed**
- `flutter build apk --debug` → **✓ Built**
- Affected non-schedule suites (manifest/state/backup/plan-mode/token/l10n) →
  **all passed**
- Full `flutter test --no-pub` → **3988 passed / 7 skipped / 0 failed**
  (first parallel run had 1 failure in `recent_models_test` — a JSON file
  read/write race; it passed in isolation and on the rerun, and touches no
  schedule code. Test-count delta: the two deleted coordinator suites held
  29 tests (15 + 14); the rewritten UI suites went 34 → 30; the new client
  suite adds 16. Net −17 schedule tests.)

## Files
New:
- `lib/core/cloud/schedule_client.dart`
- `test/cloud_schedule_client_test.dart`
- `test/support/schedule_fake.dart`
- this report

Modified:
- `lib/ui/schedule_screen.dart` (data bindings rewritten; widget tree kept)
- `lib/core/cloud/cloud_rest.dart` (DELETE verb for the 204 route)
- `lib/core/state.dart` (`ChatSession.schedules` removed; `compactionState`
  added to the persistence signature)
- `lib/core/agent_service.dart` (schedule import, tool defs, dispatch,
  stop-hook, notification hook, `scheduledTask` plumbing and the whole
  runtime block removed; `debugPauseScheduleTimerForTest` retained as a no-op
  until Task 19 deletes the class)
- `lib/core/cloud/agent_surface.dart`, `lib/core/cloud/cloud_agent_facade.dart`
  (`scheduledTask` parameter removed)
- `lib/core/plan_mode.dart` (`schedule_list` allowlists)
- `android/app/src/main/AndroidManifest.xml`, `android/app/src/play/AndroidManifest.xml`
- `android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt` (schedule
  alarm/bridge removed; `timeZoneId` added)
- `lib/l10n/app_en.arb`, `lib/l10n/app_localizations.dart`,
  `lib/l10n/app_localizations_en.dart`
- `test/background_manifest_static_test.dart`, `test/session_state_acceptance_test.dart`,
  `test/settings_actions_integration_test.dart`, `test/wave2_settings_backup_test.dart`,
  `test/plan_mode_allowlist_test.dart`, `test/token_budget_test.dart`
- `test/ui_redesign/schedule_screen_test.dart`, `test/schedule_ui_test.dart`,
  `test/schedule_premium_test.dart`, `test/schedule_pickers_test.dart`,
  `test/ui_finish_05_schedule_test.dart`

Deleted:
- `lib/core/schedule_coordinator.dart`
- `test/schedule_coordinator_test.dart`, `test/schedule_catchup_test.dart`
- `android/.../ScheduleAlarmReceiver.kt`, `android/.../ScheduleFallbackJob.kt`,
  `android/.../BackgroundStopLatch.kt`, `android/app/src/test/.../BackgroundStopLatchTest.kt`

## Deferred
- `AgentService.debugPauseScheduleTimerForTest` is a no-op compatibility seam
  (~80 unrelated suites call it in `setUp`); Task 19 deletes the class.
- `BackgroundNotifier.syncKeepActive()` still invokes `bgSetKeepActive`; the
  native handler is gone and the call is caught as `MissingPluginException`.
  The keep-alive pref has no consumer after this task; T17 removes the
  notification-runtime residue.
- The Schedule screen does not expose a create form (the widget tree never
  had one); `ScheduleClient.create` is implemented and tested for the agent/
  REST path.
- `ScheduleClient.runs()` is implemented and tested; the screen renders the
  embedded `lastResult` (the server's authoritative feed for the card) rather
  than issuing one request per row.
