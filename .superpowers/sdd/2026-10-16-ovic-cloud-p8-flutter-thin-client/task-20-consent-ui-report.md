# Task 20 (consent UI) — history import sheet + post-login hook

Status: DONE

## Scope

Created/edited exactly the assigned files:

- **New** `lib/ui/history_import_sheet.dart`
- **New** `test/history_import_sheet_test.dart`
- **Edited** `lib/ui/login_gate.dart` (post-login hook + two test seams)

No change to `lib/core/cloud/history_import.dart`, `lib/core/distribution.dart`,
`lib/core/state.dart`, `lib/main.dart`, `lib/ui/chat_screen.dart`,
`lib/ui/trajectory_screen.dart`, or `android/`.

## Sheet (`lib/ui/history_import_sheet.dart`)

`HistoryImportSheet` is shown through `showHistoryImportSheet(...)`, which uses
`showAetherSheet` with `isDismissible: false` and `enableDrag: false`.

- **Disclosure.** The consent body states exactly what is uploaded (chat
  transcripts: messages, roles, timestamps), where it goes (Ovid Cloud, this
  account only), and what is not uploaded (session event ledgers and memory
  files — no server endpoint yet). Counts come from the real
  `HistoryImportService.plan()` and render as `N chats · M messages`.
- **Two equal-weight choices.** `Import my chats` is the primary button;
  `Skip for now` is an `AetherSecondaryButton` (a full-width peer action, not
  a text link). There is no pre-checked toggle.
- **No network before consent.** `plan()` is the only pre-consent service
  call and is read-only by contract. The default service is constructed over
  `CloudRestClient.I` but nothing is sent until `run(consent: true)`.
- **Progress.** `run` receives a callback that updates the stage text
  (`ValueKey('history-import-stage')`, live region) and a determinate
  `LinearProgressIndicator` (0..1 plus a percent label). `PopScope(canPop:
  false)` while running, and the modal route is non-dismissible, so a run
  cannot be abandoned accidentally. An interrupted run is resumable because
  the service persists per-chunk progress.
- **Result.** Imported/skipped counts in plain language. A failed session
  produces a warning line ("Some chats could not be uploaded…") plus a
  `Try again` action that re-invokes `run`; the service resumes at the last
  acknowledged chunk and its deterministic `clientMsgId`s prevent duplicates.
  A clean run shows `Import complete` and `Done`.
- **Error path.** A `plan()` or `run()` exception is recorded through
  `Diag.swallow` and rendered as a non-blocking error body with `Try again`
  (re-plan) and `Skip for now`.
- **Skip marker.** The service only writes `ovid_cloud_import_done_<uid>` on a
  fully successful run, so the sheet writes the distinct
  `ovid_cloud_import_skipped_<uid>` marker itself on Skip. A failed marker
  write is swallowed (it can only cause the question to reappear later). The
  sheet never writes the done marker.
- **Seams (in the sheet, not the service).** Optional `service`, `account`,
  and `prefs` parameters. Production defaults to the real service built from
  `CloudRestClient.I` / `SessionHistoryRepository.I` and
  `AppState.sessionAccountId`.

## Login-gate hook (`lib/ui/login_gate.dart`)

`_PostLoginWelcomeGate` now runs `_startPostLogin()`: the welcome banner first
(unchanged behaviour), then the import check. The check:

1. Reads `SharedPreferences` and resolves the account from
   `historyImportAccount` (test seam) or `AppState.sessionAccountId`.
2. Returns immediately for `guest` (or an empty account).
3. Returns immediately when either `ovid_cloud_import_done_<uid>` or
   `ovid_cloud_import_skipped_<uid>` is set (accepts bool or `'true'`).
4. Calls `plan()` inside a try/catch. A failure is logged with
   `Diag.swallow('login_gate.history_import_plan', …)` and the app continues.
5. Returns when `plan.alreadyImported` is true; otherwise shows the sheet once
   (the `_importChecked` latch prevents a second show in the same mount).
   The child is always rendered, so the check never blocks the app.

The welcome overlay and the sheet share the bottom of the screen, so the sheet
waits for the welcome overlay to close (auto-dismiss or `Let's go`).

New optional `LoginGate` parameters: `historyImportService` and
`historyImportAccount`. Both are test seams; production uses the defaults.
No other login-gate behaviour changed.

## Tests (`test/history_import_sheet_test.dart`) — 10 passing

The fake is a subclass of the concrete `HistoryImportService` overriding only
`plan()`/`run()`, so no production seam was added to the service.

1. Real plan counts, both buttons, and the upload/not-uploaded disclosure.
2. Skip writes `ovid_cloud_import_skipped_u1`, does not write the done
   marker, and calls `run` zero times (no upload).
3. Import calls `run(consent: true)`, progress text and bar update from the
   callback, the choices are unavailable mid-run, and a failed session shows
   the retry line and `Try again`.
4. `Try again` re-runs with consent, then a clean result shows
   `Import complete` and no retry action.
5. Sheet text contains no token/key-like strings (`Bearer`, `sk-`, `eyJ`,
   long hex runs, api-key/secret/access-token words).
6. Login gate: done marker set → no sheet, no `plan()` call.
7. Login gate: skip marker set → no sheet, no `plan()` call.
8. Login gate: neither marker set → sheet shows once with real counts and the
   child is visible.
9. Login gate: guest account → no sheet, no `plan()` call.
10. Login gate: `plan()` throws → logged, app continues, no sheet.

## Gates

- `flutter analyze --no-pub` (shared tree) → **No issues found!** at the time
  the sheet/hook were written. A later re-run picked up other lanes' in-flight
  edits (`test/*_test.dart` referencing the removed
  `Distribution.thinOverrideForTest`/`thinClient`/`controlModeAvailable`
  members — `lib/core/distribution.dart` is being rewritten by another lane).
  **Not fixed: outside this task's scope.**
- `flutter analyze --no-pub` in a clean worktree at `HEAD` (`27c8b9a`) with
  only this task's three files applied → **No issues found!**
- `flutter test --no-pub test/history_import_sheet_test.dart` → **10/10
  passed** (shared tree at first, and again in the clean worktree).
- `flutter test --no-pub test/auth_login_gate_test.dart
  test/login_gate_hydration_test.dart` → **6/6 passed** (no regression from
  the hook).
- Full `flutter test --no-pub` in the clean worktree (`27c8b9a` + this task's
  files) → **1746 passed / 2 skipped / 0 failed**, exit 0.
- Full `flutter test --no-pub` in the shared working tree mid-edit →
  **1506 passed / 2 skipped / 42 failed**, exit 1. All 42 failures are in
  other lanes' in-flight files (the tree does not compile against the
  `Distribution`/`state.dart` edits in progress); this task's 10 tests all
  passed in that same run. Not fixed by design.

## Notes / follow-ups

- The gate uses `AppState.sessionAccountId` as the account, matching the
  service's namespace and marker derivation (`firebase:<uid>` →
  `<uid>`).
- `HistoryImportService` already provides the done marker and per-chunk
  progress; only the skip marker was added, in the sheet, as instructed.
