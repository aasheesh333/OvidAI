import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/sidebar.dart';
import 'package:ovid_ai/ui/schedule_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppState app;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app = AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    AgentService.I.schedules.stopped = false;
    app.sessions.add(ChatSession(id: 's', title: 'My work', model: 'm'));
    app.activeSessionId = 's';
  });
  tearDown(() => AppState.resetTestInstance());

  testWidgets('Schedule is above Trajectory and opens active session tasks', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: MediaQuery(data: const MediaQueryData(textScaler: TextScaler.linear(.7)),
        child: const SessionsSidebar()),
    )));
    expect(tester.getTopLeft(find.text('Schedule')).dy,
        lessThan(tester.getTopLeft(find.text('Trajectory — event ledger')).dy));
    await tester.tap(find.text('Schedule'));
    await tester.pumpAndSettle();
    expect(find.text('Schedule · My work'), findsOneWidget);
    expect(find.textContaining('Ask the agent'), findsOneWidget);
  });

  testWidgets('renders real statuses, next date and edit/cancel controls', (tester) async {
    final s = app.sessionById('s')!;
    for (final status in ['pending', 'running', 'completed', 'failed', 'paused']) {
      s.schedules.add({'id': status, 'prompt': '$status task', 'status': status,
        'fireAt': '2026-10-04T09:30:00Z'});
    }
    await tester.pumpWidget(const MaterialApp(home: ScheduleScreen(sessionId: 's')));
    expect(find.text('pending'), findsOneWidget);
    expect(find.textContaining('2026-10-04'), findsWidgets);
    expect(find.byTooltip('Edit schedule'), findsWidgets);
    expect(find.byTooltip('Cancel schedule'), findsWidgets);
    await tester.scrollUntilVisible(find.text('paused task'), 200);
    expect(find.text('paused'), findsOneWidget);
  });

  testWidgets('cancel retains visible cancelled history', (tester) async {
    final s = app.sessionById('s')!;
    s.schedules.add({'id': 'a', 'prompt': 'My task', 'status': 'pending',
      'fireAt': '2026-10-04T09:30:00Z'});
    await tester.pumpWidget(const MaterialApp(home: ScheduleScreen(sessionId: 's')));
    await tester.tap(find.byTooltip('Cancel schedule'));
    await tester.pumpAndSettle();
    expect(s.schedules.single['status'], 'cancelled');
    expect(find.text('cancelled'), findsOneWidget);
    expect(find.text('My task'), findsOneWidget);
  });

  testWidgets('editing validates and persists new prompt and time', (tester) async {
    final s = app.sessionById('s')!;
    s.schedules.add({'id': 'a', 'prompt': 'My task', 'status': 'pending',
      'fireAt': '2026-10-04T09:30:00Z'});
    await tester.pumpWidget(const MaterialApp(home: ScheduleScreen(sessionId: 's')));
    await tester.tap(find.byTooltip('Edit schedule'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Updated task');
    await tester.enterText(find.byType(TextField).at(1), '2026-02-30 10:00');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Invalid calendar'), findsOneWidget);
    expect(s.schedules.single['prompt'], 'My task');
    await tester.enterText(find.byType(TextField).at(1), '2026-12-01T12:00:00Z');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    expect(s.schedules.single['prompt'], 'Updated task');
    expect(s.schedules.single['fireAt'], '2026-12-01T12:00:00.000Z');
    expect(find.text('Updated task'), findsOneWidget);
  });
}
