import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_lifecycle_service.dart';
import 'package:ovid_ai/core/state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late ChatSession session;
  final registered = <String>[];

  NormalizedPluginManifest register(
    String name,
    List<String> commands, {
    String event = 'session_start',
    String? matcher,
    PluginFormat format = PluginFormat.claudeCode,
  }) {
    final id = 'w07/$name';
    final root = Directory('${temp.path}/plugin-runtime/w07/$name/1/content')
      ..createSync(recursive: true);
    final manifest = NormalizedPluginManifest(
      id: id,
      name: name,
      version: '1',
      format: format,
      rootPath: root.path,
      hooks: [
        for (var i = 0; i < commands.length; i++)
          PluginHook(
            pluginId: id,
            event: event,
            ordinal: i,
            type: 'command',
            payload: commands[i],
            matcher: matcher,
          ),
      ],
    );
    PluginContributionRegistry.I.register(
      manifest,
      activation: PluginActivation.globalActive,
    );
    registered.add(id);
    return manifest;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    HookService.I.resetForTest();
    HookService.I.enabled = true;
    SessionLifecycleService.I.resetForTest();
    AppState.resetTestInstance();
    final app = AppState.createForTest(pluginBootActivator: (_, _) async {});
    temp = Directory.systemTemp.createTempSync('hook-w07-');
    final workspace = Directory('${temp.path}/workspace')..createSync();
    session = ChatSession(
      id: 'w07-session',
      title: 'test',
      model: 'test',
      workspaceFolder: workspace.path,
    );
    app.sessions.add(session);
    SessionLedger.rootOverrideForTest = Directory('${temp.path}/ledger');
    SessionLifecycleService.I.activationWaiterForTest = (_) async {};
    SessionLifecycleService.I.skillRefresherForTest = (_) async {};
  });

  tearDown(() async {
    await SessionLifecycleService.I.drainForTest();
    for (final id in registered) {
      PluginContributionRegistry.I.unregisterPlugin(id);
    }
    registered.clear();
    HookService.I.resetForTest();
    SessionLifecycleService.I.resetForTest();
    SandboxService.I.resetCheckExistingForTest();
    SandboxService.execCheckedOverrideForTest = null;
    SessionLedger.rootOverrideForTest = null;
    AppState.resetTestInstance();
    await temp.delete(recursive: true);
  });

  test(
    'extracts each JSON stdout before combining or capping context',
    () async {
      register('first', ['one', 'two']);
      HookService.I.executorForTest = (cmd, _) async => jsonEncode({
        'hookSpecificOutput': {
          'additionalContext': cmd == 'one' ? 'alpha' : 'beta',
        },
        'padding': 'x' * 10000,
      });
      await HookService.I.fire('session_start', session.id);
      expect(HookService.I.sessionContextFor(session.id), 'alpha\nbeta');
    },
  );

  test(
    'targeted plugin bootstrap retains first plugin; disable filters it',
    () async {
      final first = register('first', ['alpha']);
      HookService.I.executorForTest = (cmd, _) async => cmd;
      await HookService.I.fire('session_start', session.id);
      register('second', ['beta']);
      await HookService.I.fire(
        'session_start',
        session.id,
        onlyPluginId: 'w07/second',
      );
      expect(HookService.I.sessionContextFor(session.id), 'alpha\nbeta');
      PluginContributionRegistry.I.register(
        first,
        activation: PluginActivation.disabled,
      );
      expect(HookService.I.sessionContextFor(session.id), 'beta');
      PluginContributionRegistry.I.unregisterPlugin('w07/second');
      expect(HookService.I.sessionContextFor(session.id), isEmpty);
    },
  );

  test(
    'start retry preserves first reason and skips successful hooks',
    () async {
      register('retry', ['good', 'flaky'], matcher: 'resume');
      final calls = <String>[];
      var ready = false;
      HookService.I.stdinExecutorForTest = (cmd, _, input) async {
        calls.add(cmd);
        expect(jsonDecode(input)['reason'], 'restored');
        return (cmd == 'flaky' && !ready ? 127 : 0, cmd);
      };
      await SessionLifecycleService.I.sessionStarted(
        session,
        reason: SessionStartReason.restored,
      );
      ready = true;
      await SessionLifecycleService.I.sessionStarted(
        session,
        reason: SessionStartReason.implicit,
      );
      expect(calls, ['good', 'flaky', 'flaky']);
      expect(HookService.I.sessionContextFor(session.id), 'good\nflaky');
    },
  );

  test('activation failure can retry with original resume reason', () async {
    var ready = false;
    SessionLifecycleService.I.activationWaiterForTest = (_) async {
      if (!ready) throw StateError('not ready');
    };
    register('resume', ['resume'], matcher: 'resume');
    HookService.I.executorForTest = (cmd, _) async => cmd;
    await SessionLifecycleService.I.sessionStarted(
      session,
      reason: SessionStartReason.restored,
    );
    ready = true;
    await SessionLifecycleService.I.sessionStarted(
      session,
      reason: SessionStartReason.created,
    );
    expect(HookService.I.sessionContextFor(session.id), 'resume');
  });

  test('fresh boot recomputes resume hooks without forging startup', () async {
    register('startup', ['startup'], matcher: 'startup');
    register('resume', ['resume'], matcher: 'resume');
    final calls = <String>[];
    HookService.I.executorForTest = (cmd, _) async {
      calls.add(cmd);
      return cmd;
    };
    await SessionLifecycleService.I.sessionStarted(
      session,
      reason: SessionStartReason.created,
    );
    HookService.I.resetForTest();
    SessionLifecycleService.I.bootTokenProviderForTest = () => 'second-boot';
    HookService.I.executorForTest = (cmd, _) async {
      calls.add(cmd);
      return cmd;
    };
    await SessionLifecycleService.I.sessionStarted(
      session,
      reason: SessionStartReason.restored,
    );
    expect(calls, ['startup', 'resume']);
    expect(HookService.I.sessionContextFor(session.id), 'resume');
  });

  test(
    'permission mode stays unknown unless explicitly supplied by caller',
    () {
      for (final mode in [null, 'plan', 'default']) {
        final input = jsonDecode(
          HookService.buildHookStdinJson(
            canonicalEvent: 'pre_tool',
            sessionId: session.id,
            cwd: session.workspaceFolder!,
            payload: {'permission_mode': ?mode},
          ),
        );
        expect(input['permission_mode'], mode ?? '');
      }
    },
  );

  test(
    '[CC] alias matcher accepts Ovid names without altering stdin name',
    () async {
      register(
        'cc',
        ['cc'],
        event: 'pre_tool',
        matcher: 'Bash|Read|Edit|Write',
      );
      register(
        'codex',
        ['codex'],
        event: 'pre_tool',
        matcher: 'Bash|Read|Edit|Write',
        format: PluginFormat.codex,
      );
      register(
        'native',
        ['native'],
        event: 'pre_tool',
        matcher: 'run_shell|file_read|fs_edit|file_write',
      );
      final calls = <String>[];
      HookService.I.stdinExecutorForTest = (cmd, _, input) async {
        calls.add(cmd);
        expect(
          jsonDecode(input)['tool_name'],
          isIn(['run_shell', 'file_read', 'fs_edit', 'file_write']),
        );
        return (0, '');
      };
      for (final tool in ['run_shell', 'file_read', 'fs_edit', 'file_write']) {
        await HookService.I.fireGate(
          'pre_tool',
          session.id,
          payload: {'tool': tool},
        );
      }
      expect(calls, [
        'cc',
        'native',
        'cc',
        'native',
        'cc',
        'native',
        'cc',
        'native',
      ]);
    },
  );

  test('[CC] fs_edit operations distinguish Read, Write and Edit', () async {
    for (final alias in ['Read', 'Write', 'Edit']) {
      register(alias.toLowerCase(), [alias], event: 'pre_tool', matcher: alias);
    }
    final calls = <String>[];
    HookService.I.executorForTest = (cmd, _) async {
      calls.add(cmd);
      return '';
    };
    for (final operation in ['view', 'create', 'str_replace', 'insert']) {
      await HookService.I.fireGate(
        'pre_tool',
        session.id,
        payload: {
          'tool': 'fs_edit',
          'args': {'command': operation},
        },
      );
    }
    expect(calls, ['Read', 'Write', 'Edit', 'Edit']);
  });

  test(
    'context cap applies after extraction and session end clears without listeners',
    () async {
      register('large', ['large']);
      HookService.I.executorForTest = (_, _) async => jsonEncode({
        'hookSpecificOutput': {'additionalContext': 'c' * 10000},
      });
      await HookService.I.fire('session_start', session.id);
      final context = HookService.I.sessionContextFor(session.id);
      expect(context.length, lessThanOrEqualTo(8192));
      expect(context, startsWith('cccc'));
      await HookService.I.fire('session_end', session.id);
      expect(HookService.I.sessionContextFor(session.id), isEmpty);
    },
  );

  test(
    'prompt context parses independent JSON envelopes before its cap',
    () async {
      register('prompt', ['one', 'two'], event: 'user_prompt_submit');
      HookService.I.executorForTest = (cmd, _) async =>
          jsonEncode({'additionalContext': cmd, 'padding': 'x' * 3000});
      expect(
        await HookService.I.fire('user_prompt_submit', session.id),
        'one\ntwo',
      );
    },
  );

  test('concurrent sessions retain isolated contributions', () async {
    register('parallel', ['context']);
    HookService.I.executorForTest = (_, env) async => env['PLUGIN_SESSION']!;
    await Future.wait([
      HookService.I.fire('session_start', session.id),
      HookService.I.fire('session_start', 'other-session'),
    ]);
    expect(HookService.I.sessionContextFor(session.id), session.id);
    expect(HookService.I.sessionContextFor('other-session'), 'other-session');
  });

  test('session end fences an in-flight start context', () async {
    register('late', ['late']);
    final entered = Completer<void>();
    final release = Completer<String>();
    HookService.I.executorForTest = (_, _) {
      entered.complete();
      return release.future;
    };
    final start = HookService.I.fire('session_start', session.id);
    await entered.future;
    await HookService.I.fire('session_end', session.id);
    release.complete('late context');
    await start;
    expect(HookService.I.sessionContextFor(session.id), isEmpty);
  });

  test(
    'retry honors continue false even after an earlier hook failure',
    () async {
      register('halt', ['flaky', 'halt', 'never']);
      final calls = <String>[];
      var ready = false;
      HookService.I.stdinExecutorForTest = (cmd, _, _) async {
        calls.add(cmd);
        return (
          cmd == 'flaky' && !ready ? 1 : 0,
          cmd == 'halt' ? '{"continue":false}' : cmd,
        );
      };
      await SessionLifecycleService.I.sessionStarted(
        session,
        reason: SessionStartReason.created,
      );
      ready = true;
      await SessionLifecycleService.I.sessionStarted(
        session,
        reason: SessionStartReason.created,
      );
      expect(calls, ['flaky', 'halt', 'flaky']);
    },
  );

  // Host binaries stand in for the installed userland. HookService._exec and
  // SandboxService.spawn, including policy, pipes and process tracking, are real.
  Future<void> provisionHostShell() async {
    final prefix = Directory('${temp.path}/sandbox');
    Directory('${prefix.path}/bin').createSync(recursive: true);
    Directory('${prefix.path}/home').createSync();
    Link('${prefix.path}/bin/bash').createSync('/bin/bash');
    SandboxService.I.sandboxPrefixForTest = prefix;
  }

  test(
    'production spawn accepts approved plugin root and keeps stderr out of JSON',
    () async {
      await provisionHostShell();
      final manifest = register('spawn', [r'bash "$PLUGIN_ROOT/hook.sh"']);
      File('${manifest.rootPath}/hook.sh').writeAsStringSync('''
read -r input
[[ "\$input" == *'"session_id":"w07-session"'* ]] || exit 9
[[ "\$input" == *'"hook_event_name":"SessionStart"'* ]] || exit 9
printf '%s' '{"hookSpecificOutput":{"additionalContext":"from-spawn"}}'
printf '%s' 'diagnostic-only' >&2
''');
      await HookService.I.fire('session_start', session.id);
      expect(HookService.I.sessionContextFor(session.id), 'from-spawn');
      expect(SandboxService.I.liveProcessesForTest, isEmpty);
    },
  );

  test(
    'production spawn can use committed dependency path, not another plugin',
    () async {
      await provisionHostShell();
      final manifest = register('deps', ['placeholder']);
      final dep = File(
        '${Directory(manifest.rootPath).parent.path}/bin/dependency.sh',
      );
      dep.parent.createSync(recursive: true);
      dep.writeAsStringSync('printf dependency-context');
      register('deps', ['bash "${dep.path}"']);
      await HookService.I.fire('session_start', session.id);
      expect(HookService.I.sessionContextFor(session.id), 'dependency-context');
      register('other', ['bash "${dep.path}"']);
      final result = await HookService.I.fireDetailed(
        'session_start',
        session.id,
        onlyPluginId: 'w07/other',
      );
      expect(result.retryableFailure, isTrue);
      expect(result.output, isEmpty);
    },
  );

  test(
    'production gate parses stdout despite stderr and ignores failed JSON decisions',
    () async {
      await provisionHostShell();
      register('gate', [
        "printf '%s' '{\"hookSpecificOutput\":{\"permissionDecision\":\"ask\"}}'; printf warning >&2",
      ], event: 'pre_tool');
      expect(
        (await HookService.I.fireGate('pre_tool', session.id)).decision,
        HookDecision.ask,
      );
      register('gate', [
        "printf '%s' '{\"decision\":\"deny\"}'; exit 1",
      ], event: 'pre_tool');
      expect(
        (await HookService.I.fireGate('pre_tool', session.id)).allowed,
        isTrue,
      );
    },
  );

  test('production spawn denies unrelated absolute paths', () async {
    await provisionHostShell();
    final outside = File('${temp.path}/outside.txt')
      ..writeAsStringSync('outside');
    register('escape', ['bash "${outside.path}"']);
    await HookService.I.fire('session_start', session.id);
    expect(HookService.I.sessionContextFor(session.id), isEmpty);
    expect(HookService.I.failed, 1);
  });

  test(
    'production command-not-found remains retryable after four attempts',
    () async {
      await provisionHostShell();
      register('late-dependency', ['w07_dependency']);
      for (var i = 0; i < 4; i++) {
        await SessionLifecycleService.I.sessionStarted(
          session,
          reason: SessionStartReason.created,
        );
      }
      expect(HookService.I.failed, 4);
      expect(
        HookService.I.isPluginTripped('w07/late-dependency', session.id),
        isFalse,
      );
      final binary = File('${temp.path}/sandbox/bin/w07_dependency');
      binary.writeAsStringSync('#!/bin/bash\nprintf recovered');
      await Process.run('chmod', ['+x', binary.path]);
      await SessionLifecycleService.I.sessionStarted(
        session,
        reason: SessionStartReason.created,
      );
      expect(HookService.I.sessionContextFor(session.id), 'recovered');
    },
  );

  test('missing runtime remains retryable beyond breaker threshold', () async {
    register('missing', ['printf ready']);
    for (var i = 0; i < 4; i++) {
      await SessionLifecycleService.I.sessionStarted(
        session,
        reason: SessionStartReason.created,
      );
    }
    expect(HookService.I.hookBlockerFor('w07/missing'), contains('sandbox'));
    expect(HookService.I.isPluginTripped('w07/missing', session.id), isFalse);
    await provisionHostShell();
    await SessionLifecycleService.I.sessionStarted(
      session,
      reason: SessionStartReason.created,
    );
    expect(HookService.I.sessionContextFor(session.id), 'ready');
  });
}
