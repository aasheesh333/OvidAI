import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';

/// Forced desktop size, persistent across refresh: when desktop mode is on,
/// the layout viewport must actually be the forced width in the LIVE
/// document — not just requested at toggle time. The Dart verifier probes
/// every page finish and repairs via the native `repairDesktop` channel
/// when the forcing did not stick.
///
/// The probe is deliberately NOT self-referential: it reads the REAL layout
/// viewport (`documentElement.clientWidth/clientHeight`) and never the
/// shim's own markers (`__ovidDesktopShim`, `__ovidViewportW`) or the
/// shim-overridden `window.innerWidth` — those echo our own injection, so a
/// verifier built on them could never fail.
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

  group('desktop verify probe', () {
    test('probe reads the real layout viewport, never shim markers', () {
      final js = AgentService.desktopVerifyScriptForTest();
      expect(js, contains('document.documentElement.clientWidth'));
      expect(js, contains('document.documentElement.clientHeight'));
      expect(js, contains('JSON.stringify'));
      // Never throws inside the page — a probe failure must not break load.
      expect(js, contains('catch(e)'));
    });

    test('probe is not circular: no shim markers, no innerWidth', () {
      final js = AgentService.desktopVerifyScriptForTest();
      expect(js, isNot(contains('__ovidDesktopShim')));
      expect(js, isNot(contains('__ovidViewportW')));
      expect(js, isNot(contains('innerWidth')));
      expect(js, isNot(contains('innerHeight')));
    });

    test('probe parses a healthy desktop document', () {
      final probe = AgentService.parseDesktopProbeForTest(
        '{"w":1280,"h":800}',
      );
      expect(probe.clientWidth, 1280);
      expect(probe.clientHeight, 800);
    });

    test('probe tolerates garbage, null and missing keys', () {
      for (final raw in <Object?>[null, 'not json', '{}', '[]', 42]) {
        final probe = AgentService.parseDesktopProbeForTest(raw);
        expect(probe.clientWidth, 0);
        expect(probe.clientHeight, 0);
      }
    });
  });

  group('repair gating', () {
    test('no forced width requested → never repair', () {
      expect(
        AgentService.desktopRepairNeededForTest(
          expectedWidth: null,
          expectedHeight: null,
          clientWidth: 412,
          clientHeight: 900,
        ),
        isFalse,
      );
    });

    test('mobile-width document on a desktop tab → repair', () {
      expect(
        AgentService.desktopRepairNeededForTest(
          expectedWidth: 1280,
          expectedHeight: 800,
          clientWidth: 412,
          clientHeight: 900,
        ),
        isTrue,
      );
    });

    test('healthy desktop document → no repair', () {
      expect(
        AgentService.desktopRepairNeededForTest(
          expectedWidth: 1280,
          expectedHeight: 800,
          clientWidth: 1280,
          clientHeight: 700,
        ),
        isFalse,
      );
    });

    test('scrollbar-level slack does not trigger repair', () {
      expect(
        AgentService.desktopRepairNeededForTest(
          expectedWidth: 1280,
          expectedHeight: 800,
          clientWidth: 1265,
          clientHeight: 700,
        ),
        isFalse,
      );
    });

    test('explicit browser_resize width is honored the same way', () {
      // 800 forced, document at 800 → fine.
      expect(
        AgentService.desktopRepairNeededForTest(
          expectedWidth: 800,
          expectedHeight: 600,
          clientWidth: 800,
          clientHeight: 600,
        ),
        isFalse,
      );
      // 800 forced, document fell back to ~600 → repair.
      expect(
        AgentService.desktopRepairNeededForTest(
          expectedWidth: 800,
          expectedHeight: 600,
          clientWidth: 600,
          clientHeight: 600,
        ),
        isTrue,
      );
    });

    test('device-height layout does not trigger repair on its own', () {
      // The layout HEIGHT always follows the device screen; only the
      // shim's JS-visible innerHeight carries the forced height. A tall
      // phone (clientHeight 900 vs forced 800) must not repair a tab whose
      // WIDTH is correctly forced.
      expect(
        AgentService.desktopRepairNeededForTest(
          expectedWidth: 1280,
          expectedHeight: 800,
          clientWidth: 1280,
          clientHeight: 900,
        ),
        isFalse,
      );
    });

    test('new tabs start with a fresh repair budget', () {
      final tab = BrowserTab(url: 'https://w.test', desktopMode: true);
      expect(tab.desktopRepairAttempts, 0);
    });
  });

  group('forced-size routing', () {
    test('desktop mode pins 1280x800, mobile clears both', () async {
      final tab = BrowserTab(url: 'https://w.test', desktopMode: false);
      await AgentService.I.setTabDesktopMode(tab, true, reload: false);
      expect(AgentService.viewportWidthForTest(tab), 1280);
      expect(AgentService.viewportHeightForTest(tab), 800);
      await AgentService.I.setTabDesktopMode(tab, false, reload: false);
      expect(AgentService.viewportWidthForTest(tab), isNull);
      expect(AgentService.viewportHeightForTest(tab), isNull);
    });

    test('explicit resize wins over the desktop default', () {
      final tab = BrowserTab(url: 'https://w.test', desktopMode: true)
        ..viewportWidth = 1440
        ..viewportHeight = 900;
      expect(AgentService.viewportWidthForTest(tab), 1440);
      expect(AgentService.viewportHeightForTest(tab), 900);
    });
  });

  group('native repairDesktop channel', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('ovid/webview'), (
            call,
          ) async {
            calls.add(call);
            if (call.method == 'repairDesktop') {
              return {
                'applied': true,
                'webViewFound': true,
                'tabId': call.arguments['tabId'],
                'logicalWidth': call.arguments['logicalWidth'],
                'logicalHeight': call.arguments['logicalHeight'],
              };
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('ovid/webview'), null);
      });
    });

    test('desktop tab repair sends logicalWidth 1280 + logicalHeight 800',
        () async {
      final tab = BrowserTab(url: 'https://w.test', desktopMode: true);
      final ok = await AgentService.I.repairDesktopViewport(tab);
      expect(ok, isTrue);
      final call = calls.singleWhere((c) => c.method == 'repairDesktop');
      expect(call.arguments['logicalWidth'], 1280);
      expect(call.arguments['logicalHeight'], 800);
      expect(call.arguments['tabId'], tab.id);
    });

    test('mobile tab repair is a no-op without a channel call', () async {
      final tab = BrowserTab(url: 'https://w.test', desktopMode: false);
      final ok = await AgentService.I.repairDesktopViewport(tab);
      expect(ok, isFalse);
      expect(
        calls.where((c) => c.method == 'repairDesktop'),
        isEmpty,
      );
    });

    test('explicit resize size rides the repair call', () async {
      final tab = BrowserTab(url: 'https://w.test', desktopMode: false)
        ..viewportWidth = 800
        ..viewportHeight = 600;
      final ok = await AgentService.I.repairDesktopViewport(tab);
      expect(ok, isTrue);
      final call = calls.singleWhere((c) => c.method == 'repairDesktop');
      expect(call.arguments['logicalWidth'], 800);
      expect(call.arguments['logicalHeight'], 600);
    });
  });
}
