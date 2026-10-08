import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/schedule_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    AgentService.I.schedules.stopped = false;
    AgentNotificationService.I.backgroundStopped = false;
    AppState.resetTestInstance();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ScheduleScreen(sessionId: 's')),
    );
    await _settle(tester);
  }

  testWidgets('switching recurrence preserves each draft value', (tester) async {
    app.sessionById('s')!.schedules.add({
      'id': 'a',
      'prompt': 'Keep the draft',
      'status': 'pending',
      'dailyAt': '09:30',
      'localDate': '2026-12-01',
      'fireAt': '2026-12-01T09:30:00Z',
    });
    await pumpScreen(tester);
    await tester.tap(find.byIcon(Icons.more_horiz));
    await _settle(tester);
    await tester.tap(find.text('Edit'));
    await _settle(tester);

    await tester.tap(find.text('Interval'));
    await tester.enterText(find.byKey(const ValueKey('schedule-time')), '900');
    await tester.tap(find.text('One-off'));
    expect(find.text('2026-12-01T09:30:00Z'), findsOneWidget);
    await tester.tap(find.text('Daily'));
    expect(find.text('09:30'), findsOneWidget);
    await tester.tap(find.text('Interval'));
    expect(find.text('900'), findsOneWidget);
  });

  testWidgets('cancel mutates the task and retains it in history', (tester) async {
    final task = {
      'id': 'a',
      'prompt': 'Do not cancel accidentally',
      'status': 'pending',
      'fireAt': '2026-12-01T12:00:00Z',
    };
    app.sessionById('s')!.schedules.add(task);
    await pumpScreen(tester);
    await tester.tap(find.byIcon(Icons.more_horiz));
    await _settle(tester);
    await tester.tap(find.text('Cancel'));
    await _settle(tester);
    expect(task['status'], 'cancelled');
    expect(find.text('cancelled'), findsOneWidget);
    expect(find.text('Do not cancel accidentally'), findsOneWidget);
  });

  testWidgets('recovery feedback is shown on the affected card', (tester) async {
    app.sessionById('s')!.schedules.add({
      'id': 'a',
      'prompt': 'Recover this task',
      'status': 'failed',
      'error': 'Provider/model setup required',
      'fireAt': '2026-12-01T12:00:00Z',
    });
    await pumpScreen(tester);
    expect(find.text('Recovery needed'), findsOneWidget);
    expect(find.textContaining('Provider/model setup required'), findsOneWidget);
  });
}
