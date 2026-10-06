// Aether redesign — Schedule screen widget tests.
//
// Covers the new premium layout: empty state, task card with status pill,
// pretty recurrence string, next-run countdown, overdue state, popup-menu
// actions (edit sheet, pause, resume, cancel) and background execution
// toggle. Uses the existing test seams (AppState.createForTest,
// AgentService.debugPauseScheduleTimerForTest) and the real singletons —
// these are the same seams the legacy schedule_ui_test.dart uses.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/schedule_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpScreen(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(home: ScheduleScreen(sessionId: 's')),
  );
  await tester.pump();
}

// The AetherStatusDot inside the status strip has a looping pulse animation,
// so pumpAndSettle would spin forever. Advance by a bounded duration instead.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  late AppState app;

  setUp(() async {
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

  testWidgets('renders Aether empty state when no tasks exist',
      (tester) async {
    await _pumpScreen(tester);
    expect(find.text('No scheduled tasks'), findsOneWidget);
    expect(find.textContaining('Ask the agent'), findsOneWidget);
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    expect(find.text('Background execution active'), findsOneWidget);
  });

  testWidgets('renders status pill, pretty recurrence and next-run countdown',
      (tester) async {
    final s = app.sessionById('s')!;
    final future = DateTime.now().toUtc().add(const Duration(hours: 2));
    s.schedules.add({
      'id': 'a',
      'prompt': 'Review PR queue',
      'status': 'pending',
      'fireAt': future.toIso8601String(),
      'dailyAt': '09:30',
      'maxRetries': 1,
      'attempt': 0,
    });
    await _pumpScreen(tester);

    expect(find.text('pending'), findsOneWidget);
    expect(find.text('Review PR queue'), findsOneWidget);
    expect(find.textContaining('Daily'), findsOneWidget);
    expect(find.textContaining('09:30'), findsOneWidget);
    // "Next in 2h" (minute remainder may be present; the hour marker is stable).
    expect(find.textContaining('Next in'), findsOneWidget);
  });

  testWidgets('renders overdue state when fireAt is in the past',
      (tester) async {
    final s = app.sessionById('s')!;
    final past = DateTime.now().toUtc().subtract(const Duration(minutes: 4));
    s.schedules.add({
      'id': 'b',
      'prompt': 'Overdue job',
      'status': 'pending',
      'fireAt': past.toIso8601String(),
    });
    await _pumpScreen(tester);
    expect(find.textContaining('Overdue by'), findsOneWidget);
  });

  testWidgets('edit sheet opens via menu and saves through editSchedule',
      (tester) async {
    final s = app.sessionById('s')!;
    s.schedules.add({
      'id': 'a',
      'prompt': 'Original',
      'status': 'pending',
      'fireAt': '2026-10-04T09:30:00Z',
    });
    await _pumpScreen(tester);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await _settle(tester);
    await tester.tap(find.text('Edit'));
    await _settle(tester);

    expect(find.text('Edit schedule'), findsOneWidget);
    // Task field is the first TextField in the sheet.
    await tester.enterText(find.byType(TextField).at(0), 'Rewritten task');
    await tester.enterText(
      find.byType(TextField).at(1),
      '2026-12-01T12:00:00Z',
    );
    await tester.tap(find.text('Save'));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    expect(s.schedules.single['prompt'], 'Rewritten task');
    expect(s.schedules.single['fireAt'], '2026-12-01T12:00:00.000Z');
    expect(find.text('Rewritten task'), findsOneWidget);
  });

  testWidgets('pause via menu calls cancelTask(pause: true)', (tester) async {
    final s = app.sessionById('s')!;
    s.schedules.add({
      'id': 'a',
      'prompt': 'A task',
      'status': 'pending',
      'fireAt': '2026-12-01T12:00:00Z',
    });
    await _pumpScreen(tester);
    await tester.tap(find.byIcon(Icons.more_horiz));
    await _settle(tester);
    await tester.tap(find.text('Pause'));
    await _settle(tester);
    expect(s.schedules.single['status'], 'paused');
    expect(s.schedules.single['error'], 'Paused by user');
    expect(find.text('paused'), findsOneWidget);
  });

  testWidgets('resume via menu calls resumeTask', (tester) async {
    final s = app.sessionById('s')!;
    s.schedules.add({
      'id': 'a',
      'prompt': 'A task',
      'status': 'paused',
      'error': 'Paused by user',
      'fireAt': '2026-12-01T12:00:00Z',
    });
    await _pumpScreen(tester);
    await tester.tap(find.byIcon(Icons.more_horiz));
    await _settle(tester);
    await tester.tap(find.text('Resume'));
    await _settle(tester);
    expect(s.schedules.single['status'], 'pending');
    expect(s.schedules.single.containsKey('error'), isFalse);
  });

  testWidgets('cancel via menu calls cancelTask', (tester) async {
    final s = app.sessionById('s')!;
    s.schedules.add({
      'id': 'a',
      'prompt': 'A task',
      'status': 'pending',
      'fireAt': '2026-12-01T12:00:00Z',
    });
    await _pumpScreen(tester);
    await tester.tap(find.byIcon(Icons.more_horiz));
    await _settle(tester);
    await tester.tap(find.text('Cancel'));
    await _settle(tester);
    expect(s.schedules.single['status'], 'cancelled');
    expect(find.text('cancelled'), findsOneWidget);
    expect(find.text('A task'), findsOneWidget);
  });

  testWidgets(
      'expanded details show full description, scheduled timestamp, recurrence, next-run, retries and raw spec',
      (tester) async {
    final s = app.sessionById('s')!;
    final future = DateTime.now().toUtc().add(const Duration(hours: 3));
    final longPrompt =
        'Review the staging deployment, inspect error budget, '
        'summarise release notes, then post to #ovid-release once green.';
    s.schedules.add({
      'id': 'a',
      'prompt': longPrompt,
      'status': 'pending',
      'fireAt': future.toIso8601String(),
      'dailyAt': '09:30',
      'maxRetries': 2,
      'attempt': 1,
      'lastStatus': 'ok',
      'lastRunAt':
          DateTime.now().toUtc().subtract(const Duration(hours: 20))
              .toIso8601String(),
    });
    await _pumpScreen(tester);

    // Collapsed card ellipsizes the title line but the full description is
    // only guaranteed once the user expands details.
    await tester.tap(find.text('Show details'));
    await _settle(tester);

    // Full description visible verbatim. The card's title line also renders
    // the (ellipsized) prompt, so both the title Text and the details Text
    // are present.
    expect(find.text(longPrompt), findsNWidgets(2));
    expect(find.text('Description'), findsOneWidget);

    // Readable local scheduled timestamp — the local year is stable enough.
    final year = future.toLocal().year.toString();
    expect(find.textContaining(year), findsWidgets);
    expect(find.text('Scheduled'), findsOneWidget);

    // Recurrence + next-run + retries + last-run + raw spec rows.
    expect(find.text('Recurrence'), findsOneWidget);
    expect(find.text('Next run'), findsOneWidget);
    expect(find.text('Last run'), findsOneWidget);
    expect(find.text('Retries'), findsOneWidget);
    expect(find.text('Raw spec'), findsOneWidget);
    expect(find.textContaining('1/2'), findsOneWidget);
    expect(find.textContaining('dailyAt=09:30'), findsOneWidget);
  });

  testWidgets(
      'expanded details show overdue label and local timestamp for past fireAt',
      (tester) async {
    final s = app.sessionById('s')!;
    final past = DateTime.now().toUtc().subtract(const Duration(hours: 1));
    s.schedules.add({
      'id': 'b',
      'prompt': 'Catch up on review',
      'status': 'pending',
      'fireAt': past.toIso8601String(),
    });
    await _pumpScreen(tester);
    await tester.tap(find.text('Show details'));
    await _settle(tester);
    expect(find.textContaining('Overdue by'), findsWidgets);
    expect(
      find.textContaining(past.toLocal().year.toString()),
      findsWidgets,
    );
  });

  testWidgets('background Stop toggles AgentNotificationService.stopBackground',
      (tester) async {
    await _pumpScreen(tester);
    expect(AgentNotificationService.I.backgroundStopped, isFalse);
    await tester.tap(find.text('Stop background execution'));
    await _settle(tester);
    expect(AgentNotificationService.I.backgroundStopped, isTrue);
    // The strip now shows the paused state and the Resume affordance.
    expect(find.text('Background execution paused'), findsOneWidget);
    expect(find.text('Resume background execution'), findsOneWidget);
  });
}
