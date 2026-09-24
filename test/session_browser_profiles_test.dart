import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/session_browser_profiles.dart';
import 'package:ovid_ai/core/state.dart';

/// Per-session browser identity + restart-sharing contract.
///
/// The user-facing rule this file pins down:
///   * every chat session browses in its OWN profile (its own cookies/logins),
///   * the profile name is derived from the session id, so isolation survives
///     a restart for free,
///   * at restart the accumulated logins are merged ONCE into every session,
///   * when the WebView has no profile support nothing breaks (the tab falls
///     back to the shared jar).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('BrowserProfileId', () {
    test('derives a stable, provider-safe name from a session id', () {
      expect(
        BrowserProfileId.forSession('1790017831140638'),
        'ovid_s_1790017831140638',
      );
    });

    test('sanitizes ids with separators and collapses runs', () {
      expect(
        BrowserProfileId.forSession('aasheesh/ovid:chat 42'),
        'ovid_s_aasheesh_ovid_chat_42',
      );
      expect(BrowserProfileId.forSession('...'), 'ovid_s_default');
      expect(BrowserProfileId.forSession(''), 'ovid_s_default');
    });

    test('is deterministic so a session gets its jar back after a restart', () {
      const id = 'hoplite/gortyn-77773150';
      expect(BrowserProfileId.forSession(id), BrowserProfileId.forSession(id));
    });

    test('different sessions never collide', () {
      expect(
        BrowserProfileId.forSession('s1'),
        isNot(BrowserProfileId.forSession('s2')),
      );
    });

    test('caps the length and never ends with a separator', () {
      final name = BrowserProfileId.forSession('x' * 200);
      expect(
        name.length,
        lessThanOrEqualTo(
          BrowserProfileId.prefix.length + BrowserProfileId.maxLength,
        ),
      );
      expect(name.endsWith('_'), isFalse);
    });
  });

  group('CookieMerge', () {
    test('splits a cookie header into single name=value cookies', () {
      expect(CookieMerge.pairs('a=1; b=2;c=3'), ['a=1', 'b=2', 'c=3']);
      expect(CookieMerge.pairs('   '), isEmpty);
      expect(CookieMerge.pairs(null), isEmpty);
      // Attributes without `=` are dropped rather than written as cookies.
      expect(CookieMerge.pairs('a=1; Secure'), ['a=1']);
    });

    test('merge keeps the first value for a duplicate name', () {
      expect(CookieMerge.merge(['a=1; b=2', 'a=9; c=3']), 'a=1; b=2; c=3');
    });

    test('merge skips null/empty sources', () {
      expect(CookieMerge.merge([null, '', 'sid=42']), 'sid=42');
    });

    test('originOf reduces a URL to scheme+host only', () {
      expect(
        CookieMerge.originOf('https://accounts.google.com/o/oauth2?q=secret#x'),
        'https://accounts.google.com/',
      );
      expect(
        CookieMerge.originOf('http://localhost:8080/app'),
        'http://localhost:8080/',
      );
      // Never a path/query — those can carry session-specific data.
      expect(CookieMerge.originOf('https://a.test/'), 'https://a.test/');
    });

    test('originOf rejects non-web schemes and garbage', () {
      expect(CookieMerge.originOf('ovid://preview'), isNull);
      expect(CookieMerge.originOf('file:///sdcard/x.html'), isNull);
      expect(CookieMerge.originOf('about:blank'), isNull);
      expect(CookieMerge.originOf(''), isNull);
    });
  });

  group('BrowserShareReport', () {
    test('nothing() explains itself instead of claiming success', () {
      const report = BrowserShareReport.nothing(
        'No browsed sites recorded yet.',
      );
      expect(report.applied, isFalse);
      expect(report.copied, 0);
      expect(report.message, 'No browsed sites recorded yet.');
    });

    test('applied reports what was shared', () {
      const report = BrowserShareReport(
        applied: true,
        profiles: 3,
        urls: 7,
        copied: 12,
      );
      expect(report.message, contains('3 sessions'));
      expect(report.message, contains('7 sites'));
    });
  });

  group('SessionBrowserProfiles isolation contract', () {
    test('shareOnRestart refuses to run for a single session', () async {
      final report = await SessionBrowserProfiles.I.shareOnRestart(
        sessionIds: ['only-one'],
      );
      expect(report.applied, isFalse);
      expect(report.reason, contains('Only one session'));
    });

    test('profile binding degrades safely with no platform channel', () async {
      // No Android channel in the test binding: must return false, not throw.
      final applied = await SessionBrowserProfiles.I.bind(
        profileName: BrowserProfileId.forSession('s1'),
        webViewIdentifier: null,
      );
      expect(applied, isFalse);
    });

    test('origin bookkeeping is a no-op for non-web URLs', () async {
      await SessionBrowserProfiles.I.rememberOrigin('ovid://preview');
      expect(await SessionBrowserProfiles.I.rememberedOrigins(), isEmpty);
    });

    test(
      'visit records are per session — one chat cannot read another',
      () async {
        await SessionBrowserProfiles.I.rememberOrigin(
          'https://github.com/a/b',
          sessionId: 's1',
        );
        await SessionBrowserProfiles.I.rememberOrigin(
          'https://mail.google.com',
          sessionId: 's2',
        );
        expect(
          await SessionBrowserProfiles.I.rememberedOrigins(sessionId: 's1'),
          ['https://github.com/'],
        );
        expect(
          await SessionBrowserProfiles.I.rememberedOrigins(sessionId: 's2'),
          ['https://mail.google.com/'],
        );
        expect(
          await SessionBrowserProfiles.I.rememberedOrigins(sessionId: 's3'),
          isEmpty,
        );
        // Only the merge helper unions them (it exists purely so the restart
        // login copy knows which origins to replay).
        final all = await SessionBrowserProfiles.I.allRememberedOrigins();
        expect(all.toSet(), {
          'https://github.com/',
          'https://mail.google.com/',
        });
      },
    );

    test('forgetting one session leaves the others intact', () async {
      await SessionBrowserProfiles.I.rememberOrigin(
        'https://a.com',
        sessionId: 's1',
      );
      await SessionBrowserProfiles.I.rememberOrigin(
        'https://b.com',
        sessionId: 's2',
      );
      await SessionBrowserProfiles.I.forgetOrigins(sessionId: 's1');
      expect(
        await SessionBrowserProfiles.I.rememberedOrigins(sessionId: 's1'),
        isEmpty,
      );
      expect(
        await SessionBrowserProfiles.I.rememberedOrigins(sessionId: 's2'),
        ['https://b.com/'],
      );
      await SessionBrowserProfiles.I.forgetOrigins();
      expect(await SessionBrowserProfiles.I.allRememberedOrigins(), isEmpty);
    });
  });

  group('profile deletion queue', () {
    const channel = MethodChannel('ovid/webview');

    void mock(Future<Object?> Function(MethodCall) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('a delete refused by a live WebView is retried next launch', () async {
      var deleted = false;
      var listed = <String>['ovid_s_s1'];
      mock((call) async {
        switch (call.method) {
          case 'profilesSupported':
            return true;
          case 'listProfiles':
            return listed;
          case 'deleteProfile':
            return deleted;
        }
        return null;
      });
      // An earlier test may have cached "unsupported" (no channel); a refresh
      // makes this test independent of order.
      await SessionBrowserProfiles.I.probe(refresh: true);

      // The chat was deleted while its Browser screen still held the WebView:
      // the platform refuses and the name is queued instead of being lost.
      expect(
        await SessionBrowserProfiles.I.deleteProfile('ovid_s_s1'),
        isFalse,
      );

      // Next launch, nothing holds the profile any more.
      deleted = true;
      listed = <String>[];
      expect(await SessionBrowserProfiles.I.purgePendingDeletes(), 1);
      // The queue is drained — no repeat work on the launch after that.
      expect(await SessionBrowserProfiles.I.purgePendingDeletes(), 0);
    });

    test('deleting a profile that never existed is not queued', () async {
      mock((call) async {
        switch (call.method) {
          case 'profilesSupported':
            return true;
          case 'listProfiles':
            return <String>[];
          case 'deleteProfile':
            return false;
        }
        return null;
      });
      await SessionBrowserProfiles.I.probe(refresh: true);
      expect(
        await SessionBrowserProfiles.I.deleteProfile('ovid_s_ghost'),
        isFalse,
      );
      expect(await SessionBrowserProfiles.I.purgePendingDeletes(), 0);
    });
  });

  group('wiring (source contract)', () {
    late String agentSrc;

    setUpAll(() {
      agentSrc = File('lib/core/agent_service.dart').readAsStringSync();
    });

    test('the profile is bound BEFORE any pre-navigation step', () {
      final start = agentSrc.indexOf(
        'Future<void> _bindProfileThenLoad(BrowserTab tab) async',
      );
      expect(start, greaterThan(-1));
      // Slice that method's body only, so an unrelated helper's ordering can
      // never satisfy this assertion.
      final body = agentSrc.substring(start, start + 2400);
      final bindIndex = body.indexOf('await ensureTabProfile(tab);');
      expect(bindIndex, greaterThan(-1));
      // `setProfile` is rejected once a WebView has evaluated JavaScript, and
      // the mobile viewport helper does exactly that — so the bind must come
      // first, ahead of the user agent, the viewport and the load.
      for (final later in <String>[
        'setUserAgent(BrowserTab.',
        'applyDesktopViewport(',
        'await controller.loadRequest(Uri.parse(tab.url));',
      ]) {
        final at = body.indexOf(later);
        expect(at, greaterThan(bindIndex), reason: later);
      }
    });

    test('navigateTab binds the profile before its own load', () {
      final start = agentSrc.indexOf(
        'Future<void> navigateTab(BrowserTab tab, String url) async',
      );
      expect(start, greaterThan(-1));
      // Window sized for the whole body: navigateTab grew a scheme guard (and
      // its SECURITY comment) ahead of the profile bind, so a 1200-char window
      // stopped before loadRequest and the ordering assertion silently tested
      // nothing (loadIndex == -1).
      final body = agentSrc.substring(start, start + 3000);
      final bindIndex = body.indexOf('await ensureTabProfile(tab);');
      final loadIndex = body.indexOf(
        'await controller.loadRequest(Uri.parse(url));',
      );
      expect(bindIndex, greaterThan(-1));
      expect(loadIndex, greaterThan(bindIndex));
      // The scheme guard must run BEFORE anything else, so a refused URL is
      // never bound, recorded, or loaded.
      final guardIndex = body.indexOf('if (!isLoadableTabUrl(url)) return;');
      expect(guardIndex, greaterThan(-1));
      expect(guardIndex, lessThan(bindIndex));
      expect(guardIndex, lessThan(loadIndex));
    });

    test('every navigation goes through navigateTab', () {
      // A bare loadRequest outside the two owning helpers would skip the
      // profile binding and silently leak another session's cookies in.
      final allowed = <String>[
        'Future<void> _bindProfileThenLoad(BrowserTab tab) async',
        'Future<void> navigateTab(BrowserTab tab, String url) async',
      ];
      for (final needle in allowed) {
        expect(agentSrc.contains(needle), isTrue, reason: needle);
      }
      final rawLoads = RegExp(
        r'\.loadRequest\(Uri\.parse',
      ).allMatches(agentSrc).length;
      // _bindProfileThenLoad + navigateTab only.
      expect(rawLoads, 2);
    });

    test('tabs carry the owning session id', () {
      expect(agentSrc.contains('BrowserTab(url: url, sessionId: key)'), isTrue);
      expect(
        agentSrc.contains(
          'BrowserTab(url: _defaultBrowserUrl, sessionId: sessionId)',
        ),
        isTrue,
      );
    });

    test('the system prompt tells the model the browser is per session', () {
      expect(
        agentSrc.contains(
          'Browser isolation: the Browser panel is per session too',
        ),
        isTrue,
      );
      expect(
        agentSrc.contains(
          'Studio isolation: the repo, branch and open Studio files are per session',
        ),
        isTrue,
      );
    });

    test('cookies clear covers every session profile', () {
      expect(
        agentSrc.contains('SessionBrowserProfiles.I.clearCookies('),
        isTrue,
      );
    });

    test('deleting a chat drops its tab state, visit record and profile', () {
      final start = agentSrc.indexOf(
        'AppState.I.onSessionDeleted = (sessionId)',
      );
      expect(start, greaterThan(-1));
      final body = agentSrc.substring(start, start + 1200);
      expect(body.contains('_sessionBrowsers.remove(sessionId)'), isTrue);
      expect(body.contains('_sessionActiveTab.remove(sessionId)'), isTrue);
      expect(body.contains('_dropSessionBrowserPrefs(sessionId)'), isTrue);
      expect(body.contains('SessionBrowserProfiles.I.deleteProfile('), isTrue);
      final helper = agentSrc.indexOf('Future<void> _dropSessionBrowserPrefs(');
      expect(helper, greaterThan(-1));
      final helperBody = agentSrc.substring(helper, helper + 900);
      expect(
        helperBody.contains(r"$_kBrowserSessionV2Prefix$sessionId"),
        isTrue,
      );
      expect(
        helperBody.contains('forgetOrigins(sessionId: sessionId)'),
        isTrue,
      );
    });

    test('restart sharing NEVER carries tabs or visit history', () {
      // The only cross-session readers are the restart login merge and the
      // manual "share now" — both in SessionDataSharing, and both touch
      // cookies/repo only.
      final sharingSrc = File(
        'lib/core/session_data_sharing.dart',
      ).readAsStringSync();
      expect(sharingSrc.contains('shareOnRestart'), isTrue);
      for (final forbidden in <String>[
        'browserTabs',
        'BrowserTab(',
        'activeTabIndex',
        'restoreBrowserTabs',
      ]) {
        expect(
          sharingSrc.contains(forbidden),
          isFalse,
          reason: 'the restart merge must not move tab state: $forbidden',
        );
      }
      // Each session keeps its own tab bucket; the session keys are the only
      // thing the restore path reads.
      expect(agentSrc.contains(r'$_kBrowserSessionV2Prefix$sessionId'), isTrue);
      // Every visit record is written with the tab's OWN session id.
      expect(
        RegExp(
          r"rememberOrigin\(\s*url,\s*sessionId: tab\.sessionId",
        ).allMatches(agentSrc).length,
        greaterThanOrEqualTo(2),
      );
    });
  });

  group('settings + startup wiring', () {
    late String stateSrc;
    late String settingsSrc;

    setUpAll(() {
      stateSrc = File('lib/core/state.dart').readAsStringSync();
      settingsSrc = File('lib/ui/settings_screen.dart').readAsStringSync();
    });

    test('both sharing switches persist and default ON', () {
      expect(
        stateSrc.contains(
          "_kShareStudioOnRestart = 'ovid_share_studio_on_restart'",
        ),
        isTrue,
      );
      expect(
        stateSrc.contains(
          "_kShareBrowserOnRestart = 'ovid_share_browser_on_restart'",
        ),
        isTrue,
      );
      expect(
        stateSrc.contains(
          'shareStudioOnRestart = prefs.getBool(_kShareStudioOnRestart) ?? true',
        ),
        isTrue,
      );
      // SECURITY (2026-09-24): the cross-session cookie merge defaults OFF.
      // Merging every remembered origin's cookies into every session profile
      // on each launch contradicted the per-session isolation the WebView
      // profiles exist to provide, and let a prompt-injected agent in one chat
      // act on sites the user logged into in a different chat.
      expect(
        stateSrc.contains(
          'shareBrowserOnRestart = prefs.getBool(_kShareBrowserOnRestart) ?? false',
        ),
        isTrue,
      );
      expect(AppState.createForTest().shareBrowserOnRestart, isFalse);
    });

    test('the restart merge runs as a startup task', () {
      expect(stateSrc.contains("id: 'session.shareOnRestart'"), isTrue);
      expect(stateSrc.contains('SessionDataSharing.I.runOnStartup'), isTrue);
    });

    test('Settings no longer exposes the restart-sharing rows', () {
      // Issue 6: the _SessionDataSharingTile rows were removed from
      // Settings — merges now happen at restart only. The feature itself
      // stays alive (SessionDataSharing.I.runOnStartup); only the rows are
      // gone.
      expect(settingsSrc.contains('Share browser logins on restart'), isFalse);
      expect(settingsSrc.contains('Share Studio repo on restart'), isFalse);
      expect(settingsSrc.contains('Share session data now'), isFalse);
      expect(settingsSrc.contains('_SessionDataSharingTile'), isFalse);
    });
  });
}
