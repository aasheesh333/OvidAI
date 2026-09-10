# Startup and Plugin Runtime Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render an interactive Ovid shell in under three seconds, finish plugin/MCP readiness through a visible bounded queue, and make runtime skills plus `session_start` hooks work with canonical session scope.

**Architecture:** Split startup into a minimal first-frame phase and a post-frame `StartupCoordinator` queue with per-item isolation and a 120-second global deadline. Make the normalized activation ledger authoritative for runtime rows, grants, skill roots, lifecycle events, and durable status; disable legacy execution until explicit migration approval.

**Tech Stack:** Flutter/Dart, Android, `SharedPreferences`, `FlutterSecureStorage`, existing `PluginRuntimeManager`, `PluginContributionRegistry`, `HookService`, `SkillService`, `McpService`, widget/unit/integration tests.

**Spec:** `docs/superpowers/specs/2026-09-10-startup-plugin-runtime-reliability-design.md`

## Global Constraints

- First interactive Flutter shell and composer appear in under 3 seconds on the synthetic worst-case local fixture.
- No marketplace request, plugin-owned MCP handshake, Firebase call, or sandbox maintenance runs on the first-frame critical path.
- Runtime readiness has a single 120-second global deadline; unfinished work becomes degraded/skipped with Retry instead of blocking the shell.
- Startup plugin and MCP tasks execute one-by-one with observable item status and continue after item failure.
- Boot epoch increments exactly once per production app start.
- `session_start` fires exactly once for new root, implicit first, restored active, and subagent sessions after activation and skill mounting.
- Runtime plugin skills mount from committed contained roots with canonical plugin ownership and running-session scope.
- Legacy installed plugins without a normalized runtime and valid digest grant are disabled and shown as `Migration required`; they execute no legacy hooks or skills.
- Missing credentials produce `Needs setup`; unsupported runtime/ABI produces `Unsupported on this device`; neither may claim Ready.
- Secrets never appear in preferences, startup logs, status reasons, or model-visible diagnostics.
- Existing Task 1–12 behavior remains green; baseline is 552 tests and zero analyzer issues at commit `7de3e41`.
- Flutter binary is `/home/ubuntu/sdk/flutter/bin/flutter`.

---

### Task 1: Startup coordinator state machine and deadline

**Files:**
- Create: `lib/core/startup_coordinator.dart`
- Create: `test/startup_coordinator_test.dart`

**Interfaces:**
- Produces `StartupItemKind`, `StartupItemState`, `StartupItemStatus`, `StartupSnapshot`, `StartupTask`, and `StartupCoordinator` exactly as specified in design §5.2.
- `StartupCoordinator.start(List<StartupTask>)` runs tasks sequentially and returns when every task reaches a terminal state or the 120-second deadline is applied.
- `StartupCoordinator.retry(String)` reruns only the selected terminal item and refuses a duplicate concurrent retry.
- `StartupCoordinator.disable(String)` delegates only plugin/MCP disable callbacks supplied by the task.

- [ ] **Step 1: Write failing sequential-order and continuation tests**

```dart
test('startup tasks run one-by-one and continue after a failure', () async {
  final calls = <String>[];
  final coordinator = StartupCoordinator.forTest(
    deadline: const Duration(seconds: 120),
  );
  await coordinator.start([
    FakeStartupTask('a', run: () async {
      calls.add('a:start');
      await Future<void>.delayed(Duration.zero);
      calls.add('a:end');
      return StartupItemStatus.ready('a', StartupItemKind.localState, 'A');
    }),
    FakeStartupTask('b', run: () async {
      calls.add('b:start');
      throw StateError('broken');
    }),
    FakeStartupTask('c', run: () async {
      calls.add('c:start');
      return StartupItemStatus.ready('c', StartupItemKind.plugin, 'C');
    }),
  ]);
  expect(calls, ['a:start', 'a:end', 'b:start', 'c:start']);
  expect(coordinator.snapshot.items.singleWhere((x) => x.id == 'b').state,
      StartupItemState.failed);
  expect(coordinator.snapshot.readinessComplete, isTrue);
});
```

- [ ] **Step 2: Run RED**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/startup_coordinator_test.dart`

Expected: compile failure because `startup_coordinator.dart` and its types do not exist.

- [ ] **Step 3: Implement immutable status models and sequential execution**

Implement terminal-state helpers and secret-safe error conversion:

```dart
typedef StartupDisable = Future<void> Function();

