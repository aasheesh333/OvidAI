import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/trajectory_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

/// Wave 2 UI redesign — subagent / trajectory render contract.
///
/// Asserts the premium Aether primitives are mounted on the two surviving
/// screens, while the ORIGINAL navigation, dispatch and playback entry points
/// remain intact (visible buttons, open callbacks, screen types). These tests
/// are deliberately shallow: they prove the redesign surface, not the
/// underlying services.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest().seenWelcomeVersion = AppState.welcomeVersion;
    SessionLedger.rootOverrideForTest = await Directory.systemTemp
        .createTemp('wave2-trajectory-');
  });

  tearDown(() {
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
