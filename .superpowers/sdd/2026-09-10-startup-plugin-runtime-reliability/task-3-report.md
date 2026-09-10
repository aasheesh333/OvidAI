# Task 3 Report: Canonical Runtime Rows and Legacy Migration

## Status

Implemented canonical runtime-row persistence and fail-closed legacy migration.
Normalized activation entries remain execution authority; runtime UI rows are
projected by canonical `runtimeId`, while v1 display-name stores now contain
only `runtimeId == null` legacy/native rows.

## RED Evidence

- The six focused Task 2 carryover failures reproduced in PLUGIN9: punctuation
  collision, bounded provider names, pending-global enable, same-name
  identities, legacy connect alias, and missing-owner credentials. All six
  fixtures used IDs or runtime roots rejected by the new canonical/contained
  runtime gates. The production behavior was correct; fixtures were corrected
  to use canonical `publisher/name` IDs and a contained committed root.
- A pre-reconciliation legacy hook executed before safety migration. A new test
  failed with one hook invocation, proving that `migrationRequired` alone did
  not protect the window before persisted rows were reconciled.
- A persisted `failed` activation reconstructed as enabled/Ready. A new test
  expected Failed and received Ready.
- A completed migration rewrote its marker. Injecting marker-write failure on a
  second run raised instead of proving marker read/idempotence.
- Runtime-authored custom and marketplace rows were still emitted by v1
  writers. A new test found `Runtime Custom` in `ovid_custom_plugins_v1`.
- Local hydration merged marketplace rows before canonical reconstruction. A
  v1 runtime row retained its stale `old` version instead of the activation
  entry's authoritative `1.0.0`.
- Corrupt activation JSON could leave a stale in-process registration active.
- An injected canonical-row write failure initially had no test seam; the RED
  compile failure established the expected fail-before-marker behavior.
- Full core exposed one compatibility regression after narrowing legacy
  dispatch: registered but inactive normalized rows returned `not found`
  instead of the existing scope-refusal message.

## GREEN Implementation

- Added canonical `ovid_plugin_rows_v2` reconstruction, sorted persistence,
  exact-ID field-level metadata merge, and `ActivePluginRuntime` projection.
- Added strict canonical ID, contained content-root, digest grant, capability,
  and environment-name validation.
- Centralized invalid runtime deactivation across reconciliation, boot, retry,
  and enable; missing grants become Migration required, missing content and
  persisted failed activations remain Failed, and corrupt/orphan registrations
  are unregistered.
- Added a pre-reconciliation execution gate. Legacy hook maps, skill roots, and
  generic dispatch cannot execute until local safety reconciliation succeeds.
  Legacy fallback additionally requires `runtimeId == null`, while registered
  normalized rows retain an honest scope-refusal compatibility path.
- Reconstructs canonical rows before marketplace restore. Marketplace metadata
  can enrich only an existing exact runtime ID; a v1 orphan runtime row cannot
  create a live normalized row. Name-based marketplace merge applies only to
  legacy rows.
- Restricted plugin-state, custom-plugin, and merged-marketplace v1 writers to
  `runtimeId == null` rows. Legacy migration flags/reasons remain persisted.
- Checked every migration-critical activation, canonical-row, plugin-state,
  custom-row, and marketplace write result. The completion marker is written
  only after all stores succeed and is not rewritten once true.
- Preserved the narrow executable-legacy predicate: installed, enabled,
  `runtimeId == null`, and either a source/cache or hook declaration. Native
  source-less feature toggles stay enabled.
- Kept runtime statuses and reasons in the canonical row projection and in
  `AppState.pluginSafetyStatuses` for later startup/status UI tasks.

## Verification

- `flutter test test/plugin_runtime_migration_test.dart`: 30/30 passed.
- Exact six PLUGIN9 carryover failures: 6/6 passed.
- `flutter test test/core_regression_test.dart --plain-name "PLUGIN5"`: 9/9 passed.
- `flutter test test/core_regression_test.dart --plain-name "PLUGIN7"`: 8/8 passed.
- `flutter test test/core_regression_test.dart --plain-name "PLUGIN8"`: 26/26 passed.
- `flutter test test/core_regression_test.dart --plain-name "PLUGIN9"`: 25/25 passed.
- `flutter test test/core_regression_test.dart --plain-name "PLUGIN11"`: 13/13 passed, including detail and mounted diagnostics.
- `flutter test test/startup_first_frame_test.dart`: 22/22 passed.
- `flutter test test/session_stop_isolation_test.dart`: 16/16 passed.
- `flutter test test/core_regression_test.dart`: 552/552 passed.
- `flutter analyze --no-pub`: no issues.
- `git diff --check`: clean.

## Self-Review

- Pre-reconcile execution: hooks, skill roots, and generic legacy dispatch are
  blocked until the safety task succeeds.
- Identity: canonical IDs have exactly two normalized segments; display names
  remain metadata and never identify runtime rows.
- Ordering: local hydration reconstructs activation-backed canonical rows before
  v1 marketplace restore; safety migration precedes boot activation.
- Fail-close: malformed IDs, identity mismatch, arbitrary roots, corrupt
  activation JSON, orphan v2 rows, missing grants, missing content, and write
  failures cannot leave active contributions or a truthful completion marker.
- Persistence: activation fields override exact-ID stored metadata, which
  overrides exact-ID catalog metadata, which overrides manifest fallbacks.
  Output maps are sorted and repeated reconciliation is byte-idempotent.
- Legacy: v1 readers/writers apply only to runtimeId-null rows, migrated custom
  state remains durable, cache content is preserved, and native seed rows are
  exempt from executable migration.
- Secrets: seeded secret values remain only in secure storage and do not appear
  in any preferences value.
- Startup/stop preservation: first-frame startup and session-scoped Stop suites
  remain green.

## Concerns

- Task 4 still owns mounting normalized runtime skills with session scope.
- Task 7 still owns durable cross-restart startup-status records and Plugins UI
  presentation. Task 3 preserves canonical row reasons and in-process safety
  statuses for those consumers.
- Flutter dependency resolution reports available package upgrades; no
  dependency changes were made.
