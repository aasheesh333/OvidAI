import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ovid_ai/core/cloud/studio_remote_client.dart';
import 'package:ovid_ai/core/composer_drafts.dart';
import 'package:ovid_ai/core/presets.dart';
import 'package:ovid_ai/core/secure_store.dart';
import 'package:ovid_ai/core/settings_actions.dart';
import 'package:ovid_ai/core/settings_backup_service.dart';
import 'package:ovid_ai/core/session_history_store.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/studio_drafts.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences() : super.empty();
  Future<bool> Function(String, Object)? beforeWrite;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (beforeWrite != null && !await beforeWrite!(key, value)) return false;
    return super.setValue(type, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppState app;
  late SharedPreferences prefs;
  late _Preferences backend;
  late ChatSession original;
  late Set<String> originalWorkspacePaths;
  late File existingWorkspaceFile;

  /// Seed the pre-cloud Markdown memory layout directly (the local store was
  /// deleted in P8 Task 20): `global/` and `session-<sha256(owner)>/`.
  void seedMemory(String owner, String content) {
    final memoryRoot = Directory('${root.path}/memory');
    File('${memoryRoot.path}/global/MEMORY.md')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    final session = Directory(
      '${memoryRoot.path}/session-${sha256.convert(utf8.encode(owner))}',
    )..createSync(recursive: true);
    File('${session.path}/MEMORY.md').writeAsStringSync(content);
  }

  setUpAll(() {
    open.overrideFor(OperatingSystem.linux,
        () => ffi.DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('settings-integration-');
    SessionSearch.dbPathOverrideForTest = '${root.path}/search.db';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    backend = _Preferences();
    SharedPreferencesStorePlatform.instance = backend;
    prefs = await SharedPreferences.getInstance();
    original = ChatSession(
      id: 'existing', title: 'Keep me', model: 'm',
      messages: [Message(role: 'user', content: 'Original transcript')],
    );
    await prefs.setStringList('ovid_sessions', [jsonEncode(original.toJson())]);
    await prefs.setString('ovid_active_session', original.id);
    await prefs.setString('ovid_session_bootstrap_v1', 'original snapshot');
    await prefs.setBool('show_reasoning', false);
    app = AppState.createForTest(memoryRootForTest: Directory('${root.path}/memory'));
    // The constructor warms its provisional session's workspace asynchronously.
    // Await that real path before snapshotting existing files: rollback owns
    // only the new import directories, not this already-created workspace.
    final provisional = app.activeSession!.sandboxId!;
    final workspace = localWorkspaceDirFor(provisional);
    existingWorkspaceFile = File('${workspace.path}/keep.txt');
    await existingWorkspaceFile.writeAsString('pre-existing workspace data');
    // P8 Task 13: the local workspace now lives in app-cache scratch space,
    // so this test root may not have a workspaces/ directory at all.
    Directory('${root.path}/workspaces').createSync(recursive: true);
    // The constructor warms its provisional workspace asynchronously; let it
    // land before snapshotting so rollback comparisons see a stable set.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    originalWorkspacePaths = Directory('${root.path}/workspaces')
        .listSync().map((entry) => entry.path).toSet();
    await app.loadSessions();
    app.suspendCoalescedPersistenceForTest = true;
  });

  tearDown(() async {
    backend.beforeWrite = null;
    await SessionSearch.I.close();
    SessionSearch.dbPathOverrideForTest = null;
    AppState.resetTestInstance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'), null,
        );
    // A late workspace warm may still be creating a directory; retry once.
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await root.delete(recursive: true);
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  });

  Future<List<int>> archive({bool attachment = false}) async {
    final file = File('${root.path}/source.txt');
    if (attachment) await file.writeAsString('portable');
    return SettingsBackupService(attachmentRoots: [root]).export([
      ChatSession(
        id: 'existing', title: 'Imported', model: 'untrusted',
        messages: [Message(role: 'user', content: 'Imported transcript',
          attachments: attachment ? [MessageAttachment(
            name: '../display-name.txt', size: 8, path: file.path,
          )] : [])],
      ),
    ]);
  }

  SettingsBackupService boundService() {
    expect(SettingsActions.restorePublisher, isNotNull,
        reason: 'The real AppState constructor must bind the publisher');
    return SettingsBackupService(publisher: SettingsActions.restorePublisher);
  }

  test('SE-009: the bound publisher never writes local restored- rows', () async {
    // Restore now uploads archives to Ovid Cloud (CloudBackup); the state
    // owner's local publisher refuses, so no inactive local-only chat can be
    // created that would never sync and that the model has no history for.
    final oldRows = prefs.getStringList('ovid_sessions');
    final service = boundService();
    await expectLater(
      service.restore(await archive(attachment: true), root),
      throwsUnsupportedError,
    );
    expect(app.sessions.map((s) => s.id), ['existing']);
    expect(app.sessions.where((s) => s.id.startsWith('restored-')), isEmpty);
    await prefs.reload();
    expect(prefs.getStringList('ovid_sessions'), oldRows);
    expect(prefs.getString('ovid_session_bootstrap_v1'), 'original snapshot');
    expect(Directory('${root.path}/workspaces').listSync()
        .map((entry) => entry.path).toSet(), originalWorkspacePaths);
    expect(existingWorkspaceFile.readAsStringSync(), 'pre-existing workspace data');
  });

  test('wired all-store reset clears verifiable stores and reports the rest truthfully', () async {
    seedMemory('existing', 'Forget memory');
    await prefs.setString('ovid_memories', 'invalid json');
    final file = File('${root.path}/user-file')..writeAsStringSync('keep');

    expect(SettingsActions.resetAll, isNotNull);
    final report = await SettingsActions.resetAll!();

    // Every canonical store now has a readback probe, so the reset is verified
    // complete — never merely "delete did not throw".
    expect(
      report.completed,
      containsAll([
        'sessions',
        'search',
        'memory',
        'account',
        'image-receipts',
        'shares',
      ]),
    );
    expect(report.failures.keys, isEmpty);
    expect(report.verifiedComplete, isTrue);
    expect(report.success, isTrue);

    // The verified stores really are empty after the reset.
    await prefs.reload();
    expect(prefs.getStringList('ovid_sessions'), isNull);
    expect(prefs.getString('ovid_active_session'), isNull);
    expect(prefs.getString('ovid_session_bootstrap_v1'), isNull);
    expect(Directory('${root.path}/memory').existsSync(), isFalse);
    expect(app.sessions.any((s) => s.id == 'existing'), isFalse);
    // A user file outside app-owned stores is never touched.
    expect(file.readAsStringSync(), 'keep');
  });

  // Integration: stores added by other branches are part of the verified
  // reset — composer drafts (PR-3b), Studio / repo drafts (PR-3c), tool
  // usage rollups (PR-4b), every chat-history.db namespace (PR-3) and
  // in-memory MCP OAuth attempts (PR-7).
  test('reset clears drafts, tool usage, every history namespace and OAuth memory', () async {
    ComposerDraftStore.I.resetForTest();
    StudioDraftStore.I.enable(root: () async => root);
    SessionHistoryRepository.I.enableSqlite(
      path: '${root.path}/chat-history.db',
      backgroundSearch: false,
    );
    // Migrate this account's prefs rows into SQLite, as production startup
    // does, so the reset owns a loaded namespace.
    await app.loadSessions();
    addTearDown(() async {
      StudioDraftStore.I.disableForTest();
      ComposerDraftStore.I.resetForTest();
      await SessionHistoryRepository.I.resetForTest();
    });

    ComposerDraftStore.I.put('existing', 'half-typed message');
    await ComposerDraftStore.I.flush();
    StudioDraftStore.I.schedule(
      StudioDraftStore.recordName('editor', 'bucket'),
      () => (data: {'v': 1, 'files': {}}),
    );
    StudioDraftStore.I.schedule(
      StudioDraftStore.recordName('repo', 'owner/repo'),
      () => (data: {'v': 1}),
    );
    await StudioDraftStore.I.flush();
    // Another account's namespace in chat-history.db.
    await SessionHistoryRepository.I.writeRows(prefs, 'ovid_sessions__other', [
      jsonEncode(original.toJson()),
    ]);
    expect(await ComposerDraftStore.I.isEmpty(), isFalse);
    expect(await StudioDraftStore.I.isEmpty(), isFalse);
    expect(await SessionHistoryRepository.I.isEmpty(), isFalse);

    final report = await SettingsActions.resetAll!();

    expect(report.failures, isEmpty);
    expect(report.success, isTrue);
    expect(report.completed, containsAll(['drafts', 'sessions']));
    expect(await ComposerDraftStore.I.isEmpty(), isTrue);
    expect(await StudioDraftStore.I.isEmpty(), isTrue);
    expect(await SessionHistoryRepository.I.isEmpty(), isTrue);
    expect(StudioRemoteClient.I.noDrafts, isTrue);
  });

  test('reset removes keys, configuration, settings, skills, exports, cache and cookies', () async {
    final secure = ovidSecureStorage();
    await secure.write(key: 'ovid_provider_key_openai', value: 'sk-secret');
    await secure.write(key: 'github_token', value: 'ghp-secret');
    app.providers.first.apiKey = 'sk-secret';
    PresetRegistry.saveCustom(const AgentPreset(
      id: 'custom-reset', label: 'Custom', description: 'd',
    ));
    await prefs.setString('ovid_custom_presets', '[{"id":"custom-reset"}]');
    await prefs.setString('ovid_permission_grants_v1', '[{"kind":"host"}]');
    await prefs.setString('ovid_provider_configs_v1', '[]');
    await prefs.setString('ovid_mcp_env_server', '{}');
    await prefs.setString('ovid_theme_mode', 'light');
    await prefs.setBool('ovid_sandbox_skipped', true);
    final skill = File('${root.path}/skills/mine.md')
      ..createSync(recursive: true)
      ..writeAsStringSync('# skill');
    final export = File('${root.path}/ovid-sessions-123.json')
      ..writeAsStringSync('{"sessions":[]}');
    final backupDir = Directory('${root.path}/ovid-backup-x')..createSync();
    File('${backupDir.path}/ovid-transcripts-v1.zip').writeAsStringSync('zip');
    final exportZip = File('${root.path}/ovid-export-1.zip')
      ..writeAsStringSync('zip');
    final shareCache = Directory('${root.path}/outgoing-shares')..createSync();
    final userFile = File('${root.path}/user-file')..writeAsStringSync('keep');

    final report = await SettingsActions.resetAll!();

    expect(report.failures, isEmpty);
    expect(report.success, isTrue);
    expect(
      report.completed,
      containsAll([
        'configuration', 'secrets', 'preferences', 'skills', 'exports',
        'cache', 'cookies',
      ]),
    );
    expect(await secure.readAll(), isEmpty);
    expect(app.providers.every((p) => p.apiKey.isEmpty), isTrue);
    expect(PresetRegistry.customPresets, isEmpty);
    await prefs.reload();
    expect(prefs.getKeys(), isEmpty);
    expect(skill.existsSync(), isFalse);
    expect(export.existsSync(), isFalse);
    expect(backupDir.existsSync(), isFalse);
    expect(exportZip.existsSync(), isFalse);
    expect(shareCache.existsSync(), isFalse);
    expect(userFile.readAsStringSync(), 'keep');
  });

  test('legacy deleteAllData still clears memory preferences and sessions', () async {
    seedMemory('existing', 'Forget memory');
    await prefs.setString('ovid_memories', 'invalid json');
    app.suspendCoalescedPersistenceForTest = false;
    await app.deleteAllData();
    await prefs.reload();
    expect(Directory('${root.path}/memory').existsSync(), isFalse);
    expect(prefs.containsKey('ovid_memories'), false);
    expect(prefs.containsKey('show_reasoning'), false);
    expect(app.sessions, hasLength(1));
    expect(app.activeSession!.id, isNot('existing'));
    expect(app.activeSession!.messages, isEmpty);
    expect(prefs.getStringList('ovid_sessions')!.map(
        (raw) => jsonDecode(raw)['id']), [app.activeSessionId]);
    expect(SettingsActions.resetAll, isNotNull);
  });
}
