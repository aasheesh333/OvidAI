import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/github_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    // The reminder tick runs forever; pause it so widget teardown is clean.
    AgentService.I.debugPauseScheduleTimerForTest(true);
    app.sessions.clear();
    app.activeSessionId = null;
  });

  tearDown(() {
    studioLoginPromptOverrideForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  testWidgets(
    'stored invalid token prompts login once initialize settles (401)',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'ovid_github_token': 'invalid-token',
      });
      final client = MockClient(
        (request) async => http.Response('unauthorized', 401),
      );

      var prompted = false;
      studioLoginPromptOverrideForTest = (_) => prompted = true;

      // Mount Studio while initialization is still in flight, exactly as the
      // real startup does. The auth gate must not latch on the momentary
      // logged-in state that precedes the 401.
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const StudioScreen()),
      );
      await tester.pump();
      expect(
        prompted,
        isFalse,
        reason: 'must not prompt while initialization is in flight',
      );

      await GitHubService.I.initialize(client: client);
      await tester.pump();

      expect(prompted, isTrue);
      expect(GitHubService.I.isLoggedIn, isFalse);
      client.close();
    },
  );
}
