// Legacy schedule UI coverage, migrated to the server-backed screen (P8
// Task 14). Kept: sidebar ordering/navigation, every real server status,
// cancel history, and edit persistence — now asserted against the P4 REST
// client rather than the deleted local task map.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/schedule_client.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/schedule_screen.dart';
import 'package:ovid_ai/ui/sidebar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/schedule_fake.dart';

// The redesigned screen has a pulsing status dot; pumpAndSettle would spin
// forever on it. Advance by a bounded duration instead.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  late AppState app;
  late FakeScheduleGateway fake;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ScheduleClient.timeZoneOverrideForTest = 'UTC';
    app = AppState.createForTest();
    app.sessions.add(ChatSession(id: 's', title: 'My work', model: 'm'));
    app.activeSessionId = 's';
    fake = FakeScheduleGateway([]);
    ScheduleClient.installForTest(fake.client);
  });

  tearDown(() {
    ScheduleClient.timeZoneOverrideForTest = null;
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
    await _settle(tester);
    await _settle(tester);
    expect(find.text('Schedules'), findsOneWidget);
    expect(find.textContaining('Ask the agent'), findsOneWidget);
  });

  testWidgets('renders every server status and the task actions menu',
      (tester) async {
    for (final status in [
      'pending',
      'paused',
      'completed',
      'failed',
      'cancelled',
    ]) {
      fake.schedules.add(scheduleJson(
        id: status,
        title: '$status task',
        status: status,
      ));
    }
    await tester.pumpWidget(
      const MaterialApp(home: ScheduleScreen(sessionId: 's')),
    );
    await _settle(tester);

    // The first few cards fit the viewport.
    // FE-018: statuses read as words, never the raw enum.
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Paused'), findsOneWidget);
    expect(find.text('pending'), findsNothing);
    expect(find.textContaining('2026'), findsWidgets);
    for (final status in ['completed', 'failed', 'cancelled']) {
      await tester.scrollUntilVisible(find.text('$status task'), 200);
      expect(find.text(scheduleStatusLabel(status)), findsOneWidget);
    }
    expect(find.byTooltip('Task actions'), findsWidgets);
  });

  testWidgets('cancel retains visible cancelled history', (tester) async {
    fake.schedules.add(scheduleJson(title: 'My task'));
    await tester.pumpWidget(
      const MaterialApp(home: ScheduleScreen(sessionId: 's')),
    );
    await _settle(tester);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await _settle(tester);
    await tester.tap(find.text('Cancel task'));
    await _settle(tester);
    await tester.tap(find.text('Cancel task').last);
    await _settle(tester);

    expect(fake.byId('sc1')!['status'], 'cancelled');
    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.text('My task'), findsOneWidget);
  });

  testWidgets('editing persists the new title and time', (tester) async {
    fake.schedules.add(scheduleJson(title: 'My task', description: 'Do it'));
    await tester.pumpWidget(
      const MaterialApp(home: ScheduleScreen(sessionId: 's')),
    );
    await _settle(tester);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await _settle(tester);
    await tester.tap(find.text('Edit'));
    await _settle(tester);
    expect(find.text('Edit schedule'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('schedule-title')), 'Updated');
    await tester.tap(find.text('Advanced'));
    await _settle(tester);
    await tester.tap(find.text('One-off'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('schedule-time')),
      '2031-12-01T12:00:00Z',
    );
    await tester.ensureVisible(find.text('Save'));
    await _settle(tester);
    await tester.tap(find.text('Save'));
    await _settle(tester);

    expect(fake.lastPatchBody!['title'], 'Updated');
    expect(fake.lastPatchBody!['trigger'], {
      'kind': 'at',
      'at': '2031-12-01T12:00:00.000Z',
    });
    expect(find.text('Updated'), findsOneWidget);
  });
}
