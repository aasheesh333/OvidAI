# Startup and Plugin Runtime Reliability Design

**Date:** 2026-09-10

**Status:** Approved by product direction: use engineering-best defaults without further option prompts.

## 1. Goal

Make Ovid usable within three seconds of launch while plugin, skill, hook, marketplace, and MCP initialization continues visibly in the background. Finish runtime readiness within 120 seconds or open in a truthful degraded state with per-item reasons and recovery actions.

This project also closes the production integration gaps that currently prevent runtime-managed skills and `session_start` hooks from behaving like their [CC]/Codex declarations.

## 2. User Outcomes

1. The chat shell and composer are interactive within three seconds, including with large local histories.
2. Startup shows one compact top progress bar and an expandable one-by-one runtime queue.
3. Marketplace refresh, Firebase, sandbox maintenance, plugin activation, and MCP handshakes never block the first Flutter frame.
4. Runtime readiness has a 120-second global deadline. Unfinished items become `Degraded` or `Failed` with `Retry` and `Disable`; the app remains usable.
5. Runtime-managed `skills/**/SKILL.md` entries appear in the skill catalog and canonical tool dispatch with session scope.
6. `session_start` fires exactly once for every new root, implicit first, restored active, and subagent session after the relevant plugin activation is ready.
7. Legacy installed plugins without a normalized runtime and valid grant are disabled and shown as `Migration required`; they do not execute broad legacy hooks or skills.
8. Every plugin/MCP startup result has a durable status and reason: Ready, Needs setup, Unsupported, Migration required, Degraded, Failed, Disabled.

## 3. Non-Goals

- Chat transcript database migration and 1M-context rendering; that is Project 2.
- Studio terminal/Git fixes; Project 3.
- Browser viewport changes; Project 4.
- GitHub-only Plugins-screen contraction; Project 5.
- Android control overlay; Project 6.
- Replacing `PluginRuntimeManager`, `HookService`, `SkillService`, or `McpService` wholesale.
- Guaranteeing network-dependent installation completes in 120 seconds. The guarantee is usable UI plus bounded readiness, not successful internet delivery.

## 4. Current Failure Model

### 4.1 First frame is behind unbounded work

`main()` awaits `AppState.initialize()`. Initialization serially hydrates state, refreshes marketplaces, activates plugins, and connects plugin-owned MCP servers before `runApp()`. Marketplace retries can consume minutes, and each MCP may consume approximately 60 seconds across initialize plus tool discovery.

### 4.2 Runtime plugin skills are not mounted into `SkillService`

`SkillService.addPluginRoot(root, pluginId)` exists but production `_refreshSkillRoots()` mounts only legacy cache roots with `addRoot()`. Runtime content under `plugin-runtime/<id>/<version>/content` is therefore absent from the system prompt catalog and direct skill UI.

### 4.3 `session_start` lifecycle has missing creation paths

Normal `newSession()` and implicit session creation do not fire `session_start`. The cold-load callback is installed by `AgentService`, but production initializes `AppState` before constructing `AgentService`, and sessions load before runtime activation, so restored-session start hooks can be missed.

### 4.4 Legacy execution bypasses normalized activation

Legacy installed/enabled rows with `runtimeId == null` can still mount cache skills and execute hook maps even though their activation defaults to disabled and no current digest grant exists.

### 4.5 Status is transient and coarse

Startup has no aggregate progress model. Service status is populated after waits, activation failures can be swallowed, and plugin rows do not retain a durable startup reason.

## 5. Architecture

### 5.1 Two-phase startup

Startup becomes two phases:

#### Phase A: first-frame bootstrap

Only the minimum local work needed to render is awaited before `runApp()`:

- Flutter binding
- lightweight preferences needed for theme and shell selection
- session metadata and active-session identity, not full remote refresh
- provider metadata required to render selectors
- local migration metadata required to avoid unsafe legacy execution

The shell renders a startup coordinator snapshot immediately. Chat input is usable even while runtime services are loading.

#### Phase B: bounded readiness queue

After first frame, `StartupCoordinator` processes an ordered queue:

