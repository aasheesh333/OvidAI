import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/session_lifecycle_service.dart';
import 'package:ovid_ai/core/skills.dart';
import 'package:ovid_ai/core/state.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Claude Code subagent parity (owner requirement): a subagent works with the
/// session's plugins' hooks, skills and MCP — scoped by its definition — and
/// can never trigger another subagent.
class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.directory);

  final Directory directory;

  @override
  Future<String?> getApplicationDocumentsPath() async => directory.path;

  @override
  Future<String?> getApplicationSupportPath() async => directory.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final agent = AgentService.I;
  late AppState app;
  late ChatSession root;
  final requests = <String>[];
  late Directory documents;
  late PathProviderPlatform originalPaths;

  Future<void> until(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail('condition did not settle');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  List<String> rosterNames() => agent
      .toolsForTest()
      .map((t) => (t['function'] as Map)['name'] as String)
      .toList();

  const pid = 'acme/parity';
  void registerHooks(List<PluginHook> hooks) {
    PluginContributionRegistry.I.register(
      NormalizedPluginManifest(
        id: pid,
        name: 'parity',
        version: '1',
        format: PluginFormat.claudeCode,
        rootPath: '/plugin',
        hooks: hooks,
      ),
      activation: PluginActivation.sessionActive,
      immediateSessionId: root.id,
    );
    addTearDown(() => PluginContributionRegistry.I.unregisterPlugin(pid));
  }

  PluginHook hook(String event, String payload, {String? matcher, int n = 0}) =>
      PluginHook(
        pluginId: pid,
        event: event,
        ordinal: n,
        type: 'command',
        payload: payload,
        matcher: matcher,
      );

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('cc-subagent-parity-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(documents);
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    app = AppState.createForTest();
    agent.debugPauseScheduleTimerForTest(true);
    HookService.I.resetForTest();
    SessionLifecycleService.I.resetForTest();
    SessionLifecycleService.I.activationWaiterForTest = (_) async {};
    AgentService.skillCatalogInputsForTest = (_) async => SkillCatalogInputs();
    root = ChatSession(
      id: 'cc-root',
      title: 'Root',
      model: 'test-model',
      providerId: 'ollama-local',
    );
    app.sessions.add(root);
    app.activeSessionId = root.id;
    AgentService.setRunSessionForTest('');
    requests.clear();
    AgentService.llmOnceForTest = (p, msgs, session, tools) async {
      final prompt = session.messages
          .lastWhere((m) => m.role == 'user')
          .content;
      requests.add(prompt);
      agent.streamToBubbleForTest(session, 'answer:$prompt');
      return {'content': 'answer:$prompt', 'finish_reason': 'stop'};
    };
  });

  tearDown(() async {
    await until(() => agent.subagentsOf(root.id).every((s) => s.finished));
    for (final s in List.of(app.sessions)) {
      for (final sub in agent.subagentsOf(s.id)) {
        agent.removeSubagentForTest(sub.id);
      }
    }
    AgentService.llmOnceForTest = null;
    AgentService.skillCatalogInputsForTest = null;
    AgentService.setRunSessionForTest('');
    HookService.I.resetForTest();
    SessionLifecycleService.I.resetForTest();
    agent.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
    PathProviderPlatform.instance = originalPaths;
    await documents.delete(recursive: true);
  });

  Future<String> dispatch(Map<String, dynamic> args) =>
      agent.dispatchForTest('dispatch_agent', args);

  ChatSession childOf(ChatSession parent) => app.childrenOf(parent.id).single;

  group('tool scoping', () {
    test(
      'a `tools` list restricts the child roster; spawn tools never show',
      () {
        final child = app.createSubagentSession(
          parent: root,
          label: 'reader',
          mode: 'auto',
          allowedTools: ['Read', 'Grep', 'Agent', 'dispatch_agent'],
        );
        AgentService.setRunSessionForTest(child.id);
        final names = rosterNames();
        expect(names, containsAll(['file_read', 'fs_grep']));
        expect(names, isNot(contains('run_shell')));
        expect(names, isNot(contains('file_write')));
        // Listed explicitly, still removed: a subagent cannot spawn.
        expect(names, isNot(contains('dispatch_agent')));
      },
    );

    test(
      'omitted `tools` inherits everything except spawn/user-facing tools',
      () {
        final child = app.createSubagentSession(
          parent: root,
          label: 'general',
          mode: 'auto',
        );
        AgentService.setRunSessionForTest(child.id);
        final names = rosterNames();
        expect(names, containsAll(['run_shell', 'file_read', 'fs_edit']));
        for (final spawn in ['dispatch_agent', 'workflow', 'ralph']) {
          expect(names, isNot(contains(spawn)));
        }
        expect(names, isNot(contains('ask_user_question')));
        AgentService.setRunSessionForTest(root.id);
        expect(rosterNames(), contains('dispatch_agent'));
      },
    );

    test('disallowedTools removes a tool from an inherited roster', () {
      final child = app.createSubagentSession(
        parent: root,
        label: 'no-shell',
        mode: 'auto',
        allowedTools: ['!Bash(git push *)'],
      );
      AgentService.setRunSessionForTest(child.id);
      final names = rosterNames();
      expect(names, isNot(contains('run_shell')));
      expect(names, contains('file_read'));
    });
  });

  group('no nesting', () {
    test('runtime rejects every spawn path from inside a subagent', () async {
      final child = app.createSubagentSession(
        parent: root,
        label: 'leaf',
        mode: 'auto',
      );
      AgentService.setRunSessionForTest(child.id);
      for (final tool in ['dispatch_agent', 'workflow', 'ralph']) {
        final res = await agent.dispatchForTest(tool, {
          'prompt': 'spawn',
          'name': 'x',
          'phases': '[]',
          'task': 'x',
        });
        expect(res, contains('SUBAGENT'), reason: tool);
        expect(res.toLowerCase(), contains('subagent'), reason: tool);
      }
      expect(app.childrenOf(child.id), isEmpty);
    });
  });

  group('hooks inside a subagent', () {
    test('PreToolUse/PostToolUse fire for the child with subagent identity; '
        'Stop does not fire for the child', () async {
      final stdins = <String, List<Map<String, dynamic>>>{};
      registerHooks([
        hook('pre_tool', 'pre', matcher: 'Glob'),
        hook('post_tool', 'post', matcher: 'list_agents', n: 1),
        hook('stop', 'stop', n: 2),
        hook('subagent_end', 'substop', n: 3),
      ]);
      HookService.I.stdinExecutorForTest = (cmd, env, stdin) async {
        (stdins[cmd] ??= []).add(jsonDecode(stdin) as Map<String, dynamic>);
        if (cmd == 'post') {
          return (
            0,
            jsonEncode({
              'decision': 'block',
              'reason': 'post-hook says check again',
              'hookSpecificOutput': {
                'hookEventName': 'PostToolUse',
                'additionalContext': 'ctx-from-post',
              },
            }),
          );
        }
        return (0, '');
      };
      String? listResult;
      AgentService.llmOnceForTest = (p, msgs, session, tools) async {
        if (session.isSubagent) {
          await agent.dispatchForTest('fs_glob', {'pattern': '*.md'});
          listResult = await agent.dispatchForTest('list_agents', {});
        }
        agent.streamToBubbleForTest(session, 'done');
        return {'content': 'done', 'finish_reason': 'stop'};
      };
      await dispatch({'prompt': 'work', 'label': 'worker'});
      final child = childOf(root);
      final sub = agent.subagentForSession(child.id)!;

      final pre = stdins['pre']!.single;
      expect(pre['hook_event_name'], 'PreToolUse');
      expect(pre['tool_name'], 'Glob'); // Claude Code name (Phase 2.2)
      expect(pre['tool_input']['pattern'], '*.md');
      expect(pre['agent_id'], sub.id);
      expect(pre['agent_type'], 'general-purpose');
      expect(pre['session_id'], root.id, reason: 'main session id');
      expect(pre['ovid_session_id'], child.id);

      final post = stdins['post']!.single;
      expect(post['hook_event_name'], 'PostToolUse');
      expect(post['agent_id'], sub.id);
      expect(post['tool_response'], contains('No subagents'));
      // PostToolUse was awaited and its contract applied to the result.
      expect(listResult, contains('post-hook says check again'));
      expect(listResult, contains('ctx-from-post'));

      expect(stdins['stop'], isNull, reason: 'Stop is main-agent only');
      final stop = stdins['substop']!.single;
      expect(stop['hook_event_name'], 'SubagentStop');
      expect(stop['agent_id'], sub.id);
      expect(stop['agent_type'], 'general-purpose');
      expect(stop['last_assistant_message'], 'done');
      expect(stop['stop_hook_active'], false);
      expect(stop['session_id'], root.id);
      expect(stop.containsKey('agent_transcript_path'), isTrue);
    });

    test('SubagentStop JSON decision:block keeps the child working', () async {
      registerHooks([hook('subagent_end', 'gate')]);
      var calls = 0;
      final active = <Object?>[];
      HookService.I.stdinExecutorForTest = (cmd, env, stdin) async {
        calls++;
        active.add((jsonDecode(stdin) as Map)['stop_hook_active']);
        return calls == 1
            ? (0, jsonEncode({'decision': 'block', 'reason': 'add tests'}))
            : (0, jsonEncode({'decision': 'approve'}));
      };
      final res = await dispatch({'prompt': 'initial', 'label': 'w'});
      expect(requests, ['initial', 'add tests']);
      expect(active, [false, true]);
      expect(res, contains('answer:add tests'));
    });

    test('SubagentStart/SubagentStop matchers filter on agent_type', () async {
      final fired = <String>[];
      registerHooks([
        hook('subagent_start', 'start-match', matcher: 'general-purpose'),
        hook('subagent_start', 'start-miss', matcher: 'db-agent', n: 1),
      ]);
      HookService.I.stdinExecutorForTest = (cmd, env, stdin) async {
        fired.add(cmd);
        return (
          0,
          jsonEncode({
            'hookSpecificOutput': {
              'hookEventName': 'SubagentStart',
              'additionalContext': 'START-CTX',
            },
          }),
        );
      };
      await dispatch({'prompt': 'go', 'label': 'w'});
      expect(fired, ['start-match']);
      final sub = agent.subagentForSession(childOf(root).id)!;
      expect(sub.startContext, 'START-CTX');
    });
  });

  group('skills and definitions', () {
    test(
      'subagent_type runs a definition: tools, preloaded skills, model',
      () async {
        final skills = Directory('${documents.path}/catalog')..createSync();
        Directory('${skills.path}/helper').createSync();
        File('${skills.path}/helper/SKILL.md').writeAsStringSync(
          '---\nname: helper\ndescription: helps\n---\nHELPER SKILL BODY\n',
        );
        Directory('${skills.path}/agents').createSync();
        File('${skills.path}/agents/reviewer.md').writeAsStringSync(
          '---\nname: reviewer\ndescription: reviews code\n'
          'tools: Read, Grep\nskills: helper\nmodel: inherit\n---\n'
          'You are a meticulous reviewer.\n',
        );
        await SkillService.I.publishSessionCatalog(
          root.id,
          roots: [skills.path],
        );
        List<String>? childRoster;
        AgentService.llmOnceForTest = (p, msgs, session, tools) async {
          if (session.isSubagent) childRoster = rosterNames();
          agent.streamToBubbleForTest(session, 'reviewed');
          return {'content': 'reviewed', 'finish_reason': 'stop'};
        };
        final res = await dispatch({
          'prompt': 'review it',
          'subagent_type': 'reviewer',
        });
        expect(res, contains('reviewed'));
        final child = childOf(root);
        expect(child.agentAllowedTools, ['Read', 'Grep']);
        expect(child.agentPersona, contains('meticulous reviewer'));
        expect(child.agentPersona, contains('HELPER SKILL BODY'));
        expect(child.model, root.model, reason: 'model: inherit');
        expect(agent.subagentForSession(child.id)!.agentType, 'reviewer');
        expect(childRoster, containsAll(['file_read', 'fs_grep']));
        expect(childRoster, isNot(contains('run_shell')));
        expect(childRoster, isNot(contains('dispatch_agent')));

        expect(
          await dispatch({'prompt': 'x', 'subagent_type': 'nope'}),
          contains('Unknown subagent_type'),
        );
      },
    );
  });

}
