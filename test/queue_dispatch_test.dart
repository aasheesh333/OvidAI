// P2 queue contract — the behaviour the composer's Stop button promises:
//
//   1. A prompt sent while the Main Agent is running waits in the dock; it
//      is NOT dispatched as a second concurrent run.
//   2. Stop cancels the main turn and sends the queued prompt immediately —
//      the dock row leaves and the transcript row flips to "Sending…".
//   3. Subagent child runs are independent: stopping the main turn (or the
//      pre-session "stop everything" path) never cancels them.
//   4. The queue belongs to its session: switching chats keeps the rows.
//   5. The promotion happens exactly once (double Stop, a terminal landing
//      while the promoted POST is in flight, and quick-send all included).

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/state.dart';

class _QueueRest extends CloudRestClient {
  _QueueRest()
    : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  final List<String> sent = <String>[];
  final List<String> cancelled = <String>[];
  final Set<String> failContents = <String>{};
  int _seq = 0;

  /// Holds one POST so a test can inspect the facade while the promoted
  /// row's request is in flight.
  final Map<String, Completer<void>> sendGates = <String, Completer<void>>{};
  final Map<String, Completer<void>> sendEntered = <String, Completer<void>>{};

  @override
  Future<SendMessageResponse> sendMessage(
    String sessionId,
    String content, {
    List<String> attachmentIds = const [],
    String? clientMsgId,
    int? maxOutputTokens,
    CloudTurnOptions turn = CloudTurnOptions.none,
  }) async {
    final entered = sendEntered.remove(content);
    if (entered != null && !entered.isCompleted) entered.complete();
    final gate = sendGates.remove(content);
    if (gate != null) await gate.future;
    if (failContents.remove(content)) {
      throw CloudApiException(
        status: 500,
        code: 'internal',
        message: 'refused',
      );
    }
    sent.add(content);
    final n = ++_seq;
    return SendMessageResponse(
      runId: 'run-$n',
      userMessageId: 'msg-user-$n',
      status: 'queued',
    );
  }

  @override
  Future<RunCancelResponse> cancelRun(String runId) async {
    cancelled.add(runId);
    return RunCancelResponse(runId: runId, status: 'cancelled');
  }
}

