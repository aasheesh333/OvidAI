# Task 5 Report — Exactly-once session lifecycle dispatch

## Status

Complete. Implemented exactly-once `session_start` dispatch for created,
implicit, restored, and subagent sessions, with session-aware skill refresh
and activation ordering, per-boot idempotence, and HookService concurrency
that no longer suppresses distinct concurrent sessions.

## Commit

- Message: `feat: dispatch session-start hooks exactly once`
- Files:
  - Create `lib/core/session_lifecycle_service.dart`
  - Modify `lib/core/state.dart`
  - Modify `lib/core/agent_service.dart`
  - Modify `lib/core/plugin_runtime.dart`
  - Modify `lib/core/hook_service.dart` (required by the concurrency ruling)
  - Create `test/session_plugin_lifecycle_test.dart`
  - This report

## Implementation

### `SessionLifecycleService` (`lib/core/session_lifecycle_service.dart`)

- `enum SessionStartReason { created, implicit, restored, subagent }`.
- `sessionStarted(ChatSession, {required reason})` reserves a process-local
  future keyed by `bootGeneration:sessionId` **before** the first await, so
  duplicate concurrent callers share the same in-flight future and the first
  reason wins. Reservations are never removed on failure.
- Order per session: await the captured boot token's activation-settled
  barrier -> `AgentService.I.refreshSkills(sessionId: session.id)` -> fire
  `session_start` directly through `HookService.I.fire` (no
  `hasHookListeners` pre-check) with
  `{reason, parentSessionId: session.parentId, isSubagent: parentId != null}`
  and the session model.
- Fail-open: refresh/hook errors are swallowed; sessions stay usable.
- Test seams: `bootTokenProviderForTest`, `activationWaiterForTest`,
  `skillRefresherForTest`, `hookDispatcherForTest`, `resetForTest`,
  `drainForTest`, `bootGenerationForTest`.

### Boot identity (`lib/core/state.dart`)

- Exposes `Object get bootToken` (the Task 2 process-local token, **not**
  `StartupCoordinator._runToken`) and
  `Future<void> get bootActivationSettled`, completed in a `finally` around
  the real `_activatePluginsForBoot()` body. The single production
  `_pluginBootActivator(_bootToken, false)` call site is preserved.
- `_maybeFinishSessionRestore` still requires successful `skill.mount`
  settlement plus hydration + activation, memoizes completion, restores run
  checkpoints, then awaits the lifecycle service for the restored/implicit
  active root.
- Wiring:
  - Constructor provisional root is deferred (`_pendingActiveRootReason =
    implicit`); no dispatch from the constructor.
  - `_setFirstFrameActiveSession` (persisted root) sets `restored`.
  - `_ensureActiveSession` dispatches `implicit` once for a real root created
    after hydration; no-op when it reuses an existing root.
  - `newSession()` stays synchronous and dispatches `created` after a tracked
    persistence completion.
  - `onSessionsLoaded` keeps only handle restore / interrupted-run recovery;
    the old unawaited, listener-gated `session_start` block is removed.
  - `onSessionSwitched` never fires lifecycle.
- Test seam `drainSessionLifecycleForTest()` awaits tracked dispatches.

### Subagents (`lib/core/agent_service.dart`)

- One canonical `_announceSubagentStart` helper used by both
  `_handleDispatchAgent` and workflow/Ralph `_spawnChild`:
  assign `agentId` -> `await AppState.I.persistSessions()` ->
  `await SessionLifecycleService.I.sessionStarted(child, subagent)` ->
  `await HookService.I.fire('subagent_start', ...)` with the unchanged
  payload (`subagentId`, `parentSessionId`, `label`, `background`) and child
  model -> then start the child run.
- Old unawaited `subagent_start` pre-checks removed. `continueSubagent` is
  untouched and fires neither start event.
- Background dispatch yields one event-loop turn after starting the child so a
  fail-fast background child's settlement notice is observable before the
  acknowledgement returns (preserves PR16 without changing the test).

### `PluginRuntimeManager` boot activation (`lib/core/plugin_runtime.dart`)

- In-flight activation is shared by concurrent callers carrying the same boot
  token (`_bootActivation` / `_bootActivationToken`), cleared on completion so
  retry/re-activation re-runs while reusing `_bootEpoch` — the persisted epoch
  increments exactly once per genuinely new token, and resume/repeated startup
  never increments.

### HookService concurrency (`lib/core/hook_service.dart`)

- Recursion guard is keyed by `sessionId|canonicalEvent`, so concurrent
  distinct sessions (workflow children) no longer suppress each other while a
  session cannot re-fire its own in-flight event.
- Nesting depth is carried per async invocation chain via a `Zone` value
  (`runZoned`), so concurrent sibling fires do not consume a shared global
  budget; `maxDepth` is preserved. Applied to both `fire` and `fireGate`.

## Tests

Focused:

- `test/session_plugin_lifecycle_test.dart` — 16/16. Covers created once;
  empty-storage implicit once with no ghost event; only the boot-active
  restored root fires; runtime skill visible inside the `session_start`
  executor; concurrent duplicates share/fire once; second reason no refire;
  refresh/hook failure fail-open and reserved; no-listener idempotence;
  `sessionActive` scope no leak; same-token epoch idempotence + concurrent new
  token; new boot token refires same restored id once; switch/refresh/load/
  resume no refire; direct HookService same-event distinct-session both run
  while nested same-session recursion is blocked; `dispatch_agent`,
  workflow fan-out, and Ralph all order `session_start` before
  `subagent_start` and lose no events.
- `test/core_regression_test.dart --plain-name "PLUGIN8"` — 26/26.
- `test/core_regression_test.dart --plain-name "PLUGIN7"` — 8/8.
- `test/startup_coordinator_test.dart` — 16/16.
- `test/startup_first_frame_test.dart` — 34/34.
- `test/plugin_runtime_skills_test.dart` — 18/18.
- `test/plugin_runtime_migration_test.dart` — 34/34.
- `test/session_stop_isolation_test.dart` — 16/16.
- Full `test/core_regression_test.dart` — 552/552.
- `flutter analyze` — clean.
- `git diff --check` — clean.

## Concerns / notes

- AppState integration tests inject the lifecycle dispatcher because startup
  reconciliation intentionally prunes plugin registrations that are not
  persisted canonical rows; the real HookService/registry path is covered by
  the focused unit tests (runtime skill visibility, scope, recursion).
- `_ensureActiveSession` defers its implicit dispatch until local hydration
  settles; if a root is created post-hydration while startup restore is still
  pending, idempotence guarantees one event (first reason wins) but the reason
  could be the deferred boot reason rather than `implicit`. This is an
  edge-only ordering case, not reachable through the normal boot sequence.
- The HookService zone-depth change is a general fix; it keeps the existing
  16 coordinator tests and the PLUGIN8 recursion/subagent pins green.
