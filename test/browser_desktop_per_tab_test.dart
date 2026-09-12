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

    test('desktop branch uses wide viewport without overview; mobile is inverse', () {
      final branches = _applySettingsBranches(_kotlinSource());
      expect(
        branches,
        isNotNull,
        reason: 'applySettings must have desktop/mobile branches',
      );
      final (desktop, mobile) = branches!;

      // Desktop must be pinned INSIDE the `if (desktop)` block. A whole-file
      // substring check passes even when the branches are swapped, because the
      // inverse literals also exist in the mobile branch.
      expect(
        desktop,
        matches(RegExp(r'useWideViewPort\s*=\s*true')),
        reason: 'desktop must enable the wide viewport',
      );
      expect(
        desktop,
        matches(RegExp(r'loadWithOverviewMode\s*=\s*false')),
        reason: 'desktop must NOT auto-fit (overview mode)',
      );
      expect(
        desktop,
        matches(RegExp(r'LayoutAlgorithm\.NORMAL')),
        reason: 'desktop layout algorithm',
      );

      expect(
        mobile,
        matches(RegExp(r'useWideViewPort\s*=\s*false')),
        reason: 'mobile must not use the wide viewport',
      );
      expect(
        mobile,
        matches(RegExp(r'loadWithOverviewMode\s*=\s*true')),
        reason: 'mobile restores overview mode',
      );
      expect(
        mobile,
        matches(RegExp(r'LayoutAlgorithm\.NARROW_COLUMNS')),
        reason: 'mobile layout algorithm',
      );
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

/// Returns the `(desktop, mobile)` bodies of `applySettings`' `if/else` so the
/// test pins which flags belong to which mode. Whole-file substring checks
/// cannot catch a branch swap (both literals appear somewhere in the file).
(String, String)? _applySettingsBranches(String kotlin) {
  final fnStart = kotlin.indexOf('private fun applySettings(');
  if (fnStart == -1) return null;
  final fnEnd = kotlin.indexOf('private fun ', fnStart + 1);
  final body = kotlin.substring(fnStart, fnEnd == -1 ? kotlin.length : fnEnd);

  final ifIndex = body.indexOf('if (');
  if (ifIndex == -1) return null;
  final desktopOpen = body.indexOf('{', ifIndex);
  if (desktopOpen == -1) return null;
  final desktopClose = _matchingBrace(body, desktopOpen);
  if (desktopClose == -1) return null;
  final desktop = body.substring(desktopOpen + 1, desktopClose);

  final elseIndex = body.indexOf('else', desktopClose);
  if (elseIndex == -1) return null;
  final mobileOpen = body.indexOf('{', elseIndex);
  if (mobileOpen == -1) return null;
  final mobileClose = _matchingBrace(body, mobileOpen);
  if (mobileClose == -1) return null;
  final mobile = body.substring(mobileOpen + 1, mobileClose);

  return (desktop, mobile);
}

/// Index of the `}` matching the `{` at [openIndex], or -1 when unbalanced.
int _matchingBrace(String src, int openIndex) {
  var depth = 0;
  for (var i = openIndex; i < src.length; i++) {
    final c = src[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}