abstract interface class StartupTask {
  String get id;
  StartupItemKind get kind;
  String get label;
  Duration get timeout;
  StartupDisable? get onDisable;
  Future<StartupItemStatus> run();
}

Future<StartupItemStatus> _runOne(StartupTask task) async {
  try {
    return await task.run().timeout(task.timeout);
  } on TimeoutException {
    return StartupItemStatus.degraded(
      task.id,
      task.kind,
      task.label,
      reason: 'Timed out after ${task.timeout.inSeconds}s',
    );
  } catch (error) {
    return StartupItemStatus.failed(
      task.id,
      task.kind,
      task.label,
      reason: cleanHookJson(error.toString()),
    );
  }
}
```

- [ ] **Step 4: Write failing global-deadline, retry, and disable tests**

Use `fake_async` or an injected monotonic clock/timer factory. Assert a running task becomes `degraded`, queued external tasks become `skipped`, local migration is not skipped, Retry changes only that item, and Disable invokes the supplied callback once.

- [ ] **Step 5: Implement the 120-second deadline and retry/disable locks**

Use one run token and one `_runningItemIds` set; stale completions from an expired run must not overwrite deadline states.

- [ ] **Step 6: Run GREEN and analyze**

Run:

```bash
/home/ubuntu/sdk/flutter/bin/flutter test test/startup_coordinator_test.dart
/home/ubuntu/sdk/flutter/bin/flutter analyze --no-pub
```

Expected: all coordinator tests pass and analyzer reports zero issues.

- [ ] **Step 7: Commit**

```bash
git add lib/core/startup_coordinator.dart test/startup_coordinator_test.dart
git commit -m "feat: add bounded startup coordinator"
```

---

### Task 2: First-frame startup split and non-blocking orchestration

**Files:**
- Modify: `lib/main.dart`
- Modify: `lib/core/state.dart`
- Modify: `lib/core/firebase_service.dart`
- Modify: `lib/core/sandbox_service.dart`
- Modify: `lib/core/startup_coordinator.dart`
- Create: `test/startup_first_frame_test.dart`
- Modify: `test/core_regression_test.dart` (boot-site assertions only)

**Interfaces:**
- Consumes `StartupCoordinator` from Task 1.
- Produces `AppState.initializeForFirstFrame()` and `AppState.buildReadinessTasks()`.
- Keeps `AppState.initialize()` as a compatibility seam that executes both phases for existing tests.
- Production `main()` awaits only first-frame initialization before `runApp`, then starts readiness from a post-frame callback.

- [ ] **Step 1: Write a failing first-frame critical-path test**

Create injected stage counters:

```dart
test('first-frame initialization performs no network or MCP work', () async {
  final calls = <String>[];
  final app = AppState.createForTest(
    startupStageRecorder: calls.add,
  );
  await app.initializeForFirstFrame();
  expect(calls, isNot(contains(anyOf(
    'marketplace.refresh',
    'plugin.activate',
    'mcp.connect',
    'firebase.initialize',
    'sandbox.selfHeal',
  ))));
});
```

- [ ] **Step 2: Run RED**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/startup_first_frame_test.dart`

Expected: compile failure for the missing split APIs.

- [ ] **Step 3: Split local hydration from readiness work**

`initializeForFirstFrame()` may await theme, provider metadata, active-session metadata, migration version, and local shell preferences. Move marketplace refresh, normalized activation, MCP reconnect, Firebase, sandbox maintenance, and full-history hydration into startup tasks.

- [ ] **Step 4: Move production orchestration post-frame**

Implement:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppState.I.initializeForFirstFrame();
  Aether.dark = !AppState.I.lightTheme;
  runApp(OvidApp(sandboxReady: AppState.I.sandboxInstalled));
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_startReadiness());
  });
}

