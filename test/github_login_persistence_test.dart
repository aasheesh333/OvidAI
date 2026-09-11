import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/github_service.dart';

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
    'stored token + transient then 401 retry clears the token',
    () async {
      await storage.write(key: 'ovid_github_token', value: 'stored-token');
      var profileRequests = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/user') {
          profileRequests++;
          if (profileRequests == 1) {
            return http.Response('temporarily unavailable', 503);
          }
          return http.Response('unauthorized', 401);
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

  test('stored token + 401 logs out and deletes the token', () async {
    await storage.write(key: 'ovid_github_token', value: 'invalid-token');
    final client = MockClient((request) async {
      return http.Response('unauthorized', 401);
    });

    await GitHubService.I.initialize(client: client);

    expect(GitHubService.I.isInitializing, isFalse);
    expect(GitHubService.I.isLoggedIn, isFalse);
    expect(GitHubService.I.token, isNull);
    expect(await storage.read(key: 'ovid_github_token'), isNull);
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
}
