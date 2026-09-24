import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/global_repo_registry.dart';
import 'package:ovid_ai/core/grant_store.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

/// Issue 3 — the agent's git_clone must not re-clone a GitHub repo into
/// every session's workspace. In Studio mode a github.com URL routes
/// through GlobalRepoRegistry (clone-once per repo+branch) and binds the
/// session; non-GitHub URLs, explicit `path` destinations, and non-Studio
/// modes keep the raw per-session clone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory ledgerDir;
  late AppState app;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ledgerDir = Directory.systemTemp.createTempSync('git-clone-reg-');
    SessionLedger.rootOverrideForTest = ledgerDir;
    SessionSearch.dbPathOverrideForTest = '${ledgerDir.path}/search.db';
    if (Platform.isLinux) {
      open.overrideFor(OperatingSystem.linux, () {
        try {
          return ffi.DynamicLibrary.open('libsqlite3.so.0');
        } catch (_) {
          return ffi.DynamicLibrary.open(
            '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
          );
        }
      });
    }
    app = AppState.I;
    await app.initialize();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app.sessions.clear();
    app.activeSessionId = null;
  });

  tearDown(() {
    AgentService.registryOverrideForTest = null;
    AgentService.setRunSessionForTest('');
    app.activeSessionId = null;
  });

  /// A studio session with [host] pre-granted and the run session pinned.
  ChatSession makeStudioSession(String id, String host) {
    final s = ChatSession(
      id: id,
      title: 'Custom title',
      providerId: 'ollama-local',
      model: 'test-model',
      mode: 'studio',
    );
    s.grants.add(PermissionGrant.host(host, sessionId: s.id));
    app.sessions.add(s);
    app.activeSessionId = s.id;
    AgentService.setRunSessionForTest(s.id);
    return s;
  }

  /// Fake registry whose git runner records calls and materializes the
  /// destination dir (so ensureCloned succeeds without network).
  ({GlobalRepoRegistry registry, List<List<String>> calls}) fakeRegistry() {
    final calls = <List<String>>[];
    final base = Directory.systemTemp.createTempSync('fake-reg-');
    final registry = GlobalRepoRegistry.createForTest(
      baseDir: base,
      gitRunner: (repoFull, branch, dest) async {
        calls.add([repoFull, branch]);
        await Directory(dest).create(recursive: true);
      },
    );
    addTearDown(() {
      try {
        base.deleteSync(recursive: true);
      } catch (_) {}
    });
    return (registry: registry, calls: calls);
  }

  group('github URL parsing', () {
    test('https forms resolve to owner/repo', () {
      expect(
        AgentService.githubRepoFullForTest('https://github.com/acme/widget'),
        'acme/widget',
      );
      expect(
        AgentService.githubRepoFullForTest(
          'https://github.com/acme/widget.git',
        ),
        'acme/widget',
      );
      expect(
        AgentService.githubRepoFullForTest('https://github.com/acme/widget/'),
        'acme/widget',
      );
    });

    test('scp-like git@github.com: form resolves to owner/repo', () {
      expect(
        AgentService.githubRepoFullForTest('git@github.com:acme/widget.git'),
        'acme/widget',
      );
      expect(
        AgentService.githubRepoFullForTest('git@github.com:acme/widget'),
        'acme/widget',
      );
    });

    test('non-GitHub URLs and non-repo paths return null', () {
      expect(
        AgentService.githubRepoFullForTest('https://gitlab.com/acme/widget'),
        isNull,
      );
      expect(
        AgentService.githubRepoFullForTest(
          'https://example.com/acme/widget.git',
        ),
        isNull,
      );
      expect(
        AgentService.githubRepoFullForTest('https://github.com/acme'),
        isNull,
      );
      expect(
        AgentService.githubRepoFullForTest(
          'https://github.com/acme/widget/tree/main',
        ),
        isNull,
      );
      expect(AgentService.githubRepoFullForTest('not a url'), isNull);
      expect(AgentService.githubRepoFullForTest(''), isNull);
    });
  });

  group('git_clone registry routing (Studio)', () {
    test('github URL clones once via the registry and binds the session',
        () async {
      final s = makeStudioSession('gc-1', 'github.com');
      final fake = fakeRegistry();
      AgentService.registryOverrideForTest = fake.registry;
      // The branch the user picked in the Studio screen.
      AgentService.I.sessionBranch = 'feature-x';

      final out = await AgentService.I
          .dispatchForTest('git_clone', {
            'url': 'https://github.com/acme/widget.git',
          })
          .timeout(const Duration(seconds: 30));

      expect(fake.calls.length, 1);
      expect(fake.calls.single, ['acme/widget', 'feature-x']);
      final sid = s.sandboxId ?? s.id;
      final bound = fake.registry.boundWorkspaceFor(sid);
      expect(bound, isNotNull);
      expect(out, contains(bound!));
      expect(out, contains('shared registry'));

      // Second clone of the same repo+branch reuses the shared copy —
      // the git runner is NOT invoked again.
      final out2 = await AgentService.I
          .dispatchForTest('git_clone', {
            'url': 'https://github.com/acme/widget.git',
          })
          .timeout(const Duration(seconds: 30));
      expect(fake.calls.length, 1, reason: 'clone-once: no second clone');
      expect(out2, contains(bound));
    });

    test('explicit branch arg wins over the Studio-picked branch', () async {
      makeStudioSession('gc-2', 'github.com');
      final fake = fakeRegistry();
      AgentService.registryOverrideForTest = fake.registry;
      AgentService.I.sessionBranch = 'feature-x';

      await AgentService.I
          .dispatchForTest('git_clone', {
            'url': 'git@github.com:acme/widget.git',
            'branch': 'release-2',
          })
          .timeout(const Duration(seconds: 30));

      expect(fake.calls.length, 1);
      expect(fake.calls.single, ['acme/widget', 'release-2']);
    });

    test('explicit path destination keeps the raw per-session clone',
        () async {
      makeStudioSession('gc-3', 'github.com');
      final fake = fakeRegistry();
      AgentService.registryOverrideForTest = fake.registry;

      final out = await AgentService.I
          .dispatchForTest('git_clone', {
            'url': 'https://github.com/acme/widget.git',
            'path': 'my-checkout',
          })
          .timeout(const Duration(seconds: 30));

      // Registry untouched — the raw clone path runs (and reports the
      // missing sandbox in tests instead of cloning).
      expect(fake.calls, isEmpty);
      expect(out, contains('sandbox not installed'));
    });

    test('non-GitHub URL keeps the raw per-session clone', () async {
      final s = makeStudioSession('gc-4', 'gitlab.com');
      s.grants.add(PermissionGrant.host('github.com', sessionId: s.id));
      final fake = fakeRegistry();
      AgentService.registryOverrideForTest = fake.registry;

      final out = await AgentService.I
          .dispatchForTest('git_clone', {
            'url': 'https://gitlab.com/acme/widget.git',
          })
          .timeout(const Duration(seconds: 30));

      expect(fake.calls, isEmpty);
      expect(out, contains('sandbox not installed'));
    });

    test('non-Studio mode keeps the raw per-session clone', () async {
      final s = ChatSession(
        id: 'gc-5',
        title: 'Custom title',
        providerId: 'ollama-local',
        model: 'test-model',
        mode: 'auto',
      );
      s.grants.add(PermissionGrant.host('github.com', sessionId: s.id));
      app.sessions.add(s);
      app.activeSessionId = s.id;
      AgentService.setRunSessionForTest(s.id);
      addTearDown(() {
        app.sessions.removeWhere((x) => x.id == s.id);
      });
      final fake = fakeRegistry();
      AgentService.registryOverrideForTest = fake.registry;

      final out = await AgentService.I
          .dispatchForTest('git_clone', {
            'url': 'https://github.com/acme/widget.git',
          })
          .timeout(const Duration(seconds: 30));

      // General mode keeps isolated per-session workspaces: no registry.
      expect(fake.calls, isEmpty);
      expect(out, contains('sandbox not installed'));
    });

    test('tool description tells the model GitHub clones are shared',
        () async {
      final s = makeStudioSession('gc-6', 'github.com');
      addTearDown(() {
        app.sessions.removeWhere((x) => x.id == s.id);
      });
      final fns = <String, String>{};
      for (final t in AgentService.I.toolsForTest()) {
        final fn = (t['function'] as Map).cast<String, dynamic>();
        fns[fn['name'] as String] = fn['description'] as String;
      }
      final desc = fns['git_clone']!;
      // Note: request-time descriptions are compacted to 160 chars, so
      // assert on the head of the text.
      expect(desc, contains('SHARED'));
      expect(desc, contains('CLONE-ONCE'));
    });
  });
}
