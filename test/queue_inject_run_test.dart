import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/session_lifecycle_service.dart';
import 'package:ovid_ai/core/skills.dart';
import 'package:ovid_ai/core/state.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Owner bug: sending while the agent runs queued the message and the agent
/// STOPPED. Required (Claude Code parity): queueing never stops the run; the
/// queued message(s) join the running loop at the next model request (after
/// the current tool results), show in the transcript there and leave the
/// queue. Stop/quick-send on a queued row is the only path that interrupts.
class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.directory);
  final Directory directory;
  @override
  Future<String?> getApplicationDocumentsPath() async => directory.path;
  @override
  Future<String?> getApplicationSupportPath() async => directory.path;
}

Map<String, dynamic> _toolCall(String id) => {
  'role': 'assistant',
  'content': '',
  'tool_calls': [
    {
      'id': id,
      'type': 'function',
      'function': {'name': 'todo_write', 'arguments': '{"todos":[]}'},
    },
  ],
  'finish_reason': 'tool_calls',
};

Map<String, dynamic> _final(String text) => {
  'role': 'assistant',
  'content': text,
  'finish_reason': 'stop',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final agent = AgentService.I;
  late AppState app;
  late ChatSession root;
  late Directory documents;
  late PathProviderPlatform originalPaths;

  /// Every request's messages, per session id, in call order.
  final requests = <({String session, List<Map<String, dynamic>> msgs})>[];

  Future<void> until(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail('condition did not settle');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  List<Map<String, dynamic>> mainRequests() => [
    for (final r in requests)
      if (r.session == root.id) {'msgs': r.msgs},
  ];
  String sent(int i) => jsonEncode(mainRequests()[i]['msgs']);
  List<String> userRows() => [
    for (final m in root.messages)
      if (m.role == 'user') m.content,
  ];

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('queue-inject-');
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
      id: 'queue-root',
      title: 'Root', // no title LLM call
      model: 'test-model',
      providerId: 'ollama-local',
      mode: 'auto',
    );
    app.sessions.add(root);
    app.activeSessionId = root.id;
    AgentService.setRunSessionForTest('');
    requests.clear();
  });

  tearDown(() async {
    await until(() => agent.subagentsOf(root.id).every((s) => s.finished));
    await until(() => !agent.busyFor(root.id));
    for (final sub in agent.subagentsOf(root.id)) {
      agent.removeSubagentForTest(sub.id);
    }
    agent.clearQueueForTest();
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

  /// Installs a scripted model: [step] receives the 1-based main-session
  /// call number and returns the reply.
  void script(
    FutureOr<Map<String, dynamic>> Function(int n, ChatSession s) step,
  ) {
    var n = 0;
    AgentService.llmOnceForTest = (p, msgs, session, tools) async {
      requests.add((session: session.id, msgs: List.of(msgs)));
      return step(++n, session);
    };
  }

  Future<void> run(String prompt) async {
    app.sendMessage(prompt);
    await agent
        .runTask(prompt, sessionId: root.id)
        .timeout(const Duration(seconds: 20));
    await until(() => !agent.busyFor(root.id));
  }

  test('queueing during a run does not cancel it; the message joins the '
      'next request after the tool results and the transcript', () async {
    var busyAfterQueue = false;
    script((n, s) {
      if (n == 1) {
        agent.enqueueMessage('also check tests', sessionId: root.id);
        busyAfterQueue = agent.busyFor(root.id);
        return _toolCall('t1');
      }
      return _final('done $n');
    });
    await run('build it');

    expect(busyAfterQueue, isTrue);
    expect(
      agent.runBucketForTest(root.id).stoppedByUser,
      isFalse,
      reason: 'queueing must never stop the run',
    );
    expect(mainRequests(), hasLength(2), reason: 'no restart, one loop');
    final second = mainRequests()[1]['msgs'] as List<Map<String, dynamic>>;
    final toolIdx = second.lastIndexWhere((m) => m['role'] == 'tool');
    final userIdx = second.lastIndexWhere((m) => m['role'] == 'user');
    expect(second[userIdx]['content'], contains('also check tests'));
    expect(userIdx, greaterThan(toolIdx), reason: 'after the tool results');
    expect(sent(0), isNot(contains('also check tests')));
    expect(agent.queuedMessagesFor(root.id), isEmpty);
    expect(userRows(), ['build it', 'also check tests']);
  });

  test('multiple queued messages are delivered together, in order', () async {
    script((n, s) {
      if (n == 1) {
        agent.enqueueMessage('first q', sessionId: root.id);
        agent.enqueueMessage('second q', sessionId: root.id);
        agent.enqueueMessage('third q', sessionId: root.id);
        return _toolCall('t1');
      }
      return _final('done');
    });
    await run('go');

    expect(mainRequests(), hasLength(2));
    final second = mainRequests()[1]['msgs'] as List<Map<String, dynamic>>;
    final last = second.last;
    expect(last['role'], 'user');
    final content = last['content'] as String;
    expect(content.indexOf('first q'), greaterThan(-1));
    expect(content.indexOf('second q'), greaterThan(content.indexOf('first q')));
    expect(content.indexOf('third q'), greaterThan(content.indexOf('second q')));
    expect(userRows(), ['go', 'first q', 'second q', 'third q']);
    expect(agent.queuedMessagesFor(root.id), isEmpty);
  });

  test('a message queued during the final reply runs immediately', () async {
    script((n, s) {
      if (n == 1) {
        agent.enqueueMessage('one more thing', sessionId: root.id);
        return _final('all done');
      }
      return _final('handled');
    });
    await run('task');

    expect(mainRequests(), hasLength(2));
    expect(sent(0), isNot(contains('one more thing')));
    expect(sent(1), contains('one more thing'));
    expect(agent.queuedMessagesFor(root.id), isEmpty);
    expect(userRows(), ['task', 'one more thing']);
  });

  test('a queue left when the run settles starts the next run at once, '
      'with the rest of the queue joining its first request', () async {
    final started = <String>[];
    agent.queuedRunStarterForTest = (sid, text) async => started.add(text);
    addTearDown(() => agent.queuedRunStarterForTest = null);
    // Idle session: restoring queued rows promotes the head immediately.
    agent.restoreQueuedMessages(root.id, [
      (
        id: 900,
        text: 'queued A',
        userReferences: true,
        nextDispatch: false,
        attachments: const [],
      ),
    ]);
    await until(() => started.isNotEmpty);
    expect(started, ['queued A']);
    expect(userRows(), contains('queued A'));
    expect(agent.queuedMessagesFor(root.id), isEmpty);

    // A real continuation run drains the remaining rows on request #1.
    agent.queuedRunStarterForTest = null;
    script((n, s) => _final('ok'));
    agent.enqueueMessage('queued B', sessionId: root.id);
    await run('queued A');
    expect(sent(0), contains('queued B'));
    expect(agent.queuedMessagesFor(root.id), isEmpty);
  });

  test('"stop & send now" cancels the current run, keeps its partial '
      'output and immediately runs the queued message', () async {
    final hold = Completer<void>();
    final entered = Completer<void>();
    script((n, s) async {
      if (n == 1) {
        agent.streamToBubbleForTest(s, 'PARTIAL WORK');
        entered.complete();
        await hold.future;
        return _toolCall('t1');
      }
      return _final('answer $n');
    });
    app.sendMessage('long task');
    final first = agent.runTask('long task', sessionId: root.id);
    await entered.future;
    agent.enqueueMessage('later', sessionId: root.id);
    agent.enqueueMessage('urgent', sessionId: root.id);
    final urgentId = agent.queuedMessageIdsFor(root.id).last;
    agent.quickSendQueuedMessage(urgentId, sessionId: root.id);
    hold.complete();
    await first.timeout(const Duration(seconds: 20));
    await until(() => mainRequests().length >= 2 && !agent.busyFor(root.id));

    // The cancelled run never made another request; the promoted run did.
    expect(mainRequests(), hasLength(2));
    final rows = userRows();
    expect(rows.indexOf('urgent'), greaterThan(rows.indexOf('long task')));
    expect(
      root.messages.any((m) => m.content.contains('PARTIAL WORK')),
      isTrue,
      reason: 'stop keeps partial output',
    );
    expect(sent(1), contains('urgent'));
    expect(agent.queuedMessagesFor(root.id), isEmpty);
  });

  test('deleting or editing a queued message does not cancel the run', () async {
    script((n, s) {
      if (n == 1) {
        agent.enqueueMessage('drop me', sessionId: root.id);
        agent.enqueueMessage('keep me', sessionId: root.id);
        final ids = agent.queuedMessageIdsFor(root.id);
        agent.removeQueuedMessageById(ids.first);
        agent.editQueuedMessageById(ids.last, 'keep me (edited)');
        return _toolCall('t1');
      }
      return _final('done');
    });
    await run('work');

    expect(agent.runBucketForTest(root.id).stoppedByUser, isFalse);
    expect(mainRequests(), hasLength(2));
    expect(sent(1), contains('keep me (edited)'));
    expect(sent(1), isNot(contains('drop me')));
    expect(userRows(), ['work', 'keep me (edited)']);
  });

  test('queued messages go to the main agent only, never a subagent', () async {
    final childRequests = <String>[];
    var mainCalls = 0;
    AgentService.llmOnceForTest = (p, msgs, session, tools) async {
      requests.add((session: session.id, msgs: List.of(msgs)));
      if (session.isSubagent) {
        childRequests.add(jsonEncode(msgs));
        if (childRequests.length == 1) {
          // The user queues on the MAIN chat while the child is working.
          agent.enqueueMessage('for the main agent', sessionId: root.id);
          return _toolCall('c1');
        }
        agent.streamToBubbleForTest(session, 'child done');
        return _final('child done');
      }
      mainCalls++;
      if (mainCalls == 1) {
        return {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'd1',
              'type': 'function',
              'function': {
                'name': 'dispatch_agent',
                'arguments': jsonEncode({
                  'prompt': 'investigate',
                  'label': 'worker',
                }),
              },
            },
          ],
          'finish_reason': 'tool_calls',
        };
      }
      return _final('main done');
    };
    await run('delegate');
    await until(() => agent.subagentsOf(root.id).every((s) => s.finished));
    await until(() => !agent.busyFor(root.id));

    expect(childRequests.length, greaterThanOrEqualTo(2));
    for (final r in childRequests) {
      expect(r, isNot(contains('for the main agent')));
    }
    final mainSent = [
      for (final r in requests)
        if (r.session == root.id) jsonEncode(r.msgs),
    ];
    expect(mainSent.any((r) => r.contains('for the main agent')), isTrue);
    expect(userRows(), contains('for the main agent'));
    expect(agent.queuedMessagesFor(root.id), isEmpty);
  });
}
