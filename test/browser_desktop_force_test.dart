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
    test('probe script reads layout viewport + shim markers as JSON', () {
      final js = AgentService.desktopVerifyScriptForTest();
      expect(js, contains('document.documentElement.clientWidth'));
      expect(js, contains('__ovidDesktopShim'));
      expect(js, contains('__ovidViewportW'));
      expect(js, contains('JSON.stringify'));
      // Never throws inside the page — a probe failure must not break load.
      expect(js, contains('catch(e)'));
    });

    test('probe parses a healthy desktop document', () {
      final probe = AgentService.parseDesktopProbeForTest(
        '{"w":1280,"shim":true,"vw":1280}',
      );
      expect(probe.clientWidth, 1280);
      expect(probe.shim, isTrue);
      expect(probe.viewportW, 1280);
    });

    test('probe tolerates garbage, null and missing keys', () {
      for (final raw in <Object?>[null, 'not json', '{}', '[]', 42]) {
        final probe = AgentService.parseDesktopProbeForTest(raw);
        expect(probe.clientWidth, 0);
        expect(probe.shim, isFalse);
        expect(probe.viewportW, 0);
      }
    });
  });

  group('repair gating', () {
    test('no forced width requested → never repair', () {
      expect(
        AgentService.desktopRepairNeededForTest(
          expectedWidth: null,
          clientWidth: 412,
          shim: false,
          viewportW: 0,
        ),
        isFalse,
      );
    });

    test('mobile-width document on a desktop tab → repair', () {
      expect(
        AgentService.desktopRepairNeededForTest(
          expectedWidth: 1280,
          clientWidth: 412,
          shim: true,
          viewportW: 1280,
        ),
        isTrue,
      );
    });

    test('missing shim marker → repair even at desktop width', () {
      expect(
        AgentService.desktopRepairNeededForTest(
          expectedWidth: 1280,
          clientWidth: 1280,
          shim: false,
          viewportW: 1280,
        ),
        isTrue,
      );
    });

    test('viewport script ran with wrong width → repair', () {
      expect(
        AgentService.desktopRepairNeededForTest(
          expectedWidth: 1280,
          clientWidth: 980,
          shim: true,
          viewportW: 980,
        ),
        isTrue,
      );
    });

    test('healthy desktop document → no repair', () {
      expect(
        AgentService.desktopRepairNeededForTest(
          expectedWidth: 1280,
          clientWidth: 1280,
          shim: true,
          viewportW: 1280,
        ),
        isFalse,
      );
    });

    test('scrollbar-level slack does not trigger repair', () {
      expect(
        AgentService.desktopRepairNeededForTest(
          expectedWidth: 1280,
          clientWidth: 1265,
          shim: true,
          viewportW: 1280,
        ),
        isFalse,
      );
    });

    test('explicit browser_resize width is honored the same way', () {
      // 800 forced, document at 800 → fine.
      expect(
        AgentService.desktopRepairNeededForTest(
          expectedWidth: 800,
          clientWidth: 800,
          shim: true,
          viewportW: 800,
        ),
        isFalse,
      );
      // 800 forced, document fell back to ~600 → repair.
      expect(
        AgentService.desktopRepairNeededForTest(
          expectedWidth: 800,
          clientWidth: 600,
          shim: true,
          viewportW: 800,
        ),
        isTrue,
      );
    });

    test('new tabs start with a fresh repair budget', () {
      final tab = BrowserTab(url: 'https://w.test', desktopMode: true);
      expect(tab.desktopRepairAttempts, 0);
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
              };
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('ovid/webview'), null);
      });
    });

    test('desktop tab repair sends logicalWidth 1280', () async {
      final tab = BrowserTab(url: 'https://w.test', desktopMode: true);
      final ok = await AgentService.I.repairDesktopViewport(tab);
      expect(ok, isTrue);
      final call = calls.singleWhere((c) => c.method == 'repairDesktop');
      expect(call.arguments['logicalWidth'], 1280);
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

    test('explicit resize width rides the repair call', () async {
      final tab = BrowserTab(url: 'https://w.test', desktopMode: false)
        ..viewportWidth = 800;
      final ok = await AgentService.I.repairDesktopViewport(tab);
      expect(ok, isTrue);
      final call = calls.singleWhere((c) => c.method == 'repairDesktop');
      expect(call.arguments['logicalWidth'], 800);
    });
  });
}