class _FakeSocket implements CloudSocket {
  final StreamController<Object> _frames = StreamController<Object>.broadcast();
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
) => <String, dynamic>{
  'op': 'event',
  'event': <String, dynamic>{
    'sessionId': sessionId,
    'seq': seq,
    'type': type,
    'payload': payload,
    'ts': '2026-10-21T10:00:00.000Z',
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

  Future<_FakeSocket> socket() async {
    for (var i = 0; i < 100 && sockets.isEmpty; i++) {
      await pumpEventQueue(times: 1);
    }
    expect(sockets, isNotEmpty, reason: 'the facade must subscribe on a run');
    await pumpEventQueue(times: 5);
    return sockets.last;
  }

  /// Drives an accepted run into its live state (`run_started` is what makes
  /// `busyFor` true for the enqueue path).
  Future<_FakeSocket> startRun(
    String sessionId,
    String runId, {
    String seq = '1-0',
  }) async {
    final wsSocket = await socket();
    wsSocket.server(
      _eventFrame(sessionId, seq, 'run_started', {'runId': runId}),
    );
    await pumpEventQueue();
    expect(
      facade.busyFor(sessionId),
      isTrue,
      reason: 'run_started must go live',
    );
    return wsSocket;
  }

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 300 && !condition(); i++) {
      await pumpEventQueue(times: 1);
    }
    expect(condition(), isTrue, reason: 'queue did not settle');
  }

  test(
    'a prompt queued while the main run is live waits in the dock',
    () async {
      final s = session('s1');
      await facade.runTask('start', sessionId: s.id);
      await startRun(s.id, 'run-1');

      facade.enqueueMessage('next');

      expect(facade.queuedCountFor(s.id), 1);
      expect(facade.queuedMessagesFor(s.id), ['next']);
      expect(facade.busyFor(s.id), isTrue);
      // Nothing was sent: the queued row is not a second concurrent run.
      expect(rest.sent, ['start']);
      // Nor is it a transcript row yet — it lives in the dock until promoted.
      final transcript = facade.transcriptFor(s.id) ?? const <Message>[];
      expect(
        transcript.where((m) => m.role == 'user' && m.content == 'next'),
        isEmpty,
      );
    },
  );

  test(
    'Stop promotes the queued prompt immediately and flips it to Sending',
    () async {
      final s = session('s1');
      await facade.runTask('start', sessionId: s.id);
      await startRun(s.id, 'run-1');
      facade.enqueueMessage('next');
      expect(facade.queuedCountFor(s.id), 1);

      final entered = Completer<void>();
      final gate = Completer<void>();
      rest.sendEntered['next'] = entered;
      rest.sendGates['next'] = gate;

      expect(
        facade.stopRequested(sessionId: s.id, dispatchQueued: true),
        isTrue,
      );
      // The cancel is armed before its await, so the UI reads "Stopping…".
      expect(facade.runStateFor(s.id).stopRequested, isTrue);
      expect(facade.stoppingFor(s.id), isTrue);

      await until(() => entered.isCompleted);

      // Cancel went to the MAIN run only, and the dock row left the queue...
      expect(rest.cancelled, ['run-1']);
      expect(facade.queuedCountFor(s.id), 0);
      // ...while the transcript now shows it, in its "Sending…" pending state.
      final pending = (facade.transcriptFor(s.id) ?? const <Message>[]).last;
      expect(pending.role, 'user');
      expect(pending.content, 'next');
      expect(CloudAgentFacade.pendingClientMsgIdOf(pending), isNotNull);
      expect(facade.pendingStateOf(pending), PendingSendState.sending);

      gate.complete();
      await until(() => rest.sent.length == 2);
      expect(rest.sent, ['start', 'next']);
    },
  );

  test('subagent runs survive a Stop on the main turn', () async {
    final s = session('s1');
    await facade.runTask('start', sessionId: s.id);
    final wsSocket = await startRun(s.id, 'run-1');

    // The parent dispatches a child session with its own run.
    wsSocket.server(
      _eventFrame(s.id, '2-0', 'subagent_started', {
        'childSessionId': 'child-1',
        'name': 'CodeSubagent',
      }),
    );
    await pumpEventQueue();
    wsSocket.server(
      _eventFrame('child-1', '1-0', 'run_started', {'runId': 'child-run-1'}),
    );
    await pumpEventQueue();
    expect(facade.busyFor('child-1'), isTrue);

    facade.enqueueMessage('next');
    expect(facade.stopRequested(sessionId: s.id, dispatchQueued: true), isTrue);
    await until(() => rest.sent.length == 2);

    // Only the parent's run was cancelled; the child keeps working.
    expect(rest.cancelled, ['run-1']);
    expect(facade.busyFor('child-1'), isTrue);
    expect(facade.runStateFor('child-1').stopRequested, isFalse);

    // It finishes on its own, with no further cancel from the facade.
    wsSocket.server(
      _eventFrame('child-1', '2-0', 'run_completed', {'runId': 'child-run-1'}),
    );
    await pumpEventQueue();
    expect(facade.busyFor('child-1'), isFalse);
    expect(rest.cancelled, ['run-1']);
  });

  test('hardStopAll never cancels a subagent child run', () async {
    final s = session('s1');
    await facade.runTask('start', sessionId: s.id);
    final wsSocket = await startRun(s.id, 'run-1');
    wsSocket.server(
      _eventFrame(s.id, '2-0', 'subagent_started', {
        'childSessionId': 'child-1',
        'name': 'CodeSubagent',
      }),
    );
    await pumpEventQueue();
    wsSocket.server(
      _eventFrame('child-1', '1-0', 'run_started', {'runId': 'child-run-1'}),
    );
    await pumpEventQueue();
    expect(facade.busyFor('child-1'), isTrue);

    facade.hardStopAll();
    await pumpEventQueue();

    expect(rest.cancelled, ['run-1']);
    expect(facade.busyFor('child-1'), isTrue);
  });

  test('queued prompts survive a session switch', () async {
    final s1 = session('s1');
    await facade.runTask('start', sessionId: s1.id);
    await startRun(s1.id, 'run-1');
    facade.enqueueMessage('one', sessionId: s1.id);
    facade.enqueueMessage('two', sessionId: s1.id);
    expect(facade.queuedCountFor(s1.id), 2);

    final s2 = ChatSession(id: 's2', title: 'Other', model: 'm', mode: 'auto');
    app.sessions.add(s2);
    app.activeSessionId = s2.id;
    // The chat screen releases the previous chat's subscription on switch.
    facade.releaseSession(s1.id);
    await pumpEventQueue();

    // The foreground queue is s2's (empty); s1's rows are untouched.
    expect(facade.queuedMessages, isEmpty);
    expect(facade.queuedCountFor(s1.id), 2);
    expect(facade.queuedMessagesFor(s1.id), ['one', 'two']);

    // Coming back shows them, and Stop still promotes the head.
    app.activeSessionId = s1.id;
    expect(facade.queuedCountFor(s1.id), 2);
    expect(
      facade.stopRequested(sessionId: s1.id, dispatchQueued: true),
      isTrue,
    );
    await until(() => rest.sent.length == 2);
    expect(rest.sent, ['start', 'one']);
    expect(facade.queuedCountFor(s1.id), 1);
    expect(facade.queuedMessagesFor(s1.id), ['two']);
  });

  test('a refused send does not strand the prompt queued behind it', () async {
    final s = session('s1');
    final entered = Completer<void>();
    final gate = Completer<void>();
    rest.sendEntered['first'] = entered;
    rest.sendGates['first'] = gate;
    rest.failContents.add('first');

    final firstSend = facade.runTask('first', sessionId: s.id);
    await until(() => entered.isCompleted);
    // Second tap while the first POST is in flight: queued, not concurrent.
    facade.runTask('second', sessionId: s.id);
    expect(facade.queuedCountFor(s.id), 1);

    gate.complete();
    await firstSend;
    await until(() => rest.sent.length == 1);

    // The refused first send terminalizes nothing; the flagged row still
    // leaves the queue exactly once instead of waiting forever.
    expect(rest.sent, ['second']);
    expect(facade.queuedCountFor(s.id), 0);
  });

  test(
    'promotion happens exactly once (double Stop + terminal race)',
    () async {
      final s = session('s1');
      await facade.runTask('start', sessionId: s.id);
      final wsSocket = await startRun(s.id, 'run-1');
      facade.enqueueMessage('next');
      facade.enqueueMessage('later');
      final laterId = facade.queuedMessageIdsFor(s.id).last;

      final entered = Completer<void>();
      final gate = Completer<void>();
      rest.sendEntered['next'] = entered;
      rest.sendGates['next'] = gate;

      expect(
        facade.stopRequested(sessionId: s.id, dispatchQueued: true),
        isTrue,
      );
      await until(() => entered.isCompleted);

      // A second Stop while "next" is in flight is a no-op...
      facade.stopRequested(sessionId: s.id, dispatchQueued: true);
      // ...and quick-send of a later row cannot jump the in-flight promotion.
      facade.quickSendQueuedMessage(laterId, sessionId: s.id);
      expect(facade.queuedMessagesFor(s.id), ['later']);

      // The cancelled run's terminal lands while "next" is still POSTing.
      wsSocket.server(
        _eventFrame(s.id, '2-0', 'run_completed', {'runId': 'run-1'}),
      );
      await pumpEventQueue();
      gate.complete();
      await until(() => rest.sent.length == 2);
      await pumpEventQueue();

      // "next" went out exactly once; "later" is still waiting, in order.
      expect(rest.sent, ['start', 'next']);
      expect(facade.queuedMessagesFor(s.id), ['later']);
      expect(rest.cancelled.where((r) => r == 'run-1').length, 1);

      // The promoted run's terminal releases the next row exactly once.
      wsSocket.server(
        _eventFrame(s.id, '3-0', 'run_started', {'runId': 'run-2'}),
      );
      await pumpEventQueue();
      wsSocket.server(
        _eventFrame(s.id, '4-0', 'run_completed', {'runId': 'run-2'}),
      );
      await until(() => rest.sent.length == 3);
      expect(rest.sent, ['start', 'next', 'later']);
      expect(facade.queuedCountFor(s.id), 0);
    },
  );
}
