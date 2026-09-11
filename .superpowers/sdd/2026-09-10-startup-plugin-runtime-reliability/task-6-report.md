# Task 6 Report — Plugin, marketplace, MCP, Firebase, and sandbox startup tasks

## Status

Complete. `AppState.buildReadinessTasks()` now emits a per-item queue whose
external services are concrete `StartupTask` implementations
(`PluginActivationTask`, `MarketplaceRefreshTask`, `McpConnectTask`,
`FirebaseStartupTask`, `SandboxMaintenanceTask`) built from constructor-injected
delegates. Every task runs its body through the `_runStartupStage(<legacy id>)`
seam, never throws, and returns a truthful terminal `StartupItemStatus`. MCP
connections use ONE complete-handshake budget (`min(startupTimeoutS, 30s)`) with
a `budget + 1s` task timeout, and `McpService.isConnected` is now
handshake-truthful (a reserved slot is not "connected").

## Commit

- Message: `feat: queue plugin and MCP startup readiness`
- Files:
  - Create `lib/core/startup_tasks.dart`
  - Modify `lib/core/startup_coordinator.dart`
  - Modify `lib/core/mcp_service.dart`
  - Modify `lib/core/state.dart`
  - Create `test/startup_tasks_test.dart`
  - Modify `test/startup_coordinator_test.dart`
  - Modify `test/startup_first_frame_test.dart`
  - This report

`lib/core/plugin_runtime.dart`, `lib/core/firebase_service.dart`, and
`lib/core/sandbox_service.dart` required no production changes: the new tasks
consume `reconcileRowsAndGrants()`, `SandboxUnsupportedException`, and the
existing `FirebaseService.initialize()`/`isAvailable` through injected
delegates. They are left untouched to avoid scope creep.

## Implementation

### `lib/core/startup_tasks.dart` (new)

- `MarketplaceSyncOutcome { ready, degraded, failed }` and
  `aggregateStartupStates(Iterable<StartupItemState>)` with precedence
  failed > unsupported > migrationRequired > degraded > ready.
- `PluginActivationTask` — `kind: plugin`, no disable; body injected; errors
  become `failed`.
- `MarketplaceRefreshTask` — iterates `repos()` and continues after any
  failure; aggregate is the worst outcome; cached fallback delegates return
  `degraded`.
- `McpConnectTask` — coordinator id `mcp.connect:<canonicalId>`, `kind: mcp`,
  `timeout = budget + 1s`, `budgetFor(s) = min(s, 30)`. A `ready` outcome is
  only accepted when the injected `isConnected` is true; otherwise `failed`.
  `onDisable` is injected.
- `FirebaseStartupTask` — every path (unavailable, unexpected, throw) maps to
  `degraded`; never `failed`.
- `SandboxMaintenanceTask` — not installed `skipped`; `SandboxUnsupportedException`
  `unsupported`; runtimes unverified after install `degraded`; otherwise `ready`.
  `prewarmBrowser` stays unawaited inside the injected maintenance delegate.

### `lib/core/startup_coordinator.dart`

- Added `StartupItemState.unsupported` and `StartupItemStatus.unsupported`.
- `start()` rejects duplicate task ids with `ArgumentError` before mutating
  state.

### `lib/core/mcp_service.dart`

- `isConnected(name)` now requires `_RunningServer.handshakeDone` (reserved
  slot during handshake is not connected). PLUGIN9/PLUGIN10 stay green.
- Added `McpConnectOutcomeKind { ready, needsSetup, unsupported, failed }` and
  `McpConnectOutcome`.
- Added additive `connectOutcome(server, {handshakeBudget})` (existing
  `connect()` signature/behavior unchanged). It:
  - runs owner/transport/credential gates without dialing (credentialed servers
    still never auto-spawn);
  - computes a single `deadline` at entry and hard-caps the whole future with
    `.timeout(handshakeBudget)`;
  - passes the deadline into `_connectHttp`/`_connectStdio`, which recompute
    remaining time before each RPC (initialize → initialized → tools/list);
  - treats RPC timeouts as failures so `tools/list` never follows a timed-out
    `initialize`;
  - on abort removes the exact `_RunningServer`, sets `userDisconnected` BEFORE
    killing, cancels reconnect, and never sets `handshakeDone`; detached late
    completion is ignored by `identical(_running[key], rs)` guards.

### `lib/core/state.dart`

- `_runStartupStage` now returns `bool` (whether a test override short-circuited)
  and still settles `_bootActivationSettled` in `finally`.
