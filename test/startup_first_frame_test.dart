import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/firebase_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/startup_coordinator.dart';

const _optionalStages = <String>[
  'marketplace.refresh',
  'mcp.connect',
  'firebase.initialize',
  'github.initialize',
  'sandbox.selfHeal',
];

Map<String, Future<void> Function()> _offlineStages() => {
  for (final stage in _optionalStages) stage: () async {},
  'plugin.activate': () async {},
};

String _sessionJson(
  String id,
  List<String> messages, {
  String title = 'Saved chat',
  String? parentId,
  String? sandboxId,
}) => jsonEncode(
  ChatSession(
    id: id,
    title: title,
    model: 'saved-model',
    parentId: parentId,
    sandboxId: sandboxId,
    messages: [
      for (final message in messages) Message(role: 'user', content: message),
    ],
  ).toJson(),
);

String _bootstrapJson(String source, String tail) => jsonEncode({
  'version': 1,
  'sourceFingerprint': sha256.convert(utf8.encode(source)).toString(),
  'session': jsonDecode(tail),
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
  });

  tearDown(AppState.resetTestInstance);

  test('first-frame initialization performs no network or MCP work', () async {
    final calls = <String>[];
    final app = AppState.createForTest(startupStageRecorder: calls.add);

    await app.initializeForFirstFrame();

    expect(
      calls,
      isNot(
        contains(
          anyOf(
            'marketplace.refresh',
            'plugin.activate',
            'mcp.connect',
            'firebase.initialize',
            'sandbox.selfHeal',
          ),
        ),
      ),
    );
  });

  test(
    'first-frame work completes while deferred stages are hanging',
    () async {
      SharedPreferences.setMockInitialValues({
        'ovid_sessions': [
          'not-json',
          for (var i = 0; i < 100; i++)
            _sessionJson('archive-$i', ['archived-$i ${'y' * 2000}']),
          _sessionJson('active', [
            for (var i = 0; i < 5000; i++) 'history-$i ${'x' * 200}',
          ]),
        ],
        'ovid_active_session': 'active',
      });
      final calls = <String>[];
      final never = Completer<void>();
      final app = AppState.createForTest(
        startupStageRecorder: calls.add,
        startupStageDelegates: {
          for (final stage in _optionalStages) stage: () => never.future,
          'plugin.activate': () => never.future,
        },
      );

      await app.initializeForFirstFrame().timeout(const Duration(seconds: 3));

      expect(calls, ['local.firstFrame']);
      expect(app.sessions, hasLength(1));
      expect(app.activeSession!.id, 'active');
      expect(app.activeSession!.messages, hasLength(50));
    },
  );

  test('first-frame initialization is cached for one app boot', () async {
    final calls = <String>[];
    final app = AppState.createForTest(startupStageRecorder: calls.add);

    await Future.wait([
      app.initializeForFirstFrame(),
      app.initializeForFirstFrame(),
    ]);

    expect(calls.where((stage) => stage == 'local.firstFrame'), hasLength(1));
  });

  test('initialize remains a fully hydrated compatibility seam', () async {
    SharedPreferences.setMockInitialValues({
      'ovid_sessions': [
        _sessionJson('active', ['active-old']),
        _sessionJson('archived', ['archived-old']),
      ],
      'ovid_active_session': 'active',
    });
    final app = AppState.createForTest(startupStageDelegates: _offlineStages());

    await app.initialize();

    expect(
      app.sessions.map((session) => session.id),
      containsAll(['active', 'archived']),
    );
    expect(
      app.sessionById('archived')!.messages.single.content,
      'archived-old',
    );
  });

  test(
    'deferred hydration preserves old history and a newly persisted message',
    () async {
      final oldMessages = [for (var i = 0; i < 80; i++) 'old-$i'];
      SharedPreferences.setMockInitialValues({
        'ovid_sessions': [
          _sessionJson('active', oldMessages),
          _sessionJson('archived', ['archive']),
        ],
        'ovid_active_session': 'active',
      });
      final app = AppState.createForTest(
        startupStageDelegates: _offlineStages(),
      );

      await app.initializeForFirstFrame();
      expect(app.activeSession!.messages.length, lessThan(oldMessages.length));
      expect(app.activeSession!.messages.last.content, 'old-79');

      app.sendMessage('new-after-frame');
      await app.persistSessions();
      await app.initializeReadiness();

      final hydrated = app.activeSession!.messages.map(
        (message) => message.content,
      );
      expect(hydrated, hasLength(81));
      expect(hydrated.first, 'old-0');
      expect(hydrated.last, 'new-after-frame');
      expect(app.sessionById('archived')!.messages.single.content, 'archive');
    },
  );

  test(
    'deleting before hydration tombstones the session and descendants',
    () async {
      SharedPreferences.setMockInitialValues({
        'ovid_sessions': [
          _sessionJson('active', ['parent']),
          _sessionJson('child', ['child'], parentId: 'active'),
          _sessionJson('survivor', ['keep']),
        ],
        'ovid_active_session': 'active',
      });
      final app = AppState.createForTest(
        startupStageDelegates: _offlineStages(),
      );

      await app.initializeForFirstFrame();
      app.deleteSession('active');
      await app.persistSessions();
      await app.initializeReadiness();

      expect(app.sessionById('active'), isNull);
      expect(app.sessionById('child'), isNull);
      expect(app.sessionById('survivor')!.messages.single.content, 'keep');
    },
  );

  test(
    'bootstrap-path deletion tombstones raw descendants before hydration',
    () async {
      final active = _sessionJson('active', ['parent']);
      final child = _sessionJson('child', ['child'], parentId: 'active');
      SharedPreferences.setMockInitialValues({
        'ovid_session_bootstrap_v1': _bootstrapJson(active, active),
        'ovid_sessions': [
          active,
          child,
          _sessionJson('survivor', ['keep']),
        ],
        'ovid_active_session': 'active',
      });
      final app = AppState.createForTest(
        startupStageDelegates: _offlineStages(),
      );

      await app.initializeForFirstFrame();
      app.deleteSession('active');
      await app.persistSessions();
      await app.initializeReadiness();

      expect(app.sessionById('active'), isNull);
      expect(app.sessionById('child'), isNull);
      expect(app.sessionById('survivor'), isNotNull);
    },
  );

  test('deleteAllData invalidates a pending deferred snapshot', () async {
    SharedPreferences.setMockInitialValues({
      'ovid_sessions': [
        _sessionJson('active', ['old-active']),
        _sessionJson('archived', ['old-archive']),
      ],
      'ovid_active_session': 'active',
    });
    final app = AppState.createForTest(startupStageDelegates: _offlineStages());

    await app.initializeForFirstFrame();
    await app.deleteAllData();
    final freshId = app.activeSession!.id;
    await app.initializeReadiness();

    expect(app.sessions.map((session) => session.id), [freshId]);
    expect(app.sessionById('active'), isNull);
    expect(app.sessionById('archived'), isNull);
  });

  test(
    'deleting during chunked hydration cannot resurrect the session',
    () async {
      SharedPreferences.setMockInitialValues({
        'ovid_sessions': [
          _sessionJson('active', ['active']),
          for (var i = 0; i < 60; i++)
            _sessionJson('archive-$i', ['message-$i']),
        ],
        'ovid_active_session': 'active',
      });
      final app = AppState.createForTest(
        startupStageDelegates: _offlineStages(),
      );

      await app.initializeForFirstFrame();
      final readiness = app.initializeReadiness();
      await Future<void>.delayed(Duration.zero);
      app.deleteSession('active');
      await readiness;

      expect(app.sessionById('active'), isNull);
    },
  );

  test(
    'a malformed deferred row cannot truncate valid persisted sessions',
    () async {
      final calls = <String>[];
      SharedPreferences.setMockInitialValues({
        'ovid_sessions': [
          _sessionJson('active', [for (var i = 0; i < 80; i++) 'old-$i']),
          '{malformed',
          _sessionJson('archived', ['archive']),
        ],
        'ovid_active_session': 'active',
      });
      var app = AppState.createForTest(
        startupStageRecorder: calls.add,
        startupStageDelegates: _offlineStages(),
      );

      await app.initializeReadiness();
      expect(calls, contains('local.hydrate.corrupt'));
      expect(
        StartupCoordinator.I.snapshot.items
            .singleWhere((item) => item.id == 'local.hydrate')
            .state,
        StartupItemState.degraded,
      );
      expect(app.activeSession!.messages, hasLength(80));
      expect(app.sessionById('archived')!.messages.single.content, 'archive');
      await app.persistSessions();

      AppState.resetTestInstance();
      app = AppState.createForTest(startupStageDelegates: _offlineStages());
      await app.initialize();
      expect(app.activeSession!.messages, hasLength(80));
      expect(app.sessionById('archived')!.messages.single.content, 'archive');
    },
  );

  test(
    'no decodable root preserves every opaque and valid deferred row',
    () async {
      const malformedRoot = '{"id":"broken-root","parentId":null';
      final child = _sessionJson('child', [
        'child-message',
      ], parentId: 'broken-root');
      final other = _sessionJson('other', [
        'other-message',
      ], parentId: 'missing-root');
      SharedPreferences.setMockInitialValues({
        'ovid_sessions': [malformedRoot, child, other],
        'ovid_active_session': 'broken-root',
      });
      var app = AppState.createForTest(startupStageDelegates: _offlineStages());

      await app.initializeForFirstFrame();
      await app.persistSessions();
      await app.initializeReadiness();

      var prefs = await SharedPreferences.getInstance();
      var persisted = prefs.getStringList('ovid_sessions')!;
      expect(persisted, contains(malformedRoot));
      expect(persisted, contains(child));
      expect(persisted, contains(other));

      AppState.resetTestInstance();
      app = AppState.createForTest(startupStageDelegates: _offlineStages());
      await app.initialize();
      await app.persistSessions();
      prefs = await SharedPreferences.getInstance();
      persisted = prefs.getStringList('ovid_sessions')!;
      expect(persisted, contains(malformedRoot));
      expect(
        persisted.map((raw) {
          try {
            return (jsonDecode(raw) as Map<String, dynamic>)['id'];
          } catch (_) {
            return null;
          }
        }),
        containsAll(['child', 'other']),
      );
    },
  );

  test(
    'first frame uses bootstrap cache without decoding full sessions',
    () async {
      final bootstrap = _sessionJson('active', [
        for (var i = 0; i < 50; i++) 'tail-$i',
      ]);
      final full = _sessionJson('active', [
        for (var i = 0; i < 5000; i++) 'full-$i',
      ]);
      SharedPreferences.setMockInitialValues({
        'ovid_session_bootstrap_v1': _bootstrapJson(full, bootstrap),
        'ovid_active_session': 'active',
        'ovid_sessions': [
          for (var i = 0; i < 100; i++)
            _sessionJson('archive-$i', ['${'x' * 2000}-$i']),
          full,
        ],
      });
      var fullSessionDecodes = 0;
      final app = AppState.createForTest(
        startupStageDelegates: _offlineStages(),
        persistedSessionDecoder: (raw) {
          fullSessionDecodes++;
          return ChatSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        },
      );

      await app.initializeForFirstFrame();

      expect(fullSessionDecodes, 0);
      expect(app.activeSession!.messages, hasLength(50));
      expect(app.activeSession!.messages.last.content, 'tail-49');
    },
  );

  test(
    'stale same-id bootstrap falls back to the newer persisted transcript',
    () async {
      final oldRaw = _sessionJson('active', ['old-0', 'old-1']);
      final newMessages = [for (var i = 0; i < 80; i++) 'new-$i'];
      final newRaw = _sessionJson('active', newMessages);
      SharedPreferences.setMockInitialValues({
        'ovid_session_bootstrap_v1': _bootstrapJson(oldRaw, oldRaw),
        'ovid_active_session': 'active',
        'ovid_sessions': [newRaw],
      });
      final app = AppState.createForTest(
        startupStageDelegates: _offlineStages(),
      );

      await app.initializeForFirstFrame();
      await app.initializeReadiness();

      expect(
        app.activeSession!.messages.map((message) => message.content),
        newMessages,
      );
    },
  );

  test(
    'cache-first interrupted write falls back to the older persisted truth',
    () async {
      final oldRaw = _sessionJson('active', ['old-truth']);
      final nextRaw = _sessionJson('active', ['uncommitted-next']);
      SharedPreferences.setMockInitialValues({
        'ovid_session_bootstrap_v1': _bootstrapJson(nextRaw, nextRaw),
        'ovid_active_session': 'active',
        'ovid_sessions': [oldRaw],
      });
      final app = AppState.createForTest();

      await app.initializeForFirstFrame();

      expect(app.activeSession!.messages.single.content, 'old-truth');
    },
  );

  test('cache-miss fallback yields to the UI isolate while decoding', () async {
    final huge = _sessionJson('active', [
      for (var i = 0; i < 10000; i++) 'message-$i ${'x' * 200}',
    ]);
    SharedPreferences.setMockInitialValues({
      'ovid_active_session': 'active',
      'ovid_sessions': [huge],
    });
    var tickerRan = false;
    Timer.run(() => tickerRan = true);
    final app = AppState.createForTest();

    await app.initializeForFirstFrame();

    expect(tickerRan, isTrue);
    expect(app.activeSession!.messages, hasLength(50));
  });

  test(
    'deferred descendants receive lifecycle and workspace cleanup once',
    () async {
      final parent = _sessionJson('parent', [
        'parent',
      ], sandboxId: 'parent-box');
      final child = _sessionJson(
        'child',
        ['child'],
        parentId: 'parent',
        sandboxId: 'child-box',
      );
      final deletedWorkspaces = <String>[];
      final deletedSessions = <String>[];
      SharedPreferences.setMockInitialValues({
        'ovid_session_bootstrap_v1': _bootstrapJson(parent, parent),
        'ovid_active_session': 'parent',
        'ovid_sessions': [parent, child],
      });
      final app = AppState.createForTest(
        workspaceDeleter: (sandboxId) async => deletedWorkspaces.add(sandboxId),
      );
      app.onSessionDeleted = deletedSessions.add;

      await app.initializeForFirstFrame();
      app.deleteSession('parent');
      await app.persistSessions();
      await app.initializeReadiness();

      expect(deletedSessions.where((id) => id == 'parent'), hasLength(1));
      expect(deletedSessions.where((id) => id == 'child'), hasLength(1));
      expect(deletedWorkspaces.where((id) => id == 'parent-box'), hasLength(1));
      expect(deletedWorkspaces.where((id) => id == 'child-box'), hasLength(1));
    },
  );

  test(
    'malformed descendant sandbox ids use the session id for cleanup once',
    () async {
      final parent = _sessionJson('parent', [
        'parent',
      ], sandboxId: 'parent-box');
      final numericChild =
          jsonDecode(
                  _sessionJson('numeric-child', [
                    'numeric',
                  ], parentId: 'parent'),
                )
                as Map<String, dynamic>
            ..['sandboxId'] = 42;
      final mapChild =
          jsonDecode(_sessionJson('map-child', ['map'], parentId: 'parent'))
                as Map<String, dynamic>
            ..['sandboxId'] = {'unexpected': true};
      final deletedWorkspaces = <String>[];
      final deletedSessions = <String>[];
      SharedPreferences.setMockInitialValues({
        'ovid_session_bootstrap_v1': _bootstrapJson(parent, parent),
        'ovid_active_session': 'parent',
        'ovid_sessions': [
          parent,
          jsonEncode(numericChild),
          jsonEncode(mapChild),
        ],
      });
      final app = AppState.createForTest(
        workspaceDeleter: (sandboxId) async => deletedWorkspaces.add(sandboxId),
      );
      app.onSessionDeleted = deletedSessions.add;

      await app.initializeForFirstFrame();
      app.deleteSession('parent');
      await app.persistSessions();

      final prefs = await SharedPreferences.getInstance();
      final persistedIds = prefs
          .getStringList('ovid_sessions')!
          .map((raw) => (jsonDecode(raw) as Map<String, dynamic>)['id']);
      expect(persistedIds, isNot(contains('numeric-child')));
      expect(persistedIds, isNot(contains('map-child')));
      expect(
        deletedSessions.where((id) => id == 'numeric-child'),
        hasLength(1),
      );
      expect(deletedSessions.where((id) => id == 'map-child'), hasLength(1));
      expect(
        deletedWorkspaces.where((id) => id == 'numeric-child'),
        hasLength(1),
      );
      expect(deletedWorkspaces.where((id) => id == 'map-child'), hasLength(1));
    },
  );

  test(
    'list null and empty descendant sandbox ids use session ids once',
    () async {
      final parent = _sessionJson('parent', ['parent']);
      final malformedChildren = <String, Object?>{
        'list-child': <Object?>['unexpected'],
        'null-child': null,
        'empty-child': '',
      };
      final childRows = [
        for (final entry in malformedChildren.entries)
          jsonEncode(
            (jsonDecode(
                    _sessionJson(entry.key, [entry.key], parentId: 'parent'),
                  )
                  as Map<String, dynamic>)
              ..['sandboxId'] = entry.value,
          ),
      ];
      final deletedWorkspaces = <String>[];
      final deletedSessions = <String>[];
      SharedPreferences.setMockInitialValues({
        'ovid_session_bootstrap_v1': _bootstrapJson(parent, parent),
        'ovid_active_session': 'parent',
        'ovid_sessions': [parent, ...childRows],
      });
      final app = AppState.createForTest(
        workspaceDeleter: (sandboxId) async => deletedWorkspaces.add(sandboxId),
      );
      app.onSessionDeleted = deletedSessions.add;

      await app.initializeForFirstFrame();
      app.deleteSession('parent');
      await app.persistSessions();

      for (final id in malformedChildren.keys) {
        expect(deletedSessions.where((deleted) => deleted == id), hasLength(1));
        expect(
          deletedWorkspaces.where((deleted) => deleted == id),
          hasLength(1),
        );
      }
    },
  );

  test(
    'first-frame fallback writes bootstrap cache for the next boot',
    () async {
      SharedPreferences.setMockInitialValues({
        'ovid_active_session': 'active',
        'ovid_sessions': [
          _sessionJson('active', [for (var i = 0; i < 80; i++) 'message-$i']),
        ],
      });
      var app = AppState.createForTest();

      await app.initializeForFirstFrame();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('ovid_session_bootstrap_v1'), isNotNull);

      AppState.resetTestInstance();
      app = AppState.createForTest(
        persistedSessionDecoder: (_) => throw StateError('must use cache'),
      );
      await app.initializeForFirstFrame();
      expect(app.activeSession!.messages, hasLength(50));
    },
  );

  test(
    'fallback bootstrap follows the selected root instead of requested raw',
    () async {
      const malformedRequested = '{"id":"child","sandboxId":';
      final child = _sessionJson('child', ['child'], parentId: 'root');
      final root = _sessionJson('root', [
        for (var i = 0; i < 80; i++) 'root-$i',
      ]);
      SharedPreferences.setMockInitialValues({
        'ovid_active_session': 'child',
        'ovid_sessions': [malformedRequested, child, root],
      });
      var app = AppState.createForTest();

      await app.initializeForFirstFrame();

      expect(app.activeSession!.id, 'root');
      final prefs = await SharedPreferences.getInstance();
      final bootstrap =
          jsonDecode(prefs.getString('ovid_session_bootstrap_v1')!)
              as Map<String, dynamic>;
      expect(
        bootstrap['sourceFingerprint'],
        sha256.convert(utf8.encode(root)).toString(),
      );
      expect(prefs.getString('ovid_active_session'), 'root');

      AppState.resetTestInstance();
      var fallbackDecodes = 0;
      app = AppState.createForTest(
        persistedSessionDecoder: (raw) {
          fallbackDecodes++;
          return ChatSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        },
      );
      await app.initializeForFirstFrame();

      expect(fallbackDecodes, 0);
      expect(app.activeSession!.id, 'root');
      expect(app.activeSession!.messages, hasLength(50));
    },
  );

  test('persisted subagent active falls back to a cacheable root', () async {
    final child = _sessionJson('child', ['child'], parentId: 'root');
    final root = _sessionJson('root', [for (var i = 0; i < 80; i++) 'root-$i']);
    SharedPreferences.setMockInitialValues({
      'ovid_active_session': 'child',
      'ovid_sessions': [child, root],
    });
    var app = AppState.createForTest();

    await app.initializeForFirstFrame();

    expect(app.activeSession!.id, 'root');
    AppState.resetTestInstance();
    var fallbackDecodes = 0;
    app = AppState.createForTest(
      persistedSessionDecoder: (raw) {
        fallbackDecodes++;
        return ChatSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      },
    );
    await app.initializeForFirstFrame();

    expect(fallbackDecodes, 0);
    expect(app.activeSession!.id, 'root');
    expect(app.activeSession!.messages, hasLength(50));
  });

  test('malformed requested active falls back to a cacheable root', () async {
    const malformed = '{"id":"broken","sandboxId":';
    final root = _sessionJson('root', [for (var i = 0; i < 80; i++) 'root-$i']);
    SharedPreferences.setMockInitialValues({
      'ovid_active_session': 'broken',
      'ovid_sessions': [malformed, root],
    });
    var app = AppState.createForTest();

    await app.initializeForFirstFrame();

    expect(app.activeSession!.id, 'root');
    AppState.resetTestInstance();
    var fallbackDecodes = 0;
    app = AppState.createForTest(
      persistedSessionDecoder: (raw) {
        fallbackDecodes++;
        return ChatSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      },
    );
    await app.initializeForFirstFrame();

    expect(fallbackDecodes, 0);
    expect(app.activeSession!.id, 'root');
    expect(app.activeSession!.messages, hasLength(50));
  });

  test(
    'persist builds an exact bootstrap tail without decoding session JSON',
    () async {
      var bootstrapDecodes = 0;
      final app = AppState.createForTest(
        sessionBootstrapDecoder: (raw) {
          bootstrapDecodes++;
          return jsonDecode(raw) as Map<String, dynamic>;
        },
      );
      final active = app.activeSession!;
      active.messages.addAll([
        for (var i = 0; i < 80; i++)
          Message(role: 'user', content: 'message-$i'),
      ]);

      await app.persistSessions();

      expect(bootstrapDecodes, 0);
      final prefs = await SharedPreferences.getInstance();
      final activeRaw = prefs
          .getStringList('ovid_sessions')!
          .singleWhere((raw) => raw.startsWith('{"id":"${active.id}",'));
      final bootstrap =
          jsonDecode(prefs.getString('ovid_session_bootstrap_v1')!)
              as Map<String, dynamic>;
      final tail =
          (bootstrap['session'] as Map<String, dynamic>)['messages'] as List;
      expect(
        bootstrap['sourceFingerprint'],
        sha256.convert(utf8.encode(activeRaw)).toString(),
      );
      expect(tail, hasLength(50));
      expect((tail.first as Map<String, dynamic>)['content'], 'message-30');
      expect((tail.last as Map<String, dynamic>)['content'], 'message-79');
    },
  );

  test('plugin activation retries with one boot token and one epoch', () async {
    var attempts = 0;
    final tokens = <Object>[];
    final app = AppState.createForTest(
      startupStageDelegates: _offlineStages()..remove('plugin.activate'),
      pluginBootActivator: (bootToken, connectMcp) async {
        attempts++;
        tokens.add(bootToken);
        expect(connectMcp, isFalse);
        if (attempts == 1) throw StateError('activation failed');
      },
    );
    final pluginTask = (await app.buildReadinessTasks()).singleWhere(
      (task) => task.id == 'plugin.activate',
    );

    await expectLater(pluginTask.run(), throwsStateError);
    await pluginTask.run();
    await pluginTask.run();

    expect(attempts, 2);
    expect(identical(tokens[0], tokens[1]), isTrue);
  });

  test(
    'Firebase initialization retries failure without duplicate setup',
    () async {
      var appAttempts = 0;
      var setupAttempts = 0;
      final firebase = FirebaseService.forTest(
        initializeApp: () async => appAttempts++,
        configure: () async {
          setupAttempts++;
          if (setupAttempts == 1) throw StateError('configuration failed');
        },
      );

      await expectLater(firebase.initialize(), throwsStateError);
      expect(firebase.isAvailable, isFalse);
      await firebase.initialize();
      await firebase.initialize();

      expect(firebase.isAvailable, isTrue);
      expect(appAttempts, 2);
      expect(setupAttempts, 2);
    },
  );

  test(
    'restored-session callback runs after hydration and activation',
    () async {
      final calls = <String>[];
      SharedPreferences.setMockInitialValues({
        'ovid_sessions': [
          _sessionJson('active', ['saved']),
        ],
        'ovid_active_session': 'active',
      });
      final app = AppState.createForTest(
        startupStageRecorder: calls.add,
        startupStageDelegates: _offlineStages()..remove('plugin.activate'),
        pluginBootActivator: (_, _) async {},
      );
      AgentService.I;
      app.onSessionsLoaded = () => calls.add('sessions.callback');

      await app.initializeReadiness();

      expect(
        calls,
        containsAll(['local.hydrate', 'plugin.activate', 'sessions.callback']),
      );
      expect(
        calls.indexOf('sessions.callback'),
        greaterThan(calls.indexOf('plugin.activate')),
      );
    },
  );

  test(
    'restore stays pending while timed-out hydration invocation is active',
    () async {
      final calls = <String>[];
      final hydration = Completer<void>();
      final app = AppState.createForTest(
        startupStageRecorder: calls.add,
        startupStageDelegates: _offlineStages()
          ..remove('plugin.activate')
          ..['local.hydrate'] = () => hydration.future,
        pluginBootActivator: (_, _) async {},
      );
      AgentService.I;
      app.onSessionsLoaded = () => calls.add('sessions.callback');
      final tasks = await app.buildReadinessTasks();
      final hydrationTask = tasks.singleWhere(
        (task) => task.id == 'local.hydrate',
      );
      final activation = tasks.singleWhere(
        (task) => task.id == 'plugin.activate',
      );
      final skillMount = tasks.singleWhere((task) => task.id == 'skill.mount');
      final restore = tasks.singleWhere((task) => task.id == 'session.restore');

      final hydrationRun = hydrationTask.run();
      await activation.run();
      await skillMount.run();
      final status = await restore.run();

      expect(status.state, StartupItemState.degraded);
      expect(calls, isNot(contains('sessions.callback')));

      hydration.complete();
      await hydrationRun;
      expect(calls, contains('sessions.callback'));
    },
  );

  test(
    'restore stays pending until a timed-out skill mount settles successfully',
    () async {
      final calls = <String>[];
      final mount = Completer<void>();
      SharedPreferences.setMockInitialValues({
        'ovid_sessions': [
          _sessionJson('active', ['saved']),
        ],
        'ovid_active_session': 'active',
      });
      final app = AppState.createForTest(
        startupStageRecorder: calls.add,
        startupStageDelegates: _offlineStages()
          ..remove('plugin.activate')
          ..['skill.mount'] = () => mount.future,
        startupStageTimeouts: {'skill.mount': const Duration(milliseconds: 1)},
        pluginBootActivator: (_, _) async {},
      );
      AgentService.I;
      app.onSessionsLoaded = () => calls.add('sessions.callback');

      await app.initializeReadiness();

      expect(calls, isNot(contains('sessions.callback')));
      final restore = StartupCoordinator.I.snapshot.items.singleWhere(
        (item) => item.id == 'session.restore',
      );
      expect(restore.state, StartupItemState.degraded);

      mount.complete();
      await StartupCoordinator.I.whenInvocationsSettled();
      expect(calls, contains('sessions.callback'));
    },
  );

  test(
    'a thrown skill mount keeps session restore degraded and records a reason',
    () async {
      final calls = <String>[];
      SharedPreferences.setMockInitialValues({
        'ovid_sessions': [
          _sessionJson('active', ['saved']),
        ],
        'ovid_active_session': 'active',
      });
      final app = AppState.createForTest(
        startupStageRecorder: calls.add,
        startupStageDelegates: _offlineStages()
          ..remove('plugin.activate')
          ..['skill.mount'] = () async => throw StateError('mount boom'),
        pluginBootActivator: (_, _) async {},
      );
      AgentService.I;
      app.onSessionsLoaded = () => calls.add('sessions.callback');

      await app.initializeReadiness();

      expect(calls, isNot(contains('sessions.callback')));
      final mount = StartupCoordinator.I.snapshot.items.singleWhere(
        (item) => item.id == 'skill.mount',
      );
      expect(mount.state, StartupItemState.failed);
      final restore = StartupCoordinator.I.snapshot.items.singleWhere(
        (item) => item.id == 'session.restore',
      );
      expect(restore.state, StartupItemState.degraded);
      expect(restore.reason, contains('mounting failed'));
    },
  );

  test(
    'coordinator timeout never runs restore before hydration settles',
    () async {
      final calls = <String>[];
      final hydration = Completer<void>();
      final app = AppState.createForTest(
        startupStageRecorder: calls.add,
        startupStageDelegates: _offlineStages()
          ..remove('plugin.activate')
          ..['local.hydrate'] = () => hydration.future,
        startupStageTimeouts: {
          'local.hydrate': const Duration(milliseconds: 1),
        },
        pluginBootActivator: (_, _) async {},
      );
      app.onSessionsLoaded = () => calls.add('sessions.callback');

      await app.initializeReadiness();

      expect(calls, isNot(contains('sessions.callback')));
      expect(app.startupSafeToReconnect, isFalse);

      hydration.complete();
      await StartupCoordinator.I.whenInvocationsSettled();
      expect(calls, contains('sessions.callback'));
      expect(app.startupSafeToReconnect, isTrue);
    },
  );

  test('resume reconnect is gated until readiness completes', () async {
    final calls = <String>[];
    final releaseHydration = Completer<void>();
    final delegates = _offlineStages()
      ..['local.hydrate'] = () async {
        await releaseHydration.future;
      }
      ..['mcp.resume'] = () async => calls.add('resume.connected');
    final app = AppState.createForTest(
      startupStageRecorder: calls.add,
      startupStageDelegates: delegates,
    );

    final readiness = app.initializeReadiness();
    while (!calls.contains('local.hydrate')) {
      await Future<void>.delayed(Duration.zero);
    }
    final pendingReconnect = app.reconnectServicesAfterResume();
    final duplicateReconnect = app.reconnectServicesAfterResume();
    expect(identical(pendingReconnect, duplicateReconnect), isTrue);
    expect(calls, isNot(contains('resume.connected')));

    releaseHydration.complete();
    await readiness;
    await pendingReconnect;
    expect(calls.where((stage) => stage == 'resume.connected'), hasLength(1));
  });

  test(
    'readiness and boot activation run once for one AppState boot',
    () async {
      final calls = <String>[];
      final delegates = _offlineStages()..remove('plugin.activate');
      final app = AppState.createForTest(
        startupStageRecorder: calls.add,
        startupStageDelegates: delegates,
      );
      final prefs = await SharedPreferences.getInstance();

      await Future.wait([app.initializeReadiness(), app.initializeReadiness()]);
      final firstEpoch = prefs.getInt('ovid_plugin_boot_epoch_v1');
      await app.initializeReadiness();

      expect(firstEpoch, 1);
      expect(prefs.getInt('ovid_plugin_boot_epoch_v1'), 1);
      expect(calls.where((stage) => stage == 'plugin.activate'), hasLength(1));
    },
  );

  test('production renders before optional readiness starts', () {
    final source = File('lib/main.dart').readAsStringSync();
    final mainBody = source.substring(
      source.indexOf('Future<void> main()'),
      source.indexOf('class OvidApp'),
    );

    expect(
      mainBody.indexOf('await AppState.I.initializeForFirstFrame()'),
      greaterThan(-1),
    );
    expect(
      mainBody.indexOf('runApp('),
      lessThan(mainBody.indexOf('_startReadiness()')),
    );
    for (final forbidden in [
      'FirebaseService.I.initialize()',
      'reconnectServices()',
      'selfHealInBackground()',
    ]) {
      expect(
        mainBody.substring(0, mainBody.indexOf('runApp(')),
        isNot(contains(forbidden)),
      );
    }
  });

  test('first-frame method has no direct optional-service calls', () {
    final source = File('lib/core/state.dart').readAsStringSync();
    final firstFrameBody = source.substring(
      source.indexOf('Future<void> _initializeForFirstFrame()'),
      source.indexOf('Future<List<StartupTask>> buildReadinessTasks()'),
    );

    for (final forbidden in [
      'syncMarketplaceCatalogs(',
      'activateForBoot(',
      'FirebaseService.I.initialize(',
      'reconnectServices(',
      'selfHealInBackground(',
    ]) {
      expect(firstFrameBody, isNot(contains(forbidden)));
    }
  });
}