Future<void> _startReadiness() async {
  final tasks = await AppState.I.buildReadinessTasks();
  await StartupCoordinator.I.start(tasks);
}
```

- [ ] **Step 5: Add first-frame and compatibility tests**

Assert `runApp` is lexically before optional initialization, `initialize()` still yields fully loaded test state, and two calls to the production boot entry increment the plugin boot epoch once per boot token.

- [ ] **Step 6: Run focused and existing boot tests**

```bash
/home/ubuntu/sdk/flutter/bin/flutter test test/startup_first_frame_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "boot"
```

- [ ] **Step 7: Commit**

```bash
git add lib/main.dart lib/core/state.dart lib/core/firebase_service.dart lib/core/sandbox_service.dart lib/core/startup_coordinator.dart test/startup_first_frame_test.dart test/core_regression_test.dart
git commit -m "feat: render before background runtime readiness"
```

---

### Task 3: Canonical runtime-row persistence and safe legacy migration

**Files:**
- Modify: `lib/core/plugin_runtime.dart`
- Modify: `lib/core/plugin_manifest.dart`
- Modify: `lib/core/plugin_permissions.dart`
- Modify: `lib/core/state.dart`
- Create: `test/plugin_runtime_migration_test.dart`

**Interfaces:**
- Produces `ActivePluginRuntime` and `PluginRuntimeManager.activeRuntimes()`.
- Produces `PluginRuntimeManager.reconcileRowsAndGrants()` returning startup statuses/tasks.
- Persists normalized rows keyed by canonical `runtimeId` in `ovid_plugin_rows_v2`.
- Reads legacy display-name state once, disables unnormalized installed rows, and records `Migration required` without deleting cached content.

- [ ] **Step 1: Write failing reconstruction and collision tests**

Test a valid activation entry with no catalog row, and two plugins with the same display name but different canonical IDs. After reconciliation, both rows must exist and remain independently addressable by runtime ID.

- [ ] **Step 2: Write failing grant-revalidation and legacy-disable tests**

```dart
test('boot does not activate a runtime whose digest grant is missing', () async {
  await seedRuntimeEntry(pluginId: 'acme/reviewer', withGrant: false);
  final result = await PluginRuntimeManager.I.reconcileRowsAndGrants();
  expect(result.single.state, StartupItemState.migrationRequired);
  expect(PluginContributionRegistry.I.isRegistered('acme/reviewer'), isFalse);
});

test('legacy installed row is disabled and cannot execute hooks or skills', () async {
  final row = legacyInstalledRow(name: 'Old Tools');
  await AppState.I.reconcileLegacyPluginsForTest([row]);
  expect(row.enabled, isFalse);
  expect(row.activation, PluginActivation.disabled);
  expect(row.migrationRequired, isTrue);
});
```

- [ ] **Step 3: Run RED**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/plugin_runtime_migration_test.dart`

- [ ] **Step 4: Implement canonical row storage and reconciliation**

Extend `PluginItem` with persisted `migrationRequired` and `runtimeReason`. Keep old JSON readable. Build rows from activation manifests before catalog merge; merge display metadata without using display name as identity.

- [ ] **Step 5: Gate legacy execution paths**

Update `HookService` legacy map resolution and `AgentService._refreshSkillRoots` so legacy rows require `installed && enabled && !migrationRequired`. Existing legacy rows become disabled during reconciliation before either service runs.

- [ ] **Step 6: Verify migration idempotence and no secret persistence**

Run the migration twice and compare serialized stores byte-for-byte. Search persisted preference strings for seeded secret values and assert absent.

- [ ] **Step 7: Commit**

```bash
git add lib/core/plugin_runtime.dart lib/core/plugin_manifest.dart lib/core/plugin_permissions.dart lib/core/state.dart lib/core/hook_service.dart lib/core/agent_service.dart test/plugin_runtime_migration_test.dart
git commit -m "feat: reconcile canonical plugin rows and legacy migration"
```

---

### Task 4: Runtime-managed skill roots and session-aware skill dispatch

**Files:**
- Modify: `lib/core/skills.dart`
- Modify: `lib/core/agent_service.dart`
- Modify: `lib/ui/chat_screen.dart`
- Create: `test/plugin_runtime_skills_test.dart`

**Interfaces:**
- Consumes `PluginRuntimeManager.activeRuntimes()` from Task 3.
- Changes `AgentService.refreshSkills({required String sessionId})` to mount canonical plugin roots visible to that running session.
- Produces `SkillService.skillsForSession(String)` and session-aware suggestion/lookup APIs.

- [ ] **Step 1: Write a failing install-to-skill integration test**

Create a runtime plugin fixture containing `skills/research/SKILL.md`, install it with agent origin in session A, call production `refreshSkills(sessionId: 'A')`, and assert:

- canonical skill exists in A
- bare unique alias resolves in A
- session B cannot list or invoke it before promotion
- after one boot promotion, B can resolve it

