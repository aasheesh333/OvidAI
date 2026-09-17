import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/prompt_dev.dart';
import 'package:ovid_ai/core/native_plugins/prompt_framework.dart';
import 'package:ovid_ai/core/native_plugins/prompt_knowledge.dart';
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

class FanoutFourCapability extends NativePromptCapability {
  @override
  String get pluginName => 'Fanout Four';

  @override
  String get taskSystemPrompt => 'You are a test helper.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'compare',
          description: 'Compare.',
          inputSchema: {'type': 'object'},
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  String buildPrompt(String toolName, Map<String, dynamic> args) =>
      'FANOUT:a,b,c,d|hello';
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

  // --- Task 3: knowledge/productivity prompt plugins ---

  test('Translate Pro prompt embeds bounded input, schema requires text+target',
      () {
    final cap = TranslateProCapability();
    expect(cap.pluginName, 'Translate Pro');
    expect(NativePluginRegistry.slugify(cap.pluginName), 'translate_pro');
    final prompt = cap.buildPrompt('translate', {
      'text': 'Hello world',
      'target_lang': 'French',
      'source_lang': 'English',
    });
    expect(prompt, contains('Hello world'));
    expect(prompt, contains('French'));
    expect(prompt, contains('English'));
    expect(requiredOf(cap, 'translate'), containsAll(['text', 'target_lang']));
  });

  test('Study Mode flashcards prompt demands Q/A shape with count', () {
    final cap = StudyModeCapability();
    expect(cap.pluginName, 'Study Mode');
    expect(NativePluginRegistry.slugify(cap.pluginName), 'study_mode');
    final prompt = cap.buildPrompt('flashcards', {
      'text': 'Photosynthesis converts light to energy',
      'count': 3,
    });
    expect(prompt, contains('Photosynthesis converts light to energy'));
    expect(prompt, contains('3'));
    expect(prompt, contains('Q:'));
    expect(prompt, contains('A:'));
    expect(requiredOf(cap, 'flashcards'), contains('text'));
  });

  test('Study Mode quiz prompt demands MCQs with an answer key', () {
    final cap = StudyModeCapability();
    final prompt = cap.buildPrompt('quiz', {
      'text': 'The mitochondria is the powerhouse',
      'count': 2,
    });
    expect(prompt, contains('mitochondria'));
    expect(prompt, contains('2'));
    expect(prompt, contains('answer key'));
    expect(requiredOf(cap, 'quiz'), contains('text'));
  });

  test('Meeting Notes prompt embeds transcript, demands decisions+actions',
      () {
    final cap = MeetingNotesCapability();
    expect(cap.pluginName, 'Meeting Notes');
    expect(NativePluginRegistry.slugify(cap.pluginName), 'meeting_notes');
    final prompt = cap.buildPrompt('summarize', {
      'transcript': 'Ada: ship it Friday. Bo: I will own the rollout.',
    });
    expect(prompt, contains('ship it Friday'));
    expect(prompt, contains('decision'));
    expect(prompt, contains('action item'));
    expect(requiredOf(cap, 'summarize'), contains('transcript'));
  });

  test('Meeting Notes truncates long transcripts with omission notice', () {
    final cap = MeetingNotesCapability();
    final prompt = cap.buildPrompt('summarize', {'transcript': 'x' * 13000});
    expect(prompt, contains('characters omitted'));
  });

  test('Data Analyst stats correctness on a 3-column CSV fixture', () {
    final cap = DataAnalystCapability();
    expect(cap.pluginName, 'Data Analyst');
    expect(NativePluginRegistry.slugify(cap.pluginName), 'data_analyst');
    const csv = 'name,age,score\nalice,10,1.5\nbob,20,2.5';
    final prompt = cap.buildPrompt('analyze', {'csv_text': csv});
    expect(prompt, contains('name'));
    expect(prompt, contains('age'));
    expect(prompt, contains('score'));
    expect(prompt, contains('Rows: 2'));
    expect(prompt, contains('min 10'));
    expect(prompt, contains('max 20'));
    expect(prompt, contains('mean 15'));
    expect(prompt, contains('1.5'));
    expect(prompt, contains('2.5'));
    expect(requiredOf(cap, 'analyze'), contains('csv_text'));
  });

