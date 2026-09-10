# Task 2 Report: First-Frame Startup Split

## Status

Implemented the two-phase startup split and post-frame readiness orchestration
from design sections 5.1, 5.3, 5.7, and 8.

## RED Evidence

- The initial focused test failed to compile because `AppState` did not expose
  `initializeForFirstFrame`, `initializeReadiness`, startup stage injection, or
  readiness-future caching.
- Existing boot tests then failed because their lexical assertions still
  expected sandbox self-heal in `main.dart` and the old no-argument activation
  call shape.

## Implementation

- `main()` now awaits only local first-frame state, calls `runApp`, and starts
  cached readiness work from a post-frame callback.
- First-frame hydration restores provider metadata, active root-session
  metadata and its latest 50 messages, local shell preferences, and the fast
  sandbox-presence check. It performs no marketplace, Firebase, MCP, plugin
  activation, or sandbox-maintenance work.
- Deferred hydration retains the original session JSON and merges the active
  tail with messages created before readiness, preserving old history and new
  writes without introducing the Project 2 database migration.
- `initialize()` remains the full compatibility seam and waits for both phases.
- First-frame and readiness futures are cached per `AppState`; one private boot
  token guards plugin activation so repeated readiness calls cannot advance the
  epoch again.
- `activateForBoot({bool connectMcp = true})` preserves existing callers while
  startup passes `connectMcp: false`, mounting declarations without opening MCP
  connections.
- The readiness list includes a no-op `localSafety.migrate` ordering seam for
  Task 3. No migration behavior was implemented.
- Startup stage delegates and a recorder keep tests offline and make phase
  boundaries observable.
- Firebase initialization is cached for one process boot.

## Verification

- `/home/ubuntu/sdk/flutter/bin/flutter test test/startup_first_frame_test.dart`
  passed 7 tests.
- `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "boot"`
  passed 7 tests.
- `/home/ubuntu/sdk/flutter/bin/flutter test test/startup_coordinator_test.dart`
  passed 15 tests.
- `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart`
  passed 552 tests.
- `/home/ubuntu/sdk/flutter/bin/flutter analyze --no-pub` reported no issues.
- `git diff --check` passed.

## Self-Review

- The first-frame path has no network call, plugin activation, MCP connection,
  Firebase initialization, sandbox self-heal, or full-history object hydration.
- Cold shell initialization no longer starts a second MCP reconnect outside the
  coordinator; resume keeps its existing reconnect behavior.
- The raw-session merge is tested across persistence between first frame and
  deferred hydration, including full old history and a newly sent message.
- Existing install/enable activation behavior retains MCP connection through
  the default `connectMcp: true` argument.
- `.superpowers/brainstorm/` was not modified or staged.

## Concerns

- The existing SharedPreferences storage shape still requires decoding the
  selected session JSON to extract its tail. Project 2 remains responsible for
  paged transcript storage that removes this remaining data-size sensitivity.
- Task 6 will replace the coarse marketplace and MCP readiness stages with
  concrete per-item tasks and truthful per-service outcomes.

## Fix Round 1

### RED Evidence

- Deferred deletion tests reproduced active-session and descendant resurrection
  from the retained startup snapshot, including deletion while chunked hydration
  was already running.
- A malformed-row fixture showed one bad JSON row could abort hydration and
  leave only the active tail in memory; later persistence could then truncate
  valid sessions.
- Retry tests showed activation and Firebase failures reused completed failed
  futures instead of starting fresh attempts.
- An ordering recorder showed restored-session callbacks could run at local
  hydration, before startup activation.
- A lifecycle test showed resume could invoke MCP reconnect while readiness was
  still hydrating local state.

### Changes

- Deferred session deletes now tombstone the selected session and all persisted
  descendants. `deleteAllData()` invalidates every deferred snapshot and an
  in-progress hydration generation before seeding clean state.
- Deferred rows decode independently. Valid rows hydrate despite corrupt
  siblings, unreadable raw rows remain preserved on every persistence write,
  and local hydration reports `Degraded` instead of claiming full success.
- Deferred hydration yields every 20 rows so a large history does not monopolize
  the UI isolate immediately after first paint.
- First-frame lookup scans encoded IDs before decoding and decodes only the
  active row in the normal path, including when large non-active rows precede it.
- Plugin activation now separates the once-per-boot token/epoch from retryable
  attempts. Failed coordinator retries reuse the same token and epoch; a
  successful attempt remains idempotent.
- Firebase initialization now reports failures, clears only the failed attempt,
  retries cleanly, and keeps one auth subscription after successful setup.
- Restored-session callback and checkpoint/handle recovery moved to an ordered
  `session.restore` readiness stage after hydration, safety reconciliation, and
  plugin activation. Task 5 still owns exact `session_start` semantics.
- Resume reconnect now no-ops while readiness is absent/running and reconnects
  only after the cached startup run completes.
- Added direct-call guards for every forbidden first-frame optional service.

### Verification

- `/home/ubuntu/sdk/flutter/bin/flutter test test/startup_first_frame_test.dart`
  passed 16 tests.
- `/home/ubuntu/sdk/flutter/bin/flutter test test/startup_coordinator_test.dart`
  passed 15 tests.
- `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "boot"`
  passed 7 tests.
- `/home/ubuntu/sdk/flutter/bin/flutter test test/plugin_runtime_migration_test.dart`
  passed 12 tests.
- `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart`
  passed 549 tests with 3 failures from the committed partial Task 3 migration
  work; see concerns below.
- `/home/ubuntu/sdk/flutter/bin/flutter analyze --no-pub` reported no issues.
- `git diff --check` passed.

### Remaining Dependencies and Concerns

- Task 6 owns per-plugin and per-MCP startup items. Task 2 intentionally retains
  replaceable coarse bridge stages and does not claim per-item compliance.
- SharedPreferences still materializes the full `StringList` before Dart can
  select the active row. Removing that cost requires the Project 2 database
  migration; this round minimizes Dart JSON decoding but cannot remove platform
  materialization.
- Full core's three failures are the same Task 3 WIP failures recorded in the
  controller ledger (`PLUGIN9` pending-global enable and two `PLUGIN11` install
  diagnostics fixtures). Task 2 focused, boot, coordinator, and migration suites
  are green.
