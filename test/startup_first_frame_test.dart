import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/state.dart';

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
}) => jsonEncode(
  ChatSession(
    id: id,
    title: title,
    model: 'saved-model',
    messages: [
      for (final message in messages) Message(role: 'user', content: message),
    ],
  ).toJson(),
);

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
          _sessionJson(
            'active',
            [
              for (var i = 0; i < 5000; i++) 'history-$i ${'x' * 200}',
            ],
          ),
          for (var i = 0; i < 100; i++)
            _sessionJson('archive-$i', ['archived-$i']),
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
}
