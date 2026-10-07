import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_adapters.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/plugin_runtime.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final hooks = HookService.I;
  final registry = PluginContributionRegistry.I;
  final manifests = <NormalizedPluginManifest>[];
  late Directory temp;
  const sid = 'wave2-hooks-agent-session';

  Future<NormalizedPluginManifest> fixture(
    String name,
    Map<String, dynamic> events,
  ) async {
    final root = Directory('${temp.path}/$name')..createSync();
    Directory('${root.path}/.claude-plugin').createSync();
    File('${root.path}/.claude-plugin/plugin.json').writeAsStringSync(jsonEncode({
      'name': name,
      'author': 'wave2',
      'version': '1',
      'hooks': events,
    }));
    final manifest = await const ClaudePluginAdapter().inspect(root);
    manifests.add(manifest);
    registry.register(manifest, activation: PluginActivation.globalActive);
    return manifest;
  }

  void replace(NormalizedPluginManifest manifest) {
    registry.unregisterPlugin(manifest.id);
    registry.register(manifest, activation: PluginActivation.globalActive);
  }

  Map<String, dynamic> agentHook(String prompt, {List<Object>? tools, int? timeout}) => {
    'hooks': [
      {
        'type': 'agent',
        'prompt': prompt,
        'tools': ?tools,
        'timeout': ?timeout,
      },
    ],
  };

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    hooks.resetForTest();
    hooks.enabled = true;
    AppState.resetTestInstance();
    AppState.createForTest(pluginBootActivator: (_, _) async {});
    temp = Directory.systemTemp.createTempSync('wave2-agent-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => temp.path);
    AppState.I.sessions.add(ChatSession(
      id: sid, title: 'fixture', model: 'fixture', workspaceFolder: temp.path,
    ));
    SessionLedger.rootOverrideForTest = Directory('${temp.path}/ledger')..createSync();
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
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
    await temp.delete(recursive: true);
  });

  String ledgerText() => Directory('${temp.path}/ledger')
      .listSync()
      .whereType<File>()
      .map((f) => f.readAsStringSync())
      .join();

  test('adapter registers agent hooks with a visible evaluator requirement', () async {
    final m = await fixture('declared', {'Stop': agentHook('use tools')});
    final hook = m.hooks.single;
    expect(hook.type, 'agent');
    expect(hook.payload, 'use tools');
    expect(
      m.compatibility.where((i) => i.message.contains('evaluator')).length,
      1,
    );
  });

  test('unwired agent evaluator fails open with a ledger note and never calls the prompt evaluator', () async {
    await fixture('unwired', {
      'Stop': agentHook('check'),
      'Notification': agentHook('observe'),
    });
    var promptCalls = 0;
    hooks.promptHookEvaluator = (_, _) async {
      promptCalls++;
      return '{"decision":"block"}';
    };
    expect((await hooks.fireStop(sid)).stopAllowed, isTrue);
    expect(await hooks.fire('Notification', sid), isEmpty);
    expect(promptCalls, 0);
    expect(ledgerText(), contains('AgentHookEvaluator'));
  });

  test('production wiring keeps the tool-capable evaluator honestly unassigned', () {
    final source = File('lib/core/agent_service.dart').readAsStringSync();
    expect(
      RegExp(r'agentHookEvaluator\s*=').hasMatch(source),
      isFalse,
      reason:
          'AgentService must not wire the tool-capable evaluator until '
          'per-evaluation cancellation, detached approvals and publication-free '
          'dispatch exist (docs/superpowers/audits/2026-10-06-agent-hooks-closure.md).',
    );
    expect(
      RegExp(r'promptHookEvaluator\s*=').hasMatch(source),
      isTrue,
      reason: 'prompt hooks are wired; agent hooks must never reuse them.',
    );
  });

  test('agent verdicts decide gates and stops without the prompt evaluator', () async {
    await fixture('decide', {
      'PreToolUse': agentHook('guard'),
      'Stop': agentHook('halt'),
    });
    var promptCalls = 0;
    hooks.promptHookEvaluator = (_, _) async {
      promptCalls++;
      return '{"decision":"block"}';
    };
    hooks.agentHookEvaluator = (e) async =>
        e.prompt.contains('guard') ? AgentHookVerdict.block('no tools') : AgentHookVerdict.approve();
    final gate = await hooks.fireGate('PreToolUse', sid);
    expect(gate.decision, HookDecision.deny);
    expect(gate.reason, 'no tools');
    final stop = await hooks.fireStop(sid);
    expect(stop.stopAllowed, isTrue);
    expect(promptCalls, 0);
  });

  test('agent block on an observe event surfaces as a prompt block reason', () async {
    await fixture('observe', {'UserPromptSubmit': agentHook('review')});
    hooks.agentHookEvaluator = (_) async => AgentHookVerdict.block('needs edit');
    final result = await hooks.fireDetailed('UserPromptSubmit', sid, payload: {'prompt': 'hi'});
    expect(result.promptBlockReason, 'needs edit');
  });

  test('agent verdict reason is publication-scrubbed while the decision stays operational', () async {
    const secret = 'agent-fixture-secret';
    await fixture('scrub', {'Stop': agentHook('check')});
    hooks.agentHookEvaluator = (_) async => AgentHookVerdict.block('denied for $secret');
    final stop = await hooks.fireStop(sid, payload: {'token': secret});
    expect(stop.stopAllowed, isFalse);
    expect(stop.vetoReason, isNot(contains(secret)));
    await SessionLedger.I.close(sid);
    expect(ledgerText(), isNot(contains(secret)));
  });

  test('agent tool scope is bounded by the hook declaration', () async {
    await fixture('scope', {
      'Stop': agentHook('scoped', tools: [
        'bash',
        'Bash!',
        42,
        'x' * 100,
        'ok_tool',
      ]),
      'PreToolUse': agentHook('unscoped'),
    });
    final scopes = <String, Set<String>>{};
    hooks.agentHookEvaluator = (e) async {
      scopes[e.prompt] = e.approvedTools;
      return AgentHookVerdict.approve();
    };
    await hooks.fireStop(sid);
    await hooks.fireGate('PreToolUse', sid);
    expect(scopes['scoped'], {'bash', 'ok_tool'});
    expect(scopes['unscoped'], isEmpty);
  });

  test('late agent verdict after same-object replacement is dropped and cancellation is signalled', () async {
    final m = await fixture('aba', {'Stop': agentHook('check')});
    final entered = Completer<void>();
    final release = Completer<AgentHookVerdict?>();
    Completer<void>? cancelled;
    hooks.agentHookEvaluator = (e) {
      cancelled = Completer<void>();
      e.cancelled.then((_) {
        if (!cancelled!.isCompleted) cancelled!.complete();
      });
      entered.complete();
      return release.future;
    };
    final pending = hooks.fireStop(sid);
    await entered.future;
    replace(m);
    await cancelled!.future.timeout(const Duration(seconds: 2));
    final res = await pending.timeout(const Duration(seconds: 2));
    expect(res.stopAllowed, isTrue);
    release.complete(AgentHookVerdict.block('late'));
    await Future<void>.delayed(Duration.zero);
    expect(hooks.isPluginTripped(m.id, sid), isFalse);
  });

  test('runtime uninstall cancels an in-flight agent evaluation and fences its verdict', () async {
    final m = await fixture('runtime', {'Stop': agentHook('check')});
    final entered = Completer<void>();
    final release = Completer<AgentHookVerdict?>();
    Future<void>? cancelled;
    hooks.agentHookEvaluator = (e) {
      cancelled = e.cancelled;
      entered.complete();
      return release.future;
    };
    final pending = hooks.fireStop(sid);
    await entered.future;
    final uninstall = PluginRuntimeManager.I.uninstall(m.id);
    try {
      expect(registry.isPluginActiveForSession(m.id, sid), isFalse);
      await cancelled!.timeout(const Duration(seconds: 2));
      final res = await pending.timeout(const Duration(seconds: 2));
      expect(res.stopAllowed, isTrue);
    } finally {
      release.complete(AgentHookVerdict.block('late'));
      await uninstall;
    }
    await Future<void>.delayed(Duration.zero);
    expect(hooks.isPluginTripped(m.id, sid), isFalse);
  });

  test('agent evaluation timeout fails open within the declared bound and signals cancellation', () async {
    await fixture('timeout', {'Stop': agentHook('slow', timeout: 1)});
    Future<void>? cancelled;
    hooks.agentHookEvaluator = (e) {
      cancelled = e.cancelled;
      return Completer<AgentHookVerdict?>().future;
    };
    final clock = Stopwatch()..start();
    final res = await hooks.fireStop(sid);
    expect(res.stopAllowed, isTrue);
    // The hook declares a 1s timeout; fail-open must occur near that bound, not
    // hang. Wall-clock is generous because a loaded suite (many isolates) can
    // stretch the timeout path well past 3s — the ledger + cancellation checks
    // below prove the timeout actually fired.
    expect(clock.elapsedMilliseconds, lessThan(15000));
    await cancelled!.timeout(const Duration(seconds: 1));
    await SessionLedger.I.flush(sid);
    expect(ledgerText(), contains('AgentHookEvaluator'));
  });

  test('master disable cancels agent evaluation immediately', () async {
    await fixture('disable', {'Stop': agentHook('check')});
    final entered = Completer<void>();
    final release = Completer<AgentHookVerdict?>();
    Future<void>? cancelled;
    hooks.agentHookEvaluator = (e) {
      cancelled = e.cancelled;
      entered.complete();
      return release.future;
    };
    final pending = hooks.fireStop(sid);
    await entered.future;
    await hooks.setEnabled(false);
    await cancelled!.timeout(const Duration(seconds: 2));
    release.complete(AgentHookVerdict.block('late'));
    final res = await pending.timeout(const Duration(seconds: 2));
    expect(res.stopAllowed, isTrue);
  });

  test('explicit isCancelled signal stays false when the evaluator settles on time', () async {
    await fixture('signal-ok', {'Stop': agentHook('check')});
    Future<bool>? signal;
    hooks.agentHookEvaluator = (e) async {
      signal = e.isCancelled;
      return AgentHookVerdict.approve('done');
    };
    final stop = await hooks.fireStop(sid);
    expect(stop.stopAllowed, isTrue);
    expect(await signal!.timeout(const Duration(seconds: 2)), isFalse);
  });

  test('explicit isCancelled signal completes true on a same-object fence', () async {
    final m = await fixture('signal-fence', {'Stop': agentHook('check')});
    final entered = Completer<void>();
    final release = Completer<AgentHookVerdict?>();
    Future<bool>? signal;
    hooks.agentHookEvaluator = (e) {
      signal = e.isCancelled;
      entered.complete();
      return release.future;
    };
    final pending = hooks.fireStop(sid);
    await entered.future;
    replace(m);
    expect(await signal!.timeout(const Duration(seconds: 2)), isTrue);
    release.complete(AgentHookVerdict.block('late'));
    expect(
      (await pending.timeout(const Duration(seconds: 2))).stopAllowed,
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);
    expect(hooks.isPluginTripped(m.id, sid), isFalse);
  });

  test('explicit isCancelled signal completes true when the budget expires', () async {
    await fixture('signal-timeout', {'Stop': agentHook('slow', timeout: 1)});
    Future<bool>? signal;
    hooks.agentHookEvaluator = (e) {
      signal = e.isCancelled;
      return Completer<AgentHookVerdict?>().future;
    };
    expect((await hooks.fireStop(sid)).stopAllowed, isTrue);
    expect(await signal!.timeout(const Duration(seconds: 2)), isTrue);
  });

  test('agent evaluation is quiet: a verdict never publishes to the chat transcript', () async {
    await fixture('quiet', {'UserPromptSubmit': agentHook('review')});
    hooks.agentHookEvaluator = (_) async => AgentHookVerdict.block('denied');
    final session = AppState.I.sessions.firstWhere((s) => s.id == sid);
    final before = session.messages.length;
    final result = await hooks.fireDetailed(
      'UserPromptSubmit',
      sid,
      payload: {'prompt': 'hi'},
    );
    expect(result.promptBlockReason, 'denied');
    expect(session.messages.length, before);
  });
}
