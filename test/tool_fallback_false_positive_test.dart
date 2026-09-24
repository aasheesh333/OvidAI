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

/// Issue 8 — tool-calling fallback false positives.
///
/// 1. A 400 "reasoning_effort is not supported" (injected from a model label
///    like `deepseek-v4.1-flash · High`) must NOT disable tools: the field is
///    dropped and the request retried ONCE with tools intact.
/// 2. The tool-rejection heuristic is narrowed to tool-specific language —
///    a bare "not supported" (e.g. max_tokens) never disables tools.
/// 3. No request-time tool schema carries an empty `properties` object or
///    `additionalProperties` (gateways 400 on both).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory ledgerDir;
  late AppState app;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ledgerDir = Directory.systemTemp.createTempSync('tool-fallback-');
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

  setUp(() {
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
  });

  tearDown(() {
    HttpOverrides.global = null;
    AgentService.retryDelaysForTest = const [
      Duration(seconds: 3),
      Duration(seconds: 9),
      Duration(seconds: 27),
      Duration(seconds: 60),
    ];
    AgentService.setRunSessionForTest('');
  });

  ChatSession makeSession(String id, {String model = 'test-model · High'}) {
    final provider = app.providerById('ollama-local')!;
    provider
      ..baseUrl = 'http://127.0.0.1:1/v1'
      ..models = ['test-model']
      ..selectedModel = 'test-model';
    final s = ChatSession(
      id: id,
      title: 'Custom title', // prevents the fire-and-forget title LLM call
      providerId: provider.id,
      model: model,
      mode: 'auto',
    );
    app.sessions.add(s);
    app.activeSessionId = s.id;
    return s;
  }

  bool hasToolWarning(ChatSession s) => s.messages.any(
    (m) =>
        m.role == 'assistant' &&
        m.content.contains('does not support tool calling'),
  );

  List<Map<String, dynamic>> messages() => [
    {'role': 'user', 'content': 'hi'},
  ];

  test(
    '400 "reasoning_effort is not supported" retries WITHOUT the field and keeps tools',
    () async {
      final s = makeSession('re-1');
      final p = app.providerById('ollama-local')!;
      final fake = _ScriptedHttp(
        responses: [
          _ScriptedHttp.errorResponse(
            400,
            'reasoning_effort is not supported for this model',
          ),
          _ScriptedHttp.sseResponse('RECOVERED'),
        ],
      );
      HttpOverrides.global = _Overrides(fake);

      final r = await AgentService.I
          .callLlmOnceForTest(p, messages(), s)
          .timeout(const Duration(seconds: 20));

      expect(r, isNotNull);
      expect(r!['content'], contains('RECOVERED'));
      expect(fake.bodies.length, 2);

      // First attempt: effort injected, tools present.
      expect(fake.bodies[0]['reasoning_effort'], 'high');
      expect((fake.bodies[0]['tools'] as List).isNotEmpty, isTrue);

      // Retry: reasoning_effort dropped, tools STILL present.
      expect((fake.bodies[1] as Map).containsKey('reasoning_effort'), isFalse);
      expect((fake.bodies[1]['tools'] as List).isNotEmpty, isTrue);

      // No "tools disabled" warning banner was appended.
      expect(hasToolWarning(s), isFalse);
    },
  );

  test(
    '400 naming tools as unsupported still disables tools (true positive)',
    () async {
      final s = makeSession('re-2', model: 'test-model');
      final p = app.providerById('ollama-local')!;
      final fake = _ScriptedHttp(
        responses: [
          _ScriptedHttp.errorResponse(
            400,
            'tools are not supported for this model',
          ),
          _ScriptedHttp.sseResponse('ANSWER WITHOUT TOOLS'),
        ],
      );
      HttpOverrides.global = _Overrides(fake);

      final r = await AgentService.I
          .callLlmOnceForTest(p, messages(), s)
          .timeout(const Duration(seconds: 20));

      expect(r, isNotNull);
      expect(r!['content'], contains('ANSWER WITHOUT TOOLS'));
      expect(fake.bodies.length, 2);
      // First attempt carried tools; the fallback retry does not.
      expect((fake.bodies[0]['tools'] as List).isNotEmpty, isTrue);
      expect((fake.bodies[1] as Map).containsKey('tools'), isFalse);
      // And the visible warning banner IS appended for a real rejection.
      expect(hasToolWarning(s), isTrue);
    },
  );

  test(
    '400 "max_tokens is not supported" does not disable tools and does not retry tool-less',
    () async {
      final s = makeSession('re-3', model: 'test-model');
      final p = app.providerById('ollama-local')!;
      final fake = _ScriptedHttp(
        responses: [
          _ScriptedHttp.errorResponse(
            400,
            'max_tokens is not supported for this model',
          ),
        ],
      );
      HttpOverrides.global = _Overrides(fake);

      final r = await AgentService.I
          .callLlmOnceForTest(p, messages(), s)
          .timeout(const Duration(seconds: 20));

      // No retry at all — the narrow heuristic did not fire.
      expect(r, isNull);
      expect(fake.bodies.length, 1);
      expect(hasToolWarning(s), isFalse);
      expect(AgentService.I.lastError, contains('HTTP 400'));
    },
  );

  test('no request-time tool schema has empty properties/additionalProperties',
      () async {
    final s = ChatSession(
      id: 'schema-1',
      title: 't',
      providerId: 'ollama-local',
      model: 'm',
      mode: 'control', // device_* tools are hard-denied outside Control
    );
    app.sessions.add(s);
    app.activeSessionId = s.id;
    AgentService.setRunSessionForTest(s.id);
    addTearDown(() {
      AgentService.setRunSessionForTest('');
      app.activeSessionId = null;
      app.sessions.removeWhere((x) => x.id == s.id);
    });

    final tools = AgentService.I.toolsForTest();
    expect(tools.isNotEmpty, isTrue);
    var zeroArgCount = 0;
    for (final t in tools) {
      final fn = (t['function'] as Map).cast<String, dynamic>();
      final name = fn['name'] as String;
      final params = (fn['parameters'] as Map).cast<String, dynamic>();
      expect(
        params.containsKey('additionalProperties'),
        isFalse,
        reason: '$name sends additionalProperties',
      );
      if (params.containsKey('properties')) {
        expect(
          (params['properties'] as Map).isNotEmpty,
          isTrue,
          reason: '$name sends an empty properties object',
        );
      } else {
        zeroArgCount++;
        expect(params['type'], 'object');
      }
    }
    // Sanity: the roster really does contain zero-arg tools — the
    // normalization above is exercised, not vacuous.
    expect(zeroArgCount, greaterThan(0));

    // Same contract on the Anthropic conversion path.
    final anthropic = AgentService.I.anthropicToolsForTest(tools);
    expect(anthropic.length, tools.length);
    for (final t in anthropic) {
      final schema = (t['input_schema'] as Map).cast<String, dynamic>();
      expect(
        schema.containsKey('additionalProperties'),
        isFalse,
        reason: '${t['name']} sends additionalProperties',
      );
      if (schema.containsKey('properties')) {
        expect(
          (schema['properties'] as Map).isNotEmpty,
          isTrue,
          reason: '${t['name']} sends an empty properties object',
        );
      }
    }
  });
}