1. hydrate active session tail and remaining local state
2. restore normalized plugin activation records
3. migrate or disable legacy rows
4. mount runtime plugin skills and contributions
5. fire restored-session `session_start`
6. refresh marketplace catalogs
7. connect intended MCP servers one by one
8. initialize optional Firebase/telemetry
9. run sandbox self-heal/maintenance

Each item has its own timeout and failure boundary. One failure never stops later items.

### 5.2 Startup coordinator model

Create `lib/core/startup_coordinator.dart` with these public interfaces:

```dart
enum StartupItemKind {
  localState,
  plugin,
  skillMount,
  sessionHook,
  marketplace,
  mcp,
  firebase,
  sandbox,
}

enum StartupItemState {
  queued,
  running,
  ready,
  needsSetup,
  migrationRequired,
  degraded,
  failed,
  disabled,
  skipped,
}

class StartupItemStatus {
  final String id;
  final StartupItemKind kind;
  final String label;
  final StartupItemState state;
  final String? reason;
  final DateTime updatedAt;
  final int attempt;
}

class StartupSnapshot {
  final bool shellReady;
  final bool readinessComplete;
  final bool deadlineExceeded;
  final int completed;
  final int total;
  final List<StartupItemStatus> items;
}

abstract interface class StartupTask {
  String get id;
  StartupItemKind get kind;
  String get label;
  Duration get timeout;
  Future<StartupItemStatus> run();
}

class StartupCoordinator extends ChangeNotifier {
  static final StartupCoordinator I = StartupCoordinator();

  StartupSnapshot get snapshot;
  Future<void> start(List<StartupTask> tasks);
  Future<void> retry(String itemId);
  Future<void> disable(String itemId);
}
```

The global deadline is 120 seconds from `start()`. An item that is running when the deadline expires is marked `degraded` with reason `Startup readiness deadline exceeded`; queued network/runtime items are marked `skipped` with a Retry action. Local safety migrations are not skipped; they execute before external runtime contributions can become visible.

### 5.3 First-frame state split

`AppState.initialize()` is split without changing the singleton API:

```dart
Future<void> initializeForFirstFrame();
Future<List<StartupTask>> buildReadinessTasks();
```

`main()` does:

```dart
await AppState.I.initializeForFirstFrame();
runApp(OvidApp(...));
WidgetsBinding.instance.addPostFrameCallback((_) {
  unawaited(_startReadiness());
});
```

`initialize()` remains as a compatibility/test seam that calls first-frame initialization and then runs the coordinator to completion. Existing tests and non-UI callers can continue awaiting a fully initialized state, while production no longer blocks first paint.

The boot epoch increments exactly once in the plugin-activation startup task. Repeated calls to `start()` during resume use the same boot-run token and cannot increment the epoch again.

### 5.4 Runtime plugin row reconciliation

The normalized activation ledger is authoritative for runtime installs. During local migration:

- Reconstruct a `PluginItem` for every valid activation entry missing from the catalog.
- Persist normalized rows by canonical `runtimeId`, not display name.
- Preserve display-name fields for UI only.
- Mark a runtime entry `Failed` if committed content is missing.
- Revalidate the manifest digest grant before activation. A missing/mismatched grant becomes `Migration required`/disabled, never active.

Legacy rows satisfy all of these conditions:

```text
installed == true
enabled == true
runtimeId == null
```

They are changed to:

```text
enabled = false
activation = disabled
startup status = migrationRequired
reason = "Re-approve this legacy plugin before it can run"
```

Legacy hook-map execution and legacy skill-root mounting must both require a migration-safe flag. There is no silent auto-approval.

### 5.5 Runtime skill mounting

`PluginRuntimeManager` exposes active install records without leaking mutable internals:

```dart
class ActivePluginRuntime {
  final String pluginId;
  final String contentDir;
  final PluginActivation activation;
  final String? immediateSessionId;
  final NormalizedPluginManifest manifest;
}

Future<List<ActivePluginRuntime>> activeRuntimes();
```

`AgentService._refreshSkillRoots(sessionId)` then:

