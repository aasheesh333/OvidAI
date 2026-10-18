import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/claude_code_tools.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/subagent_tools.dart';
import 'package:ovid_ai/core/tool_usage_store.dart';

/// Master plan Phase 2 items 1-3 (PostToolUse contract, Claude Code tool
/// aliasing, MCP client capabilities) plus the pure subagent-scoping helpers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Claude Code tool aliasing (Phase 2.2)', () {
    test('native → Claude Code names, incl. Write vs Edit on create', () {
      expect(ClaudeCodeTools.ccToolName('run_shell'), 'Bash');
      expect(ClaudeCodeTools.ccToolName('fs_glob'), 'Glob');
      expect(ClaudeCodeTools.ccToolName('fs_grep'), 'Grep');
      expect(ClaudeCodeTools.ccToolName('fetch_url'), 'WebFetch');
      expect(ClaudeCodeTools.ccToolName('web_search'), 'WebSearch');
      expect(ClaudeCodeTools.ccToolName('dispatch_agent'), 'Agent');
      expect(ClaudeCodeTools.ccMatcherNames('dispatch_agent'), [
        'Agent',
        'Task',
      ]);
      expect(
        ClaudeCodeTools.ccToolName('fs_edit', {'command': 'create'}),
        'Write',
      );
      expect(
        ClaudeCodeTools.ccToolName('fs_edit', {'command': 'view'}),
        'Read',
      );
      expect(
        ClaudeCodeTools.ccToolName('fs_edit', {'command': 'str_replace'}),
        'Edit',
      );
      expect(ClaudeCodeTools.ccToolName('mcp__gh__issue'), isNull);
    });

    test(
      'Claude Code names grant native tools (MultiEdit, NotebookEdit, Task)',
      () {
        expect(ClaudeCodeTools.nativeToolsFor('MultiEdit'), {'multi_edit'});
        expect(
          ClaudeCodeTools.nativeToolsFor('NotebookEdit'),
          {'notebook_edit'},
        );
        expect(ClaudeCodeTools.ccToolName('multi_edit'), 'MultiEdit');
        expect(ClaudeCodeTools.ccToolName('notebook_edit'), 'NotebookEdit');
        expect(ClaudeCodeTools.nativeToolsFor('Task'), {'dispatch_agent'});
        expect(ClaudeCodeTools.nativeToolsFor('Glob'), {'fs_glob'});
      },
    );

    test('fs_edit input both ways (tool_input and updatedInput)', () {
      final native = {
        'command': 'str_replace',
        'path': 'a.txt',
        'old_str': 'x',
        'new_str': 'y',
      };
      final cc = ClaudeCodeTools.ccToolInput('fs_edit', native);
      expect(cc['file_path'], 'a.txt');
      expect(cc['old_string'], 'x');
      expect(cc['new_string'], 'y');
      expect(cc['path'], 'a.txt', reason: 'native keys are kept');
      final back = ClaudeCodeTools.nativeToolInput('fs_edit', native, {
        'file_path': 'b.txt',
        'old_string': 'p',
        'new_string': 'q',
        'replace_all': false,
      });
      expect(back, {'path': 'b.txt', 'old_str': 'p', 'new_str': 'q'});
      final create = ClaudeCodeTools.nativeToolInput(
        'fs_edit',
        {'command': 'create', 'path': 'n.txt', 'file_text': ''},
        {'content': 'hello'},
      );
      expect(create, {'file_text': 'hello'});
      expect(
        ClaudeCodeTools.ccToolInput('fs_grep', {
          'pattern': 'x',
          'include': '*.dart',
        })['glob'],
        '*.dart',
      );
    });
  });

  group('subagent tool policy', () {
    SubagentToolPolicy p(List<String> stored) =>
        SubagentToolPolicy.fromStored(stored);

    test('inherit-all, explicit list, CC names and specifiers', () {
      expect(p([]).allows('run_shell'), isTrue);
      expect(p([]).allows('mcp__gh__issue'), isTrue);
      expect(p(['Read', 'Grep']).allows('file_read'), isTrue);
      expect(p(['Read', 'Grep']).allows('run_shell'), isFalse);
      expect(p(['Bash(git status)']).allows('run_shell'), isTrue);
      expect(p(['!Bash(git push *)']).allows('run_shell'), isFalse);
      expect(p(['!Bash']).allows('file_read'), isTrue);
    });

    test('MCP patterns: exact, server, server wildcard, mcp__*', () {
      expect(p(['mcp__gh__issue']).allows('mcp__gh__issue'), isTrue);
      expect(p(['mcp__gh__issue']).allows('mcp__gh__pr'), isFalse);
      expect(p(['mcp__gh']).allows('mcp__gh__pr'), isTrue);
      expect(p(['mcp__gh__*']).allows('mcp__gh__pr'), isTrue);
      expect(p(['mcp__gh__*']).allows('mcp__ghx__pr'), isFalse);
      expect(p(['mcp__gh__*']).allows('file_read'), isFalse);
      expect(p(['!mcp__*']).allows('mcp__gh__pr'), isFalse);
      expect(p(['!mcp__*']).allows('file_read'), isTrue);
    });

    test('spawn tools are removed whatever the list says', () {
      for (final stored in [
        <String>[],
        ['*'],
        ['dispatch_agent', 'Agent', 'Task', 'workflow', 'ralph'],
      ]) {
        for (final spawn in ['dispatch_agent', 'workflow', 'ralph']) {
          expect(p(stored).allows(spawn), isFalse, reason: '$stored $spawn');
        }
        expect(
          p(stored).allows('plugin__x__agent', isAgentContribution: true),
          isFalse,
        );
      }
    });

    test('frontmatter lists and model resolution', () {
      expect(parseFrontmatterList('Read, Grep, Bash(git push *)'), [
        'Read',
        'Grep',
        'Bash(git push *)',
      ]);
      expect(parseFrontmatterList('a\nb'), ['a', 'b']);
      expect(parseFrontmatterList('Read Grep'), ['Read', 'Grep']);
      expect(resolveSubagentModel('inherit', parentModel: 'm'), isNull);
      expect(resolveSubagentModel(null, parentModel: 'm'), isNull);
      expect(resolveSubagentModel('gpt-x', parentModel: 'm'), 'gpt-x');
      expect(
        resolveSubagentModel(
          'haiku',
          parentModel: 'claude-sonnet',
          providerModels: ['claude-haiku-4', 'claude-sonnet'],
        ),
        'claude-haiku-4',
      );
      expect(
        resolveSubagentModel('opus', parentModel: 'llama', providerModels: []),
        isNull,
        reason: 'an alias the provider lacks inherits instead',
      );
    });
  });

  group('hooks (Phase 2.1 + 2.2)', () {
    const pid = 'acme/post';
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AppState.resetTestInstance();
      AppState.createForTest();
      HookService.I.resetForTest();
    });
    tearDown(() {
      HookService.I.resetForTest();
      PluginContributionRegistry.I.unregisterPlugin(pid);
      AppState.resetTestInstance();
    });

    void register(String event, {String? matcher, int count = 1}) {
      PluginContributionRegistry.I.register(
        NormalizedPluginManifest(
          id: pid,
          name: 'post',
          version: '1',
          format: PluginFormat.claudeCode,
          rootPath: '/plugin',
          hooks: [
            for (var i = 0; i < count; i++)
              PluginHook(
                pluginId: pid,
                event: event,
                ordinal: i,
                type: 'command',
                payload: 'h$i',
                matcher: matcher,
              ),
          ],
        ),
        activation: PluginActivation.sessionActive,
        immediateSessionId: 's1',
      );
    }

    test(
      'PostToolUse gets full tool_input and the untruncated tool_response',
      () async {
        register('post_tool', matcher: 'Edit');
        final big = 'R' * 20000;
        Map<String, dynamic>? stdin;
        String? envPayload;
        HookService.I.stdinExecutorForTest = (cmd, env, input) async {
          stdin = jsonDecode(input) as Map<String, dynamic>;
          envPayload = env['PLUGIN_PAYLOAD'];
          return (0, '');
        };
        final res = await HookService.I.firePostTool(
          's1',
          payload: {
            'tool': 'fs_edit',
            'args': {
              'command': 'str_replace',
              'path': 'a.txt',
              'old_str': 'x',
              'new_str': 'y',
            },
            'tool_response': big,
            'duration_ms': 12,
          },
        );
        expect(res.isEmpty, isTrue);
        expect(stdin!['tool_name'], 'Edit');
        expect(stdin!['tool_input']['file_path'], 'a.txt');
        expect(stdin!['tool_input']['old_string'], 'x');
        expect((stdin!['tool_response'] as String).length, 20000);
        expect(stdin!['duration_ms'], 12);
        if (envPayload != null) {
          expect(
            envPayload!.length,
            lessThan(10000),
            reason: 'env copy is bounded',
          );
        }
      },
    );

    test(
      'decision:block, exit 2, additionalContext and updatedToolOutput',
      () async {
        register('post_tool', count: 3);
        HookService.I.stdinExecutorForTest = (cmd, env, input) async {
          switch (cmd) {
            case 'h0':
              return (
                0,
                jsonEncode({
                  'decision': 'block',
                  'reason': 'lint failed',
                  'hookSpecificOutput': {
                    'hookEventName': 'PostToolUse',
                    'additionalContext': 'run the linter',
                  },
                }),
              );
            case 'h1':
              return (2, 'stderr feedback');
            default:
              return (
                0,
                jsonEncode({
                  'hookSpecificOutput': {
                    'hookEventName': 'PostToolUse',
                    'updatedToolOutput': 'REPLACED',
                  },
                }),
              );
          }
        };
        final res = await HookService.I.firePostTool(
          's1',
          payload: {
            'tool': 'run_shell',
            'args': {'command': 'ls'},
            'tool_response': 'orig',
          },
        );
        expect(res.blockReasons, ['lint failed']);
        expect(res.feedback, ['stderr feedback']);
        expect(res.additionalContext, ['run the linter']);
        final applied = res.apply('orig');
        expect(applied, startsWith('REPLACED'));
        expect(applied, contains('lint failed'));
        expect(applied, contains('stderr feedback'));
        expect(applied, contains('run the linter'));
      },
    );

    test('PostToolUse is awaited by the agent dispatch', () async {
      register('post_tool', matcher: 'list_agents');
      final session = ChatSession(id: 's1', title: 'S', model: 'm');
      AppState.I.sessions.add(session);
      AgentService.setRunSessionForTest('s1');
      addTearDown(() => AgentService.setRunSessionForTest(''));
      HookService.I.stdinExecutorForTest = (cmd, env, input) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return (2, 'late but awaited');
      };
      final res = await AgentService.I.dispatchForTest('list_agents', {});
      expect(res, contains('late but awaited'));
    });

    test(
      'a [CC] PreToolUse updatedInput is translated back to native args',
      () async {
        register('pre_tool', matcher: 'Edit');
        Map<String, dynamic>? stdin;
        HookService.I.gateExecutorForTest = null;
        HookService.I.stdinExecutorForTest = (cmd, env, input) async {
          stdin = jsonDecode(input) as Map<String, dynamic>;
          return (
            0,
            jsonEncode({
              'hookSpecificOutput': {
                'hookEventName': 'PreToolUse',
                'permissionDecision': 'allow',
                'updatedInput': {
                  'file_path': 'b.txt',
                  'old_string': 'p',
                  'new_string': 'q',
                },
              },
            }),
          );
        };
        final gate = await HookService.I.fireGate(
          'pre_tool',
          's1',
          payload: {
            'tool': 'fs_edit',
            'args': {
              'command': 'str_replace',
              'path': 'a.txt',
              'old_str': 'x',
              'new_str': 'y',
            },
          },
        );
        expect(stdin!['tool_name'], 'Edit');
        expect(stdin!['tool_input']['file_path'], 'a.txt');
        expect(gate.updatedInput, {
          'path': 'b.txt',
          'old_str': 'p',
          'new_str': 'q',
        });
      },
    );

    test('a Task matcher catches dispatch_agent', () {
      expect(
        HookService.matcherAppliesForTest('pre_tool', 'Task', {'tool': 'Task'}),
        isTrue,
      );
    });
  });

  group('tool usage attribution', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      ToolUsageStore.I.resetForTest();
      ToolUsageStore.saveDelayForTest = Duration.zero;
    });

    test('calls inside a SubagentScope are attributed to its agent_type', () {
      const scope = SubagentScope(
        agentId: 'sub-1',
        agentType: 'acme:reviewer',
        sessionId: 'c',
        rootSessionId: 'r',
      );
      scope.run(
        () => ToolUsageStore.I.record(
          kind: ToolUsageKind.mcp,
          tool: 'ping',
          mcpServerId: 'probe',
          ok: true,
          elapsed: const Duration(milliseconds: 3),
        ),
      );
      ToolUsageStore.I.record(
        kind: ToolUsageKind.mcp,
        tool: 'ping',
        mcpServerId: 'probe',
        ok: true,
        elapsed: const Duration(milliseconds: 3),
      );
      expect(ToolUsageStore.I.summary(mcpServerId: 'probe').calls, 2);
      expect(ToolUsageStore.I.agentCalls(mcpServerId: 'probe'), {
        'acme:reviewer': 1,
      });
    });
  });


}
