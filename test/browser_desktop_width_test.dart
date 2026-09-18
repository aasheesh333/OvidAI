import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';

/// Desktop mode must force a wide layout viewport (1280px), not just swap
/// the user agent: pages whose viewport meta pins `width=device-width`
/// otherwise keep laying out at phone width, so `window.innerWidth` stays
/// mobile-size and sites gate with "better on large screen".
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

  group('desktop layout viewport width', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
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
    });

    test('toggling desktop on sends logicalWidth 1280', () async {
      final tab = BrowserTab(url: 'https://w.test', desktopMode: false);

      await AgentService.I.setTabDesktopMode(tab, true, reload: false);
      await pumpEventQueue();

      final payload = calls.last.arguments as Map;
      expect(calls.last.method, 'setDesktopViewport');
      expect(payload['enabled'], isTrue);
      expect(payload['tabId'], tab.id);
      expect(payload['logicalWidth'], 1280);
    });

    test('toggling desktop off clears the forced width', () async {
      final tab = BrowserTab(url: 'https://w.test', desktopMode: false);

      await AgentService.I.setTabDesktopMode(tab, true, reload: false);
      await pumpEventQueue();
      await AgentService.I.setTabDesktopMode(tab, false, reload: false);
      await pumpEventQueue();

      final payload = calls.last.arguments as Map;
      expect(payload['enabled'], isFalse);
      expect(payload.containsKey('logicalWidth'), isFalse);
      expect(tab.desktopMode, isFalse);
    });

    test('effective width: desktop defaults 1280, mobile null, resize wins',
        () {
      expect(
        AgentService.viewportWidthForTest(
          BrowserTab(url: 'https://w.test', desktopMode: true),
        ),
        1280,
      );
      expect(
        AgentService.viewportWidthForTest(
          BrowserTab(url: 'https://w.test', desktopMode: false),
        ),
        isNull,
      );
      final explicit = BrowserTab(url: 'https://w.test', desktopMode: true)
        ..viewportWidth = 390;
      expect(AgentService.viewportWidthForTest(explicit), 390);
      final mobileExplicit =
          BrowserTab(url: 'https://w.test', desktopMode: false)
            ..viewportWidth = 800;
      expect(AgentService.viewportWidthForTest(mobileExplicit), 800);
    });
  });
}