  test('Issue Triager prompt demands strict area/severity/priority/labels',
      () {
    final cap = IssueTriagerCapability();
    expect(cap.pluginName, 'Issue Triager');
    expect(NativePluginRegistry.slugify(cap.pluginName), 'issue_triager');
    final prompt = cap.buildPrompt('triage', {
      'title': 'Crash on launch',
      'body': 'App exits immediately on Android 14',
    });
    expect(prompt, contains('Crash on launch'));
    expect(prompt, contains('Android 14'));
    expect(prompt, contains('area:'));
    expect(prompt, contains('severity:'));
    expect(prompt, contains('priority:'));
    expect(prompt, contains('labels:'));
    expect(requiredOf(cap, 'triage'), contains('title'));
  });

  test('Release Notes prompt embeds PR list, demands highlights+upgrade notes',
      () {
    final cap = ReleaseNotesCapability();
    expect(cap.pluginName, 'Release Notes');
    expect(NativePluginRegistry.slugify(cap.pluginName), 'release_notes');
    final prompt = cap.buildPrompt('generate', {
      'pr_list': '#41 fix login crash\n#42 add dark mode',
    });
    expect(prompt, contains('#41 fix login crash'));
    expect(prompt, contains('#42 add dark mode'));
    expect(prompt.toLowerCase(), contains('upgrade'));
    expect(requiredOf(cap, 'generate'), contains('pr_list'));
  });

  test('Calendar parse_reminder demands strict JSON title/when_text', () {
    final cap = CalendarTasksCapability();
    expect(cap.pluginName, 'Calendar & Tasks');
    expect(NativePluginRegistry.slugify(cap.pluginName), 'calendar_tasks');
    final prompt = cap.buildPrompt('parse_reminder', {
      'text': 'Remind me to call mom tomorrow at 6pm',
    });
    expect(prompt, contains('call mom'));
    expect(prompt, contains('title'));
    expect(prompt, contains('when_text'));
    expect(prompt.toLowerCase(), contains('json'));
    expect(requiredOf(cap, 'parse_reminder'), contains('text'));
  });

  test('Calendar list_help returns static syntax help without arguments', () {
    final cap = CalendarTasksCapability();
    final prompt = cap.buildPrompt('list_help', {});
    expect(prompt.toLowerCase(), contains('reminder'));
    expect(prompt, contains('parse_reminder'));
  });

  test('Multi-Model Compare encodes a FANOUT envelope, rejects 4 models',
      () {
    final cap = MultiModelCompareCapability();
    expect(cap.pluginName, 'Multi-Model Compare');
    expect(
      NativePluginRegistry.slugify(cap.pluginName),
      'multi_model_compare',
    );
    final prompt = cap.buildPrompt('compare', {
      'prompt': 'Summarize X',
      'models': ['m-a', 'm-b'],
    });
    expect(prompt.startsWith('FANOUT:'), isTrue);
    expect(prompt, contains('m-a'));
    expect(prompt, contains('m-b'));
    expect(prompt, contains('Summarize X'));
    expect(requiredOf(cap, 'compare'), contains('prompt'));
    expect(
      () => cap.buildPrompt('compare', {
        'prompt': 'hi',
        'models': ['a', 'b', 'c', 'd'],
      }),
      throwsArgumentError,
    );
    expect(
      () => cap.buildPrompt('compare', {'prompt': '   '}),
      throwsArgumentError,
    );
  });

  test('Translate Pro end-to-end dispatch returns echo marker', () async {
    installSessionWithProvider('prompt-prov');
    registerPromptKnowledge();
    installDevRow('Translate Pro');
    final out = await dispatchEcho(
      'plugin__translate_pro__translate',
      {'text': 'Hello', 'target_lang': 'French'},
    );
    expect(out, contains('ECHO:'));
  });

  test('Study Mode flashcards end-to-end dispatch returns echo marker',
      () async {
    installSessionWithProvider('prompt-prov');
    registerPromptKnowledge();
    installDevRow('Study Mode');
    final out = await dispatchEcho(
      'plugin__study_mode__flashcards',
      {'text': 'Photosynthesis basics'},
    );
    expect(out, contains('ECHO:'));
  });

