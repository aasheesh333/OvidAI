import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/trajectory_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

import '../support/fake_cloud_events.dart';

/// Wave 2 UI redesign — trajectory (server event mirror) screen contract.
///
/// P8 Task 20 re-pointed the screen from the local JSONL ledger to
/// `GET /sessions/:id/events`. These tests pin the surviving Aether surface:
///   * [AetherSectionTitle] eyebrow 'Events' above the event list.
///   * One [AetherCard] per event carrying a mono timestamp caption, the
///     `#seq · title` title, and the detail body.
///   * [AetherEmptyState] when the mirror has no events.
///   * A real error state for a 404 instead of an endless spinner.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeCloudEventsRest rest;
  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    rest = FakeCloudEventsRest();
    installFakeCloudEvents(rest);
  });

  tearDown(() {
    AppState.resetTestInstance();
  });

  ChatSession addSession(String id, String title) {
    final session = ChatSession(
      id: id,
      title: title,
      model: 'm',
      mode: 'auto',
    );
    app.sessions.add(session);
    return session;
  }

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

  testWidgets('empty mirror renders AetherEmptyState and no event cards', (
    tester,
  ) async {
    final session = addSession('wave2-ui-traj-smoke-empty', 'Empty');
    await pumpTrajectory(tester, session.id);

    expect(find.byKey(const ValueKey('trajectory-empty')), findsOneWidget);
    expect(find.byType(AetherEmptyState), findsOneWidget);
    expect(find.text('No events yet'), findsOneWidget);
    expect(find.byType(AetherCard), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets(
    'events render as AetherCards with mono timestamp caption, title and '
    'body, under the Events section title',
    (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final session = addSession('wave2-ui-traj-smoke-events', 'With events');
      rest.events = [
        cloudEvent('1', 'run_started', {'runId': 'r1'}),
        cloudEvent('2', 'tool_started', {'name': 'read_file'}),
        cloudEvent('3', 'tool_completed', {'name': 'read_file', 'isError': false}),
        cloudEvent('4', 'run_completed', {'runId': 'r1'}),
      ];

      await pumpTrajectory(tester, session.id);

      // App bar keeps the trajectory route identity.
      expect(find.text('Trajectory · With events'), findsOneWidget);

      // Section title above the list.
      expect(
        find.byKey(const ValueKey('trajectory-events-title')),
        findsOneWidget,
      );
      expect(find.text('EVENTS'), findsOneWidget);

      // Four events → four event cards (no local projection strip any more).
      expect(find.byType(AetherCard), findsNWidgets(4));

      // Titles and detail bodies come straight from the server events.
      expect(find.text('#1 · Run started'), findsOneWidget);
      expect(find.text('#2 · Tool: read_file'), findsOneWidget);
      expect(find.text('#3 · Tool done: read_file'), findsOneWidget);
      expect(find.text('ok'), findsOneWidget);
      expect(find.text('#4 · Run completed'), findsOneWidget);

      // Every event card leads with a mono timestamp caption.
      final monoTimestamps = find.byWidgetPredicate(
        (w) => w is Text && w.style?.fontFamily == 'JetBrainsMono',
      );
      expect(monoTimestamps, findsNWidgets(4));
    },
  );

  testWidgets('resolves a LOCAL session id to the server UUID', (tester) async {
    final session = addSession('local-traj', 'Local id');
    rest.events = [cloudEvent('1', 'run_started', {'runId': 'r1'})];
    installFakeCloudEvents(
      rest,
      idMap: <String, String>{'local-traj': 'server-uuid-traj'},
    );

    await pumpTrajectory(tester, session.id);

    expect(rest.requests.single['path'], '/sessions/server-uuid-traj/events');
    expect(
      rest.requests.single['tail'],
      '1',
      reason: 'a bare no-cursor request would return from the beginning',
    );
  });

  testWidgets('reload action re-reads the mirror (playback preserved)', (
    tester,
  ) async {
    final session = addSession('wave2-ui-traj-smoke-reload', 'Reload');
    rest.events = [cloudEvent('1', 'system_note', {'message': 'hello'})];

    await pumpTrajectory(tester, session.id);
    expect(find.text('#1 · Note'), findsOneWidget);
    expect(find.byType(AetherCard), findsNWidgets(1));

    // A new event lands in the mirror; the app-bar reload must re-read it.
    rest.events = [
      ...rest.events,
      cloudEvent('2', 'system_note', {'message': 'again'}),
    ];
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Reload events'));
      await pumpUntilTrajectoryReady(tester);
    });

    expect(find.text('#2 · Note'), findsOneWidget);
    expect(find.byType(AetherCard), findsNWidgets(2));
  });

  testWidgets('404 renders a real error state, not an endless spinner', (
    tester,
  ) async {
    final session = addSession('wave2-ui-traj-missing', 'Missing');
    rest.error = CloudApiException(
      status: 404,
      code: 'not_found',
      message: 'Not found.',
    );

    await pumpTrajectory(tester, session.id);

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Could not load events'), findsOneWidget);
    expect(
      find.text('This session was not found on Ovid Cloud.'),
      findsOneWidget,
    );
  });
}
