import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_adapters.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Production agent-hook wiring decision.
///
/// The tool-capable [AgentHookEvaluator] IS wired in `AgentService` (v2-22):
/// the closure audit's blockers were resolved by `_evaluateAgentHookQuietly`,
/// a bounded, cancellable, publication-free tool loop in which
///
/// * the evaluation runs detached in a Dart Zone carrying its own run
///   bucket, so `_dispatch` accounting, session-ledger entries and chat text
///   (`_emit`) never publish for an evaluation;
/// * interactive approvals fail safe (deny) instead of parking a card on the
///   active session's run bucket;
/// * per-evaluation cancellation is threaded through the evaluation's OWN
///   transport owner, sandbox process key and [UtilityCancellation] token.
///
/// These tests pin that wiring seam and its fail-open/quiet behaviour.
///
/// See `docs/superpowers/audits/2026-10-06-agent-hooks-closure.md` and
/// `docs/superpowers/audits/2026-10-06-partial-closure.md` §C.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final hooks = HookService.I;
  final registry = PluginContributionRegistry.I;
  final manifests = <NormalizedPluginManifest>[];
  late Directory temp;
  const sid = 'agent-hook-production-session';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    hooks.resetForTest();
    hooks.enabled = true;
    AppState.resetTestInstance();
    AppState.createForTest(pluginBootActivator: (_, _) async {});
    temp = Directory.systemTemp.createTempSync('agent-hook-production-');
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
        workspaceFolder: temp.path,
      ),
    );
    SessionLedger.rootOverrideForTest = Directory('${temp.path}/ledger')
      ..createSync();
  });

  tearDown(() async {
    for (final m in manifests) {
      registry.unregisterPlugin(m.id);
    }
    manifests.clear();
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

  Map<String, dynamic> agentHook(String prompt) => {
    'hooks': [
      {'type': 'agent', 'prompt': prompt, 'tools': ['bash']},
    ],
  };

  Future<NormalizedPluginManifest> agentHookFixture(String name) async {
    final root = Directory('${temp.path}/$name')..createSync();
    Directory('${root.path}/.claude-plugin').createSync();
    File('${root.path}/.claude-plugin/plugin.json').writeAsStringSync(
      jsonEncode({
        'name': name,
        'author': 'production',
        'version': '1',
        'hooks': {'Stop': agentHook('check the stop')},
      }),
    );
    final manifest = await const ClaudePluginAdapter().inspect(root);
    manifests.add(manifest);
    registry.register(manifest, activation: PluginActivation.globalActive);
    return manifest;
  }

  String ledgerText() => Directory('${temp.path}/ledger')
      .listSync()
      .whereType<File>()
      .map((f) => f.readAsStringSync())
      .join();

  test('production AgentService wires the tool-capable evaluator to the '
      'bounded quiet loop', () {
    final source = File('lib/core/agent_service.dart').readAsStringSync();
    expect(
      RegExp(
        r'agentHookEvaluator\s*=\s*_evaluateAgentHookQuietly',
      ).hasMatch(source),
      isTrue,
      reason:
          'Per-evaluation cancellation, detached approvals and a '
          'publication-free dispatch exist now, so the evaluator is wired — '
          'exclusively to the bounded, cancellable, quiet loop '
          '(2026-10-06-agent-hooks-closure.md).',
    );
  });

  test('the wired production evaluator fails open and stays quiet when it '
      'cannot decide', () async {
    await agentHookFixture('wired-fail-open');
    var promptCalls = 0;
    hooks.promptHookEvaluator = (_, _) async {
      promptCalls++;
      return '{"decision":"block"}';
    };
    // The production seam — the same assignment the AgentService constructor
    // performs. resetForTest deliberately does NOT clear agentHookEvaluator
    // (the constructor wires it once in production), so this test must
    // unwind its own wiring to keep the suite order-independent.
    AgentService.I.wireAgentHookEvaluatorForTest();
    addTearDown(() => hooks.agentHookEvaluator = null);
    final session = AppState.I.sessions.firstWhere((s) => s.id == sid);
    final before = session.messages.length;
    // No provider is configured for the fixture session, so the wired
    // evaluator cannot produce a verdict and must fail OPEN…
    final stop = await hooks.fireStop(sid).timeout(
      const Duration(seconds: 10),
    );
    expect(stop.stopAllowed, isTrue);
    // …without ever consulting the prompt evaluator…
    expect(promptCalls, 0);
    // …without the unwired-path ledger note (the evaluator WAS wired)…
    expect(ledgerText(), isNot(contains('AgentHookEvaluator unavailable')));
    // …and without publishing anything to the chat transcript.
    expect(session.messages.length, before);
  });

  test('production AgentService still wires the prompt evaluator', () {
    final source = File('lib/core/agent_service.dart').readAsStringSync();
    expect(
      RegExp(r'promptHookEvaluator\s*=').hasMatch(source),
      isTrue,
      reason: 'Prompt hooks are wired; agent hooks must never reuse them.',
    );
  });

  test('an agent hook fails open with a ledger note when no evaluator is wired',
      () async {
    await agentHookFixture('unwired');
    var promptCalls = 0;
    hooks.promptHookEvaluator = (_, _) async {
      promptCalls++;
      return '{"decision":"block"}';
    };
    final stop = await hooks.fireStop(sid);
    expect(stop.stopAllowed, isTrue);
    expect(promptCalls, 0);
    await SessionLedger.I.flush(sid);
    expect(ledgerText(), contains('AgentHookEvaluator'));
  });

  test('AgentHookEvaluation exposes a fence and an explicit cancel signal',
      () async {
    final fence = Completer<void>();
    final cancel = Completer<bool>();
    final evaluation = AgentHookEvaluation(
      prompt: 'p',
      context: const <String, dynamic>{},
      approvedTools: const {'bash'},
      budget: const Duration(seconds: 1),
      cancelled: fence.future,
      isCancelled: cancel.future,
    );
    expect(evaluation.cancelled, isNot(same(evaluation.isCancelled)));
    expect(evaluation.approvedTools, {'bash'});
    cancel.complete(true);
    expect(await evaluation.isCancelled, isTrue);
  });
}
