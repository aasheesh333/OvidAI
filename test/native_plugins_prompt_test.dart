import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/prompt_dev.dart';
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

  // --- Task 2: writing/dev prompt plugins ---

  PluginItem installDevRow(String name) {
    final row = PluginItem(
      name: name,
      author: 'test',
      description: 'Dev prompt capability.',
      version: '1.0',
      category: 'Tool',
      installed: true,
      enabled: true,
    );
    AppState.I.plugins.add(row);
    return row;
  }

  Future<String> dispatchEcho(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    AgentService.promptLlmForTest = (p, msgs, sess) async => {
          'choices': [
            {
              'message': {
                'content':
                    'ECHO:${(msgs[1]['content'] as String).length}',
              },
            },
          ],
        };
    return AgentService.I.dispatchForTest(toolName, args);
  }

  List<String> requiredOf(NativePluginCapability cap, String tool) {
    final t = cap.tools.singleWhere((e) => e.name == tool);
    return (t.inputSchema['required'] as List).cast<String>();
  }

  test('README Writer prompt embeds bounded input, schema requires repo_name',
      () {
    final cap = ReadmeWriterCapability();
    expect(cap.pluginName, 'README Writer');
    expect(NativePluginRegistry.slugify(cap.pluginName), 'readme_writer');
    final prompt = cap.buildPrompt('generate', {
      'repo_name': 'my-repo',
      'files_summary': 'lib/main.dart entrypoint',
      'tone': 'friendly',
    });
    expect(prompt, contains('my-repo'));
    expect(prompt, contains('lib/main.dart entrypoint'));
    expect(prompt, contains('friendly'));
    expect(requiredOf(cap, 'generate'), contains('repo_name'));
  });

  test(
      'Changelog Gen prompt embeds bounded input, '
      'schema requires commits_text', () {
    final cap = ChangelogGenCapability();
    expect(cap.pluginName, 'Changelog Gen');
    expect(NativePluginRegistry.slugify(cap.pluginName), 'changelog_gen');
    final prompt = cap.buildPrompt('generate', {
      'commits_text': 'feat: add login\nfix: crash on start',
    });
    expect(prompt, contains('feat: add login'));
    expect(prompt, contains('fix: crash on start'));
    expect(requiredOf(cap, 'generate'), contains('commits_text'));
  });

  test('Commit Msg Helper prompt embeds bounded input, schema requires diff',
      () {
    final cap = CommitMsgHelperCapability();
    expect(cap.pluginName, 'Commit Msg Helper');
    expect(
      NativePluginRegistry.slugify(cap.pluginName),
      'commit_msg_helper',
    );
    final prompt = cap.buildPrompt('generate', {
      'diff': 'diff --git a/lib/main.dart b/lib/main.dart\n+void main() {}',
    });
    expect(prompt, contains('void main() {}'));
    expect(requiredOf(cap, 'generate'), contains('diff'));
  });

  test('Commit Msg Helper truncates long diffs with omission notice', () {
    final cap = CommitMsgHelperCapability();
    final longDiff = 'x' * 13000;
    final prompt = cap.buildPrompt('generate', {'diff': longDiff});
    expect(prompt, contains('characters omitted'));
    expect(prompt, contains('1000'));
  });

  test('Test Writer prompt embeds bounded input, schema requires code', () {
    final cap = TestWriterCapability();
    expect(cap.pluginName, 'Test Writer');
    expect(NativePluginRegistry.slugify(cap.pluginName), 'test_writer');
    final prompt = cap.buildPrompt('generate', {
      'code': 'int add(int a, int b) => a + b;',
      'framework': 'flutter_test',
    });
    expect(prompt, contains('int add(int a, int b) => a + b;'));
    expect(prompt, contains('flutter_test'));
    expect(requiredOf(cap, 'generate'), contains('code'));
  });

  test('Code Review AI prompt embeds bounded input, schema requires code',
      () {
    final cap = CodeReviewAiCapability();
    expect(cap.pluginName, 'Code Review AI');
    expect(NativePluginRegistry.slugify(cap.pluginName), 'code_review_ai');
    final prompt = cap.buildPrompt('review', {
      'code': 'void risky() { throw "x"; }',
      'focus': 'security',
    });
    expect(prompt, contains('void risky() { throw "x"; }'));
    expect(prompt, contains('security'));
    expect(requiredOf(cap, 'review'), contains('code'));
  });

  test('Git Diff Explain prompt embeds bounded input, schema requires diff',
      () {
    final cap = GitDiffExplainCapability();
    expect(cap.pluginName, 'Git Diff Explain');
    expect(
      NativePluginRegistry.slugify(cap.pluginName),
      'git_diff_explain',
    );
    final prompt = cap.buildPrompt('explain', {
      'diff': 'diff --git a/a.dart b/a.dart\n-old();\n+new();',
    });
    expect(prompt, contains('old();'));
    expect(prompt, contains('new();'));
    expect(requiredOf(cap, 'explain'), contains('diff'));
  });

  test('PR Reviewer prompt embeds bounded input, schema requires pr_diff',
      () {
    final cap = PrReviewerCapability();
    expect(cap.pluginName, 'PR Reviewer');
    expect(NativePluginRegistry.slugify(cap.pluginName), 'pr_reviewer');
    final prompt = cap.buildPrompt('review', {
      'pr_diff': 'diff --git a/b.dart b/b.dart\n+fix();',
      'checklist': 'tests, docs',
    });
    expect(prompt, contains('fix();'));
    expect(prompt, contains('tests, docs'));
    expect(requiredOf(cap, 'review'), contains('pr_diff'));
  });

  test(
      'Tailwind Helper prompt embeds bounded input, '
      'schema requires description', () {
    final cap = TailwindHelperCapability();
    expect(cap.pluginName, 'Tailwind Helper');
    expect(
      NativePluginRegistry.slugify(cap.pluginName),
      'tailwind_helper',
    );
    final prompt = cap.buildPrompt('generate', {
      'description': 'a centered card with shadow',
    });
    expect(prompt, contains('a centered card with shadow'));
    expect(requiredOf(cap, 'generate'), contains('description'));
  });

  test('README Writer end-to-end dispatch returns echo marker', () async {
    installSessionWithProvider('prompt-prov');
    registerPromptDev();
    installDevRow('README Writer');
    final out = await dispatchEcho(
      'plugin__readme_writer__generate',
      {'repo_name': 'my-repo'},
    );
    expect(out, contains('ECHO:'));
  });

  test('Changelog Gen end-to-end dispatch returns echo marker', () async {
    installSessionWithProvider('prompt-prov');
    registerPromptDev();
    installDevRow('Changelog Gen');
    final out = await dispatchEcho(
      'plugin__changelog_gen__generate',
      {'commits_text': 'feat: x'},
    );
    expect(out, contains('ECHO:'));
  });

  test('Commit Msg Helper end-to-end dispatch returns echo marker', () async {
    installSessionWithProvider('prompt-prov');
    registerPromptDev();
    installDevRow('Commit Msg Helper');
    final out = await dispatchEcho(
      'plugin__commit_msg_helper__generate',
      {'diff': 'diff --git a/f b/f\n+x;'},
    );
    expect(out, contains('ECHO:'));
  });

  test('Test Writer end-to-end dispatch returns echo marker', () async {
    installSessionWithProvider('prompt-prov');
    registerPromptDev();
    installDevRow('Test Writer');
    final out = await dispatchEcho(
      'plugin__test_writer__generate',
      {'code': 'int f() => 1;'},
    );
    expect(out, contains('ECHO:'));
  });

  test('Code Review AI end-to-end dispatch returns echo marker', () async {
    installSessionWithProvider('prompt-prov');
    registerPromptDev();
    installDevRow('Code Review AI');
    final out = await dispatchEcho(
      'plugin__code_review_ai__review',
      {'code': 'void f() {}'},
    );
    expect(out, contains('ECHO:'));
  });

  test('Git Diff Explain end-to-end dispatch returns echo marker', () async {
    installSessionWithProvider('prompt-prov');
    registerPromptDev();
    installDevRow('Git Diff Explain');
    final out = await dispatchEcho(
      'plugin__git_diff_explain__explain',
      {'diff': 'diff --git a/f b/f\n+x;'},
    );
    expect(out, contains('ECHO:'));
  });

  test('PR Reviewer end-to-end dispatch returns echo marker', () async {
    installSessionWithProvider('prompt-prov');
    registerPromptDev();
    installDevRow('PR Reviewer');
    final out = await dispatchEcho(
      'plugin__pr_reviewer__review',
      {'pr_diff': 'diff --git a/f b/f\n+x;'},
    );
    expect(out, contains('ECHO:'));
  });

  test('Tailwind Helper end-to-end dispatch returns echo marker', () async {
    installSessionWithProvider('prompt-prov');
    registerPromptDev();
    installDevRow('Tailwind Helper');
    final out = await dispatchEcho(
      'plugin__tailwind_helper__generate',
      {'description': 'a button'},
    );
    expect(out, contains('ECHO:'));
  });

  test('Commit Msg Helper generate without diff throws ArgumentError', () {
    expect(
      () => CommitMsgHelperCapability().buildPrompt('generate', {}),
      throwsArgumentError,
    );
    expect(
      () => CommitMsgHelperCapability().buildPrompt('generate', {'diff': ''}),
      throwsArgumentError,
    );
  });

  test('prompt dev capabilities reject unknown tools with ArgumentError', () {
    final caps = <NativePromptCapability>[
      ReadmeWriterCapability(),
      ChangelogGenCapability(),
      CommitMsgHelperCapability(),
      TestWriterCapability(),
      CodeReviewAiCapability(),
      GitDiffExplainCapability(),
      PrReviewerCapability(),
      TailwindHelperCapability(),
    ];
    for (final cap in caps) {
      expect(
        () => cap.buildPrompt('nope', {}),
        throwsArgumentError,
        reason: '${cap.pluginName} should reject unknown tool',
      );
      expect(cap.configFields, isEmpty);
      expect(cap.maxInputChars, 12000);
    }
  });

  test('registerPromptDev registers all eight writing/dev plugins', () {
    registerPromptDev();
    for (final name in [
      'README Writer',
      'Changelog Gen',
      'Commit Msg Helper',
      'Test Writer',
      'Code Review AI',
      'Git Diff Explain',
      'PR Reviewer',
      'Tailwind Helper',
    ]) {
      expect(
        NativePluginRegistry.I.has(name),
        isTrue,
        reason: '$name should be registered',
      );
    }
  });

  test('prompt dev configure no-ops and callTool defers to the agent',
      () async {
    final cap = ReadmeWriterCapability();
    await cap.configure({});
    final out = await cap.callTool('generate', {'repo_name': 'r'});
    expect(out, contains('through the agent'));
  });
}