// ── Fake HTTP layer: scripted status/body sequence + request capture ──

class _Overrides extends HttpOverrides {
  _Overrides(this.fake);
  final _ScriptedHttp fake;

  @override
  HttpClient createHttpClient(SecurityContext? context) => fake;
}

class _ScriptedHttp implements HttpClient {
  _ScriptedHttp({required this.responses});

  final List<_FakeResponse> responses;
  final bodies = <Map<String, dynamic>>[];
  var _next = 0;

  static _FakeResponse errorResponse(int status, String message) =>
      _FakeResponse(
        status,
        utf8.encode(jsonEncode({'error': {'message': message}})),
      );

  static _FakeResponse sseResponse(String content) {
    final chunk = jsonEncode({
      'choices': [
        {
          'delta': {'content': content},
          'finish_reason': 'stop',
        },
      ],
    });
    return _FakeResponse(
      200,
      utf8.encode('data: $chunk\n\ndata: [DONE]\n\n'),
    );
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  set connectionTimeout(Duration? v) {}

  @override
  Future<HttpClientRequest> postUrl(Uri url) async =>
      _FakeRequest(this);

  @override
  void close({bool force = false}) {}
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.client);
  final _ScriptedHttp client;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);

  final _FakeHeaders _headers = _FakeHeaders();
  final BytesBuilder _body = BytesBuilder();

  @override
  HttpHeaders get headers => _headers;

  @override
  void add(List<int> data) => _body.add(data);

  @override
  Future<HttpClientResponse> close() async {
    final decoded =
        jsonDecode(utf8.decode(_body.toBytes())) as Map<String, dynamic>;
    client.bodies.add(decoded);
    final idx = client._next < client.responses.length
        ? client._next++
        : client.responses.length - 1;
    return client.responses[idx];
  }
}

class _FakeHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  set contentLength(int v) {}
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.statusCode, this.bytes);

  @override
  final int statusCode;
  final List<int> bytes;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}
