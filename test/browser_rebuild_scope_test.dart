import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
// Replace only the native boundary; tab state and screen logic stay real.
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/core/webview_pool.dart';
import 'package:ovid_ai/ui/browser_screen.dart';

class _CountingController extends PlatformWebViewController {
  _CountingController()
    : super.implementation(const PlatformWebViewControllerCreationParams());

  int historyCalls = 0;

  @override
  Future<bool> canGoBack() async {
    historyCalls++;
    return false;
  }

  @override
  Future<bool> canGoForward() async {
    historyCalls++;
    return false;
  }
}

/// F-031 / F-032: the browser mounts one WebView and ignores unrelated
/// [AgentService] notifications.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest().seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I
      ..debugPauseScheduleTimerForTest(true)
      ..clearBrowserTabsForTest();
    browserWebViewBuilderForTest = (tab) =>
        SizedBox.expand(key: ValueKey('stub-${tab.id}'));
  });

  tearDown(() {
    browserWebViewBuilderForTest = null;
    AgentService.I
      ..clearBrowserTabsForTest()
      ..debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
  });

  Future<void> pumpBrowser(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const BrowserScreen()),
    );
    await tester.pump();
  }

  testWidgets('five tabs mount a single web view (the active one)', (
    tester,
  ) async {
    final tabs = [
      for (var i = 0; i < 5; i++) BrowserTab(url: 'https://t$i.test/'),
    ];
    AgentService.I.browserTabs.addAll(tabs);
    AgentService.I.activeTabIndex = 2;
    await pumpBrowser(tester);

    expect(find.byKey(ValueKey('stub-${tabs[2].id}')), findsOneWidget);
    for (final i in [0, 1, 3, 4]) {
      expect(find.byKey(ValueKey('stub-${tabs[i].id}')), findsNothing);
    }

    AgentService.I.selectBrowserTab(4);
    await tester.pump();
    expect(find.byKey(ValueKey('stub-${tabs[4].id}')), findsOneWidget);
    expect(find.byKey(ValueKey('stub-${tabs[2].id}')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('100 unrelated notifies make no history platform calls', (
    tester,
  ) async {
    final native = _CountingController();
    final tab = BrowserTab(url: 'https://example.test/')
      ..controller = WebViewController.fromPlatform(native)
      ..profileBound = true;
    AgentService.I.browserTabs.add(tab);
    await pumpBrowser(tester);
    await tester.pump();
    native.historyCalls = 0;

    for (var i = 0; i < 100; i++) {
      AgentService.I.refreshNow();
      await tester.pump();
    }
    expect(native.historyCalls, 0);

    // A navigation does refresh history once (back + forward).
    tab.url = 'https://example.test/next';
    AgentService.I.refreshNow();
    await tester.pump();
    expect(native.historyCalls, 2);
    await tester.pumpWidget(const SizedBox());
  });

  test('tab cap drops the oldest inactive tab', () {
    final agent = AgentService.I;
    for (var i = 0; i < AgentService.maxTabsPerSession + 3; i++) {
      agent.newBrowserTab('https://t$i.test/');
    }
    final tabs = agent.browserTabs;
    expect(tabs, hasLength(AgentService.maxTabsPerSession));
    expect(
      tabs.last.url,
      'https://t${AgentService.maxTabsPerSession + 2}.test/',
    );
    expect(agent.activeTabIndex, tabs.length - 1);
  });

  group('LruWebViewPool', () {
    test('releases the least recently used beyond maxLive', () {
      final released = <String>[];
      final pool = LruWebViewPool<String>(maxLive: 3, release: released.add);
      for (final t in ['a', 'b', 'c']) {
        pool.touch(t);
      }
      pool.touch('a');
      pool.touch('d');
      expect(released, ['b']);
      expect(pool.live, ['c', 'a', 'd']);
    });

    test('never releases pinned tabs or the touched tab', () {
      final released = <String>[];
      final pool = LruWebViewPool<String>(maxLive: 2, release: released.add);
      pool.touch('a');
      pool.touch('b');
      pool.touch('c', pinned: {'a'});
      expect(released, ['b']);
      expect(pool.live, ['a', 'c']);
    });

    test('memory pressure releases all but the kept tabs', () {
      final released = <String>[];
      final pool = LruWebViewPool<String>(maxLive: 3, release: released.add);
      for (final t in ['a', 'b', 'c']) {
        pool.touch(t);
      }
      pool.releaseAllExcept({'c'});
      expect(released, ['a', 'b']);
      expect(pool.live, ['c']);
    });
  });
}
