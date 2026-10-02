import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/ui/browser_screen.dart';

/// Owner screenshot (2026-09-27): the in-app browser showed Google's sign-in
/// wall with the "provider blocks embedded sign-in" banner.  That blocking
/// banner was replaced (2026-10-02) with a non-blocking, once-per-session
/// snackbar tip.  The URL classification logic is unchanged.
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

  /// The old blocking banner was replaced with a non-blocking snackbar tip.
  /// The notice text is now a short, friendly one-liner per provider.
  group('notice copy is a non-blocking tip', () {
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

    test('always-external provider: tip names the provider', () {
      final text = externalSignInNoticeText(
        'https://accounts.google.com/signin',
      )!;
      expect(text, contains('Google'));
      // The tip is a short suggestion, not a blocking wall.
      expect(text, contains('Tip'));
      expect(text, contains('your browser'));
      // Must NOT contain the old blocking banner language.
      expect(text, isNot(contains('refuses sign-in')));
      expect(text, isNot(contains('Reload - I signed in')));
    });

    test('path-gated provider: same friendly tip format', () {
      final text = externalSignInNoticeText(
        'https://www.facebook.com/login.php',
      )!;
      expect(text, contains('Facebook'));
      expect(text, contains('Tip'));
      expect(text, contains('your browser'));
    });
  });

  group('notice widget is now non-blocking', () {
    Future<void> pumpNotice(WidgetTester tester, String url) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ExternalSignInNotice(url: url)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('ExternalSignInNotice renders nothing (SizedBox.shrink)', (
      tester,
    ) async {
      await pumpNotice(tester, 'https://accounts.google.com/signin');
      // The widget no longer renders a MaterialBanner — it returns
      // SizedBox.shrink.  The snackbar tip is shown by the BrowserScreen
      // state, not by this widget.
      expect(find.byKey(const ValueKey('external-signin-open')), findsNothing);
      expect(find.byKey(const ValueKey('external-signin-copy')), findsNothing);
      expect(find.byKey(const ValueKey('external-signin-reload')), findsNothing);
      expect(find.byType(MaterialBanner), findsNothing);
    });

    test('browser_screen no longer wires a reload into the notice', () {
      final src = File('lib/ui/browser_screen.dart').readAsStringSync();
      expect(src.contains('Reload - I signed in'), isFalse);
      expect(src.contains('_reloadActiveTab'), isFalse);
      expect(src.contains('external-signin-reload'), isFalse);
    });

    test('browser_screen no longer places ExternalSignInNotice in the Column', () {
      final src = File('lib/ui/browser_screen.dart').readAsStringSync();
      // The old inline usage was:  ExternalSignInNotice(url: tab.url)
      // inside the Column's children.  That line is gone.
      expect(src, isNot(contains('ExternalSignInNotice(url: tab.url)')));
    });
  });
}