- `_PluginSafetyStartupTask` uses `aggregateStartupStates`, so the
  `localSafety.migrate` item can surface `unsupported`.
- `buildReadinessTasks()` → `_buildReadinessTasks()` emits, in order:
  `local.hydrate`, `localSafety.migrate`, `plugin.activate`, `skill.mount`,
  `session.restore`, `marketplace.refresh`, `github.initialize`,
  `mcp.connect:<canonicalId>…`, `firebase.initialize`, `sandbox.selfHeal`.
  (localState items are also hoisted by the coordinator.)
- Per-server MCP items are built from the persisted `ovid_mcp_connected_v1`
  intent (deduped by canonical id) and resolve the server at run time, so
  custom servers queued before local hydration still work. Each routes through
  `_runStartupStage('mcp.connect', …)`.
- MCP disable disconnects and removes ONLY the selected canonical id from
  `ovid_mcp_connected_v1` (never rebuilds intent from connected flags).
- `syncMarketplaceCatalogs` records `_fetchedMarketplaces` only AFTER a
  successful fetch, so a failed item stays retryable. Added
  `MarketplaceSyncOutcome`-returning `refreshMarketplaceForStartup`.
- Firebase delegate wraps `FirebaseService.I.initialize()` in the
  `firebase.initialize` stage and reports `isAvailable`; overrides return
  available.
- Sandbox delegates wrap `selfHealInBackground` + unawaited `prewarmBrowser` in
  the `sandbox.selfHeal` stage; runtimes verify/install and quota enforcement
  follow.

## Tests

- `test/startup_tasks_test.dart` — 25/25 (new). Two MCP tasks strict
  one-by-one/no-overlap; failed MCP A still runs MCP B; failed plugin does not
  stop MCP; ordering plugin+skill before owner MCP; canonical distinct ids;
  `startupTimeoutS=120` → exactly one 30 s budget and a 31 s task timeout;
  initialize timeout prevents tools/list; tools/list timeout cleans the slot,
  never ready, no reconnect; missing env/header → `needsSetup` with zero dials;
  sse/unknown → `unsupported`; permanent ABI → `unsupported`; success-but-not-
  connected → `failed`; marketplace ready/degraded/failed + continue-after-
  failure + cached fallback degraded; Firebase unavailable/unexpected →
  degraded and ready; sandbox skipped/unsupported/degraded/ready; disable
  clears only the selected intent id; reasons never leak secrets; aggregate
  precedence.
- `test/startup_coordinator_test.dart` — 19/19 (+2: `unsupported` terminal
  preservation, duplicate-id rejection).
- `test/startup_first_frame_test.dart` — 34/34 (+1 per-server canonical child id
  through the base stage; plugin-activation test updated for the non-throwing
  task contract).
- PLUGIN9 25/25, PLUGIN10 9/9.
- `plugin_runtime_skills_test.dart` + `plugin_runtime_migration_test.dart` +
  `session_stop_isolation_test.dart` + `session_plugin_lifecycle_test.dart` —
  89/89.
- Full `test/core_regression_test.dart` — 552/552.
- Full `flutter test` (all files) — 727/727.
- `flutter analyze` — clean.
- `git diff --check` — clean.

## Concerns / notes

- The MCP offline test seam treats an injected `mcp.connect` stage as a live
  connection (`isConnected` delegate override-aware) so `_offlineStages()`
  still short-circuits to `ready`; production never has injected delegates, so
  the honesty check is unchanged in production.
- `localSafety.migrate` can surface `unsupported` and the aggregate precedence
  is unit-tested, but `reconcileRowsAndGrants()` currently never produces an
  `unsupported` plugin status (there is no unsupported `PluginActivation`).
  The handling is defensive for future ABI/permanent failures.
- Per-server MCP tasks are created for every persisted intent id, even if the
  server row no longer exists; such an item resolves at run time to `failed`
  ("Server is no longer configured"). Pruning stale intent ids was out of
  scope.
- A marketplace item refreshes all registered repos under one 20 s item
  timeout (spec §5.7 says "20 s per marketplace"); the item-level aggregate is
  a single queue entry, matching the queue contract.
- No production changes were made to `plugin_runtime.dart`,
  `firebase_service.dart`, or `sandbox_service.dart`; the brief's `git add`
  list names them, but `git add` on unchanged paths is a no-op.

---

## Fix round 1

### Important 1 — restore MCP startup side effects and intent retention

`AppState._connectMcpForStartup` now mirrors the old `reconnectServices`
side effects:

