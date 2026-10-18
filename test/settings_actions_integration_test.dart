import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/composer_drafts.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/memory_store.dart';
import 'package:ovid_ai/core/presets.dart';
import 'package:ovid_ai/core/secure_store.dart';
import 'package:ovid_ai/core/settings_actions.dart';
import 'package:ovid_ai/core/settings_backup_service.dart';
import 'package:ovid_ai/core/session_history_store.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/studio_drafts.dart';
import 'package:ovid_ai/core/tool_usage_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences() : super.empty();
  Future<bool> Function(String, Object)? beforeWrite;
  bool throwAfterImportWrite = false;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (beforeWrite != null && !await beforeWrite!(key, value)) return false;
    final result = await super.setValue(type, key, value);
    if (throwAfterImportWrite && key == 'flutter.ovid_sessions' &&
        (value as List).length == 2) {
      throwAfterImportWrite = false;
      throw StateError('storage failed after accepting the candidate');
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final defaultClearWebCookies = AppState.clearWebCookies;
  late Directory root;
  late AppState app;
  late SharedPreferences prefs;
  late _Preferences backend;
  late ChatSession original;
  late MemoryStore memory;
  late Set<String> originalWorkspacePaths;
  late File existingWorkspaceFile;

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
    // No WebView platform in unit tests: model an emptied cookie jar.
    AppState.clearWebCookies = () async => false;
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
    memory = MemoryStore(Directory('${root.path}/memory'));
    app = AppState.createForTest(memoryStore: memory);
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
    AppState.clearWebCookies = defaultClearWebCookies;
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

  test('production owner restores inactive new IDs and durable attachments', () async {
    final oldRows = prefs.getStringList('ovid_sessions')!;
    await boundService().restore(await archive(attachment: true), root);
    expect(app.sessions, hasLength(2));
    expect(app.activeSessionId, 'existing');
    final imported = app.sessions.singleWhere((s) => s.id != 'existing');
    expect(imported.id, startsWith('restored-'));
    expect(imported.sandboxId, imported.id);
    expect(imported.grants, isEmpty);
    expect(imported.messages.single.content, 'Imported transcript');
    final path = imported.messages.single.attachments.single.path!;
    expect(await File(path).readAsString(), 'portable');
    expect(path, contains('workspaces'));
    expect(path, contains('/ws_${imported.sandboxId}/'));
    expect(root.listSync().whereType<Directory>().where(
      (d) => d.path.split('/').last.startsWith('ovid-restore-')), isEmpty);
    await prefs.reload();
    expect(prefs.getStringList('ovid_sessions')!.first, oldRows.first);
    expect(prefs.getStringList('ovid_sessions'), hasLength(2));
    expect(prefs.getString('ovid_session_bootstrap_v1'), 'original snapshot');
    expect(prefs.getBool('show_reasoning'), false);
  });

  test('rejected publication rolls back disk, live state and copied files', () async {
    final oldRows = prefs.getStringList('ovid_sessions');
    backend.beforeWrite = (key, value) async =>
        !(key == 'flutter.ovid_sessions' && (value as List).length == 2);
    await expectLater(boundService().restore(await archive(attachment: true), root),
        throwsStateError);
    await prefs.reload();
    expect(prefs.getStringList('ovid_sessions'), oldRows);
    expect(app.sessions.map((s) => s.id), ['existing']);
    expect(prefs.getString('ovid_session_bootstrap_v1'), 'original snapshot');
    expect(prefs.getBool('show_reasoning'), false);
    expect(Directory('${root.path}/workspaces').listSync()
        .map((entry) => entry.path).toSet(), originalWorkspacePaths);
    expect(existingWorkspaceFile.readAsStringSync(), 'pre-existing workspace data');
  });

  test('ID collisions are rejected under the owner barrier', () async {
    final service = boundService();
    final staged = await service.stage(await archive(), root);
    try {
      await expectLater(SettingsActions.restorePublisher!(staged,
          {'existing': 'existing'}), throwsStateError);
      expect(app.sessions.map((s) => s.id), ['existing']);
    } finally {
      await staged.dispose();
    }
  });

  test('storage throwing after mutation restores the exact previous rows', () async {
    final saved = prefs.getStringList('ovid_sessions');
    backend.throwAfterImportWrite = true;
    await expectLater(boundService().restore(await archive(), root), throwsStateError);
    await prefs.reload();
    expect(prefs.getStringList('ovid_sessions'), saved);
    expect(app.sessions.map((s) => s.id), ['existing']);
    expect(prefs.getString('ovid_session_bootstrap_v1'), 'original snapshot');
  });

  test('an existing workspace is never overwritten for a restored ID', () async {
    final service = boundService();
    final staged = await service.stage(await archive(attachment: true), root);
    final id = 'restored-${'2' * 32}';
    final workspace = await Directory('${root.path}/workspaces/ws_$id')
        .create(recursive: true);
    final retained = File('${workspace.path}/keep')..writeAsStringSync('original');
    try {
      await expectLater(SettingsActions.restorePublisher!(staged,
          {'existing': id}), throwsStateError);
      expect(retained.readAsStringSync(), 'original');
      expect(workspace.listSync(), hasLength(1));
      expect(app.sessions.map((s) => s.id), ['existing']);
    } finally {
      await staged.dispose();
    }
  });

  test('missing staged attachment never publishes any transcript', () async {
    final service = boundService();
    final staged = await service.stage(await archive(attachment: true), root);
    await staged.attachments.values.single.delete();
    try {
      await expectLater(SettingsActions.restorePublisher!(staged,
          {'existing': 'restored-${'1' * 32}'}), throwsStateError);
      expect(app.sessions.map((s) => s.id), ['existing']);
      await prefs.reload();
      expect(prefs.getStringList('ovid_sessions'), hasLength(1));
    } finally {
      await staged.dispose();
    }
  });

  test('publisher captured before an account change cannot restore into B', () async {
    final service = boundService();
    final bytes = await archive();
    await app.transitionSessionAccount('B');
    await expectLater(service.restore(bytes, root), throwsStateError);
    expect(app.sessionAccountId, 'B');
    expect(app.sessions.any((s) => s.title == 'Imported'), false);
    await prefs.reload();
    expect(prefs.getStringList('ovid_sessions'), hasLength(1));
    expect(prefs.getStringList('ovid_sessions_owner_B'), isNull);
  });

  test('restore before namespace hydration cannot replace unloaded history', () async {
    AppState.createForTest();
    final service = boundService();
    await expectLater(service.restore(await archive(), root), throwsStateError);
    await prefs.reload();
    expect(prefs.getStringList('ovid_sessions'), hasLength(1));
    expect(prefs.getString('ovid_session_bootstrap_v1'), 'original snapshot');
  });

  test('account transition waits for in-flight restore rollback', () async {
    final saved = prefs.getStringList('ovid_sessions');
    final entered = Completer<void>();
    final release = Completer<void>();
    backend.beforeWrite = (key, value) async {
      if (key == 'flutter.ovid_sessions' && (value as List).length == 2) {
        entered.complete();
        await release.future;
      }
      return true;
    };
    final restore = boundService().restore(await archive(attachment: true), root);
    final failed = expectLater(restore, throwsStateError);
    await entered.future;
    expect(app.sessionAccountReady, false);
    var transitioned = false;
    final transition = app.transitionSessionAccount('B').then((_) {
      transitioned = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(transitioned, false);
    release.complete();
    await failed;
    await transition;
    await prefs.reload();
    expect(app.sessionAccountId, 'B');
    expect(app.sessionAccountReady, true);
    expect(prefs.getStringList('ovid_sessions'), saved);
    expect(prefs.getStringList('ovid_sessions_owner_B'), isNull);
    expect(Directory('${root.path}/workspaces').listSync()
        .map((entry) => entry.path).toSet(), originalWorkspacePaths);
    expect(existingWorkspaceFile.readAsStringSync(), 'pre-existing workspace data');
  });

  test('racing session edits abort publication without undoing the edit', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    backend.beforeWrite = (key, value) async {
      if (key == 'flutter.ovid_sessions' && (value as List).length == 2) {
        entered.complete();
        await release.future;
      }
      return true;
    };
    final restore = boundService().restore(await archive(), root);
    final failed = expectLater(restore, throwsStateError);
    await entered.future;
    app.renameSession('existing', 'Edited while copying');
    expect(() => app.deleteSession('existing'), throwsStateError);
    release.complete();
    await failed;
    expect(app.sessions.single.title, 'Edited while copying');
    await prefs.reload();
    expect(prefs.getStringList('ovid_sessions'), hasLength(1));
  });

  test('restore waits for pending setting writes and fences active work', () async {
    final service = boundService();
    final staged = await service.stage(await archive(), root);
    final entered = Completer<void>();
    final release = Completer<void>();
    final token = app.sessionAccountToken;
    AgentService.I.setActiveRunForTest('existing', 'active-before-reset');
    expect(AgentService.I.busyFor('existing'), true);
    final write = SettingsActions.persist('pending-setting', true, () async {
      entered.complete();
      await release.future;
      await prefs.setBool('pending-setting', true);
    });
    await entered.future;
    var finished = false;
    final restore = service.publisher!(staged,
        {'existing': 'restored-${'3' * 32}'}).then((_) {
      finished = true;
    });
    expect(identical(app.sessionAccountToken, token), false);
    expect(app.sessionAccountReady, false);
    expect(AgentService.I.busyFor('existing'), false);
    await Future<void>.delayed(Duration.zero);
    expect(finished, false);
    release.complete();
    await write;
    await restore;
    await staged.dispose();
    expect(app.sessionAccountReady, true);
    await prefs.reload();
    expect(prefs.getBool('pending-setting'), true);
    expect(prefs.getStringList('ovid_sessions'), hasLength(2));
  });

  test('restore applies the allowlisted settings snapshot with the transcripts', () async {
    await prefs.setString('ovid_theme_mode', 'light');
    await prefs.setBool('ovid_keep_alive', false);
    await prefs.setBool('ovid_show_reasoning', true);
    final bytes = await SettingsBackupService(attachmentRoots: [root]).export([
      ChatSession(
        id: 'existing', title: 'Imported', model: 'untrusted',
        messages: [Message(role: 'user', content: 'Imported transcript')],
      ),
    ], settings: {'ovid_theme_mode': 'dark', 'ovid_keep_alive': true});
    await boundService().restore(bytes, root);
    await prefs.reload();
    expect(prefs.getString('ovid_theme_mode'), 'dark');
    expect(prefs.getBool('ovid_keep_alive'), true);
    // The snapshot is a full allowlist section: an allowlisted key absent from
    // it is removed, while non-allowlisted app state is untouched.
    expect(prefs.getBool('ovid_show_reasoning'), isNull);
    expect(prefs.getString('ovid_session_bootstrap_v1'), 'original snapshot');
    expect(app.sessions, hasLength(2));
  });

  test('failed settings apply rolls back settings and transcripts together', () async {
    await prefs.setString('ovid_theme_mode', 'light');
    await prefs.setBool('ovid_keep_alive', true);
    final saved = prefs.getStringList('ovid_sessions');
    backend.beforeWrite = (key, value) async =>
        !(key == 'flutter.ovid_theme_mode' && value == 'dark');
    final bytes = await SettingsBackupService(attachmentRoots: [root]).export([
      ChatSession(
        id: 'existing', title: 'Imported', model: 'untrusted',
        messages: [Message(role: 'user', content: 'Imported transcript')],
      ),
    ], settings: {'ovid_theme_mode': 'dark'});
    await expectLater(boundService().restore(bytes, root), throwsStateError);
    await prefs.reload();
    expect(prefs.getString('ovid_theme_mode'), 'light');
    expect(prefs.getBool('ovid_keep_alive'), true);
    expect(prefs.getStringList('ovid_sessions'), saved);
    expect(app.sessions.map((s) => s.id), ['existing']);
  });

  test('wired all-store reset clears verifiable stores and reports the rest truthfully', () async {
    memory.save(null, 'MEMORY.md', 'Forget global', mode: 'append');
    memory.save('existing', 'MEMORY.md', 'Forget session', mode: 'append');
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
        'ledger',
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
    expect(memory.root.existsSync(), isFalse);
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
    ToolUsageStore.I.resetForTest();
    ToolUsageStore.saveDelayForTest = Duration.zero;
    StudioDraftStore.I.enable(root: () async => root);
    SessionHistoryRepository.I.enableSqlite(
      path: '${root.path}/chat-history.db',
      backgroundSearch: false,
    );
    // Migrate this account's prefs rows into SQLite, as production startup
    // does, so the reset owns a loaded namespace.
    await app.loadSessions();
    SessionLedger.rootOverrideForTest =
        Directory('${root.path}/session-ledgers')..createSync(recursive: true);
    addTearDown(() async {
      SessionLedger.rootOverrideForTest = null;
      StudioDraftStore.I.disableForTest();
      ComposerDraftStore.I.resetForTest();
      ToolUsageStore.I.resetForTest();
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
    ToolUsageStore.I.record(
      kind: ToolUsageKind.pluginTool,
      tool: 'search',
      mcpServerId: 'srv',
      ok: true,
      elapsed: const Duration(milliseconds: 5),
    );
    await ToolUsageStore.I.flush();
    // Another account's namespace in chat-history.db.
    await SessionHistoryRepository.I.writeRows(prefs, 'ovid_sessions__other', [
      jsonEncode(original.toJson()),
    ]);
    expect(await ComposerDraftStore.I.isEmpty(), isFalse);
    expect(await StudioDraftStore.I.isEmpty(), isFalse);
    expect(await ToolUsageStore.I.isEmpty(), isFalse);
    expect(await SessionHistoryRepository.I.isEmpty(), isFalse);

    final report = await SettingsActions.resetAll!();

    expect(report.failures, isEmpty);
    expect(report.success, isTrue);
    expect(report.completed, containsAll(['drafts', 'tool-usage', 'sessions']));
    expect(await ComposerDraftStore.I.isEmpty(), isTrue);
    expect(await StudioDraftStore.I.isEmpty(), isTrue);
    expect(await ToolUsageStore.I.isEmpty(), isTrue);
    expect(await SessionHistoryRepository.I.isEmpty(), isTrue);
    expect(AgentService.I.studioDraftsEmpty, isTrue);
    expect(McpService.I.oauthMemoryEmpty, isTrue);
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
    var cookieClears = 0;
    AppState.clearWebCookies = () async => cookieClears++ == 0;
    // SessionLedger.I caches the first test's (since deleted) root; point it
    // at this test's root so the ledger tombstone can be written.
    SessionLedger.rootOverrideForTest =
        Directory('${root.path}/session-ledgers')..createSync(recursive: true);
    addTearDown(() => SessionLedger.rootOverrideForTest = null);

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
    expect(app.globalPermissionGrants, isEmpty);
    await prefs.reload();
    expect(prefs.getKeys(), isEmpty);
    expect(skill.existsSync(), isFalse);
    expect(export.existsSync(), isFalse);
    expect(backupDir.existsSync(), isFalse);
    expect(exportZip.existsSync(), isFalse);
    expect(shareCache.existsSync(), isFalse);
    expect(cookieClears, 2, reason: 'clear, then readback');
    expect(userFile.readAsStringSync(), 'keep');
  });

  test('a store whose readback still finds data is never reported as success', () async {
    // A cookie jar that keeps reporting cookies after clearing.
    AppState.clearWebCookies = () async => true;
    final report = await SettingsActions.resetAll!();
    expect(report.success, isFalse);
    expect(report.failures.keys, contains('cookies'));
  });

  test('legacy deleteAllData still clears memory preferences and sessions', () async {
    memory.save(null, 'MEMORY.md', 'Forget global', mode: 'append');
    memory.save('existing', 'MEMORY.md', 'Forget session', mode: 'append');
    await prefs.setString('ovid_memories', 'invalid json');
    app.suspendCoalescedPersistenceForTest = false;
    await app.deleteAllData();
    await prefs.reload();
    expect(memory.read(null, 'MEMORY.md').content, isEmpty);
    expect(memory.read('existing', 'MEMORY.md').content, isEmpty);
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
