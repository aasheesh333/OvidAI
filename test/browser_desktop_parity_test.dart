import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';

/// Task 4 (browser desktop compatibility) composition gate.
///
/// Pins the three shipped behaviors together in one flow instead of
/// re-proving each unit in isolation:
///   1. readable scale — desktop mode keeps `userZoom` (never `devW/1280`);
///   2. per-tab independence — toggling/resizing one tab never moves another;
///   3. persistence — per-tab `desktopMode` + `userZoom` survive a restart.
///
/// Each test touches at least two of the three so a regression in any one
/// breaks the gate. Runtime behavior only (no source-substring checks).
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
    BrowserTab.devW = 360;
    BrowserTab.devH = 720;
  });

  tearDown(() {
    AgentService.I.clearBrowserTabsForTest();
    AgentService.setRunSessionForTest('');
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    BrowserTab.devW = 360;
    BrowserTab.devH = 720;
  });

  ChatSession session(String id) {
    final app = AppState.I;
    final s = ChatSession(id: id, title: 'Title of $id', model: 'm');
    app.sessions.insert(0, s);
    app.activeSessionId = s.id;
    return s;
  }

  void mockViewport(List<MethodCall> calls) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ovid/webview'), (
          call,
        ) async {
          calls.add(call);
          if (call.method == 'setDesktopViewport') {
            return {
              'applied': true,
              'enabled': call.arguments['enabled'],
              'tabId': call.arguments['tabId'],
            };
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('ovid/webview'), null);
    });
  }

  group('parity: readable scale stays per-tab', () {
    test('desktop toggle keeps 1.0 scale and leaves sibling mobile', () async {
      // devW=360 would shrink to ~0.28 under the old devW/1280 fit.
      final a = BrowserTab(url: 'https://a.parity', desktopMode: false);
      final b = BrowserTab(url: 'https://b.parity', desktopMode: false);

      await AgentService.I.setTabDesktopMode(a, true, reload: false);

      expect(a.desktopMode, isTrue);
      expect(a.userZoom, 1.0);
      expect(a.zoom, 1.0);
      expect(
        AgentService.browserZoomScriptForTest(a.userZoom),
        'document.documentElement.style.zoom = "1.0";',
      );
      expect(b.desktopMode, isFalse);
      expect(b.userZoom, 1.0);
    });

    test('distinct user zooms survive opposite mode toggles', () async {
      final a = BrowserTab(url: 'https://a.parity', desktopMode: false)
        ..userZoom = 1.5;
      final b = BrowserTab(url: 'https://b.parity', desktopMode: false)
        ..userZoom = 0.7;

      await AgentService.I.setTabDesktopMode(a, true, reload: false);
      await AgentService.I.setTabDesktopMode(b, true, reload: false);
      await AgentService.I.setTabDesktopMode(b, false, reload: false);

      expect(a.desktopMode, isTrue);
      expect(b.desktopMode, isFalse);
      expect(a.userZoom, 1.5);
      expect(b.userZoom, 0.7);
      expect(
        AgentService.browserZoomScriptForTest(a.userZoom),
        contains('1.5'),
      );
      expect(
        AgentService.browserZoomScriptForTest(b.userZoom),
        contains('0.7'),
      );
    });
  });

  group('parity: native identity across a mixed sequence', () {
    test('toggle + resize + second toggle keep tab identities separate',
        () async {
      final calls = <MethodCall>[];
      mockViewport(calls);
      final s = session('parity-seq');
      AgentService.setRunSessionForTest(s.id);
      final a = BrowserTab(url: 'https://a.parity', desktopMode: false);
      final b = BrowserTab(url: 'https://b.parity', desktopMode: false);
      AgentService.I.browserTabs.addAll([a, b]);

      await AgentService.I.setTabDesktopMode(a, true, reload: false);
      await pumpEventQueue();
      expect((calls.last.arguments as Map)['tabId'], a.id);

      // Resize targets the active tab only and must not touch visual zoom.
      AgentService.I.activeTabIndex = 0;
      a.userZoom = 1.4;
      final res = await AgentService.I.dispatchForTest('browser_resize', {
        'width': 1280,
        'height': 800,
      });
      await pumpEventQueue();
      expect(res, contains('1280x800'));
      expect(a.userZoom, 1.4);
      final resizeCall = calls.lastWhere(
        (c) => (c.arguments as Map).containsKey('logicalWidth'),
      );
      expect((resizeCall.arguments as Map)['logicalWidth'], 1280);
      expect((resizeCall.arguments as Map)['tabId'], a.id);

      await AgentService.I.setTabDesktopMode(b, true, reload: false);
      await pumpEventQueue();
      expect((calls.last.arguments as Map)['tabId'], b.id);
      expect(a.desktopMode, isTrue);
      expect(b.desktopMode, isTrue);
      expect(a.userZoom, 1.4);
    });
  });

  group('parity: persistence round-trip', () {
    test('mixed two-tab configuration restores modes, zooms, index',
        () async {
      final s = session('parity-rt');
      AgentService.setRunSessionForTest(s.id);
      AgentService.I.browserTabs.addAll([
        BrowserTab(url: 'https://a.parity', desktopMode: true)
          ..userZoom = 1.5,
        BrowserTab(url: 'https://b.parity', desktopMode: false)
          ..userZoom = 0.75,
      ]);
      AgentService.I.activeTabIndex = 1;

      await AgentService.I.persistBrowserTabsForTest();
      AgentService.I.clearBrowserTabsForTest();
      AgentService.setRunSessionForTest(s.id);
      expect(await AgentService.I.restoreBrowserTabsForTest(), isTrue);

      final out = AgentService.I.browserTabs;
      expect(out.map((t) => t.url), [
        'https://a.parity',
        'https://b.parity',
      ]);
      expect(out[0].desktopMode, isTrue);
      expect(out[0].userZoom, 1.5);
      expect(out[1].desktopMode, isFalse);
      expect(out[1].userZoom, 0.75);
      expect(AgentService.I.activeTabIndex, 1);
    });

    test('toggle, zoom, resize, restart keeps the whole configuration',
        () async {
      final calls = <MethodCall>[];
      mockViewport(calls);
      final s = session('parity-e2e');
      AgentService.setRunSessionForTest(s.id);
      final a = BrowserTab(url: 'https://a.parity', desktopMode: false);
      final b = BrowserTab(url: 'https://b.parity', desktopMode: false);
      AgentService.I.browserTabs.addAll([a, b]);

      await AgentService.I.setTabDesktopMode(a, true, reload: false);
      a.userZoom = 1.6;
      b.userZoom = 0.6;
      AgentService.I.activeTabIndex = 0;
      await AgentService.I.dispatchForTest('browser_resize', {
        'width': 1280,
        'height': 800,
      });
      await pumpEventQueue();
      AgentService.I.activeTabIndex = 1;
      await AgentService.I.persistBrowserTabsForTest();

      AgentService.I.clearBrowserTabsForTest();
      AgentService.setRunSessionForTest(s.id);
      await AgentService.I.restoreBrowserTabsForTest();

      final out = AgentService.I.browserTabs;
      expect(out.length, 2);
      expect(out[0].desktopMode, isTrue);
      expect(out[0].userZoom, 1.6);
      expect(out[1].desktopMode, isFalse);
      expect(out[1].userZoom, 0.6);
      // Readable scale still holds after the restart: injected CSS equals
      // userZoom, never the ~0.28 device-derived fit.
      for (final t in out) {
        expect(
          AgentService.browserZoomScriptForTest(t.userZoom),
          'document.documentElement.style.zoom = "${t.userZoom}";',
        );
        expect((t.userZoom - 360 / 1280).abs() > 0.05, isTrue);
      }
    });

    test('restore clamps out-of-range zoom and defaults missing fields',
        () async {
      // One raw envelope exercises both edges at once: an out-of-range zoom
      // must clamp at restore time, and a bare URL must take the global
      // default mode plus 1.0 zoom.
      AppState.I.browserDesktopMode = false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'ovid_browser_tabs_v2',
        jsonEncode({
          'version': 2,
          'activeIndex': 0,
          'tabs': [
            {
              'url': 'https://wide.parity',
              'desktopMode': true,
              'userZoom': 9.0,
            },
            {'url': 'https://bare.parity'},
          ],
        }),
      );

      final s = session('parity-clamp');
      AgentService.setRunSessionForTest(s.id);
      expect(await AgentService.I.restoreBrowserTabsForTest(), isTrue);

      final out = AgentService.I.browserTabs;
      expect(out[0].userZoom, 2.0);
      expect(out[0].desktopMode, isTrue);
      expect(out[1].userZoom, 1.0);
      expect(out[1].desktopMode, isFalse);
    });
  });
}
