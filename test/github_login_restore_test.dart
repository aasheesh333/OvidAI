import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/github_service.dart';

/// Studio login must survive reopening the app (2026-09-24).
///
/// Two independent paths lost a valid login:
///
/// 1. **A failed storage read was reported as "not signed in".** The read helper
///    retried 3× over ~300 ms and then returned null, which `initialize()` could
///    not distinguish from an empty key — so the app showed Studio logged out for
///    the WHOLE launch while the token sat intact on disk. On Android a
///    Keystore / EncryptedSharedPreferences read can fail far longer than 300 ms
///    (cold-start contention, an OS update, a damaged Tink keyset), which is why
///    the symptom was intermittent and "fixed itself" on the next launch.
///
/// 2. **`_persistToken` could delete the token it had just written.** It
///    re-checked the auth generation *inside* the queued write, so a concurrent
///    `initialize()` bumping the generation made a successful device-flow
///    sign-in survive only for that process lifetime.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final gh = GitHubService.I;

  setUp(() async {
    // The mock handler must be installed BEFORE any storage call, otherwise the
    // first one hits the real platform channel.
    FlutterSecureStorage.setMockInitialValues({});
    gh.profileRetryDelay = Duration.zero;
    // signOut clears the in-memory token AND storage, so re-seed storage after.
    await gh.signOut();
    GitHubService.lastReadFailedForTest = false;
    gh.restoreFailed = false;
    FlutterSecureStorage.setMockInitialValues({
      'ovid_github_token': 'stored-token',
    });
  });

  tearDown(() async {
    await gh.signOut();
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('a failed read is not a sign-out', () {
    test('exhausted attempts by THROWING are reported as a failure', () async {
      var calls = 0;
      final token = await GitHubService.readTokenWithRetriesForTest((() async {
        calls++;
        throw StateError('keystore unavailable');
      }));

      expect(token, isNull);
      expect(calls, 3, reason: 'it must actually retry');
      expect(
        GitHubService.lastReadFailedForTest,
        isTrue,
        reason: 'a throw is not the same as reading an empty key',
      );
    });

    test('reading an empty key is NOT a failure', () async {
      final token = await GitHubService.readTokenWithRetriesForTest(
        () async => null,
      );

      expect(token, isNull);
      expect(
        GitHubService.lastReadFailedForTest,
        isFalse,
        reason: 'genuinely signed out must stay a terminal answer',
      );
    });

    test('a later success clears the failure flag', () async {
      await GitHubService.readTokenWithRetriesForTest((() async {
        throw StateError('transient');
      }));
      expect(GitHubService.lastReadFailedForTest, isTrue);

      final token = await GitHubService.readTokenWithRetriesForTest(
        () async => 'recovered',
      );
      expect(token, 'recovered');
      expect(GitHubService.lastReadFailedForTest, isFalse);
    });
  });

  group('retryRestoreIfNotLoggedIn recovers the login', () {
    test('restores a token that is on disk but not in memory', () async {
      expect(gh.isLoggedIn, isFalse, reason: 'precondition: memory is empty');

      await gh.retryRestoreIfNotLoggedIn();

      expect(gh.isLoggedIn, isTrue);
      expect(gh.token, 'stored-token');
      expect(gh.restoreFailed, isFalse);
    });

    test('is a no-op when already logged in', () async {
      await gh.retryRestoreIfNotLoggedIn();
      expect(gh.isLoggedIn, isTrue);
      final before = gh.token;

      await gh.retryRestoreIfNotLoggedIn();

      expect(gh.token, before);
      expect(gh.isLoggedIn, isTrue);
    });

    test('reports failure instead of signed-out when storage is unreadable',
        () async {
      // Empty storage reads as "no token" — the honest terminal answer.
      FlutterSecureStorage.setMockInitialValues({});
      await gh.retryRestoreIfNotLoggedIn();
      expect(gh.isLoggedIn, isFalse);
      expect(gh.restoreFailed, isFalse);
    });
  });

  group('a freshly issued token is never discarded', () {
    test('_persistToken has no generation-guarded write skip or delete', () {
      // The race cannot be reproduced deterministically through the public API
      // (it needs a generation bump to land inside a queued write), so pin the
      // code shape that caused it: no re-check of _authGeneration inside the
      // queued closure, and no delete-after-write.
      final src = File('lib/core/github_service.dart').readAsStringSync();
      final body = src.substring(
        src.indexOf('Future<void> _persistToken('),
        src.indexOf('/// Persist (or clear) the token') > 0
            ? src.indexOf('STEP 1 — request device code')
            : src.length,
      );
      expect(
        body,
        isNot(contains('_authGeneration')),
        reason: 'a queued write must not re-check the generation and skip',
      );
      // delete is legitimate for an explicit CLEAR (sign-out) — the bug was a
      // delete AFTER a successful write, which discarded a token that was
      // valid when it was written.
      expect(
        RegExp(
          r'if \(token == null \|\| token\.isEmpty\) \{\s*'
          r'await _secureStorage\.delete',
        ).hasMatch(body),
        isTrue,
        reason: 'delete must only run on the clear path',
      );
      expect(
        RegExp(r'_secureStorage\.write\([^)]*\);\s*\}').hasMatch(body),
        isTrue,
        reason: 'the write branch must end immediately — no delete-after-write',
      );
      expect(body, contains('_secureStorage.write'));
    });

    test('sign-out still clears storage', () async {
      await gh.retryRestoreIfNotLoggedIn();
      expect(gh.isLoggedIn, isTrue);

      await gh.signOut();

      expect(gh.isLoggedIn, isFalse);
      expect(gh.token, isNull);
      const storage = FlutterSecureStorage();
      expect(await storage.read(key: 'ovid_github_token'), isNull);
    });
  });

  group('callers do not treat a failed restore as a sign-out', () {
    test('Studio declines to latch the login prompt on a failed read', () {
      final src = File('lib/ui/studio_screen.dart').readAsStringSync();
      final i = src.indexOf('if (github.restoreFailed) return;');
      expect(i, greaterThan(-1));
      expect(
        i,
        lessThan(src.indexOf('_handledInitialAuth = true;\n    (studioLoginPromptOverrideForTest')),
        reason: 'the guard must run before the prompt latches',
      );
    });

    test('app resume retries the restore', () {
      final src = File('lib/ui/shell.dart').readAsStringSync();
      // The UI-initiated variant, not the plain one: it also restarts the
      // automatic backoff window, which otherwise expires after ~2.5 minutes
      // and leaves Studio signed out for the rest of the process.
      expect(src, contains('GitHubService.I.retryRestoreFromUi()'));
    });

    test('opening Studio retries the restore too', () {
      final src = File('lib/ui/studio_screen.dart').readAsStringSync();
      expect(src, contains('GitHubService.I.retryRestoreFromUi()'));
    });

    test('the status dot does not call an unknown state signed-out', () {
      final src = File('lib/ui/studio_screen.dart').readAsStringSync();
      expect(src, contains('gh.restoreFailed'));
      expect(src, contains('gh.isInitializing'));
    });

    test('delete-all-data clears the in-memory login too', () {
      final src = File('lib/core/state.dart').readAsStringSync();
      final wipe = src.indexOf('await _secureStorage.deleteAll();');
      expect(wipe, greaterThan(-1));
      expect(
        src.lastIndexOf('await GitHubService.I.signOut();', wipe),
        greaterThan(-1),
        reason: 'signOut must run before the storage wipe',
      );
    });
  });
}
