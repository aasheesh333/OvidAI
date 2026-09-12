import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';

/// Task 2 (browser desktop compatibility): native viewport settings are
/// per-tab. Toggling tab A must send only tab A's identity to the native
/// `ovid/webview` channel and must leave tab B's mode/controller untouched.
/// The native handler must resolve that identity to a single WebView instead
/// of traversing the decor view and applying a global companion static.
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

  group('per-tab native viewport', () {
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

    test('each tab has a distinct identity', () {
      final a = BrowserTab(url: 'https://a.example');
      final b = BrowserTab(url: 'https://b.example');
      expect(a.id, isNot(b.id));
    });

    test('toggling tab A sends A identity and leaves B unchanged', () async {
      final a = BrowserTab(url: 'https://a.example', desktopMode: false);
      final b = BrowserTab(url: 'https://b.example', desktopMode: false);

      await AgentService.I.setTabDesktopMode(a, true, reload: false);
      await pumpEventQueue();

      final payload = calls.last.arguments as Map;
      expect(calls.last.method, 'setDesktopViewport');
      expect(payload['enabled'], isTrue);
      expect(payload['tabId'], a.id);
      expect(payload['tabId'], isNot(b.id));

      expect(a.desktopMode, isTrue);
      expect(b.desktopMode, isFalse, reason: 'tab B must not change');
      expect(b.controller, isNull);
      expect(b.loadedOnce, isFalse);
    });

    test('toggling B after A keeps both tabs independent', () async {
      final a = BrowserTab(url: 'https://a.example', desktopMode: false);
      final b = BrowserTab(url: 'https://b.example', desktopMode: false);

      await AgentService.I.setTabDesktopMode(a, true, reload: false);
      await pumpEventQueue();
      final aPayload = calls.last.arguments as Map;
      expect(aPayload['tabId'], a.id);

      await AgentService.I.setTabDesktopMode(b, true, reload: false);
      await pumpEventQueue();
      final bPayload = calls.last.arguments as Map;
      expect(bPayload['tabId'], b.id);
      expect(bPayload['tabId'], isNot(a.id));

      expect(a.desktopMode, isTrue, reason: 'A keeps desktop mode');
      expect(b.desktopMode, isTrue);
    });

    test('applyDesktopViewport forwards an explicit tab identity', () async {
      await AgentService.applyDesktopViewport(
        true,
        tabId: 7,
        webViewIdentifier: 42,
      );
      final payload = calls.single.arguments as Map;
      expect(payload['enabled'], isTrue);
      expect(payload['tabId'], 7);
      expect(payload['webViewIdentifier'], 42);
    });

    test('applyDesktopViewport without identity keeps the legacy payload', () async {
      await AgentService.applyDesktopViewport(false);
      expect(calls.single.arguments, {'enabled': false});
    });
  });

  group('native handler targets one WebView', () {
    test('drops decor-view traversal and global companion static', () {
      final kotlin = _kotlinSource();
      expect(kotlin, contains('"setDesktopViewport"'));
      expect(kotlin, contains('webViewIdentifier'));
      expect(kotlin, contains('getWebView'));
      expect(kotlin, isNot(contains('traverseAndApply')));
      expect(kotlin, isNot(contains('decorView')));
      expect(kotlin, isNot(contains('companion object')));
      expect(kotlin, isNot(contains('desktopEnabled')));
      expect(kotlin, isNot(contains('lastDesktopViewport')));
    });

    test('desktop uses wide viewport but not overview mode', () {
      final kotlin = _kotlinSource();
      expect(kotlin, contains('useWideViewPort = true'));
      expect(kotlin, contains('loadWithOverviewMode = false'));
    });
  });

  group('per-tab wiring in agent_service', () {
    test('both viewport call sites pass the tab identity', () {
      final src = _agentSource();
      final withIdentity = RegExp(
        r'applyDesktopViewport\(\s*[^;]*?tabId:\s*tab\.id',
        multiLine: true,
        dotAll: true,
      ).allMatches(src);
      expect(
        withIdentity.length,
        greaterThanOrEqualTo(2),
        reason: 'controllerForTab and setTabDesktopMode must target the tab',
      );
    });

    test('controller recreation clears state so no stale settings leak', () {
      final src = _agentSource();
      final start = src.indexOf('Future<void> recreateControllerForDesktopToggle');
      final end = src.indexOf('Future<void> setTabDesktopMode', start);
      final body = src.substring(start, end);
      expect(body, contains('tab.controller = null'));
      expect(body, contains('tab.loadedOnce = false'));
    });
  });
}

String _agentSource() => File('lib/core/agent_service.dart').readAsStringSync();

String _kotlinSource() => File(
  'android/app/src/main/kotlin/com/dhanuk/ovidai/OvidWebViewHandler.kt',
).readAsStringSync();
