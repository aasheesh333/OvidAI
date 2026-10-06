import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/utility_limits.dart';
import 'package:ovid_ai/core/plugin_adapters.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/state.dart';

/// A native capability whose tool blocks until its cancellation token fires
/// — proves the per-evaluation token is threaded into callTool (Blocker B).
class _BlockingCapability implements NativePluginCapability {
  UtilityCancellation? cancellationSeen;
  void Function()? onEntered;

  @override
  String get pluginName => 'Eval Blocker';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
    NativePluginTool(
      name: 'slow_tool',
      description: 'blocks until cancelled',
      inputSchema: {'type': 'object', 'properties': <String, dynamic>{}},
    ),
  ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  Future<String> callTool(
    String toolName,
    Map<String, dynamic> args, {
    UtilityCancellation? cancellation,
  }) async {
    cancellationSeen = cancellation;
    onEntered?.call();
    await cancellation?.whenCancelled;
    return 'interrupted by cancellation';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final hooks = HookService.I;
  final registry = PluginContributionRegistry.I;
  final manifests = <NormalizedPluginManifest>[];
  late Directory temp;
  late Directory workspace;
  const sid = 'agent-hook-eval-session';

  Map<String, dynamic> llmToolCall(String name, Map<String, dynamic> args) => {
    'role': 'assistant',
    'content': '',
    'tool_calls': [
      {
        'id': 'c1',
        'function': {'name': name, 'arguments': jsonEncode(args)},
      },
    ],
  };

  Map<String, dynamic> llmVerdict(String json) => {
    'role': 'assistant',
    'content': json,
  };

  AgentHookEvaluation eval({
    String prompt = 'check the event',
    Set<String> tools = const {},
    String stdin = '{}',
    Completer<void>? fence,
    Completer<bool>? cancelSignal,
  }) {
    return AgentHookEvaluation(
      prompt: prompt,
      context: {
        'event': 'Stop',
        'session': sid,
        'plugin': 'fixture',
        'hook': 'h1',
        'stdin': stdin,
      },
      approvedTools: tools,
      budget: const Duration(seconds: 30),
      cancelled: (fence ?? Completer<void>()).future,
      isCancelled: (cancelSignal ?? Completer<bool>()).future,
    );
  }

  Future<NormalizedPluginManifest> fixture(
    String name,
    Map<String, dynamic> events,
  ) async {
    final root = Directory('${temp.path}/$name')..createSync();
    Directory('${root.path}/.claude-plugin').createSync();
    File('${root.path}/.claude-plugin/plugin.json').writeAsStringSync(
      jsonEncode({
        'name': name,
        'author': 'eval-test',
        'version': '1',
        'hooks': events,
      }),
    );
    final manifest = await const ClaudePluginAdapter().inspect(root);
    manifests.add(manifest);
    registry.register(manifest, activation: PluginActivation.globalActive);
    return manifest;
  }

  Map<String, dynamic> agentHook(String prompt, {List<Object>? tools}) => {
    'hooks': [
      {'type': 'agent', 'prompt': prompt, 'tools': ?tools},
    ],
  };

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    hooks.resetForTest();
    hooks.enabled = true;
    AppState.resetTestInstance();
    AppState.createForTest(pluginBootActivator: (_, _) async {});
    temp = Directory.systemTemp.createTempSync('agent-hook-eval-');
    workspace = Directory('${temp.path}/workspace')..createSync();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => temp.path,
        );
    AppState.I.sessions.add(
      ChatSession(
        id: sid,
        title: 'fixture',
        model: 'fixture',
        workspaceFolder: workspace.path,
      ),
    );
    AppState.I.activeSessionId = sid;
    final provider = AppState.I.providers.first;
    provider.apiKey = 'fixture-key';
    AppState.I.sessionById(sid)!.providerId = provider.id;
    SessionLedger.rootOverrideForTest = Directory('${temp.path}/ledger')
      ..createSync();
    // Fast retries + scripted LLM; the wiring seam is explicit so test order
    // cannot matter (the constructor wires it too, on first touch).
    AgentService.retryDelaysForTest = List.filled(4, Duration.zero);
    AgentService.llmOnceForTest = null;
    AgentService.I.wireAgentHookEvaluatorForTest();
  });

  tearDown(() async {
    AgentService.llmOnceForTest = null;
    AgentService.retryDelaysForTest = const [
      Duration(seconds: 3),
      Duration(seconds: 9),
      Duration(seconds: 27),
      Duration(seconds: 60),
    ];
    for (final m in manifests) {
      registry.unregisterPlugin(m.id);
    }
    manifests.clear();
    NativePluginRegistry.I.clearForTest();
    hooks.enabled = false;
    await hooks.fire('session_end', sid);
    await SessionLedger.I.close(sid);
    hooks.resetForTest();
    SessionLedger.rootOverrideForTest = null;
    AppState.resetTestInstance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await temp.delete(recursive: true);
  });

  String ledgerText() => Directory('${temp.path}/ledger')
      .listSync()
      .whereType<File>()
      .map((f) => f.readAsStringSync())
      .join();

  test('runs a tool loop for an agent hook and returns the verdict', () async {
    File('${workspace.path}/note.md').writeAsStringSync('hello');
    final calls = <List<Map<String, dynamic>>>[];
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      calls.add(msgs);
      if (calls.length == 1) {
        expect(includeTools, isTrue);
        return llmToolCall('fs_glob', {'pattern': '*.md'});
      }
      // The quiet tool result must feed the next request as a tool message.
      expect(msgs.last['role'], 'tool');
      expect(msgs.last['content'] as String, contains('note.md'));
      return llmVerdict(
        '{"decision":"approve","reason":"workspace inspected"}',
      );
    };
    final verdict = await AgentService.I.evaluateAgentHookForTest(
      eval(tools: {'fs_glob'}),
    );
    expect(verdict, isNotNull);
    expect(verdict!.decision, 'approve');
    expect(verdict.reason, 'workspace inspected');
    expect(calls.length, 2);
    // Declared-tools ∩ roster built the offered schemas.
    expect(AgentService.I.lastAgentHookEvalToolsForTest, ['fs_glob']);
  });

  test('honors allowedTools: undeclared tools are denied, never offered', () async {
    var calls = 0;
    String? firstToolResult;
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      calls++;
      if (calls == 1) {
        return llmToolCall('run_shell', {'command': 'echo hi'});
      }
      firstToolResult = msgs.last['content'] as String;
      return llmVerdict('{"decision":"block","reason":"cannot inspect"}');
    };
    final verdict = await AgentService.I.evaluateAgentHookForTest(
      eval(tools: {'fs_grep', 'not_a_real_tool'}),
    );
    expect(verdict, isNotNull);
    expect(verdict!.decision, 'block');
    expect(firstToolResult, contains('not one of this hook'));
    // Intersection: only the declared tool that exists in the roster is
    // offered; a declared-but-nonexistent tool never becomes a schema.
    expect(AgentService.I.lastAgentHookEvalToolsForTest, ['fs_grep']);
  });

  test('is quiet: no chat, no session-ledger tool entries, no run events', () async {
    File('${workspace.path}/quiet.md').writeAsStringSync('q');
    var calls = 0;
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      calls++;
      if (calls == 1) return llmToolCall('fs_glob', {'pattern': '*.md'});
      return llmVerdict('{"decision":"approve","reason":"done"}');
    };
    final session = AppState.I.sessionById(sid)!;
    final beforeMsgs = session.messages.length;
    final verdict = await AgentService.I.evaluateAgentHookForTest(
      eval(tools: {'fs_glob'}),
    );
    expect(verdict, isNotNull);
    expect(session.messages.length, beforeMsgs);
    // The ACTIVE session's run bucket was never touched: no run events, no
    // approval card, no parked state.
    expect(AgentService.I.events, isEmpty);
    expect(AgentService.I.pendingApproval, isNull);
    // No session-ledger tool accounting from the evaluation.
    await SessionLedger.I.flush(sid);
    expect(ledgerText(), isNot(contains('tool_start')));
    expect(ledgerText(), isNot(contains('tool_end')));
    expect(ledgerText(), isNot(contains('checkpoint')));
    expect(ledgerText(), isNot(contains('approval')));
  });

  test('cancels on isCancelled: the evaluation token reaches native callTool', () async {
    AppState.I.plugins.add(
      PluginItem(
        name: 'Eval Blocker',
        author: 'fixture',
        description: 'fixture',
        version: '1',
        category: 'Tool',
        installed: true,
        enabled: true,
      ),
    );
    final cap = _BlockingCapability();
    NativePluginRegistry.I.register(cap);
    final cancelSignal = Completer<bool>();
    final entered = Completer<void>();
    cap.onEntered = () {
      if (!entered.isCompleted) entered.complete();
    };
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      return llmToolCall('plugin__eval_blocker__slow_tool', {});
    };
    final pending = AgentService.I.evaluateAgentHookForTest(
      eval(
        tools: {'plugin__eval_blocker__slow_tool'},
        cancelSignal: cancelSignal,
      ),
    );
    await entered.future.timeout(const Duration(seconds: 5));
    // The token handed to callTool is the evaluation's OWN token — not a
    // session-keyed bridge token.
    expect(cap.cancellationSeen, isNotNull);
    expect(cap.cancellationSeen!.isCancelled, isFalse);
    cancelSignal.complete(true);
    final verdict = await pending.timeout(const Duration(seconds: 5));
    // Aborted → no verdict (HookService fails open on null).
    expect(verdict, isNull);
    expect(cap.cancellationSeen!.isCancelled, isTrue);
  });

  test('denies approval-gated tools instead of parking a detached card', () async {
    var calls = 0;
    String? denial;
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      calls++;
      if (calls == 1) return llmToolCall('run_shell', {'command': 'echo hi'});
      denial = msgs.last['content'] as String;
      return llmVerdict('{"decision":"approve","reason":"shell unavailable"}');
    };
    final verdict = await AgentService.I.evaluateAgentHookForTest(
      eval(tools: {'run_shell'}),
    );
    expect(verdict, isNotNull);
    expect(verdict!.decision, 'approve');
    expect(denial, startsWith('DENIED'));
    // Fail-safe: the denial never parked an approval anywhere — not on the
    // active session's bucket, not on the evaluation's detached bucket.
    expect(AgentService.I.pendingApproval, isNull);
    expect(AgentService.I.events, isEmpty);
  });

  test('wired evaluator decides a Stop hook through HookService', () async {
    await fixture('wired', {
      'Stop': agentHook('inspect before stopping', tools: ['fs_glob']),
    });
    var promptCalls = 0;
    hooks.promptHookEvaluator = (_, _) async {
      promptCalls++;
      return null;
    };
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      return llmVerdict('{"decision":"block","reason":"not done yet"}');
    };
    final stop = await hooks.fireStop(sid);
    expect(stop.stopAllowed, isFalse);
    expect(stop.vetoReason, 'not done yet');
    // Agent hooks never fall back to the prompt evaluator.
    expect(promptCalls, 0);
  });

  test('returns null (fail open) when the model never produces a verdict', () async {
    var calls = 0;
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      calls++;
      return llmToolCall('fs_glob', {'pattern': '*.md'});
    };
    final verdict = await AgentService.I.evaluateAgentHookForTest(
      eval(tools: {'fs_glob'}),
    );
    // Turn bound: 8 tool rounds, then fail open — never an infinite loop.
    expect(verdict, isNull);
    expect(calls, 9);
  });
}
