import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_permissions.dart';
import 'package:ovid_ai/core/plugin_runtime.dart';
import 'package:ovid_ai/core/skills.dart';
import 'package:ovid_ai/core/startup_coordinator.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';
import 'package:ovid_ai/ui/shell.dart';
import 'package:ovid_ai/ui/startup_progress_panel.dart';

/// A startup task whose body is supplied by the test. Implements
/// [StartupOwnedTask] so the panel can deep-link by canonical id.
final class _Task implements StartupTask, StartupOwnedTask {
  _Task(
    this.id, {
    required this.kind,
    required this.label,
    required Future<StartupItemStatus> Function() run,
    this.timeout = const Duration(seconds: 15),
    this.onDisable,
    this.ownerId = '',
    // ignore: prefer_initializing_formals
  }) : _run = run;

  @override
  final String id;
  @override
  final StartupItemKind kind;
  @override
  final String label;
  @override
  final Duration timeout;
  @override
  final StartupDisable? onDisable;
  @override
  final String ownerId;

  final Future<StartupItemStatus> Function() _run;

  @override
  Future<StartupItemStatus> run() => _run();
}

StartupItemStatus _ready(String id, StartupItemKind kind, String label) =>
    StartupItemStatus.ready(id, kind, label);

/// A task with no static owner. Its [run] may return a status carrying an
/// owner id computed at run time — the aggregate `localSafety.migrate` case.
final class _PlainTask implements StartupTask {
  _PlainTask(
    this.id, {
    required this.kind,
    required this.label,
    required Future<StartupItemStatus> Function() run,
    // ignore: prefer_initializing_formals
  }) : _run = run;

  @override
  final String id;
  @override
  final StartupItemKind kind;
  @override
  final String label;
  @override
  Duration get timeout => const Duration(seconds: 15);

  final Future<StartupItemStatus> Function() _run;

  @override
  StartupDisable? get onDisable => null;

  @override
  Future<StartupItemStatus> run() => _run();
}

