import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/browser_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

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
    browserWebViewBuilderForTest = (_) => const SizedBox.shrink();
  });

  tearDown(() {
    browserWebViewBuilderForTest = null;
    AgentService.I
      ..clearBrowserTabsForTest()
      ..debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  Future<void> pumpBrowser(WidgetTester tester) async {
    tester.view.physicalSize = const Size(480, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const BrowserScreen()),
    );
    await tester.pump();
  }

  testWidgets('empty browser offers an Open new tab action', (tester) async {
    await pumpBrowser(tester);

    expect(find.byKey(const ValueKey('browser-open-new-tab')), findsOneWidget);
    expect(find.text('Open new tab'), findsOneWidget);
  });

  testWidgets('submitting the omnibar creates a tab when none exists', (
    tester,
  ) async {
    await pumpBrowser(tester);
    await tester.enterText(find.byType(TextField), 'example.com/docs');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(AgentService.I.browserTabs, hasLength(1));
    expect(AgentService.I.browserTabs.single.url, 'https://example.com/docs');
  });

  test('host-like omnibar input is normalized as a secure URL', () {
    expect(normalizeBrowserUrl('example.com/docs'), 'https://example.com/docs');
    expect(
      normalizeBrowserUrl('https://example.com/docs'),
      'https://example.com/docs',
    );
    expect(normalizeBrowserUrl('hello world'), contains('google.com/search'));
  });

  testWidgets('back and forward are disabled without available history', (
    tester,
  ) async {
    await pumpBrowser(tester);

    final back = tester.widget<AetherGhostButton>(
      find.byKey(const ValueKey('browser-back')),
    );
    final forward = tester.widget<AetherGhostButton>(
      find.byKey(const ValueKey('browser-forward')),
    );
    expect(back.onPressed, isNull);
    expect(forward.onPressed, isNull);
  });
}
