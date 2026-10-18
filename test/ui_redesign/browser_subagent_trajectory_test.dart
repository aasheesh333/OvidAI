import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/trajectory_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

import '../support/fake_cloud_events.dart';

/// Wave 2 UI redesign — trajectory render contract.
///
/// Asserts the premium Aether primitives are mounted on the surviving
/// trajectory screen while the playback entry point (the server event
/// mirror) remains intact. These tests are deliberately shallow: they prove
/// the redesign surface, not the gateway.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeCloudEventsRest rest;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest().seenWelcomeVersion = AppState.welcomeVersion;
    rest = FakeCloudEventsRest();
    installFakeCloudEvents(rest);
  });

  tearDown(() {
    AppState.resetTestInstance();
  });

  Widget host(Widget child) =>
      MaterialApp(theme: Aether.theme(), home: child);

  Future<void> pumpUntilTrajectoryReady(WidgetTester tester) async {
    await settleTrajectory(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'The event request must leave loading once it answers');
  }

  Future<void> pumpTrajectory(WidgetTester tester, String id) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(host(TrajectoryScreen(sessionId: id)));
      await pumpUntilTrajectoryReady(tester);
    });
  }

  testWidgets(
    'trajectory screen renders AetherEmptyState when the mirror is empty',
    (tester) async {
      final session = ChatSession(
        id: 'wave2-ui-traj-empty',
        title: 'Empty',
        model: 'm',
        mode: 'auto',
      );
      AppState.I.sessions.add(session);
      await pumpTrajectory(tester, session.id);

      expect(
        find.byKey(const ValueKey('trajectory-empty')),
        findsOneWidget,
      );
      expect(find.byType(AetherEmptyState), findsOneWidget);
    },
  );

  testWidgets(
    'trajectory screen mounts an AetherSectionTitle for Events and an '
    'AetherCard per event',
    (tester) async {
      final session = ChatSession(
        id: 'wave2-ui-traj-events',
        title: 'With events',
        model: 'm',
        mode: 'auto',
      );
      AppState.I.sessions.add(session);
      rest.events = [
        cloudEvent('1', 'run_started', {'runId': 'r1'}),
        cloudEvent('2', 'tool_completed', {'name': 'read_file', 'isError': false}),
      ];

      await pumpTrajectory(tester, session.id);

      final eventsTitle = find.byKey(const ValueKey('trajectory-events-title'));
      await tester.scrollUntilVisible(eventsTitle, 180,
          scrollable: find.byType(Scrollable).first);
      await tester.pump();
      await tester.ensureVisible(eventsTitle);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('trajectory-events-title')),
        findsOneWidget,
      );
      expect(find.byType(AetherSectionTitle), findsOneWidget);
      // Two events → two event cards. The empty-state branch is not taken.
      expect(find.byType(AetherCard), findsNWidgets(2));
      expect(find.text('#1 · Run started'), findsOneWidget);
      expect(find.text('#2 · Tool done: read_file'), findsOneWidget);
      expect(find.text('ok'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
