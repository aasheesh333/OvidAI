import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => HttpOverrides.global = null);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I.debugPauseScheduleTimerForTest(true);
  });

  tearDown(() {
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  test('OpenAI Auto stream reports actual model and transport duration', () async {
    final server = await _serve((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await _sse(request, [
        {
          'id': '1',
          'model': 'gpt-4.1-mini',
          'choices': [
            {'delta': {'content': 'ok'}, 'finish_reason': null},
          ],
        },
        {
          'model': 'gpt-4.1-mini',
          'choices': [],
          'usage': {
            'prompt_tokens': 0,
            'completion_tokens': 0,
            'total_tokens': 0,
          },
        },
      ]);
    });
    addTearDown(server.close);

    final result = await _call(
      server,
      ProviderConfig(
        id: 'test-openai',
        name: 'Test OpenAI',
        description: '',
        baseUrl: 'http://${server.address.host}:${server.port}',
        models: ['auto'],
        selectedModel: 'auto',
        requiresApiKey: false,
      ),
      'auto',
    );

    expect(result?['reportedModel'], 'gpt-4.1-mini');
    expect(result?['requestedModel'], 'auto');
    expect((result?['usage'] as Map)['prompt_tokens'], 0);
    expect((result?['usage'] as Map)['completion_tokens'], 0);
    expect(result?['elapsedMs'], greaterThanOrEqualTo(20));
  });

  test('Anthropic message_start model is retained with missing usage fields', () async {
    final server = await _serve((request) async {
      await _sse(request, [
        {
          'type': 'message_start',
          'message': {
            'model': 'claude-3-5-sonnet-20241022',
            'usage': {'input_tokens': 7},
          },
        },
        {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': 'ok'},
        },
        {
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn'},
          'usage': {'output_tokens': 0},
        },
      ]);
    });
    addTearDown(server.close);

    final result = await _call(
      server,
      ProviderConfig(
        id: 'test-anthropic',
        name: 'Test Anthropic',
        description: '',
        baseUrl: 'http://${server.address.host}:${server.port}',
        models: ['auto'],
        selectedModel: 'auto',
        requiresApiKey: false,
        apiFormat: ApiFormat.anthropic,
      ),
      'auto',
    );

    expect(result?['reportedModel'], 'claude-3-5-sonnet-20241022');
    expect(result?['requestedModel'], 'auto');
    final usage = result?['usage'] as Map;
    expect(usage['prompt_tokens'], 7);
    expect(usage['completion_tokens'], 0);
    expect(usage['total_tokens'], 7);
  });
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

Future<void> _sse(HttpRequest request, List<Map<String, dynamic>> events) async {
  request.response.headers.contentType = ContentType('text', 'event-stream');
  request.response.headers.chunkedTransferEncoding = true;
  for (final event in events) {
    request.response.write('data: ${jsonEncode(event)}\n\n');
    await request.response.flush();
  }
  request.response.write('data: [DONE]\n\n');
  await request.response.close();
}

Future<Map<String, dynamic>?> _call(
  HttpServer server,
  ProviderConfig provider,
  String model,
) {
  final session = ChatSession(
    id: 'usage-test',
    title: 'Usage test',
    model: model,
    providerId: provider.id,
    messages: [Message(role: 'user', content: 'hello')],
  );
  return AgentService.I.callLlmOnceForTest(
    provider,
    [
      {'role': 'user', 'content': 'hello'},
    ],
    session,
    includeTools: false,
  );
}
