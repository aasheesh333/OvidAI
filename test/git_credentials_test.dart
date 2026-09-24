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
    // SECURITY (2026-09-24): the token used to be interpolated straight into
    // GIT_CONFIG_VALUE_0, which `_sandboxEnv()` merges into EVERY child
    // process — the agent shell, the Studio terminal, MCP stdio servers and
    // plugin hooks. Any `printenv` (auto-approved in Read-Only mode) then put
    // the raw token into tool output → transcript → the LLM provider. The
    // contract is now: the secret lives in a 0600 file that the path jail
    // protects, and NO env value ever contains it.
    test('no env value contains the token', () {
      SandboxService.I.gitCredentialToken = 'gho_testtoken123';
      final env = SandboxService.I.sandboxEnvForTest();

      for (final entry in env.entries) {
        expect(
          entry.value,
          isNot(contains('gho_testtoken123')),
          reason: '${entry.key} leaks the git token into every child process',
        );
      }
      // `printenv` output must be free of the secret.
      expect(env.values.join('\n'), isNot(contains('password=')));
    });

    test('injects a github.com-scoped store helper pointing at a file', () {
      SandboxService.I.gitCredentialToken = 'gho_testtoken123';
      final env = SandboxService.I.sandboxEnvForTest();

      expect(env['GIT_TERMINAL_PROMPT'], '0');
      expect(env['GIT_CONFIG_COUNT'], '1');
      expect(env['GIT_CONFIG_KEY_0'], 'credential.https://github.com.helper');
      final helper = env['GIT_CONFIG_VALUE_0'];
      expect(helper, isNotNull);
      expect(helper, contains('store --file='));
      expect(helper, isNot(contains('gho_testtoken123')));
      // Host-scoped: the key names github.com explicitly; no unscoped
      // credential.helper is injected.
      expect(env.containsKey('credential.helper'), isFalse);
    });

    test('the credential file is 0600 and holds the git-credentials line', () {
      SandboxService.I.gitCredentialToken = 'gho_testtoken123';
      SandboxService.I.sandboxEnvForTest();

      final f = File(SandboxService.I.gitCredentialFilePath!);
      expect(f.existsSync(), isTrue, reason: 'the store file must be written');
      expect(
        f.readAsStringSync(),
        'https://x-access-token:gho_testtoken123@github.com\n',
      );
      // Owner-only: the sandbox runs as the app UID, so anything wider is
      // readable by every process on the device.
      expect(f.statSync().mode & 0x1ff, 0x180, reason: 'must be mode 0600');
    });

    test('the credential file path is jail-protected', () {
      SandboxService.I.gitCredentialToken = 'gho_testtoken123';
      SandboxService.I.sandboxEnvForTest();

      expect(
        SandboxService.I.protectedPaths,
        contains(SandboxService.I.gitCredentialFilePath),
        reason: 'reading the token file must require an explicit grant',
      );
    });

    test('clearing the token deletes the credential file', () {
      SandboxService.I.gitCredentialToken = 'gho_testtoken123';
      SandboxService.I.sandboxEnvForTest();
      final path = SandboxService.I.gitCredentialFilePath!;
      expect(File(path).existsSync(), isTrue);

      SandboxService.I.gitCredentialToken = null;
      SandboxService.I.clearGitCredentialFile();
      expect(File(path).existsSync(), isFalse);
    });

    test('the shared git env helper is secret-free for registry + studio', () {
      SandboxService.I.gitCredentialToken = 'gho_testtoken123';
      final env = SandboxService.I.gitCredentialEnv();

      expect(env['GIT_TERMINAL_PROMPT'], '0');
      for (final value in env.values) {
        expect(value, isNot(contains('gho_testtoken123')));
      }
    });

    test('adds no credential env when no token is present', () {
      SandboxService.I.gitCredentialToken = null;
      final env = SandboxService.I.sandboxEnvForTest();

      expect(env.containsKey('GIT_TERMINAL_PROMPT'), isFalse);
      expect(env.containsKey('GIT_CONFIG_COUNT'), isFalse);
      expect(env.containsKey('GIT_CONFIG_KEY_0'), isFalse);
      expect(env.containsKey('GIT_CONFIG_VALUE_0'), isFalse);
      expect(SandboxService.I.gitCredentialFilePath, isNull);
      expect(SandboxService.I.gitCredentialEnv().containsKey('GIT_CONFIG_COUNT'),
          isFalse);
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
        // The published token reaches git through a 0600 store file; the env
        // value names the file and never the secret.
        final helper = SandboxService.I.sandboxEnvForTest()['GIT_CONFIG_VALUE_0'];
        expect(helper, contains('store --file='));
        expect(helper, isNot(contains('stored-token')));

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

    test('an unconfirmed 401 keeps the sandbox token', () async {
      await storage.write(key: 'ovid_github_token', value: 'invalid-token');
      GitHubService.I.profileRetryDelay = Duration.zero;
      addTearDown(() {
        GitHubService.I.profileRetryDelay = const Duration(seconds: 30);
      });
      final client = MockClient(
        (request) async => http.Response('unauthorized', 401),
      );

      await GitHubService.I.initialize(client: client);

      // A lone 401 (proxy/WAF/edge artifact) is never proof the token died.
      expect(GitHubService.I.token, 'invalid-token');
      expect(SandboxService.I.gitCredentialToken, 'invalid-token');
      client.close();
    });

    test('a confirmed Bad credentials 401 clears the sandbox token', () async {
      await storage.write(key: 'ovid_github_token', value: 'invalid-token');
      final client = MockClient(
        (request) async => http.Response(
          '{"message": "Bad credentials",'
          ' "documentation_url": "https://docs.github.com/rest"}',
          401,
          headers: {'content-type': 'application/json'},
        ),
      );

      await GitHubService.I.initialize(client: client);

      expect(GitHubService.I.token, isNull);
      expect(SandboxService.I.gitCredentialToken, isNull);
      client.close();
    });
  });
}
