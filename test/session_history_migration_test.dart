import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/session_history_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

const _optionalStages = <String>[
  'marketplace.refresh',
  'mcp.connect',
  'firebase.initialize',
  'github.initialize',
  'sandbox.selfHeal',
  'plugin.activate',
];

String _sessionJson(String id, List<String> messages, {DateTime? at}) =>
    jsonEncode(
      ChatSession(
        id: id,
        title: 'Chat $id',
        model: 'saved-model',
        createdAt: at,
        messages: [
          for (final m in messages) Message(role: 'user', content: m, time: at),
        ],
      ).toJson(),
    );

/// AppState end-to-end over the SQLite history backend: migration from a
/// SharedPreferences fixture (master plan Verification), idempotent re-run,
/// incremental persistence, content search and recency ordering.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isLinux) {
    open.overrideFor(
      OperatingSystem.linux,
      () => ffi.DynamicLibrary.open('libsqlite3.so.0'),
    );
  }

  late Directory root;
  final history = SessionHistoryRepository.I;

  Future<AppState> boot() async {
    AppState.resetTestInstance();
    await history.resetForTest();
    history.enableSqlite(
      path: '${root.path}/history.db',
      backgroundSearch: false,
    );
    final app = AppState.createForTest(
      startupStageDelegates: {
        for (final stage in _optionalStages) stage: () async {},
      },
    );
    await app.initializeForFirstFrame();
    await app.initializeReadiness();
    return app;
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('history-migration-');
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    AppState.resetTestInstance();
    await history.resetForTest();
    root.deleteSync(recursive: true);
  });

  test(
    'upgrade migrates the prefs fixture and re-running is idempotent',
    () async {
      final fixture = [
        for (var i = 0; i < 40; i++)
          _sessionJson('s$i', ['hello $i', 'needle-$i lives here']),
      ];
      SharedPreferences.setMockInitialValues({
        'ovid_sessions': fixture,
        'ovid_active_session': 's0',
      });
      final app = await boot();
      expect(app.sessions.map((s) => s.id), [
        for (var i = 0; i < 40; i++) 's$i',
      ]);
      expect(app.activeSession!.messages, hasLength(2));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('ovid_sessions'), isNull);
      expect(prefs.getStringList(SessionHistoryRepository.migratedMarkerKey), [
        'ovid_sessions',
      ]);
      expect(history.migrationReports.single.imported, 40);

      app
          .sessionById('s7')!
          .messages
          .add(Message(role: 'assistant', content: 'a brand new zebra answer'));
      app.persistSessions();
      await app.flushSessionPersistenceForTest();
      expect(app.lastSessionPersistFailed, isFalse);
      expect(
        prefs.getStringList('ovid_sessions'),
        isNull,
        reason: 'SQLite only',
      );

      final hits = await app.searchSessionContent('zebra');
      expect(hits.single.sessionId, 's7');

      // Next launch: no second migration, the new message survived.
      final again = await boot();
      expect(history.migrationReports, isEmpty);
      expect(again.sessions, hasLength(40));
      expect(
        again.sessionById('s7')!.messages.last.content,
        'a brand new zebra answer',
      );
      expect(
        (await again.searchSessionContent('needle-12')).single.sessionId,
        's12',
      );
    },
  );

  test(
    'large history hydrates through the background-isolate decoder',
    () async {
      final previous = AppState.hydrationIsolateThreshold;
      AppState.hydrationIsolateThreshold = 0;
      addTearDown(() => AppState.hydrationIsolateThreshold = previous);
      SharedPreferences.setMockInitialValues({
        'ovid_sessions': [
          for (var i = 0; i < 30; i++)
            _sessionJson('h$i', [
              for (var m = 0; m < 60; m++) 'h$i message $m',
            ]),
          '{"id":"",',
        ],
        'ovid_active_session': 'h3',
      });
      final app = await boot();
      expect(app.sessions, hasLength(30));
      expect(app.sessionById('h3')!.messages, hasLength(60));
      expect(app.sessionById('h29')!.messages.last.content, 'h29 message 59');
    },
  );

  test('fresh install starts empty and persists new chats to SQLite', () async {
    SharedPreferences.setMockInitialValues({});
    final app = await boot();
    app.sendMessage('first ever message');
    await app.flushSessionPersistenceForTest();
    final id = app.activeSession!.id;
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('ovid_sessions'), isNull);
    final again = await boot();
    expect(
      again.sessionById(id)!.messages.single.content,
      'first ever message',
    );
  });

  // Integration: tool inputs ride in the session JSON, so they must
  // survive the PR-3 SQLite repository.
  test('tool inputs persist through SQLite', () async {
    SharedPreferences.setMockInitialValues({});
    final app = await boot();
    app.sendMessage('before compaction');
    final session = app.activeSession!;
    session.messages.add(
      Message(
        role: 'assistant',
        kind: MsgKind.tool,
        content: '',
        toolName: 'read_file',
        toolInput: '{"path":"lib/a.dart"}',
      ),
    );
    app.persistSessions();
    await app.flushSessionPersistenceForTest();
    final id = session.id;
    final again = await boot();
    final restored = again.sessionById(id)!;
    expect(restored.messages.last.toolInput, '{"path":"lib/a.dart"}');
  });

  test('corrupt fixture rows are quarantined, the rest loads', () async {
    SharedPreferences.setMockInitialValues({
      'ovid_sessions': [
        '{not json',
        _sessionJson('ok', ['fine']),
      ],
      'ovid_active_session': 'ok',
    });
    final app = await boot();
    expect(app.sessions.map((s) => s.id), ['ok']);
    expect(history.migrationReports.single.quarantined.single.index, 0);
    expect(
      (await history.quarantined('ovid_sessions')).single.raw,
      '{not json',
    );
  });

  test('sending in an old chat moves it to the top under Today', () async {
    final now = DateTime.now();
    SharedPreferences.setMockInitialValues({
      'ovid_sessions': [
        _sessionJson('recent', [
          'r',
        ], at: now.subtract(const Duration(hours: 1))),
        _sessionJson('old', ['o'], at: now.subtract(const Duration(days: 30))),
      ],
      'ovid_active_session': 'recent',
    });
    final app = await boot();
    expect(app.rootSessionsByRecency.map((s) => s.id), ['recent', 'old']);
    app.selectSession('old');
    app.sendMessage('continuing the old chat');
    expect(app.rootSessionsByRecency.map((s) => s.id), ['old', 'recent']);
    await app.flushSessionPersistenceForTest();
    final again = await boot();
    expect(again.rootSessionsByRecency.first.id, 'old');
    expect(again.sessionById('old')!.updatedAt, isNotNull);
  });
}
