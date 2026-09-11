import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';

/// Task 1 (browser desktop compatibility): desktop mode must render at a
/// readable scale. The visual CSS scale is `BrowserTab.userZoom` only — it is
/// never derived from the device width (`devW / 1280`), and toggling
/// desktop/mobile does not alter it.
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
  });

  tearDown(() {
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  group('BrowserTab.userZoom', () {
    test('defaults to 1.0 (readable, not device-derived)', () {
      final tab = BrowserTab(url: 'https://example.com', desktopMode: false);
      expect(tab.userZoom, 1.0);
    });

    test('clamps to the 0.5-2.0 readable range', () {
      final tab = BrowserTab(url: 'https://example.com', desktopMode: false);
      tab.userZoom = 3.0;
      expect(tab.userZoom, 2.0);
      tab.userZoom = 0.1;
      expect(tab.userZoom, 0.5);
      tab.userZoom = 1.75;
      expect(tab.userZoom, 1.75);
    });
  });

  group('desktop mode readable scale', () {
    test('desktop toggle does not derive zoom from the device width', () async {
      BrowserTab.devW = 360;
      BrowserTab.devH = 720;
      final tab = BrowserTab(url: 'https://example.com', desktopMode: false);
      expect(tab.zoom, 1.0);

      await AgentService.I.setTabDesktopMode(tab, true, reload: false);
      expect(tab.desktopMode, isTrue);
      expect(
        tab.zoom,
        1.0,
        reason: 'zoom is the browser_resize logical factor, not devW/1280',
      );
      expect(
        tab.userZoom,
        1.0,
        reason: 'desktop mode must not shrink the readable scale',
      );
    });

    test('mode toggle leaves a user-set visual zoom untouched', () async {
      final tab = BrowserTab(url: 'https://example.com', desktopMode: false)
        ..userZoom = 1.6;
      await AgentService.I.setTabDesktopMode(tab, true, reload: false);
      expect(tab.userZoom, 1.6);
      await AgentService.I.setTabDesktopMode(tab, false, reload: false);
      expect(tab.userZoom, 1.6);
    });
  });

  group('injected CSS scale', () {
    test('equals userZoom and ignores the logical (viewport) zoom', () {
      final tab = BrowserTab(url: 'https://example.com', desktopMode: true)
        ..userZoom = 1.75
        // A viewport-derived factor set by browser_resize must not leak in.
        ..zoom = 0.28;
      expect(
        AgentService.browserZoomScriptForTest(tab.userZoom),
        'document.documentElement.style.zoom = "1.75";',
      );
    });

    test('_applyTabZoom injects userZoom, never the logical zoom', () {
      final src = _agentSource();
      final start = src.indexOf('Future<void> _applyTabZoom');
      expect(start, isNot(-1), reason: '_applyTabZoom exists');
      final end = src.indexOf(
        'Future<void> recreateControllerForDesktopToggle',
        start,
      );
      final body = src.substring(start, end == -1 ? src.length : end);
      expect(body, contains('tab.userZoom'));
      expect(body, isNot(contains('tab.zoom')));
    });

    test('source no longer injects devW/1280 as a visual scale', () {
      final src = _agentSource();
      expect(src, isNot(contains('devW / 1280')));
    });
  });
}

String _agentSource() => File('lib/core/agent_service.dart').readAsStringSync();
