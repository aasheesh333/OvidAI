import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/state.dart';

/// The queue dock's delete / steer / edit actions operated by list INDEX on
/// rows built in a plain `for` loop, so Flutter reused the wrong row's State
/// after any mutation (`_editing`/`_ctrl` bound to the wrong message) — the
/// reported "delete/next/edit does not work". Each queued message has a
/// stable id and the actions target that id.
///
/// P8 Task 19 port: the local service is gone; the surviving queue is
/// `CloudAgentFacade`'s in-memory per-session list (`_queues`, keyed by SERVER
/// session id). The assertions are the same. Where the old test needed the
/// retired local service's `setRunSessionForTest`, this file either marks the
/// session busy through the facade's `setActiveRunForTest` seam (so enqueueing
/// does not drain immediately) or drives a real fake-rest/fake-socket run so
/// the terminal-event drain can be observed.
class _QueueRest extends CloudRestClient {
  _QueueRest()
      : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  final List<String> sent = <String>[];
  int _seq = 0;

  /// Per-content gates: lets a test emit the promoted run's `run_started`
  /// while its POST is in flight, so the facade sees a live run and does not
  /// recursively drain the rest of the queue.
  final Map<String, Completer<void>> sendGates =
      <String, Completer<void>>{};
  final Map<String, Completer<void>> sendEntered =
      <String, Completer<void>>{};

  CloudTurnOptions lastTurn = CloudTurnOptions.none;

  @override
  Future<SendMessageResponse> sendMessage(
    String sessionId,
    String content, {
    List<String> attachmentIds = const [],
    String? clientMsgId,
    int? maxOutputTokens,
    CloudTurnOptions turn = CloudTurnOptions.none,
  }) async {
    lastTurn = turn;
    final entered = sendEntered.remove(content);
    if (entered != null && !entered.isCompleted) entered.complete();
    final gate = sendGates.remove(content);
    if (gate != null) await gate.future;
    sent.add(content);
    final n = ++_seq;
    return SendMessageResponse(
      runId: 'run-$n',
      userMessageId: 'msg-user-$n',
      status: 'queued',
    );
  }

  @override
  Future<RunCancelResponse> cancelRun(String runId) async =>
      RunCancelResponse(runId: runId, status: 'cancelled');
}

class _FakeSocket implements CloudSocket {
  final StreamController<Object> _frames =
      StreamController<Object>.broadcast();
  final StreamController<void> _closed = StreamController<void>.broadcast();

  @override
  Stream<Object> get frames => _frames.stream;

  @override
  Stream<void> get closed => _closed.stream;

  @override
  int? get closeCode => null;

  @override
  void sendText(String frame) {}

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_closed.isClosed) await _closed.close();
  }

  void server(Object frame) =>
      _frames.add(frame is String ? frame : jsonEncode(frame));
}

