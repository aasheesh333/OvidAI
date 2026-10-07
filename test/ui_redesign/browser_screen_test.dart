import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/browser_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

/// Wave 2 UI redesign — BrowserScreen smoke renders.
///
/// The redesign composes the browser chrome from Aether primitives
/// (AetherGradientHeader + AetherField omnibar + AetherGhostButton nav +
/// AetherStatusDot load status) while keeping every functional contract the
/// older suites pin: navigation guards, popup notice, desktop geometry,
/// external-open tooltip and the agent-status semantics. These tests only
/// prove the screen RENDERS as primitives and that the cheap, platform-free
/// interactions (tab strip, focus-driven omnibar reveal, disabled nav guards)
/// survive. Real WebView behaviour is out of reach of a widget test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const stubKey = Key('browser-stub-webview');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    AppState.createForTest().seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I
      ..debugPauseScheduleTimerForTest(true)
      ..clearBrowserTabsForTest();
    browserWebViewBuilderForTest = (_) =>
        const ColoredBox(key: stubKey, color: Color(0xFF123456));
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
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const BrowserScreen()),
    );
    await tester.pump();
  }

  testWidgets(
    'smoke: a tab renders the Aether chrome and the stubbed web view',
    (tester) async {
      AgentService.I.browserTabs.add(BrowserTab(url: 'https://example.com'));
      await pumpBrowser(tester);

      // Header shell + omnibar are the real primitives, one of each.
      final header = find.byType(AetherGradientHeader);
      expect(header, findsOneWidget);
      expect(
        find.descendant(of: header, matching: find.byType(AetherField)),
        findsOneWidget,
      );
      // Back / forward / reload / go are all Aether ghost icon buttons
      // sitting inside the gradient header.
      expect(
        find.descendant(of: header, matching: find.byType(AetherGhostButton)),
        findsNWidgets(4),
      );

      // Stable keys the older suites (and screen readers) navigate by.
      expect(
        find.byKey(const ValueKey('browser-url-field')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('browser-status-dot')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('browser-back')), findsOneWidget);
      expect(find.byKey(const ValueKey('browser-forward')), findsOneWidget);
      expect(find.byKey(const ValueKey('browser-reload')), findsOneWidget);

      // Load status is an AetherStatusDot (strip + app-bar agent indicator).
      expect(find.byType(AetherStatusDot), findsWidgets);
      expect(find.textContaining('Ready · '), findsOneWidget);

      // External-launch entry point (download fallback / sign-in escape
      // hatch) is still mounted.
      expect(find.byTooltip('Open in browser'), findsOneWidget);

      // The tab body is the stubbed web view, and nothing threw.
      expect(find.byKey(stubKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('smoke: renders with no tabs and no crash', (tester) async {
    await pumpBrowser(tester);
    expect(find.byType(AetherGradientHeader), findsOneWidget);
    expect(
      find.byKey(const ValueKey('browser-url-field')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('smoke: two tabs render the tab strip with labelled close hit '
      'areas', (tester) async {
    AgentService.I.browserTabs.add(BrowserTab(url: 'https://a.test/'));
    AgentService.I.browserTabs.add(BrowserTab(url: 'https://b.test/'));
    await pumpBrowser(tester);

    expect(find.bySemanticsLabel('Close tab'), findsNWidgets(2));
    // One ghost button per nav action still, strip did not add more.
    expect(find.byType(AetherGhostButton), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('smoke: focusing the omnibar reveals the live URL', (
    tester,
  ) async {
    final tab = BrowserTab(url: 'https://example.test/page')
      ..title = 'Some page title';
    AgentService.I.browserTabs.add(tab);
    await pumpBrowser(tester);

    final field = find.byType(TextField);
    expect(field, findsOneWidget);
    expect(
      tester.widget<TextField>(field).controller!.text,
      'Some page title',
    );

    await tester.tap(field);
    await tester.pump();
    expect(
      tester.widget<TextField>(field).controller!.text,
      'https://example.test/page',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'smoke: nav ghost buttons with a controller-less tab are safe no-ops',
    (tester) async {
      AgentService.I.browserTabs.add(BrowserTab(url: 'https://example.com'));
      await pumpBrowser(tester);

      // The stubbed tab has no WebViewController; guards must swallow the
      // taps instead of throwing (navigation itself lives in AgentService).
      await tester.tap(find.byKey(const ValueKey('browser-back')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('browser-forward')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('browser-reload')));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