- [ ] **Step 2: Run RED**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/plugin_runtime_skills_test.dart`

Expected: runtime root is absent from `SkillService` production catalog.

- [ ] **Step 3: Mount active runtime roots canonically**

Implement one batched reload:

```dart
Future<void> _refreshSkillRoots(String sessionId) async {
  SkillService.I.clearRoots();
  await _addUserAndWorkspaceRoots(sessionId);
  for (final runtime in await PluginRuntimeManager.I.activeRuntimes()) {
    if (!PluginContributionRegistry.I
        .isPluginActiveForSession(runtime.pluginId, sessionId)) continue;
    SkillService.I.addPluginRoot(runtime.contentDir, runtime.pluginId);
  }
  await SkillService.I.reload();
}
```

- [ ] **Step 4: Route composer suggestions and invocation through session scope**

Replace direct plugin `SkillService.find()` use with the canonical resolver. User/global workspace skills retain current behavior; ambiguous plugin aliases show exact canonical options and do not execute.

- [ ] **Step 5: Add traversal and stale-cache tests**

Assert a hostile `../` manifest path is not mounted and a stale legacy cache cannot expose a pending runtime skill globally.

- [ ] **Step 6: Run focused and full skill tests**

```bash
/home/ubuntu/sdk/flutter/bin/flutter test test/plugin_runtime_skills_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "skill"
```

- [ ] **Step 7: Commit**

```bash
git add lib/core/skills.dart lib/core/agent_service.dart lib/ui/chat_screen.dart test/plugin_runtime_skills_test.dart
git commit -m "feat: mount runtime plugin skills by session scope"
```

---

### Task 5: Exactly-once session lifecycle dispatch

**Files:**
- Create: `lib/core/session_lifecycle_service.dart`
- Modify: `lib/core/state.dart`
- Modify: `lib/core/agent_service.dart`
- Modify: `lib/core/plugin_runtime.dart`
- Create: `test/session_plugin_lifecycle_test.dart`

**Interfaces:**
- Produces `SessionStartReason` and `SessionLifecycleService.sessionStarted(ChatSession, {required reason})` from design §5.6.
- Consumes runtime activation and session-aware skill refresh before firing.
- Existing `subagent_start` remains and follows the child session's general `session_start`.

- [ ] **Step 1: Write failing tests for all four session types**

Use a normalized plugin with `SessionStart` and an executor recorder. Test new root, implicit first, restored active, and subagent sessions. Assert each session ID fires once with its correct reason payload.

- [ ] **Step 2: Write failing ordering and idempotence tests**

Assert the hook sees its runtime skill in the session catalog, repeated switch/load callbacks do not refire, and hook failure does not block session creation.

- [ ] **Step 3: Run RED**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/session_plugin_lifecycle_test.dart`

- [ ] **Step 4: Implement lifecycle service and wire creation paths**

Wire:

- `AppState.newSession` → `created`
- `_ensureActiveSession` → `implicit`
- readiness task after restored activation → `restored`
- child creation → `subagent`, followed by existing `subagent_start`

Do not fire from `onSessionSwitched`; switching is not creation.

- [ ] **Step 5: Add a boot-run idempotence token**

Reset the process-local fired set only when the startup coordinator creates a new boot run. A resume callback cannot generate a new boot token.

- [ ] **Step 6: Run hook/session suites**

```bash
/home/ubuntu/sdk/flutter/bin/flutter test test/session_plugin_lifecycle_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "PLUGIN8"
/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "PLUGIN7"
```

- [ ] **Step 7: Commit**

```bash
git add lib/core/session_lifecycle_service.dart lib/core/state.dart lib/core/agent_service.dart lib/core/plugin_runtime.dart test/session_plugin_lifecycle_test.dart
git commit -m "feat: dispatch session-start hooks exactly once"
```

---

### Task 6: Plugin, marketplace, MCP, Firebase, and sandbox startup tasks

**Files:**
- Create: `lib/core/startup_tasks.dart`
- Modify: `lib/core/plugin_runtime.dart`
- Modify: `lib/core/mcp_service.dart`
- Modify: `lib/core/state.dart`
- Modify: `lib/core/firebase_service.dart`
- Modify: `lib/core/sandbox_service.dart`
- Create: `test/startup_tasks_test.dart`

**Interfaces:**
- Produces concrete `StartupTask` implementations: `PluginActivationTask`, `MarketplaceRefreshTask`, `McpConnectTask`, `FirebaseStartupTask`, `SandboxMaintenanceTask`.
- MCP task uses one complete-handshake timeout capped at 30 seconds.
- Every task returns a truthful terminal `StartupItemStatus`; none throws out of the coordinator.

