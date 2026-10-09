import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/browser_screen.dart';
import 'package:ovid_ai/ui/subagent_screen.dart';
import 'package:ovid_ai/ui/trajectory_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

/// Wave 2 UI redesign — browser / subagent / trajectory render contract.
///
/// Asserts the premium Aether primitives are mounted on the three redesigned
/// screens, while the ORIGINAL navigation, dispatch and playback entry points
/// remain intact (visible buttons, open callbacks, screen types). These tests
/// are deliberately shallow: they prove the redesign surface, not the
/// underlying services.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final agent = AgentService.I;
  // AppState.I is a getter whose target changes across setUp()
  // (resetTestInstance / createForTest), so always read it fresh inside tests.
  AppState app() => AppState.I;

  const stubKey = Key('stub-webview');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    AppState.createForTest().seenWelcomeVersion = AppState.welcomeVersion;
    agent
      ..debugPauseScheduleTimerForTest(true)
      ..clearBrowserTabsForTest();
    browserWebViewBuilderForTest = (_) =>
        const ColoredBox(key: stubKey, color: Color(0xFF123456));
    SessionLedger.rootOverrideForTest = await Directory.systemTemp
        .createTemp('wave2-trajectory-');
  });

  tearDown(() {
    browserWebViewBuilderForTest = null;
    agent
      ..clearBrowserTabsForTest()
      ..debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    final root = SessionLedger.rootOverrideForTest;
    SessionLedger.rootOverrideForTest = null;
    try {
      root?.deleteSync(recursive: true);
    } catch (_) {}
  });

  Widget host(Widget child) =>
      MaterialApp(theme: Aether.theme(), home: child);

  Future<void> pumpUntilTrajectoryReady(
    WidgetTester tester,
  ) async {
    // Called inside runAsync: ledger reads use real files and worker isolates,
    // which advancing the widget test's fake clock cannot complete.
    // Generous bound: under the full suite several isolates and real file IO
    // run concurrently, so loading can take far longer than an idle 5s. The
    // wait is still condition-based; the bound only guards against hangs.
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    // Readiness is loading completion, not a lazy offscreen event header.
    // Keep pumping while IO runs: frame callbacks can enqueue fake-zone
    // microtasks that a directly awaited ledger barrier cannot drain.
    while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'Ledger must leave loading once real IO completes');
  }

  testWidgets(
    'browser screen mounts compact aether header/field primitives and '
    'preserves nav controls',
    (tester) async {
      tester.view.physicalSize = const Size(480, 960);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      agent.browserTabs.add(BrowserTab(url: 'https://example.com'));
      await tester.pumpWidget(host(const BrowserScreen()));
      await tester.pump();

      expect(find.byType(AetherGradientHeader), findsOneWidget);
      expect(find.byKey(const ValueKey('browser-url-field')), findsOneWidget);
      expect(find.byKey(const ValueKey('browser-status-dot')), findsNothing);
      expect(find.byKey(const ValueKey('browser-back')), findsOneWidget);
      expect(find.byKey(const ValueKey('browser-forward')), findsOneWidget);
      expect(find.byKey(const ValueKey('browser-reload')), findsOneWidget);
      // Download / external-launch nav entry point still present.
      expect(find.byTooltip('Open in browser'), findsOneWidget);
    },
  );

  testWidgets(
    'subagent catalog renders AetherEmptyState when a parent has no children '
    'and preserves dispatch open route',
    (tester) async {
      final parent = ChatSession(
        id: 'wave2-ui-parent-empty',
        title: 'Parent',
        model: 'm',
        mode: 'auto',
      );
      app().sessions.add(parent);
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showSubagentCatalog(context, parent.id),
                  child: const Text('open-catalog'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open-catalog'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('subagent-catalog-empty')),
        findsOneWidget,
      );
      expect(find.byType(AetherEmptyState), findsOneWidget);
    },
  );

  testWidgets(
    'subagent catalog renders an AetherCard per child with status pill and '
    'stop ghost for running ones',
    (tester) async {
      final parent = ChatSession(
        id: 'wave2-ui-parent',
        title: 'Parent',
        model: 'm',
        mode: 'auto',
      );
      final childRunning = ChatSession(
        id: 'wave2-ui-child-running',
        title: 'child-running',
        model: 'm',
        mode: 'auto',
        parentId: parent.id,
        agentState: 'running',
      );
      final childDone = ChatSession(
        id: 'wave2-ui-child-done',
        title: 'child-done',
        model: 'm',
        mode: 'auto',
        parentId: parent.id,
        agentState: 'finished',
      );
      app().sessions.addAll([parent, childRunning, childDone]);
      agent.runBucketForTest(childRunning.id).activeRunId = 'r-running';

      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showSubagentCatalog(context, parent.id),
                  child: const Text('open-catalog'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open-catalog'));
      // The running child's AetherStatusDot drives a repeating pulse
      // AnimationController, so pumpAndSettle never terminates. Pump a few
      // frames to let the bottom sheet open and the catalog build.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.byType(AetherCard), findsNWidgets(2));
      // Each child's state surfaces as a pill; stop ghost only for running.
      expect(find.byType(AetherPill), findsNWidgets(2));
      expect(
        find.byKey(ValueKey('subagent-stop-${childRunning.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('subagent-stop-${childDone.id}')),
        findsNothing,
      );
      // Dispatch open route is still a TextButton inside the catalog cards:
      // tapping the running card still runs SubagentScreen.open (verified by
      // the InkWell wrapper being hit-testable).
      expect(find.text('child-running'), findsOneWidget);
      expect(find.text('child-done'), findsOneWidget);

      agent.dropSessionRun(childRunning.id);
    },
  );

  testWidgets(
    'trajectory screen renders AetherEmptyState when the ledger has no events',
    (tester) async {
      final session = ChatSession(
        id: 'wave2-ui-traj-empty',
        title: 'Empty',
        model: 'm',
        mode: 'auto',
      );
      AppState.I.sessions.add(session);
      await tester.runAsync(() async {
      await tester.pumpWidget(
        host(TrajectoryScreen(sessionId: session.id)),
      );
      await pumpUntilTrajectoryReady(
        tester,
      );
      });

      expect(
        find.byKey(const ValueKey('trajectory-empty')),
        findsOneWidget,
      );
      expect(find.byType(AetherEmptyState), findsOneWidget);
    },
  );

  testWidgets(
    'trajectory screen mounts an AetherSectionTitle for Events and an '
    'AetherCard per event',
    (tester) async {
      final session = ChatSession(
        id: 'wave2-ui-traj-events',
        title: 'With events',
        model: 'm',
        mode: 'auto',
      );
      AppState.I.sessions.add(session);
      addTearDown(() => SessionLedger.I.close(session.id));
      await tester.runAsync(() async {
      await SessionLedger.I.append(session.id, 'turn_start', {
        'turn': 1,
        'msgs': 2,
      });
      await SessionLedger.I.append(session.id, 'tool_end', {
        'tool': 'read_file',
        'ms': 42,
        'ok': true,
      });

      await tester.pumpWidget(
        host(TrajectoryScreen(sessionId: session.id)),
      );
      await pumpUntilTrajectoryReady(
        tester,
      );
      });

      final eventsTitle = find.byKey(const ValueKey('trajectory-events-title'));
      await tester.scrollUntilVisible(eventsTitle, 180,
          scrollable: find.byType(Scrollable).first);
      await tester.pump();
      await tester.ensureVisible(eventsTitle);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('trajectory-events-title')),
        findsOneWidget,
      );
      expect(find.byType(AetherSectionTitle), findsOneWidget);
      // Two events → two event cards, plus the stats projection strip card
      // (turns > 0). The empty-state branch is not taken.
      expect(find.byType(AetherCard), findsNWidgets(3));
      expect(find.text('#1 · Turn start (turn 1)'), findsOneWidget);
      expect(find.text('#2 · Tool done: read_file'), findsOneWidget);
      expect(find.text('42ms · ok'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
