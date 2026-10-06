import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/memory_store.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/studio_setup_coordinator.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/memory_screen.dart';
import 'package:ovid_ai/ui/sandbox_setup.dart';
import 'package:ovid_ai/ui/subagent_screen.dart';
import 'package:ovid_ai/ui/trajectory_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _capture = bool.fromEnvironment('UI_REVIEW_CAPTURE');
const _captureKey = ValueKey('ui-finish-14-capture');
const _longName = 'research-notes-with-a-long-but-valid-filename.md';
const _agentLabel = 'Research agent reviewing the complete implementation history';
const _failure = 'Package verification failed. The downloaded runtime could not '
    'be verified against the signed release manifest. Reconnect and retry the '
    'installation to download a fresh copy without replacing the existing core.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final agent = AgentService.I;
  late Directory root;
  late MemoryStore memory;
  late AppState app;
  late bool wasDark;
  final ledgerIds = <String>{};

  setUp(() async {
    wasDark = Aether.dark;
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
    root = Directory.systemTemp.createTempSync('ui-finish-14-');
    memory = MemoryStore(Directory('${root.path}/memory'));
    SessionLedger.rootOverrideForTest = Directory('${root.path}/ledger')
      ..createSync();
    app = AppState.createForTest(memoryStore: memory);
    AgentNotificationService.I.resetForTest();
    agent.debugPauseScheduleTimerForTest(true);
  });

  tearDown(() async {
    for (final id in ledgerIds) {
      agent.dropSessionRun(id);
      await SessionLedger.I.close(id);
    }
    ledgerIds.clear();
    await app.persistSessions();
    StudioSetupCoordinator.overrideForTest?.dispose();
    StudioSetupCoordinator.overrideForTest = null;
    SessionLedger.rootOverrideForTest = null;
    AppState.resetTestInstance();
    AgentNotificationService.I.resetForTest();
    agent.debugPauseScheduleTimerForTest(false);
    Aether.dark = wasDark;
    root.deleteSync(recursive: true);
  });

  final views = [
    (name: 'phone large text dark', size: const Size(360, 640), scale: 2.0, dark: true),
    (name: 'phone large text light', size: const Size(360, 640), scale: 2.0, dark: false),
    (name: 'small phone', size: const Size(320, 640), scale: 1.0, dark: true),
    (name: 'desktop dark', size: const Size(1024, 768), scale: 1.0, dark: true),
    (name: 'desktop light', size: const Size(1024, 768), scale: 1.0, dark: false),
  ];

  for (final view in views) {
    Future<void> mount(WidgetTester tester, Widget screen) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = view.size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Aether.dark = view.dark;
      await tester.pumpWidget(MaterialApp(
        theme: Aether.theme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(view.scale),
          ),
          child: child!,
        ),
        home: RepaintBoundary(key: _captureKey, child: screen),
      ));
    }

    testWidgets('memory saves long content and preserves conflicts: ${view.name}', (tester) async {
      await tester.runAsync(() async {
        await app.prepareMemory();
        memory.save(null, _longName, 'Original note', mode: 'create');
        await mount(tester, const MemoryScreen());
      });
      await _brief(tester);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text(_longName));
      await tester.tap(find.text(_longName));
      await _brief(tester);
      final editor = find.byKey(const Key('memory-content'));
      await tester.ensureVisible(editor);
      await tester.enterText(editor, 'A long plain Markdown note.\n' * 24);
      await tester.tap(find.text('Save'));
      await _brief(tester);
      expect(memory.read(null, _longName).content, 'A long plain Markdown note.\n' * 24);
      memory.save(null, _longName, 'Newer external content', mode: 'append');
      await tester.enterText(editor, 'Unsaved conflicting draft');
      await tester.tap(find.text('Save'));
      await _brief(tester);
      expect(find.textContaining('Reload before saving'), findsOneWidget);
      expect(memory.read(null, _longName).content, endsWith('Newer external content'));
      await tester.tap(find.text('Reload'));
      await _brief(tester);
      await tester.tap(find.text('Keep editing'));
      await _brief(tester);
      expect(tester.widget<TextField>(editor).controller!.text, 'Unsaved conflicting draft');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('trajectory scrolls stats, inspects raw data, reloads: ${view.name}', (tester) async {
      const id = 'finish-14-trajectory';
      ledgerIds.add(id);
      app.sessions.add(ChatSession(id: id, title: 'Research history', model: 'm', mode: 'auto'));
      await tester.runAsync(() async {
        await SessionLedger.I.append(id, 'turn_start', {'turn': 1, 'msgs': 3});
        await SessionLedger.I.append(id, 'tool_start', {'tool': 'read_long_project_documentation'});
        await SessionLedger.I.append(id, 'tool_end', {
          'tool': 'read_long_project_documentation',
          'ms': 42.5,
          'ok': false,
          'error': _failure,
          'data': {'path': '/workspace/project/docs/complete-history.md', 'tokens': 1234},
        });
        await mount(tester, const TrajectoryScreen(sessionId: id));
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        await _ledgerReady(tester, id);
      });
      expect(tester.takeException(), isNull);
      expect(find.textContaining('1 turns · 1 tool calls'), findsOneWidget);
      if (_capture && view.name == 'desktop dark') {
        await _captureScreen(tester);
      }
      final details = find.byKey(const ValueKey('trajectory-detail-3'));
      await tester.scrollUntilVisible(details, 180, scrollable: find.byType(Scrollable).first);
      await tester.pump();
      await tester.ensureVisible(details);
      await tester.pump();
      expect(details.hitTestable(), findsOneWidget);
      await tester.tap(details);
      await _brief(tester);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(tester.widget<SelectableText>(find.byType(SelectableText)).data,
          contains('/workspace/project/docs/complete-history.md'));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Close'));
      await _brief(tester);
      await tester.runAsync(() async {
        await SessionLedger.I.append(id, 'note', {'text': 'Additional durable record'});
        await tester.tap(find.byTooltip('Reload ledger'));
        await tester.pump();
        await _ledgerReady(tester, id);
      });
      await tester.scrollUntilVisible(find.text('Additional durable record'), 180,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Additional durable record'), findsOneWidget);
      expect((await tester.runAsync(() => SessionLedger.I.read(id)))!.length, 4);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('subagent long catalog opens own record and stops only child: ${view.name}', (tester) async {
      final parent = ChatSession(id: 'finish-14-parent', title: 'Root project', model: 'm', mode: 'auto');
      final child = ChatSession(id: 'finish-14-child', title: _agentLabel, model: 'm',
          mode: 'A long descriptive execution mode', parentId: parent.id,
          agentLabel: _agentLabel, agentState: 'running');
      ledgerIds.addAll([parent.id, child.id]);
      app.sessions.addAll([parent, child]);
      agent.runBucketForTest(parent.id).activeRunId = 'parent-run';
      agent.runBucketForTest(child.id).activeRunId = 'child-run';
      await mount(tester, Builder(builder: (context) => Scaffold(body: TextButton(
        onPressed: () => showSubagentCatalog(context, parent.id),
        child: const Text('Open children'),
      ))));
      await tester.tap(find.text('Open children'));
      await _brief(tester);
      expect(tester.takeException(), isNull);
      final stop = find.byKey(ValueKey('subagent-stop-${child.id}'));
      await tester.ensureVisible(stop);
      await tester.pump();
      expect(stop.hitTestable(), findsOneWidget);
      // Stop persists session state and appends a real ledger checkpoint.
      // Start and drain that IO in the real zone, before fake-async teardown.
      await tester.runAsync(() async {
        await tester.tap(stop);
        await app.flushSessionPersistenceForTest();
        await SessionLedger.I.read(child.id);
      });
      await _brief(tester);
      expect(agent.busyFor(child.id), isFalse);
      expect(agent.busyFor(parent.id), isTrue);
      expect(child.agentState, 'stopped');
      await tester.ensureVisible(find.text(_agentLabel));
      await tester.pump();
      await tester.tap(find.text(_agentLabel));
      await _brief(tester);
      expect(find.byType(SubagentScreen), findsOneWidget);
      expect(find.text('No activity recorded.'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('setup approval, live log, long failure and retry: ${view.name}', (tester) async {
      var attempts = 0;
      final barrier = Completer<void>();
      final coordinator = StudioSetupCoordinator(
        checkExisting: () async => false,
        install: (progress, full) async {
          expect(full, isTrue);
          attempts++;
          progress(7, .4, 'Verifying signed runtime packages in the existing sandbox prefix');
          if (attempts == 1) await barrier.future;
        },
        verifyCore: () async => true,
        verifyRuntimes: () async => true,
      );
      StudioSetupCoordinator.overrideForTest = coordinator;
      await mount(tester, const SandboxSetupScreen(studioFirstOpen: true));
      expect(attempts, 0);
      await tester.ensureVisible(find.text('Install sandbox'));
      await tester.tap(find.text('Install sandbox'));
      await _brief(tester);
      expect(attempts, 1);
      expect(coordinator.status, StudioSetupStatus.running);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('Verifying signed runtime packages in the existing sandbox prefix'),
          200, scrollable: find.byType(Scrollable).first);
      expect(tester.takeException(), isNull);
      barrier.completeError(StateError(_failure));
      await _brief(tester);
      expect(coordinator.status, StudioSetupStatus.failed);
      expect(app.studioFirstOpenDone, isFalse);
      expect(find.textContaining(_failure), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('Retry install'), 240,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Retry install'));
      await _brief(tester);
      expect(attempts, 2);
      expect(coordinator.status, StudioSetupStatus.ready);
      expect(app.studioFirstOpenDone, isTrue);
      await tester.ensureVisible(find.text('Open Studio'));
      expect(find.text('Open Studio').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('memory filename sheet stays usable above keyboard with validation', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.runAsync(() async {
      await app.prepareMemory();
      await tester.pumpWidget(MaterialApp(theme: Aether.theme(), builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)), child: child!),
        home: const MemoryScreen()));
    });
    await _brief(tester);
    await tester.ensureVisible(find.text('Add file'));
    await tester.tap(find.text('Add file'));
    await _brief(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await _brief(tester);
    await tester.enterText(find.byKey(const Key('memory-filename')), '../bad.md');
    await tester.ensureVisible(find.text('Add'));
    expect(tester.getBottomRight(find.text('Add')).dy, lessThanOrEqualTo(380));
    await tester.tap(find.text('Add'));
    await _brief(tester);
    expect(find.textContaining('plain .md filename'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('memory-filename')), 'keyboard.md');
    await tester.ensureVisible(find.text('Add'));
    await tester.tap(find.text('Add'));
    await _brief(tester);
    expect(memory.list(null), contains('keyboard.md'));
    final editor = find.byKey(const Key('memory-content'));
    await tester.ensureVisible(editor);
    await tester.enterText(editor, 'Saved with the keyboard visible');
    expect(tester.getBottomRight(find.text('Save')).dy, lessThanOrEqualTo(380));
    await tester.tap(find.text('Save'));
    await _brief(tester);
    expect(memory.read(null, 'keyboard.md').content, 'Saved with the keyboard visible');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('large-text empty subagent catalog scrolls without overflow', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme: Aether.theme(), builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)), child: child!),
      home: Builder(builder: (context) => Scaffold(body: TextButton(
        onPressed: () => showSubagentCatalog(context, 'no-children'),
        child: const Text('Catalog'),
      )))));
    await tester.tap(find.text('Catalog'));
    await _brief(tester);
    expect(find.text('No subagents yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('partial setup keeps existing core and exposes runtime retry at large text', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var ready = false;
    final coordinator = StudioSetupCoordinator(
      checkExisting: () async => true,
      install: (_, _) async => fail('Existing core must be retained'),
      installRuntimes: (_) async => false,
      verifyCore: () async => true,
      verifyRuntimes: () async => ready,
    );
    StudioSetupCoordinator.overrideForTest = coordinator;
    await coordinator.start();
    await tester.pumpWidget(MaterialApp(theme: Aether.theme(), builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)), child: child!),
      home: const SandboxSetupScreen()));
    await _brief(tester);
    expect(find.text('Sandbox core ready'), findsOneWidget);
    expect(find.text('RUNTIMES INCOMPLETE'), findsOneWidget);
    expect(app.studioFirstOpenDone, isFalse);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Retry runtime setup'));
    ready = true;
    await tester.tap(find.text('Retry runtime setup'));
    await _brief(tester);
    expect(coordinator.status, StudioSetupStatus.ready);
    expect(find.text('RUNTIMES VERIFIED'), findsOneWidget);
    expect(app.studioFirstOpenDone, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('empty ledger finishes loading and malformed projection offers retry', (tester) async {
    const id = 'finish-14-empty-error';
    ledgerIds.add(id);
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(theme: Aether.theme(), home: const TrajectoryScreen(sessionId: id)));
      await _ledgerReady(tester, id);
    });
    expect(find.byKey(const ValueKey('trajectory-empty')), findsOneWidget);
    await tester.runAsync(() async {
      await SessionLedger.I.append(id, 'tool_end', {'ms': 'invalid legacy duration'});
      await tester.tap(find.byTooltip('Reload ledger'));
      await tester.pump();
      await _ledgerReady(tester, id);
    });
    expect(find.text('Could not load ledger'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.runAsync(() async {
      await SessionLedger.I.close(id);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await _ledgerReady(tester, id);
    });
    expect(find.byKey(const ValueKey('trajectory-empty')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('subagent refusal retains keyboard draft and stale session is readable', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final session = ChatSession(id: 'finish-14-refusal', title: _agentLabel, model: 'm',
        mode: 'auto', agentContinuable: true);
    app.sessions.add(session); // No parent: the real service must refuse this stale route.
    ledgerIds.add(session.id);
    await tester.pumpWidget(MaterialApp(theme: Aether.theme(), builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)), child: child!),
      home: SubagentScreen(sessionId: session.id)));
    await tester.enterText(find.byType(TextField), 'Keep this draft\nwith several\nlines of follow-up\nwork');
    await tester.tap(find.byTooltip('Send'));
    await _brief(tester);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, startsWith('Keep this draft'));
    expect(find.text('not a subagent session'), findsOneWidget);
    expect(tester.takeException(), isNull);
    app.sessions.remove(session);
    app.refresh();
    await _brief(tester);
    expect(find.text('This subagent session is gone.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _brief(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

// Run only inside tester.runAsync: file IO and Isolate.run cannot complete by
// advancing fake time. Yield the real event queue until readiness, with a bound.
Future<void> _ledgerReady(WidgetTester tester, String sessionId) async {
  // Generous bound: under the full suite several isolates and real file IO run
  // concurrently, so loading can take far longer than an idle 5s. The wait is
  // still condition-based (loading must complete); the bound only guards hangs.
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  // Two queue barriers cover the screen's read followed by projection's read.
  // Await real IO instead of continuously scheduling frames against isolates.
  for (var i = 0; i < 2; i++) {
    await SessionLedger.I.read(sessionId).timeout(deadline.difference(DateTime.now()));
  }
  await tester.pump();
  while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(Duration.zero);
    await tester.pump();
  }
  expect(find.byType(CircularProgressIndicator), findsNothing,
      reason: 'Ledger must leave loading once real IO completes');
}

Future<void> _captureScreen(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_captureKey));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('/tmp/opencode/ui-finish-14.png').writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
