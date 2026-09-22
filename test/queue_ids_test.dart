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
    agent.queuedRunStarterForTest = null;
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

  test('quick send steers the row to front and promotes it on stop', () async {
    final s = session('qid-a');
    AgentService.setRunSessionForTest(s.id);
    agent.enqueueMessage('one');
    agent.enqueueMessage('two');
    agent.enqueueMessage('three');
    final ids = agent.queuedMessageIdsFor(s.id);

    // Stop only promotes a RUNNING session's queue.
    agent.runBucketForTest(s.id).activeRunId = 'run-a';
    String? startedText;
    agent.queuedRunStarterForTest = (_, text) async {
      startedText = text;
    };

    // No sessionId passed: defaults to the resolved run's session key.
    agent.quickSendQueuedMessage(ids[2]);
    await Future<void>.delayed(Duration.zero);

    // 'three' was steered to the front and the stop promoted it
    // immediately; the remaining rows keep their ids and order.
    expect(startedText, 'three');
    expect(agent.queuedMessages, ['one', 'two']);
    expect(agent.queuedMessageIdsFor(s.id), [ids[0], ids[1]]);
  });

  test('quick send is a no-op for unknown id or empty queue', () {
    final s = session('qid-a');
    AgentService.setRunSessionForTest(s.id);
    agent.enqueueMessage('one');

    // Unknown id: queue untouched, no stop triggered, no crash.
    agent.quickSendQueuedMessage(999999);
    expect(agent.queuedMessages, ['one']);

    // Empty queue: same guarantees.
    agent.clearQueueForTest();
    agent.quickSendQueuedMessage(999999);
    expect(agent.queuedMessages, isEmpty);
  });

  test('quick send on an idle session steers but keeps the queue', () {
    final s = session('qid-a');
    AgentService.setRunSessionForTest(s.id);
    agent.enqueueMessage('one');
    agent.enqueueMessage('two');
    final ids = agent.queuedMessageIdsFor(s.id);

    // No active run: Stop must NOT promote (idle sessions keep their
    // queue — the same contract as the stop button).
    agent.quickSendQueuedMessage(ids[1], sessionId: s.id);

    expect(agent.queuedMessages, ['two', 'one']);
    expect(agent.queuedMessageIdsFor(s.id), [ids[1], ids[0]]);
  });

  test('edit-to-composer contract: row removed, text handed to composer', () {
    final s = session('qid-a');
    AgentService.setRunSessionForTest(s.id);
    agent.enqueueMessage('one');
    agent.enqueueMessage('two');
    final ids = agent.queuedMessageIdsFor(s.id);

    // Mirrors _QueueRowState._editToComposer: the row leaves the queue
    // first, then its text is handed to the dock's onEditToComposer
    // callback (which loads the composer's TextEditingController and
    // focuses the input field).
    String? composerText;
    void onEditToComposer(String text) => composerText = text;
    agent.removeQueuedMessageById(ids[0]);
    onEditToComposer('one');

    expect(agent.queuedMessages, ['two']);
    expect(agent.queuedMessageIdsFor(s.id), [ids[1]]);
    expect(composerText, 'one');
  });
}