  test('Study Mode quiz end-to-end dispatch returns echo marker', () async {
    installSessionWithProvider('prompt-prov');
    registerPromptKnowledge();
    installDevRow('Study Mode');
    final out = await dispatchEcho(
      'plugin__study_mode__quiz',
      {'text': 'Mitochondria basics'},
    );
    expect(out, contains('ECHO:'));
  });

  test('Meeting Notes end-to-end dispatch returns echo marker', () async {
    installSessionWithProvider('prompt-prov');
    registerPromptKnowledge();
    installDevRow('Meeting Notes');
    final out = await dispatchEcho(
      'plugin__meeting_notes__summarize',
      {'transcript': 'Ada: ship it.'},
    );
    expect(out, contains('ECHO:'));
  });

  test('Data Analyst end-to-end dispatch returns echo marker', () async {
    installSessionWithProvider('prompt-prov');
    registerPromptKnowledge();
    installDevRow('Data Analyst');
    final out = await dispatchEcho(
      'plugin__data_analyst__analyze',
      {'csv_text': 'a,b\n1,2\n3,4'},
    );
    expect(out, contains('ECHO:'));
  });

  test('Issue Triager end-to-end dispatch returns echo marker', () async {
    installSessionWithProvider('prompt-prov');
    registerPromptKnowledge();
    installDevRow('Issue Triager');
    final out = await dispatchEcho(
      'plugin__issue_triager__triage',
      {'title': 'Crash on launch'},
    );
    expect(out, contains('ECHO:'));
  });

  test('Release Notes end-to-end dispatch returns echo marker', () async {
    installSessionWithProvider('prompt-prov');
    registerPromptKnowledge();
    installDevRow('Release Notes');
    final out = await dispatchEcho(
      'plugin__release_notes__generate',
      {'pr_list': '#1 fix x'},
    );
    expect(out, contains('ECHO:'));
  });

  test('Calendar parse_reminder end-to-end dispatch returns echo marker',
      () async {
    installSessionWithProvider('prompt-prov');
    registerPromptKnowledge();
    installDevRow('Calendar & Tasks');
    final out = await dispatchEcho(
      'plugin__calendar_tasks__parse_reminder',
      {'text': 'Call mom tomorrow'},
    );
    expect(out, contains('ECHO:'));
  });

  test('Calendar list_help end-to-end dispatch returns echo marker', () async {
    installSessionWithProvider('prompt-prov');
    registerPromptKnowledge();
    installDevRow('Calendar & Tasks');
    final out = await dispatchEcho(
      'plugin__calendar_tasks__list_help',
      {},
    );
    expect(out, contains('ECHO:'));
  });

  test('Multi-Model Compare end-to-end dispatch returns echo marker',
      () async {
    installSessionWithProvider('prompt-prov');
    registerPromptKnowledge();
    installDevRow('Multi-Model Compare');
    final out = await dispatchEcho(
      'plugin__multi_model_compare__compare',
      {
        'prompt': 'Summarize X',
        'models': ['prompt-prov'],
      },
    );
    expect(out, contains('ECHO:'));
  });

  test('compare fan-out calls each model once with labeled sections',
      () async {
    installSessionWithProvider('cmp-a');
    installSessionWithProvider('cmp-b');
    registerPromptKnowledge();
    installDevRow('Multi-Model Compare');
    final calls = <String>[];
    AgentService.promptLlmForTest = (p, msgs, sess) async {
      calls.add(p.id);
      return {
        'choices': [
          {
            'message': {'content': 'ANS-${p.id}'},
          },
        ],
      };
    };
    final out = await AgentService.I.dispatchForTest(
      'plugin__multi_model_compare__compare',
      {
        'prompt': 'Summarize X',
        'models': ['cmp-a', 'cmp-b'],
      },
    );
    expect(calls, ['cmp-a', 'cmp-b']);
    expect(out, contains('## cmp-a'));
    expect(out, contains('## cmp-b'));
    expect(out, contains('ANS-cmp-a'));
    expect(out, contains('ANS-cmp-b'));
  });

