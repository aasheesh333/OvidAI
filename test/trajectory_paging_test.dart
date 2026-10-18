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
    app.seenWelcomeVersion = AppState.welcomeVersion;
    rest = FakeCloudEventsRest();
    installFakeCloudEvents(rest);
  });

  tearDown(() async {
    AppState.resetTestInstance();
  });

  testWidgets('trajectory opens on the tail and pages older events', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final session = ChatSession(
      id: 'paging',
      title: 'Paging',
      model: 'm',
      mode: 'auto',
    );
    app.sessions.add(session);
    const total = TrajectoryScreen.pageSize + 50;
    rest.events = [
      cloudEvent('1', 'run_started', {'runId': 'r1'}),
      for (var i = 2; i <= total; i++)
        cloudEvent('$i', 'tool_started', {'name': 'read'}),
    ];

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: TrajectoryScreen(sessionId: session.id),
        ),
      );
      await settleTrajectory(tester);
    });

    // The tail is explicit (`tail=1`); a bare request would start at seq 1.
    expect(rest.requests.first['tail'], '1');
    expect(rest.requests.first['limit'], '${TrajectoryScreen.pageSize}');
    expect(find.text('#51 · Tool: read'), findsOneWidget);
    expect(find.text('#50 · Tool: read'), findsNothing);

    final more = find.byKey(const ValueKey('trajectory-load-earlier'));
    expect(more, findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(more);
      await settleTrajectory(tester);
    });

    // Older page is requested with the oldest loaded seq as the exclusive
    // `before` cursor.
    expect(rest.requests[1]['before'], '51');
    expect(find.text('#1 · Run started'), findsOneWidget);
    // No more older pages: the first page was smaller than the page size.
    expect(more, findsNothing);
  });
}
