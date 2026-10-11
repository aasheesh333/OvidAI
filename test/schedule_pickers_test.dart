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
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
  });

  Future<void> openEdit(WidgetTester tester, Map<String, dynamic> task) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    app.sessionById('s')!.schedules.add(task);
    await tester.pumpWidget(
      const MaterialApp(home: ScheduleScreen(sessionId: 's')),
    );
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.more_horiz));
    await _settle(tester);
    await tester.tap(find.text('Edit'));
    await _settle(tester);
  }

  test('interval helpers pick the largest even unit', () {
    expect(splitScheduleInterval(900), ('15', ScheduleIntervalUnit.minutes));
    expect(splitScheduleInterval(7200), ('2', ScheduleIntervalUnit.hours));
    expect(splitScheduleInterval(86400), ('1', ScheduleIntervalUnit.days));
    expect(describeScheduleInterval(86400), '1 day');
    expect(describeScheduleInterval(300), '5 minutes');
  });

  test('stored UTC one-offs become local text without Z', () {
    const stored = '2026-12-01T09:30:00Z';
    final local = DateTime.parse(stored).toLocal();
    final text = scheduleLocalText(stored);
    expect(text, isNot(contains('Z')));
    expect(text, formatScheduleLocal(local));
    expect(DateTime.parse(text.replaceAll(' ', 'T')), local);
  });

  testWidgets('editing a one-off shows local time, not the stored UTC value', (
    tester,
  ) async {
    const stored = '2026-12-01T09:30:00Z';
    await openEdit(tester, {
      'id': 'a',
      'prompt': 'One-off task',
      'status': 'pending',
      'fireAt': stored,
    });
    final local = DateTime.parse(stored).toLocal();
    final l10n = tester.element(find.byType(ScheduleScreen));
    final loc = MaterialLocalizations.of(l10n);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('schedule-oneoff-time')),
        matching: find.text(loc.formatTimeOfDay(TimeOfDay.fromDateTime(local))),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('schedule-oneoff-date')),
        matching: find.text(loc.formatMediumDate(local)),
      ),
      findsOneWidget,
    );
    expect(find.textContaining(stored), findsNothing);
    final preview = tester.widget<Text>(
      find.byKey(const ValueKey('schedule-preview')),
    );
    expect(preview.data, contains('device-local'));
    expect(preview.data, isNot(contains('Z')));

    // The raw value lives behind Advanced and is local too.
    expect(find.byKey(const ValueKey('schedule-time')), findsNothing);
    await tester.tap(find.text('Advanced'));
    await _settle(tester);
    expect(find.text(scheduleLocalText(stored)), findsOneWidget);
  });

  testWidgets('interval uses number + unit and rejects under 5 minutes', (
    tester,
  ) async {
    await openEdit(tester, {
      'id': 'b',
      'prompt': 'Interval task',
      'status': 'pending',
      'every': 3600,
      'fireAt': '2031-04-07T01:00:00Z',
    });
    final value = find.byKey(const ValueKey('schedule-interval-value'));
    expect(tester.widget<TextField>(value).controller!.text, '1');
    expect(find.text('hours'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('schedule-interval-unit')));
    await _settle(tester);
    await tester.tap(find.text('minutes').last);
    await _settle(tester);
    await tester.enterText(value, '4');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await _settle(tester);
    expect(find.text('The shortest interval is 5 minutes.'), findsOneWidget);
    final task = app.sessionById('s')!.schedules.single;
    expect(task['every'], 3600);

    await tester.enterText(value, '5');
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text('Save'));
      await app.flushSessionPersistence();
    });
    await _settle(tester);
    expect(task['every'], 300);
    expect(find.text('Edit schedule'), findsNothing);
  });
}