  test('compare fan-out without models falls back to the session provider',
      () async {
    installSessionWithProvider('prompt-prov');
    registerPromptKnowledge();
    installDevRow('Multi-Model Compare');
    final calls = <String>[];
    AgentService.promptLlmForTest = (p, msgs, sess) async {
      calls.add(p.id);
      return {
        'choices': [
          {
            'message': {'content': 'SOLO'},
          },
        ],
      };
    };
    final out = await AgentService.I.dispatchForTest(
      'plugin__multi_model_compare__compare',
      {'prompt': 'Summarize X'},
    );
    expect(calls, ['prompt-prov']);
    expect(out, contains('## prompt-prov'));
    expect(out, contains('SOLO'));
  });

  test('compare fan-out keeps one section on per-model failure', () async {
    installSessionWithProvider('cmp-a');
    installSessionWithProvider('cmp-b');
    registerPromptKnowledge();
    installDevRow('Multi-Model Compare');
    AgentService.promptLlmForTest = (p, msgs, sess) async {
      if (p.id == 'cmp-b') return null;
      return {
        'choices': [
          {
            'message': {'content': 'OK-A'},
          },
        ],
      };
    };
    final out = await AgentService.I.dispatchForTest(
      'plugin__multi_model_compare__compare',
      {
        'prompt': 'Summarize X',
        'models': ['cmp-a', 'cmp-b'],
      },
    );
    expect(out, contains('## cmp-a'));
    expect(out, contains('OK-A'));
    expect(out, contains('## cmp-b'));
    expect(out, contains('Model call failed'));
  });

  test('compare fan-out reports a shortfall line for unknown models',
      () async {
    installSessionWithProvider('cmp-a');
    registerPromptKnowledge();
    installDevRow('Multi-Model Compare');
    AgentService.promptLlmForTest = (p, msgs, sess) async => {
          'choices': [
            {
              'message': {'content': 'OK-A'},
            },
          ],
        };
    final out = await AgentService.I.dispatchForTest(
      'plugin__multi_model_compare__compare',
      {
        'prompt': 'Summarize X',
        'models': ['cmp-a', 'ghost-x'],
      },
    );
    expect(out, contains('## cmp-a'));
    expect(out, contains('OK-A'));
    expect(out, contains('## ghost-x'));
    expect(out, contains('No configured provider'));
  });

  test('compare fan-out rejects more than 3 models agent-side', () async {
    installSessionWithProvider('prompt-prov');
    NativePluginRegistry.I.register(FanoutFourCapability());
    installDevRow('Fanout Four');
    var called = false;
    AgentService.promptLlmForTest = (p, msgs, sess) async {
      called = true;
      return {
        'choices': [
          {
            'message': {'content': 'SHOULD NOT HAPPEN'},
          },
        ],
      };
    };
    final out = await AgentService.I.dispatchForTest(
      'plugin__fanout_four__compare',
      {},
    );
    expect(called, isFalse);
    expect(out, contains('at most 3'));
  });

