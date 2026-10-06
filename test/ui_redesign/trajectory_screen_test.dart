import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/trajectory_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

/// Wave 2 UI redesign — trajectory (event-ledger) screen smoke contract.
///
/// Pins the Aether surface the redesign owes callers while ALL ledger
/// playback stays intact (`SessionLedger.read`/`projection` and the
/// app-bar reload action):
///   * [AetherSectionTitle] eyebrow 'Events' above the ledger list.
///   * One [AetherCard] per event carrying a mono timestamp caption, the
///     `#seq · title` title, and the detail body.
///   * The stats projection strip rendered as an [AetherCard].
///   * [AetherEmptyState] when the ledger has no records.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory ledgerRoot;
  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    ledgerRoot = await Directory.systemTemp.createTemp('wave2-ui-trajectory-');
    SessionLedger.rootOverrideForTest = ledgerRoot;
  });

  tearDown(() async {
    for (final sid in SessionLedger.I.sinkOpensForTest.keys.toList()) {
      await SessionLedger.I.close(sid);
    }
    SessionLedger.rootOverrideForTest = null;
    AppState.resetTestInstance();
    try {
      ledgerRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  ChatSession addSession(String id, String title) {
    final session = ChatSession(
      id: id,
      title: title,
      model: 'm',
      mode: 'auto',
    );
    app.sessions.add(session);
    return session;
  }

  Widget host(Widget child) =>
      MaterialApp(theme: Aether.theme(), home: child);

  Future<void> pumpUntilTrajectoryReady(WidgetTester tester) async {
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

  testWidgets('empty ledger renders AetherEmptyState and no event cards', (
    tester,
  ) async {
    final session = addSession('wave2-ui-traj-smoke-empty', 'Empty');
    await tester.runAsync(() async {
      await tester.pumpWidget(host(TrajectoryScreen(sessionId: session.id)));
      await pumpUntilTrajectoryReady(tester);
    });

    expect(find.byKey(const ValueKey('trajectory-empty')), findsOneWidget);
    expect(find.byType(AetherEmptyState), findsOneWidget);
    expect(find.text('No ledger records yet'), findsOneWidget);
    expect(find.byType(AetherCard), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets(
    'events render as AetherCards with mono timestamp caption, title and '
    'body, under the Events section title',
    (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final session = addSession('wave2-ui-traj-smoke-events', 'With events');
      await tester.runAsync(() async {
        await SessionLedger.I.append(session.id, 'turn_start', {
          'turn': 1,
          'msgs': 3,
        });
        await SessionLedger.I.append(session.id, 'tool_start', {
          'tool': 'read_file',
        });
        await SessionLedger.I.append(session.id, 'tool_end', {
          'tool': 'read_file',
          'ms': 42,
          'ok': true,
        });
        await SessionLedger.I.append(session.id, 'turn_end', {
          'steps': 1,
          'turns': 1,
          'toolMs': 42,
          'llmMs': 120,
        });

        await tester.pumpWidget(host(TrajectoryScreen(sessionId: session.id)));
        await pumpUntilTrajectoryReady(tester);
      });

      final eventsTitle = find.byKey(
        const ValueKey('trajectory-events-title'),
      );
      await tester.scrollUntilVisible(eventsTitle, 180,
          scrollable: find.byType(Scrollable).first);
      await tester.pump();
      await tester.ensureVisible(eventsTitle);
      await tester.pump();

      // App bar keeps the ledger playback route identity.
      expect(find.text('Trajectory · With events'), findsOneWidget);

      // Section title above the list.
      expect(
        find.byKey(const ValueKey('trajectory-events-title')),
        findsOneWidget,
      );
      expect(find.text('EVENTS'), findsOneWidget);

      // Stats projection strip renders as an AetherCard.
      expect(find.byKey(const ValueKey('trajectory-stats')), findsOneWidget);
      expect(find.text('Session stats (ledger projection)'), findsOneWidget);
      expect(find.textContaining('1 turns · 1 tool calls'), findsOneWidget);
      expect(find.textContaining('top: read_file×1'), findsOneWidget);

      // Four events → four event cards, plus the stats card.
      expect(find.byType(AetherCard), findsNWidgets(5));

      // Titles and detail bodies come straight from the ledger records.
      expect(find.text('#1 · Turn start (turn 1)'), findsOneWidget);
      expect(find.text('#2 · Tool: read_file'), findsOneWidget);
      expect(find.text('#3 · Tool done: read_file'), findsOneWidget);
      expect(find.text('42ms · ok'), findsOneWidget);
      expect(find.text('#4 · Turn end'), findsOneWidget);
      expect(
        find.text('steps 1 · turns 1 · tool 42ms · llm 120ms'),
        findsOneWidget,
      );

      // Every event card leads with a mono timestamp caption.
      final monoTimestamps = find.byWidgetPredicate(
        (w) => w is Text && w.style?.fontFamily == 'JetBrainsMono',
      );
      expect(monoTimestamps, findsNWidgets(4));
    },
  );

  testWidgets('reload action re-reads the ledger (playback preserved)', (
    tester,
  ) async {
    final session = addSession('wave2-ui-traj-smoke-reload', 'Reload');
    await tester.runAsync(() async {
      await SessionLedger.I.append(session.id, 'note', {});

      await tester.pumpWidget(host(TrajectoryScreen(sessionId: session.id)));
      await pumpUntilTrajectoryReady(tester);
    });
    expect(find.text('#1 · Note'), findsOneWidget);
    expect(find.byType(AetherCard), findsNWidgets(1));

    // A new record lands in the ledger; the app-bar reload must re-read it.
    await tester.runAsync(() async {
      await SessionLedger.I.append(session.id, 'note', {});
      await tester.tap(find.byTooltip('Reload ledger'));
      await tester.pump();
      await pumpUntilTrajectoryReady(tester);
    });

    expect(find.text('#2 · Note'), findsOneWidget);
    expect(find.byType(AetherCard), findsNWidgets(2));
  });
}
