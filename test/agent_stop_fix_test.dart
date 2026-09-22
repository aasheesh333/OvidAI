import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

/// Stop/ownership + invisible-helper regression tests (Task 1):
///
/// 1. The title helper LLM call is invisible: the first answer plus the
///    fire-and-forget title generation must leave exactly ONE assistant
///    bubble in the transcript. This drives the REAL SSE transport (fake
///    HTTP layer) so `streamToTranscript: false` is genuinely exercised —
///    the `llmOnceForTest` override would bypass the streaming code and
///    could not catch the bug.
/// 2. Stop with a queued message promotes it immediately as a new run.
/// 3. Run ownership: when the old (stopped) run's `finally` unwinds AFTER
///    the promoted run was admitted, it must NOT clear `activeRunId` — the
///    promoted run still owns the bucket (otherwise the Stop button hides
///    mid-stream and a second concurrent run can slip in).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory ledgerDir;
  late AppState app;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ledgerDir = Directory.systemTemp.createTempSync('stop-fix-');
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
    HttpOverrides.global = null;
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
    HttpOverrides.global = null;
    AgentService.llmOnceForTest = null;
    AgentService.resetTitleStateForTest();
    AgentService.runRetryWaitForTest = null;
    AgentService.setRunSessionForTest('');
  });

  tearDownAll(() {
    AgentService.retryDelaysForTest = const [
      Duration(seconds: 3),
      Duration(seconds: 9),
      Duration(seconds: 27),
      Duration(seconds: 60),
    ];
  });

  /// Session whose provider is fully configured for the real transport.
  /// [customTitle] skips the title pass (like agent_double_response_test);
  /// leave it 'New chat' when the title helper itself is under test.
  ChatSession makeSession(String id, {String title = 'Custom title'}) {
    final provider = app.providerById('ollama-local')!;
    provider
      ..baseUrl = 'http://127.0.0.1:1/v1'
      ..models = ['test-model']
      ..selectedModel = 'test-model'
      ..apiKey = 'test-key';
    final s = ChatSession(
      id: id,
      title: title,
      providerId: provider.id,
      model: 'test-model',
      mode: 'auto',
    );
    app.sessions.add(s);
    app.activeSessionId = s.id;
    return s;
  }

  List<Message> assistantText(ChatSession s) => s.messages
      .where((m) => m.role == 'assistant' && m.kind == MsgKind.text)
      .toList();

  Future<void> pollUntil(
    bool Function() cond,
    String what, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!cond()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting for: $what');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  test('title helper LLM call leaves exactly one assistant bubble', () async {
    final s = makeSession('stopfix-title', title: 'New chat');
    // Real transport, fake HTTP: the main answer and the title helper
    // both stream through _callLlmOnce's SSE parser.
    HttpOverrides.global = _SseTestOverrides();

    await AgentService.I
        .runTask('hi', sessionId: s.id)
        .timeout(const Duration(seconds: 30));

    // The title pass is fire-and-forget at run end — wait for it.
    await pollUntil(
      () => s.titleGenerated,
      'the title helper to finish',
      timeout: const Duration(seconds: 10),
    );

    expect(s.title, 'My Test Title', reason: 'the helper must have run');
    final bubbles = assistantText(s);
    expect(
      bubbles.length,
      1,
      reason: 'first answer + title helper must yield exactly one bubble',
    );
    expect(bubbles.single.content, 'FIRST ANSWER');
    expect(
      s.messages.any(
        (m) => m.role == 'assistant' && m.content.contains('My Test Title'),
      ),
      isFalse,
      reason: 'the title must never leak into the transcript',
    );
  });

  test(
    'Stop with a queued message promotes it as a new run immediately',
    () async {
      final s = makeSession('stopfix-promote');
      final stopGate = Completer<void>();
      var attempt = 0;
      AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
        attempt++;
        if (attempt == 1) {
          // Run A: block until the test releases it (simulates a long turn).
          await stopGate.future;
          AgentService.I.lastError = 'stopped: api key revoked (test)';
          return null; // non-transient → no retry, the run unwinds
        }
        // Run B (the promoted continuation): answer right away. The
        // override bypasses transport streaming, so stream the answer into
        // the live bubble explicitly (the streamToBubbleForTest seam).
        AgentService.I.streamToBubbleForTest(session, 'SECOND ANSWER');
        return {
          'role': 'assistant',
          'content': 'SECOND ANSWER',
          'finish_reason': 'stop',
        };
      };

      final runA = AgentService.I.runTask('first', sessionId: s.id);
      // Wait until run A is admitted and blocked in the LLM call.
      await pollUntil(
        () => AgentService.I.activeRunId != null,
        'run A to be admitted',
      );

      // User sends while busy → queued; then hits Stop.
      AgentService.I.enqueueMessage('second', sessionId: s.id);
      final preserved = AgentService.I.stopRequested(sessionId: s.id);
      expect(preserved, isTrue, reason: 'the queue must survive the stop');

      // The promotion must NOT wait for run A to finish unwinding.
      await pollUntil(
        () =>
            s.messages.any((m) => m.role == 'user' && m.content == 'second') &&
            assistantText(s).any((m) => m.content == 'SECOND ANSWER'),
        'the promoted run to answer',
      );

      // Let run A finish unwinding, then await it.
      stopGate.complete();
      await runA.timeout(const Duration(seconds: 20));

      expect(
        s.messages
            .where((m) => m.role == 'user' && m.content == 'second')
            .length,
        1,
        reason: 'the queued message becomes a real user row exactly once',
      );
      expect(
        assistantText(s).where((m) => m.content == 'SECOND ANSWER').length,
        1,
      );
      expect(AgentService.I.runBucketForTest(s.id).queue, isEmpty);
    },
  );

  test(
    'old run finally does not steal activeRunId from the promoted run',
    () async {
      final s = makeSession('stopfix-ownership');
      final stopGate = Completer<void>();
      final runBRelease = Completer<void>();
      var attempt = 0;
      AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
        attempt++;
        if (attempt == 1) {
          await stopGate.future; // run A: long turn, stopped by the user
          AgentService.I.lastError = 'stopped: api key revoked (test)';
          return null;
        }
        await runBRelease.future; // run B: stays streaming while we assert
        // The override bypasses transport streaming — put the answer in the
        // live bubble explicitly (the streamToBubbleForTest seam).
        AgentService.I.streamToBubbleForTest(session, 'PROMOTED ANSWER');
        return {
          'role': 'assistant',
          'content': 'PROMOTED ANSWER',
          'finish_reason': 'stop',
        };
      };

      final runA = AgentService.I.runTask('first', sessionId: s.id);
      await pollUntil(
        () => AgentService.I.activeRunId != null,
        'run A to be admitted',
      );
      final runAId = AgentService.I.activeRunId!;

      AgentService.I.enqueueMessage('second', sessionId: s.id);
      AgentService.I.stopRequested(sessionId: s.id);

      // Wait until the promoted run B is admitted (new run id on the bucket).
      await pollUntil(
        () =>
            AgentService.I.activeRunId != null &&
            AgentService.I.activeRunId != runAId,
        'the promoted run to own activeRunId',
      );
      final runBId = AgentService.I.activeRunId!;
      expect(runBId, isNot(runAId));

      // Now let the OLD run's finally unwind — it must not clear the id
      // the promoted run owns.
      stopGate.complete();
      await runA.timeout(const Duration(seconds: 20));
      // Give the finally a chance to run its (buggy) clear.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(
        AgentService.I.activeRunId,
        runBId,
        reason:
            'after the old run unwound, the promoted run must still own activeRunId',
      );

      // And the owning run still clears it on its own normal end.
      runBRelease.complete();
      await pollUntil(
        () => AgentService.I.activeRunId == null,
        'run B to clear activeRunId on its own end',
      );
      expect(
        assistantText(s).any((m) => m.content == 'PROMOTED ANSWER'),
        isTrue,
      );
    },
  );
}

