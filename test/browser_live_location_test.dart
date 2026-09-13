import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/browser_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    AppState.createForTest().seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I
      ..debugPauseScheduleTimerForTest(true)
      ..clearBrowserTabsForTest();
    browserWebViewBuilderForTest = (_) => const SizedBox();
  });

  tearDown(() {
    browserWebViewBuilderForTest = null;
    AgentService.I
      ..clearBrowserTabsForTest()
      ..debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  testWidgets('omnibar shows title until tapped, then reveals live URL',
      (tester) async {
    final tab = BrowserTab(url: 'https://example.test/live')
      ..title = 'Live page title';
    AgentService.I.browserTabs.add(tab);

    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const BrowserScreen()),
    );
    await tester.pump();

    final field = find.byType(TextField);
    expect(field, findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, 'Live page title');

    await tester.tap(field);
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text,
        'https://example.test/live');
  });
}
