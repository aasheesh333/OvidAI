import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/memory_store.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/settings_actions.dart';
import 'package:ovid_ai/core/settings_backup_service.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';
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
    final workspace = await SandboxService.I.workDirFor(provisional);
    existingWorkspaceFile = File('${workspace.path}/keep.txt');
    await existingWorkspaceFile.writeAsString('pre-existing workspace data');
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
    await root.delete(recursive: true);
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
    expect(imported.schedules, isEmpty);
    expect(imported.grants, isEmpty);
    expect(imported.messages.single.content, 'Imported transcript');
    final path = imported.messages.single.attachments.single.path!;
    expect(await File(path).readAsString(), 'portable');
    expect(path, contains('/workspaces/'));
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

    // Stores with a readback probe are genuinely cleared and reported complete.
    expect(
      report.completed,
      containsAll(['sessions', 'memory', 'account', 'image-receipts']),
    );
    // Stores without a readback API are reported unsupported, never success.
    expect(report.failures.keys, containsAll(['search', 'ledger', 'shares']));
    expect(report.verifiedComplete, isFalse);
    expect(report.success, isFalse);

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
