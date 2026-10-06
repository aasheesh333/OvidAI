import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ovid_ai/core/firebase_service.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/memory_store.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/session_lifecycle_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

ChatSession chat(String id, String text) => ChatSession(
  id: id,
  title: text,
  model: 'm',
  messages: [Message(role: 'user', content: text)],
);

class _User extends Fake implements User {
  _User(this.uid);
  @override
  final String uid;
  final token = Completer<String?>();
  @override
  bool get isAnonymous => false;
  @override
  List<UserInfo> get providerData => const [];
  @override
  Future<String?> getIdToken([bool forceRefresh = false]) => token.future;
}

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences() : super.empty();
  Future<bool> Function(String key)? beforeWrite;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (beforeWrite != null && !await beforeWrite!(key)) return false;
    return super.setValue(type, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppState app;
  late Directory dir;
  final index = SessionSearch.I;
  final agent = AgentService.I;
  setUpAll(() {
    open.overrideFor(
      OperatingSystem.linux,
      () => ffi.DynamicLibrary.open('libsqlite3.so.0'),
    );
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('ownership-');
    SessionSearch.dbPathOverrideForTest = '${dir.path}/search.db';
    SessionLedger.rootOverrideForTest = dir;
    await index.setAccount('test-${dir.path}');
    app = AppState.createForTest(
      memoryStore: MemoryStore(dir),
      workspaceDeleter: (_) async {},
    );
    app.sessions.clear();
    app.suspendCoalescedPersistenceForTest = true;
  });
  tearDown(() async {
    AgentService.setRunSessionForTest('');
    agent.clearRunCtxForTest();
    await app.awaitPendingSessionWritesForTest();
    await index.close();
    SessionSearch.dbPathOverrideForTest = null;
    SessionLedger.rootOverrideForTest = null;
    AppState.resetTestInstance();
    await dir.delete(recursive: true);
  });

  Future<String> search([Map<String, dynamic> extra = const {}]) =>
      agent.dispatchForTest('session_search', {'query': 'needle', ...extra});

  test(
    'tool pages reuse the returned snapshot instead of rebuilding',
    () async {
      final s = chat('same', 'needle alpha');
      s.messages.add(Message(role: 'user', content: 'needle beta'));
      app.sessions.add(s);
      app.activeSessionId = s.id;
      final first = await search({'limit': 1});
      final generation = index.generation;
      s.messages.insert(0, Message(role: 'user', content: 'needle aardvark'));
      final second = await search({
        'limit': 1,
        'cursor': 1,
        'generation': generation,
      });
      expect(first, contains('generation $generation'));
      expect(index.generation, generation);
      expect(second, contains('beta'));
      await index.clear();
      expect(
        await search({'cursor': 2, 'generation': generation}),
        contains('Restart'),
      );
    },
  );

  test('tool validates paging before rebuilding', () async {
    app.sessions.add(chat('same', 'needle'));
    app.activeSessionId = 'same';
    final generation = index.generation;
    expect(await search({'limit': 101}), contains('Error:'));
    expect(await search({'cursor': 1}), contains('Restart'));
    expect(index.generation, generation);
  });

  test(
    'session deletion drains FTS and prevents stale reindex resurrection',
    () async {
      app.sessions.add(chat('gone', 'needle private'));
      app.activeSessionId = 'gone';
      await search();
      app.deleteSession('gone');
      await app.flushSessionPersistence();
      expect(await index.search('needle'), isEmpty);
      await index.reindex([
        (
          id: 'gone',
          model: 'm',
          rows: [(role: 'user', content: 'needle private')],
        ),
      ]);
      expect(await index.search('needle'), isEmpty);
    },
  );

  test(
    'account replacement preserves legacy guest and same-id account transcripts across restart',
    () async {
      app.sessions.add(chat('same', 'guest secret'));
      app.activeSessionId = 'same';
      await app.flushSessionPersistence();
      await (app as dynamic).transitionSessionAccount('firebase:A');
      expect(
        app.sessions.any(
          (s) => s.messages.any((m) => m.content == 'guest secret'),
        ),
        isFalse,
      );
      app.sessions
        ..clear()
        ..add(chat('same', 'A secret'));
      app.activeSessionId = 'same';
      await app.flushSessionPersistence();
      await (app as dynamic).transitionSessionAccount('firebase:B');
      expect(app.sessionById('same'), isNull);
      app.sessions
        ..clear()
        ..add(chat('same', 'B secret'));
      await app.flushSessionPersistence();
      AppState.resetTestInstance();
      app = AppState.createForTest();
      await (app as dynamic).transitionSessionAccount('firebase:A');
      expect(app.sessionById('same')!.messages.single.content, 'A secret');
      await (app as dynamic).transitionSessionAccount('guest');
      expect(app.sessionById('same')!.messages.single.content, 'guest secret');
    },
  );

  test('delayed guest hydration cannot publish into B', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('ovid_sessions', [
      for (var i = 0; i < 80; i++)
        jsonEncode(chat('old-$i', 'private guest').toJson()),
    ]);
    await prefs.setString('ovid_active_session', 'old-0');
    await app.initializeForFirstFrame();
    final loading = app.loadSessions();
    await Future<void>.delayed(Duration.zero);
    final switching =
        (app as dynamic).transitionSessionAccount('firebase:B') as Future<void>;
    expect(app.sessions, isEmpty);
    await switching;
    await loading;
    expect(app.sessions.any((s) => s.id.startsWith('old-')), isFalse);
    await app.flushSessionPersistence();
    await (app as dynamic).transitionSessionAccount('guest');
    expect(app.sessionById('old-79')!.messages.single.content, 'private guest');
  });

  test(
    'delayed session-start activation cannot refresh or dispatch after account replacement',
    () async {
      final old = chat('same', 'A secret');
      app.sessions.add(old);
      final gate = Completer<void>();
      final lifecycle = SessionLifecycleService.I;
      lifecycle.activationWaiterForTest = (_) => gate.future;
      final effects = <String>[];
      lifecycle.skillRefresherForTest = (s) async {
        effects.add('refresh');
      };
      lifecycle.hookDispatcherForTest =
          (event, id, {payload = const {}, model}) async {
            effects.add(event);
            return '';
          };
      final starting = lifecycle.sessionStarted(
        old,
        reason: SessionStartReason.restored,
      );
      await app.transitionSessionAccount('firebase:B');
      app.sessions.add(chat('same', 'B secret'));
      gate.complete();
      await starting;
      expect(effects, isEmpty);
      await lifecycle.sessionStarted(
        app.sessions.last,
        reason: SessionStartReason.restored,
      );
      expect(effects, ['refresh', 'session_start']);
    },
  );

  test(
    'delayed search returns no old-account hits after replacement',
    () async {
      app.sessions.add(chat('same', 'needle A secret'));
      app.activeSessionId = 'same';
      final pending = search();
      await app.transitionSessionAccount('firebase:B');
      app.sessions.add(chat('same', 'needle B secret'));
      app.activeSessionId = 'same';
      final result = await pending;
      expect(
        result,
        anyOf(
          contains('Restart'),
          contains('Cancelled: session account changed'),
        ),
      );
      expect(result, isNot(contains('A secret')));
      expect(await search(), contains('B secret'));
    },
  );

  test(
    'delayed run callback cannot append or enqueue into replacement same-id session',
    () async {
      final old = chat('same', 'A secret');
      app.sessions.add(old);
      app.activeSessionId = old.id;
      final run = agent.runBucketForTest(old.id);
      run.cancelRequested = false;
      agent.setRunCtxForTest(run, old, run.runEpoch);
      final gate = Completer<void>();
      final callback = () async {
        await gate.future;
        agent.streamToBubbleForTest(old, 'late A output');
        agent.enqueueMessage('late A queue', sessionId: 'same');
      }();
      await app.transitionSessionAccount('firebase:B');
      final replacement = chat('same', 'B secret');
      app.sessions.add(replacement);
      app.activeSessionId = replacement.id;
      gate.complete();
      await callback;
      expect(old.messages.map((m) => m.content), ['A secret']);
      expect(replacement.messages.map((m) => m.content), ['B secret']);
      expect(agent.queuedMessagesFor('same'), isEmpty);
    },
  );

  test(
    'Firebase startup binds ownership before publishing readiness',
    () async {
      app.sessions.add(chat('guest', 'private guest'));
      await app.flushSessionPersistence();
      final service = FirebaseService.forTest(
        initializeApp: () async {},
        configure: () async {},
        initialUser: _User('A'),
      );
      final exposed = <String>[];
      service.addListener(() {
        if (service.accountReady) exposed.addAll(app.sessions.map((s) => s.id));
      });
      await service.initialize();
      expect(app.sessionAccountId, 'firebase:A');
      expect(exposed, isNot(contains('guest')));
      expect(service.accountReady, isTrue);
      service.dispose();
    },
  );

  test(
    'Firebase image journal binds only after account is ready and clears on signout boundary',
    () async {
      final images = ImageStudio.I;
      images.bindAccount(null);
      final service = FirebaseService.forTest(
        initializeApp: () async {},
        configure: () async {},
        initialUser: _User('A'),
      );
      await service.initialize();
      expect(images.accountId, 'A');
      service.dispose();
      // Service's auth invalidation seam must revoke image ownership synchronously.
      images.bindAccount(null);
    },
  );

  test(
    'cloud mint restores model catalog for the same ready account after restart',
    () async {
      final user = _User('A')..token.complete('fixture-token');
      final service = FirebaseService.forTest(
        initializeApp: () async {},
        configure: () async {},
        initialUser: user,
      );
      await service.initialize();
      final requests = <Uri>[];
      final client = MockClient((request) async {
        requests.add(request.url);
        if (request.url.path == '/mint') {
          return http.Response(
            '{"key":"fixture-key","tier":"free","base_url":"https://fixture.invalid/v1/"}',
            200,
          );
        }
        if (request.url.path == '/v1/models') {
          return http.Response('{"data":[{"id":"fixture-model"}]}', 200);
        }
        return http.Response('', 404);
      });
      final cloud = OvidCloudService.I;
      OvidCloudService.idTokenOverrideForTest = () async => 'fixture-token';
      try {
        final result = await cloud.bindOvidCloud(client: client, app: app);
        expect(result.ok, isTrue);
        expect(
          app.providerById(AppState.ovidCloudProviderId)!.models,
          contains('fixture-model'),
        );
        expect(requests.map((uri) => uri.path), ['/mint', '/v1/models']);
      } finally {
        OvidCloudService.idTokenOverrideForTest = null;
        service.dispose();
      }
    },
  );

  test(
    'stale run context cannot admit a new run or dispatch session reads in B',
    () async {
      final old = chat('same', 'A secret');
      app.sessions.add(old);
      app.activeSessionId = old.id;
      final bucket = agent.runBucketForTest(old.id)..cancelRequested = false;
      agent.setRunCtxForTest(bucket, old, bucket.runEpoch);
      await app.transitionSessionAccount('firebase:B');
      final replacement = chat('same', 'B secret');
      app.sessions.add(replacement);
      app.activeSessionId = 'same';
      final read = await agent.dispatchForTest('session_read', {
        'session_id': 'same',
      });
      expect(read, isNot(contains('B secret')));
      await agent.runTask('stale run', sessionId: 'same');
      expect(replacement.messages.map((m) => m.content), ['B secret']);
    },
  );

  test(
    'account replacement serializes a delayed A preference write before restoring B',
    () async {
      final backend = _Preferences();
      SharedPreferencesStorePlatform.instance = backend;
      await app.transitionSessionAccount('firebase:A');
      app.sessions.add(chat('same', 'A durable'));
      app.activeSessionId = 'same';
      final entered = Completer<void>();
      final release = Completer<void>();
      backend.beforeWrite = (key) async {
        if (key.contains('ovid_sessions') &&
            key.contains('firebase%3AA') &&
            !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
        return true;
      };
      final saving = app.flushSessionPersistence();
      await entered.future;
      final switching = app.transitionSessionAccount('firebase:B');
      expect(app.sessions, isEmpty);
      release.complete();
      await saving;
      await switching;
      app.sessions.add(chat('same', 'B durable'));
      await app.flushSessionPersistence();
      await app.transitionSessionAccount('firebase:A');
      expect(app.sessionById('same')!.messages.single.content, 'A durable');
      await app.transitionSessionAccount('firebase:B');
      expect(app.sessionById('same')!.messages.single.content, 'B durable');
    },
  );

  test(
    'failed account handoff retains unsaved A snapshot for explicit retry',
    () async {
      final backend = _Preferences();
      SharedPreferencesStorePlatform.instance = backend;
      await app.transitionSessionAccount('firebase:A');
      app.sessions.add(chat('same', 'before edit'));
      await app.flushSessionPersistence();
      app.sessionById('same')!.messages.single.content = 'unsaved A edit';
      backend.beforeWrite = (key) async => !key.contains('ovid_sessions');
      await expectLater(
        app.transitionSessionAccount('firebase:B'),
        throwsStateError,
      );
      expect(app.sessionAccountReady, isFalse);
      backend.beforeWrite = null;
      await (await SharedPreferences.getInstance()).reload();
      await app.transitionSessionAccount('firebase:B');
      await app.transitionSessionAccount('firebase:A');
      expect(
        app.sessionById('same')!.messages.single.content,
        'unsaved A edit',
      );
    },
  );

  test(
    'failed FTS deletion retries through all-store barrier and stale retries cannot delete B',
    () async {
      await app.transitionSessionAccount('firebase:A');
      app.sessions.add(chat('same', 'needle A'));
      app.activeSessionId = 'same';
      await search();
      final lock = sqlite3.open(SessionSearch.dbPathOverrideForTest!);
      lock.execute('BEGIN IMMEDIATE');
      app.deleteSession('same');
      await app.flushSessionPersistence();
      expect(app.lastSessionPersistFailed, isTrue);
      expect(await index.search('needle'), isEmpty);
      lock.execute('ROLLBACK');
      lock.dispose();
      await (app as dynamic).awaitSessionDeletions(retryFailed: true);
      await app.flushSessionPersistence();
      expect(app.lastSessionPersistFailed, isFalse);
      await app.transitionSessionAccount('firebase:B');
      app.sessions.add(chat('same', 'needle B'));
      app.activeSessionId = 'same';
      await search();
      await (app as dynamic).awaitSessionDeletions(retryFailed: true);
      expect((await index.search('needle')).single.snippet, contains('B'));
    },
  );

  test('A usage stays in A after B transitions and both reload', () async {
    UsageEntry record(String name) => UsageEntry(
      time: DateTime.utc(2026),
      providerId: name,
      providerName: name,
      model: 'm',
      promptTokens: 1,
      completionTokens: 2,
      totalTokens: 3,
      duration: Duration.zero,
    );
    await app.transitionSessionAccount('firebase:A');
    app.appendUsage(record('A'));
    await app.transitionSessionAccount('firebase:B');
    app.appendUsage(record('B'));
    await app.transitionSessionAccount('firebase:A');
    expect(app.usageLog.map((entry) => entry.providerId), ['A']);
    await app.transitionSessionAccount('firebase:B');
    expect(app.usageLog.map((entry) => entry.providerId), ['B']);
  });

  test(
    'account switch after first-frame guest read cannot overwrite saved guest transcript with provisional state',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('ovid_sessions', [
        jsonEncode(chat('guest-only', 'guest private').toJson()),
      ]);
      // No first-frame hydrate has run; constructor created only a provisional chat.
      await app.transitionSessionAccount('firebase:A');
      await app.transitionSessionAccount('guest');
      expect(
        app.sessionById('guest-only')!.messages.single.content,
        'guest private',
      );
    },
  );

  test('stale checkpoint restore never installs A run metadata in B', () async {
    final backend = _Preferences();
    SharedPreferencesStorePlatform.instance = backend;
    await app.transitionSessionAccount('firebase:A');
    await agent.checkpointRunStart('same', 'A-run');
    await app.transitionSessionAccount('firebase:B');
    final restored = agent.restoreRunCheckpoints();
    await restored;
    expect(agent.activeRunCheckpointForTest(), isEmpty);
  });

  test(
    'guest-to-A boundary waits for failed deletion cleanup before publishing A',
    () async {
      app.sessions.add(chat('old', 'guest needle'));
      app.activeSessionId = 'old';
      await search();
      final lock = sqlite3.open(SessionSearch.dbPathOverrideForTest!);
      lock.execute('BEGIN IMMEDIATE');
      app.deleteSession('old');
      await app.flushSessionPersistence();
      expect(app.lastSessionPersistFailed, isTrue);
      final transition = app.transitionSessionAccount('firebase:A');
      await expectLater(transition, throwsStateError);
      expect(app.sessionAccountReady, isFalse);
      lock.execute('ROLLBACK');
      lock.dispose();
      await app.transitionSessionAccount('firebase:A');
      expect(app.sessionAccountReady, isTrue);
    },
  );

  test(
    'a failed old-account FTS deletion cannot delete same-id rows in B',
    () async {
      app.sessions.add(chat('same', 'needle old'));
      app.activeSessionId = 'same';
      await search();
      final lock = sqlite3.open(SessionSearch.dbPathOverrideForTest!);
      lock.execute('BEGIN IMMEDIATE');
      app.deleteSession('same');
      await app.flushSessionPersistence();
      lock.execute('ROLLBACK');
      lock.dispose();
      await app.transitionSessionAccount('firebase:B');
      app.sessions.add(chat('same', 'needle B'));
      app.activeSessionId = 'same';
      await search();
      expect((await index.search('needle')).single.snippet, contains('B'));
    },
  );
}