1. clears the current session-aware catalog
2. adds global user and workspace roots
3. obtains active normalized runtimes
4. checks `PluginContributionRegistry.isPluginActiveForSession(pluginId, sessionId)`
5. calls `SkillService.addPluginRoot(contentDir, pluginId)`
6. mounts only manifest-declared `skills`, `commands`, and `agents`
7. reloads once after all roots are registered

Legacy cache roots are mounted only for rows explicitly approved by migration. Direct composer skill invocation and suggestions use the same canonical/session-aware resolver as the agent `skill` tool; `SkillService.find()` first-match behavior is not used for plugin-owned skills.

### 5.6 Session lifecycle dispatcher

Create `lib/core/session_lifecycle_service.dart` to make session hooks explicit and exactly-once:

```dart
enum SessionStartReason { created, implicit, restored, subagent }

class SessionLifecycleService {
  static final SessionLifecycleService I = SessionLifecycleService();

  Future<void> sessionStarted(
    ChatSession session, {
    required SessionStartReason reason,
  });
}
```

It stores a process-local set keyed by `bootRunId + sessionId`. Calls for the same session/reason-independent start are idempotent. It fires:

```dart
HookService.I.fire(
  'session_start',
  session.id,
  payload: {
    'reason': reason.name,
    'parentSessionId': session.parentSessionId,
    'isSubagent': session.parentSessionId != null,
  },
  model: session.model,
);
```

Ordering:

- New root/implicit session: create and persist session, mount session-visible skills, then fire.
- Restored active session: restore activation and skill roots first, then fire once.
- Subagent: create child, mount inherited/session-visible roots, fire `session_start`, then existing `subagent_start`.

Failures remain visible and fail-open according to `HookService`; they never block session usability.

### 5.7 Sequential plugin and MCP readiness

Each normalized runtime becomes one plugin startup item. MCP declarations become child items processed after the owner is registered and its prerequisites are validated.

Per-item timeout defaults:

- local state/migration: 15 seconds
- plugin registration/skill mount: 15 seconds
- marketplace refresh: 20 seconds per marketplace, one attempt at startup
- MCP connection: `min(server.startupTimeoutS, 30)` for the complete handshake, not separately per RPC
- Firebase: 10 seconds
- sandbox maintenance: 30 seconds, always background-degradable

MCP items are sequential by default to provide understandable progress and avoid startup resource spikes. Manual Retry can run one item. The coordinator prevents duplicate concurrent retries for the same canonical ID.

### 5.8 Durable status and reason

Add a persisted `PluginRuntimeStatus` record keyed by canonical plugin ID:

```dart
class PluginRuntimeStatus {
  final StartupItemState state;
  final String? reason;
  final DateTime updatedAt;
  final List<String> logs;
}
```

Logs are capped to the most recent 100 lines and 32 KiB per plugin. Secret-like values are scrubbed before persistence. MCP status continues to use canonical server IDs and gains a startup-attempt reason that survives restart.

The Plugins screen consumes these durable records instead of inferring failure solely from booleans.

## 6. User Interface

### 6.1 Non-blocking startup dashboard

The chat shell renders immediately with:

- a three-pixel progress bar below the app header while readiness is incomplete
- `Chat ready` once first-frame state is available
- an expandable `Finishing setup · X of Y` panel
- one row per startup item with icon, label, state, and short reason
- Retry for failed/degraded/skipped items
- Disable for plugin/MCP items
- `Open Plugins` for migration/setup failures

The panel defaults collapsed after all items reach terminal states. Failed items remain discoverable through a warning dot until acknowledged or fixed.

### 6.2 State copy

Exact user-facing states:

- `Loading`
- `Ready`
- `Needs setup`
- `Migration required`
- `Unsupported on this device`
- `Degraded`
- `Failed`
- `Disabled`

No item is labeled `Working` solely because it is enabled. MCP `Ready` requires a successful handshake. Plugin `Ready` requires a valid grant, committed content, active registration, and successful required probes.

## 7. Error Handling

