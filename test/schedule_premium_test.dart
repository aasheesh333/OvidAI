// Schedule picker/draft coverage, migrated to the server-backed screen
// (P8 Task 14). The local task map is gone; the sheet edits a ScheduleDto and
// PATCHes the trigger.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/schedule_client.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/schedule_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/schedule_fake.dart';

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

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ScheduleScreen(sessionId: 's')),
    );
    await _settle(tester);
  }

  testWidgets('switching recurrence preserves each draft value', (tester) async {
    fake.schedules.add(scheduleJson(
      title: 'Keep the draft',
      trigger: {'kind': 'at', 'at': '2026-12-01T09:30:00.000Z'},
    ));
    await pumpScreen(tester);
    await tester.tap(find.byIcon(Icons.more_horiz));
    await _settle(tester);
    await tester.tap(find.text('Edit'));
    await _settle(tester);

    await tester.tap(find.text('Interval'));
    await tester.tap(find.text('Advanced'));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('schedule-time')), '900');
    await tester.tap(find.text('One-off'));
    await tester.pump();
    // One-offs are edited in device-local time, never as the stored UTC "Z".
    expect(
      find.text(scheduleLocalText('2026-12-01T09:30:00Z')),
      findsOneWidget,
    );
    await tester.tap(find.text('Daily'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('schedule-time')),
      '09:30',
    );
    await tester.tap(find.text('Interval'));
    expect(find.text('900'), findsOneWidget);
    await tester.tap(find.text('Daily'));
    expect(find.text('09:30'), findsOneWidget);
  });

  testWidgets('cancel mutates the server task and retains it in history',
      (tester) async {
    fake.schedules.add(scheduleJson(title: 'Do not cancel accidentally'));
    await pumpScreen(tester);
    await tester.tap(find.byIcon(Icons.more_horiz));
    await _settle(tester);
    await tester.tap(find.text('Cancel task'));
    await _settle(tester);
    expect(find.text('Cancel this task?'), findsOneWidget);
    await tester.tap(find.text('Cancel task').last);
    await _settle(tester);
    expect(fake.byId('sc1')!['status'], 'cancelled');
    expect(find.text('cancelled'), findsOneWidget);
    expect(find.text('Do not cancel accidentally'), findsOneWidget);
  });

  testWidgets('recovery feedback is shown on the affected card',
      (tester) async {
    fake.schedules.add(scheduleJson(
      title: 'Recover this task',
      status: 'failed',
      lastResult: lastResultJson(
        status: 'failed',
        message: 'Provider/model setup required',
      ),
    ));
    await pumpScreen(tester);
    expect(find.text('Recovery needed'), findsOneWidget);
    expect(find.textContaining('Provider/model setup required'), findsWidgets);
  });
}
