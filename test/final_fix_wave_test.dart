import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

// Final review wave: P4 user-zoom control (browser_desktop `zoom`) +
// overlay lifecycle wiring (show on Control run start, hide on run end /
// mode exit / panic-stop). Runtime hookup only — no source-string checks.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    if (Platform.isLinux) {
      open.overrideFor(OperatingSystem.linux, () {
        try {
          return ffi.DynamicLibrary.open('libsqlite3.so.0');
        } catch (_) {
          return ffi.DynamicLibrary.open(
            '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
          );
        }
      });
    }
    app = AppState.I;
    await app.initialize();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentService.I.debugPauseScheduleTimerForTest(true);
    AgentService.I.clearBrowserTabsForTest();
    BrowserTab.devW = 360;
    BrowserTab.devH = 720;
  });

  tearDown(() {
    AgentService.I.clearBrowserTabsForTest();
    AgentService.setRunSessionForTest('');
    AgentService.I.debugPauseScheduleTimerForTest(false);
    BrowserTab.devW = 360;
    BrowserTab.devH = 720;
  });

  ChatSession newSession(
    String id, {
    String mode = 'auto',
    String model = 'm',
    String? providerId,
  }) {
    final s = ChatSession(
      id: id,
      title: 'S',
      model: model,
      mode: mode,
      providerId: providerId,
    );
    app.sessions.insert(0, s);
    app.activeSessionId = s.id;
    addTearDown(() {
      AgentService.setRunSessionForTest('');
      app.activeSessionId = null;
      app.sessions.removeWhere((x) => x.id == s.id);
    });
    return s;
  }

  group('wave: browser_desktop zoom schema', () {
    test('schema exposes optional zoom 0.5-2.0; mode still required', () {
      final tools = AgentService.I.toolsForTest();
      final tool = tools.firstWhere(
        (t) => (t['function'] as Map)['name'] == 'browser_desktop',
      );
      final fn = tool['function'] as Map;
      final params = fn['parameters'] as Map;
      final props = params['properties'] as Map;
      expect(props.containsKey('zoom'), isTrue, reason: 'missing zoom arg');
      final zoom = props['zoom'] as Map;
      expect(zoom['minimum'], 0.5);
      expect(zoom['maximum'], 2.0);
      expect(params['required'], ['mode']);
    });
  });

  group('wave: browser_desktop zoom validation (no WebView needed)', () {
    test('non-numeric zoom is rejected before any platform touch', () async {
      final s = newSession('wave-zoom-nonnumeric');
      AgentService.setRunSessionForTest(s.id);
      final res = await AgentService.I.dispatchForTest('browser_desktop', {
        'mode': 'desktop',
        'zoom': 'big',
      });
      expect(res.toLowerCase(), contains('invalid zoom'));
    });

    test('out-of-range zoom is rejected before any platform touch', () async {
      final s = newSession('wave-zoom-range');
      AgentService.setRunSessionForTest(s.id);
      final res = await AgentService.I.dispatchForTest('browser_desktop', {
        'mode': 'desktop',
        'zoom': 9.0,
      });
      expect(res, contains('out of range'));
      expect(res, contains('0.5'));
      expect(res, contains('2.0'));
    });

    test('invalid mode still rejected (existing gate unchanged)', () async {
      final s = newSession('wave-zoom-badmode');
      AgentService.setRunSessionForTest(s.id);
      expect(
        await AgentService.I.dispatchForTest('browser_desktop', {
          'mode': 'wide',
        }),
        contains('invalid mode'),
      );
    });

    test('read-only and plan gates unchanged (zoom or not)', () async {
      final s = newSession('wave-zoom-gates', mode: 'safe');
      AgentService.setRunSessionForTest(s.id);
      expect(
        await AgentService.I.dispatchForTest('browser_desktop', {
          'mode': 'desktop',
          'zoom': 1.5,
        }),
        contains('READ-ONLY MODE'),
      );
      s.mode = AgentMode.auto.name;
      s.planMode = true;
      expect(
        await AgentService.I.dispatchForTest('browser_desktop', {
          'mode': 'desktop',
          'zoom': 1.5,
        }),
        contains('PLAN MODE'),
      );
      s.planMode = false;
    });

    test('read-only blocks browser_hover (real pointer events)', () async {
      // Audit 2026-09-25: hover dispatches pointerover/mousemove and can
      // trigger menus / JS side effects, so it must be blocked in Read-Only
      // just like click/type — not fall through the deny-list as "reading".
      final s = newSession('wave-ro-hover', mode: 'safe');
      AgentService.setRunSessionForTest(s.id);
      expect(
        await AgentService.I.dispatchForTest('browser_hover', {
          'selector': '#menu',
        }),
        contains('READ-ONLY MODE'),
      );
    });
  });

  group('wave: userZoom clamp (existing setter)', () {
    test('clamps to the 0.5-2.0 readable range', () {
      final tab = BrowserTab(url: 'https://example.com', desktopMode: false);
      tab.userZoom = 9.0;
      expect(tab.userZoom, 2.0);
      tab.userZoom = 0.1;
      expect(tab.userZoom, 0.5);
      tab.userZoom = 1.5;
      expect(tab.userZoom, 1.5);
    });

    test('zoom applied + persisted round-trip + reports value', () async {
      final s = newSession('wave-zoom-roundtrip');
      AgentService.setRunSessionForTest(s.id);
      final tab = BrowserTab(
        url: 'https://zoom.test',
        desktopMode: false,
      );
      AgentService.I.browserTabs.add(tab);

      final frag = await AgentService.I.applyBrowserZoomForTest(tab, 1.5);
      expect(tab.userZoom, 1.5);
      expect(frag, 'userZoom=1.50');

      AgentService.I.clearBrowserTabsForTest();
      AgentService.setRunSessionForTest(s.id);
      expect(await AgentService.I.restoreBrowserTabsForTest(), isTrue);
      expect(AgentService.I.browserTabs, hasLength(1));
      expect(AgentService.I.browserTabs.single.userZoom, 1.5);
    });
  });

}
