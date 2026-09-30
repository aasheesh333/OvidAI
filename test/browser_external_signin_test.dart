import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/ui/browser_screen.dart';

/// Owner screenshot (2026-09-27): the in-app browser showed Google's sign-in
/// wall with the "provider blocks embedded sign-in" banner. The banner itself
/// is correct — Google refuses WebView logins — but the host table behind it
/// treated `facebook.com`, `x.com`, `twitter.com` and `linkedin.com` as
/// ALWAYS-sign-in origins, so the same scary banner fired over ordinary
/// timelines, profiles and posts.
///
/// Contract: dedicated auth origins warn on any path; general-purpose social
/// origins warn only on a real sign-in path.
void main() {
  group('always-sign-in origins warn on any path', () {
    test('Google accounts', () {
      expect(
        externalSignInProvider('https://accounts.google.com/signin'),
        'Google',
      );
      expect(
        externalSignInProvider('https://accounts.google.com/v3/signin/identifier'),
        'Google',
      );
      expect(externalSignInProvider('https://accounts.google.com/'), 'Google');
    });

    test('Microsoft, Apple', () {
      expect(
        externalSignInProvider('https://login.microsoftonline.com/common/oauth2'),
        'Microsoft',
      );
      expect(externalSignInProvider('https://login.live.com/'), 'Microsoft');
      expect(
        externalSignInProvider('https://appleid.apple.com/auth/authorize'),
        'Apple',
      );
      expect(externalSignInProvider('https://id.apple.com/'), 'Apple');
    });

    test('subdomains of an auth origin still match', () {
      expect(
        externalSignInProvider('https://mail.accounts.google.com/x'),
        'Google',
      );
    });
  });

  group('social origins warn ONLY on sign-in paths', () {
    test('sign-in paths are flagged', () {
      expect(externalSignInProvider('https://www.facebook.com/login.php'), 'Facebook');
      expect(externalSignInProvider('https://m.facebook.com/login'), 'Facebook');
      expect(externalSignInProvider('https://www.linkedin.com/login'), 'LinkedIn');
      expect(
        externalSignInProvider('https://www.linkedin.com/oauth/v2/authorize'),
        'LinkedIn',
      );
      expect(externalSignInProvider('https://x.com/i/flow/login'), 'X');
      expect(externalSignInProvider('https://twitter.com/login'), 'X');
      expect(
        externalSignInProvider('https://www.facebook.com/dialog/oauth?client_id=1'),
        'Facebook',
      );
    });

    test('ordinary pages are NOT flagged (the regression)', () {
      expect(externalSignInProvider('https://x.com/elonmusk'), isNull);
      expect(
        externalSignInProvider('https://x.com/user/status/1234567890'),
        isNull,
      );
      expect(externalSignInProvider('https://twitter.com/home'), isNull);
      expect(
        externalSignInProvider('https://www.facebook.com/some.group/posts'),
        isNull,
      );
      expect(
        externalSignInProvider('https://www.linkedin.com/feed/'),
        isNull,
      );
      expect(externalSignInProvider('https://www.linkedin.com/in/johndoe'), isNull);
    });
  });

  group('spoofing and non-auth origins', () {
    test('dot-boundary suffix rule still holds', () {
      expect(
        externalSignInProvider('https://accounts.google.com.evil.example/'),
        isNull,
      );
      expect(externalSignInProvider('https://x.com.evil.example/login'), isNull);
    });

    test('unrelated origins never warn', () {
      expect(externalSignInProvider('https://github.com/login'), isNull);
      expect(
        externalSignInProvider('https://github.com/aasheesh333/OvidAI'),
        isNull,
      );
      expect(externalSignInProvider('https://example.com/login'), isNull);
      expect(externalSignInProvider('https://softonic.com/'), isNull);
    });

    test('junk input is null, never a crash', () {
      expect(externalSignInProvider('not a url'), isNull);
      expect(externalSignInProvider(''), isNull);
      expect(isExternalSignInUrl('https://github.com/login'), isFalse);
      expect(isExternalSignInUrl('https://accounts.google.com/signin'), isTrue);
    });
  });

  group('always-external vs path-gated classification', () {
    test('dedicated auth origins NEVER complete inside the tab', () {
      expect(isAlwaysExternalSignInUrl('https://accounts.google.com/'), isTrue);
      expect(isAlwaysExternalSignInUrl('https://accounts.youtube.com/'), isTrue);
      expect(
        isAlwaysExternalSignInUrl('https://login.microsoftonline.com/x'),
        isTrue,
      );
      expect(isAlwaysExternalSignInUrl('https://login.live.com/'), isTrue);
      expect(isAlwaysExternalSignInUrl('https://login.microsoft.com/'), isTrue);
      expect(isAlwaysExternalSignInUrl('https://appleid.apple.com/'), isTrue);
      expect(isAlwaysExternalSignInUrl('https://id.apple.com/'), isTrue);
    });

    test('path-gated social origins are NOT always-external', () {
      // Their sign-in forms often DO work inside a WebView — the banner must
      // not tell the user trying is pointless.
      expect(
        isAlwaysExternalSignInUrl('https://www.facebook.com/login.php'),
        isFalse,
      );
      expect(isAlwaysExternalSignInUrl('https://x.com/i/flow/login'), isFalse);
      expect(
        isAlwaysExternalSignInUrl('https://www.linkedin.com/login'),
        isFalse,
      );
      expect(isAlwaysExternalSignInUrl('https://github.com/login'), isFalse);
    });
  });

  /// Owner bug (2026-09-30): "Open in browser → sign in → Reload" left the
  /// tab logged out, because the banner's "Reload - I signed in" button
  /// implied something Android makes impossible — no app can read another
  /// browser's cookies, so an external sign-in can NEVER be imported back.
  /// The copy must say that plainly and offer only real options.
  group('notice copy is honest and actionable', () {
    test('every covered host gets a notice', () {
      const covered = [
        'https://accounts.google.com/signin',
        'https://accounts.youtube.com/',
        'https://login.microsoftonline.com/common/oauth2',
        'https://login.live.com/',
        'https://login.microsoft.com/',
        'https://appleid.apple.com/auth/authorize',
        'https://id.apple.com/',
        'https://facebook.com/login.php',
        'https://m.facebook.com/login',
        'https://www.facebook.com/dialog/oauth?client_id=1',
        'https://linkedin.com/login',
        'https://www.linkedin.com/oauth/v2/authorize',
        'https://x.com/i/flow/login',
        'https://twitter.com/login',
      ];
      for (final url in covered) {
        expect(externalSignInNoticeText(url), isNotNull, reason: url);
        expect(externalSignInNoticeText(url), isNotEmpty, reason: url);
      }
      expect(externalSignInNoticeText('https://example.com/'), isNull);
    });

    test('blocked provider: names the truth — the login cannot come back', () {
      final text = externalSignInNoticeText(
        'https://accounts.google.com/signin',
      )!;
      expect(text, contains('Google'));
      expect(text, contains('embedded browser'));
      // The hard Android truth, stated plainly:
      expect(text, contains('cannot be brought back'));
      expect(text.toLowerCase(), contains('cookie'));
      // ...so no wording may imply a reload would pick the sign-in up.
      expect(text, isNot(contains('Reload - I signed in')));
      expect(text.toLowerCase(), isNot(contains('worth trying')));
      // Real options: continue externally, or a token-style sign-in in-tab.
      expect(text, contains('real browser'));
      expect(text.toLowerCase(), contains('app password'));
      expect(text, contains('API key'));
    });

    test('path-gated provider: offers the in-tab attempt honestly', () {
      final text = externalSignInNoticeText(
        'https://www.facebook.com/login.php',
      )!;
      expect(text, contains('Facebook'));
      // Trying the form inside the tab is a REAL option for these hosts.
      expect(text.toLowerCase(), contains('try'));
      // The no-import truth applies here too.
      expect(text, contains('cannot be brought back'));
      expect(text, contains('real browser'));
    });
  });

  group('notice actions', () {
    Future<void> pumpNotice(WidgetTester tester, String url) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ExternalSignInNotice(url: url)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('offers Open in browser + Copy link, and NO reload button', (
      tester,
    ) async {
      await pumpNotice(tester, 'https://accounts.google.com/signin');
      expect(find.byKey(const ValueKey('external-signin-open')), findsOne);
      expect(find.byKey(const ValueKey('external-signin-copy')), findsOne);
      // The fake-fix button is gone for good.
      expect(find.byKey(const ValueKey('external-signin-reload')), findsNothing);
      expect(find.textContaining('Reload'), findsNothing);
    });

    testWidgets('the banner renders for every always-external provider', (
      tester,
    ) async {
      await pumpNotice(tester, 'https://login.live.com/');
      expect(find.textContaining('Microsoft'), findsOneWidget);
      await pumpNotice(tester, 'https://id.apple.com/');
      expect(find.textContaining('Apple'), findsOneWidget);
    });

    test('browser_screen no longer wires a reload into the notice', () {
      // The old onReload plumbing (`_reloadActiveTab` → "Reload - I signed
      // in") is what made the owner's dead end look like a supported flow.
      final src = File('lib/ui/browser_screen.dart').readAsStringSync();
      expect(src.contains('Reload - I signed in'), isFalse);
      expect(src.contains('_reloadActiveTab'), isFalse);
      expect(src.contains('external-signin-reload'), isFalse);
    });
  });
}
