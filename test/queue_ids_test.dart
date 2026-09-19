import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';

/// The queue dock's delete / steer / edit actions operated by list INDEX on
/// rows built in a plain `for` loop, so Flutter reused the wrong row's State
/// after any mutation (`_editing`/`_ctrl` bound to the wrong message) — the
/// reported "delete/next/edit does not work". Each queued message now has a
/// stable id and the actions target that id.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final agent = AgentService.I;
  final app = AppState.I;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    app.sessions.clear();
    app.activeSessionId = null;
  });

  tearDown(() {
    agent.clearQueueForTest();
    agent.dropSessionRun('qid-a');
    app.sessions.clear();
    app.activeSessionId = null;
  });

  ChatSession session(String id) {
    final s = ChatSession(id: id, title: 'T', model: 'm', mode: 'auto');
    app.sessions.add(s);
    app.activeSessionId = id;
    return s;
  }

  test('queued messages get distinct stable ids', () {
    final s = session('qid-a');
    AgentService.setRunSessionForTest(s.id);
    agent.enqueueMessage('one');
    agent.enqueueMessage('two');
    agent.enqueueMessage('three');
    final ids = agent.queuedMessageIdsFor(s.id);
    expect(ids.length, 3);
    expect(ids.toSet().length, 3, reason: 'ids must be unique');
  });

  test('delete by id removes exactly that message', () {
    final s = session('qid-a');
    AgentService.setRunSessionForTest(s.id);
    agent.enqueueMessage('one');
    agent.enqueueMessage('two');
    agent.enqueueMessage('three');
    final ids = agent.queuedMessageIdsFor(s.id);

    agent.removeQueuedMessageById(ids[1]);
    expect(agent.queuedMessages, ['one', 'three']);
    // The surviving ids are unchanged (no re-indexing).
    expect(agent.queuedMessageIdsFor(s.id), [ids[0], ids[2]]);
  });

  test('steer by id moves exactly that message to the front', () {
    final s = session('qid-a');
    AgentService.setRunSessionForTest(s.id);
    agent.enqueueMessage('one');
    agent.enqueueMessage('two');
    agent.enqueueMessage('three');
    final ids = agent.queuedMessageIdsFor(s.id);

    agent.steerQueuedMessageById(ids[2]);
    expect(agent.queuedMessages, ['three', 'one', 'two']);
    expect(agent.queuedMessageIdsFor(s.id), [ids[2], ids[0], ids[1]]);
  });

  test('edit by id replaces exactly that message', () {
    final s = session('qid-a');
    AgentService.setRunSessionForTest(s.id);
    agent.enqueueMessage('one');
    agent.enqueueMessage('two');
    final ids = agent.queuedMessageIdsFor(s.id);

    agent.editQueuedMessageById(ids[0], 'one-edited');
    expect(agent.queuedMessages, ['one-edited', 'two']);
    expect(agent.queuedMessageIdsFor(s.id), ids);
  });

  test('ids survive a stop-and-continue (head promoted, rest keep ids)', () {
    final s = session('qid-a');
    AgentService.setRunSessionForTest(s.id);
    agent.enqueueMessage('first');
    agent.enqueueMessage('second');
    final ids = agent.queuedMessageIdsFor(s.id);

    // Stop only promotes a RUNNING session's queue.
    agent.runBucketForTest(s.id).activeRunId = 'run-a';
    agent.queuedRunStarterForTest = (_, _) async {};
    agent.stopRequested(sessionId: s.id);

    // The head is promoted; the remaining id is untouched.
    expect(agent.queuedMessageIdsFor(s.id), [ids[1]]);
    expect(agent.queuedMessages, ['second']);
  });
}