- Before the handshake it writes
  `updateServiceStatus('mcp:<id>', connecting, detail: 'connecting…')`.
- After `McpService.connectOutcome` it sets
  `server.connected = (outcome.kind == ready && McpService.I.isConnected(id))`
  and writes `working` (connected) or `failed` with a
  `redactStartupError`-scrubbed reason (needsSetup/unsupported/failed all map
  to `ServiceHealth.failed`, distinguished by detail).
- The stage-delegate override still short-circuits without touching real
  connection state.
- `redactStartupError` was promoted from private to public in
  `startup_coordinator.dart` so service-status details share the same
  secret-safe scrubber as task reasons.

Intent retention: `_persistMcpConnectedIntent` no longer blindly rebuilds the
list from live `connected` flags. It merges (a) existing persisted ids that
still map to a configured **ownerless** server and (b) currently connected
servers. This keeps a startup-connected or startup-failed ownerless seed in
`ovid_mcp_connected_v1` after a later persist, while owned servers continue to
follow the plugin lifecycle. `toggleMcpServer` passes `removed: [id]` when
turning a server off so explicit disconnect still prunes exactly that id.

RED tests: `successful startup connect sets connected + working and keeps
intent`; `failed startup connect sets failed/needsSetup without dropping
intent`; plus `toggling an ownerless server off prunes only its intent id`
to guard the merge against a toggle-off regression.

### Important 2 — resolve the MCP budget from the loaded server

`McpConnectTask` now takes `resolveBudget: Duration Function()` and evaluates
it lazily in both `timeout` (coordinator bound) and `run()` (handshake
budget). `AppState._buildMcpReadinessTasks` passes
`() => McpConnectTask.budgetFor(_mcpServerByCanonicalId(name)?.startupTimeoutS ?? 30)`,
so a custom/marketplace row loaded by readiness inventory contributes its real
`startupTimeoutS` instead of the pre-hydration default of 30.

RED test: `resolves the budget from the server loaded after task build`
asserts a custom `startupTimeoutS=5` server yields a 6 s task timeout (5 s
budget) and a plugin `startupTimeoutS=120` server yields 31 s (30 s budget)
when both rows are added only after `buildReadinessTasks()`.

### Minor (a) — close the pre-reservation timeout window

`connectOutcome` now awaits `beforeReserveHookForTest` (test seam) and checks
the injected-clock deadline immediately before reserving `_RunningServer`, and
`_connectHttp`/`_connectStdio` reject an already-expired deadline before
dialing/spawning. A timeout that lands during the credential gate can no
longer reserve a slot or spawn a process. RED test: `an expired deadline never
reserves a slot or dials` (zero HTTP requests, not connected).

### Minor (b) — per-repo marketplace remaining-budget guard

`MarketplaceRefreshTask` keeps the single plan-mandated item but computes an
internal deadline and gives each repo its fair share of the remaining budget
via `guarded(repo).timeout(slice, onTimeout: failed)`, so one slow repo cannot
starve later repos. The refresh is guarded so a throwing repo cannot leak an
unhandled async error. RED test: `a slow repo cannot starve later repos within
the item budget` (slow gate blocks, `fast` still runs).

### Minor (c) — remaining-time propagation test seam

Added `McpService.clockForTest` (injectable clock) and
`connectPhaseTimeoutRecorderForTest` (phase timeout recorder). The RED test
`remaining budget shrinks across initialize, initialized, tools/list` advances
the injected clock 5 s per phase and asserts the recorded budgets are 30 s,
25 s, and 20 s.

### Fix-round verification

- `startup_tasks_test.dart` — 32/32 (was 25; +7 fix-round tests).
- `startup_coordinator_test.dart` — 19/19.
- `startup_first_frame_test.dart` — 34/34.
- PLUGIN9 25/25, PLUGIN10 9/9.
- runtime skills 18/18, migration 34/34, stop isolation 16/16, lifecycle 21/21.
- Full `test/core_regression_test.dart` — 552/552.
- Full `flutter test` — 734/734.
- `flutter analyze` — clean; `git diff --check` — clean.

### Fix-round concerns

- `_persistMcpConnectedIntent` retains only ownerless intended servers. Owned
  servers intentionally continue to follow the plugin activation lifecycle, so
  disabling a plugin still prunes its owned MCP intent (pre-existing behavior).
- The marketplace fair-share slice can time out a legitimately slow repo
  earlier than the old whole-item behavior when several repos are registered;
  the tradeoff is bounded, even progress instead of one repo consuming the
  whole item budget.
