import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/claude_code_tools.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/mcp_client_requests.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/subagent_tools.dart';
import 'package:ovid_ai/core/tool_usage_store.dart';
import 'package:ovid_ai/ui/mcp_elicitation_sheet.dart';

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
        expect(ClaudeCodeTools.nativeToolsFor('MultiEdit'), {'fs_edit'});
        expect(
          ClaudeCodeTools.nativeToolsFor('NotebookEdit'),
          containsAll(['fs_edit', 'file_write']),
        );
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

  group('MCP client capabilities (Phase 2.3)', () {
    final client = McpClientRequests.I;
    setUp(client.resetForTest);
    tearDown(client.resetForTest);

    Future<Map<String, dynamic>> req(String method, [Map? params]) =>
        client.handle('srv', {
          'jsonrpc': '2.0',
          'id': 7,
          'method': method,
          'params': ?params,
        });

    test('initialize advertises capabilities and protocol 2025-06-18', () {
      final p = McpClientRequests.initializeParams();
      expect(p['protocolVersion'], '2025-06-18');
      expect(
        (p['capabilities'] as Map).keys,
        containsAll(['roots', 'sampling', 'elicitation']),
      );
    });

    test('ping, roots/list and unknown methods', () async {
      expect(await req('ping'), {'jsonrpc': '2.0', 'id': 7, 'result': {}});
      client.rootsProvider = (_) => [McpRoot.directory('/work/app', name: 'w')];
      final roots = await req('roots/list');
      expect(roots['result']['roots'], [
        {'uri': 'file:///work/app/', 'name': 'w'},
      ]);
      final unknown = await req('nope/x');
      expect(unknown['error']['code'], McpClientRequests.methodNotFound);
    });

    test('sampling requires approval; rejection uses the spec error', () async {
      final params = {
        'messages': [
          {
            'role': 'user',
            'content': {'type': 'text', 'text': 'hi'},
          },
        ],
        'maxTokens': 50,
      };
      expect(
        (await req('sampling/createMessage', params))['error']['code'],
        McpClientRequests.userRejected,
      );
      McpSamplingRequest? seen;
      client.samplingApprover = (r) async {
        seen = r;
        return false;
      };
      client.sampler = (r) async => {'role': 'assistant'};
      expect(
        (await req('sampling/createMessage', params))['error']['code'],
        McpClientRequests.userRejected,
      );
      expect(seen!.preview, contains('hi'));
      client.samplingApprover = (_) async => true;
      client.sampler = (r) async => {
        'role': 'assistant',
        'content': {'type': 'text', 'text': 'answer'},
        'model': 'm',
        'stopReason': 'endTurn',
      };
      final ok = await req('sampling/createMessage', params);
      expect(ok['result']['content']['text'], 'answer');
    });

    test('elicitation: no UI cancels, accept is validated', () async {
      final params = {
        'message': 'Your name?',
        'requestedSchema': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'age': {'type': 'integer'},
          },
          'required': ['name'],
        },
      };
      expect((await req('elicitation/create', params))['result'], {
        'action': 'cancel',
      });
      client.elicitor = (r) async =>
          const McpElicitationResponse.accept({'name': 'Ada', 'age': '36'});
      expect((await req('elicitation/create', params))['result'], {
        'action': 'accept',
        'content': {'name': 'Ada', 'age': 36},
      });
      client.elicitor = (r) async =>
          const McpElicitationResponse.accept({'age': '36'});
      expect(
        (await req('elicitation/create', params))['result']['action'],
        'cancel',
        reason: 'missing required field',
      );
      client.elicitor = (r) async => const McpElicitationResponse.decline();
      expect((await req('elicitation/create', params))['result'], {
        'action': 'decline',
      });
    });

    test('progress and logging notifications are recorded', () {
      client.handleNotification('srv', {
        'method': 'notifications/progress',
        'params': {'progressToken': 't1', 'progress': 3, 'total': 10},
      });
      client.handleNotification('srv', {
        'method': 'notifications/message',
        'params': {'level': 'warning', 'data': 'disk low'},
      });
      expect(client.progressFor('srv', 't1')!.progress, 3);
      expect(client.logsFor('srv').single.level, 'warning');
    });

    test('HTTP: a server request sharing our id is answered, not mistaken '
        'for the response', () async {
      SharedPreferences.setMockInitialValues({});
      AppState.resetTestInstance();
      final app = AppState.createForTest();
      addTearDown(AppState.resetTestInstance);
      final server = McpServer(
        name: 'srv',
        author: 't',
        description: 'd',
        category: 'Custom',
        command: '',
        custom: true,
        transport: 'http',
        url: 'https://mcp.test/rpc',
      );
      app.mcpServers.add(server);
      final posted = <Map<String, dynamic>>[];
      Map<String, dynamic>? initParams;
      McpService.I.httpClientForTest = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        posted.add(body);
        final method = body['method'];
        if (method == 'initialize') initParams = body['params'];
        if (method == 'tools/call') {
          final id = body['id'];
          final sse =
              'event: message\ndata: ${jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': 'ping'})}\n\n'
              'event: message\ndata: ${jsonEncode({
                'jsonrpc': '2.0',
                'id': id,
                'result': {
                  'content': [
                    {'type': 'text', 'text': 'REAL RESULT'},
                  ],
                },
              })}\n\n';
          return http.Response(
            sse,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        if (method == null) return http.Response('', 202);
        final result = switch (method) {
          'initialize' => {
            'protocolVersion': '2025-06-18',
            'capabilities': {'tools': {}},
          },
          'tools/list' => {
            'tools': [
              {
                'name': 'echo',
                'inputSchema': {'type': 'object', 'properties': {}},
              },
            ],
          },
          _ => <String, dynamic>{},
        };
        return http.Response(
          jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}),
          200,
        );
      });
      addTearDown(() async {
        await McpService.I.disconnect('srv');
        McpService.I.httpClientForTest = null;
      });
      expect(await McpService.I.connect(server), contains('connected'));
      expect(initParams!['protocolVersion'], '2025-06-18');
      expect(
        (initParams!['capabilities'] as Map).keys,
        containsAll(['roots', 'sampling', 'elicitation']),
      );
      final out = await McpService.I.callTool('srv', 'echo', {});
      expect(out, contains('REAL RESULT'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final pong = posted.where(
        (m) => m['method'] == null && m.containsKey('result'),
      );
      expect(pong, isNotEmpty, reason: 'ping answered over HTTP');
      expect(pong.first['result'], {});
    });

    test('AgentService asks before sampling, even in Full Access', () async {
      SharedPreferences.setMockInitialValues({});
      AppState.resetTestInstance();
      final app = AppState.createForTest();
      addTearDown(AppState.resetTestInstance);
      final s = ChatSession(
        id: 'samp',
        title: 'S',
        model: 'm',
        mode: 'drive',
        providerId: 'ollama-local',
      );
      app.sessions.add(s);
      app.activeSessionId = s.id;
      final agent = AgentService.I;
      // The constructor wires the client; re-wire after resetForTest.
      client.samplingApprover = (r) => agent.approveMcpSamplingForTest(r);
      client.sampler = (r) => agent.runMcpSamplingForTest(r);
      AgentService.promptLlmForTest = (p, msgs, session) async => {
        'content': 'sampled:${msgs.last['content']}',
      };
      addTearDown(() {
        AgentService.promptLlmForTest = null;
        agent.pendingApproval = null;
      });
      final pending = req('sampling/createMessage', {
        'messages': [
          {
            'role': 'user',
            'content': {'type': 'text', 'text': 'q'},
          },
        ],
        'maxTokens': 10,
      });
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (agent.pendingApproval == null &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(agent.pendingApproval?.tool, 'mcp_sampling');
      agent.pendingApproval!.completer.complete(true);
      final res = await pending;
      expect(res['result']['content']['text'], 'sampled:q');
    });
  });

  testWidgets('elicitation sheet returns the entered values', (tester) async {
    final request = McpElicitationRequest.parse('srv', {
      'message': 'Pick a name',
      'requestedSchema': {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'title': 'Name'},
          'agree': {'type': 'boolean'},
        },
        'required': ['name'],
      },
    })!;
    McpElicitationResponse? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                result = await showMcpElicitationSheet(context, request),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Pick a name'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('mcp-elicitation-name')),
      'Ada',
    );
    await tester.tap(find.byKey(const Key('mcp-elicitation-agree')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('mcp-elicitation-accept')));
    await tester.pumpAndSettle();
    expect(result!.action, 'accept');
    expect(result!.validated(request).content, {'name': 'Ada', 'agree': true});
  });
}