- [ ] **Step 1: Write failing ordering and per-item failure tests**

Seed two plugins and two MCPs with fake completers. Assert plugin registration/skill mount precedes owner MCP connection, MCPs never overlap, and failure of MCP A still runs MCP B.

- [ ] **Step 2: Write failing timeout-budget tests**

Assert a server with `startupTimeoutS=120` receives a 30-second complete-handshake budget, not two 30-second RPC budgets. Add an MCP test seam accepting the deadline/budget.

- [ ] **Step 3: Run RED**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/startup_tasks_test.dart`

- [ ] **Step 4: Implement concrete tasks and queue construction**

`AppState.buildReadinessTasks()` returns local safety tasks first, then runtime registration/skill tasks, restored session hook, marketplaces, MCPs, Firebase, and sandbox maintenance.

- [ ] **Step 5: Add truthful outcome mapping**

Map missing env/header names to `needsSetup`, unsupported transport/ABI to `failed` or `unsupported`, cached-marketplace fallback to `degraded`, and successful MCP handshake to `ready` only when `McpService.isConnected(canonicalId)` is true.

- [ ] **Step 6: Run focused MCP/runtime tests**

```bash
/home/ubuntu/sdk/flutter/bin/flutter test test/startup_tasks_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "PLUGIN9"
/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "PLUGIN10"
```

- [ ] **Step 7: Commit**

```bash
git add lib/core/startup_tasks.dart lib/core/plugin_runtime.dart lib/core/mcp_service.dart lib/core/state.dart lib/core/firebase_service.dart lib/core/sandbox_service.dart test/startup_tasks_test.dart
git commit -m "feat: queue plugin and MCP startup readiness"
```

---

### Task 7: Durable startup status, scrubbed reasons, and plugin health

**Files:**
- Modify: `lib/core/startup_coordinator.dart`
- Modify: `lib/core/plugin_runtime.dart`
- Modify: `lib/core/state.dart`
- Modify: `lib/core/hook_service.dart`
- Create: `test/startup_status_persistence_test.dart`

**Interfaces:**
- Produces versioned persisted `PluginRuntimeStatus` records keyed by canonical plugin ID.
- Persists at most 100 lines and 32 KiB of scrubbed logs per plugin.
- Hook-only and MCP-only normalized plugins can report Ready from real active capability instead of requiring command/skill/agent tools.

- [ ] **Step 1: Write failing persistence and secret-scrub tests**

Persist failures containing seeded token/header values, recreate `AppState`, and assert state/reason survives while the raw secrets do not appear in SharedPreferences JSON.

- [ ] **Step 2: Write hook-only and MCP-only health tests**

Assert a registered active hook-only plugin reports Ready after hook registration; an MCP-only plugin reports Ready only after handshake; missing credentials report Needs setup.

- [ ] **Step 3: Run RED**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/startup_status_persistence_test.dart`

- [ ] **Step 4: Implement capped status persistence**

Use canonical IDs, stable JSON, corrupt-entry isolation, and existing MCP/hook secret scrubbers. Persist state transitions only when values change.

- [ ] **Step 5: Replace plugin health inference**

Stop equating command/skill/agent roster tools with total plugin capability. Probe manifest-declared active contribution types and live MCP ownership.

- [ ] **Step 6: Verify restart and factory-reset cleanup**

Assert uninstall removes the status record and factory reset deletes the status key.

- [ ] **Step 7: Commit**

```bash
git add lib/core/startup_coordinator.dart lib/core/plugin_runtime.dart lib/core/state.dart lib/core/hook_service.dart test/startup_status_persistence_test.dart
git commit -m "feat: persist truthful plugin startup status"
```

---

### Task 8: Non-blocking startup dashboard UI

**Files:**
- Create: `lib/ui/startup_progress_panel.dart`
- Modify: `lib/ui/shell.dart`
- Modify: `lib/ui/chat_screen.dart`
- Modify: `lib/ui/plugins_screen.dart`
- Create: `test/startup_progress_widget_test.dart`

**Interfaces:**
- Consumes `StartupCoordinator.snapshot` and Retry/Disable methods.
- Produces a 3px header progress bar and expandable `Finishing setup · X of Y` panel without blocking chat input.
- Plugins screen consumes durable canonical status/reason from Task 7.

- [ ] **Step 1: Write a failing first-frame widget test**

