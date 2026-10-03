import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/prompt_framework.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Prompt extends NativePromptCapability {
  @override
  String get pluginName => 'Transport fixture';
  @override
  String get taskSystemPrompt => 'Answer the request.';
  @override
  List<NativePluginConfigField> get configFields => const [];
  @override
  List<NativePluginTool> get tools => const [];
  @override
  Future<void> configure(Map<String, String> values) async {}
  @override
  String buildPrompt(String toolName, Map<String, dynamic> args) =>
      args['prompt'] as String;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late AppState app;
  late ChatSession session;
  late ProviderConfig provider;
  final requests = <Map<String, dynamic>>[];
  final authorizations = <String?>[];

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app = AppState.createForTest();
    requests.clear();
    authorizations.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider = ProviderConfig(
      id: 'fixture-provider', name: 'Fixture', description: '',
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      apiKey: 'fixture-key', models: ['session-model', 'model-a', 'model-b'],
      selectedModel: 'session-model',
    );
    app.providers.add(provider);
    session = ChatSession(id: 'transport-fixture', title: 'Custom title',
        providerId: provider.id, model: 'session-model', mode: 'auto');
    app.sessions.add(session);
    app.activeSessionId = session.id;
    AgentService.I.runBucketForTest(session.id).modelSnapshot = 'old-run-model';
    server.listen((req) async {
      final body = jsonDecode(await utf8.decoder.bind(req).join())
          as Map<String, dynamic>;
      requests.add(body);
      authorizations.add(req.headers.value('authorization'));
      final text = 'answer:${body['model']}';
      req.response.headers.contentType = ContentType('text', 'event-stream');
      void send(Map<String, dynamic> event) =>
          req.response.write('data: ${jsonEncode(event)}\n\n');
      if (req.uri.path.endsWith('/messages')) {
        send({'type': 'message_start', 'message': {'id': 'msg-fixture',
          'type': 'message', 'role': 'assistant', 'model': body['model'],
          'content': [], 'usage': {'input_tokens': 12, 'output_tokens': 0}}});
        send({'type': 'content_block_start', 'index': 0,
          'content_block': {'type': 'text', 'text': ''}});
        send({'type': 'content_block_delta', 'index': 0,
          'delta': {'type': 'text_delta', 'text': text}});
        send({'type': 'content_block_stop', 'index': 0});
        send({'type': 'message_delta', 'delta': {'stop_reason': 'end_turn'},
          'usage': {'output_tokens': 3}});
        send({'type': 'message_stop'});
      } else {
        send({'id': 'chatcmpl-fixture', 'object': 'chat.completion.chunk',
          'model': body['model'], 'choices': [{'index': 0,
            'delta': {'role': 'assistant', 'content': text},
            'finish_reason': 'stop'}],
          'usage': {'prompt_tokens': 12, 'completion_tokens': 3,
            'total_tokens': 15}});
        req.response.write('data: [DONE]\n\n');
      }
      await req.response.close();
    });
  });

  tearDown(() async {
    AgentService.I.dropSessionRun(session.id);
    await server.close(force: true);
    AppState.resetTestInstance();
  });

  for (final format in [ApiFormat.openai, ApiFormat.anthropic]) {
    test('${format.name} prompt helper consumes normalized transport text', () async {
      provider.apiFormat = format;
      final result = await AgentService.I.runPromptTool(
          _Prompt(), 'answer', {'prompt': 'hello'});
      expect(result, 'answer:session-model');
      expect(requests.single['model'], 'session-model');
      expect(session.messages, isEmpty);
    });

    test('${format.name} fanout sends each requested model on the wire', () async {
      provider.apiFormat = format;
      final result = await AgentService.I.runPromptTool(_Prompt(), 'compare',
          {'prompt': 'FANOUT:model-a,model-b|hello'});
      expect(requests.map((r) => r['model']), ['model-a', 'model-b']);
      expect(result, '## model-a\nanswer:model-a\n\n## model-b\nanswer:model-b');
      expect(session.model, 'session-model');
      expect(provider.selectedModel, 'session-model');
      expect(AgentService.I.runBucketForTest(session.id).modelSnapshot,
          'old-run-model');
      expect(session.messages, isEmpty);
    });
  }

  test('ambiguous bare fanout model refuses to guess a provider', () async {
    app.providers.add(ProviderConfig(id: 'other-fixture', name: 'Other',
        description: '', baseUrl: provider.baseUrl, apiKey: 'other-key',
        models: ['model-a']));
    final result = await AgentService.I.runPromptTool(_Prompt(), 'compare',
        {'prompt': 'FANOUT:model-a|hello'});
    expect(requests, isEmpty);
    expect(result.toLowerCase(), contains('ambiguous'));
  });

  test('qualified fanout targets disambiguate identical model IDs', () async {
    app.providers.add(ProviderConfig(id: 'other-fixture', name: 'Other',
        description: '', baseUrl: provider.baseUrl, apiKey: 'other-key',
        models: ['model-a']));
    final result = await AgentService.I.runPromptTool(_Prompt(), 'compare',
        {'prompt': 'FANOUT:fixture-provider::model-a,other-fixture::model-a|hello'});
    expect(requests.map((r) => r['model']), ['model-a', 'model-a']);
    expect(authorizations, ['Bearer fixture-key', 'Bearer other-key']);
    expect(result, contains('## fixture-provider::model-a\nanswer:model-a'));
    expect(result, contains('## other-fixture::model-a\nanswer:model-a'));
  });
}