- Startup task exceptions are converted to a terminal status with a capped, scrubbed reason.
- One item failure cannot abort the queue.
- The coordinator catches timeout separately from implementation errors.
- Activation rollback semantics remain owned by `PluginRuntimeManager`.
- Missing credentials become `Needs setup`, not `Failed`.
- Unsupported ABI/runtime becomes `Unsupported on this device`.
- Missing/mismatched grant becomes `Migration required` and disables the plugin.
- Missing committed content becomes `Failed` with `Installed content is missing`.
- Marketplace unavailability keeps cached catalog content and becomes `Degraded`.

## 8. Performance Budgets

- First Flutter frame: under 3 seconds on the synthetic worst-case local fixture.
- Shell/composer interaction: available immediately after first frame.
- Readiness global deadline: 120 seconds.
- No network operation on the first-frame critical path.
- No MCP process/network connection on the first-frame critical path.
- Startup queue memory: capped status/log records; no unbounded output retention.
- Session start hook: scheduled after activation/skill mount and does not block rendering.

## 9. Security

- Legacy runtime execution is disabled until normalized inspection and explicit grant approval.
- Boot activation revalidates effective grant by manifest digest.
- Startup reasons and logs use existing secret scrubbers before persistence/UI.
- Runtime skill roots are mounted from committed, contained plugin directories only.
- Session visibility is checked before mounting or invoking plugin skills/hooks.
- Retry never bypasses grant, digest, activation, or credential gates.

## 10. Testing

### Unit tests

- Coordinator ordering, progress transitions, item timeout, 120-second deadline, Retry and Disable.
- First-frame initialization excludes network/MCP/plugin-connection calls.
- Boot epoch increments once per production startup.
- Legacy installed rows disable into `Migration required`.
- Missing/mismatched grants do not register contributions.
- Runtime rows reconstruct from activation records by canonical ID.
- Runtime plugin roots mount through `addPluginRoot` only in visible sessions.
- Canonical composer skill suggestions/invocation respect session scope.
- Every session type fires `session_start` once.

### Widget tests

- Shell appears before a blocked startup task completes.
- Top progress and expandable queue update one item at a time.
- 120-second deadline opens degraded state without blocking composer.
- Retry and Disable actions call coordinator/runtime owners.
- Durable reason appears after state recreation.

### Integration tests

- Install runtime plugin with `skills/**/SKILL.md`; before restart, installing session sees the skill and another session does not; after restart it is global.
- Install plugin with `SessionStart`; create root, implicit, restored, and subagent sessions; each fires exactly once.
- Hook-only and MCP-only plugins report Ready when their real capability is active.
- One hanging marketplace and one hanging MCP do not delay first frame and cannot exceed the readiness deadline.
- Legacy installed row cannot execute hooks/skills until migration approval.

## 11. Migration

1. Add a versioned canonical plugin-row store while continuing to read the old display-name store.
2. On first startup, merge normalized rows by `runtimeId` and preserve display metadata.
3. Convert legacy installed/enabled rows to disabled `Migration required` entries.
4. Do not delete legacy cache content until migration succeeds or the user uninstalls.
5. After successful inspection/approval/install, replace the legacy row with the normalized runtime row and remove stale legacy hook/skill mounting.
6. Persist migration completion so it does not prompt repeatedly.

## 12. Rollout and Observability

- Persist startup item duration, final state, and scrubbed reason for diagnostics.
- Add a debug-only startup timeline export.
- Keep the old fully awaited `initialize()` path for tests during rollout; production uses first-frame plus coordinator.
- Release only when the first-frame deadline, 120-second deadline, runtime skill integration, session lifecycle, and migration tests pass.
- Physical Android smoke test must include offline startup, one hanging MCP, one missing-credential MCP, one runtime skill, one `SessionStart` hook, and one legacy plugin migration.

## 13. Decisions

- First usable shell target: under 3 seconds.
- Readiness deadline: 120 seconds.
- Deadline behavior: open degraded; never keep blocking indefinitely.
- Startup UI: non-blocking dashboard with top progress bar and expandable item queue.
- `session_start`: all root, restored, implicit, and subagent sessions, exactly once.
- Legacy installed plugin policy: disable and require migration approval.