Pump shell with a pending startup completer. Assert composer is enabled before the completer resolves, progress bar is visible, and panel shows the current item.

- [ ] **Step 2: Write failing state/action tests**

Cover exact labels `Loading`, `Ready`, `Needs setup`, `Migration required`, `Unsupported on this device`, `Degraded`, `Failed`, `Disabled`; assert Retry and Disable delegate to coordinator.

- [ ] **Step 3: Run RED**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/startup_progress_widget_test.dart`

- [ ] **Step 4: Implement the panel**

Keep the panel compact, accessible, and independent of ChatScreen rebuild frequency. Use one `AnimatedBuilder` around the panel, not the transcript.

- [ ] **Step 5: Add Plugins-screen durable-reason integration**

Cards and detail pages show the persisted status and short reason. `Open Plugins` deep-links to the failing canonical row. Do not infer failure solely from `installed`/`enabled` booleans.

- [ ] **Step 6: Add deadline UX test**

Advance fake time to 120 seconds; assert composer remains usable, the panel stops showing an indefinite spinner, and the slow item exposes Retry.

- [ ] **Step 7: Commit**

```bash
git add lib/ui/startup_progress_panel.dart lib/ui/shell.dart lib/ui/chat_screen.dart lib/ui/plugins_screen.dart test/startup_progress_widget_test.dart
git commit -m "feat: show non-blocking startup readiness dashboard"
```

---

### Task 9: Performance, integration, migration, and Android release gate

**Files:**
- Modify: `test/core_regression_test.dart` (cross-task regression pins only)
- Create: `test/startup_performance_test.dart`
- Create: `docs/superpowers/audits/2026-09-10-startup-plugin-runtime-reliability.md`
- Modify: `README.md`

**Interfaces:**
- Verifies all interfaces produced by Tasks 1–8.
- Documents physical-device checks without claiming they ran when no device is attached.

- [ ] **Step 1: Add synthetic first-frame and deadline tests**

Use fake hanging marketplace/MCP tasks and a synthetic large local session metadata fixture. Assert first-frame initialization finishes within a test budget independent of hanging tasks and readiness reaches terminal degraded state at 120 seconds fake time.

- [ ] **Step 2: Add end-to-end runtime skill and session hook tests**

Run real local-folder install fixtures through inspect, grant, install, boot coordinator, skill catalog, root/implicit/restored/subagent session creation, and hook executor. Assert canonical/session scope and exactly-once behavior.

- [ ] **Step 3: Add legacy migration security test**

Seed old installed/enabled hook and skill rows. Boot. Assert they become disabled Migration required and cannot execute until inspect/approve/install succeeds.

- [ ] **Step 4: Run all focused suites**

```bash
/home/ubuntu/sdk/flutter/bin/flutter test test/startup_coordinator_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test test/startup_first_frame_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test test/plugin_runtime_migration_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test test/plugin_runtime_skills_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test test/session_plugin_lifecycle_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test test/startup_tasks_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test test/startup_status_persistence_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test test/startup_progress_widget_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test test/startup_performance_test.dart
```

- [ ] **Step 5: Run full verification**

```bash
/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test
/home/ubuntu/sdk/flutter/bin/flutter analyze --no-pub
/home/ubuntu/sdk/flutter/bin/flutter build apk --debug
git diff --check
```

Expected: all tests pass, analyzer reports zero issues, debug APK exists at `build/app/outputs/flutter-apk/app-debug.apk`, and diff check is clean.

- [ ] **Step 6: Write the audit and README behavior contract**

Document measured first-frame time, item/deadline behavior, runtime skill/session-hook fixtures, legacy migration, offline startup, APK output, and physical-device checklist. Explicitly state whether on-device smoke was executed.

- [ ] **Step 7: Commit**

```bash
git add test/core_regression_test.dart test/startup_performance_test.dart docs/superpowers/audits/2026-09-10-startup-plugin-runtime-reliability.md README.md
git commit -m "docs: verify startup and plugin runtime reliability"
```

---

## Execution Order

Tasks are sequential because they share startup state and cross-cut singleton initialization:

```text
1 coordinator
→ 2 first frame
→ 3 runtime rows/migration
→ 4 runtime skills
→ 5 session lifecycle
→ 6 concrete startup tasks
→ 7 durable status
→ 8 dashboard UI
→ 9 release gate
```

Read-only scouts and reviewers may run in parallel; implementation agents may not edit concurrently.
