import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/memory_store.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppState app;
  final ledger = SessionLedger.I;

  setUpAll(() {
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
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    root = await Directory.systemTemp.createTemp('ledger-integration-');
    SessionLedger.rootOverrideForTest = root;
    // Session deletion now drains every store, including the FTS search
    // index; point it at the temp root or the cleanup task fails on the
    // unmocked path_provider channel and persistence stays flagged.
    SessionSearch.dbPathOverrideForTest = '${root.path}/search.db';
    app = AppState.createForTest(
      memoryStore: MemoryStore(Directory('${root.path}/memory')),
      workspaceDeleter: (_) async {},
      pluginBootActivator: (_, _) async {},
    );
    app.suspendCoalescedPersistenceForTest = true;
  });

  tearDown(() async {
    await app.flushSessionPersistence();
    for (final id in ledger.sinkOpensForTest.keys.toList()) {
      await ledger.close(id);
    }
    AppState.resetTestInstance();
    await SessionSearch.I.close();
    SessionSearch.dbPathOverrideForTest = null;
    SessionLedger.rootOverrideForTest = null;
    await root.delete(recursive: true);
  });

  ChatSession session(String id, {String? parentId}) =>
      ChatSession(id: id, title: id, model: 'test', parentId: parentId);

  test(
    'AppState deletes root and deferred child before callback and delayed appends',
    () async {
      final parent = session('parent');
      final child = session('child', parentId: parent.id);
      SharedPreferences.setMockInitialValues({
        'ovid_active_session': parent.id,
        'ovid_sessions': [
          jsonEncode(parent.toJson()),
          jsonEncode(child.toJson()),
        ],
      });
      await app.initializeForFirstFrame();
      expect(app.sessionById('child'), isNull);
      await ledger.append('parent', 'note', {'text': 'old parent'});
      await ledger.append('child', 'note', {'text': 'old child'});
      final release = Completer<void>();
      final callbacks = <String>[];
      final lateWrites = <Future<void>>[];
      app.onSessionDeleted = (id) {
        callbacks.add(id);
        lateWrites.add(ledger.append(id, 'note', {'text': 'callback'}));
        lateWrites.add(
          release.future.then(
            (_) => ledger.append(id, 'note', {'text': 'delayed'}),
          ),
        );
      };
      app.deleteSession('parent');
      await app.flushSessionPersistence();
      expect(callbacks, unorderedEquals(['parent', 'child']));
      release.complete();
      await Future.wait(lateWrites);
      for (final id in ['parent', 'child']) {
        expect(await ledger.read(id), isEmpty);
        expect(File('${root.path}/$id.jsonl').existsSync(), isFalse);
      }
    },
  );

  test(
    'failed ledger cleanup remains awaitable after persistence and retries once',
    () async {
      app.sessions.add(session('failure'));
      await ledger.append('failure', 'note', {'text': 'durable'});
      final obstruction = await Directory(
        '${root.path}/failure.jsonl.deleted',
      ).create();
      var callbacks = 0;
      app.onSessionDeleted = (_) => callbacks++;
      app.deleteSession('failure');
      await app.flushSessionPersistence();
      expect(app.lastSessionPersistFailed, isTrue);
      final errors = await app.awaitSessionLedgerDeletions();
      expect(errors.keys, ['failure']);
      expect(errors['failure'], isA<FileSystemException>());
      await app.flushSessionPersistence();
      expect((await app.awaitSessionLedgerDeletions()).keys, ['failure']);
      expect(
        File('${root.path}/failure.jsonl').readAsStringSync(),
        contains('durable'),
      );
      await obstruction.delete();
      expect(await app.awaitSessionLedgerDeletions(retryFailed: true), isEmpty);
      await app.flushSessionPersistence();
      expect(app.lastSessionPersistFailed, isFalse);
      expect(callbacks, 1);
      await ledger.append('failure', 'note', {'text': 'late'});
      expect(await ledger.read('failure'), isEmpty);
    },
  );

  test(
    'agent warms authoritative hashed transcript and invalidates on deletion',
    () async {
      const id = 'team/private';
      app.sessions.add(session(id));
      final legacy = File('${root.path}/team_private.jsonl');
      await legacy.writeAsString('ambiguous private bytes');
      await ledger.append(id, 'note', {'text': 'owned'});
      final path = await ledger.transcriptPath(id);
      expect(path, isNotNull);
      expect(path, isNot(legacy.path));
      expect(await File(path!).readAsString(), contains('owned'));
      final agent = AgentService.I;
      await agent.warmTranscriptPathForTest(id);
      expect(agent.transcriptPathForTest(id), path);
      // Exercise the real scheduler; invalidation must not depend on an agent
      // callback being installed (deferred cleanup also runs before agent boot).
      app.onSessionDeleted = null;
      app.deleteSession(id);
      expect(agent.transcriptPathForTest(id), '');
      await app.awaitSessionLedgerDeletions();
      await agent.warmTranscriptPathForTest(id);
      expect(agent.transcriptPathForTest(id), '');
      expect(await ledger.transcriptPath(id), isNull);
      expect(await legacy.readAsString(), 'ambiguous private bytes');
    },
  );

  test(
    'close failure retains deletion retry and fences the open handle',
    () async {
      const id = 'close-failure';
      app.sessions.add(session(id));
      final file = File('${root.path}/$id.jsonl');
      final marker = File('${file.path}.deleted');
      final fault = _CloseFailureFile(file);
      var callbacks = 0;
      app.onSessionDeleted = (_) => callbacks++;
      try {
        await IOOverrides.runZoned(
          () async {
            await ledger.append(id, 'note', {'text': 'durable'});
            await ledger.flush(id);
            final original = await file.readAsString();
            app.deleteSession(id);
            final errors = await app.awaitSessionLedgerDeletions();
            expect(errors[id], isA<FileSystemException>());
            expect(marker.existsSync(), isTrue);
            await expectLater(
              ledger.delete(id),
              throwsA(isA<FileSystemException>()),
            );
            await app.flushSessionPersistence();
            await app.flushSessionPersistence();
            expect(app.lastSessionPersistFailed, isTrue);
            expect((await app.awaitSessionLedgerDeletions()).keys, [id]);
            // The failed close leaves a live descriptor: checking only newly opened
            // sinks would allow these writes to bypass the persisted tombstone.
            await ledger.append(id, 'note', {'text': 'late'});
            await ledger.flush(id);
            expect(await file.readAsString(), original);
            expect(await ledger.read(id), isEmpty);
            expect(await ledger.transcriptPath(id), isNull);
            fault.handle!.failClose = false;
            expect(
              await app.awaitSessionLedgerDeletions(retryFailed: true),
              isEmpty,
            );
            expect(fault.handle!.closed, isTrue);
            expect(file.existsSync(), isFalse);
            expect(callbacks, 1);
            await app.flushSessionPersistence();
            expect(app.lastSessionPersistFailed, isFalse);
            await ledger.append(id, 'note', {'text': 'after retry'});
            expect(file.existsSync(), isFalse);
          },
          createFile: (path) {
            if (path == file.path) return fault;
            expect(path, marker.path);
            return marker;
          },
        );
      } finally {
        // Release the real descriptor even when a red assertion aborts the test.
        final handle = fault.handle;
        if (handle != null && !handle.closed) {
          handle.failClose = false;
          await handle.close();
        }
      }
    },
  );

  test(
    'in-flight transcript warm cannot restore deleted cache entry',
    () async {
      const id = 'warm-race';
      await ledger.append(id, 'note', {});
      final agent = AgentService.I;
      final warming = agent.warmTranscriptPathForTest(id);
      final deleting = ledger.delete(id);
      expect(agent.transcriptPathForTest(id), '');
      await Future.wait([warming, deleting]);
      expect(agent.transcriptPathForTest(id), '');
    },
  );

  test(
    'transcript cache invalidates when ledger storage root changes',
    () async {
      const id = 'root-change';
      await ledger.append(id, 'note', {});
      final agent = AgentService.I;
      await agent.warmTranscriptPathForTest(id);
      final oldPath = agent.transcriptPathForTest(id);
      expect(oldPath, isNotEmpty);
      // Close handles before replacing the test store.
      await ledger.close(id);
      final other = await Directory('${root.path}/other').create();
      SessionLedger.rootOverrideForTest = other;
      try {
        expect(agent.transcriptPathForTest(id), '');
        await ledger.append(id, 'note', {'text': 'new root'});
        await agent.warmTranscriptPathForTest(id);
        final newPath = agent.transcriptPathForTest(id);
        expect(newPath, isNot(oldPath));
        expect(await File(newPath).readAsString(), contains('new root'));
      } finally {
        await ledger.close(id);
        SessionLedger.rootOverrideForTest = root;
      }
    },
  );

  test('ledger result does not erase a failed workspace cleanup', () async {
    app = AppState.createForTest(
      memoryStore: MemoryStore(Directory('${root.path}/memory')),
      workspaceDeleter: (_) async => throw StateError('workspace unavailable'),
    );
    app.suspendCoalescedPersistenceForTest = true;
    app.sessions.add(session('workspace-failure'));
    await ledger.append('workspace-failure', 'note', {});
    app.deleteSession('workspace-failure');
    expect(await app.awaitSessionLedgerDeletions(), isEmpty);
    await app.flushSessionPersistence();
    expect(app.lastSessionPersistFailed, isTrue);
    await app.flushSessionPersistence();
    expect(app.lastSessionPersistFailed, isTrue);
    expect(await app.awaitSessionLedgerDeletions(retryFailed: true), isEmpty);
    expect(await ledger.read('workspace-failure'), isEmpty);
  });

  test(
    'deleting another session preserves an active warmed transcript',
    () async {
      await ledger.append('still-active', 'note', {});
      final agent = AgentService.I;
      await agent.warmTranscriptPathForTest('still-active');
      final path = agent.transcriptPathForTest('still-active');
      expect(path, isNotEmpty);
      await ledger.delete('other');
      expect(agent.transcriptPathForTest('still-active'), path);
    },
  );
}

class _CloseFailureFile implements File {
  _CloseFailureFile(this.file);
  final File file;
  _CloseFailureHandle? handle;

  @override
  String get path => file.path;
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      handle = _CloseFailureHandle(await file.open(mode: mode));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CloseFailureHandle implements RandomAccessFile {
  _CloseFailureHandle(this.handle);
  final RandomAccessFile handle;
  bool failClose = true;
  bool closed = false;

  @override
  Future<RandomAccessFile> writeString(
    String string, {
    Encoding encoding = utf8,
  }) => handle.writeString(string, encoding: encoding);
  @override
  Future<RandomAccessFile> flush() => handle.flush();
  @override
  Future<void> close() async {
    if (failClose) throw const FileSystemException('injected close failure');
    await handle.close();
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
