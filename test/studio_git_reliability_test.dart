import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/github_service.dart';
import 'package:ovid_ai/core/pty_service.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/core/sandbox_pkg.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/studio_terminal.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_screen.dart';

/// Task 7 end-to-end gate for the Studio/Git reliability project
/// (spec `docs/superpowers/specs/2026-09-10-studio-git-reliability-design.md`).
///
/// Every case drives the real seam with an injected/mocked boundary:
/// - login uses a `MockClient` (no network) and the Studio prompt override;
/// - the terminal uses a real host `bash` through the `PtySpawner` seam (no
///   network, no sandbox);
/// - repo/branch reads use a `MockClient` (no network);
/// - ovid-pkg executes the generated script against a temp `PREFIX` (no
///   network);
/// - git credentials are asserted through `sandboxEnvForTest`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();

  group('one-time login persistence', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      await GitHubService.I.signOut();
      GitHubService.I.profileRetryDelay = Duration.zero;
      studioLoginPromptOverrideForTest = null;
      // Establish "one successful login" before the widget fake-async zone:
      // `setUp` runs outside `testWidgets`'s FakeAsync, so the restore settles.
      await storage.write(key: 'ovid_github_token', value: 'stored-token');
      await GitHubService.I.initialize(
        client: MockClient(
          (request) async => request.url.path == '/user'
              ? http.Response(jsonEncode({'login': 'octocat'}), 200)
              : http.Response('{}', 404),
        ),
      );
    });

    tearDown(() async {
      studioLoginPromptOverrideForTest = null;
      GitHubService.I.profileRetryDelay = const Duration(seconds: 30);
      await GitHubService.I.signOut();
    });

    testWidgets(
      'one login is not re-prompted on a later transient profile failure',
      (tester) async {
        AgentNotificationService.I.resetForTest();
        AppState.resetTestInstance();
        final app = AppState.createForTest();
        app.seenWelcomeVersion = AppState.welcomeVersion;
        AgentService.I.debugPauseScheduleTimerForTest(true);
        addTearDown(() {
          AgentService.I.debugPauseScheduleTimerForTest(false);
          AgentNotificationService.I.resetForTest();
          AppState.resetTestInstance();
        });

        var prompted = false;
        studioLoginPromptOverrideForTest = (_) => prompted = true;
        await tester.pumpWidget(
          MaterialApp(theme: Aether.theme(), home: const StudioScreen()),
        );
        await tester.pump();
        expect(prompted, isFalse, reason: 'a logged-in Studio does not prompt');

        // A later launch whose profile fetch fails transiently must not sign
        // the user out or re-prompt.
        final failing = MockClient(
          (request) async => http.Response('temporarily unavailable', 503),
        );
        await GitHubService.I.initialize(client: failing);
        await tester.pump();
        // Flush the background profile retry (zero-delay in this suite) so no
        // fake timer outlives the widget tree.
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();

        expect(GitHubService.I.isLoggedIn, isTrue);
        expect(GitHubService.I.token, 'stored-token');
        expect(await storage.read(key: 'ovid_github_token'), 'stored-token');
        expect(
          prompted,
          isFalse,
          reason: 'a transient 5xx must not re-prompt an established login',
        );
        failing.close();
      },
    );

    test('a transient profile failure keeps the sandbox credential too', () async {
      await storage.write(key: 'ovid_github_token', value: 'stored-token');
      final failing = MockClient(
        (request) async => http.Response('temporarily unavailable', 503),
      );

      await GitHubService.I.initialize(client: failing);
      await pumpEventQueue();

      expect(GitHubService.I.isLoggedIn, isTrue);
      expect(SandboxService.I.gitCredentialToken, 'stored-token');
      failing.close();
    });
  });

  group('last selection inheritance', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      AppState.resetTestInstance();
      await GitHubService.I.signOut();
    });

    tearDown(() async {
      studioRepoSyncOverrideForTest = null;
      AgentService.I.debugPauseScheduleTimerForTest(false);
      AgentNotificationService.I.resetForTest();
      await GitHubService.I.signOut();
      AppState.resetTestInstance();
    });

    test('a logged-in new session inherits the last repo, branch, and folder', () async {
      await storage.write(key: 'ovid_github_token', value: 'stored-token');
      await GitHubService.I.initialize(
        client: MockClient(
          (request) async => request.url.path == '/user'
              ? http.Response(jsonEncode({'login': 'octocat'}), 200)
              : http.Response('{}', 404),
        ),
      );
      expect(GitHubService.I.isLoggedIn, isTrue);

      final dir = Directory.systemTemp.createTempSync('ovid-e2e-selection');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final app = AppState.createForTest();
      app.lastRepoFull = 'owner/repo';
      app.lastBranch = 'develop';
      app.lastWorkspaceFolder = dir.path;

      app.newSession();

      final session = app.activeSession!;
      expect(session.repo, 'owner/repo');
      expect(session.branch, 'develop');
      expect(session.workspaceFolder, dir.path);
      expect(app.getRepoForSession(session.id), 'owner/repo');
      expect(app.getBranchForSession(session.id), 'develop');
    });

    test('the inherited selection round-trips through a restart', () async {
      final dir = Directory.systemTemp.createTempSync('ovid-e2e-roundtrip');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final app = AppState.createForTest();
      final id = app.activeSession!.id;
      app.setRepoForSession(id, 'owner/repo');
      app.setBranchForSession(id, 'release');
      app.setSessionWorkspaceFolder(dir.path);
      await pumpEventQueue();

      AppState.resetTestInstance();
      final restarted = AppState.createForTest();
      await restarted.initializeForFirstFrame();

      expect(restarted.lastRepoFull, 'owner/repo');
      expect(restarted.lastBranch, 'release');
      expect(restarted.lastWorkspaceFolder, dir.path);
    });

    testWidgets('Studio shows the inherited repo instead of Connect a repo', (
      tester,
    ) async {
      await storage.write(key: 'ovid_github_token', value: 'stored-token');
      await GitHubService.I.initialize(
        client: MockClient(
          (request) async => request.url.path == '/user'
              ? http.Response(jsonEncode({'login': 'octocat'}), 200)
              : http.Response('{}', 404),
        ),
      );
      AgentNotificationService.I.resetForTest();
      final app = AppState.createForTest();
      app.seenWelcomeVersion = AppState.welcomeVersion;
      AgentService.I.debugPauseScheduleTimerForTest(true);
      app.lastRepoFull = 'owner/inherited';
      app.lastBranch = 'main';
      app.newSession();
      studioRepoSyncOverrideForTest = () async {};

      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const StudioScreen()),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('owner/inherited'), findsWidgets);
      expect(find.text('Connect a repo'), findsNothing);
    });
  });

  group('studio terminal streaming', () {
    tearDown(() => PtyPool.I.discardAllShells());

    test('streams output before exit and persists cd across commands', () async {
      final s = StudioShellSession(tabId: 'e2e-term');
      addTearDown(s.dispose);
      final dir = Directory.systemTemp.createTempSync('ovid-e2e-cwd');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      s.begin('echo first; sleep 1; echo second');
      expect(
        await s.runPersistent(
          'echo first; sleep 1; echo second',
          sid: 'e2e-sess',
          spawner: _spawnShell,
        ),
        isTrue,
      );
      await _waitFor(
        () => s.history.any((l) => l.trim() == 'first'),
        reason: 'the first line streams before the command exits',
      );
      expect(
        s.busy,
        isTrue,
        reason: 'output streams while the command is still running',
      );
      await _waitFor(
        () => s.history.any((l) => l.trim() == 'second'),
        reason: 'the second line arrives',
      );
      await _waitFor(() => !s.busy, reason: 'the command completes');

      s.begin('cd ${dir.path}');
      expect(
        await s.runPersistent(
          'cd ${dir.path}',
          sid: 'e2e-sess',
          spawner: _spawnShell,
        ),
        isTrue,
      );
      await _waitFor(() => !s.busy, reason: 'cd completes');

      s.begin('pwd');
      expect(
        await s.runPersistent('pwd', sid: 'e2e-sess', spawner: _spawnShell),
        isTrue,
      );
      await _waitFor(
        () => s.history.any((l) => l.trim() == dir.path),
        reason: 'pwd shows the cwd persisted from the previous command',
      );
      expect(s.busy, isFalse);
    });
  });

  group('repo + branch binding', () {
    setUp(() => RepoCache.I.unbind());
    tearDown(() => RepoCache.I.unbind());

    test('sync reads the tree and raw content on the bound branch', () async {
      final urls = <Uri>[];
      final client = MockClient((request) async {
        urls.add(request.url);
        if (request.url.path.contains('/git/trees/')) {
          return http.Response(
            jsonEncode({
              'tree': [
                {'type': 'blob', 'path': 'README.md'},
              ],
            }),
            200,
          );
        }
        return http.Response('hello', 200);
      });

      RepoCache.I.bind(
        'owner/repo',
        'tok',
        branch: 'develop',
        sessionId: 's1',
      );
      await RepoCache.I.sync(client: client);

      final tree = urls.firstWhere((u) => u.path.contains('/git/trees/'));
      expect(tree.path, contains('/git/trees/develop'));
      final raw = urls.firstWhere((u) => u.path.contains('/contents/'));
      expect(raw.queryParameters['ref'], 'develop');
      expect(RepoCache.I.files['README.md'], 'hello');
    });

    test('commitAll reads the SHA and commits on the bound branch', () async {
      Uri? shaUrl;
      Map<String, dynamic>? putBody;
      final client = MockClient((request) async {
        if (request.method == 'GET') {
          shaUrl = request.url;
          return http.Response(jsonEncode({'sha': 'old-sha'}), 200);
        }
        putBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('{}', 200);
      });

      RepoCache.I.bind(
        'owner/repo',
        'tok',
        branch: 'feature/x',
        sessionId: 's1',
      );
      RepoCache.I.write('README.md', 'updated');

      final pushed = await RepoCache.I.commitAll(
        'Update README',
        client: client,
      );

      expect(pushed, 1);
      expect(shaUrl!.queryParameters['ref'], 'feature/x');
      expect(putBody!['branch'], 'feature/x');
    });

    test('listRepoContent carries the branch ref', () async {
      await storage.write(key: 'ovid_github_token', value: 'tok');
      addTearDown(() async {
        await GitHubService.I.signOut();
      });
      await GitHubService.I.initialize(
        client: MockClient(
          (request) async => request.url.path == '/user'
              ? http.Response(jsonEncode({'login': 'octocat'}), 200)
              : http.Response('{}', 404),
        ),
      );
      Uri? seen;
      final client = MockClient((request) async {
        seen = request.url;
        return http.Response(
          jsonEncode([
            {'name': 'README.md', 'type': 'file'},
          ]),
          200,
        );
      });

      await GitHubService.I.listRepoContent(
        owner: 'owner',
        repo: 'repo',
        branch: 'develop',
        client: client,
      );

      expect(seen!.queryParameters['ref'], 'develop');
    });
  });

  group('ovid-pkg honesty', () {
    test('apt upgrade and full-upgrade fail non-zero with a stderr message', () async {
      final tmp = Directory.systemTemp.createTempSync('ovid-e2e-pkg');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      OvidPkgInstaller.writeAll(
        tmp,
        arch: 'aarch64',
        mirrors: const ['https://mirror.test/apt/termux-main'],
      );
      Link('${tmp.path}/bin/sh').createSync('/bin/sh');
      final env = {
        'PREFIX': tmp.path,
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
      };

      for (final verb in const ['upgrade', 'full-upgrade']) {
        final res = await Process.run(
          '/bin/sh',
          ['${tmp.path}/bin/ovid-pkg', verb],
          environment: env,
        ).timeout(const Duration(seconds: 30));
        expect(res.exitCode, isNot(0), reason: '$verb must not silently succeed');
        expect(res.stderr, contains('not supported'));
      }
    });
  });

  group('git credential scoping', () {
    late Directory prefix;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      await GitHubService.I.signOut();
      SandboxService.I.gitCredentialToken = null;
      prefix = Directory.systemTemp.createTempSync('ovid-e2e-cred');
      SandboxService.I.sandboxPrefixForTest = prefix;
    });

    tearDown(() async {
      SandboxService.I.sandboxPrefixForTest = null;
      SandboxService.I.gitCredentialToken = null;
      await GitHubService.I.signOut();
      if (prefix.existsSync()) prefix.deleteSync(recursive: true);
    });

    test('login injects a github.com-scoped env credential and sign-out clears it', () async {
      await storage.write(key: 'ovid_github_token', value: 'stored-token');
      await GitHubService.I.initialize(
        client: MockClient(
          (request) async => request.url.path == '/user'
              ? http.Response(jsonEncode({'login': 'octocat'}), 200)
              : http.Response('{}', 404),
        ),
      );

      final env = SandboxService.I.sandboxEnvForTest();
      expect(env['GIT_TERMINAL_PROMPT'], '0');
      expect(env['GIT_CONFIG_COUNT'], '1');
      expect(env['GIT_CONFIG_KEY_0'], 'credential.https://github.com.helper');
      expect(env['GIT_CONFIG_VALUE_0'], contains('password=stored-token'));
      // Host-scoped: no unscoped credential.helper, no persisted store.
      expect(env.containsKey('credential.helper'), isFalse);
      expect(env.containsKey('GIT_ASKPASS'), isFalse);
      expect(
        env.values.any((v) => v.contains('.git-credentials')),
        isFalse,
        reason: 'credentials must never be written to disk',
      );

      await GitHubService.I.signOut();

      expect(SandboxService.I.gitCredentialToken, isNull);
      expect(
        SandboxService.I.sandboxEnvForTest().containsKey('GIT_CONFIG_COUNT'),
        isFalse,
      );
    });
  });
}

String _bash() =>
    File('/bin/bash').existsSync() ? '/bin/bash' : '/usr/bin/bash';

Future<Process> _spawnShell() =>
    Process.start(_bash(), ['--norc'], workingDirectory: '/tmp');

Future<void> _waitFor(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 10),
  String reason = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $reason');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
