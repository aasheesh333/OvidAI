import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/github_service.dart';
import 'package:ovid_ai/core/sandbox_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();

  late Directory prefix;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await GitHubService.I.signOut();
    SandboxService.I.gitCredentialToken = null;
    prefix = await Directory.systemTemp.createTemp('git-cred-prefix');
    SandboxService.I.sandboxPrefixForTest = prefix;
  });

  tearDown(() async {
    SandboxService.I.sandboxPrefixForTest = null;
    SandboxService.I.gitCredentialToken = null;
    await GitHubService.I.signOut();
    if (prefix.existsSync()) prefix.deleteSync(recursive: true);
  });

  group('sandbox env git credentials', () {
    test(
      'injects a github.com-scoped credential helper and disables prompts '
      'when a token is present',
      () {
        SandboxService.I.gitCredentialToken = 'gho_testtoken123';
        final env = SandboxService.I.sandboxEnvForTest();

        expect(env['GIT_TERMINAL_PROMPT'], '0');
        expect(env['GIT_CONFIG_COUNT'], '1');
        expect(
          env['GIT_CONFIG_KEY_0'],
          'credential.https://github.com.helper',
        );
        final helper = env['GIT_CONFIG_VALUE_0'];
        expect(helper, isNotNull);
        expect(helper, contains('username=x-access-token'));
        expect(helper, contains('password=gho_testtoken123'));
        // Host-scoped: the key names github.com explicitly; no unscoped
        // credential.helper is injected.
        expect(env.containsKey('credential.helper'), isFalse);
      },
    );

    test('never persists credentials (no store helper, no .git-credentials)', () {
      SandboxService.I.gitCredentialToken = 'gho_testtoken123';
      final env = SandboxService.I.sandboxEnvForTest();

      expect(env['GIT_CONFIG_VALUE_0'], isNot(contains('store')));
      for (final value in env.values) {
        expect(value, isNot(contains('.git-credentials')));
      }
      // No env var points git at a credentials file / askpass program.
      expect(env.containsKey('GIT_ASKPASS'), isFalse);
      expect(env.containsKey('GIT_CREDENTIAL_HELPER'), isFalse);
    });

    test('adds no credential env when no token is present', () {
      SandboxService.I.gitCredentialToken = null;
      final env = SandboxService.I.sandboxEnvForTest();

      expect(env.containsKey('GIT_TERMINAL_PROMPT'), isFalse);
      expect(env.containsKey('GIT_CONFIG_COUNT'), isFalse);
      expect(env.containsKey('GIT_CONFIG_KEY_0'), isFalse);
      expect(env.containsKey('GIT_CONFIG_VALUE_0'), isFalse);
    });
  });

  group('GitHubService token wiring', () {
    test(
      'initialize publishes the token to the sandbox; sign-out clears it',
      () async {
        await storage.write(key: 'ovid_github_token', value: 'stored-token');
        final client = MockClient(
          (request) async => http.Response('{"login":"octocat"}', 200),
        );

        await GitHubService.I.initialize(client: client);

        expect(GitHubService.I.token, 'stored-token');
        expect(SandboxService.I.gitCredentialToken, 'stored-token');
        expect(
          SandboxService.I.sandboxEnvForTest()['GIT_CONFIG_VALUE_0'],
          contains('password=stored-token'),
        );

        await GitHubService.I.signOut();

        expect(SandboxService.I.gitCredentialToken, isNull);
        expect(
          SandboxService.I.sandboxEnvForTest().containsKey('GIT_CONFIG_COUNT'),
          isFalse,
        );
        client.close();
      },
    );

    test('a transient profile failure keeps the sandbox token', () async {
      await storage.write(key: 'ovid_github_token', value: 'stored-token');
      GitHubService.I.profileRetryDelay = Duration.zero;
      addTearDown(() {
        GitHubService.I.profileRetryDelay = const Duration(seconds: 30);
      });
      final client = MockClient(
        (request) async => http.Response('temporarily unavailable', 503),
      );

      await GitHubService.I.initialize(client: client);

      expect(GitHubService.I.token, 'stored-token');
      expect(SandboxService.I.gitCredentialToken, 'stored-token');
      client.close();
    });

    test('a 401 clears the sandbox token', () async {
      await storage.write(key: 'ovid_github_token', value: 'invalid-token');
      final client = MockClient(
        (request) async => http.Response('unauthorized', 401),
      );

      await GitHubService.I.initialize(client: client);

      expect(GitHubService.I.token, isNull);
      expect(SandboxService.I.gitCredentialToken, isNull);
      client.close();
    });
  });
}
