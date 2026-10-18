// Schedule picker helpers + edit-sheet coverage (P8 Task 14). The helpers are
// unchanged; the sheet now PATCHes a P4 trigger instead of mutating a local
// task map.
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

  Future<void> openEdit(
    WidgetTester tester,
    Map<String, dynamic> schedule,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    fake.schedules.add(schedule);
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
    await openEdit(tester, scheduleJson(
      title: 'One-off task',
      trigger: {'kind': 'at', 'at': stored},
    ));
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
    await openEdit(tester, scheduleJson(
      title: 'Interval task',
      trigger: {'kind': 'every', 'seconds': 3600},
    ));
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
    expect(fake.patchCalls, 0);

    await tester.enterText(value, '5');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await _settle(tester);
    expect(fake.lastPatchBody!['trigger'], {
      'kind': 'every',
      'seconds': 300,
    });
    expect(find.text('Edit schedule'), findsNothing);
    expect(find.textContaining('Every 5 min'), findsOneWidget);
  });
}
