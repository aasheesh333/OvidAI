import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/device_control_service.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

/// Retry diagnostics: when a turn hits transient provider failures, the
/// think row must show the request size and the recovery — otherwise a
/// slow turn (e.g. 20s on a big session) is indistinguishable from a hang.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory ledgerDir;
  late AppState app;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ledgerDir = Directory.systemTemp.createTempSync('retry-diag-');
    SessionLedger.rootOverrideForTest = ledgerDir;
    SessionSearch.dbPathOverrideForTest = '${ledgerDir.path}/search.db';
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
    app = AppState.I;
    await app.initialize();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app.sessions.clear();
    app.activeSessionId = null;
    AgentService.retryDelaysForTest = const [
      Duration.zero,
      Duration.zero,
      Duration.zero,
      Duration.zero,
    ];
    AgentService.runRetryWaitForTest = (_) => Duration.zero;
  });

  tearDown(() {
    AgentService.llmOnceForTest = null;
    AgentService.runRetryWaitForTest = null;
    AgentService.retryDelaysForTest = const [
      Duration(seconds: 3),
      Duration(seconds: 9),
      Duration(seconds: 27),
      Duration(seconds: 60),
    ];
    AgentService.setRunSessionForTest('');
  });

  ChatSession makeSession(String id) {
    final provider = app.providerById('ollama-local')!;
    provider
      ..baseUrl = 'http://127.0.0.1:1/v1'
      ..models = ['test-model']
      ..selectedModel = 'test-model';
    final s = ChatSession(
      id: id,
      title: 'Custom title', // prevents the fire-and-forget title LLM call
      providerId: provider.id,
      model: 'test-model',
      mode: 'auto',
    );
    app.sessions.add(s);
    app.activeSessionId = s.id;
    return s;
  }

  // Think rows land on the zone-pinned run bucket (capped at 120), so
  // read them back from the session bucket after the run completes.
  String thinkText(String sessionId) => AgentService.I
      .runBucketForTest(sessionId)
      .runEvents
      .where((e) => e.kind == 'think')
      .map((e) => e.text)
      .join('\n');

  test('LLM retry line shows request size and recovery', () async {
    final s = makeSession('retry-diag-1');
    var attempt = 0;
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      attempt++;
      if (attempt == 1) {
        AgentService.I.streamToBubbleForTest(session, 'PARTIAL ');
        AgentService.I.lastError = 'stream error: boom';
        return null;
      }
      AgentService.I.streamToBubbleForTest(session, 'FINAL ANSWER');
      return {
        'role': 'assistant',
        'content': 'FINAL ANSWER',
        'finish_reason': 'stop',
      };
    };

    await AgentService.I
        .runTask('hi', sessionId: s.id)
        .timeout(const Duration(seconds: 20));

    final thinks = thinkText(s.id);
    expect(thinks, contains('KB request'));
    expect(thinks, contains('recovered after 2 attempts'));
  });

  test('run-level retry line shows context size', () async {
    final s = makeSession('retry-diag-2');
    var attempt = 0;
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      attempt++;
      // Exhaust the whole inner retry budget (5 attempts), then succeed on
      // the run-level retry so the outer hiccup line fires.
      if (attempt <= 5) {
        AgentService.I.lastError = 'stream error: boom';
        return null;
      }
      AgentService.I.streamToBubbleForTest(session, 'FINAL ANSWER');
      return {
        'role': 'assistant',
        'content': 'FINAL ANSWER',
        'finish_reason': 'stop',
      };
    };

    await AgentService.I
        .runTask('hi', sessionId: s.id)
        .timeout(const Duration(seconds: 30));

    expect(thinkText(s.id), contains('tokens in context'));
  });

  test(
    'terminal empty reply has one notice and no invented timeout advice',
    () async {
      final s = makeSession('empty-reply');
      AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
        AgentService.I.lastError = 'empty response from test-model';
        return null;
      };
      await AgentService.I.runTask('hi', sessionId: s.id);
      final replies = s.messages.where((m) => m.role == 'assistant').toList();
      expect(replies, hasLength(1));
      expect(
        replies.single.content,
        isNot(contains('increase "AI response timeout"')),
      );
      expect(replies.single.content.toLowerCase(), contains('retry'));
    },
  );

  for (final format in [ApiFormat.openai, ApiFormat.anthropic]) {
    test(
      '${format.name} empty stream does not inherit a prior timeout',
      () async {
        final s = makeSession('empty-${format.name}');
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          await req.drain<void>();
          req.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          req.response.write('data: [DONE]\n\n');
          await req.response.close();
        });
        final p = app.providerById(s.providerId)!;
        p.baseUrl = 'http://127.0.0.1:${server.port}/v1';
        p.apiFormat = format;
        AgentService.I.lastError =
            'stream error: TimeoutException: prior attempt';
        final result = await AgentService.I.callLlmOnceForTest(p, [], s);
        expect(result, isNull);
        expect(AgentService.I.lastError, startsWith('empty response'));
        expect(AgentService.I.lastError, isNot(contains('prior attempt')));
        p.apiFormat = ApiFormat.openai;
      },
    );
  }

  test(
    'OpenAI SSE provider error survives instead of becoming empty response',
    () async {
      final s = makeSession('stream-error');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        await req.drain<void>();
        req.response.headers.contentType = ContentType('text', 'event-stream');
        req.response.write(
          'data: {"error":{"message":"quota exhausted","code":"insufficient_quota"}}\n\n',
        );
        await req.response.close();
      });
      final p = app.providerById(s.providerId)!;
      p.baseUrl = 'http://127.0.0.1:${server.port}/v1';
      expect(await AgentService.I.callLlmOnceForTest(p, [], s), isNull);
      expect(AgentService.I.lastError, contains('quota exhausted'));
      expect(AgentService.I.lastError, isNot(contains('empty response')));
    },
  );

  test(
    'coordinate deltas are appended once and never copied from tool input',
    () async {
      final s = makeSession('coordinate-evidence');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        await req.drain<void>();
        req.response.headers.contentType = ContentType('text', 'event-stream');
        for (final content in ['(10,20) ', '(10,20) ', 'done']) {
          req.response.write(
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': content},
                },
              ],
            })}\n\n',
          );
        }
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
      });
      final p = app.providerById(s.providerId)!;
      p.baseUrl = 'http://127.0.0.1:${server.port}/v1';
      final result = await AgentService.I.callLlmOnceForTest(p, [
        {'role': 'tool', 'content': '[1] bounds=(99,98,97,96)'},
      ], s);
      expect(result!['content'], '(10,20) (10,20) done');
      expect(s.messages.last.content, '(10,20) (10,20) done');
    },
  );

  test(
    'native accessibility evidence has one four-coordinate rectangle per node',
    () {
      final output = DeviceControlService.formatReadResultForTest({
        'full': true,
        'status': 'ok',
        'package': 'example.app',
        'added': [
          {
            'handle': 1,
            'text': 'Button',
            'bounds': [10, 20, 30, 40],
          },
          {
            'handle': 2,
            'text': 'Container',
            'bounds': [10, 20, 30, 40],
          },
        ],
      });
      expect('bounds=(10,20,30,40)'.allMatches(output).length, 2);
      expect(
        output.split('\n').where((line) => line.contains('bounds=')).length,
        2,
      );
    },
  );

  test(
    'real idle timeout carries facts and only one recovery instruction',
    () async {
      final s = makeSession('idle-timeout');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final previousTimeout = app.responseTimeoutSec;
      app.responseTimeoutSec = 1;
      addTearDown(() => app.responseTimeoutSec = previousTimeout);
      server.listen((req) async {
        await req.drain<void>();
        req.response.headers.contentType = ContentType('text', 'event-stream');
        req.response.write(': heartbeat\n\n');
        await req.response.flush();
      });
      final p = app.providerById(s.providerId)!;
      p.baseUrl = 'http://127.0.0.1:${server.port}/v1';
      expect(await AgentService.I.callLlmOnceForTest(p, [], s), isNull);
      expect(AgentService.I.lastError, contains('idle for 1s'));
      expect(AgentService.I.lastError, isNot(contains('increase')));
    },
  );

  for (final format in [ApiFormat.openai, ApiFormat.anthropic]) {
    test(
      '${format.name} malformed SSE is identified without timeout diagnosis',
      () async {
        final s = makeSession('malformed-${format.name}');
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          await req.drain<void>();
          req.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          req.response.write('data: {broken-json}\n\ndata: [DONE]\n\n');
          await req.response.close();
        });
        final p = app.providerById(s.providerId)!;
        p.baseUrl = 'http://127.0.0.1:${server.port}/v1';
        p.apiFormat = format;
        expect(await AgentService.I.callLlmOnceForTest(p, [], s), isNull);
        expect(AgentService.I.lastError, startsWith('invalid model response'));
        expect(AgentService.I.lastError, contains('1 malformed'));
        p.apiFormat = ApiFormat.openai;
      },
    );
  }
}
