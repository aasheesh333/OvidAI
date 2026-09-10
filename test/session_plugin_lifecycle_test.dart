import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/plugin_runtime.dart';
import 'package:ovid_ai/core/session_lifecycle_service.dart';
import 'package:ovid_ai/core/skills.dart';
import 'package:ovid_ai/core/state.dart';

/// Optional/external startup stages stubbed out so readiness completes
/// without network. `plugin.activate` is intentionally NOT stubbed: the real
/// AppState activation must run so the boot-activation barrier settles.
Map<String, Future<void> Function()> _offlineStages() => {
  'marketplace.refresh': () async {},
  'mcp.connect': () async {},
  'firebase.initialize': () async {},
  'github.initialize': () async {},
  'sandbox.selfHeal': () async {},
  'mcp.resume': () async {},
};

typedef _RecordedEvent = ({
  String event,
  String sessionId,
  Map<String, dynamic> payload,
});

List<_RecordedEvent> _recordEvents(HookService svc) {
  final events = <_RecordedEvent>[];
  svc.executorForTest = (cmd, env) async {
    final payload =
        (jsonDecode(env['PLUGIN_PAYLOAD'] ?? '{}') as Map)
            .cast<String, dynamic>();
    events.add((
      event: env['PLUGIN_EVENT'] ?? '',
      sessionId: env['PLUGIN_SESSION'] ?? '',
      payload: payload,
    ));
    return '';
  };
  addTearDown(() => svc.executorForTest = null);
  return events;
}

/// Records lifecycle dispatches without going through the hook registry.
/// Startup reconciliation prunes unpersisted registrations, so AppState
/// integration tests observe the dispatcher contract directly; the real
/// HookService/registry path is covered by the focused unit tests above.
List<_RecordedEvent> _injectDispatcher() {
  final events = <_RecordedEvent>[];
  SessionLifecycleService.I.hookDispatcherForTest =
      (event, sessionId, {payload = const {}, model}) async {
        events.add((event: event, sessionId: sessionId, payload: payload));
        return '';
      };
  addTearDown(() => SessionLifecycleService.I.hookDispatcherForTest = null);
  return events;
}

void _registerHooks(
  String pluginId, {
  bool sessionStart = true,
  bool subagentStart = false,
  PluginActivation activation = PluginActivation.globalActive,
  String? immediateSessionId,
}) {
  final hooks = <PluginHook>[
    if (sessionStart)
      PluginHook(
        pluginId: pluginId,
        event: 'session_start',
        ordinal: 0,
        type: 'command',
        payload: 'echo session-start',
        path: 'hooks/hooks.json',
      ),
    if (subagentStart)
      PluginHook(
        pluginId: pluginId,
        event: 'subagent_start',
        ordinal: 1,
        type: 'command',
        payload: 'echo subagent-start',
        path: 'hooks/hooks.json',
      ),
  ];
  final manifest = NormalizedPluginManifest(
    id: pluginId,
    name: pluginId,
    version: '1.0.0',
    format: PluginFormat.claudeCode,
    rootPath: '/lifecycle/root',
    hooks: hooks,
  );
  PluginContributionRegistry.I.register(
    manifest,
    activation: activation,
    immediateSessionId: immediateSessionId,
  );
  addTearDown(() => PluginContributionRegistry.I.unregisterPlugin(pluginId));
}

ChatSession _session(String id, {String? parentId}) =>
    ChatSession(id: id, title: id, model: 'm', parentId: parentId);

String _sessionJson(
  String id,
  List<String> messages, {
  String title = 'Saved chat',
  String? parentId,
}) => jsonEncode(
  ChatSession(
    id: id,
    title: title,
    model: 'saved-model',
    parentId: parentId,
    messages: [
      for (final message in messages) Message(role: 'user', content: message),
    ],
  ).toJson(),
);

