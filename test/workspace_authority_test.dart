import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/state.dart';

/// One workspace authority per session (2026-09-24).
///
/// `setSessionWorkspaceFolder` only ever touched the FOREGROUND session. With
/// 10+ sessions able to run in parallel, an agent cloning a repo in a background
/// session would have repointed whichever chat the user happened to be looking
/// at — and the agent's own cwd would stay unpinned, so `_sessionWorkDir`
/// (which prefers the pinned folder) and the Studio terminal (which prefers the
/// registry binding) could disagree about where the session lives.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    app.sessions.clear();
  });

  tearDown(AppState.resetTestInstance);

  ChatSession add(String id) {
    final s = ChatSession(id: id, title: id, model: 'm', mode: 'studio');
    app.sessions.add(s);
    return s;
  }

  group('the setter can target a specific session', () {
    test('an explicit sessionId pins THAT session, not the foreground one', () {
      final active = add('active');
      final background = add('background');
      app.activeSessionId = active.id;

      app.setSessionWorkspaceFolder('/repos/widget', sessionId: background.id);

      expect(background.workspaceFolder, '/repos/widget');
      expect(
        active.workspaceFolder,
        isNull,
        reason: 'the visible chat must not be repointed by a background run',
      );
    });

    test('no sessionId keeps the old foreground behaviour', () {
      final active = add('active');
      app.activeSessionId = active.id;

      app.setSessionWorkspaceFolder('/repos/widget');

      expect(active.workspaceFolder, '/repos/widget');
    });

    test('an unknown sessionId falls back rather than throwing', () {
      final active = add('active');
      app.activeSessionId = active.id;

      app.setSessionWorkspaceFolder('/repos/x', sessionId: 'nope');

      expect(active.workspaceFolder, '/repos/x');
    });

    test('clearing works per session too', () {
      final a = add('a');
      final b = add('b');
      app.activeSessionId = a.id;
      app.setSessionWorkspaceFolder('/x', sessionId: a.id);
      app.setSessionWorkspaceFolder('/y', sessionId: b.id);

      app.setSessionWorkspaceFolder(null, sessionId: b.id);

      expect(a.workspaceFolder, '/x');
      expect(b.workspaceFolder, isNull);
    });
  });

  group('the branch picker moves the working copy, not just the API view', () {
    test('picking a branch rebinds the registry clone', () {
      // `_autoSync` rebinds only the API-based RepoCache. Without the rebind,
      // the file tree showed branch B while the on-disk clone, the registry
      // binding and the pinned folder all still pointed at branch A — and a
      // later agent git_clone with no explicit branch created a SECOND global
      // clone, so "exactly once" became "once per (repo, branch)".
      final src = File('lib/ui/studio_screen.dart').readAsStringSync();
      final pick = src.substring(src.indexOf('Future<void> _pickBranch()'));
      final body = pick.substring(0, pick.indexOf('\n  }\n'));
      expect(body, contains('_rebindCloneToBranch(repo, picked)'));

      final helper = src.substring(
        src.indexOf('Future<void> _rebindCloneToBranch('),
      );
      expect(helper, contains('boundWorkspaceFor(sid) == null'));
      expect(
        helper,
        contains('_cloneIntoRegistry(reg, sid, repo, branch)'),
        reason: 'the rebind must go through the clone-once path',
      );
    });

    test('the agent clone path pins the run session, not the active one', () {
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      final i = src.indexOf('ONE workspace authority');
      expect(i, greaterThan(-1));
      final region = src.substring(i, i + 900);
      expect(region, contains('sessionId: runSid'));
      expect(
        region,
        isNot(contains('setSessionWorkspaceFolder(sharedPath);')),
        reason: 'a bare call would pin the foreground session',
      );
    });
  });
}
