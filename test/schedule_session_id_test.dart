// The Schedule screen is opened with a LOCAL `ChatSession.id`, while every
// server schedule carries the server UUID. The screen must resolve the id at
// the REST boundary before filtering, or the list is always empty.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/schedule_client.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/schedule_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/schedule_fake.dart';

// The redesigned screen has a pulsing status dot; pumpAndSettle would spin
// forever on it. Advance by a bounded duration instead.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  const localId = 'local-1';
  const serverId = '018f3b0e-7a2c-7c4d-9e5f-123456789abc';

  late AppState app;
  late FakeScheduleGateway fake;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ScheduleClient.timeZoneOverrideForTest = 'UTC';
    app = AppState.createForTest();
    app.sessions.add(ChatSession(id: localId, title: 'Local chat', model: 'm'));
    app.activeSessionId = localId;
    fake = FakeScheduleGateway([
      scheduleJson(sessionId: serverId, title: 'Server task'),
    ]);
    ScheduleClient.installForTest(fake.client);
    CloudSessionStore.installForTest(
      CloudSessionStore.forTest(idMap: const {localId: serverId}),
    );
  });

  tearDown(() {
    ScheduleClient.timeZoneOverrideForTest = null;
    CloudSessionStore.resetForTest();
    AppState.resetTestInstance();
  });

  testWidgets(
      'a screen opened with the LOCAL id shows the schedule stored under the '
      'server UUID', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ScheduleScreen(sessionId: localId)),
    );
    await _settle(tester);

    expect(CloudSessionStore.I.serverIdFor(localId), serverId);
    expect(fake.listCalls, 1);
    expect(find.text('Server task'), findsOneWidget);
    expect(find.text('No scheduled tasks'), findsNothing);
    // The title still comes from the LOCAL row.
    expect(find.textContaining('Local chat'), findsOneWidget);
  });
}
