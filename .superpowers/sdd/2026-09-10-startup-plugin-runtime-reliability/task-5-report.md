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

---

## Fix round 1

Review findings addressed: C1 (Critical), I1 (Important), M1, M4, M5, and M2
test gap. M3 was already satisfied and is now explicitly guarded.

### C1 — capture the boot-active root

`_maybeFinishSessionRestore` no longer reads the mutable `activeSession`. A new
`_pendingActiveRootId` captures the boot-active root:

- `_setFirstFrameActiveSession` captures the persisted root id with reason
  `restored`.
- `_ensureActiveSession`'s pre-hydration provisional branch captures the
  surviving root id with reason `implicit`, but only when no id is already
  captured (M3 — it can never clobber a restored marker).
- `loadSessions()` captures a loaded persisted root for the standalone path.
- Restore dispatches `sessionById(_pendingActiveRootId)`, so a user
  `newSession()`/`selectSession()` during the interactive readiness window can
  no longer steal the restored event or receive a mislabel.

RED test: `C1: a switch/newSession during readiness cannot steal the restored
event` hangs `skill.mount` to hold the readiness window open, calls
`newSession()` + `selectSession('root-a')`, then completes restore and asserts
`root-b` fires `restored` exactly once, `root-a` never fires, and the new
session fires `created`.

### I1 — bound the activation barrier

The coordinator's `invocation.timeout` does not cancel the underlying future,
so a hung activation left `_bootActivationSettled` pending forever. Now:

- `_activatePluginsForBoot` bounds its activation await with the
  `plugin.activate` stage timeout (`onTimeout` degrades, does not throw) and
  attaches a swallow listener so a late raw failure is not unhandled.
- `_runStartupStage` completes the barrier in a `finally` when the
  `plugin.activate` STAGE reaches terminal, covering test delegates too.
- `_maybeFinishSessionRestore` gates on `_bootActivationSettled.isCompleted`
  (activation attempted, possibly degraded) instead of the success-only
  `_pluginBootActivated`, so restored still fires fail-open.

RED test: `I1: a hung activation still settles the barrier so session_start
fires` injects a never-completing activator with a 50 ms stage timeout and
asserts `sessionStarted` completes and fires within 5 s.

### Minor fixes

- **M1**: `_generationFor` evicts prior-generation `_starts` reservations.
- **M4**: `_nextSubagentId()` skips ids held by a live handle or persisted on a
  session `agentId`, so a dispatch racing ahead of `restoreSubagentHandles`
  cannot reuse a durable id. Test: `M4: a dispatch cannot reuse a persisted
  durable agent id`.
- **M5**: `activateForBoot` serializes a genuinely new token behind any
  in-flight activation so the persisted boot-epoch read-modify-write cannot
  interleave. Test: `M5: concurrent different boot tokens advance the epoch
  without racing` (RED before, +2 after).
- **M2**: `M2: restored path fires through the real HookService registry`
  registers the hook manifest from inside the injected `pluginBootActivator`
  (after reconciliation prunes unpersisted rows) and asserts the real
  `HookService` executor observes the restored `session_start`.

### Fix-round verification

- `session_plugin_lifecycle_test.dart` — 21/21 (was 16, +5 fix-round tests).
- PLUGIN8 26/26, PLUGIN7 8/8.
- startup coordinator 16/16, startup first-frame 34/34.
- runtime skills 18/18, migration 34/34, stop isolation 16/16.
- Full `core_regression_test.dart` — 552/552.
- `flutter analyze` — clean; `git diff --check` — clean.

### Fix-round concerns

- Out-of-scope observation: `AgentService.maybeGenerateSessionTitle` adds to
  `static const _titledSessions = <String>{}`, which is unmodifiable and throws
  `UnsupportedError` whenever a session reaches title generation. Pre-existing
  and unrelated to Task 5; the M4 test avoids tripping it by using a label that
  differs from the heuristic title. Not fixed here to respect task scope.

