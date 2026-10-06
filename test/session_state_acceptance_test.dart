import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ffi' as ffi;

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/grant_store.dart';
import 'package:ovid_ai/core/html_artifact.dart';
import 'package:ovid_ai/core/memory_store.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences() : super.empty();
  Future<bool> Function(String key)? beforeWrite;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (beforeWrite != null && !await beforeWrite!(key)) return false;
    return super.setValue(valueType, key, value);
  }

  @override
  Future<bool> remove(String key) async {
    if (beforeWrite != null && !await beforeWrite!(key)) return false;
    return super.remove(key);
  }
}

ChatSession _saved(String id, {int count = 1}) => ChatSession(
  id: id,
  title: 'Saved',
  model: 'saved-model',
  branch: 'old-branch',
  grants: [PermissionGrant.host('old.example', sessionId: id)],
  messages: [
    for (var i = 0; i < count; i++)
      Message(
        role: 'user',
        content: 'old-$i',
        time: DateTime.utc(2026, 1, 1, 0, i),
      ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    AppState.resetTestInstance();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(AppState.resetTestInstance);

  Future<Map<String, dynamic>> stored(String id) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs
        .getStringList('ovid_sessions')!
        .map((raw) => jsonDecode(raw) as Map<String, dynamic>)
        .singleWhere((row) => row['id'] == id);
  }

  Future<AppState> deferred() async {
    SharedPreferences.setMockInitialValues({
      'ovid_sessions': [
        jsonEncode(_saved('active', count: 80).toJson()),
        for (var i = 0; i < 60; i++) jsonEncode(_saved('archive-$i').toJson()),
      ],
      'ovid_active_session': 'active',
    });
    final app = AppState.createForTest(
      persistedSessionDecoder: (raw) => ChatSession.fromJson(jsonDecode(raw)),
    );
    await app.initializeForFirstFrame();
    app.suspendCoalescedPersistenceForTest = true;
    return app;
  }

  test(
    'chunked hydration retains live session and message identity and late edits',
    () async {
      final app = await deferred();
      final live = app.activeSession!;
      final tail = live.messages.first;
      final loading = app.loadSessions();
      await Future<void>.delayed(Duration.zero);
      app.renameSession(live.id, 'Live rename');
      live.model = 'live-model';
      live.mode = 'control';
      live.grants.clear();
      live.branch = null;
      tail.content = 'edited tail';
      app.sendMessage('sent during yield');
      await loading;
      expect(identical(app.sessionById(live.id), live), isTrue);
      expect(identical(live.messages[30], tail), isTrue);
      expect(live.messages, hasLength(81));
      expect(live.messages.first.content, 'old-0');
      expect(live.messages.last.content, 'sent during yield');
      expect(live.title, 'Live rename');
      expect(live.model, 'live-model');
      expect(live.mode, 'control');
      expect(live.grants, isEmpty);
      expect(live.branch, isNull);
      await app.flushSessionPersistence();
      final row = await stored(live.id);
      expect(row['title'], 'Live rename');
      expect(row['mode'], 'control');
      expect(row['grants'], isNull);
      expect(row['branch'], isNull);
      expect((row['messages'] as List).last['content'], 'sent during yield');
    },
  );

  test(
    'new and nonactive live objects created during hydration survive',
    () async {
      final app = await deferred();
      final loading = app.loadSessions();
      await Future<void>.delayed(Duration.zero);
      final other = _saved('archive-0')..title = 'Nonactive edit';
      other.messages.single.content = 'nonactive message';
      app.sessions.add(other);
      app.newSession();
      final fresh = app.activeSession!;
      app.sendMessage('new chat message');
      await loading;
      expect(identical(app.sessionById(other.id), other), isTrue);
      expect(identical(app.activeSession, fresh), isTrue);
      expect(other.messages.single.content, 'nonactive message');
      await app.flushSessionPersistence();
      expect((await stored(other.id))['title'], 'Nonactive edit');
      expect(
        ((await stored(fresh.id))['messages'] as List).single['content'],
        'new chat message',
      );
    },
  );

  test(
    'deferred persistence does not restore cleared optional fields',
    () async {
      final app = await deferred();
      app.activeSession!.grants.clear();
      app.activeSession!.branch = null;
      await app.flushSessionPersistence();
      final row = await stored('active');
      expect(row['grants'], isNull);
      expect(row['branch'], isNull);
      expect(row['messages'], hasLength(80));
    },
  );

  test(
    'deferred writes preserve live Control mode without cold-start sanitization',
    () async {
      final app = await deferred();
      app.activeSession!.mode = 'control';
      await app.flushSessionPersistence();
      expect((await stored('active'))['mode'], 'control');
    },
  );

  test(
    'nonactive metadata edits persist before full hydration without truncating history',
    () async {
      final app = await deferred();
      final other = _saved('archive-0')..title = 'Edited while deferred';
      other.grants.clear();
      app.sessions.add(other);
      await app.flushSessionPersistence();
      final row = await stored(other.id);
      expect(row['title'], 'Edited while deferred');
      expect(row['grants'], isNull);
      expect((row['messages'] as List).single['content'], 'old-0');
    },
  );

  test(
    'same-id replacement owns its transcript during deferred persistence',
    () async {
      final app = await deferred();
      final replacement = ChatSession(
        id: 'active',
        title: 'Replacement',
        model: 'new',
        messages: [Message(role: 'user', content: 'replacement history')],
      );
      app.sessions[0] = replacement;
      await app.flushSessionPersistence();
      expect((await stored('active'))['messages'], hasLength(1));
      await app.loadSessions();
      expect(identical(app.activeSession, replacement), isTrue);
      expect(replacement.messages.single.content, 'replacement history');
    },
  );

  for (final preflush in [true, false]) {
    test(
      'nonactive raw tail survives ${preflush ? 'preflush/' : ''}hydrate/flush/restart with yield append',
      () async {
        final full = _saved('other', count: 80).toJson();
        SharedPreferences.setMockInitialValues({
          'ovid_sessions': [
            jsonEncode(_saved('active').toJson()),
            jsonEncode(full),
            for (var i = 0; i < 60; i++)
              jsonEncode(_saved('filler-$i').toJson()),
          ],
          'ovid_active_session': 'active',
        });
        var app = AppState.createForTest();
        await app.initializeForFirstFrame();
        final projection = ChatSession.fromJson({
          ...full,
          'messages': (full['messages'] as List).sublist(30),
        })..title = 'Edited projection';
        final firstTailMessage = projection.messages.first;
        app.sessions.add(projection);
        if (preflush) {
          await app.flushSessionPersistence();
          expect((await stored('other'))['messages'], hasLength(80));
        }
        final loading = app.loadSessions();
        await Future<void>.delayed(Duration.zero);
        firstTailMessage.content = 'edited during yield';
        projection.messages.add(
          Message(role: 'user', content: 'appended during yield'),
        );
        await loading;
        expect(identical(app.sessionById('other'), projection), isTrue);
        expect(projection.messages, hasLength(81));
        expect(identical(projection.messages[30], firstTailMessage), isTrue);
        await app.flushSessionPersistence();
        final row = await stored('other');
        expect(row['title'], 'Edited projection');
        expect(row['messages'], hasLength(81));
        AppState.resetTestInstance();
        app = AppState.createForTest();
        await app.loadSessions();
        final messages = app.sessionById('other')!.messages;
        expect(messages, hasLength(81));
        expect(messages.first.content, 'old-0');
        expect(messages[30].content, 'edited during yield');
        expect(messages.last.content, 'appended during yield');
      },
    );
  }

  test(
    'intentional replacement of a known nonactive projection keeps its own history',
    () async {
      final full = _saved('other', count: 80).toJson();
      SharedPreferences.setMockInitialValues({
        'ovid_sessions': [
          jsonEncode(_saved('active').toJson()),
          jsonEncode(full),
        ],
        'ovid_active_session': 'active',
      });
      final app = AppState.createForTest();
      await app.initializeForFirstFrame();
      final projection = ChatSession.fromJson({
        ...full,
        'messages': (full['messages'] as List).sublist(30),
      });
      app.sessions.add(projection);
      await app.flushSessionPersistence();
      final replacement = ChatSession(
        id: 'other',
        title: 'Replacement',
        model: 'new',
        messages: [Message(role: 'user', content: 'replacement history')],
      );
      app.sessions[app.sessions.indexOf(projection)] = replacement;
      await app.flushSessionPersistence();
      expect((await stored('other'))['messages'], hasLength(1));
      await app.loadSessions();
      expect(identical(app.sessionById('other'), replacement), isTrue);
      await app.flushSessionPersistence();
      expect(
        ((await stored('other'))['messages'] as List).single['content'],
        'replacement history',
      );
    },
  );

  for (final mutation in ['edit', 'append', 'clear']) {
    test(
      'recognized zero-prefix nonactive $mutation survives original flush and restart',
      () async {
        final full = _saved('other', count: 3).toJson();
        SharedPreferences.setMockInitialValues({
          'ovid_sessions': [
            jsonEncode(_saved('active').toJson()),
            jsonEncode(full),
          ],
          'ovid_active_session': 'active',
        });
        var app = AppState.createForTest();
        await app.initializeForFirstFrame();
        final live = ChatSession.fromJson(full);
        app.sessions.add(live);
        // Establish that this exact object contains the complete saved transcript.
        await app.flushSessionPersistence();
        expect((await stored('other'))['messages'], hasLength(3));
        final expected = switch (mutation) {
          'edit' => ['edited', 'old-1', 'old-2'],
          'append' => ['old-0', 'old-1', 'old-2', 'appended'],
          _ => <String>[],
        };
        switch (mutation) {
          case 'edit':
            live.messages.first.content = 'edited';
          case 'append':
            live.messages.add(Message(role: 'user', content: 'appended'));
          case 'clear':
            live.messages.clear();
        }
        // No hydration or rescue flush may repair a stale write for this test.
        await app.flushSessionPersistence();
        expect(identical(app.sessionById('other'), live), isTrue);
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        final persistedContents = ((await stored('other'))['messages'] as List)
            .map((message) => message['content'])
            .toList();
        AppState.resetTestInstance();
        app = AppState.createForTest();
        await app.loadSessions();
        expect(
          app.sessionById('other')!.messages.map((m) => m.content),
          expected,
        );
        expect(persistedContents, expected);
      },
    );
  }

  test(
    'unmatched edited projection with saved creation identity conservatively retains history',
    () async {
      final full = _saved('other', count: 80).toJson();
      SharedPreferences.setMockInitialValues({
        'ovid_sessions': [
          jsonEncode(_saved('active').toJson()),
          jsonEncode(full),
        ],
        'ovid_active_session': 'active',
      });
      var app = AppState.createForTest();
      await app.initializeForFirstFrame();
      final projection = ChatSession.fromJson({
        ...full,
        'messages': (full['messages'] as List).sublist(30),
      });
      // No exact suffix remains to establish an offset. Keep both histories
      // rather than guessing that the missing saved messages were deleted.
      projection.messages.first.content = 'edited before observation';
      app.sessions.add(projection);
      await app.flushSessionPersistence();
      await app.loadSessions();
      expect(identical(app.sessionById('other'), projection), isTrue);
      await app.flushSessionPersistence();
      AppState.resetTestInstance();
      app = AppState.createForTest();
      await app.loadSessions();
      final restored = app.sessionById('other')!;
      expect(restored.messages, hasLength(130));
      expect(restored.messages.first.content, 'old-0');
      expect(restored.messages[79].content, 'old-79');
      expect(restored.messages[80].content, 'edited before observation');
    },
  );

  for (final omitted in [true, false]) {
    test(
      'legacy ${omitted ? 'omitted' : 'null'} messages append quiesces in one deferred write and restarts',
      () async {
        final backend = _Preferences();
        SharedPreferencesStorePlatform.instance = backend;
        final legacy = <String, dynamic>{
          'id': 'other',
          'title': 'Legacy',
          'model': 'saved-model',
          if (!omitted) 'messages': null,
        };
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList('ovid_sessions', [
          jsonEncode(_saved('active').toJson()),
          jsonEncode(legacy),
        ]);
        await prefs.setString('ovid_active_session', 'active');
        var app = AppState.createForTest();
        await app.initializeForFirstFrame();
        final live = ChatSession.fromJson(legacy);
        expect(live.messages, isEmpty);
        app.sessions.add(live);
        live.messages.add(Message(role: 'user', content: 'legacy append'));
        var writes = 0;
        backend.beforeWrite = (key) async {
          if (key == 'flutter.ovid_sessions' && ++writes > 1) {
            // Bound the regression: an erroneous dirty retry must fail rather
            // than leave the real flush spinning indefinitely in microtasks.
            throw StateError('unexpected repeated session write');
          }
          return true;
        };
        await app.flushSessionPersistence();
        expect(writes, 1);
        expect(app.lastSessionPersistFailed, isFalse);
        expect(app.sessionEncodeCountsForTest['other'], 1);
        expect(identical(app.sessionById('other'), live), isTrue);
        await prefs.reload();
        final row = await stored('other');
        expect((row['messages'] as List).single['content'], 'legacy append');
        AppState.resetTestInstance();
        app = AppState.createForTest();
        await app.loadSessions();
        expect(
          app.sessionById('other')!.messages.single.content,
          'legacy append',
        );
      },
    );
  }

  test('overlapping hydration callers prepend history only once', () async {
    final app = await deferred();
    final live = app.activeSession!;
    await Future.wait([app.loadSessions(), app.loadSessions()]);
    expect(identical(app.activeSession, live), isTrue);
    expect(live.messages, hasLength(80));
  });

  test(
    'overlapping hydration cannot clear a deletion fence for a stale caller',
    () async {
      final app = await deferred();
      final first = app.loadSessions();
      final second = app.loadSessions();
      await Future<void>.delayed(Duration.zero);
      app.deleteSession('active');
      await Future.wait([first, second]);
      expect(app.sessionById('active'), isNull);
      await app.flushSessionPersistence();
      expect(
        (await SharedPreferences.getInstance())
            .getStringList('ovid_sessions')!
            .map((raw) => jsonDecode(raw)['id']),
        isNot(contains('active')),
      );
    },
  );

  test(
    'valid JSON with no session identity stays recoverable after hydration',
    () async {
      const opaque = '{"title":"recover me","messages":[]}';
      SharedPreferences.setMockInitialValues({
        'ovid_sessions': [jsonEncode(_saved('active').toJson()), opaque],
        'ovid_active_session': 'active',
      });
      final app = AppState.createForTest();
      await app.initializeForFirstFrame();
      await app.loadSessions();
      await app.flushSessionPersistence();
      expect(
        (await SharedPreferences.getInstance()).getStringList('ovid_sessions'),
        contains(opaque),
      );
    },
  );

  test(
    'reset while hydration yields prevents old sessions from returning',
    () async {
      final app = await deferred();
      final loading = app.loadSessions();
      await Future<void>.delayed(Duration.zero);
      app.suspendCoalescedPersistenceForTest = false;
      await app.deleteAllData();
      final fresh = app.activeSession!;
      await loading;
      expect(app.sessions, [fresh]);
      expect(app.sessionById('archive-0'), isNull);
      expect(app.sessionById('active'), isNull);
    },
  );

  test(
    'nested scalar types and collection boundaries affect persistence',
    () async {
      final app = AppState.createForTest();
      final live = app.activeSession!;
      live.goal = {
        'nested': <String, dynamic>{'value': 1},
      };
      await app.flushSessionPersistence();
      (live.goal!['nested'] as Map)['value'] = '1';
      await app.persistSessions();
      expect((await stored(live.id))['goal']['nested']['value'], '1');
    },
  );

  for (final field in ['goal', 'schedule']) {
    for (final toList in [true, false]) {
      test(
        '$field isolated empty ${toList ? 'map to list' : 'list to map'} survives restart',
        () async {
          var app = AppState.createForTest();
          final live = app.activeSession!;
          final nested = <String, dynamic>{
            'value': toList ? <String, dynamic>{} : <dynamic>[],
          };
          if (field == 'goal') {
            live.goal = nested;
          } else {
            live.schedules.add(nested);
          }
          await app.flushSessionPersistence();
          nested['value'] = toList ? <dynamic>[] : <String, dynamic>{};
          await app.persistSessions();
          AppState.resetTestInstance();
          app = AppState.createForTest();
          await app.loadSessions();
          final restored = app.sessionById(live.id)!;
          final value = field == 'goal'
              ? restored.goal!['value']
              : restored.schedules.single['value'];
          expect(value, toList ? isA<List>() : isA<Map>());
          expect(value, isEmpty);
        },
      );
    }
  }

  for (final field in ['schedule', 'todo']) {
    test(
      '$field isolated immutable row replacement survives restart',
      () async {
        var app = AppState.createForTest();
        final live = app.activeSession!;
        if (field == 'schedule') {
          live.schedules.add(const {'id': 'schedule', 'enabled': false});
        } else {
          live.todos.add(const {'task': 'task', 'status': 'pending'});
        }
        await app.flushSessionPersistence();
        if (field == 'schedule') {
          live.schedules[0] = const {'id': 'schedule', 'enabled': true};
        } else {
          live.todos[0] = const {'task': 'task', 'status': 'completed'};
        }
        await app.persistSessions();
        AppState.resetTestInstance();
        app = AppState.createForTest();
        await app.loadSessions();
        final restored = app.sessionById(live.id)!;
        if (field == 'schedule') {
          expect(restored.schedules.single, {
            'id': 'schedule',
            'enabled': true,
          });
        } else {
          expect(restored.todos.single, {
            'task': 'task',
            'status': 'completed',
          });
        }
      },
    );
  }

  test(
    'original pending flush captures unmaterialized parent and descendant deletion',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'state-pending-delete-',
      );
      SessionLedger.rootOverrideForTest = root;
      open.overrideFor(
        OperatingSystem.linux,
        () => ffi.DynamicLibrary.open('libsqlite3.so.0'),
      );
      SessionSearch.dbPathOverrideForTest = '${root.path}/search.db';
      addTearDown(() async {
        await SessionSearch.I.close();
        SessionSearch.dbPathOverrideForTest = null;
        SessionLedger.rootOverrideForTest = null;
        await root.delete(recursive: true);
      });
      final backend = _Preferences();
      SharedPreferencesStorePlatform.instance = backend;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('ovid_sessions', [
        jsonEncode(_saved('active').toJson()),
        jsonEncode(_saved('parent').toJson()),
        jsonEncode((_saved('child')..parentId = 'parent').toJson()),
      ]);
      await prefs.setString('ovid_active_session', 'active');
      final app = AppState.createForTest(
        memoryStore: MemoryStore(Directory('${root.path}/memory')),
        workspaceDeleter: (_) async {},
      );
      await app.initializeForFirstFrame();
      expect(app.sessions.map((s) => s.id), ['active']);
      final entered = Completer<void>();
      final release = Completer<void>();
      backend.beforeWrite = (key) async {
        if (key == 'flutter.ovid_sessions' && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
        return true;
      };
      final flushing = app.flushSessionPersistence();
      await entered.future;
      app.deleteSession('parent');
      // Let the coalesced persistence request join the already-running write.
      await Future<void>.delayed(Duration.zero);
      release.complete();
      await flushing;
      expect(app.lastSessionPersistFailed, isFalse);
      final disk = await backend.getAll();
      expect(
        (disk['flutter.ovid_sessions'] as List).map(
          (raw) => jsonDecode(raw as String)['id'],
        ),
        ['active'],
      );
    },
  );

  test(
    'analytics-only mutation is detected without another dirty field',
    () async {
      final app = AppState.createForTest();
      final live = app.activeSession!;
      await app.flushSessionPersistence();
      live.analytics.contextToolTokens = 123;
      await app.persistSessions();
      expect((await stored(live.id))['analytics']['contextToolTokens'], 123);
    },
  );

  test(
    'save recovery notifies listeners to clear the durability status',
    () async {
      final app = AppState.createForTest();
      app.failNextSessionWriteForTest = true;
      await app.flushSessionPersistence();
      final observed = <bool>[];
      app.addListener(() => observed.add(app.lastSessionPersistFailed));
      await app.flushSessionPersistence();
      expect(observed, contains(false));
    },
  );

  for (final action in ['active switch', 'membership removal']) {
    test(
      '$action during final preference write is included in flush',
      () async {
        final backend = _Preferences();
        SharedPreferencesStorePlatform.instance = backend;
        final app = AppState.createForTest();
        final first = app.activeSession!;
        final other = _saved('other');
        app.sessions.add(other);
        await app.flushSessionPersistence();
        final entered = Completer<void>();
        final release = Completer<void>();
        backend.beforeWrite = (key) async {
          if (key == 'flutter.ovid_active_session' && !entered.isCompleted) {
            entered.complete();
            await release.future;
          }
          return true;
        };
        final flushing = app.flushSessionPersistence();
        await entered.future;
        if (action == 'active switch') {
          app.activeSessionId = other.id;
        } else {
          app.sessions.remove(other);
        }
        release.complete();
        await flushing;
        final disk = await backend.getAll();
        if (action == 'active switch') {
          expect(disk['flutter.ovid_active_session'], other.id);
        } else {
          expect(
            (disk['flutter.ovid_sessions'] as List).map(
              (raw) => jsonDecode(raw as String)['id'],
            ),
            [first.id],
          );
        }
      },
    );
  }

  for (final throws in [false, true]) {
    test(
      'session disk ${throws ? 'throw' : 'false'} keeps edits retryable across reload',
      () async {
        final backend = _Preferences();
        SharedPreferencesStorePlatform.instance = backend;
        final app = AppState.createForTest();
        final live = app.activeSession!;
        await app.flushSessionPersistence();
        live.title = 'retry title';
        backend.beforeWrite = (key) async {
          if (key == 'flutter.ovid_sessions') {
            if (throws) throw StateError('disk unavailable');
            return false;
          }
          return true;
        };
        await app.persistSessions();
        expect(app.lastSessionPersistFailed, isTrue);
        backend.beforeWrite = null;
        await app.flushSessionPersistence();
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        expect((await stored(live.id))['title'], 'retry title');
        expect(app.lastSessionPersistFailed, isFalse);
      },
    );
  }

  final mutations = <String, (void Function(ChatSession), String, Object?)>{
    'branch': ((s) => s.branch = 'topic', 'branch', 'topic'),
    'workspace pin': (
      (s) => s.workspaceFolderPinned = true,
      'workspaceFolderPinned',
      true,
    ),
    'system prompt': (
      (s) => s.systemPromptSnapshot = 'prompt',
      'systemPromptSnapshot',
      'prompt',
    ),
    'title generated': ((s) => s.titleGenerated = true, 'titleGenerated', true),
    'child continuable': (
      (s) => s.agentContinuable = true,
      'agentContinuable',
      true,
    ),
    'child persona': (
      (s) => s.agentPersona = 'reviewer',
      'agentPersona',
      'reviewer',
    ),
    'child output hint': (
      (s) => s.agentOutputHint = 'json',
      'agentOutputHint',
      'json',
    ),
    'child tools': (
      (s) => s.agentAllowedTools.add('read_file'),
      'agentAllowedTools',
      ['read_file'],
    ),
    'queued plan': ((s) => s.planModePending = false, 'planModePending', false),
    'nested goal': (
      (s) => s.goal = {
        'steps': [
          {'done': true},
        ],
      },
      'goal',
      {
        'steps': [
          {'done': true},
        ],
      },
    ),
  };
  for (final entry in mutations.entries) {
    test(
      'persist and restart detects isolated ${entry.key} mutation',
      () async {
        var app = AppState.createForTest();
        final session = app.activeSession!;
        await app.flushSessionPersistence();
        entry.value.$1(session);
        await app.persistSessions();
        expect((await stored(session.id))[entry.value.$2], entry.value.$3);
        AppState.resetTestInstance();
        app = AppState.createForTest();
        await app.loadSessions();
        expect(
          app.sessionById(session.id)!.toJson()[entry.value.$2],
          entry.value.$3,
        );
      },
    );
  }

  test(
    'grant-only and analytics-only changes survive separate writes and restart',
    () async {
      var app = AppState.createForTest();
      final session = app.activeSession!;
      await app.flushSessionPersistence();
      session.grants.add(
        PermissionGrant.path('/workspace', sessionId: session.id),
      );
      await app.persistSessions();
      expect((await stored(session.id))['grants'], hasLength(1));
      session.analytics.contextToolTokens = 123;
      await app.persistSessions();
      expect((await stored(session.id))['analytics']['contextToolTokens'], 123);
      AppState.resetTestInstance();
      app = AppState.createForTest();
      await app.loadSessions();
      expect(app.sessionById(session.id)!.grants.single.value, '/workspace');
      expect(app.sessionById(session.id)!.analytics.contextToolTokens, 123);
    },
  );

  test(
    'artifact replacement and nested edits survive cached session writes',
    () async {
      final app = AppState.createForTest();
      final session = app.activeSession!;
      session.messages.add(Message(role: 'assistant', content: 'artifact'));
      session.goal = {
        'nested': {'done': false},
      };
      session.schedules.add({
        'nested': {'enabled': false},
      });
      await app.flushSessionPersistence();
      session.messages[0] = Message(
        role: 'assistant',
        htmlArtifact: HtmlArtifact.create(session.id, {'html': '<p>saved</p>'}),
      );
      await app.persistSessions();
      expect(
        ((await stored(session.id))['messages'] as List)
            .single['htmlArtifact']['html'],
        '<p>saved</p>',
      );
      (session.goal!['nested'] as Map)['done'] = true;
      (session.schedules.single['nested'] as Map)['enabled'] = true;
      await app.persistSessions();
      final row = await stored(session.id);
      expect(row['goal']['nested']['done'], true);
      expect((row['schedules'] as List).single['nested']['enabled'], true);
    },
  );

  for (final remove in [false, true]) {
    test(
      'active-id ${remove ? 'remove' : 'write'} false is visible and retryable',
      () async {
        final backend = _Preferences();
        SharedPreferencesStorePlatform.instance = backend;
        final app = AppState.createForTest();
        await app.flushSessionPersistence();
        if (remove) app.activeSessionId = null;
        backend.beforeWrite = (key) async =>
            key != 'flutter.ovid_active_session';
        await app.flushSessionPersistence();
        expect(app.lastSessionPersistFailed, isTrue);
        backend.beforeWrite = null;
        await app.flushSessionPersistence();
        expect(app.lastSessionPersistFailed, isFalse);
        expect(
          (await backend.getAll())['flutter.ovid_active_session'],
          app.activeSessionId,
        );
      },
    );
  }

  test(
    'mutation during pending disk write is flushed without concurrent writes',
    () async {
      final backend = _Preferences();
      SharedPreferencesStorePlatform.instance = backend;
      final app = AppState.createForTest();
      final session = app.activeSession!;
      final entered = Completer<void>();
      final release = Completer<void>();
      var waiting = false;
      backend.beforeWrite = (key) async {
        if (key == 'flutter.ovid_sessions' && !entered.isCompleted) {
          waiting = true;
          entered.complete();
          await release.future;
          waiting = false;
        } else {
          expect(waiting, isFalse, reason: 'writes must be serialized');
        }
        return true;
      };
      final flushing = app.flushSessionPersistence();
      await entered.future;
      session.systemPromptSnapshot = 'during write';
      app.persistSessions();
      release.complete();
      await flushing;
      expect(
        (await stored(session.id))['systemPromptSnapshot'],
        'during write',
      );
    },
  );

  testWidgets(
    'continuous tokens have a bounded save delay and reuse history caches',
    (tester) async {
      final app = AppState.createForTest(
        sessionPersistDebounce: const Duration(milliseconds: 200),
      );
      final active = app.activeSession!;
      final archive = _saved('archive', count: 1000);
      app.sessions.add(archive);
      await tester.runAsync(app.flushSessionPersistence);
      app.sessionEncodeCountsForTest.clear();
      active.messages.add(Message(role: 'assistant', kind: MsgKind.streaming));
      for (var i = 0; i < 30; i++) {
        active.messages.last.content = 'token-$i';
        app.persistSessions();
        await tester.pump(const Duration(milliseconds: 100));
        if (i == 8) expect(app.sessionEncodeCountsForTest[active.id], isNull);
        if (i == 9 || i == 19 || i == 29) {
          expect(app.sessionEncodeCountsForTest[active.id], (i + 1) ~/ 10);
          expect(
            ((await stored(active.id))['messages'] as List).last['content'],
            'token-$i',
          );
        }
      }
      final writesDuringStream = app.sessionEncodeCountsForTest[active.id] ?? 0;
      await tester.runAsync(app.flushSessionPersistence);
      expect(writesDuringStream, greaterThan(0));
      expect(app.sessionEncodeCountsForTest[active.id], lessThan(10));
      expect(app.sessionEncodeCountsForTest[archive.id], isNull);
      expect(
        ((await stored(active.id))['messages'] as List).last['content'],
        'token-29',
      );
    },
  );
}
