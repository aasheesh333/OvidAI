import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/presets.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/usage_attempt.dart';
import 'package:ovid_ai/core/usage_attempt_recorder.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

class _DelayedConnect extends HttpOverrides {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool first = true;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    if (!first) return client;
    first = false;
    return _DelayedClient(client, entered, release);
  }
}

class _DelayedClient implements HttpClient {
  final HttpClient delegate;
  final Completer<void> entered, release;
  _DelayedClient(this.delegate, this.entered, this.release);
  @override
  set connectionTimeout(Duration? value) => delegate.connectionTimeout = value;
  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    final request = await delegate.postUrl(url);
    entered.complete();
    await release.future;
    return request;
  }
  @override
  void close({bool force = false}) {
    // Model a connection factory that completes after cancellation. The
    // caller must reject/close the returned resource instead of publishing it.
    if (release.isCompleted) delegate.close(force: force);
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final agent = AgentService.I;
  late AppState app;
  late Directory root;
  late HttpServer server;
  late ProviderConfig provider;
  late ChatSession session;
  final requests = <Map<String, dynamic>>[];
  Future<void> Function(HttpRequest, Map<String, dynamic>)? respond;

  Future<void> answer(HttpRequest req, String text, {bool tool = false}) async {
    req.response.headers.contentType = ContentType('text', 'event-stream');
    req.response.write('data: ${jsonEncode({
      'id': 'fixture', 'object': 'chat.completion.chunk',
      'choices': [{'index': 0, 'delta': tool
          ? {'tool_calls': [{'index': 0, 'id': 'call-fixture',
              'type': 'function', 'function': {'name': 'todo_write',
                'arguments': '{"todos":[]}'}}]}
          : {'content': text},
        'finish_reason': tool ? 'tool_calls' : 'stop'}],
      'usage': {'prompt_tokens': 12, 'completion_tokens': 3, 'total_tokens': 15},
    })}\n\ndata: [DONE]\n\n');
    await req.response.close();
  }

  Future<void> until(bool Function() predicate) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!predicate()) {
      if (DateTime.now().isAfter(deadline)) fail('condition did not settle');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  setUpAll(() {
    if (Platform.isLinux) {
      open.overrideFor(OperatingSystem.linux,
          () => ffi.DynamicLibrary.open('libsqlite3.so.0'));
    }
  });
  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('agent-route-');
    SessionLedger.rootOverrideForTest = root;
    SessionSearch.dbPathOverrideForTest = '${root.path}/search.db';
    app = AppState.createForTest();
    agent.debugPauseScheduleTimerForTest(true);
    requests.clear();
    respond = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider = ProviderConfig(id: 'dispatch-fixture', name: 'Fixture',
        description: '', baseUrl: 'http://127.0.0.1:${server.port}/original/',
        apiKey: 'original-key', models: ['chip-model', 'hidden-model']);
    app.providers.add(provider);
    session = ChatSession(id: 'dispatch-session', title: 'Custom title',
        providerId: provider.id, model: 'chip-model', mode: 'drive')
      ..workspaceFolder = root.path;
    app.sessions.add(session);
    app.activeSessionId = session.id;
    server.listen((req) async {
      final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
      requests.add({...body, 'path': req.uri.path,
        'authorization': req.headers.value('authorization')});
      if (respond != null) {
        await respond!(req, body);
      } else {
        await answer(req, 'done');
      }
    });
  });
  tearDown(() async {
    HookService.I.resetForTest();
    PluginContributionRegistry.I.unregisterPlugin('fixture/submit');
    PresetRegistry.deleteCustom('fixture-preset');
    agent.dropSessionRun(session.id);
    await server.close(force: true);
    AppState.resetTestInstance();
  });

  void submitHook(Future<String> Function() callback) {
    PluginContributionRegistry.I.register(NormalizedPluginManifest(
      id: 'fixture/submit', name: 'Submit', version: '1',
      format: PluginFormat.claudeCode, rootPath: root.path,
      hooks: [PluginHook(pluginId: 'fixture/submit', event: 'user_prompt_submit',
          ordinal: 0, type: 'command', payload: 'wait')],
    ), activation: PluginActivation.globalActive);
    HookService.I.executorForTest = (_, _) => callback();
  }

  test('session model chip wins over a hidden preset model pin', () async {
    PresetRegistry.saveCustom(const AgentPreset(id: 'fixture-preset',
        label: 'Fixture', description: '', model: 'hidden-model', temperature: 0.2));
    session.presetId = 'fixture-preset';
    await agent.runTask('first', sessionId: session.id);
    expect(requests.single['model'], 'chip-model');
    expect(requests.single['temperature'], 0.2);
  });

  test('admission reserves before submit hooks and freezes the request route', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var hookCalls = 0;
    submitHook(() async {
      hookCalls++;
      if (!entered.isCompleted) entered.complete();
      await release.future;
      return '';
    });
    final first = agent.runTask('first', sessionId: session.id);
    await entered.future;
    final busyDuringHook = agent.busyFor(session.id);
    provider..apiKey = 'edited-key'..baseUrl = 'http://127.0.0.1:${server.port}/edited/';
    session.model = 'new-model';
    final duplicate = agent.runTask('duplicate', sessionId: session.id);
    release.complete();
    await Future.wait([first, duplicate]);
    expect(busyDuringHook, isTrue);
    expect(hookCalls, 1);
    expect(requests, hasLength(1));
    expect(requests.single['model'], 'chip-model');
    expect(requests.single['authorization'], 'Bearer original-key');
    expect(requests.single['path'], '/original/chat/completions');
    expect(agent.busyFor(session.id), isFalse);
  });

  test('stop during an ordinary submit hook cannot admit late work', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    submitHook(() async { entered.complete(); await release.future; return ''; });
    final task = agent.runTask('first', sessionId: session.id);
    await entered.future;
    agent.stopRequested(sessionId: session.id);
    release.complete();
    await task;
    expect(requests, isEmpty);
    expect(agent.busyFor(session.id), isFalse);
  });

  void addNextProvider() {
    app.providers.add(ProviderConfig(id: 'next-provider', name: 'Next',
        description: '', baseUrl: 'http://127.0.0.1:${server.port}/next/',
        apiKey: 'next-key', models: ['next-model']));
  }

  void selectNextChip() {
    addNextProvider();
    session..providerId = 'next-provider'..model = 'next-model';
  }

  test('a queued message after a chip change switches the route for that '
      'and every later request of the run', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    respond = (req, body) async {
      if (requests.length == 1) {
        entered.complete();
        await release.future;
        await answer(req, '', tool: true);
      } else if (requests.length == 2) {
        await answer(req, '', tool: true); // the run keeps looping
      } else {
        await answer(req, 'done-${requests.length}');
      }
    };
    final first = agent.runTask('first', sessionId: session.id);
    await entered.future;
    selectNextChip();
    agent.enqueueMessage('ordinary follow-up', sessionId: session.id);
    release.complete();
    await first;
    await until(() => !agent.busyFor(session.id));
    // Queueing never stops the run; the follow-up rides its very next
    // request on the chip selected when it is delivered — and the run then
    // CONTINUES on that route through the tool loop.
    expect(requests.map((r) => r['model']),
        ['chip-model', 'next-model', 'next-model']);
    expect(requests.map((r) => r['path']), [
      '/original/chat/completions',
      '/next/chat/completions',
      '/next/chat/completions',
    ]);
    expect(requests[1]['authorization'], 'Bearer next-key');
    expect(requests[2]['authorization'], 'Bearer next-key');
    expect(jsonEncode(requests[1]['messages']), contains('ordinary follow-up'));
    expect(agent.queuedMessagesFor(session.id), isEmpty);
    expect(session.messages.where((m) => m.role == 'user' &&
        m.content == 'ordinary follow-up'), hasLength(1));
  });

  test('a chip change without a send keeps the running run on its route', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    respond = (req, body) async {
      if (requests.length == 1) {
        entered.complete();
        await release.future;
        await answer(req, '', tool: true);
      } else if (requests.length == 2) {
        await answer(req, '', tool: true);
      } else {
        await answer(req, 'done');
      }
    };
    final first = agent.runTask('first', sessionId: session.id);
    await entered.future;
    selectNextChip();
    release.complete();
    await first;
    await until(() => !agent.busyFor(session.id));
    expect(requests.map((r) => r['model']),
        ['chip-model', 'chip-model', 'chip-model']);
    expect(requests.map((r) => r['authorization']).toSet(),
        {'Bearer original-key'});
    expect(AgentService.effectiveModelForSession(session), 'chip-model');
  });

  test('internal notices never switch the route; only chat-box rows do', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    respond = (req, body) async {
      if (requests.length == 1) {
        entered.complete();
        await release.future;
        await answer(req, '', tool: true);
      } else {
        await answer(req, 'done');
      }
    };
    final first = agent.runTask('first', sessionId: session.id);
    await entered.future;
    selectNextChip();
    // Subagent reports / settlement notices enter the queue without the
    // composer flag.
    agent.runBucketForTest(session.id).queue.add('subagent report');
    release.complete();
    await first;
    await until(() => !agent.busyFor(session.id));
    expect(requests.map((r) => r['model']), ['chip-model', 'chip-model']);
    expect(jsonEncode(requests[1]['messages']), contains('subagent report'));
  });

  test('steered and ordinary rows join the next request together, in queue order', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    respond = (req, body) async {
      if (requests.length == 1) {
        entered.complete();
        await release.future;
        await answer(req, '', tool: true);
      } else {
        await answer(req, 'done');
      }
    };
    final task = agent.runTask('first', sessionId: session.id);
    await entered.future;
    agent.enqueueMessage('ordinary', sessionId: session.id);
    agent.enqueueMessage('steering', sessionId: session.id);
    agent.steerQueuedMessageById(agent.queuedMessageIdsFor(session.id).last);
    selectNextChip();
    release.complete();
    await task;
    await until(() => !agent.busyFor(session.id));
    expect(requests.map((r) => r['model']), ['chip-model', 'next-model']);
    final sent = jsonEncode(requests[1]['messages']);
    expect(sent.indexOf('steering'), greaterThan(-1));
    expect(sent.indexOf('ordinary'), greaterThan(sent.indexOf('steering')));
  });

  test('stop-and-send-now runs the queued message on the current chip', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    respond = (req, body) async {
      if (requests.length == 1) {
        entered.complete();
        await release.future;
        try {
          await answer(req, '', tool: true);
        } catch (_) {}
      } else {
        await answer(req, 'done');
      }
    };
    final first = agent.runTask('first', sessionId: session.id);
    await entered.future;
    agent.enqueueMessage('urgent', sessionId: session.id);
    selectNextChip();
    agent.quickSendQueuedMessage(agent.queuedMessageIdsFor(session.id).single,
        sessionId: session.id);
    release.complete();
    await first;
    await until(() => requests.length >= 2 && !agent.busyFor(session.id));
    expect(requests.map((r) => r['model']), ['chip-model', 'next-model']);
    expect(requests[1]['path'], '/next/chat/completions');
    expect(requests[1]['authorization'], 'Bearer next-key');
    expect(jsonEncode(requests[1]['messages']), contains('urgent'));
  });

  test('a new run uses the current chip', () async {
    await agent.runTask('first', sessionId: session.id);
    selectNextChip();
    await agent.runTask('second', sessionId: session.id);
    expect(requests.map((r) => r['model']), ['chip-model', 'next-model']);
    expect(requests[1]['authorization'], 'Bearer next-key');
  });

  test('usage attribution follows the model actually used after a switch', () async {
    final attempts = <UsageAttempt>[];
    agent.resetUsageAttemptRecorderForTest(recorder: UsageAttemptRecorder(
      owner: AppState.I.sessionAccountToken,
      write: (attempt, {owner}) async {
        attempts.add(attempt);
        return true;
      },
    ));
    addTearDown(() => agent.resetUsageAttemptRecorderForTest());
    final entered = Completer<void>();
    final release = Completer<void>();
    respond = (req, body) async {
      if (requests.length == 1) {
        entered.complete();
        await release.future;
        await answer(req, '', tool: true);
      } else {
        await answer(req, 'done');
      }
    };
    final first = agent.runTask('first', sessionId: session.id);
    await entered.future;
    selectNextChip();
    agent.enqueueMessage('follow-up', sessionId: session.id);
    release.complete();
    await first;
    await until(() => !agent.busyFor(session.id));
    final byRequest = <String, UsageAttempt>{};
    for (final a in attempts) {
      byRequest[a.requestId] = a;
    }
    final used = byRequest.values
        .where((a) => a.purpose == 'agent')
        .map((a) => '${a.provider}/${a.requestedModel}')
        .toList();
    expect(used, ['dispatch-fixture/chip-model', 'next-provider/next-model']);
    expect(AgentService.effectiveModelForSession(session), 'next-model');
  });

  for (final barrier in ['pre_request', 'retry']) {
    test('superseded $barrier chain cannot send or steal replacement handles', () async {
      final paused = Completer<void>();
      final releaseHook = Completer<void>();
      final replacementEntered = Completer<void>();
      final releaseReplacement = Completer<void>();
      final oldDelays = AgentService.retryDelaysForTest;
      addTearDown(() => AgentService.retryDelaysForTest = oldDelays);
      void Function()? releaseRetry;
      if (barrier == 'pre_request') {
        PluginContributionRegistry.I.register(NormalizedPluginManifest(
          id: 'fixture/submit', name: 'Pre request', version: '1',
          format: PluginFormat.claudeCode, rootPath: root.path,
          hooks: [PluginHook(pluginId: 'fixture/submit', event: 'pre_request',
              ordinal: 0, type: 'command', payload: 'wait')],
        ), activation: PluginActivation.globalActive);
        var calls = 0;
        HookService.I.executorForTest = (_, _) async {
          if (++calls == 1) {
            paused.complete();
            await releaseHook.future;
          }
          return '';
        };
      } else {
        AgentService.retryDelaysForTest = List.filled(4, const Duration(milliseconds: 987));
      }
      respond = (req, body) async {
        if (body['model'] == 'chip-model') {
          if (barrier == 'retry' && requests.length == 1) {
            req.response.statusCode = 503;
            req.response.write('temporarily unavailable');
            await req.response.close();
          } else {
            await answer(req, 'STALE');
          }
        } else {
          replacementEntered.complete();
          await releaseReplacement.future;
          await answer(req, 'replacement');
        }
      };
      final first = runZoned(() => agent.runTask('first', sessionId: session.id),
          zoneSpecification: ZoneSpecification(createTimer: (self, parent, zone, duration, callback) {
        if (barrier == 'retry' && duration == const Duration(milliseconds: 987)) {
          final timer = parent.createTimer(zone, const Duration(days: 1), callback);
          releaseRetry = () { timer.cancel(); zone.run(callback); };
          paused.complete();
          return timer;
        }
        return parent.createTimer(zone, duration, callback);
      }));
      await paused.future.timeout(const Duration(seconds: 10));
      agent.stopRequested(sessionId: session.id);
      session.model = 'replacement-model';
      final replacement = agent.runTask('replacement', sessionId: session.id);
      await replacementEntered.future.timeout(const Duration(seconds: 10));
      final bucket = agent.runBucketForTest(session.id);
      final request = bucket.activeRequest;
      final client = bucket.activeClient;
      final id = bucket.activeRunId;
      expect(request, isNotNull);
      expect(client, isNotNull);
      if (barrier == 'retry') { releaseRetry!(); } else { releaseHook.complete(); }
      await first.timeout(const Duration(seconds: 10));
      final models = requests.map((r) => r['model']).toList();
      final retainedRequest = identical(bucket.activeRequest, request);
      final retainedClient = identical(bucket.activeClient, client);
      final retainedId = bucket.activeRunId == id;
      releaseReplacement.complete();
      await replacement;
      expect(models, barrier == 'retry'
          ? ['chip-model', 'replacement-model'] : ['replacement-model']);
      expect(retainedRequest, isTrue);
      expect(retainedClient, isTrue);
      expect(retainedId, isTrue);
      expect(session.messages.any((m) => m.content == 'STALE'), isFalse);
    });
  }

  for (final format in [ApiFormat.openai, ApiFormat.anthropic]) {
    test('${format.name} late connection completion leaves replacement handles intact', () async {
      final delayed = _DelayedConnect();
      HttpOverrides.global = delayed;
      provider.apiFormat = format;
      final replacementEntered = Completer<void>();
      final releaseReplacement = Completer<void>();
      respond = (req, body) async {
        replacementEntered.complete();
        await releaseReplacement.future;
        if (format == ApiFormat.openai) {
          await answer(req, 'replacement');
        } else {
          req.response.headers.contentType = ContentType('text', 'event-stream');
          req.response.write('data: ${jsonEncode({'type': 'content_block_delta',
            'index': 0, 'delta': {'type': 'text_delta', 'text': 'replacement'}})}\n\n');
          await req.response.close();
        }
      };
      final first = agent.runTask('first', sessionId: session.id);
      await delayed.entered.future;
      agent.stopRequested(sessionId: session.id);
      session.model = 'replacement-model';
      final replacement = agent.runTask('replacement', sessionId: session.id);
      await replacementEntered.future;
      final bucket = agent.runBucketForTest(session.id);
      final request = bucket.activeRequest;
      final client = bucket.activeClient;
      delayed.release.complete();
      await first.timeout(const Duration(seconds: 10));
      final retainedRequest = identical(bucket.activeRequest, request);
      final retainedClient = identical(bucket.activeClient, client);
      releaseReplacement.complete();
      await replacement;
      HttpOverrides.global = null;
      expect(retainedRequest, isTrue);
      expect(retainedClient, isTrue);
      expect(requests.map((r) => r['model']), ['replacement-model']);
    });
  }
}
