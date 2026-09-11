import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted last selection (spec §5.2).
///
/// A new session must inherit the last repo/workspace folder instead of
/// forcing a fresh selection, and agent tools must resolve the last repo
/// after a restart even when the restored session never bound one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
  });

  tearDown(AppState.resetTestInstance);

  Directory tempFolder(String prefix) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    return dir;
  }

  test('newSession seeds the last repo and an existing workspace folder', () {
    final dir = tempFolder('ovid-last-selection');
    final app = AppState.createForTest();
    app.lastRepoFull = 'owner/repo';
    app.lastWorkspaceFolder = dir.path;

    app.newSession();

    final session = app.activeSession!;
    expect(session.repo, 'owner/repo');
    expect(session.workspaceFolder, dir.path);
  });

  test('newSession leaves repo and folder unset when none persisted', () {
    final app = AppState.createForTest();

    app.newSession();

    final session = app.activeSession!;
    expect(session.repo, isNull);
    expect(session.workspaceFolder, isNull);
  });

  test('newSession does not seed a stale workspace folder', () {
    final app = AppState.createForTest();
    app.lastWorkspaceFolder = '/definitely/not/a/real/folder/ovid-missing';

    app.newSession();

    // A vanished folder must fall back to the per-session sandbox.
    expect(app.activeSession!.workspaceFolder, isNull);
  });

  test('repo/folder/branch persist to prefs and reload after restart', () async {
    final dir = tempFolder('ovid-last-selection-roundtrip');
    final app = AppState.createForTest();
    final id = app.activeSession!.id;
    app.lastBranch = 'release';
    app.setSessionWorkspaceFolder(dir.path);
    await pumpEventQueue();
    app.setRepoForSession(id, 'owner/repo');
    await pumpEventQueue();

    AppState.resetTestInstance();
    final restarted = AppState.createForTest();
    await restarted.initializeForFirstFrame();

    expect(restarted.lastRepoFull, 'owner/repo');
    expect(restarted.lastWorkspaceFolder, dir.path);
    expect(restarted.lastBranch, 'release');
  });

  test('clearing the workspace folder clears the persisted selection', () async {
    final dir = tempFolder('ovid-last-selection-clear');
    final app = AppState.createForTest();
    app.setSessionWorkspaceFolder(dir.path);
    await pumpEventQueue();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ovid_last_workspace'), dir.path);

    app.setSessionWorkspaceFolder(null);
    await pumpEventQueue();

    expect(prefs.getString('ovid_last_workspace'), isNull);
  });

  test('lastBranch defaults to main', () async {
    final app = AppState.createForTest();

    await app.initializeForFirstFrame();

    expect(app.lastBranch, 'main');
  });

  test('getRepoForSession falls back to the persisted repo after restart', () async {
    SharedPreferences.setMockInitialValues({'ovid_last_repo': 'owner/restored'});
    final app = AppState.createForTest();
    await app.initializeForFirstFrame();

    final session = app.activeSession!;
    session.repo = null;

    expect(app.getRepoForSession(session.id), 'owner/restored');
  });

  test('explicit fallback still wins over the persisted repo', () async {
    SharedPreferences.setMockInitialValues({'ovid_last_repo': 'owner/restored'});
    final app = AppState.createForTest();
    await app.initializeForFirstFrame();

    final session = app.activeSession!;
    session.repo = null;

    expect(
      app.getRepoForSession(session.id, fallback: 'caller/global'),
      'caller/global',
    );
  });

  test('last selection backfills from the restored active session', () async {
    final dir = tempFolder('ovid-last-selection-upgrade');
    final raw = jsonEncode(
      ChatSession(
        id: 'active',
        title: 'Saved chat',
        model: 'test-model',
        repo: 'owner/upgraded',
        workspaceFolder: dir.path,
      ).toJson(),
    );
    SharedPreferences.setMockInitialValues({
      'ovid_sessions': [raw],
      'ovid_active_session': 'active',
    });
    final app = AppState.createForTest();

    await app.initializeForFirstFrame();

    expect(app.lastRepoFull, 'owner/upgraded');
    expect(app.lastWorkspaceFolder, dir.path);
  });
}