  test('prompt knowledge capabilities reject unknown tools with ArgumentError',
      () {
    final caps = <NativePromptCapability>[
      TranslateProCapability(),
      StudyModeCapability(),
      MeetingNotesCapability(),
      DataAnalystCapability(),
      IssueTriagerCapability(),
      ReleaseNotesCapability(),
      CalendarTasksCapability(),
      MultiModelCompareCapability(),
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

  test('knowledge plugins reject blank required args with ArgumentError', () {
    expect(
      () => TranslateProCapability().buildPrompt('translate', {
        'text': '',
        'target_lang': 'French',
      }),
      throwsArgumentError,
    );
    expect(
      () => MeetingNotesCapability().buildPrompt('summarize', {}),
      throwsArgumentError,
    );
    expect(
      () => DataAnalystCapability().buildPrompt('analyze', {'csv_text': ''}),
      throwsArgumentError,
    );
    expect(
      () => IssueTriagerCapability().buildPrompt('triage', {'title': '  '}),
      throwsArgumentError,
    );
    expect(
      () => ReleaseNotesCapability().buildPrompt('generate', {}),
      throwsArgumentError,
    );
    expect(
      () => CalendarTasksCapability().buildPrompt('parse_reminder', {}),
      throwsArgumentError,
    );
  });

  test('registerPromptKnowledge registers all eight knowledge plugins', () {
    registerPromptKnowledge();
    for (final name in [
      'Translate Pro',
      'Study Mode',
      'Meeting Notes',
      'Data Analyst',
      'Issue Triager',
      'Release Notes',
      'Calendar & Tasks',
      'Multi-Model Compare',
    ]) {
      expect(
        NativePluginRegistry.I.has(name),
        isTrue,
        reason: '$name should be registered',
      );
    }
  });

  test('prompt knowledge configure no-ops and callTool defers to the agent',
      () async {
    final cap = TranslateProCapability();
    await cap.configure({});
    final out = await cap.callTool('translate', {
      'text': 'hi',
      'target_lang': 'French',
    });
    expect(out, contains('through the agent'));
  });

  // --- Task 4: registration wiring + roster halves (NP1 Task-3 pattern) ---

  test('registerAllNativePlugins wires all sixteen prompt plugins', () {
    registerPromptDev();
    registerPromptKnowledge();
    const allSixteen = [
      'README Writer',
      'Changelog Gen',
      'Commit Msg Helper',
      'Test Writer',
      'Code Review AI',
      'Git Diff Explain',
      'PR Reviewer',
      'Tailwind Helper',
      'Translate Pro',
      'Study Mode',
      'Meeting Notes',
      'Data Analyst',
      'Issue Triager',
      'Release Notes',
      'Calendar & Tasks',
      'Multi-Model Compare',
    ];
    for (final name in allSixteen) {
      expect(
        NativePluginRegistry.I.has(name),
        isTrue,
        reason: '$name should be registered',
      );
    }
    // Wiring truth: the app boot path registers all sixteen too.
    NativePluginRegistry.I.clearForTest();
    registerAllNativePlugins();
    for (final name in allSixteen) {
      expect(
        NativePluginRegistry.I.has(name),
        isTrue,
        reason: '$name should be wired via registerAllNativePlugins',
      );
    }
    // Roster truth (NP1 Task-3 pattern): an installed+enabled dev row
    // advertises plugin__readme_writer__generate; disabled it does not.
    List<String> rosterNames() => AgentService.I.toolsForTest()
        .map((t) => ((t['function'] as Map)['name']).toString())
        .toList();
    final devRow =
        AppState.I.plugins.firstWhere((p) => p.name == 'README Writer');
    final devInstalled = devRow.installed;
    final devEnabled = devRow.enabled;
    addTearDown(() {
      devRow.installed = devInstalled;
      devRow.enabled = devEnabled;
    });
    devRow.installed = true;
    devRow.enabled = true;
    expect(rosterNames(), contains('plugin__readme_writer__generate'));
    expect(
      AgentService.I.pluginToolNames(devRow),
      contains('plugin__readme_writer__generate'),
    );
    devRow.enabled = false;
    expect(
      rosterNames(),
      isNot(contains('plugin__readme_writer__generate')),
    );
    expect(AgentService.I.pluginToolNames(devRow), isEmpty);
    // Roster truth (NP1 Task-3 pattern): an installed+enabled knowledge row
    // advertises plugin__translate_pro__translate; disabled it does not.
    final knowRow =
        AppState.I.plugins.firstWhere((p) => p.name == 'Translate Pro');
    final knowInstalled = knowRow.installed;
    final knowEnabled = knowRow.enabled;
    addTearDown(() {
      knowRow.installed = knowInstalled;
      knowRow.enabled = knowEnabled;
    });
    knowRow.installed = true;
    knowRow.enabled = true;
    expect(rosterNames(), contains('plugin__translate_pro__translate'));
    expect(
      AgentService.I.pluginToolNames(knowRow),
      contains('plugin__translate_pro__translate'),
    );
    knowRow.enabled = false;
    expect(
      rosterNames(),
      isNot(contains('plugin__translate_pro__translate')),
    );
    expect(AgentService.I.pluginToolNames(knowRow), isEmpty);
  });
}
