import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/usage_attempt.dart';
import 'package:ovid_ai/core/usage_attempt_recorder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory usageRoot;

  setUpAll(() {
    HttpOverrides.global = null;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    usageRoot = await Directory.systemTemp.createTemp('ovid-accounting-');
    AppState.usageRootOverrideForTest = usageRoot;
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I.debugPauseScheduleTimerForTest(true);
  });

  tearDown(() async {
    AgentService.retryDelaysForTest = const [
      Duration(seconds: 3),
      Duration(seconds: 9),
      Duration(seconds: 27),
      Duration(seconds: 60),
    ];
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AgentService.I.resetUsageAttemptRecorderForTest();
    AgentNotificationService.I.resetForTest();
    AppState.usageRootOverrideForTest = null;
    AppState.resetTestInstance();
    await usageRoot.delete(recursive: true);
  });

  test(
    'records one prepared attempt per retry under one logical request',
    () async {
      final app = AppState.I;
      await app.prepareUsageAttempts();
      var requests = 0;
      final server = await _serve((request) async {
        requests++;
        if (requests == 1) {
          request.response.statusCode = 503;
          await request.response.close();
          return;
        }
        await _sse(request, [
          {
            'model': 'gpt-test',
            'choices': [
              {
                'delta': {'content': 'ok'},
                'finish_reason': 'stop',
              },
            ],
          },
          {
            'model': 'gpt-test',
            'choices': [],
            'usage': {
              'prompt_tokens': 0,
              'completion_tokens': 2,
              'total_tokens': 2,
            },
          },
        ]);
      });
      addTearDown(server.close);

      AgentService.retryDelaysForTest = const [
        Duration.zero,
        Duration.zero,
        Duration.zero,
        Duration.zero,
      ];
      final provider = ProviderConfig(
        id: 'accounting-test',
        name: 'Accounting test',
        description: '',
        baseUrl: 'http://${server.address.host}:${server.port}',
        models: ['test-model'],
        selectedModel: 'test-model',
        requiresApiKey: false,
      );
      final session = ChatSession(
        id: 'accounting-session',
        title: 'Accounting',
        model: 'test-model',
        providerId: provider.id,
        messages: [Message(role: 'user', content: 'hello')],
      );

      final result = await AgentService.I.callLlmForTest(provider, [
        {'role': 'user', 'content': 'hello'},
      ], session);

       expect(result?['content'], 'ok');
       expect(requests, 2);
       await _eventually(() {
         final records = app.usageAttempts
             .where((a) => a.provider == provider.id)
             .toList();
         return records.length == 2 &&
             records.every((a) => a.outcome != UsageOutcome.pending);
       });
      final records = app.usageAttempts
          .where((a) => a.provider == provider.id)
          .toList();
      expect(records, hasLength(2));
      expect(records.map((a) => a.attemptId).toSet(), hasLength(2));
      expect(records.map((a) => a.requestId).toSet(), hasLength(1));
      expect(records.every((a) => a.revision >= 2), isTrue);
      expect(records.map((a) => a.outcome), contains(UsageOutcome.failed));
      final success = records.singleWhere(
        (a) => a.outcome == UsageOutcome.succeeded,
      );
      expect(success.inputTokens, UsageTokenCount.reported(0));
      expect(success.outputTokens, UsageTokenCount.reported(2));
      expect(success.elapsed, isNotNull);
    },
  );

  test(
    'recorder uses transport elapsed time and ignores duplicate terminal updates',
    () async {
      final writes = <UsageAttempt>[];
      final recorder = UsageAttemptRecorder(
        owner: Object(),
        write: (attempt, {owner}) async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          writes.add(attempt);
          return true;
        },
      );
      final handle = await recorder.begin(
        requestId: 'request-test',
        provider: 'provider-test',
        requestedModel: 'model-test',
        purpose: 'agent',
        sessionId: 'session-test',
        runId: 'run-test',
      );
      expect(handle, isNotNull);
      handle!.setTransportElapsed(17);
      await handle.updateUsage(usage: {'total_tokens': 3});
       await handle.complete(outcome: UsageOutcome.succeeded);
       await handle.complete(outcome: UsageOutcome.failed);
      await handle.updateUsage(usage: {'total_tokens': 99});

      expect(writes, hasLength(2));
      expect(writes.last.elapsed, const Duration(milliseconds: 17));
      expect(writes.last.outcome, UsageOutcome.succeeded);
      expect(writes.last.totalTokens, UsageTokenCount.reported(3));
    },
  );

  test(
    'recorder coalesces usage updates without delaying terminal capture',
    () async {
      final writes = <UsageAttempt>[];
      final release = Completer<void>();
      var writeCount = 0;
      final recorder = UsageAttemptRecorder(
        owner: Object(),
        write: (attempt, {owner}) async {
          writeCount++;
          if (writeCount > 1) await release.future;
          writes.add(attempt);
          return true;
        },
      );
      final handle = await recorder.begin(
        requestId: 'request-buffered',
        provider: 'provider-test',
        requestedModel: 'model-test',
        purpose: 'agent',
        sessionId: null,
        runId: null,
      );
      expect(handle, isNotNull);

      await handle!
          .updateUsage(usage: {'total_tokens': 7})
          .timeout(const Duration(milliseconds: 20));
      final terminal = handle.complete(outcome: UsageOutcome.succeeded);
      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(writes, hasLength(1));

       release.complete();
       await terminal;
      expect(writes, hasLength(2));
      expect(writes.last.dispatchStage, UsageDispatchStage.completed);
      expect(writes.last.totalTokens, UsageTokenCount.reported(7));
    },
  );

  test(
    'transmission marking is queued while terminal reconciliation keeps final usage',
    () async {
      final writes = <UsageAttempt>[];
      final release = Completer<void>();
      var writeCount = 0;
      final recorder = UsageAttemptRecorder(
        owner: Object(),
        write: (attempt, {owner}) async {
          writeCount++;
          if (writeCount == 2) await release.future;
          writes.add(attempt);
          return true;
        },
      );
      final handle = await recorder.begin(
        requestId: 'request-queued-transmission',
        provider: 'provider-test',
        requestedModel: 'model-test',
        purpose: 'agent',
        sessionId: null,
        runId: null,
      );
      expect(handle, isNotNull);

      final marking = handle!.markTransmitted();
      await marking.timeout(const Duration(milliseconds: 20));
      handle.updateUsage(usage: {'total_tokens': 11});
      final terminal = handle.complete(outcome: UsageOutcome.succeeded);

      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(writes, hasLength(1));
       release.complete();
       await terminal;

      expect(writes.last.dispatchStage, UsageDispatchStage.completed);
      expect(writes.last.totalTokens, UsageTokenCount.reported(11));
    },
  );

  test(
    'recorder exposes incomplete capture without retaining storage errors',
    () async {
      final recorder = UsageAttemptRecorder(
        owner: Object(),
        write: (attempt, {owner}) async => false,
      );
      final handle = await recorder.begin(
        requestId: 'request-missing',
        provider: 'provider-test',
        requestedModel: 'model-test',
        purpose: 'helper',
        sessionId: null,
        runId: null,
      );

      expect(handle, isNotNull);
      expect(handle?.captureResult.captured, isFalse);
      expect(handle?.captureResult.stage, UsageAttemptCaptureStage.prepared);
    },
  );

  test(
    'delayed preparation journal does not block transport admission',
    () async {
      final release = Completer<void>();
      final writes = <UsageAttempt>[];
      final recorder = UsageAttemptRecorder(
        owner: Object(),
        write: (attempt, {owner}) async {
          await release.future;
          writes.add(attempt);
          return true;
        },
      );

      final stopwatch = Stopwatch()..start();
      final handle = await recorder.begin(
        requestId: 'request-delayed-preparation',
        provider: 'provider-test',
        requestedModel: 'model-test',
        purpose: 'agent',
        sessionId: null,
        runId: null,
      );
      stopwatch.stop();

      expect(handle, isNotNull);
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 100)));
      handle!.setTransportElapsed(23);
      final terminal = handle.complete(outcome: UsageOutcome.succeeded);

       release.complete();
       await terminal;
      expect(handle.captureResult.captured, isTrue);
      expect(writes.last.elapsed, const Duration(milliseconds: 23));
    },
  );

  test(
    'terminal provider completion is not delayed by a blocked journal',
    () async {
      final release = Completer<void>();
      final writes = <UsageAttempt>[];
      final captured = Completer<void>();
      final recorder = UsageAttemptRecorder(
        owner: AppState.I.sessionAccountToken,
        write: (attempt, {owner}) async {
          await release.future;
          writes.add(attempt);
          if (attempt.dispatchStage == UsageDispatchStage.completed) {
            captured.complete();
          }
          return true;
        },
      );
      AgentService.I.resetUsageAttemptRecorderForTest(recorder: recorder);
      final server = await _serve((request) => _sse(request, [
        {
          'choices': [{'delta': {'content': 'ok'}, 'finish_reason': 'stop'}],
          'usage': {'total_tokens': 13},
        },
      ]));
      addTearDown(server.close);
      final provider = ProviderConfig(
        id: 'blocked-journal', name: 'Blocked journal', description: '',
        baseUrl: 'http://${server.address.host}:${server.port}',
        models: ['test-model'], selectedModel: 'test-model', requiresApiKey: false,
      );
      final completion = AgentService.I.callLlmForTest(
        provider, [{'role': 'user', 'content': 'hello'}],
        ChatSession(id: 'blocked-session', title: 'Blocked', model: 'test-model',
          providerId: provider.id, messages: []),
      );
      try {
        final result = await completion.timeout(const Duration(milliseconds: 500));
        expect(result?['content'], 'ok');
        expect(writes, isEmpty);
      } finally {
        release.complete();
        await completion;
        await captured.future;
      }
      expect(writes.last.dispatchStage, UsageDispatchStage.completed);
      expect(writes.last.totalTokens, UsageTokenCount.reported(13));
    },
  );

  test('capture status belongs to its handle', () async {
    final writes = <UsageAttempt>[];
    final recorder = UsageAttemptRecorder(
      owner: Object(),
      write: (attempt, {owner}) async {
        writes.add(attempt);
        return attempt.requestId != 'request-failed';
      },
    );

    final failed = await recorder.begin(
      requestId: 'request-failed',
      provider: 'provider-test',
      requestedModel: 'model-test',
      purpose: 'agent',
      sessionId: null,
      runId: null,
    );
    final succeeded = await recorder.begin(
      requestId: 'request-succeeded',
      provider: 'provider-test',
      requestedModel: 'model-test',
      purpose: 'agent',
      sessionId: null,
      runId: null,
    );
    await Future<void>.delayed(const Duration(milliseconds: 1));

    expect(failed!.captureResult.captured, isFalse);
    expect(succeeded!.captureResult.captured, isTrue);
  });

  test(
    'recorder preserves helper purpose and terminal partial outcomes',
    () async {
      final writes = <UsageAttempt>[];
      final recorder = UsageAttemptRecorder(
        owner: Object(),
        write: (attempt, {owner}) async {
          writes.add(attempt);
          return true;
        },
      );
      final handle = await recorder.begin(
        requestId: 'request-helper',
        provider: 'provider-test',
        requestedModel: 'model-test',
        purpose: 'compaction',
        sessionId: 'session-test',
        runId: 'run-test',
      );
      expect(handle, isNotNull);
      await handle!.markTransmitted();
      await handle.updateUsage(usage: {'prompt_tokens': 4});
      await handle.complete(
        outcome: UsageOutcome.cancelled,
        usage: {'prompt_tokens': 4},
      );

      expect(
        writes.map((attempt) => attempt.purpose),
        everyElement('compaction'),
      );
      expect(writes.last.dispatchStage, UsageDispatchStage.completed);
      expect(writes.last.outcome, UsageOutcome.cancelled);
      expect(writes.last.inputTokens, UsageTokenCount.reported(4));
    },
  );
}

Future<HttpServer> _serve(
  Future<void> Function(HttpRequest request) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(() async {
    await for (final request in server) {
      unawaited(handler(request));
    }
  }());
  return server;
}

Future<void> _sse(
  HttpRequest request,
  List<Map<String, dynamic>> events,
) async {
  request.response.headers.contentType = ContentType('text', 'event-stream');
  request.response.headers.chunkedTransferEncoding = true;
  for (final event in events) {
    request.response.write('data: ${jsonEncode(event)}\n\n');
    await request.response.flush();
  }
  request.response.write('data: [DONE]\n\n');
  await request.response.close();
}

Future<void> _eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition did not become true before the deadline');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