// ── Fake HTTP layer: canned OpenAI-style SSE through the real transport ──

String _ssePayload(String content) {
  final chunk = jsonEncode({
    'choices': [
      {
        'delta': {'content': content},
        'finish_reason': 'stop',
      },
    ],
  });
  return 'data: $chunk\n\ndata: [DONE]\n\n';
}

class _SseTestOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _SseTestClient();
}

class _SseTestClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  set connectionTimeout(Duration? v) {}

  @override
  Future<HttpClientRequest> postUrl(Uri url) async => _SseTestRequest();

  @override
  void close({bool force = false}) {}
}

class _SseTestRequest implements HttpClientRequest {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);

  final _SseTestHeaders _headers = _SseTestHeaders();
  final BytesBuilder _body = BytesBuilder();

  @override
  HttpHeaders get headers => _headers;

  @override
  void add(List<int> data) => _body.add(data);

  @override
  Future<HttpClientResponse> close() async {
    var isTitleCall = false;
    try {
      final body =
          jsonDecode(utf8.decode(_body.toBytes())) as Map<String, dynamic>;
      final messages = body['messages'] as List?;
      isTitleCall =
          messages?.any(
            (m) => (m as Map)['content'].toString().contains('3-6 word title'),
          ) ??
          false;
    } catch (_) {}
    final payload = _ssePayload(isTitleCall ? 'My Test Title' : 'FIRST ANSWER');
    return _SseTestResponse(Stream.value(utf8.encode(payload)));
  }
}

class _SseTestHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  set contentLength(int v) {}
}

class _SseTestResponse extends Stream<List<int>> implements HttpClientResponse {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);

  final Stream<List<int>> _inner;
  _SseTestResponse(this._inner);

  @override
  int get statusCode => 200;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _inner.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}
