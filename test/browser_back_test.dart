import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/browser_screen.dart';

class _History extends PlatformWebViewController {
  _History(this.canBack)
    : super.implementation(const PlatformWebViewControllerCreationParams());

  bool canBack;
  int backs = 0;

  @override
  Future<bool> canGoBack() async => canBack;
  @override
  Future<bool> canGoForward() async => false;
  @override
  Future<void> goBack() async {
    backs++;
    canBack = false;
  }
}

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
    browserWebViewBuilderForTest = (tab) => const SizedBox.expand();
  });

  tearDown(() {
    browserWebViewBuilderForTest = null;
    AgentService.I
      ..clearBrowserTabsForTest()
      ..debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  Future<_History> pumpBrowser(
    WidgetTester tester, {
    required bool canBack,
  }) async {
    final native = _History(canBack);
    AgentService.I.browserTabs.add(
      BrowserTab(url: 'https://example.test/')
        ..controller = WebViewController.fromPlatform(native)
        ..profileBound = true,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => BrowserScreen.open(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(BrowserScreen), findsOneWidget);
    return native;
  }

  testWidgets('system back goes back a page while history exists', (
    tester,
  ) async {
    final native = await pumpBrowser(tester, canBack: true);
    await tester.binding.handlePopRoute();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(native.backs, 1);
    expect(find.byType(BrowserScreen), findsOneWidget);

    // History exhausted: the next system back leaves the screen.
    await tester.binding.handlePopRoute();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(native.backs, 1);
    expect(find.byType(BrowserScreen), findsNothing);
  });

  testWidgets('AppBar close leaves the screen even with history', (
    tester,
  ) async {
    final native = await pumpBrowser(tester, canBack: true);
    await tester.tap(find.byKey(const ValueKey('browser-close')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(native.backs, 0);
    expect(find.byType(BrowserScreen), findsNothing);
  });
}
