import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/trajectory_screen.dart';

import 'support/fake_cloud_events.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeCloudEventsRest rest;
  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    app = AppState.createForTest();
    rest = FakeCloudEventsRest();
    installFakeCloudEvents(rest);
  });

  tearDown(() async {
    AppState.resetTestInstance();
  });

  Future<void> pumpReady(WidgetTester tester, String id) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: TrajectoryScreen(sessionId: id)),
      );
      await settleTrajectory(tester);
    });
  }

  testWidgets('shows outcome-accurate event labels and accessible details',
      (tester) async {
    const id = 'trajectory-premium-outcomes';
    app.sessions.add(ChatSession(id: id, title: 'Outcomes', model: 'm', mode: 'auto'));
    rest.events = [
      cloudEvent('1', 'tool_completed', {'name': 'search', 'isError': false}),
      cloudEvent('2', 'tool_completed', {'name': 'write', 'isError': true}),
      cloudEvent('3', 'subagent_completed', {
        'agent': 'researcher',
        'ok': false,
        'error': 'timed out',
      }),
    ];
    await pumpReady(tester, id);

    expect(find.text('Tool succeeded: search'), findsOneWidget);
    expect(find.text('Tool failed: write'), findsOneWidget);
    expect(find.text('Subagent failed: researcher'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNWidgets(2));
    expect(find.bySemanticsLabel('Tool done: write. failed'), findsOneWidget);
  });

  testWidgets('keeps the existing timeline visible while reloading',
      (tester) async {
    const id = 'trajectory-premium-refresh';
    app.sessions.add(ChatSession(id: id, title: 'Refresh', model: 'm', mode: 'auto'));
    rest.events = [
      cloudEvent('1', 'system_note', {'message': 'Existing timeline'}),
    ];
    await pumpReady(tester, id);

    final gate = Completer<void>();
    rest.hold = gate;
    rest.events = [
      ...rest.events,
      cloudEvent('2', 'system_note', {'message': 'New timeline'}),
    ];
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Reload events'));
      await tester.pump();
    });

    expect(find.text('Existing timeline'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.runAsync(() async {
      gate.complete();
      await settleTrajectory(tester);
    });
    expect(find.text('New timeline'), findsOneWidget);
  });
}
