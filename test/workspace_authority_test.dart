import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/global_repo_registry.dart';

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

  tearDown(() {
    AgentService.setRunSessionForTest('');
    RepoCache.I.unbind();
    AppState.resetTestInstance();
  });

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

    test('a deleted target session never repoints the foreground chat', () {
      final active = add('active');
      app.activeSessionId = active.id;

      app.setSessionWorkspaceFolder('/repos/x', sessionId: 'nope');

      expect(active.workspaceFolder, isNull);
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

  test('background agent repo and branch follow its run session', () async {
    final active = add('foreground')..repo = 'owner/foreground'
      ..branch = 'main';
    final background = add('background')..repo = 'owner/background'
      ..branch = 'feature/work';
    app.activeSessionId = active.id;
    AgentService.setRunSessionForTest(background.id);
    expect(AgentService.I.sessionRepoFull, 'owner/background');
    expect(AgentService.I.sessionBranch, 'feature/work');
    AgentService.I.sessionBranch = 'release';
    expect(background.branch, 'release');
    expect(active.branch, 'main');
  });

  test('rebinding cache does not show or commit another branch edits', () {
    final cache = RepoCache.I;
    cache.bind('owner/repo', 'tok', branch: 'main', sessionId: 'a');
    cache.write('main.txt', 'unsaved work');
    cache.bind('owner/repo', 'tok', branch: 'feature', sessionId: 'a');
    expect(cache.files, isEmpty);
    expect(cache.hasPending, isFalse);
    cache.bind('owner/repo', 'tok', branch: 'main', sessionId: 'a');
    expect(cache.read('main.txt'), 'unsaved work');
    expect(cache.hasPending, isTrue);
  });

  test('Studio tabs retain separate buffers when the workspace changes', () {
    final session = add('tabs')..branch = 'main'..workspaceFolder = '/repo/main';
    app.activeSessionId = session.id;
    AgentService.I.openStudioFile('same.txt', 'main draft');
    session.branch = 'feature';
    session.workspaceFolder = '/repo/feature';
    expect(AgentService.I.studioOpenFiles, isEmpty);
    AgentService.I.openStudioFile('same.txt', 'feature draft');
    session.branch = 'main';
    session.workspaceFolder = '/repo/main';
    expect(AgentService.I.fileBuffer['same.txt'], 'main draft');
  });

  test('background file reads use its checkout instead of the foreground cache', () async {
    final root = Directory.systemTemp.createTempSync('background-read-');
    addTearDown(() => root.deleteSync(recursive: true));
    File('${root.path}/shared.txt').writeAsStringSync('background bytes');
    final active = add('visible')..repo = 'owner/visible';
    final background = add('running')..repo = 'owner/running'
      ..branch = 'feature'..workspaceFolder = root.path;
    app.activeSessionId = active.id;
    RepoCache.I.bind('owner/visible', 'token', sessionId: active.id);
    RepoCache.I.files['shared.txt'] = 'foreground bytes';
    AgentService.setRunSessionForTest(background.id);
    final result = await AgentService.I.dispatchForTest('file_read', {'path': 'shared.txt'});
    expect(result, contains('background bytes'));
    expect(result, isNot(contains('foreground bytes')));
  });

  test('selected folder supplies sandbox cwd, agent context and Studio bytes', () async {
    final root = Directory.systemTemp.createTempSync('authority-');
    addTearDown(() => root.deleteSync(recursive: true));
    final old = Directory('${root.path}/old')..createSync();
    final selected = Directory('${root.path}/selected')..createSync();
    File('${selected.path}/only-local.txt').writeAsStringSync('local edit');
    final session = add('workspace')..repo = 'owner/project'..branch = 'feature/local';
    app.activeSessionId = session.id;
    final registry = await GlobalRepoRegistry.instance();
    await registry.bindSession(session.id, 'owner/old', 'main', old.path);
    addTearDown(() => registry.unbindSession(session.id));
    app.setSessionWorkspaceFolder(selected.path);
    expect((await SandboxService.I.workDirFor(session.id)).path, selected.path);
    expect(SandboxService.I.workDirForSync(session.id).path, selected.path);
    expect((await AgentService.I.sessionWorkDirForTest()).path, selected.path);
    final context = await AgentService.I.workspaceContext();
    expect(context, contains(selected.path));
    expect(context, contains('owner/project'));
    expect(context, contains('feature/local'));
    RepoCache.I.bind('owner/project', '', branch: 'feature/local',
      sessionId: session.id, workspaceFolder: selected.path);
    await RepoCache.I.sync();
    expect(RepoCache.I.treePaths, contains('only-local.txt'));
    expect(RepoCache.I.read('only-local.txt'), 'local edit');
    File('${selected.path}/only-local.txt').writeAsStringSync('shell edit');
    expect(RepoCache.I.read('only-local.txt'), 'shell edit');
    app.setSessionWorkspaceFolder(null);
    expect(SandboxService.I.workDirForSync(session.id).path, isNot(old.path));
  });

  group('the branch picker moves the working copy, not just the API view', () {
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
