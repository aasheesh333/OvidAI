import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/plugin_runtime.dart';

/// Real-world [CC] plugin compatibility, using the shape of `obra/superpowers`
/// (the plugin the user tried to install).
///
/// superpowers' entire mechanism is a `SessionStart` hook that injects the
/// `using-superpowers` skill text as session context. Three Ovid gaps broke it:
///   1. the hook command uses `${CLAUDE_PLUGIN_ROOT}`, which Ovid never set;
///   2. its matcher `startup|clear|compact` matches the session SOURCE, but
///      Ovid matched matchers against a tool name (empty for SessionStart);
///   3. the hook's JSON output (`hookSpecificOutput.additionalContext`) was
///      returned raw and never surfaced as context.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    HookService.I.resetForTest();
  });

  tearDown(() {
    HookService.I.resetForTest();
  });

  NormalizedPluginManifest register(
    List<PluginHook> hooks, {
    String rootPath = '/plugin',
  }) {
    final m = NormalizedPluginManifest(
      id: 'jesse-vincent/superpowers',
      name: 'superpowers',
      version: '6.4.1',
      format: PluginFormat.claudeCode,
      rootPath: rootPath,
      hooks: List.unmodifiable(hooks),
    );
    PluginContributionRegistry.I.register(
      m,
      activation: PluginActivation.sessionActive,
      immediateSessionId: 's1',
    );
    addTearDown(
      () => PluginContributionRegistry.I.unregisterPlugin(m.id),
    );
    return m;
  }

  PluginHook sessionStartHook({String? matcher}) => PluginHook(
    pluginId: 'jesse-vincent/superpowers',
    event: 'session_start',
    ordinal: 0,
    type: 'command',
    payload: '"\${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd" session-start',
    matcher: matcher,
    timeoutS: 5,
  );

  group('SessionStart matcher (CC source semantics)', () {
    test('startup|clear|compact matches a created session', () async {
      var ran = false;
      HookService.I.executorForTest = (cmd, env) async {
        ran = true;
        return 'context';
      };
      register([sessionStartHook(matcher: 'startup|clear|compact')]);

      await HookService.I.fire(
        'session_start',
        's1',
        payload: {'reason': 'created'},
      );
      expect(ran, isTrue, reason: 'created maps to CC source "startup"');
    });

    test('startup|clear|compact does not match a restored session', () async {
      var ran = false;
      HookService.I.executorForTest = (cmd, env) async {
        ran = true;
        return 'context';
      };
      register([sessionStartHook(matcher: 'startup|clear|compact')]);

      await HookService.I.fire(
        'session_start',
        's1',
        payload: {'reason': 'restored'},
      );
      expect(ran, isFalse, reason: 'restored maps to CC source "resume"');
    });

    test('matcher "*" matches every session start', () async {
      var ran = false;
      HookService.I.executorForTest = (cmd, env) async {
        ran = true;
        return 'context';
      };
      register([sessionStartHook(matcher: '*')]);
      await HookService.I.fire(
        'session_start',
        's1',
        payload: {'reason': 'restored'},
      );
      expect(ran, isTrue);
    });
  });

  group('hook environment', () {
    test('CLAUDE_PLUGIN_ROOT is exported and equals the plugin root', () async {
      Map<String, String>? captured;
      HookService.I.executorForTest = (cmd, env) async {
        captured = env;
        return 'ok';
      };
      register([sessionStartHook()], rootPath: '/data/plugins/superpowers');

      await HookService.I.fire(
        'session_start',
        's1',
        payload: {'reason': 'created'},
      );
      expect(captured, isNotNull);
      expect(
        captured!['CLAUDE_PLUGIN_ROOT'],
        '/data/plugins/superpowers',
      );
      expect(captured!['PLUGIN_ROOT'], '/data/plugins/superpowers');
    });
  });

  group('extractHookContext (CC/Cursor/SDK output shapes)', () {
    test('reads hookSpecificOutput.additionalContext (CC)', () {
      final out = jsonEncode({
        'hookSpecificOutput': {
          'hookEventName': 'SessionStart',
          'additionalContext': 'You have superpowers.',
        },
      });
      expect(HookService.extractHookContext(out), 'You have superpowers.');
    });

    test('reads additional_context (Cursor)', () {
      expect(
        HookService.extractHookContext('{"additional_context":"ctx"}'),
        'ctx',
      );
    });

    test('reads top-level additionalContext (SDK)', () {
      expect(
        HookService.extractHookContext('{"additionalContext":"ctx2"}'),
        'ctx2',
      );
    });

    test('falls back to raw text when the output is not JSON', () {
      expect(HookService.extractHookContext('plain context'), 'plain context');
    });

    test('returns empty for a JSON object with no context field', () {
      expect(
        HookService.extractHookContext('{"decision":"allow"}'),
        '',
      );
    });
  });

  group('hook scripts stay executable (install-time)', () {
    test('ensureHookScriptsExecutable sets +x on hooks/ and scripts/', () async {
      final root = Directory.systemTemp.createTempSync('ovid-hook-x-');
      addTearDown(() => root.deleteSync(recursive: true));
      File('${root.path}/hooks/run-hook.cmd')
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/usr/bin/env bash\nexit 0\n');
      File('${root.path}/scripts/tool.sh')
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/usr/bin/env bash\nexit 0\n');

      await PluginRuntimeManager.ensureHookScriptsExecutable(root);

      bool isExec(String p) => (File(p).statSync().mode & 0x49) != 0;
      expect(isExec('${root.path}/hooks/run-hook.cmd'), isTrue);
      expect(isExec('${root.path}/scripts/tool.sh'), isTrue);
    });
  });

  group('session_start context is surfaced for injection', () {
    test('a CC-shaped hook output becomes the session context', () async {
      HookService.I.executorForTest = (cmd, env) async => jsonEncode({
        'hookSpecificOutput': {
          'hookEventName': 'SessionStart',
          'additionalContext': 'You have superpowers.',
        },
      });
      register([sessionStartHook(matcher: 'startup|clear|compact')]);

      await HookService.I.fire(
        'session_start',
        's1',
        payload: {'reason': 'created'},
      );
      expect(
        HookService.I.sessionContextFor('s1'),
        'You have superpowers.',
      );
    });

    test('no session context when the hook produces nothing', () async {
      HookService.I.executorForTest = (cmd, env) async => '';
      register([sessionStartHook()]);
      await HookService.I.fire(
        'session_start',
        's1',
        payload: {'reason': 'created'},
      );
      expect(HookService.I.sessionContextFor('s1'), isEmpty);
    });
  });
}
