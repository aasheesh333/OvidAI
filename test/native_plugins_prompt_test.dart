import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/prompt_framework.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TestPromptCapability extends NativePromptCapability {
  @override
  String get pluginName => 'Test Prompt';

  @override
  String get taskSystemPrompt => 'You are a test helper.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'greet',
          description: 'Greet someone.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'name': {'type': 'string'},
            },
            'required': ['name'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {
    if (values.isNotEmpty) {
      throw ArgumentError(
        'Plugin "$pluginName" has no configurable settings.',
      );
    }
  }

  @override
  String buildPrompt(String toolName, Map<String, dynamic> args) {
    if (toolName != 'greet') throw ArgumentError('Unknown tool: $toolName');
    final name = args['name']?.toString() ?? 'world';
    return 'Greet $name warmly.';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestPromptCapability capability;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.createForTest();
    NativePluginRegistry.I.clearForTest();
    capability = TestPromptCapability();
    NativePluginRegistry.I.register(capability);
  });

  tearDown(() {
    NativePluginRegistry.I.clearForTest();
    AgentService.setRunSessionForTest('');
    AgentService.promptLlmForTest = null;
    AppState.resetTestInstance();
  });

  PluginItem installTestPromptRow() {
    final row = PluginItem(
      name: 'Test Prompt',
      author: 'test',
      description: 'Test prompt capability.',
      version: '1.0',
      category: 'Tool',
      installed: true,
      enabled: true,
    );
    AppState.I.plugins.add(row);
    return row;
  }

  ChatSession installSessionWithProvider(String providerId) {
    final app = AppState.I;
    app.providers.add(
      ProviderConfig(
        id: providerId,
        name: 'Prompt Test',
        description: '',
        baseUrl: 'https://example.test/v1',
        apiKey: 'test-key',
        models: const ['m'],
      ),
    );
    addTearDown(
      () => AppState.I.providers.removeWhere((p) => p.id == providerId),
    );
    final s = ChatSession(
      id: 'prompt-sess',
      title: 'Test',
      model: 'm',
      providerId: providerId,
      mode: 'auto',
    );
    app.sessions.insert(0, s);
    addTearDown(() => AppState.I.sessions.removeWhere((x) => x.id == s.id));
    app.activeSessionId = s.id;
    return s;
  }

  test('prompt capability advertises tools and refuses direct callTool',
      () async {
    expect(NativePluginRegistry.I.has('Test Prompt'), isTrue);
    expect(
      capability.tools.map((t) => t.name),
      contains('greet'),
    );
    final out = await capability.callTool('greet', {'name': 'Ada'});
    expect(out, contains('through the agent'));
  });

  test('runPromptTool returns model text via the override seam', () async {
    installSessionWithProvider('prompt-prov');
    installTestPromptRow();

    List<Map<String, dynamic>>? captured;
    AgentService.promptLlmForTest = (p, msgs, sess) async {
      captured = msgs;
      return {
        'choices': [
          {
            'message': {'content': 'HELLO'},
          },
        ],
      };
    };

    final out = await AgentService.I.dispatchForTest(
      'plugin__test_prompt__greet',
      {'name': 'Ada'},
    );
    expect(out, 'HELLO');
    expect(captured, isNotNull);
    expect(captured![0]['role'], 'system');
    expect(captured![0]['content'], capability.taskSystemPrompt);
  });

  test('runPromptTool is honest on null and empty results', () async {
    installSessionWithProvider('prompt-prov');
    installTestPromptRow();

    AgentService.promptLlmForTest = (p, msgs, sess) async => null;
    final nullOut = await AgentService.I.dispatchForTest(
      'plugin__test_prompt__greet',
      {'name': 'Ada'},
    );
    expect(nullOut, contains('Model call failed'));

    AgentService.promptLlmForTest = (p, msgs, sess) async => {
          'choices': [
            {
              'message': {'content': '   '},
            },
          ],
        };
    final emptyOut = await AgentService.I.dispatchForTest(
      'plugin__test_prompt__greet',
      {'name': 'Ada'},
    );
    expect(emptyOut, contains('no text'));
  });

  test('input bound truncates with exact omission notice', () {
    final long = 'x' * 13000;
    final bounded = boundInput(long);
    expect(bounded.length, lessThanOrEqualTo(12000 + 100));
    expect(bounded, contains('1000'));
    expect(bounded, contains('characters omitted'));
    expect(boundInput('short'), 'short');
  });
}
