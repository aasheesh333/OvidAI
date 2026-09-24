import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';

/// Subagent width and nesting (2026-09-24).
///
/// Before this there was **no concurrency cap at all**: background
/// `dispatch_agent` calls were fired with `unawaited` and nothing counted them,
/// so a model could start an unbounded number of concurrent children — each with
/// its own SSE stream, workspace, 900 ms mirror timer and full-blob session
/// write, all on the single main isolate. And nesting was live: a child kept
/// `dispatch_agent`/`workflow`/`ralph` in its roster and passed the depth gate
/// at depth 1, so it could spawn grandchildren.
///
/// The contract now: at most 49 running at once, enforced atomically, and a
/// subagent can never spawn a subagent.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final agent = AgentService.I;
  final registered = <String>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    agent.debugPauseScheduleTimerForTest(true);
    registered.clear();
  });

  tearDown(() {
    for (final id in registered) {
      agent.removeSubagentForTest(id);
    }
    registered.clear();
    AgentService.setRunSessionForTest('');
    agent.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
  });

  ChatSession newRoot(String id) {
    final app = AppState.I;
    final s = ChatSession(id: id, title: id, model: 'm', mode: 'auto');
    app.sessions.insert(0, s);
    app.activeSessionId = s.id;
    AgentService.setRunSessionForTest(s.id);
    return s;
  }

  void registerLive(String id, {String parent = 'root', bool finished = false}) {
    final sub = SubagentInfo(
      id: id,
      label: id,
      sessionId: 'sess-$id',
      parentSessionId: parent,
      parentMode: AgentMode.auto,
      prompt: 'p',
    )..finished = finished;
    agent.registerSubagentForTest(sub);
    registered.add(id);
  }

  group('the ceiling is 49 and admission is exact', () {
    test('49 is the hard maximum, never 50', () {
      expect(AgentService.maxConcurrentSubagentsForTest, 49);
    });

    test('admission flips exactly at the ceiling', () {
      expect(agent.canAdmitSubagentForTest(), isTrue);

      for (var i = 1; i <= 48; i++) {
        registerLive('sub-$i');
        expect(
          agent.canAdmitSubagentForTest(),
          isTrue,
          reason: 'at $i live there is still room',
        );
      }

      registerLive('sub-49');
      expect(agent.liveSubagentCountForTest, 49);
      expect(
        agent.canAdmitSubagentForTest(),
        isFalse,
        reason: 'the 50th must not be admitted',
      );
    });

    test('finished handles do not consume budget', () {
      for (var i = 1; i <= 60; i++) {
        registerLive('done-$i', finished: true);
      }
      expect(agent.liveSubagentCountForTest, 0);
      expect(agent.canAdmitSubagentForTest(), isTrue);

      // 49 settled + 1 running is still admissible; 49 running is not.
      registerLive('live-1');
      expect(agent.canAdmitSubagentForTest(), isTrue);
    });

    test('dispatch_agent is refused at the ceiling and spawns nothing',
        () async {
      final root = newRoot('ceil-root');
      for (var i = 1; i <= 49; i++) {
        registerLive('busy-$i', parent: root.id);
      }

      final res = await agent.dispatchForTest('dispatch_agent', {
        'prompt': 'one more',
        'run_in_background': true,
      });

      expect(res, contains('ceiling (49'));
      expect(res, contains('list_agents'));
      // Nothing was created: the refusal happens before any session exists.
      expect(AppState.I.childrenOf(root.id), isEmpty);
      expect(agent.liveSubagentCountForTest, 49);
    });
  });

  group('a subagent can never spawn a subagent', () {
    test('dispatch from a child is refused', () async {
      final app = AppState.I;
      final root = newRoot('nest-root');
      final child = app.createSubagentSession(
        parent: root,
        label: 'child',
        mode: 'auto',
      );
      expect(child.isSubagent, isTrue);

      app.activeSessionId = child.id;
      AgentService.setRunSessionForTest(child.id);

      final res = await agent.dispatchForTest('dispatch_agent', {
        'prompt': 'delegate this',
      });
      expect(res, contains('SUBAGENT'));
      expect(app.childrenOf(child.id), isEmpty);
    });

    test('the child roster never advertises the spawn tools', () {
      final app = AppState.I;
      final root = newRoot('roster-root');

      // Root sees them — a top-level agent must be able to delegate.
      AgentService.setRunSessionForTest(root.id);
      final rootNames = agent
          .toolsForTest()
          .map((t) => (t['function'] as Map)['name'] as String)
          .toSet();
      for (final t in ['dispatch_agent', 'workflow', 'ralph']) {
        expect(rootNames, contains(t), reason: 'root must keep $t');
      }

      // A child does not.
      final child = app.createSubagentSession(
        parent: root,
        label: 'child',
        mode: 'auto',
      );
      AgentService.setRunSessionForTest(child.id);
      final childNames = agent
          .toolsForTest()
          .map((t) => (t['function'] as Map)['name'] as String)
          .toSet();
      for (final t in ['dispatch_agent', 'workflow', 'ralph']) {
        expect(childNames, isNot(contains(t)), reason: 'child must not see $t');
      }

      // Management and reporting tools stay: a child must still coordinate.
      for (final t in ['send_message', 'list_agents', 'report']) {
        expect(childNames, contains(t), reason: 'child must keep $t');
      }
    });

    test('the dispatch gate also refuses the spawn tools for a child', () async {
      final app = AppState.I;
      final root = newRoot('gate-root');
      final child = app.createSubagentSession(
        parent: root,
        label: 'child',
        mode: 'auto',
      );
      AgentService.setRunSessionForTest(child.id);

      // Layer 1: even if a roster leak occurred, the gate refuses.
      for (final tool in ['workflow', 'ralph']) {
        final res = await agent.dispatchForTest(tool, {
          'phases': [
            {'name': 'p', 'tasks': ['x']},
          ],
          'objective': 'x',
        });
        expect(res, contains('SUBAGENT'), reason: '$tool must be gated');
      }
    });
  });
}
