import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Browser tabs are per-session: a new session must never show another
/// session's tabs, and Google sign-in must leave the embedded WebView
/// (Google blocks OAuth there) for the system browser.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    app.sessions.clear();
    app.activeSessionId = null;
    AgentService.I.clearBrowserTabsForTest();
  });

  tearDown(() {
    AgentService.I.clearBrowserTabsForTest();
    AgentService.setRunSessionForTest('');
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  String envelope(List<String> urls) => jsonEncode({
    'version': 2,
    'activeIndex': 0,
    'tabs': [
      for (final u in urls) {'url': u},
    ],
  });

  ChatSession session(String id) {
    final app = AppState.I;
    final s = ChatSession(id: id, title: 'Title of $id', model: 'm');
    app.sessions.insert(0, s);
    app.activeSessionId = s.id;
    return s;
  }

  test('prewarm restores only the launch-active session tabs', () async {
    SharedPreferences.setMockInitialValues({
      // Stale global copy from another session — must never leak in.
      'ovid_browser_tabs_v2': envelope(['https://old-session.example/']),
      'ovid_browser_session_v2_sess-b': envelope(['https://b.example/']),
    });
    session('sess-b');

    await AgentService.I.prewarmBrowser();

    expect(
      AgentService.I.browserTabs.map((t) => t.url),
      ['https://b.example/'],
    );
  });

  test('prewarm falls back to global keys only with no per-session data',
      () async {
    SharedPreferences.setMockInitialValues({
      'ovid_browser_tabs_v2': envelope(['https://legacy.example/']),
    });
    session('sess-fresh');

    await AgentService.I.prewarmBrowser();

    expect(
      AgentService.I.browserTabs.map((t) => t.url),
      ['https://legacy.example/'],
    );
  });

  test('prewarm gives a fresh session its own default tab', () async {
    SharedPreferences.setMockInitialValues({});
    session('sess-new');

    await AgentService.I.prewarmBrowser();

    final urls = AgentService.I.browserTabs.map((t) => t.url).toList();
    expect(urls, hasLength(1));
    expect(urls.single.contains('old-session'), isFalse);
  });

  test('Google OAuth hosts open outside the embedded WebView', () {
    expect(
      AgentService.googleAuthNeedsExternalBrowser(
        Uri.parse('https://accounts.google.com/o/oauth2/v2/auth?x=1'),
      ),
      isTrue,
    );
    expect(
      AgentService.googleAuthNeedsExternalBrowser(
        Uri.parse('https://sub.accounts.google.com/signin'),
      ),
      isTrue,
    );
    expect(
      AgentService.googleAuthNeedsExternalBrowser(
        Uri.parse('https://www.google.com/search?q=x'),
      ),
      isFalse,
    );
    expect(
      AgentService.googleAuthNeedsExternalBrowser(
        Uri.parse('https://accounts.google.com.evil.example/'),
      ),
      isFalse,
    );
    expect(
      AgentService.googleAuthNeedsExternalBrowser(
        Uri.parse('https://example.com/'),
      ),
      isFalse,
    );
  });
}