StartupItemStatus _terminal(
  String id,
  StartupItemKind kind,
  String label,
  StartupItemState state, {
  String? reason,
}) => StartupItemStatus(
  id: id,
  kind: kind,
  label: label,
  state: state,
  reason: reason,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    // The agent reminder tick runs forever; widget tests fail on a pending
    // timer at teardown, so pause it for the whole file.
    AgentService.I.debugPauseScheduleTimerForTest(true);
    app.sessions.clear();
    app.activeSessionId = null;
    SkillService.I.invalidateAllSessions();
    tempRoot = Directory.systemTemp.createTempSync('ovid-startup-widget-');
  });

  tearDown(() {
    AgentNotificationService.I.resetForTest();
    SkillService.I.invalidateAllSessions();
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    AppState.resetTestInstance();
  });

  ChatSession session(String id) {
    final s = ChatSession(id: id, title: 'Session', model: 'm', mode: 'auto');
    AppState.I.sessions.add(s);
    AppState.I.activeSessionId = id;
    return s;
  }

  Future<void> pumpPanel(WidgetTester tester, StartupCoordinator c) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: StartupProgressPanel(coordinator: c),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> pumpChat(
    WidgetTester tester,
    StartupCoordinator c, {
    bool shell = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: shell
            ? OvidShell(startupCoordinator: c)
            : ChatScreen(startupCoordinator: c),
      ),
    );
    await tester.pump();
  }

  NormalizedPluginManifest runtimeManifest(String id, {String name = 'Runtime'}) =>
      NormalizedPluginManifest(
        id: id,
        name: name,
        version: '1.0.0',
        format: PluginFormat.claudeCode,
        rootPath: '${tempRoot.path}/$id/content',
        requestedCapabilities: const {PluginCapability.workspaceRead},
      );

  Future<void> seedRuntimeEntry(NormalizedPluginManifest m) async {
    Directory(m.rootPath).createSync(recursive: true);
    final entry = PluginInstallEntry(
      activation: PluginActivationRecord(
        pluginId: m.id,
        state: PluginActivation.globalActive,
        installedBootEpoch: 0,
      ),
      manifest: m,
      contentDir: m.rootPath,
      version: m.version,
    );
    final prefs = await SharedPreferences.getInstance();
    final existingRaw = prefs.getString(kPluginActivationPrefKey);
    final entries = existingRaw == null || existingRaw.isEmpty
        ? <String, dynamic>{}
        : (jsonDecode(existingRaw) as Map).cast<String, dynamic>();
    entries[m.id] = jsonEncode(entry.toJson());
    await prefs.setString(kPluginActivationPrefKey, jsonEncode(entries));
    await PluginPermissionStore().save(
      PluginPermissionGrant(
        pluginId: m.id,
        manifestDigest: pluginManifestDigest(m),
        capabilities: m.requestedCapabilities,
        approvedAt: DateTime.utc(2026, 9, 10),
      ),
    );
  }

  testWidgets(
    'pending startup task keeps the composer usable and shows progress',
    (tester) async {
      session('s1');
      final gate = Completer<StartupItemStatus>();
      final c = StartupCoordinator.forTest(
        deadline: const Duration(seconds: 120),
      );
      unawaited(
        c.start([
          _Task(
            'localSafety.migrate',
            kind: StartupItemKind.localState,
            label: 'Prepare local state',
            run: () => gate.future,
          ),
        ]),
      );

      await pumpChat(tester, c, shell: true);

      expect(find.byKey(const ValueKey('startup-progress-bar')), findsOneWidget);
      final composer = find.byKey(const ValueKey('chat-composer'));
      expect(composer, findsOneWidget);
      expect(tester.widget<TextField>(composer).enabled, isTrue);
      await tester.enterText(composer, 'hello while loading');
      await tester.pump();
      expect(find.text('hello while loading'), findsOneWidget);
      expect(find.textContaining('Prepare local state'), findsWidgets);

      gate.complete(
        _ready('localSafety.migrate', StartupItemKind.localState, 'Prepare local state'),
      );
      await tester.pump();
      await tester.pump();
    },
  );

  testWidgets('panel advances X of Y and auto-collapses when complete', (
    tester,
  ) async {
    session('s2');
    final gates = List.generate(3, (_) => Completer<StartupItemStatus>());
    final c = StartupCoordinator.forTest(deadline: const Duration(seconds: 120));
    unawaited(
      c.start([
        for (var i = 0; i < 3; i++)
          _Task(
            'item$i',
            kind: StartupItemKind.plugin,
            label: 'Item $i',
            run: () => gates[i].future,
          ),
      ]),
    );

    await pumpPanel(tester, c);
    expect(find.text('Finishing setup · 0 of 3'), findsOneWidget);
    expect(find.byKey(const ValueKey('startup-item-item0')), findsOneWidget);

    gates[0].complete(
      _ready('item0', StartupItemKind.plugin, 'Item 0'),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Finishing setup · 1 of 3'), findsOneWidget);

    gates[1].complete(
      _ready('item1', StartupItemKind.plugin, 'Item 1'),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Finishing setup · 2 of 3'), findsOneWidget);

    gates[2].complete(
      _ready('item2', StartupItemKind.plugin, 'Item 2'),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Finishing setup · 3 of 3'), findsOneWidget);
    // Auto-collapse once every item is terminal.
    expect(find.byKey(const ValueKey('startup-item-item0')), findsNothing);
    expect(find.byKey(const ValueKey('startup-item-item2')), findsNothing);
  });

  testWidgets('panel renders exact state copy including Unsupported', (
    tester,
  ) async {
    session('s3');
    final pending = Completer<StartupItemStatus>();
    final c = StartupCoordinator.forTest(deadline: const Duration(seconds: 120));
    unawaited(
      c.start([
        _Task(
          'ready',
          kind: StartupItemKind.plugin,
          label: 'Ready item',
          run: () async =>
              _ready('ready', StartupItemKind.plugin, 'Ready item'),
        ),
        _Task(
          'needs',
          kind: StartupItemKind.mcp,
          label: 'Needs item',
          run: () async => _terminal(
            'needs',
            StartupItemKind.mcp,
            'Needs item',
            StartupItemState.needsSetup,
            reason: 'Add a token',
          ),
        ),
        _Task(
          'migration',
          kind: StartupItemKind.plugin,
          label: 'Migration item',
          run: () async => _terminal(
            'migration',
            StartupItemKind.plugin,
            'Migration item',
            StartupItemState.migrationRequired,
            reason: 'Re-approve this plugin before it can run',
          ),
        ),
        _Task(
          'unsupported',
          kind: StartupItemKind.plugin,
          label: 'Unsupported item',
          run: () async => _terminal(
            'unsupported',
            StartupItemKind.plugin,
            'Unsupported item',
            StartupItemState.unsupported,
            reason: 'No compatible runtime',
          ),
        ),
        _Task(
          'degraded',
          kind: StartupItemKind.marketplace,
          label: 'Degraded item',
          run: () async => _terminal(
            'degraded',
            StartupItemKind.marketplace,
            'Degraded item',
            StartupItemState.degraded,
            reason: 'Cached content',
          ),
        ),
        _Task(
          'failed',
          kind: StartupItemKind.plugin,
          label: 'Failed item',
          run: () async => _terminal(
            'failed',
            StartupItemKind.plugin,
            'Failed item',
            StartupItemState.failed,
            reason: 'Installed content is missing',
          ),
        ),
        _Task(
          'disabled',
          kind: StartupItemKind.plugin,
          label: 'Disabled item',
          run: () async => _terminal(
            'disabled',
            StartupItemKind.plugin,
            'Disabled item',
            StartupItemState.disabled,
          ),
        ),
        _Task(
          'skipped',
          kind: StartupItemKind.sandbox,
          label: 'Skipped item',
          run: () async => _terminal(
            'skipped',
            StartupItemKind.sandbox,
            'Skipped item',
            StartupItemState.skipped,
            reason: 'Sandbox is not installed on this device',
          ),
        ),
        _Task(
          'loading',
          kind: StartupItemKind.mcp,
          label: 'Loading item',
          run: () => pending.future,
        ),
      ]),
    );

    await pumpPanel(tester, c);

    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('Needs setup'), findsOneWidget);
    expect(find.text('Migration required'), findsOneWidget);
    expect(find.text('Unsupported on this device'), findsOneWidget);
    expect(find.text('Degraded'), findsNWidgets(2));
    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('Disabled'), findsOneWidget);
    expect(find.text('Loading'), findsOneWidget);

    // Retry is offered for failed/degraded/skipped.
    expect(
      find.byKey(const ValueKey('startup-retry-failed')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('startup-retry-degraded')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('startup-retry-skipped')),
      findsOneWidget,
    );

    pending.complete(
      _ready('loading', StartupItemKind.mcp, 'Loading item'),
    );
    await tester.pump();
    await tester.pump();
  });

  testWidgets('Retry and Disable delegate only to the selected item', (
    tester,
  ) async {
    session('s4');
    final runs = <String, int>{'pluginA': 0, 'pluginB': 0, 'local': 0};
    final disables = <String>[];
    final c = StartupCoordinator.forTest(deadline: const Duration(seconds: 120));
    unawaited(
      c.start([
        _Task(
          'pluginA',
          kind: StartupItemKind.plugin,
          label: 'Plugin A',
          ownerId: 'acme/a',
          onDisable: () async => disables.add('pluginA'),
          run: () async {
            runs['pluginA'] = runs['pluginA']! + 1;
            return _terminal(
              'pluginA',
              StartupItemKind.plugin,
              'Plugin A',
              StartupItemState.failed,
              reason: 'boom',
            );
          },
        ),
        _Task(
          'pluginB',
          kind: StartupItemKind.plugin,
          label: 'Plugin B',
          ownerId: 'acme/b',
          onDisable: () async => disables.add('pluginB'),
          run: () async {
            runs['pluginB'] = runs['pluginB']! + 1;
            return _terminal(
              'pluginB',
              StartupItemKind.plugin,
              'Plugin B',
              StartupItemState.failed,
              reason: 'boom',
            );
          },
        ),
        _Task(
          'local',
          kind: StartupItemKind.localState,
          label: 'Local state',
          run: () async {
            runs['local'] = runs['local']! + 1;
            return _terminal(
              'local',
              StartupItemKind.localState,
              'Local state',
              StartupItemState.failed,
              reason: 'boom',
            );
          },
        ),
      ]),
    );

    await pumpPanel(tester, c);
    expect(runs, {'pluginA': 1, 'pluginB': 1, 'local': 1});

    // All items are terminal, so the panel auto-collapsed; re-expand it.
    await tester.tap(find.byKey(const ValueKey('startup-panel-toggle')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('startup-retry-pluginA')));
    await tester.pump();
    await tester.pump();
    expect(runs, {'pluginA': 2, 'pluginB': 1, 'local': 1});

    await tester.tap(find.byKey(const ValueKey('startup-disable-pluginA')));
    await tester.pump();
    await tester.pump();
    expect(disables, ['pluginA']);
    expect(find.text('Disabled'), findsOneWidget);

    // Local (non-plugin) items never expose Disable.
    expect(find.byKey(const ValueKey('startup-disable-local')), findsNothing);
    // The local item was never retried by the plugin actions.
    expect(runs['local'], 1);
  });

  testWidgets(
    '120s deadline degrades a hanging item and keeps the composer usable',
    (tester) async {
      session('s5');
      final never = Completer<StartupItemStatus>();
      final c = StartupCoordinator.forTest(
        deadline: const Duration(seconds: 120),
      );
      unawaited(
        c.start([
          _Task(
            'mcp.connect:acme/server',
            kind: StartupItemKind.mcp,
            label: 'Connect MCP',
            ownerId: 'acme/server',
            timeout: const Duration(seconds: 300),
            run: () => never.future,
          ),
        ]),
      );

      await pumpChat(tester, c);
      expect(find.text('Loading'), findsWidgets);

      await tester.pump(const Duration(seconds: 120));
      await tester.pump();

      // The panel collapses once the deadline makes the item terminal;
      // re-expand to inspect the degraded row and its Retry action.
      await tester.tap(find.byKey(const ValueKey('startup-panel-toggle')));
      await tester.pump();

      expect(find.text('Degraded'), findsWidgets);
      expect(
        find.byKey(const ValueKey('startup-retry-mcp.connect:acme/server')),
        findsOneWidget,
      );
      final composer = find.byKey(const ValueKey('chat-composer'));
      expect(tester.widget<TextField>(composer).enabled, isTrue);
      await tester.enterText(composer, 'typing after deadline');
      await tester.pump();
      expect(find.text('typing after deadline'), findsOneWidget);

      never.complete(
        _ready('mcp.connect:acme/server', StartupItemKind.mcp, 'Connect MCP'),
      );
      await tester.pump();
    },
  );

  testWidgets('coordinator transitions preserve rendered-session Stop isolation', (
    tester,
  ) async {
    final agent = AgentService.I;
    final a = session('stop-a');
    final b = ChatSession(id: 'stop-b', title: 'B', model: 'm', mode: 'auto');
    AppState.I.sessions.add(b);
    AppState.I.activeSessionId = a.id;
    final runA = agent.runBucketForTest(a.id)..activeRunId = 'run-a';
    final runB = agent.runBucketForTest(b.id)..activeRunId = 'run-b';
    final c = StartupCoordinator.forTest(deadline: const Duration(seconds: 120));
    unawaited(
      c.start([
        _Task(
          'localSafety.migrate',
          kind: StartupItemKind.localState,
          label: 'Prepare local state',
          run: () async => _ready(
            'localSafety.migrate',
            StartupItemKind.localState,
            'Prepare local state',
          ),
        ),
      ]),
    );

    await pumpChat(tester, c);
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byIcon(Icons.stop_rounded));
    await tester.pump();

    expect(runA.activeRunId, isNull);
    expect(runA.cancelRequested, isTrue);
    expect(runB.activeRunId, 'run-b');
    expect(runB.cancelRequested, isFalse);

    agent.dropSessionRun(a.id);
    agent.dropSessionRun(b.id);
  });

  testWidgets('composer skill suggestions refresh when skill.mount settles', (
    tester,
  ) async {
    final s = session('skill-session');
    final gate = Completer<StartupItemStatus>();
    final c = StartupCoordinator.forTest(deadline: const Duration(seconds: 120));
    unawaited(
      c.start([
        _Task(
          'skill.mount',
          kind: StartupItemKind.skillMount,
          label: 'Mount session skills',
          run: () => gate.future,
        ),
      ]),
    );

    await pumpChat(tester, c);
    final composer = find.byKey(const ValueKey('chat-composer'));
    await tester.enterText(composer, '/research');
    await tester.pump();
    expect(
      find.textContaining('plugin:acme/research-kit/skill:research'),
      findsNothing,
    );

    // Mount the runtime skill directly (no AppState notification) and then
    // settle the coordinator item; the composer must refresh on the startup
    // transition, not on an unrelated rebuild.
    final root = Directory('${tempRoot.path}/acme/research-kit')
      ..createSync(recursive: true);
    File('${root.path}/skills/research/SKILL.md')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '---\nname: research\nuser-invocable: true\n---\nRESEARCH',
      );
    final manifest = NormalizedPluginManifest(
      id: 'acme/research-kit',
      name: 'Research Kit',
      version: '1.0.0',
      format: PluginFormat.claudeCode,
      rootPath: root.path,
      skills: const [
        PluginSkill(
          pluginId: 'acme/research-kit',
          name: 'research',
          path: 'skills/research/SKILL.md',
        ),
      ],
    );
    await tester.runAsync(() async {
      await SkillService.I.publishSessionCatalog(
        s.id,
        mounts: [PluginCatalogMount(root.path, manifest)],
      );
    });
    expect(SkillService.I.userSkillsForSession(s.id), hasLength(1));

    gate.complete(
      _ready('skill.mount', StartupItemKind.skillMount, 'Mount session skills'),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.textContaining('plugin:acme/research-kit/skill:research'),
      findsOneWidget,
    );
  });

  testWidgets('durable plugin reason survives an app recreate', (tester) async {
    const id = 'acme/broken';
    final prefs = await SharedPreferences.getInstance();
    final inner = jsonEncode({
      'pluginId': id,
      'state': 'failed',
      'reason': 'Installed content is missing',
      'updatedAt': DateTime.utc(2026, 9, 10).toIso8601String(),
      'logs': <String>[],
      'wireVersion': 1,
    });
    await prefs.setString(kPluginRuntimeStatusPrefKey, jsonEncode({id: inner}));

    Future<void> showCard() async {
      await AppState.I.hydrateRuntimeStatuses();
      final row = PluginItem(
        name: 'Broken Plugin',
        author: 'acme',
        description: 'A broken runtime plugin',
        version: '1.0.0',
        category: 'Tool',
        installed: true,
        enabled: true,
        runtimeId: id,
      );
      AppState.I.plugins.add(row);
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Scaffold(body: PluginCard(plugin: row)),
        ),
      );
      await tester.pump();
    }

    await showCard();
    expect(find.textContaining('Installed content is missing'), findsOneWidget);
    // A durable Failed must never fall back to the installed/enabled check.
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);

    AppState.resetTestInstance();
    AppState.createForTest();
    AppState.I.seenWelcomeVersion = AppState.welcomeVersion;

    await showCard();
    expect(find.textContaining('Installed content is missing'), findsOneWidget);
  });

  testWidgets(
    'panel exposes progress semantics and action labels at 2x text scale',
    (tester) async {
      session('s9');
      final handle = tester.ensureSemantics();
      final pending = Completer<StartupItemStatus>();
      final c = StartupCoordinator.forTest(
        deadline: const Duration(seconds: 120),
      );
      unawaited(
        c.start([
          _Task(
            'failed',
            kind: StartupItemKind.plugin,
            label: 'Failed plugin',
            ownerId: 'acme/failed',
            onDisable: () async {},
            run: () async => _terminal(
              'failed',
              StartupItemKind.plugin,
              'Failed plugin',
              StartupItemState.failed,
              reason: 'boom',
            ),
          ),
          _Task(
            'needs',
            kind: StartupItemKind.mcp,
            label: 'Needs setup server',
            ownerId: 'acme/server',
            run: () async => _terminal(
              'needs',
              StartupItemKind.mcp,
              'Needs setup server',
              StartupItemState.needsSetup,
              reason: 'Add a token',
            ),
          ),
          _Task(
            'loading',
            kind: StartupItemKind.mcp,
            label: 'Loading item',
            run: () => pending.future,
          ),
        ]),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(2.0)),
              child: SingleChildScrollView(
                child: StartupProgressPanel(coordinator: c),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.bySemanticsLabel('Startup progress'), findsOneWidget);
      final toggle = tester.getSemantics(
        find.byKey(const ValueKey('startup-panel-toggle')),
      );
      expect(toggle.flagsCollection.isButton, isTrue);
      expect(find.text('Retry'), findsWidgets);
      expect(find.text('Disable'), findsWidgets);
      expect(find.text('Open Plugins'), findsWidgets);
      expect(tester.takeException(), isNull);

      pending.complete(
        _ready('loading', StartupItemKind.mcp, 'Loading item'),
      );
      await tester.pump();
      handle.dispose();
    },
  );

  testWidgets('panel and composer survive narrow and wide layouts', (
    tester,
  ) async {
    session('s10');
    final gate = Completer<StartupItemStatus>();
    final c = StartupCoordinator.forTest(deadline: const Duration(seconds: 120));
    unawaited(
      c.start([
        _Task(
          'localSafety.migrate',
          kind: StartupItemKind.localState,
          label: 'Prepare local state',
          run: () => gate.future,
        ),
      ]),
    );

    for (final size in [const Size(360, 640), const Size(1200, 800)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: ChatScreen(startupCoordinator: c),
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('startup-progress-bar')), findsOneWidget);
      final composer = find.byKey(const ValueKey('chat-composer'));
      expect(composer, findsOneWidget);
      final rect = tester.getRect(composer);
      expect(rect.top, greaterThanOrEqualTo(-1));
      expect(rect.bottom, lessThanOrEqualTo(size.height + 1));
      expect(tester.takeException(), isNull);
    }

    gate.complete(
      _ready(
        'localSafety.migrate',
        StartupItemKind.localState,
        'Prepare local state',
      ),
    );
    await tester.pump();
  });

  testWidgets(
    'panel expands when tasks queue after an empty first snapshot',
    (tester) async {
      // Production readiness starts post-frame: the panel first sees an empty
      // snapshot (readinessComplete is vacuously true), then tasks arrive.
      final c = StartupCoordinator.forTest(
        deadline: const Duration(seconds: 120),
      );
      await pumpPanel(tester, c);
      expect(find.textContaining('Finishing setup'), findsNothing);

      final gate = Completer<StartupItemStatus>();
      unawaited(
        c.start([
          _Task(
            'local.hydrate',
            kind: StartupItemKind.localState,
            label: 'Load local state',
            run: () => gate.future,
          ),
        ]),
      );
      await tester.pump();

      expect(find.text('Finishing setup · 0 of 1'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('startup-item-local.hydrate')),
        findsOneWidget,
      );

      gate.complete(
        _ready('local.hydrate', StartupItemKind.localState, 'Load local state'),
      );
      await tester.pump();
      await tester.pump();
      // Auto-collapse once the only item is terminal.
      expect(
        find.byKey(const ValueKey('startup-item-local.hydrate')),
        findsNothing,
      );
    },
  );

  testWidgets('Disable renders only for rows with a real disable callback', (
    tester,
  ) async {
    final c = StartupCoordinator.forTest(deadline: const Duration(seconds: 120));
    unawaited(
      c.start([
        _Task(
          'plugin.activate',
          kind: StartupItemKind.plugin,
          label: 'Activate plugins',
          run: () async => _terminal(
            'plugin.activate',
            StartupItemKind.plugin,
            'Activate plugins',
            StartupItemState.failed,
            reason: 'boot failed',
          ),
        ),
        _Task(
          'plugin.activate:acme/x',
          kind: StartupItemKind.plugin,
          label: 'Acme X',
          ownerId: 'acme/x',
          onDisable: () async {},
          run: () async => _terminal(
            'plugin.activate:acme/x',
            StartupItemKind.plugin,
            'Acme X',
            StartupItemState.failed,
            reason: 'boom',
          ),
        ),
        _Task(
          'mcp.connect:acme/server',
          kind: StartupItemKind.mcp,
          label: 'Acme Server',
          ownerId: 'acme/server',
          onDisable: () async {},
          run: () async => _terminal(
            'mcp.connect:acme/server',
            StartupItemKind.mcp,
            'Acme Server',
            StartupItemState.failed,
            reason: 'boom',
          ),
        ),
        _Task(
          'localSafety.migrate',
          kind: StartupItemKind.localState,
          label: 'Local state',
          run: () async => _terminal(
            'localSafety.migrate',
            StartupItemKind.localState,
            'Local state',
            StartupItemState.failed,
            reason: 'boom',
          ),
        ),
      ]),
    );

    await pumpPanel(tester, c);
    // Every item is terminal → auto-collapsed; re-expand to inspect actions.
    await tester.tap(find.byKey(const ValueKey('startup-panel-toggle')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('startup-disable-plugin.activate')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('startup-disable-plugin.activate:acme/x')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('startup-disable-mcp.connect:acme/server')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('startup-disable-localSafety.migrate')),
      findsNothing,
    );
  });

  test(
    'readiness emits one plugin item per canonical runtime in sorted order',
    () async {
      await seedRuntimeEntry(runtimeManifest('zeta/two', name: 'Zeta Two'));
      await seedRuntimeEntry(runtimeManifest('alpha/one', name: 'Alpha One'));

      final tasks = await AppState.I.buildReadinessTasks();
      final pluginTasks = tasks
          .where((task) => task.id.startsWith('plugin.activate:'))
          .toList();

      expect(pluginTasks.map((task) => task.id), [
        'plugin.activate:alpha/one',
        'plugin.activate:zeta/two',
      ]);
      expect(
        pluginTasks.map((task) => (task as StartupOwnedTask).ownerId),
        ['alpha/one', 'zeta/two'],
      );
      expect(
        pluginTasks.map((task) => task.kind),
        everyElement(StartupItemKind.plugin),
      );
      expect(
        tasks.where((task) => task.id == 'plugin.activate'),
        isEmpty,
        reason: 'per-runtime items replace the single aggregate',
      );
    },
  );

  test('zero normalized runtimes still emit the aggregate boot item', () async {
    final tasks = await AppState.I.buildReadinessTasks();
    expect(tasks.where((task) => task.id == 'plugin.activate'), hasLength(1));
    expect(
      tasks.where((task) => task.id.startsWith('plugin.activate:')),
      isEmpty,
    );
  });

  test(
    'per-runtime plugin items share one boot activation and one epoch',
    () async {
      await seedRuntimeEntry(runtimeManifest('alpha/one', name: 'Alpha One'));
      await seedRuntimeEntry(runtimeManifest('zeta/two', name: 'Zeta Two'));

      var activatorCalls = 0;
      final app = AppState.createForTest(
        startupStageDelegates: {
          'marketplace.refresh': () async {},
          'mcp.connect': () async {},
          'firebase.initialize': () async {},
          'github.initialize': () async {},
          'sandbox.selfHeal': () async {},
        },
        pluginBootActivator: (token, connect) {
          activatorCalls++;
          return PluginRuntimeManager.I.activateForBoot(
            bootToken: token,
            connectMcp: connect,
            reportFailure: true,
          );
        },
      );

      await app.initializeReadiness();

      final prefs = await SharedPreferences.getInstance();
      expect(activatorCalls, 1);
      expect(prefs.getInt(kPluginBootEpochPrefKey), 1);
    },
  );

  testWidgets(
    'Open Plugins deep-links, highlights, and scrolls the canonical row',
    (tester) async {
      const targetId = 'acme/target';
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        kPluginRuntimeStatusPrefKey,
        jsonEncode({
          targetId: jsonEncode({
            'pluginId': targetId,
            'state': 'failed',
            'reason': 'Installed content is missing',
            'updatedAt': DateTime.utc(2026, 9, 10).toIso8601String(),
            'logs': <String>[],
            'wireVersion': 1,
          }),
        }),
      );
      await AppState.I.hydrateRuntimeStatuses();
      AppState.I.plugins.clear();
      for (var i = 0; i < 12; i++) {
        AppState.I.plugins.add(
          PluginItem(
            name: 'Same Name',
            author: 'acme',
            description: 'row $i',
            version: '1.0.0',
            category: 'Tool',
            installed: true,
            enabled: true,
            runtimeId: 'acme/p$i',
          ),
        );
      }
      AppState.I.plugins.add(
        PluginItem(
          name: 'Same Name',
          author: 'acme',
          description: 'target row',
          version: '1.0.0',
          category: 'Tool',
          installed: true,
          enabled: true,
          runtimeId: targetId,
        ),
      );

      tester.view.physicalSize = const Size(400, 520);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: const PluginsScreen(focusCanonicalId: targetId),
        ),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }

      // Only the exact canonical row is highlighted, even though every row
      // shares the display name "Same Name".
      expect(
        find.byKey(const ValueKey('plugin-card-highlight-$targetId')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('plugin-card-highlight-acme/p0')),
        findsNothing,
      );
      final rect = tester.getRect(
        find.byKey(const ValueKey('plugin-card-$targetId')),
      );
      expect(rect.top, greaterThanOrEqualTo(-1));
      expect(rect.bottom, lessThanOrEqualTo(521));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'long state labels do not overflow the expanded panel at 2x on narrow',
    (tester) async {
      session('s11');
      final c = StartupCoordinator.forTest(
        deadline: const Duration(seconds: 120),
      );
      unawaited(
        c.start([
          _Task(
            'unsupported',
            kind: StartupItemKind.plugin,
            label: 'Unsupported runtime plugin with a long name',
            ownerId: 'acme/unsupported',
            run: () async => _terminal(
              'unsupported',
              StartupItemKind.plugin,
              'Unsupported runtime plugin with a long name',
              StartupItemState.unsupported,
              reason: 'No compatible ABI or runtime is available',
            ),
          ),
          _Task(
            'migration',
            kind: StartupItemKind.plugin,
            label: 'Legacy plugin needing migration',
            ownerId: 'acme/legacy',
            run: () async => _terminal(
              'migration',
              StartupItemKind.plugin,
              'Legacy plugin needing migration',
              StartupItemState.migrationRequired,
              reason: 'Re-approve this legacy plugin before it can run',
            ),
          ),
        ]),
      );

      for (final size in [const Size(360, 640), const Size(1200, 800)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            theme: Aether.theme(),
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(2.0)),
              child: ChatScreen(
                key: ValueKey(size),
                startupCoordinator: c,
              ),
            ),
          ),
        );
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        // All items are terminal → auto-collapsed; re-expand to lay out the
        // long state labels.
        await tester.tap(find.byKey(const ValueKey('startup-panel-toggle')));
        await tester.pump();

        expect(
          find.text('Unsupported on this device'),
          findsOneWidget,
        );
        expect(find.text('Migration required'), findsOneWidget);
        final composer = find.byKey(const ValueKey('chat-composer'));
        expect(composer, findsOneWidget);
        final rect = tester.getRect(composer);
        expect(rect.top, greaterThanOrEqualTo(-1));
        expect(rect.bottom, lessThanOrEqualTo(size.height + 1));
        expect(tester.takeException(), isNull);
      }
    },
  );

  PluginItem legacyRow({
    required String name,
    String? source,
    bool migrationRequired = true,
    String? runtimeReason =
        'Re-approve this legacy plugin before it can run',
  }) => PluginItem(
    name: name,
    author: 'legacy',
    description: 'legacy row',
    version: '1.0.0',
    category: 'Tool',
    installed: true,
    enabled: false,
    source: source,
    migrationRequired: migrationRequired,
    runtimeReason: runtimeReason,
  );

  testWidgets(
    'legacy migration row shows state + reason on card and detail',
    (tester) async {
      AppState.I.plugins.clear();
      final row = legacyRow(name: 'Legacy Migrate', source: 'legacy/migrate');
      AppState.I.plugins.add(row);

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Scaffold(body: PluginCard(plugin: row)),
        ),
      );
      await tester.pump();
      expect(find.textContaining('Migration required'), findsWidgets);
      expect(
        find.textContaining('Re-approve this legacy plugin'),
        findsWidgets,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: PluginDetailScreen(plugin: row),
        ),
      );
      await tester.pump();
      expect(find.text('Migration required'), findsOneWidget);
      expect(
        find.text('Re-approve this legacy plugin before it can run'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('legacy migration row deep-links and focuses its card', (
    tester,
  ) async {
    AppState.I.plugins.clear();
    final row = legacyRow(name: 'Legacy Focus', source: 'legacy/focus');
    AppState.I.plugins.add(row);
    final focusId = legacyPluginFocusId(row, 0);

    tester.view.physicalSize = const Size(400, 520);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: PluginsScreen(focusCanonicalId: focusId),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }

    expect(
      find.byKey(ValueKey('plugin-card-highlight-$focusId')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('same-name legacy rows do not cross-target focus', (
    tester,
  ) async {
    AppState.I.plugins.clear();
    final a = legacyRow(name: 'Twin Legacy', source: 'legacy/a');
    final b = legacyRow(name: 'Twin Legacy', source: 'legacy/b');
    AppState.I.plugins.addAll([a, b]);
    final focusA = legacyPluginFocusId(a, 0);
    final focusB = legacyPluginFocusId(b, 1);

    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: PluginsScreen(focusCanonicalId: focusA),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }

    expect(
      find.byKey(ValueKey('plugin-card-highlight-$focusA')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('plugin-card-highlight-$focusB')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'migration sentinel filters and highlights every migration row',
    (tester) async {
      AppState.I.plugins.clear();
      final a = legacyRow(name: 'Migrate A', source: 'legacy/a');
      final b = legacyRow(name: 'Migrate B', source: 'legacy/b');
      final healthy = PluginItem(
        name: 'Healthy Plugin',
        author: 'you',
        description: 'fine',
        version: '1.0.0',
        category: 'Tool',
        installed: true,
        enabled: true,
      );
      AppState.I.plugins.addAll([a, b, healthy]);

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: const PluginsScreen(focusCanonicalId: kMigrationRequiredFocusId),
        ),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }

      expect(find.text('NEEDS RE-APPROVAL'), findsOneWidget);
      expect(find.text('Healthy Plugin'), findsNothing);
      expect(
        find.byKey(ValueKey('plugin-card-highlight-${legacyPluginFocusId(a, 0)}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('plugin-card-highlight-${legacyPluginFocusId(b, 1)}')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Open Plugins receives the owner a non-owned task returned at run time',
    (tester) async {
      final c = StartupCoordinator.forTest(
        deadline: const Duration(seconds: 120),
      );
      String? openedWith;
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Scaffold(
            body: StartupProgressPanel(
              coordinator: c,
              onOpenPlugins: (id) => openedWith = id,
            ),
          ),
        ),
      );
      await tester.pump();

      unawaited(
        c.start([
          _PlainTask(
            'localSafety.migrate',
            kind: StartupItemKind.localState,
            label: 'Check local plugin safety',
            run: () async => StartupItemStatus.migrationRequired(
              'localSafety.migrate',
              StartupItemKind.localState,
              'Check local plugin safety',
              reason: 'Re-approve this legacy plugin before it can run',
              ownerId: 'legacy:legacy/solo:0',
            ),
          ),
        ]),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      // All items terminal → auto-collapsed; re-expand to reach the action.
      await tester.tap(find.byKey(const ValueKey('startup-panel-toggle')));
      await tester.pump();
      await tester.tap(
        find.byKey(
          const ValueKey('startup-open-plugins-localSafety.migrate'),
        ),
      );
      await tester.pump();

      expect(openedWith, 'legacy:legacy/solo:0');
    },
  );
}