Future<void> _serve(HttpServer server, {String content = 'child done'}) async {
  await for (final request in server) {
    await utf8.decoder.bind(request).join();
    request.response.headers.chunkedTransferEncoding = true;
    request.response.add(
      utf8.encode(
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': content},
              'finish_reason': 'stop',
            },
          ],
        })}\n\n',
      ),
    );
    await request.response.flush();
    await request.response.close();
  }
}

Future<({AppState app, ChatSession parent})> _subagentFixture({
  String content = 'child done',
}) async {
  final app = AppState.createForTest(
    pluginBootActivator: (_, _) async {},
  );
  app.sessions.clear();
  final provider = app.providerById('ollama-local')!;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  unawaited(_serve(server, content: content));
  provider
    ..baseUrl = 'http://${server.address.host}:${server.port}/v1'
    ..models = ['test-model'];
  final parent = ChatSession(
    id: 'lifecycle-parent',
    title: 'parent',
    providerId: provider.id,
    model: 'test-model',
    mode: 'auto',
  );
  app.sessions.insert(0, parent);
  app.activeSessionId = parent.id;
  AgentService.setRunSessionForTest(parent.id);
  return (app: app, parent: parent);
}

void _noOpLifecycleWaits() {
  SessionLifecycleService.I.activationWaiterForTest = (_) async {};
  SessionLifecycleService.I.skillRefresherForTest = (_) async {};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    SessionLifecycleService.I.resetForTest();
    AgentService.setRunSessionForTest('');
    AgentService.skillCatalogInputsForTest = null;
    HookService.I.enabled = true;
    HookService.I.executorForTest = null;
    HookService.I.gateExecutorForTest = null;
    SkillService.I.invalidateAllSessions();
  });

  tearDown(() {
    AgentService.setRunSessionForTest('');
    AgentService.skillCatalogInputsForTest = null;
    SessionLifecycleService.I.resetForTest();
    HookService.I.executorForTest = null;
    HookService.I.gateExecutorForTest = null;
    AppState.resetTestInstance();
    SkillService.I.invalidateAllSessions();
  });

  group('session_start dispatch reasons', () {
    test('newSession fires created once for the new root only', () async {
      final app = AppState.createForTest(
        startupStageDelegates: _offlineStages(),
        pluginBootActivator: (_, _) async {},
      );
      AgentService.skillCatalogInputsForTest =
          (sessionId) async => SkillCatalogInputs();
      final events = _injectDispatcher();

      await app.initialize();
      final bootRoot = app.activeSession!.id;
      app.newSession();
      await app.drainSessionLifecycleForTest();

      final created = app.activeSession!;
      expect(created.id, isNot(bootRoot));
      final starts = events
          .where(
            (event) =>
                event.event == 'session_start' &&
                event.sessionId == created.id,
          )
          .toList();
      expect(starts, hasLength(1));
      expect(starts.single.payload['reason'], 'created');
      expect(starts.single.payload['parentSessionId'], isNull);
      expect(starts.single.payload['isSubagent'], isFalse);
      expect(
        events.any((event) => event.sessionId == bootRoot),
        isTrue,
        reason: 'the boot root still fires its own lifecycle',
      );
    });

    test(
      'empty storage fires implicit once for the surviving root (no ghost)',
      () async {
        final app = AppState.createForTest(
          startupStageDelegates: _offlineStages(),
          pluginBootActivator: (_, _) async {},
        );
        final provisionalId = app.activeSession!.id;
        AgentService.skillCatalogInputsForTest =
            (sessionId) async => SkillCatalogInputs();
        final events = _injectDispatcher();

        await app.initialize();

        expect(app.sessions, hasLength(1));
        expect(app.activeSession!.id, provisionalId);
        final starts = events
            .where((event) => event.event == 'session_start')
            .toList();
        expect(starts, hasLength(1));
        expect(starts.single.sessionId, provisionalId);
        expect(starts.single.payload['reason'], 'implicit');
      },
    );

    test('only the boot-active restored root fires, once', () async {
      SharedPreferences.setMockInitialValues({
        'ovid_sessions': [
          _sessionJson('root-a', ['a']),
          _sessionJson('root-b', ['b']),
        ],
        'ovid_active_session': 'root-b',
      });
      final app = AppState.createForTest(
        startupStageDelegates: _offlineStages(),
        pluginBootActivator: (_, _) async {},
      );
      final provisionalId = app.activeSession!.id;
      AgentService.skillCatalogInputsForTest =
          (sessionId) async => SkillCatalogInputs();
      final events = _injectDispatcher();

      await app.initialize();

      expect(app.activeSession!.id, 'root-b');
      final starts = events
          .where((event) => event.event == 'session_start')
          .toList();
      expect(starts, hasLength(1));
      expect(starts.single.sessionId, 'root-b');
      expect(starts.single.payload['reason'], 'restored');
      expect(
        events.any(
          (event) =>
              event.sessionId == provisionalId ||
              event.sessionId == 'root-a',
        ),
        isFalse,
        reason: 'discarded provisional root and inactive roots must not fire',
      );
    });

    test(
      'the executor sees the session-visible runtime skill at session_start',
      () async {
        final dir = Directory.systemTemp.createTempSync('ovid-lifecycle-skill-');
        addTearDown(() {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });
        File('${dir.path}/SKILL.md').writeAsStringSync(
          '---\nname: lifecycle-probe\nuser-invocable: true\n---\nPROBE',
        );
        AgentService.skillCatalogInputsForTest =
            (sessionId) async => SkillCatalogInputs(roots: [dir.path]);
        SessionLifecycleService.I.bootTokenProviderForTest = () => 'boot';
        SessionLifecycleService.I.activationWaiterForTest = (_) async {};
        var sawSkill = false;
        HookService.I.executorForTest = (cmd, env) async {
          if (env['PLUGIN_EVENT'] == 'session_start') {
            final names = SkillService.I
                .skillsForSession(env['PLUGIN_SESSION']!)
                .map((skill) => skill.name);
            sawSkill = names.contains('lifecycle-probe');
          }
          return '';
        };
        addTearDown(() => HookService.I.executorForTest = null);
        _registerHooks('lifecycle/skill');

        await SessionLifecycleService.I.sessionStarted(
          _session('skill-session'),
          reason: SessionStartReason.created,
        );

        expect(sawSkill, isTrue);
      },
    );
  });

  group('idempotence and fail-open', () {
    test('concurrent duplicate starts share one future and fire once', () async {
      SessionLifecycleService.I.bootTokenProviderForTest = () => 'boot';
      final gate = Completer<void>();
      var fires = 0;
      SessionLifecycleService.I.activationWaiterForTest = (_) => gate.future;
      SessionLifecycleService.I.skillRefresherForTest = (_) async {};
      SessionLifecycleService.I.hookDispatcherForTest =
          (event, sessionId, {payload = const {}, model}) async {
            fires++;
            return '';
          };

      final session = _session('dup');
      final first = SessionLifecycleService.I.sessionStarted(
        session,
        reason: SessionStartReason.created,
      );
      final second = SessionLifecycleService.I.sessionStarted(
        session,
        reason: SessionStartReason.restored,
      );
      expect(identical(first, second), isTrue);
      gate.complete();
      await Future.wait([first, second]);
      expect(fires, 1);
    });

    test('a second reason in the same boot never refires', () async {
      SessionLifecycleService.I.bootTokenProviderForTest = () => 'boot';
      SessionLifecycleService.I.activationWaiterForTest = (_) async {};
      SessionLifecycleService.I.skillRefresherForTest = (_) async {};
      final reasons = <String>[];
      SessionLifecycleService.I.hookDispatcherForTest =
          (event, sessionId, {payload = const {}, model}) async {
            reasons.add(payload['reason'] as String);
            return '';
          };

      final session = _session('reason');
      await SessionLifecycleService.I.sessionStarted(
        session,
        reason: SessionStartReason.created,
      );
      await SessionLifecycleService.I.sessionStarted(
        session,
        reason: SessionStartReason.restored,
      );
      expect(reasons, ['created']);
    });

    test('refresh and hook failures stay fail-open and reserved', () async {
      SessionLifecycleService.I.bootTokenProviderForTest = () => 'boot';
      SessionLifecycleService.I.activationWaiterForTest = (_) async {};

      var refreshes = 0;
      SessionLifecycleService.I.skillRefresherForTest = (_) async {
        refreshes++;
        throw StateError('refresh boom');
      };
      SessionLifecycleService.I.hookDispatcherForTest =
          (event, sessionId, {payload = const {}, model}) async {
            throw StateError('should not dispatch');
          };
      await SessionLifecycleService.I.sessionStarted(
        _session('refresh-fail'),
        reason: SessionStartReason.created,
      );
      await SessionLifecycleService.I.sessionStarted(
        _session('refresh-fail'),
        reason: SessionStartReason.created,
      );
      expect(refreshes, 1, reason: 'reservation survives a refresh failure');

      SessionLifecycleService.I.skillRefresherForTest = (_) async {};
      var dispatches = 0;
      SessionLifecycleService.I.hookDispatcherForTest =
          (event, sessionId, {payload = const {}, model}) async {
            dispatches++;
            throw StateError('hook boom');
          };
      await SessionLifecycleService.I.sessionStarted(
        _session('hook-fail'),
        reason: SessionStartReason.created,
      );
      await SessionLifecycleService.I.sessionStarted(
        _session('hook-fail'),
        reason: SessionStartReason.created,
      );
      expect(dispatches, 1, reason: 'reservation survives a hook failure');
    });

    test('no listeners completes idempotently', () async {
      SessionLifecycleService.I.bootTokenProviderForTest = () => 'boot';
      SessionLifecycleService.I.activationWaiterForTest = (_) async {};
      SessionLifecycleService.I.skillRefresherForTest = (_) async {};

      final session = _session('no-listener');
      await SessionLifecycleService.I.sessionStarted(
        session,
        reason: SessionStartReason.created,
      );
      await SessionLifecycleService.I.sessionStarted(
        session,
        reason: SessionStartReason.created,
      );
      expect(SessionLifecycleService.I.bootGenerationForTest, 1);
    });

    test('sessionActive hooks never leak to another session', () async {
      final events = _recordEvents(HookService.I);
      _registerHooks(
        'lifecycle/scoped',
        activation: PluginActivation.sessionActive,
        immediateSessionId: 'owner',
      );
      SessionLifecycleService.I.bootTokenProviderForTest = () => 'boot';
      SessionLifecycleService.I.activationWaiterForTest = (_) async {};
      SessionLifecycleService.I.skillRefresherForTest = (_) async {};

      await SessionLifecycleService.I.sessionStarted(
        _session('other'),
        reason: SessionStartReason.created,
      );
      expect(events.where((event) => event.event == 'session_start'), isEmpty);

      await SessionLifecycleService.I.sessionStarted(
        _session('owner'),
        reason: SessionStartReason.created,
      );
      expect(
        events
            .where(
              (event) =>
                  event.event == 'session_start' &&
                  event.sessionId == 'owner',
            )
            .length,
        1,
      );
    });
  });

  group('boot identity', () {
    test('same boot token never re-increments the plugin epoch', () async {
      final prefs = await SharedPreferences.getInstance();
      final token = Object();
      await PluginRuntimeManager.I.activateForBoot(bootToken: token);
      final first = prefs.getInt(kPluginBootEpochPrefKey) ?? 0;
      await PluginRuntimeManager.I.activateForBoot(bootToken: token);
      expect(
        prefs.getInt(kPluginBootEpochPrefKey),
        first,
        reason: 'repeated activation for one token is idempotent',
      );

      final next = Object();
      await Future.wait([
        PluginRuntimeManager.I.activateForBoot(bootToken: next),
        PluginRuntimeManager.I.activateForBoot(bootToken: next),
      ]);
      expect(
        prefs.getInt(kPluginBootEpochPrefKey),
        first + 1,
        reason: 'a genuinely new boot advances the epoch exactly once',
      );
    });

    test(
      'M5: concurrent different boot tokens advance the epoch without racing',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final before = prefs.getInt(kPluginBootEpochPrefKey) ?? 0;
        final a = Object();
        final b = Object();
        await Future.wait([
          PluginRuntimeManager.I.activateForBoot(bootToken: a),
          PluginRuntimeManager.I.activateForBoot(bootToken: b),
        ]);
        expect(
          prefs.getInt(kPluginBootEpochPrefKey),
          before + 2,
          reason: 'two genuinely distinct boots must each advance the epoch',
        );
      },
    );

    test('a new boot token refires the same restored id once', () async {
      var token = Object();
      final fired = <String>[];
      SessionLifecycleService.I.bootTokenProviderForTest = () => token;
      SessionLifecycleService.I.activationWaiterForTest = (_) async {};
      SessionLifecycleService.I.skillRefresherForTest = (_) async {};
      SessionLifecycleService.I.hookDispatcherForTest =
          (event, sessionId, {payload = const {}, model}) async {
            fired.add(sessionId);
            return '';
          };

      final session = _session('restored-x');
      await SessionLifecycleService.I.sessionStarted(
        session,
        reason: SessionStartReason.restored,
      );
      await SessionLifecycleService.I.sessionStarted(
        session,
        reason: SessionStartReason.restored,
      );
      expect(fired, ['restored-x']);

      token = Object();
      await SessionLifecycleService.I.sessionStarted(
        session,
        reason: SessionStartReason.restored,
      );
      expect(fired, ['restored-x', 'restored-x']);
    });
  });

  group('session switching and loading', () {
    test('switch, refresh, load, and resume never refire lifecycle', () async {
      SharedPreferences.setMockInitialValues({
        'ovid_sessions': [
          _sessionJson('root-a', ['a']),
          _sessionJson('root-b', ['b']),
        ],
        'ovid_active_session': 'root-b',
      });
      final app = AppState.createForTest(
        startupStageDelegates: _offlineStages(),
        pluginBootActivator: (_, _) async {},
      );
      AgentService.skillCatalogInputsForTest =
          (sessionId) async => SkillCatalogInputs();
      final events = _injectDispatcher();

      await app.initialize();
      final baseline = events
          .where((event) => event.event == 'session_start')
          .length;
      expect(baseline, 1);

      app.selectSession('root-a');
      app.selectSession('root-b');
      await AgentService.I.refreshSkills(sessionId: 'root-b');
      app.onSessionsLoaded?.call();
      await app.initialize();
      final tokenBefore = app.bootToken;
      await app.reconnectServicesAfterResume();

      expect(app.bootToken, same(tokenBefore));
      expect(
        events.where((event) => event.event == 'session_start').length,
        baseline,
        reason: 'switching/refresh/load/resume is never creation',
      );
    });
  });

  group('boot-active root capture and bounded activation', () {
    test(
      'C1: a switch/newSession during readiness cannot steal the restored event',
      () async {
        SharedPreferences.setMockInitialValues({
          'ovid_sessions': [
            _sessionJson('root-a', ['a']),
            _sessionJson('root-b', ['b']),
          ],
          'ovid_active_session': 'root-b',
        });
        final skillGate = Completer<void>();
        var skillMountStarted = false;
        final app = AppState.createForTest(
          startupStageDelegates: {
            ..._offlineStages(),
            'skill.mount': () {
              skillMountStarted = true;
              return skillGate.future;
            },
          },
          pluginBootActivator: (_, _) async {},
        );
        AgentService.skillCatalogInputsForTest =
            (sessionId) async => SkillCatalogInputs();
        final events = _injectDispatcher();

        final init = app.initialize();
        for (var i = 0; i < 3000 && !skillMountStarted; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(skillMountStarted, isTrue, reason: 'readiness window reached');

        // The shell is interactive during the window: create and switch.
        app.newSession();
        final createdId = app.activeSession!.id;
        app.selectSession('root-a');

        skillGate.complete();
        await init;
        await app.drainSessionLifecycleForTest();

        final starts = events
            .where((event) => event.event == 'session_start')
            .toList();
        final restored = starts.where(
          (event) => event.sessionId == 'root-b',
        );
        expect(
          restored,
          hasLength(1),
          reason: 'the captured boot root fires even when no longer active',
        );
        expect(restored.single.payload['reason'], 'restored');
        expect(
          starts.where((event) => event.sessionId == 'root-a'),
          isEmpty,
          reason: 'switching is not creation and must not fire',
        );
        final created = starts.where(
          (event) => event.sessionId == createdId,
        );
        expect(created, hasLength(1));
        expect(created.single.payload['reason'], 'created');
      },
    );

    test(
      'I1: a hung activation still settles the barrier so session_start fires',
      () async {
        final never = Completer<void>();
        final app = AppState.createForTest(
          startupStageDelegates: _offlineStages(),
          startupStageTimeouts: {
            'plugin.activate': const Duration(milliseconds: 50),
          },
          pluginBootActivator: (_, _) => never.future,
        );
        AgentService.skillCatalogInputsForTest =
            (sessionId) async => SkillCatalogInputs();
        final events = _injectDispatcher();

        final readiness = app.initialize();
        await SessionLifecycleService.I
            .sessionStarted(
              _session('bounded'),
              reason: SessionStartReason.created,
            )
            .timeout(const Duration(seconds: 5));

        expect(
          events.where((event) => event.sessionId == 'bounded'),
          hasLength(1),
          reason: 'the barrier must settle within the stage timeout, not hang',
        );
        await readiness.timeout(const Duration(seconds: 5));
      },
    );

    test(
      'M2: restored path fires through the real HookService registry',
      () async {
        SharedPreferences.setMockInitialValues({
          'ovid_sessions': [
            _sessionJson('active', ['saved']),
          ],
          'ovid_active_session': 'active',
        });
        final events = _recordEvents(HookService.I);
        final app = AppState.createForTest(
          startupStageDelegates: _offlineStages(),
          pluginBootActivator: (_, _) async {
            // Register AFTER reconciliation prunes unpersisted rows, so the
            // real HookService can resolve the hook for the restored session.
            _registerHooks('lifecycle/real-restored');
          },
        );
        AgentService.skillCatalogInputsForTest =
            (sessionId) async => SkillCatalogInputs();

        await app.initialize();

        final starts = events.where(
          (event) => event.event == 'session_start',
        );
        expect(starts, hasLength(1));
        expect(starts.single.sessionId, 'active');
        expect(starts.single.payload['reason'], 'restored');
      },
    );
  });

  group('HookService concurrency', () {
    test(
      'same event for distinct sessions both run; nested same-session blocked',
      () async {
        _registerHooks('lifecycle/hook-concurrency');
        final svc = HookService.I;
        var calls = 0;
        svc.executorForTest = (cmd, env) async {
          calls++;
          if (env['PLUGIN_SESSION'] == 'concurrent-a') {
            await svc.fire('session_start', 'concurrent-a');
          }
          return '';
        };
        addTearDown(() => svc.executorForTest = null);

        await Future.wait([
          svc.fire('session_start', 'concurrent-a'),
          svc.fire('session_start', 'concurrent-b'),
        ]);
        expect(calls, 2);
      },
    );
  });

  group('subagent lifecycle ordering', () {
    test(
      'dispatch_agent fires session_start then subagent_start for the child',
      () async {
        final fixture = await _subagentFixture();
        _noOpLifecycleWaits();
        final events = _recordEvents(HookService.I);
        _registerHooks('lifecycle/subagent', subagentStart: true);

        await AgentService.I.dispatchForTest('dispatch_agent', {
          'prompt': 'do the child task',
          'label': 'child',
        });
        await Future<void>.delayed(const Duration(milliseconds: 200));

        final child = fixture.app.sessions.firstWhere(
          (session) => session.parentId == fixture.parent.id,
        );
        final sequence = events
            .where((event) => event.sessionId == child.id)
            .map((event) => event.event)
            .toList();
        expect(sequence, contains('session_start'));
        expect(sequence, contains('subagent_start'));
        expect(
          sequence.indexOf('subagent_start'),
          greaterThan(sequence.indexOf('session_start')),
        );

        final start = events.firstWhere(
          (event) =>
              event.event == 'session_start' && event.sessionId == child.id,
        );
        expect(start.payload['reason'], 'subagent');
        expect(start.payload['parentSessionId'], fixture.parent.id);
        expect(start.payload['isSubagent'], isTrue);

        final sub = events.firstWhere(
          (event) =>
              event.event == 'subagent_start' && event.sessionId == child.id,
        );
        expect(sub.payload['subagentId'], isNotNull);
        expect(sub.payload['parentSessionId'], fixture.parent.id);
        expect(sub.payload['label'], 'child');
        expect(sub.payload['background'], false);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'workflow fan-out loses neither event and keeps per-child order',
      () async {
        final fixture = await _subagentFixture();
        _noOpLifecycleWaits();
        final events = _recordEvents(HookService.I);
        _registerHooks('lifecycle/workflow', subagentStart: true);

        await AgentService.I.dispatchForTest('workflow', {
          'name': 'wf',
          'phases': [
            {
              'name': 'p1',
              'tasks': [
                {'label': 't1', 'prompt': 'one'},
                {'label': 't2', 'prompt': 'two'},
              ],
            },
          ],
        });

        final children = fixture.app.sessions
            .where((session) => session.parentId == fixture.parent.id)
            .toList();
        expect(children, hasLength(2));
        for (final child in children) {
          final sequence = events
              .where((event) => event.sessionId == child.id)
              .map((event) => event.event)
              .toList();
          expect(sequence.where((e) => e == 'session_start'), hasLength(1));
          expect(sequence.where((e) => e == 'subagent_start'), hasLength(1));
          expect(
            sequence.indexOf('subagent_start'),
            greaterThan(sequence.indexOf('session_start')),
          );
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'Ralph uses the same session_start then subagent_start ordering',
      () async {
        final fixture = await _subagentFixture(
          content:
              '{"status":"complete","summary":"ok","evidence":"e",'
              '"next_steps":"","blocker":""}',
        );
        _noOpLifecycleWaits();
        final events = _recordEvents(HookService.I);
        _registerHooks('lifecycle/ralph', subagentStart: true);

        await AgentService.I.dispatchForTest('ralph', {
          'objective': 'finish',
          'max_rounds': 1,
        });

        final child = fixture.app.sessions.firstWhere(
          (session) => session.parentId == fixture.parent.id,
        );
        final sequence = events
            .where((event) => event.sessionId == child.id)
            .map((event) => event.event)
            .toList();
        expect(sequence, contains('session_start'));
        expect(sequence, contains('subagent_start'));
        expect(
          sequence.indexOf('subagent_start'),
          greaterThan(sequence.indexOf('session_start')),
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('M4: a dispatch cannot reuse a persisted durable agent id', () async {
      final fixture = await _subagentFixture();
      _noOpLifecycleWaits();
      _registerHooks('lifecycle/collision', subagentStart: true);
      final nextId = 'sub-${AgentService.I.subagentCounterForTest + 1}';
      final persisted = ChatSession(
        id: 'persisted-child',
        title: 'persisted',
        model: 'm',
        parentId: fixture.parent.id,
      )..agentId = nextId;
      fixture.app.sessions.insert(0, persisted);

      await AgentService.I.dispatchForTest('dispatch_agent', {
        'prompt': 'do a thing',
        'label': 'Collision probe',
        'run_in_background': true,
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final child = fixture.app.sessions.firstWhere(
        (session) =>
            session.parentId == fixture.parent.id &&
            session.id != 'persisted-child',
      );
      expect(
        child.agentId,
        isNot(nextId),
        reason: 'the next counter id is already durable on another session',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
