import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';

/// Task 3 (browser desktop compatibility): each tab's desktop mode and
/// user-controlled visual zoom persist alongside its URL, and restore applies
/// them. Old saved shapes (a plain URL list) still restore with the global
/// defaults. Carried-over Task 1 fix: `browser_resize` sets the logical
/// viewport through the per-tab native API — it never shrinks the visual scale.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I.debugPauseScheduleTimerForTest(true);
    app.sessions.clear();
    app.activeSessionId = null;
    AgentService.I.clearBrowserTabsForTest();
  });

  tearDown(() {
    AgentService.I.clearBrowserTabsForTest();
    AgentService.setRunSessionForTest('');
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  ChatSession session(String id) {
    final app = AppState.I;
    final s = ChatSession(id: id, title: 'Title of $id', model: 'm');
    app.sessions.insert(0, s);
    app.activeSessionId = s.id;
    return s;
  }

  group('per-tab mode/zoom persistence', () {
    test('round-trips desktopMode and userZoom per tab', () async {
      final s = session('bdp-rt');
      AgentService.setRunSessionForTest(s.id);
      AgentService.I.browserTabs.addAll([
        BrowserTab(url: 'https://a.test', desktopMode: true)..userZoom = 1.5,
        BrowserTab(url: 'https://b.test', desktopMode: false)..userZoom = 0.75,
      ]);
      AgentService.I.activeTabIndex = 1;

      await AgentService.I.persistBrowserTabsForTest();

      AgentService.I.clearBrowserTabsForTest();
      final restored = await AgentService.I.restoreBrowserTabsForTest();
      expect(restored, isTrue);

      final out = AgentService.I.browserTabs;
      expect(out.map((t) => t.url), ['https://a.test', 'https://b.test']);
      expect(out[0].desktopMode, isTrue);
      expect(out[0].userZoom, 1.5);
      expect(out[1].desktopMode, isFalse);
      expect(out[1].userZoom, 0.75);
      expect(AgentService.I.activeTabIndex, 1);
    });

    test('restore applies persisted values, not the current globals', () async {
      // Global default says desktop, but the saved tab says mobile.
      AppState.I.browserDesktopMode = true;
      final s = session('bdp-apply');
      AgentService.setRunSessionForTest(s.id);
      AgentService.I.browserTabs.add(
        BrowserTab(url: 'https://mobile.test', desktopMode: false)
          ..userZoom = 1.25,
      );

      await AgentService.I.persistBrowserTabsForTest();
      AgentService.I.clearBrowserTabsForTest();
      await AgentService.I.restoreBrowserTabsForTest();

      final tab = AgentService.I.browserTabs.single;
      expect(tab.desktopMode, isFalse, reason: 'persisted value wins');
      expect(tab.userZoom, 1.25);
    });

    test('missing desktopMode falls back to the global default', () async {
      AppState.I.browserDesktopMode = true;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'ovid_browser_tabs_v2',
        jsonEncode({
          'version': 2,
          'activeIndex': 0,
          'tabs': [
            {'url': 'https://bare.test'},
          ],
        }),
      );

      final s = session('bdp-missing');
      AgentService.setRunSessionForTest(s.id);
      final ok = await AgentService.I.restoreBrowserTabsForTest();
      expect(ok, isTrue);

      final tab = AgentService.I.browserTabs.single;
      expect(tab.url, 'https://bare.test');
      expect(
        tab.desktopMode,
        isTrue,
        reason: 'absent mode falls back to browserDesktopMode',
      );
      expect(tab.userZoom, 1.0, reason: 'absent zoom falls back to 1.0');
    });

    test('out-of-range persisted zoom clamps to the readable range', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'ovid_browser_tabs_v2',
        jsonEncode({
          'version': 2,
          'activeIndex': 0,
          'tabs': [
            {'url': 'https://wide.test', 'userZoom': 9.0},
            {'url': 'https://tiny.test', 'userZoom': 0.01},
          ],
        }),
      );

      final s = session('bdp-clamp');
      AgentService.setRunSessionForTest(s.id);
      await AgentService.I.restoreBrowserTabsForTest();

      expect(AgentService.I.browserTabs[0].userZoom, 2.0);
      expect(AgentService.I.browserTabs[1].userZoom, 0.5);
    });

    test('old plain URL-list shape still restores with defaults', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('ovid_browser_tabs', [
        'https://old1.test',
        'https://old2.test',
      ]);
      await prefs.setInt('ovid_browser_active_tab', 1);

      final s = session('bdp-old');
      AgentService.setRunSessionForTest(s.id);
      final ok = await AgentService.I.restoreBrowserTabsForTest();
      expect(ok, isTrue);

      final out = AgentService.I.browserTabs;
      expect(out.map((t) => t.url), ['https://old1.test', 'https://old2.test']);
      expect(out.every((t) => t.userZoom == 1.0), isTrue);
      expect(out.every((t) => t.desktopMode == false), isTrue);
      expect(AgentService.I.activeTabIndex, 1);
    });

    test('per-session restore applies per-tab mode and zoom', () async {
      final s = session('bdp-sess');
      AgentService.setRunSessionForTest(s.id);
      AgentService.I.browserTabs.add(
        BrowserTab(url: 'https://session.test', desktopMode: true)
          ..userZoom = 1.75,
      );
      await AgentService.I.persistBrowserTabsForTest();

      AgentService.I.clearBrowserTabsForTest();
      await AgentService.I.restoreSessionTabsForTest(s.id);

      final tab = AgentService.I.browserTabsFor(s.id).single;
      expect(tab.url, 'https://session.test');
      expect(tab.desktopMode, isTrue);
      expect(tab.userZoom, 1.75);
    });

    test('v2 envelope wins over a stale legacy URL list', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('ovid_browser_tabs', ['https://stale.test']);
      await prefs.setString(
        'ovid_browser_tabs_v2',
        jsonEncode({
          'version': 2,
          'activeIndex': 0,
          'tabs': [
            {'url': 'https://fresh.test', 'desktopMode': true, 'userZoom': 1.5},
          ],
        }),
      );

      final s = session('bdp-win');
      AgentService.setRunSessionForTest(s.id);
      await AgentService.I.restoreBrowserTabsForTest();

      final tab = AgentService.I.browserTabs.single;
      expect(tab.url, 'https://fresh.test');
      expect(tab.desktopMode, isTrue);
      expect(tab.userZoom, 1.5);
    });
  });

  group('browser_resize uses the native viewport, not a visual shrink', () {
    test('resize forwards the logical width and leaves userZoom untouched', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('ovid/webview'), (
            call,
          ) async {
            calls.add(call);
            if (call.method == 'setDesktopViewport') {
              return {'applied': true, 'enabled': call.arguments['enabled']};
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('ovid/webview'), null);
      });

      final s = session('bdp-resize');
      AgentService.setRunSessionForTest(s.id);
      final tab = BrowserTab(url: 'https://r.test', desktopMode: true)
        ..userZoom = 1.4;
      AgentService.I.browserTabs.add(tab);

      final res = await AgentService.I.dispatchForTest('browser_resize', {
        'width': 1280,
        'height': 800,
      });
      await pumpEventQueue();

      expect(res, contains('1280x800'));
      expect(
        tab.userZoom,
        1.4,
        reason: 'resize must not change the injected visual scale',
      );

      final viewportCalls = calls
          .where((c) => c.method == 'setDesktopViewport')
          .toList();
      expect(viewportCalls, hasLength(1));
      final payload = viewportCalls.single.arguments as Map;
      expect(payload['logicalWidth'], 1280);
      expect(payload['tabId'], tab.id);
    });

    test('resize source never injects the viewport factor as CSS zoom', () {
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      final start = src.indexOf("case 'browser_resize':");
      expect(start, isNot(-1), reason: 'browser_resize case exists');
      final end = src.indexOf("case 'browser_desktop':", start);
      final body = src.substring(start, end == -1 ? src.length : end);
      expect(body, contains('applyDesktopViewport'));
      expect(body, contains('logicalWidth'));
      expect(
        body,
        isNot(contains('style.zoom')),
        reason: 'the visual scale must stay userZoom, never a resize value',
      );
      expect(
        body,
        isNot(contains('runJavaScript')),
        reason: 'resize drives the native viewport, not a CSS shrink',
      );
    });

    test('native handler understands the logical viewport width', () {
      final kotlin = File(
        'android/app/src/main/kotlin/com/dhanuk/ovidai/OvidWebViewHandler.kt',
      ).readAsStringSync();
      expect(kotlin, contains('logicalWidth'));
    });
  });
}
