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
}
