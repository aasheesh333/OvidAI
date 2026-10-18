// Aether redesign — Schedule screen widget tests (P8 Task 14).
//
// The screen is server-backed: rows come from ScheduleClient (P4 REST).
// These tests use a fake gateway that mirrors the built routes, so they
// exercise the real DTO parsing + bindings.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/schedule_client.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/schedule_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/schedule_fake.dart';

// The AetherStatusDot in the status strip has a looping pulse animation, so
// pumpAndSettle would spin forever. Advance by a bounded duration instead.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
}

Future<FakeScheduleGateway> _pump(
  WidgetTester tester,
  List<Map<String, dynamic>> schedules,
) async {
  final fake = FakeScheduleGateway(schedules);
  ScheduleClient.installForTest(fake.client);
  await tester.pumpWidget(
    const MaterialApp(home: ScheduleScreen(sessionId: 's')),
  );
  await _settle(tester);
  return fake;
}

void main() {
  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ScheduleClient.timeZoneOverrideForTest = 'UTC';
    app = AppState.createForTest();
    app.sessions.add(ChatSession(id: 's', title: 'My work', model: 'm'));
    app.activeSessionId = 's';
  });

  tearDown(() {
    ScheduleClient.timeZoneOverrideForTest = null;
    AppState.resetTestInstance();
  });

  testWidgets('renders the Aether empty state when no tasks exist',
      (tester) async {
    await _pump(tester, []);
    expect(find.text('No scheduled tasks'), findsOneWidget);
    expect(find.textContaining('Ask the agent'), findsOneWidget);
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    expect(find.text('Cloud scheduling active'), findsOneWidget);
  });

  testWidgets('renders rows from the cloud client with status and countdown',
      (tester) async {
    await _pump(tester, [
      scheduleJson(
        title: 'Review PR queue',
        description: 'Open the queue and summarise',
        trigger: {'kind': 'daily_at', 'time': '09:30', 'tz': 'UTC'},
      ),
    ]);

    expect(find.text('pending'), findsOneWidget);
    expect(find.text('Review PR queue'), findsOneWidget);
    expect(find.textContaining('Daily'), findsOneWidget);
    expect(find.textContaining('09:30'), findsOneWidget);
    expect(find.textContaining('Next in'), findsOneWidget);
  });

  testWidgets('results feed shows lastResult.message and the ran-late badge',
      (tester) async {
    await _pump(tester, [
      scheduleJson(
        lastResult: lastResultJson(
          message: 'Posted the digest',
          ranLate: true,
        ),
      ),
    ]);

    expect(find.text('ran late'), findsOneWidget);
    expect(find.textContaining('Posted the digest'), findsOneWidget);
    expect(find.textContaining('Last run: succeeded'), findsOneWidget);
  });

  testWidgets('a schedule paused by the missed-run policy shows missed run',
      (tester) async {
    await _pump(tester, [
      scheduleJson(
        status: 'paused',
        pausedReason: 'missed_beyond_grace',
      ),
    ]);

    expect(find.text('missed run'), findsOneWidget);
    expect(find.textContaining('Missed while Ovid was offline'), findsOneWidget);
  });

  testWidgets('pull-to-refresh reloads from the server', (tester) async {
    final fake = await _pump(tester, [
      scheduleJson(title: 'First task'),
    ]);
    expect(fake.listCalls, 1);
    expect(find.text('First task'), findsOneWidget);

    fake.schedules.add(scheduleJson(id: 'sc2', title: 'Second task'));
    await tester.fling(find.byType(ListView), const Offset(0, 320), 1200);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(fake.listCalls, greaterThan(1));
    expect(find.text('Second task'), findsOneWidget);
  });

  testWidgets('edit sheet saves through PATCH /schedules/:id', (tester) async {
    final fake = await _pump(tester, [
      scheduleJson(title: 'Original', description: 'Original task'),
    ]);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await _settle(tester);
    await tester.tap(find.text('Edit'));
    await _settle(tester);

    expect(find.text('Edit schedule'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('schedule-title')), 'Rewritten');
    await tester.enterText(
      find.byKey(const ValueKey('schedule-prompt')),
      'Rewritten task',
    );
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

    expect(fake.patchCalls, 1);
    expect(fake.lastPatchBody!['title'], 'Rewritten');
    expect(fake.lastPatchBody!['description'], 'Rewritten task');
    expect(fake.lastPatchBody!['trigger'], {
      'kind': 'at',
      'at': '2031-12-01T12:00:00.000Z',
    });
    expect(find.text('Rewritten'), findsOneWidget);
  });

  testWidgets('pause and resume PATCH the status', (tester) async {
    final fake = await _pump(tester, [scheduleJson()]);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await _settle(tester);
    await tester.tap(find.text('Pause'));
    await _settle(tester);
    expect(fake.lastPatchBody, {'status': 'paused'});
    expect(fake.byId('sc1')!['status'], 'paused');
    expect(find.text('paused'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await _settle(tester);
    await tester.tap(find.text('Resume'));
    await _settle(tester);
    expect(fake.lastPatchBody, {'status': 'pending'});
    expect(fake.byId('sc1')!['status'], 'pending');
  });

  testWidgets('cancel confirms and DELETEs; cancelled history remains',
      (tester) async {
    final fake = await _pump(tester, [
      scheduleJson(title: 'A task'),
    ]);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await _settle(tester);
    await tester.tap(find.text('Cancel task'));
    await _settle(tester);
    expect(find.text('Cancel this task?'), findsOneWidget);
    await tester.tap(find.text('Cancel task').last);
    await _settle(tester);

    expect(fake.deleteCalls, 1);
    expect(fake.byId('sc1')!['status'], 'cancelled');
    expect(find.text('cancelled'), findsOneWidget);
    expect(find.text('A task'), findsOneWidget);
  });

  testWidgets('expanded details show the server fields', (tester) async {
    await _pump(tester, [
      scheduleJson(
        title: 'Long task',
        description: 'A much longer description that must survive expansion.',
        trigger: {'kind': 'every', 'seconds': 3600},
        maxRetries: 2,
        lastResult: lastResultJson(message: 'All clear'),
      ),
    ]);

    await tester.tap(find.text('Show details'));
    await _settle(tester);

    for (final label in [
      'Description',
      'Scheduled',
      'Time zone',
      'Recurrence',
      'Next run',
      'Last run',
      'Retries',
      'Raw spec',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(
      find.text('A much longer description that must survive expansion.'),
      findsOneWidget,
    );
    expect(find.textContaining('every=3600s'), findsOneWidget);
    expect(find.textContaining('Up to 2'), findsOneWidget);
    expect(find.text('All clear'), findsOneWidget);
  });

  testWidgets('a failed load offers Retry', (tester) async {
    final fake = FakeScheduleGateway(<Map<String, dynamic>>[]);
    fake.failListStatus = 500;
    ScheduleClient.installForTest(fake.client);
    await tester.pumpWidget(
      const MaterialApp(home: ScheduleScreen(sessionId: 's')),
    );
    await _settle(tester);

    expect(find.text('Could not load schedules'), findsOneWidget);
    fake.failListStatus = null;
    fake.schedules.add(scheduleJson(title: 'Recovered'));
    await tester.tap(find.text('Retry'));
    await _settle(tester);
    expect(find.text('Recovered'), findsOneWidget);
  });
}
