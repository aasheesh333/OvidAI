// Legacy schedule UI coverage, updated for the Aether redesign.
//
// The pre-redesign screen exposed inline tooltipped "Edit schedule" /
// "Cancel schedule" icon buttons and a bare 2026-10-04 timestamp. Those
// affordances are now a single popup-menu per task card, and the timestamp
// is rendered as a readable local "Oct 4, 2026 at 9:30 AM" string. These
// tests have been migrated to the new widgets without deleting coverage:
// sidebar ordering, rendering of every real status, cancel flow preserving
// cancelled history, and the edit sheet persisting prompt + fireAt.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/sidebar.dart';
import 'package:ovid_ai/ui/schedule_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The redesigned screen has a pulsing status dot; pumpAndSettle would spin
// forever on it. Advance by a bounded duration instead.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  late AppState app;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app = AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    AgentService.I.schedules.stopped = false;
    AgentNotificationService.I.backgroundStopped = false;
    AgentNotificationService.I.backgroundConstraint = null;
    app.sessions.add(ChatSession(id: 's', title: 'My work', model: 'm'));
    app.activeSessionId = 's';
  });
  tearDown(() {
    AgentNotificationService.I.backgroundStopped = false;
    AgentNotificationService.I.backgroundConstraint = null;
    AgentService.I.schedules.stopped = false;
    AppState.resetTestInstance();
  });

  testWidgets('Schedule is above Trajectory and opens active session tasks',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(.7)),
        child: const SessionsSidebar(),
      ),
    )));
    expect(
      tester.getTopLeft(find.text('Schedule')).dy,
      lessThan(
        tester.getTopLeft(find.text('Trajectory — event ledger')).dy,
      ),
    );
    await tester.tap(find.text('Schedule'));
    // Route transition + initial frame; pumpAndSettle would spin on the
    // pulsing status dot of the destination screen.
    await _settle(tester);
    await _settle(tester);
    expect(find.text('Schedule \u00B7 My work'), findsOneWidget);
    expect(find.textContaining('Ask the agent'), findsOneWidget);
  });

  testWidgets('renders real statuses, readable date and task actions menu',
      (tester) async {
    final s = app.sessionById('s')!;
    for (final status in [
      'pending',
      'running',
      'completed',
      'failed',
      'paused',
    ]) {
      s.schedules.add({
        'id': status,
        'prompt': '$status task',
        'status': status,
        'fireAt': '2026-10-04T09:30:00Z',
      });
    }
    await tester.pumpWidget(
      const MaterialApp(home: ScheduleScreen(sessionId: 's')),
    );
    await _settle(tester);
    // The first few cards fit the viewport.
    expect(find.text('pending'), findsOneWidget);
    expect(find.text('running'), findsOneWidget);
    // Readable local timestamp (year 2026 is stable across time zones for
    // 2026-10-04T09:30 UTC).
    expect(find.textContaining('2026'), findsWidgets);
    // Scroll the lazy ListView to confirm every status pill is rendered.
    for (final status in ['completed', 'failed', 'paused']) {
      await tester.scrollUntilVisible(find.text('$status task'), 200);
      expect(find.text(status), findsOneWidget);
    }
    // Per-task actions menu replaces the old tooltipped icon buttons.
    expect(find.byTooltip('Task actions'), findsWidgets);
  });

  testWidgets('cancel retains visible cancelled history', (tester) async {
    final s = app.sessionById('s')!;
    s.schedules.add({
      'id': 'a',
      'prompt': 'My task',
      'status': 'pending',
      'fireAt': '2026-10-04T09:30:00Z',
    });
    await tester.pumpWidget(
      const MaterialApp(home: ScheduleScreen(sessionId: 's')),
    );
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.more_horiz));
    await _settle(tester);
    await tester.tap(find.text('Cancel'));
    await _settle(tester);
    expect(s.schedules.single['status'], 'cancelled');
    expect(find.text('cancelled'), findsOneWidget);
    expect(find.text('My task'), findsOneWidget);
  });

  testWidgets('editing persists new prompt and time', (tester) async {
    final s = app.sessionById('s')!;
    s.schedules.add({
      'id': 'a',
      'prompt': 'My task',
      'status': 'pending',
      'fireAt': '2026-10-04T09:30:00Z',
    });
    await tester.pumpWidget(
      const MaterialApp(home: ScheduleScreen(sessionId: 's')),
    );
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.more_horiz));
    await _settle(tester);
    await tester.tap(find.text('Edit'));
    await _settle(tester);
    expect(find.text('Edit schedule'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), 'Updated task');
    await tester.enterText(
      find.byType(TextField).at(1),
      '2026-12-01T12:00:00Z',
    );
    await tester.tap(find.text('Save'));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(s.schedules.single['prompt'], 'Updated task');
    expect(s.schedules.single['fireAt'], '2026-12-01T12:00:00.000Z');
    expect(find.text('Updated task'), findsOneWidget);
  });
}
