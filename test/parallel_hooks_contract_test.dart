import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/diag.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_adapters.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final service = HookService.I;
  final registry = PluginContributionRegistry.I;
  final ids = <String>[];
  final sessions = <String>[];
  late Directory temp;
  late String sid;

  void session(String id) {
    sessions.add(id);
    AppState.I.sessions.add(ChatSession(
      id: id, title: 'fixture', model: 'fixture',
      workspaceFolder: '${temp.path}/workspace',
    ));
  }

  Future<NormalizedPluginManifest> fixture(String name,
      Map<String, dynamic> events, {Map<String, String> scripts = const {}}) async {
    final root = Directory('${temp.path}/$name')..createSync();
    Directory('${root.path}/.claude-plugin').createSync();
    File('${root.path}/.claude-plugin/plugin.json').writeAsStringSync(jsonEncode({
      'name': name, 'author': 'parallel-hooks', 'version': '1',
      'hooks': events,
    }));
    for (final e in scripts.entries) {
      File('${root.path}/${e.key}').writeAsStringSync(e.value);
    }
    final manifest = await const ClaudePluginAdapter().inspect(root);
    ids.add(manifest.id);
    registry.register(manifest, activation: PluginActivation.globalActive);
    return manifest;
  }

  List<Map<String, dynamic>> command(String text, {String? matcher}) => [{
    'matcher': ?matcher,
    'hooks': [{'type': 'command', 'command': text}],
  }];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    service.resetForTest();
    service.enabled = true;
    Diag.resetForTest();
    AppState.resetTestInstance();
    AppState.createForTest(pluginBootActivator: (_, _) async {});
    temp = Directory.systemTemp.createTempSync('parallel-hooks-');
    Directory('${temp.path}/workspace').createSync();
    final prefix = Directory('${temp.path}/sandbox');
    Directory('${prefix.path}/bin').createSync(recursive: true);
    Directory('${prefix.path}/home').createSync();
    Link('${prefix.path}/bin/bash').createSync('/bin/bash');
    SandboxService.I.sandboxPrefixForTest = prefix;
    sid = temp.path.split('/').last;
    session(sid);
    SessionLedger.rootOverrideForTest = Directory('${temp.path}/ledger')..createSync();
  });

  tearDown(() async {
    AgentService.setRunSessionForTest('');
    service.enabled = false;
    for (final id in sessions) {
      await service.fire('session_end', id);
      await SessionLedger.I.close(id);
    }
    sessions.clear();
    for (final id in ids) { registry.unregisterPlugin(id); }
    ids.clear();
    service.resetForTest();
    SandboxService.I.resetCheckExistingForTest();
    SessionLedger.rootOverrideForTest = null;
    AppState.resetTestInstance();
    await temp.delete(recursive: true);
  });

  test('actual reentrant same-event dispatch is skipped; another session runs', () async {
    await fixture('reentrant', {'Notification': command('notify')});
    session('$sid-other');
    final seen = <String>[];
    service.executorForTest = (_, env) async {
      final current = env['PLUGIN_SESSION']!;
      seen.add(current);
      expect(await service.fire('Notification', current), isEmpty);
      if (current == sid) {
        expect(await service.fire('notification', '$sid-other'), 'other');
      }
      return current == sid ? 'main' : 'other';
    };
    expect(await service.fire('notification', sid), 'main');
    expect(seen, [sid, '$sid-other']);
  });

  test('queued removed hook never executes after a reentrant callback', () async {
    await fixture('first', {'Notification': command('first')});
    final removed = await fixture('removed', {'Notification': command('removed')});
    service.executorForTest = (cmd, _) async {
      registry.unregisterPlugin(removed.id);
      return cmd;
    };
    expect(await service.fire('notification', sid), 'first');
    expect(service.fired, 1);
  });

  for (final end in [false, true]) {
    test('late gate decision is ignored after ${end ? 'session end' : 'disable'}', () async {
      final manifest = await fixture('late', {'PreToolUse': command('late')});
      final entered = Completer<void>();
      final release = Completer<String>();
      service.executorForTest = (_, _) { entered.complete(); return release.future; };
      final result = service.fireGate('pre_tool', sid);
      await entered.future;
      if (end) {
        await service.fire('session_end', sid);
      } else {
        registry.register(manifest, activation: PluginActivation.disabled);
      }
      release.complete('{"decision":"block","reason":"stale"}');
      expect((await result).allowed, isTrue);
    });
  }

  test('late prompt veto cannot override user stop during evaluation', () async {
    await fixture('prompt', {'Stop': [{'hooks': [{'type': 'prompt', 'prompt': 'check'}]}]});
    var stopped = false;
    service.userStopChecker = (_) => stopped;
    service.promptHookEvaluator = (_, _) async {
      stopped = true;
      return '{"decision":"block","reason":"late"}';
    };
    final result = await service.fireStop(sid);
    expect(result.stopAllowed, isTrue);
    expect(result.userInitiated, isTrue);
  });

  test('real env-file exports are parsed; colliding sessions stay isolated', () async {
    session('$sid/a');
    session('${sid}_a');
    await fixture('env', {
      'SessionStart': command(r'bash "$CLAUDE_PLUGIN_ROOT/start.sh"', matcher: 'startup'),
      'Notification': command(r'printf "%s" "${COLOR:-unset}"'),
    }, scripts: {'start.sh': '''
read -r input
[[ "\$input" == *'"source":"startup"'* ]] || exit 3
[[ "\$PWD" == "\$CLAUDE_PROJECT_DIR" ]] || exit 4
printf '%s\n' "export COLOR='deep blue'" >> "\$CLAUDE_ENV_FILE"
printf '%s' '{"hookSpecificOutput":{"additionalContext":"ready"}}'
'''});
    await service.fire('SessionStart', '$sid/a', payload: {'reason': 'created'});
    expect(service.sessionContextFor('$sid/a'), 'ready');
    expect(await service.fire('Notification', '$sid/a'), 'deep blue');
    expect(await service.fire('Notification', '${sid}_a'), 'unset');
  });

  test('disable removes only owned environment contribution', () async {
    final first = await fixture('first', {'SessionStart': command(
      '''printf '%s' '{"hookSpecificOutput":{"env":{"FIRST":"one"}}}' ''')});
    await fixture('second', {
      'SessionStart': command('''printf '%s' '{"hookSpecificOutput":{"env":{"SECOND":"two"}}}' '''),
      'Notification': command(r'printf "%s/%s" "${FIRST:-unset}" "${SECOND:-unset}"'),
    });
    await service.fire('session_start', sid);
    expect(await service.fire('notification', sid), 'one/two');
    registry.register(first, activation: PluginActivation.disabled);
    expect(await service.fire('notification', sid), 'unset/two');
    registry.unregisterPlugin('parallel-hooks/second');
    expect(service.sessionContextFor(sid), isEmpty);
  });

  test('late direct env-file write cannot reach replacement session generation', () async {
    await fixture('lateenv', {
      'SessionStart': command('late'),
      'Notification': command('read'),
    });
    final entered = Completer<String>();
    final release = Completer<String>();
    service.executorForTest = (cmd, env) async {
      if (cmd == 'read') return env['LATE'] ?? 'unset';
      entered.complete(env['CLAUDE_ENV_FILE']!);
      return release.future;
    };
    final start = service.fire('session_start', sid);
    final path = await entered.future;
    await service.fire('session_end', sid);
    File(path).writeAsStringSync('LATE=stale\n');
    release.complete('{"hookSpecificOutput":{"env":{"LATE":"also-stale"}}}');
    await start;
    expect(await service.fire('notification', sid), 'unset');
    expect(File(path).existsSync(), isFalse);
  });

  test('environment updates reject newline injection and execution overrides', () async {
    await fixture('unsafe', {
      'SessionStart': command('unsafe'), 'Notification': command('read'),
    });
    service.executorForTest = (cmd, env) async => cmd == 'unsafe'
      ? jsonEncode({'hookSpecificOutput': {'env': {
          'SAFE': 'yes', 'MULTI': 'line\nINJECTED=bad', 'BASH_ENV': '/bad',
          'LD_PRELOAD': '/bad', 'PLUGIN_SESSION': 'forged',
        }}})
      : jsonEncode({for (final key in ['SAFE', 'MULTI', 'INJECTED', 'BASH_ENV', 'LD_PRELOAD', 'PLUGIN_SESSION']) key: env[key]});
    await service.fire('session_start', sid);
    final env = jsonDecode(await service.fire('notification', sid));
    expect(env['SAFE'], 'yes');
    for (final key in ['MULTI', 'INJECTED', 'BASH_ENV', 'LD_PRELOAD']) {
      expect(env[key], isNull, reason: key);
    }
    expect(env['PLUGIN_SESSION'], sid);
  });

  test('secret output cannot enter context, gate reason, rewritten input or ledger', () async {
    const secret = 'fixture-sensitive-value';
    await fixture('secret', {
      'SessionStart': command("printf '%s' '{\"hookSpecificOutput\":{\"env\":{\"API_TOKEN\":\"$secret\"}}}'"),
      'UserPromptSubmit': command(r'''printf '{"hookSpecificOutput":{"additionalContext":"%s"},"systemMessage":"%s"}' "$API_TOKEN" "$API_TOKEN"'''),
      'PreToolUse': command(r'''printf '{"decision":"block","reason":"%s","hookSpecificOutput":{"updatedInput":{"password":"%s"}}}' "$API_TOKEN" "$API_TOKEN"'''),
    });
    expect(await service.fire('session_start', sid), isNot(contains(secret)));
    final observe = await service.fireDetailed('user_prompt_submit', sid);
    expect(observe.output, isNot(contains(secret)));
    expect(observe.systemMessages.join(), isNot(contains(secret)));
    final gate = await service.fireGate('pre_tool', sid);
    expect(gate.decision, HookDecision.deny);
    expect(gate.reason, isNot(contains(secret)));
    // Operational arguments must survive intact; only publication copies scrub.
    expect(gate.updatedInput?['password'], secret);
    await SessionLedger.I.close(sid);
    final ledger = Directory('${temp.path}/ledger').listSync().whereType<File>()
      .map((f) => f.readAsStringSync()).join();
    expect(ledger, isNot(contains(secret)));
    expect(Diag.recent().map((e) => e.error).join(), isNot(contains(secret)));
  });

  test('prompt evaluator errors do not persist credentials', () async {
    await fixture('error', {'Stop': [{'hooks': [{'type': 'prompt', 'prompt': 'check'}]}]});
    service.promptHookEvaluator = (_, _) async => throw StateError('credential=fixture-secret');
    expect((await service.fireStop(sid)).stopAllowed, isTrue);
    await SessionLedger.I.close(sid);
    expect(Directory('${temp.path}/ledger').listSync().whereType<File>()
      .map((f) => f.readAsStringSync()).join(), isNot(contains('fixture-secret')));
  });

  test('adapter rejects unsupported agent hooks and malformed declarations visibly', () async {
    final manifest = await fixture('unsupported', {
      'Stop': [{'hooks': [
        {'type': 'agent', 'prompt': 'use tools'},
        {'type': 'command', 'command': 42},
        {'type': 'prompt', 'command': 'wrong', 'prompt': 'right'},
      ]}],
    });
    expect(manifest.hooks.map((h) => h.type), ['prompt']);
    expect(manifest.hooks.single.payload, 'right');
    expect(manifest.compatibility.length, greaterThanOrEqualTo(2));
  });

  test('oversized real hook output fails open instead of entering prompt', () async {
    await fixture('flood', {'SessionStart': command("printf '%70000s' x")});
    final result = await service.fireDetailed('session_start', sid);
    expect(result.retryableFailure, isTrue);
    expect(result.output, isEmpty);
    expect(service.sessionContextFor(sid), isEmpty);
    expect(SandboxService.I.liveProcessesForTest, isEmpty);
  });

  test('oversized environment append cannot inflate or poison later hooks', () async {
    await fixture('bigenv', {
      'SessionStart': command('big'), 'Notification': command('read'),
    });
    String? path;
    service.executorForTest = (cmd, env) async {
      path = env['CLAUDE_ENV_FILE'];
      return cmd == 'big'
          ? jsonEncode({'hookSpecificOutput': {'env': {'BIG': 'x' * 70000}}})
          : env['BIG'] ?? 'unset';
    };
    await service.fire('session_start', sid);
    expect(await service.fire('notification', sid), 'unset');
    expect(File(path!).existsSync() ? File(path!).lengthSync() : 0, lessThanOrEqualTo(65536));
  });

  test('real missing-secret and malformed-output hooks fail open', () async {
    await fixture('missing', {
      'PreToolUse': command(r': "${PARALLEL_HOOK_MISSING_TOKEN:?required}"'),
      'UserPromptSubmit': command('''printf '%s' '{"decision":"block"' '''),
    });
    expect((await service.fireGate('pre_tool', sid)).allowed, isTrue);
    final result = await service.fireDetailed('user_prompt_submit', sid);
    expect(result.blockedReason, isNull);
    expect(result.output, isEmpty);
  });

  test('[CC] success and failure hooks receive only their declared event', () async {
    await fixture('events', {
      'PostToolUse': command(r'printf "success:%s" "$PLUGIN_PAYLOAD"', matcher: 'Bash'),
      'PostToolUseFailure': command(r'printf "failure:%s" "$PLUGIN_PAYLOAD"', matcher: 'Bash'),
    });
    final success = await service.fire('post_tool', sid, payload: {'tool': 'run_shell'});
    expect(success, startsWith('success:'));
    expect(success, isNot(contains('failure:')));
    final failure = await service.fire('PostToolUseFailure', sid, payload: {'tool': 'run_shell'});
    expect(failure, startsWith('failure:'));
    expect(failure, isNot(contains('success:')));
  });

  test('[CC] prompt boolean verdict blocks through evaluator with event JSON', () async {
    await fixture('verdict', {'PreToolUse': [{'hooks': [
      {'type': 'prompt', 'prompt': r'Check $ARGUMENTS'},
    ]}]});
    service.promptHookEvaluator = (prompt, _) async {
      expect(prompt, contains('"tool_name":"run_shell"'));
      expect(prompt, isNot(contains(r'$ARGUMENTS')));
      return '{"ok":false,"reason":"fixture denied"}';
    };
    final result = await service.fireGate('PreToolUse', sid, payload: {'tool': 'run_shell'});
    expect(result.decision, HookDecision.deny);
    expect(result.reason, 'fixture denied');
  });

  test('stale prompt failure cannot trip replacement session breaker', () async {
    await fixture('lateprompt', {'Stop': [{'hooks': [{'type': 'prompt', 'prompt': 'check'}]}]});
    for (var i = 0; i < 3; i++) {
      final entered = Completer<void>();
      final release = Completer<String?>();
      service.promptHookEvaluator = (_, _) { entered.complete(); return release.future; };
      final stop = service.fireStop(sid);
      await entered.future;
      await service.fire('session_end', sid);
      release.completeError(StateError('stale'));
      expect((await stop).stopAllowed, isTrue);
    }
    expect(service.isPluginTripped('parallel-hooks/lateprompt', sid), isFalse);
  });

  test('session-scoped plugin never exports env or context to sibling', () async {
    session('$sid-sibling');
    final manifest = await fixture('scoped', {
      'SessionStart': command('''printf '%s' '{"additionalContext":"owned","hookSpecificOutput":{"env":{"OWNED":"yes"}}}' '''),
      'Notification': command(r'printf "%s" "${OWNED:-unset}"'),
    });
    registry.register(manifest, activation: PluginActivation.sessionActive, immediateSessionId: sid);
    await Future.wait([service.fire('session_start', sid), service.fire('session_start', '$sid-sibling')]);
    expect(service.sessionContextFor(sid), 'owned');
    expect(service.sessionContextFor('$sid-sibling'), isEmpty);
    expect(await service.fire('notification', sid), 'yes');
    expect(await service.fire('notification', '$sid-sibling'), isEmpty);
  });

  test('reentrant session end invalidates already collected event output', () async {
    await fixture('collected', {'Notification': [{'hooks': [
      {'type': 'command', 'command': 'first'}, {'type': 'command', 'command': 'end'},
    ]}]});
    service.executorForTest = (cmd, _) async {
      if (cmd == 'end') await service.fire('session_end', sid);
      return cmd;
    };
    expect(await service.fire('notification', sid), isEmpty);
  });

  test('async late failure cannot consume replacement generation breaker', () async {
    await fixture('async', {'Notification': [{'hooks': [
      {'type': 'command', 'command': 'late', 'async': true},
    ]}]});
    for (var i = 0; i < 3; i++) {
      final release = Completer<(int, String)>();
      service.stdinExecutorForTest = (_, _, _) => release.future;
      await service.fire('notification', sid);
      await service.fire('session_end', sid);
      release.complete((1, 'ignored'));
      await Future<void>.delayed(Duration.zero);
    }
    expect(service.isPluginTripped('parallel-hooks/async', sid), isFalse);
  });

  test('real hook timeout terminates tracked child and permits later event', () async {
    await fixture('timeout', {'Notification': [{'hooks': [
      {'type': 'command', 'command': 'while :; do :; done', 'timeout': 1},
    ]}]});
    final result = await service.fireDetailed('notification', sid).timeout(const Duration(seconds: 5));
    expect(result.retryableFailure, isTrue);
    expect(result.output, isEmpty);
    // The exit callback runs after SIGKILL, independently of the timeout result.
    for (var i = 0; i < 100 && SandboxService.I.liveProcessesForTest.isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(SandboxService.I.liveProcessesForTest, isEmpty);
    service.executorForTest = (_, _) async => 'recovered';
    expect(await service.fire('notification', sid), 'recovered');
  });

  test('prompt hook honors declared timeout and ignores late verdict', () async {
    await fixture('prompttimeout', {'Stop': [{'hooks': [
      {'type': 'prompt', 'prompt': 'check', 'timeout': 1},
    ]}]});
    final release = Completer<String?>();
    service.promptHookEvaluator = (_, _) => release.future;
    try {
      final stop = await service.fireStop(sid).timeout(const Duration(seconds: 3));
      expect(stop.stopAllowed, isTrue);
      expect(service.failed, 1);
    } finally {
      release.complete('{"ok":false,"reason":"too late"}');
    }
  });

  test('unsafe environment declarations emit value-free diagnostics', () async {
    await fixture('diagnostics', {'SessionStart': command('unsafe')});
    service.executorForTest = (_, _) async => '{"hookSpecificOutput":{"env":{"BASH_ENV":"private-fixture"}}}';
    await service.fire('session_start', sid);
    expect(Diag.recent().any((e) => e.context == 'hook_env'), isTrue);
    expect(Diag.recent().map((e) => e.error).join(), isNot(contains('private-fixture')));
  });

  test('SessionStart source matcher accepts native source payload', () async {
    await fixture('source', {'SessionStart': command('printf resumed', matcher: 'resume')});
    await service.fire('SessionStart', sid, payload: {'source': 'resume'});
    expect(service.sessionContextFor(sid), 'resumed');
  });

  test('distinct reentrant events stop at chain bound and release all guards', () async {
    const events = ['notification', 'pre_request', 'post_request', 'pre_compact', 'post_compact'];
    await fixture('depth', {for (final event in events) event: command(event)});
    final seen = <String>[];
    service.executorForTest = (cmd, _) async {
      seen.add(cmd);
      final index = events.indexOf(cmd);
      if (index + 1 < events.length) await service.fire(events[index + 1], sid);
      return cmd;
    };
    await service.fire(events.first, sid);
    expect(seen, ['notification', 'pre_request', 'post_request', 'pre_compact']);
    expect(await service.fire('post_compact', sid), 'post_compact');
  });

  test('secret matching a decision cannot turn a deny into allow', () async {
    await fixture('collision', {'PreToolUse': command('decision')});
    service.executorForTest = (_, _) async => '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"deny"}}';
    final gate = await service.fireGate('pre_tool', sid, payload: {'args': {'token': 'deny'}});
    expect(gate.decision, HookDecision.deny);
    expect(gate.reason, '[redacted]');
  });

  test('prompt decision survives secret collision while reason is scrubbed', () async {
    await fixture('promptcollision', {'PreToolUse': [{'hooks': [
      {'type': 'prompt', 'prompt': 'check'},
    ]}]});
    service.promptHookEvaluator = (_, _) async => '{"decision":"block","reason":"block"}';
    final gate = await service.fireGate('pre_tool', sid, payload: {'token': 'block'});
    expect(gate.decision, HookDecision.deny);
    expect(gate.reason, '[redacted]');
  });

  test('actual dispatcher applies credential-bearing hook rewrite intact', () async {
    const credential = 'round-two-credential';
    AgentService.setRunSessionForTest(sid);
    final provider = AppState.I.providers.first;
    await fixture('rewrite', {'PreToolUse': command(
      '''printf '%s' '{"hookSpecificOutput":{"updatedInput":{"api_key":"$credential"}}}' ''',
      matcher: 'catalog_set_provider_key')});
    final result = await AgentService.I.dispatchForTest('catalog_set_provider_key', {
      'provider_id': provider.id, 'api_key': 'original',
    });
    expect(result, contains('API key stored'));
    expect(provider.apiKey, credential);
    expect(result, isNot(contains(credential)));
    await SessionLedger.I.close(sid);
    expect(Directory('${temp.path}/ledger').listSync().whereType<File>()
      .map((f) => f.readAsStringSync()).join(), isNot(contains(credential)));
  });

  for (final outcome in ['success', 'returned-error', 'exception']) {
    test('actual dispatcher selects $outcome post-tool fixture', () async {
      AgentService.setRunSessionForTest(sid);
      await fixture('dispatch', {
        'PostToolUse': command('success', matcher: 'catalog_set_provider_key'),
        'PostToolUseFailure': command('failure', matcher: 'catalog_set_provider_key'),
      });
      final seen = <String>[];
      final done = Completer<void>();
      service.stdinExecutorForTest = (cmd, _, stdin) async {
        seen.add(cmd);
        final input = jsonDecode(stdin);
        expect(input['hook_event_name'], outcome == 'success' ? 'PostToolUse' : 'PostToolUseFailure');
        done.complete();
        return (0, '');
      };
      final provider = AppState.I.providers.first;
      final dispatch = AgentService.I.dispatchForTest('catalog_set_provider_key', {
        if (outcome != 'exception') 'provider_id': outcome == 'success' ? provider.id : 'missing-provider',
        'api_key': 'fixture-only',
      });
      if (outcome == 'exception') {
        await expectLater(dispatch, throwsA(isA<TypeError>()));
      } else {
        final result = await dispatch;
        expect(result, contains(outcome == 'success' ? 'API key stored' : 'not found'));
      }
      await done.future.timeout(const Duration(seconds: 3));
      // Wait for fire-and-forget dispatch to release its recursion guard.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(seen, [outcome == 'success' ? 'success' : 'failure']);
    });
  }

  test('old session end cannot delete concurrent new start environment', () async {
    await fixture('endrace', {
      'SessionStart': command('start'),
      'SessionEnd': command('end'),
      'Notification': command('read'),
    });
    final entered = Completer<void>();
    final release = Completer<String>();
    service.executorForTest = (cmd, env) async {
      if (cmd == 'end') { entered.complete(); return release.future; }
      if (cmd == 'read') return env['FRESH'] ?? 'unset';
      return '{"hookSpecificOutput":{"env":{"FRESH":"new"},"additionalContext":"new"}}';
    };
    final ending = service.fire('session_end', sid);
    await entered.future;
    await service.fire('session_start', sid);
    release.complete('old end');
    await ending;
    expect(await service.fire('notification', sid), 'new');
    expect(service.sessionContextFor(sid), 'new');
  });

  test('later plugin removal filters prior context and system message publication', () async {
    final first = await fixture('earlier', {'UserPromptSubmit': command('earlier')});
    await fixture('remover', {'UserPromptSubmit': command('remove')});
    service.executorForTest = (cmd, _) async {
      if (cmd == 'remove') { registry.unregisterPlugin(first.id); return 'keep'; }
      return '{"additionalContext":"stale","systemMessage":"stale-message"}';
    };
    final result = await service.fireDetailed('user_prompt_submit', sid);
    expect(result.output, 'keep');
    expect(result.systemMessages, isEmpty);
  });

  test('later disable filters prior rewrite and permission bypass', () async {
    final first = await fixture('earliergate', {'PreToolUse': command('earlier')});
    await fixture('removergate', {'PreToolUse': command('remove')});
    service.executorForTest = (cmd, _) async {
      if (cmd == 'remove') { registry.register(first, activation: PluginActivation.disabled); return ''; }
      return '{"hookSpecificOutput":{"permissionDecision":"allow","updatedInput":{"path":"stale"}}}';
    };
    final result = await service.fireGate('pre_tool', sid);
    expect(result.updatedInput, isNull);
    expect(result.bypassPermission, isFalse);
  });

  test('new start fences session end still awaiting context-store deletion', () async {
    await fixture('earlyendrace', {
      'SessionStart': command('start'), 'SessionEnd': command('end'),
      'Notification': command('read'),
    });
    final endRelease = Completer<String>();
    service.executorForTest = (cmd, env) async {
      if (cmd == 'end') return endRelease.future;
      if (cmd == 'read') return env['FRESH'] ?? 'unset';
      return '{"hookSpecificOutput":{"env":{"FRESH":"new"}}}';
    };
    final ending = service.fire('session_end', sid);
    await service.fire('session_start', sid);
    endRelease.complete('obsolete');
    expect(await ending, isEmpty);
    expect(await service.fire('notification', sid), 'new');
  });

  test('paused end detaches once across sequential targeted starts', () async {
    session('$sid-other');
    final first = await fixture('handofffirst', {
      'SessionStart': command('first'), 'SessionEnd': command('end'),
      'Notification': command('read'),
    });
    final second = await fixture('handoffsecond', {'SessionStart': command('second')});
    final entered = Completer<void>();
    final release = Completer<String>();
    service.executorForTest = (cmd, env) async {
      if (cmd == 'end') { entered.complete(); return release.future; }
      if (cmd == 'read') return '${env['FIRST'] ?? 'unset'}/${env['SECOND'] ?? 'unset'}';
      return jsonEncode({'hookSpecificOutput': {
        'env': {cmd == 'first' ? 'FIRST' : 'SECOND': env['PLUGIN_SESSION']},
        'additionalContext': cmd,
      }});
    };
    await service.fire('session_start', '$sid-other', onlyPluginId: first.id);
    final ending = service.fire('session_end', sid);
    await entered.future;
    try {
      await service.fire('session_start', sid, onlyPluginId: first.id);
      await service.fire('session_start', sid, onlyPluginId: second.id);
      await service.fire('session_start', sid, onlyPluginId: second.id);
      expect(await service.fire('notification', sid), '$sid/$sid');
      expect(service.sessionContextFor(sid), 'first\nsecond');
      expect(await service.fire('notification', '$sid-other'), '$sid-other/unset');
    } finally {
      release.complete('old');
      await ending;
    }
    expect(await service.fire('notification', sid), '$sid/$sid');
  });

  for (final reentrant in [false, true]) {
    test('paused end rejected ${reentrant ? 'reentrant' : 'overlapping'} start leaves active start intact', () async {
      await fixture('duplicatestart', {
        'SessionStart': command('start'), 'SessionEnd': command('end'),
        'Notification': command('read'),
      });
      final endEntered = Completer<void>();
      final endRelease = Completer<String>();
      final startEntered = Completer<void>();
      final startRelease = Completer<void>();
      var starts = 0;
      HookFireResult? duplicate;
      service.executorForTest = (cmd, env) async {
        if (cmd == 'end') { endEntered.complete(); return endRelease.future; }
        if (cmd == 'read') return env['FRESH'] ?? 'unset';
        starts++;
        startEntered.complete();
        if (reentrant) {
          duplicate = await service.fireDetailed('SessionStart', sid);
        } else {
          await startRelease.future;
        }
        return '{"hookSpecificOutput":{"env":{"FRESH":"kept"},"additionalContext":"kept"}}';
      };
      final ending = service.fire('session_end', sid);
      await endEntered.future;
      final starting = service.fireDetailed('session_start', sid);
      try {
        await startEntered.future;
        if (!reentrant) {
          duplicate = await service.fireDetailed('SessionStart', sid);
          startRelease.complete();
        }
        final result = await starting;
        expect(duplicate?.retryableFailure, isTrue);
        expect(duplicate?.output, isEmpty);
        expect(starts, 1);
        expect(result.output, contains('kept'));
        expect(service.sessionContextFor(sid), 'kept');
        expect(await service.fire('notification', sid), 'kept');
      } finally {
        if (!startRelease.isCompleted) startRelease.complete();
        endRelease.complete('old');
        await starting;
        await ending;
      }
      expect(await service.fire('notification', sid), 'kept');
    });
  }
}
