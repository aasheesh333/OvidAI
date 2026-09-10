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
