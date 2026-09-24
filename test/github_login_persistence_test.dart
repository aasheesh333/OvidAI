import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/github_service.dart';

/// GitHub's real "your token is dead" response body for GET /user.
String _badCredentialsBody() => jsonEncode({
  'message': 'Bad credentials',
  'documentation_url':
      'https://docs.github.com/rest/users/users#get-the-authenticated-user',
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await GitHubService.I.signOut();
    GitHubService.I.profileRetryDelay = Duration.zero;
  });

  tearDown(() async {
    await GitHubService.I.signOut();
    GitHubService.I.profileRetryDelay = const Duration(seconds: 30);
  });

  test(
    'stored token + transient profile failure stays logged in and retries',
    () async {
      await storage.write(key: 'ovid_github_token', value: 'stored-token');
      var profileRequests = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/user') {
          profileRequests++;
          return http.Response('temporarily unavailable', 503);
        }
        return http.Response('not found', 404);
      });

      await GitHubService.I.initialize(client: client);

      expect(GitHubService.I.isInitializing, isFalse);
      expect(GitHubService.I.isLoggedIn, isTrue);
      expect(GitHubService.I.token, 'stored-token');
      expect(await storage.read(key: 'ovid_github_token'), 'stored-token');

      await pumpEventQueue();
      expect(profileRequests, greaterThanOrEqualTo(2));
      expect(GitHubService.I.isLoggedIn, isTrue);
      expect(GitHubService.I.token, 'stored-token');
      expect(await storage.read(key: 'ovid_github_token'), 'stored-token');
      client.close();
    },
  );

  test(
    'stored token + transient then CONFIRMED bad-credentials 401 clears the token',
    () async {
      await storage.write(key: 'ovid_github_token', value: 'stored-token');
      var profileRequests = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/user') {
          profileRequests++;
          if (profileRequests == 1) {
            return http.Response('temporarily unavailable', 503);
          }
          // GitHub's own JSON `Bad credentials` — the token is really dead.
          return http.Response(_badCredentialsBody(), 401);
        }
        return http.Response('not found', 404);
      });

      await GitHubService.I.initialize(client: client);

      // The initial transient failure keeps the token so the user stays
      // signed in until the background profile retry settles.
      expect(GitHubService.I.isLoggedIn, isTrue);
      expect(GitHubService.I.token, 'stored-token');

      await pumpEventQueue();

      expect(profileRequests, greaterThanOrEqualTo(2));
      expect(GitHubService.I.isLoggedIn, isFalse);
      expect(GitHubService.I.token, isNull);
      expect(await storage.read(key: 'ovid_github_token'), isNull);
      client.close();
    },
  );

  test(
    'single UNCONFIRMED 401 keeps the token and arms the retry (no wipe)',
    () async {
      // A longer retry delay so the re-armed timer does not fire inside
      // this test (an unconfirmed 401 re-arms the retry instead of wiping).
      GitHubService.I.profileRetryDelay = const Duration(seconds: 30);
      await storage.write(key: 'ovid_github_token', value: 'stored-token');
      var profileRequests = 0;
      final client = MockClient((request) async {
        profileRequests++;
        // A bare 401 with no GitHub JSON body — e.g. a proxy/WAF/edge page —
        // must NEVER delete the stored token.
        return http.Response('unauthorized', 401);
      });

      await GitHubService.I.initialize(client: client);

      // Initial fetch 401 + confirmation fetch 401 (both unconfirmed).
      expect(profileRequests, 2);
      expect(GitHubService.I.isInitializing, isFalse);
      expect(GitHubService.I.isLoggedIn, isTrue);
      expect(GitHubService.I.token, 'stored-token');
      expect(await storage.read(key: 'ovid_github_token'), 'stored-token');
      // ...and the background retry is armed instead of a wipe.
      expect(GitHubService.I.hasProfileRetryScheduledForTest, isTrue);
      client.close();
    },
  );

  test('confirmed bad-credentials 401 at startup wipes the token', () async {
    await storage.write(key: 'ovid_github_token', value: 'invalid-token');
    var profileRequests = 0;
    final client = MockClient((request) async {
      profileRequests++;
      return http.Response(_badCredentialsBody(), 401);
    });

    await GitHubService.I.initialize(client: client);

    // First fetch 401 + confirmation fetch 401-with-Bad-credentials.
    expect(profileRequests, 2);
    expect(GitHubService.I.isInitializing, isFalse);
    expect(GitHubService.I.isLoggedIn, isFalse);
    expect(GitHubService.I.token, isNull);
    expect(await storage.read(key: 'ovid_github_token'), isNull);
    // Wiped tokens do not arm a retry.
    expect(GitHubService.I.hasProfileRetryScheduledForTest, isFalse);
    client.close();
  });

  test('stored token + 200 loads the profile and stays logged in', () async {
    await storage.write(key: 'ovid_github_token', value: 'stored-token');
    final client = MockClient((request) async {
      expect(request.url.path, '/user');
      expect(request.headers['Authorization'], 'Bearer stored-token');
      return http.Response(jsonEncode({'login': 'octocat'}), 200);
    });

    await GitHubService.I.initialize(client: client);

    expect(GitHubService.I.isInitializing, isFalse);
    expect(GitHubService.I.isLoggedIn, isTrue);
    expect(GitHubService.I.login, 'octocat');
    expect(GitHubService.I.token, 'stored-token');
    expect(await storage.read(key: 'ovid_github_token'), 'stored-token');
    client.close();
  });

  test(
    'inconclusive confirmations keep the retry loop alive and probing',
    () async {
      // profileRetryDelay is Duration.zero in setUp, so every re-armed
      // timer fires on pumpEventQueue.
      await storage.write(key: 'ovid_github_token', value: 'stored-token');
      var profileRequests = 0;
      final client = MockClient((request) async {
        profileRequests++;
        // A bare 401 with no GitHub JSON body — never confirmable as a
        // dead token, so every round must re-arm the retry with a usable
        // client instead of reusing a closed confirmation client.
        return http.Response('proxy says no', 401);
      });

      await GitHubService.I.initialize(client: client);

      // Initial fetch + confirmation fetch.
      expect(profileRequests, 2);
      expect(GitHubService.I.isLoggedIn, isTrue);

      // First retry round: fetch + confirmation again, then re-arm.
      await pumpEventQueue();
      final afterFirstRetry = profileRequests;
      expect(afterFirstRetry, greaterThan(2));
      expect(GitHubService.I.hasProfileRetryScheduledForTest, isTrue);

      // The loop stays alive: a second retry round still probes.
      await pumpEventQueue();
      expect(profileRequests, greaterThan(afterFirstRetry));
      expect(GitHubService.I.hasProfileRetryScheduledForTest, isTrue);

      // And the token was never wiped by the unconfirmed 401s.
      expect(GitHubService.I.isLoggedIn, isTrue);
      expect(GitHubService.I.token, 'stored-token');
      expect(await storage.read(key: 'ovid_github_token'), 'stored-token');
      client.close();
    },
  );

  group('secure-storage read retries', () {
    test('transient read failures are retried before concluding "no login"',
        () async {
      var attempts = 0;
      final token = await GitHubService.readTokenWithRetriesForTest(() async {
        attempts++;
        if (attempts < 3) throw Exception('Keystore hiccup');
        return 'recovered-token';
      });
      expect(token, 'recovered-token');
      expect(attempts, 3);
    });

    test('a read that succeeds first try costs exactly one attempt', () async {
      var attempts = 0;
      final token = await GitHubService.readTokenWithRetriesForTest(() async {
        attempts++;
        return 'tok';
      });
      expect(token, 'tok');
      expect(attempts, 1);
    });

    test('persistently failing reads are treated as absent (not a crash)',
        () async {
      var attempts = 0;
      final token = await GitHubService.readTokenWithRetriesForTest(() async {
        attempts++;
        throw Exception('Keystore down');
      });
      expect(token, isNull);
      expect(attempts, 3);
    });
  });
}