Map<String, dynamic> _eventFrame(
  String sessionId,
  String seq,
  String type,
  Map<String, dynamic> payload,
) =>
    <String, dynamic>{
      'op': 'event',
      'event': <String, dynamic>{
        'sessionId': sessionId,
        'seq': seq,
        'type': type,
        'payload': payload,
        'ts': '2026-10-18T10:00:00.000Z',
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late _QueueRest rest;
  late WsMultiplexer ws;
  late CloudAgentFacade facade;
  final sockets = <_FakeSocket>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    app = AppState.createForTest();
    rest = _QueueRest();
    sockets.clear();
    ws = WsMultiplexer(
      mintTicket: () async => 'ticket',
      socketFactory: (_) async {
        final socket = _FakeSocket();
        sockets.add(socket);
        return socket;
      },
      heartbeatInterval: const Duration(hours: 1),
      pongTimeout: const Duration(hours: 1),
      jitterMs: () => 0,
    );
    facade = CloudAgentFacade(rest: rest, ws: ws, store: null);
    CloudAgentFacade.installForTest(facade);
  });

  tearDown(() async {
    facade.clearQueueForTest();
    await ws.disconnect();
    facade.dispose();
    CloudAgentFacade.resetForTest();
    AppState.resetTestInstance();
  });

  ChatSession session(String id) {
    final s = ChatSession(id: id, title: 'T', model: 'm', mode: 'auto');
    app.sessions.add(s);
    app.activeSessionId = id;
    return s;
  }

  /// Waits for the facade's lazy WS subscription to reach the fake factory.
  Future<_FakeSocket> socket() async {
    for (var i = 0; i < 100 && sockets.isEmpty; i++) {
      await pumpEventQueue(times: 1);
    }
    expect(sockets, isNotEmpty, reason: 'the facade must subscribe on a run');
    // The factory resolving is not the same as the multiplexer attaching its
    // frame listener; give `_attach` its microtask before emitting.
    await pumpEventQueue(times: 5);
    return sockets.last;
  }

  /// Drives the accepted run into its live state. Without `run_started`,
  /// `busyFor` is false for a fresh (not-yet-started) run and enqueueing
  /// would drain immediately.
  Future<_FakeSocket> startRun(ChatSession s, String runId) async {
    final wsSocket = await socket();
    wsSocket.server(_eventFrame(s.id, '1-0', 'run_started', {'runId': runId}));
    await pumpEventQueue();
    expect(facade.busyFor(s.id), isTrue, reason: 'run_started must go live');
    return wsSocket;
  }

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 200 && !condition(); i++) {
      await pumpEventQueue(times: 1);
    }
    expect(condition(), isTrue, reason: 'drain did not settle');
  }

  test('queued messages get distinct stable ids', () {
    final s = session('qid-a');
    facade.setActiveRunForTest(s.id, 'run-a');
    facade.enqueueMessage('one');
    facade.enqueueMessage('two');
    facade.enqueueMessage('three');
    final ids = facade.queuedMessageIdsFor(s.id);
    expect(ids.length, 3);
    expect(ids.toSet().length, 3, reason: 'ids must be unique');
  });

  test('delete by id removes exactly that message', () {
    final s = session('qid-a');
    facade.setActiveRunForTest(s.id, 'run-a');
    facade.enqueueMessage('one');
    facade.enqueueMessage('two');
    facade.enqueueMessage('three');
    final ids = facade.queuedMessageIdsFor(s.id);

    facade.removeQueuedMessageById(ids[1]);
    expect(facade.queuedMessages, ['one', 'three']);
    // The surviving ids are unchanged (no re-indexing).
    expect(facade.queuedMessageIdsFor(s.id), [ids[0], ids[2]]);
  });

  test('steer by id moves exactly that message to the front', () {
    final s = session('qid-a');
    facade.setActiveRunForTest(s.id, 'run-a');
    facade.enqueueMessage('one');
    facade.enqueueMessage('two');
    facade.enqueueMessage('three');
    final ids = facade.queuedMessageIdsFor(s.id);

    // The retired service exposed `steerQueuedMessageById`; the surviving
    // id-based steer is `quickSendQueuedMessage(id)` — it moves the row to the
    // front and then asks the session to stop. On the test busy seam the stop
    // resolves without a server run, so the steered order is what remains.
    facade.quickSendQueuedMessage(ids[2]);
    expect(facade.queuedMessages, ['three', 'one', 'two']);
    expect(facade.queuedMessageIdsFor(s.id), [ids[2], ids[0], ids[1]]);
  });

  test('editing a queued row replaces its refs; they ride the next send',
      () async {
    final s = session('qid-a');
    await facade.runTask('start', sessionId: s.id);
    await startRun(s, 'run-1');
    const oldId = '0199aaaa-0000-7000-8000-00000000e0aa';
    const newId = '0199aaaa-0000-7000-8000-00000000e0bb';
    const sessionId = '0199aaaa-0000-7000-8000-00000000e0cc';
    facade.enqueueMessage(
      'one',
      sessionId: s.id,
      sessionRefs: const [sessionId],
      projectRefs: const [oldId],
    );
    final id = facade.queuedMessageIdsFor(s.id).single;

    facade.editQueuedMessageById(
      id,
      'one edited',
      sessionRefs: const [sessionId],
      projectRefs: const [newId],
    );

    expect(facade.stopRequested(sessionId: s.id, dispatchQueued: true), isTrue);
    await until(() => rest.sent.length == 2);

    expect(rest.sent, ['start', 'one edited']);
    expect(rest.lastTurn.projectRefs, [newId]);
    expect(rest.lastTurn.sessionRefs, [sessionId]);
  });

  test('edit by id replaces exactly that message', () {
    final s = session('qid-a');
    facade.setActiveRunForTest(s.id, 'run-a');
    facade.enqueueMessage('one');
    facade.enqueueMessage('two');
    final ids = facade.queuedMessageIdsFor(s.id);

    facade.editQueuedMessageById(ids[0], 'one-edited');
    expect(facade.queuedMessages, ['one-edited', 'two']);
    expect(facade.queuedMessageIdsFor(s.id), ids);
  });

  test(
    'ids survive a stop-and-continue (head promoted, rest keep ids)',
    () async {
      final s = session('qid-a');
      await facade.runTask('start', sessionId: s.id);
      expect(rest.sent, ['start']);
      final wsSocket = await startRun(s, 'run-1');
      facade.enqueueMessage('first');
      facade.enqueueMessage('second');
      final ids = facade.queuedMessageIdsFor(s.id);

      // Stop only promotes a RUNNING session's queue: the cancel terminal
      // drains the head as the next run.
      expect(facade.stopRequested(sessionId: s.id), isTrue);
      await pumpEventQueue();
      final entered = Completer<void>();
      final gate = Completer<void>();
      rest.sendEntered['first'] = entered;
      rest.sendGates['first'] = gate;
      wsSocket.server(
        _eventFrame(s.id, '2-0', 'run_completed', {'runId': 'run-1'}),
      );
      await until(() => entered.isCompleted);
      // The promoted run goes live while its POST is in flight; without this
      // the facade would keep draining the queue in the same pass.
      wsSocket.server(
        _eventFrame(s.id, '3-0', 'run_started', {'runId': 'run-2'}),
      );
      await pumpEventQueue();
      gate.complete();
      await until(() => rest.sent.length == 2);
      await pumpEventQueue();

      // The head is promoted; the remaining id is untouched.
      expect(rest.sent, ['start', 'first']);
      expect(facade.queuedMessageIdsFor(s.id), [ids[1]]);
      expect(facade.queuedMessages, ['second']);
    },
  );

  test(
    'quick send steers the row to front and dispatches it immediately',
    () async {
      final s = session('qid-a');
      await facade.runTask('start', sessionId: s.id);
      final wsSocket = await startRun(s, 'run-1');
      facade.enqueueMessage('one');
      facade.enqueueMessage('two');
      facade.enqueueMessage('three');
      final ids = facade.queuedMessageIdsFor(s.id);

      // W9: the cancel is accepted and the row is dispatched WITHOUT waiting
      // for run-1's terminal event. Hold its POST so the queue snapshot is
      // deterministic while the send is in flight.
      final entered = Completer<void>();
      final gate = Completer<void>();
      rest.sendEntered['three'] = entered;
      rest.sendGates['three'] = gate;

      facade.quickSendQueuedMessage(ids[2]);
      await until(() => entered.isCompleted);
      // 'three' left the queue and its POST is in flight; the remaining rows
      // keep their ids and order.
      expect(facade.queuedMessages, ['one', 'two']);
      expect(facade.queuedMessageIdsFor(s.id), [ids[0], ids[1]]);

      // The cancelled run settles and the promoted run goes live while its
      // POST is still gated.
      wsSocket.server(
        _eventFrame(s.id, '2-0', 'run_completed', {'runId': 'run-1'}),
      );
      await pumpEventQueue();
      wsSocket.server(
        _eventFrame(s.id, '3-0', 'run_started', {'runId': 'run-2'}),
      );
      await pumpEventQueue();
      gate.complete();
      await until(() => rest.sent.length == 2);
      await pumpEventQueue();

      expect(rest.sent, ['start', 'three']);
      expect(facade.queuedMessages, ['one', 'two']);
    },
  );

  test('quick send is a no-op for unknown id or empty queue', () {
    final s = session('qid-a');
    facade.setActiveRunForTest(s.id, 'run-a');
    facade.enqueueMessage('one');

    // Unknown id: queue untouched, no stop triggered, no crash.
    facade.quickSendQueuedMessage(999999);
    expect(facade.queuedMessages, ['one']);

    // Empty queue: same guarantees.
    facade.clearQueueForTest();
    facade.quickSendQueuedMessage(999999);
    expect(facade.queuedMessages, isEmpty);
  });

  test('quick send on an idle session steers but keeps the queue', () {
    final s = session('qid-a');
    // Fill the queue while the session reads busy, then clear the test seam
    // without triggering a drain: the session is now idle with a queue.
    facade.setActiveRunForTest(s.id, 'run-a');
    facade.enqueueMessage('one');
    facade.enqueueMessage('two');
    final ids = facade.queuedMessageIdsFor(s.id);
    facade.setActiveRunForTest(s.id, null);

    // No active run: Stop must NOT promote (idle sessions keep their
    // queue — the same contract as the stop button).
    facade.quickSendQueuedMessage(ids[1], sessionId: s.id);

    expect(facade.queuedMessages, ['two', 'one']);
    expect(facade.queuedMessageIdsFor(s.id), [ids[1], ids[0]]);
  });

  test('edit-to-composer contract: row removed, text handed to composer', () {
    final s = session('qid-a');
    facade.setActiveRunForTest(s.id, 'run-a');
    facade.enqueueMessage('one');
    facade.enqueueMessage('two');
    final ids = facade.queuedMessageIdsFor(s.id);

    // Mirrors _QueueRowState._editToComposer: the row leaves the queue
    // first, then its text is handed to the dock's onEditToComposer
    // callback (which loads the composer's TextEditingController and
    // focuses the input field).
    String? composerText;
    void onEditToComposer(String text) => composerText = text;
    facade.removeQueuedMessageById(ids[0]);
    onEditToComposer('one');

    expect(facade.queuedMessages, ['two']);
    expect(facade.queuedMessageIdsFor(s.id), [ids[1]]);
    expect(composerText, 'one');
  });
}
