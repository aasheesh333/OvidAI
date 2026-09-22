import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';

/// Hook stdin JSON (spec item 1): every hook child receives the full event
/// payload as JSON on stdin, exactly like Claude Code (`json.load(sys.stdin)`).
///
/// The production `_exec` path writes these bytes through
/// `SandboxService.spawn`'s stdin pipe, but `spawn` needs the provisioned
/// sandbox userland, which `flutter test` does not have — so these tests pin
/// the contract one layer up, through the [HookService.stdinExecutorForTest]
/// seam, which receives the exact bytes `_exec` would write.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => HookService.I.resetForTest());
  tearDown(() => HookService.I.resetForTest());

  NormalizedPluginManifest register(List<PluginHook> hooks) {
    final m = NormalizedPluginManifest(
      id: 'acme/stdin-probe',
      name: 'stdin-probe',
      version: '1.0.0',
      format: PluginFormat.claudeCode,
      rootPath: '/plugin',
      hooks: List.unmodifiable(hooks),
    );
    PluginContributionRegistry.I.register(
      m,
      activation: PluginActivation.sessionActive,
      immediateSessionId: 's1',
    );
    addTearDown(() => PluginContributionRegistry.I.unregisterPlugin(m.id));
    return m;
  }

  PluginHook preToolHook() => PluginHook(
    pluginId: 'acme/stdin-probe',
    event: 'pre_tool',
    ordinal: 0,
    type: 'command',
    // In production this command reads stdin (`cat` echoes it); in tests
    // the seam below stands in for the process.
    payload: 'cat',
    timeoutS: 5,
  );

  group('buildHookStdinJson: exact key contract', () {
    test('pre_tool emits the exact Claude Code key set', () {
      final raw = HookService.buildHookStdinJson(
        canonicalEvent: 'pre_tool',
        sessionId: 's1',
        payload: {
          'tool': 'Bash',
          'tool_input': {'command': 'ls'},
          'permission_mode': 'default',
        },
        cwd: '/work',
      );
      final j = jsonDecode(raw) as Map<String, dynamic>;
      expect(j['session_id'], 's1');
      expect(j['transcript_path'], '');
      expect(j['cwd'], '/work');
      expect(j['permission_mode'], 'default');
      expect(j['hook_event_name'], 'PreToolUse');
      expect(j['tool_name'], 'Bash');
      expect(j['tool_input'], {'command': 'ls'});
      // Absent optionals are omitted, not null.
      expect(j.containsKey('tool_response'), isFalse);
      expect(j.containsKey('prompt'), isFalse);
      expect(j.containsKey('reason'), isFalse);
      expect(
        j.keys.toSet(),
        {
          'session_id',
          'transcript_path',
          'cwd',
          'permission_mode',
          'hook_event_name',
          'tool_name',
          'tool_input',
        },
        reason: 'no extra keys leak into the stdin contract',
      );
    });

    test('transcript_path flows from the payload when the caller supplies it',
        () {
      final raw = HookService.buildHookStdinJson(
        canonicalEvent: 'stop',
        sessionId: 's1',
        payload: {'transcript_path': '/tmp/t.jsonl'},
        cwd: '/work',
      );
      final j = jsonDecode(raw) as Map<String, dynamic>;
      expect(j['transcript_path'], '/tmp/t.jsonl');
      expect(j['hook_event_name'], 'Stop');
    });

    test('user_prompt_submit carries prompt, not tool keys', () {
      final raw = HookService.buildHookStdinJson(
        canonicalEvent: 'user_prompt_submit',
        sessionId: 's1',
        payload: {'prompt': 'hello'},
        cwd: '/work',
      );
      final j = jsonDecode(raw) as Map<String, dynamic>;
      expect(j['hook_event_name'], 'UserPromptSubmit');
      expect(j['prompt'], 'hello');
      expect(j.containsKey('tool_name'), isFalse);
    });
  });

  group('fireDetailed delivers the stdin JSON to hook children', () {
    test('pre_tool hook receives session_id, event name, tool context',
        () async {
      String? seen;
      HookService.I.stdinExecutorForTest = (cmd, env, stdinJson) async {
        seen = stdinJson;
        return (0, '{}');
      };
      register([preToolHook()]);

      await HookService.I.fireDetailed(
        'pre_tool',
        's1',
        payload: {
          'tool': 'Bash',
          'tool_input': {'command': 'echo hi'},
        },
      );

      expect(seen, isNotNull, reason: 'hook must receive stdin bytes');
      final j = jsonDecode(seen!) as Map<String, dynamic>;
      expect(j['session_id'], 's1');
      expect(j['hook_event_name'], 'PreToolUse');
      expect(j['tool_name'], 'Bash');
      expect(j['tool_input'], {'command': 'echo hi'});
      expect(j['cwd'], isNotEmpty);
    });

    test('secret values are redacted in the stdin JSON', () async {
      String? seen;
      HookService.I.stdinExecutorForTest = (cmd, env, stdinJson) async {
        seen = stdinJson;
        return (0, '{}');
      };
      register([preToolHook()]);

      await HookService.I.fireDetailed(
        'pre_tool',
        's1',
        payload: {
          'tool': 'Bash',
          'tool_input': {'command': 'deploy', 'api_key': 'sk-live-secret'},
        },
      );

      final j = jsonDecode(seen!) as Map<String, dynamic>;
      expect(
        (j['tool_input'] as Map)['api_key'],
        isNot('sk-live-secret'),
        reason: 'stdin JSON uses the same redaction as the env payload',
      );
      expect((j['tool_input'] as Map)['command'], 'deploy');
    });
  });

  group('fireGate delivers the stdin JSON to gate hooks', () {
    test('pre_tool gate hook receives the stdin JSON', () async {
      String? seen;
      HookService.I.stdinExecutorForTest = (cmd, env, stdinJson) async {
        seen = stdinJson;
        return (0, '{}');
      };
      register([preToolHook()]);

      final gate = await HookService.I.fireGate(
        'pre_tool',
        's1',
        payload: {
          'tool': 'Bash',
          'tool_input': {'command': 'ls'},
        },
      );

      expect(gate.allowed, isTrue);
      expect(seen, isNotNull);
      final j = jsonDecode(seen!) as Map<String, dynamic>;
      expect(j['hook_event_name'], 'PreToolUse');
      expect(j['tool_name'], 'Bash');
      expect(j['tool_input'], {'command': 'ls'});
    });
  });
}
