import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';

/// Desktop mode must survive every navigation/reload. The bug: the forced
/// viewport was a post-load DOM mutation (evaluateJavascript at
/// onPageFinished), so a fresh document laid out at device width and the
/// site's "better on a large screen" gate fired before we widened it. The
/// desktop UA was also set only once at first load.
///
/// Fix: the forced viewport is a document-start script (re-applied to every
/// new document before page scripts run) and the UA is re-asserted on every
/// page start/finish, both scoped to the tab's WebView.
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

  String kotlinSource() => File(
    'android/app/src/main/kotlin/com/dhanuk/ovidai/OvidWebViewHandler.kt',
  ).readAsStringSync();

  String agentSource() =>
      File('lib/core/agent_service.dart').readAsStringSync();

  group('per-navigation re-assertion (Dart)', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
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
    });

    test('applyDesktopViewport forwards the user agent', () async {
      await AgentService.applyDesktopViewport(
        true,
        tabId: 3,
        webViewIdentifier: 9,
        logicalWidth: 1280,
        userAgent: BrowserTab.desktopUserAgent,
      );
      final payload = calls.single.arguments as Map;
      expect(payload['enabled'], isTrue);
      expect(payload['tabId'], 3);
      expect(payload['webViewIdentifier'], 9);
      expect(payload['logicalWidth'], 1280);
      expect(payload['userAgent'], BrowserTab.desktopUserAgent);
    });

    test('legacy payload (no identity/ua) is unchanged', () async {
      await AgentService.applyDesktopViewport(false);
      expect(calls.single.arguments, {'enabled': false});
    });

    test('UA helper resolves per mode', () {
      final desktop = BrowserTab(url: 'https://w.test', desktopMode: true);
      final mobile = BrowserTab(url: 'https://w.test', desktopMode: false);
      expect(
        AgentService.userAgentForTest(desktop),
        BrowserTab.desktopUserAgent,
      );
      expect(AgentService.userAgentForTest(mobile), BrowserTab.mobileUserAgent);
    });

    test('containerForTab re-asserts desktop settings on page start', () {
      final src = agentSource();
      final start = src.indexOf('onPageStarted:');
      final end = src.indexOf('onProgress:', start);
      final body = src.substring(start, end);
      expect(
        body,
        contains('applyDesktopViewport'),
        reason: 'a new document must get desktop UA/viewport before load',
      );
      expect(body, contains('userAgent'));
    });

    test('page-finish re-assertion still passes the UA', () {
      final src = agentSource();
      final start = src.indexOf('onPageFinished:');
      final end = src.indexOf('onWebResourceError:', start);
      final body = src.substring(start, end);
      expect(body, contains('applyDesktopViewport'));
      expect(body, contains('userAgent'));
    });
  });

  group('document-start viewport (native)', () {
    test('forced viewport is a document-start script, not post-load only', () {
      final src = kotlinSource();
      // The viewport must be registered at document start so it applies to
      // every navigation before page scripts read window.innerWidth.
      expect(src, contains('addDocumentStartJavaScript'));
      final fn = src.substring(
        src.indexOf('private fun applyLogicalViewport('),
      );
      final body = fn.substring(0, fn.indexOf('\n    }') + 1);
      expect(
        body,
        contains('addDocumentStartJavaScript'),
        reason: 'viewport must be injected at document start',
      );
      expect(body, contains('DOCUMENT_START_SCRIPT'));
    });

    test('the forced-width script re-asserts after the parser adds its meta',
        () {
      final src = kotlinSource();
      // Immediate apply is not enough: the page's own viewport meta can be
      // appended by the parser after document-start, so re-assert later too.
      expect(src, contains('DOMContentLoaded'));
    });

    test('native handler sets the UA string from the payload', () {
      final src = kotlinSource();
      expect(src, contains('userAgentString'));
      expect(src, contains('"userAgent"'));
    });

    test('a previously installed viewport script is replaced, not stacked', () {
      final src = kotlinSource();
      expect(src, contains('viewportHandlers'));
      expect(src, contains('.remove()'));
    });

    test('mobile clears a forced width so the page meta wins again', () {
      final src = kotlinSource();
      expect(src, contains('clearViewport'));
    });

    test('forced height rides the same channel payload as width', () {
      final src = kotlinSource();
      expect(src, contains('"logicalHeight"'));
      expect(
        src,
        contains('applyLogicalViewport(webView, logicalWidth, logicalHeight)'),
      );
    });
  });
}
