import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_adapters.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_permissions.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/plugin_runtime.dart';
import 'package:ovid_ai/core/secure_store.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final hooks = HookService.I;
  final registry = PluginContributionRegistry.I;
  final manifests = <NormalizedPluginManifest>[];
  late Directory temp;
  const sid = 'wave2-hooks-session';

  Future<NormalizedPluginManifest> fixture(String name, Map<String, dynamic> events) async {
    final root = Directory('${temp.path}/$name')..createSync();
    Directory('${root.path}/.claude-plugin').createSync();
    File('${root.path}/.claude-plugin/plugin.json').writeAsStringSync(jsonEncode({
      'name': name, 'author': 'wave2', 'version': '1', 'hooks': events,
    }));
    final manifest = await const ClaudePluginAdapter().inspect(root);
    manifests.add(manifest);
    registry.register(manifest, activation: PluginActivation.globalActive);
    return manifest;
  }

  List<Map<String, dynamic>> command(String text) => [{
    'hooks': [{'type': 'command', 'command': text}],
  }];

  List<Map<String, dynamic>> agentHook(String prompt, {int? timeout}) => [{
    'hooks': [{'type': 'agent', 'prompt': prompt, 'timeout': ?timeout}],
  }];

  void replace(NormalizedPluginManifest manifest) {
    registry.unregisterPlugin(manifest.id);
    registry.register(manifest, activation: PluginActivation.globalActive);
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    hooks.resetForTest();
    hooks.enabled = true;
    AppState.resetTestInstance();
    final app = AppState.createForTest(pluginBootActivator: (_, _) async {});
    temp = Directory.systemTemp.createTempSync('wave2-hooks-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => temp.path);
    app.sessions.add(ChatSession(id: sid, title: 'fixture', model: 'fixture', workspaceFolder: temp.path));
    SessionLedger.rootOverrideForTest = Directory('${temp.path}/ledger')..createSync();
  });

  tearDown(() async {
    for (final m in manifests) { registry.unregisterPlugin(m.id); }
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

  for (final event in ['Notification', 'PreToolUse', 'Stop']) {
    test('same-object ABA fences in-flight $event result', () async {
      final m = await fixture('inflight', {event: command('pause')});
      hooks.executorForTest = (_, _) async {
        replace(m);
        return '{"decision":"block","reason":"stale","additionalContext":"stale","hookSpecificOutput":{"updatedInput":{"path":"stale"},"permissionDecision":"allow"}}';
      };
      if (event == 'Notification') {
        expect(await hooks.fire(event, sid), isEmpty);
      } else if (event == 'Stop') {
        expect((await hooks.fireStop(sid)).stopAllowed, isTrue);
      } else {
        final result = await hooks.fireGate(event, sid);
        expect(result.allowed, isTrue);
        expect(result.updatedInput, isNull);
        expect(result.bypassPermission, isFalse);
      }
    });
  }

  test('queued identical hook is fenced but unrelated owner still publishes', () async {
    await fixture('first', {'Notification': command('first')});
    final queued = await fixture('queued', {'Notification': command('queued')});
    hooks.executorForTest = (cmd, _) async {
      if (cmd == 'first') replace(queued);
      return cmd;
    };
    expect(await hooks.fire('Notification', sid), 'first');
  });

  for (final gate in [false, true]) {
    test('same-chain ABA removes prior ${gate ? 'rewrite and bypass' : 'output and messages'}', () async {
      final event = gate ? 'PreToolUse' : 'UserPromptSubmit';
      final first = await fixture('first', {event: command('first')});
      await fixture('second', {event: command('second')});
      hooks.executorForTest = (cmd, _) async {
        if (cmd == 'second') { replace(first); return gate ? '' : 'keep'; }
        return '{"additionalContext":"stale","systemMessage":"stale","hookSpecificOutput":{"updatedInput":{"path":"stale"},"permissionDecision":"allow"}}';
      };
      if (gate) {
        final result = await hooks.fireGate(event, sid);
        expect(result.updatedInput, isNull);
        expect(result.bypassPermission, isFalse);
      } else {
        final result = await hooks.fireDetailed(event, sid);
        expect(result.output, 'keep');
        expect(result.systemMessages, isEmpty);
      }
    });
  }

  for (final remove in [false, true]) {
    test('runtime ${remove ? 'uninstall' : 'disable'} revokes before its first await', () async {
      final m = await fixture('runtime', {'SessionStart': command('start')});
      String? envPath;
      hooks.executorForTest = (_, env) async {
        envPath = env['CLAUDE_ENV_FILE'];
        return '{"additionalContext":"owned","hookSpecificOutput":{"env":{"OWNED":"yes"}}}';
      };
      await hooks.fire('SessionStart', sid);
      expect(File(envPath!).existsSync(), isTrue);
      final pending = remove ? PluginRuntimeManager.I.uninstall(m.id) : PluginRuntimeManager.I.disable(m.id);
      try {
        expect(registry.isPluginActiveForSession(m.id, sid), isFalse);
        expect(File(envPath!).existsSync(), isFalse);
        expect(hooks.sessionContextFor(sid), isEmpty);
      } finally { await pending; }
    });
  }

  test('persisted runtime disable-enable does not restore unopened old context', () async {
    final m = await fixture('durable', {'SessionStart': [{
      'matcher': 'startup', 'hooks': [{'type': 'command', 'command': 'start'}],
    }]});
    // Real runtime entry/grant and content layout, not a mocked manager.
    final content = Directory('${temp.path}/plugin-runtime/${m.id}/1/content')..createSync(recursive: true);
    final installed = NormalizedPluginManifest.fromJson({...m.toJson(), 'rootPath': content.path});
    registry.register(installed, activation: PluginActivation.globalActive);
    final entry = PluginInstallEntry(
      activation: PluginActivationRecord(pluginId: m.id, state: PluginActivation.globalActive, installedBootEpoch: 0),
      manifest: installed, contentDir: content.path, version: '1',
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPluginActivationPrefKey, jsonEncode({m.id: jsonEncode(entry.toJson())}));
    await PluginPermissionStore().save(PluginPermissionGrant(
      pluginId: m.id, manifestDigest: pluginManifestDigest(installed),
      capabilities: installed.requestedCapabilities,
      environmentReadNames: installed.environmentReadNames, approvedAt: DateTime.utc(2026),
    ));
    hooks.executorForTest = (_, _) async => '{"additionalContext":"old-boot-context"}';
    await hooks.fire('SessionStart', sid, payload: {'source': 'startup'});
    hooks.resetForTest();
    await PluginRuntimeManager.I.disable(m.id);
    await PluginRuntimeManager.I.enable(m.id);
    await hooks.fire('SessionStart', sid, payload: {'source': 'resume'});
    expect(registry.isPluginActiveForSession(m.id, sid), isTrue);
    expect(hooks.sessionContextFor(sid), isEmpty);
    expect((await ovidSecureStorage().readAll()).values.join(), isNot(contains('old-boot-context')));
  });

  test('registration ABA erases owned context and env without an intervening read', () async {
    final m = await fixture('owned', {'SessionStart': command('start'), 'Notification': command('read')});
    String? oldPath;
    hooks.executorForTest = (cmd, env) async {
      if (cmd == 'read') return env['OWNED'] ?? 'unset';
      oldPath = env['CLAUDE_ENV_FILE'];
      return '{"additionalContext":"obsolete","hookSpecificOutput":{"env":{"OWNED":"yes"}}}';
    };
    await hooks.fire('SessionStart', sid);
    replace(m);
    expect(File(oldPath!).existsSync(), isFalse);
    expect(hooks.sessionContextFor(sid), isEmpty);
    expect(await hooks.fire('Notification', sid), 'unset');
    // Reconcile uses the production serialized encrypted-store queue.
    await hooks.fire('SessionStart', sid, payload: {'source': 'resume'}, onlyPluginId: 'absent/plugin');
    expect((await ovidSecureStorage().readAll()).values.join(), isNot(contains('obsolete')));
  });

  test('late prompt failures do not trip a same-object replacement', () async {
    final m = await fixture('prompt', {'Stop': [{'hooks': [{'type': 'prompt', 'prompt': 'check'}]}]});
    for (var i = 0; i < 3; i++) {
      hooks.promptHookEvaluator = (_, _) async { replace(m); throw StateError('old'); };
      expect((await hooks.fireStop(sid)).stopAllowed, isTrue);
    }
    expect(hooks.isPluginTripped(m.id, sid), isFalse);
  });

  test('replacement registration must run despite old start completion receipt', () async {
    final m = await fixture('receipt', {'SessionStart': command('start')});
    final completed = <String>{};
    var runs = 0;
    hooks.executorForTest = (_, _) async => '{"additionalContext":"run${++runs}"}';
    await hooks.fireDetailed('session_start', sid, completedStartHooks: completed);
    replace(m);
    await hooks.fireDetailed('session_start', sid, completedStartHooks: completed);
    expect(runs, 2);
    expect(hooks.sessionContextFor(sid), 'run2');
  });

  test('late gate file recreation is removed without touching replacement env', () async {
    final m = await fixture('latefile', {'PreToolUse': command('gate'), 'SessionStart': command('start')});
    String? oldPath;
    String? freshPath;
    hooks.executorForTest = (cmd, env) async {
      if (cmd == 'start') {
        freshPath = env['CLAUDE_ENV_FILE'];
        return '{"hookSpecificOutput":{"env":{"FRESH":"yes"}}}';
      }
      oldPath = env['CLAUDE_ENV_FILE'];
      replace(m);
      await hooks.fire('SessionStart', sid);
      File(oldPath!).writeAsStringSync('OLD=stale');
      return '{"decision":"block"}';
    };
    expect((await hooks.fireGate('PreToolUse', sid)).allowed, isTrue);
    expect(File(oldPath!).existsSync(), isFalse);
    expect(File(freshPath!).readAsStringSync(), contains('FRESH=yes'));
  });

  test('boot removes orphan env files and symlinks without traversing them', () async {
    final env = Directory('${temp.path}/hook-env')..createSync();
    final old = File('${env.path}/old-boot.env')..writeAsStringSync('SECRET=old');
    final target = File('${temp.path}/target')..writeAsStringSync('keep');
    final link = Link('${env.path}/linked.env')..createSync(target.path);
    final dir = Directory('${env.path}/directory.env')..createSync();
    File('${dir.path}/nested.env').writeAsStringSync('keep');
    await hooks.loadEnabled();
    expect(old.existsSync(), isFalse);
    expect(link.existsSync(), isFalse);
    expect(target.readAsStringSync(), 'keep');
    expect(File('${dir.path}/nested.env').existsSync(), isTrue);
  });

  test('orphan sweep has a bounded batch and progresses across invocations', () async {
    final env = Directory('${temp.path}/hook-env')..createSync();
    for (var i = 0; i < 150; i++) {
      File('${env.path}/old-$i.env').writeAsStringSync('OLD=yes');
    }
    await hooks.loadEnabled();
    int remaining() => env.listSync().whereType<File>().length;
    expect(remaining(), greaterThan(0));
    expect(remaining(), lessThan(150));
    for (var i = 0; i < 10 && remaining() > 0; i++) { await hooks.loadEnabled(); }
    expect(remaining(), 0);
  });

  test('agent evaluation is cancelled and fenced when the session ends', () async {
    await fixture('agent-end', {'Stop': agentHook('check')});
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
    await hooks.fire('session_end', sid);
    expect(await signal!.timeout(const Duration(seconds: 2)), isTrue);
    release.complete(AgentHookVerdict.block('late'));
    expect(
      (await pending.timeout(const Duration(seconds: 2))).stopAllowed,
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);
  });

  test('agent timeout fails open with a ledger note and signals isCancelled', () async {
    await fixture('agent-timeout', {'Stop': agentHook('slow', timeout: 1)});
    Future<bool>? signal;
    hooks.agentHookEvaluator = (e) {
      signal = e.isCancelled;
      return Completer<AgentHookVerdict?>().future;
    };
    expect((await hooks.fireStop(sid)).stopAllowed, isTrue);
    expect(await signal!.timeout(const Duration(seconds: 2)), isTrue);
    await SessionLedger.I.flush(sid);
    expect(
      Directory('${temp.path}/ledger')
          .listSync()
          .whereType<File>()
          .map((f) => f.readAsStringSync())
          .join(),
      contains('timed out (fail-open)'),
    );
  });

  test('agent cancellation token is delivered before the fence settles', () async {
    final m = await fixture('agent-token', {'Stop': agentHook('check')});
    final entered = Completer<void>();
    final release = Completer<AgentHookVerdict?>();
    Future<void>? cancelled;
    Future<bool>? signal;
    hooks.agentHookEvaluator = (e) {
      cancelled = e.cancelled;
      signal = e.isCancelled;
      entered.complete();
      return release.future;
    };
    final pending = hooks.fireStop(sid);
    await entered.future;
    final uninstall = PluginRuntimeManager.I.uninstall(m.id);
    try {
      await cancelled!.timeout(const Duration(seconds: 2));
      expect(await signal!.timeout(const Duration(seconds: 2)), isTrue);
      expect((await pending.timeout(const Duration(seconds: 2))).stopAllowed, isTrue);
    } finally {
      release.complete(AgentHookVerdict.block('late'));
      await uninstall;
    }
  });
}
