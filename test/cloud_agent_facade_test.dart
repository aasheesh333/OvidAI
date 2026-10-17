// P8 Task 8 — CloudAgentFacade.
//
// The facade composes the landed pieces (Task 5 REST, Task 6 multiplexer,
// Task 7 projector) behind the AgentService-shaped AgentSurface seam. Every
// assertion below is behavioural: what goes on the wire, what the projection
// shows, and how run state settles — never an internal field.
//
// Contract anchors:
//   - POST /sessions/:id/messages 202 {runId,userMessageId,status:'queued'}
//     (shared/src/rest.ts; clientMsgId is the Task 4 idempotency key)
//   - run_started / run_completed / run_failed fold table (Task 7)
//   - POST /runs/:id/cancel 202 | 409 run_not_cancellable (Task 1)
//   - PATCH /sessions/:id {mode} (Task 2)
//   - POST /sessions/:id/attachments + presigned PUT (Task 3)

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart' show AgentMode;
import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// FakeCloudRest — records every wire call, returns contract-shaped answers
// ---------------------------------------------------------------------------

class FakeCloudRest extends CloudRestClient {
  FakeCloudRest()
      : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  final List<({String sessionId, String content, List<String> attachmentIds,
      String? clientMsgId})> sent = [];
  final List<String> cancelled = [];
  final List<({String sessionId, String? mode})> patches = [];
  final List<({String sessionId, String name, int size})> created = [];
  final List<List<int>> uploaded = [];

  CloudApiException? sendError;
  CloudApiException? cancelError;
  CloudApiException? patchError;

  int _seq = 0;

  @override
  Future<SendMessageResponse> sendMessage(
    String sessionId,
    String content, {
    List<String> attachmentIds = const [],
    String? clientMsgId,
  }) async {
    if (sendError != null) throw sendError!;
    sent.add((
      sessionId: sessionId,
      content: content,
      attachmentIds: attachmentIds,
      clientMsgId: clientMsgId,
    ));
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
    if (cancelError != null) throw cancelError!;
    return RunCancelResponse(runId: runId, status: 'cancelling');
  }

  @override
  Future<SessionDto> patchSession(String id,
      {String? title, String? mode}) async {
    patches.add((sessionId: id, mode: mode));
    if (patchError != null) throw patchError!;
    return SessionDto(
      id: id,
      title: null,
      mode: mode ?? 'auto',
      createdAt: DateTime.utc(2026, 10, 17),
      updatedAt: DateTime.utc(2026, 10, 17),
    );
  }

  @override
  Future<AttachmentUpload> createAttachment(
    String sessionId, {
    required String name,
    required int size,
  }) async {
    created.add((sessionId: sessionId, name: name, size: size));
    return AttachmentUpload(
      attachmentId: 'att-${created.length}',
      uploadUrl: 'https://upload.test/${created.length}',
      path: '.attachments/$name',
      expiresAt: DateTime.utc(2026, 10, 17, 1),
    );
  }

  @override
  Future<void> uploadAttachmentBytes(
      AttachmentUpload upload, List<int> bytes) async {
    uploaded.add(bytes);
  }
}

// ---------------------------------------------------------------------------
// FakeCloudSocket — the multiplexer's test seam
// ---------------------------------------------------------------------------

class FakeCloudSocket implements CloudSocket {
  final StreamController<Object> _frames = StreamController<Object>.broadcast();
  final StreamController<void> _closed = StreamController<void>.broadcast();
  final List<String> sent = [];
  int? _closeCode;

  @override
  Stream<Object> get frames => _frames.stream;

  @override
  Stream<void> get closed => _closed.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  void sendText(String frame) => sent.add(frame);

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_closed.isClosed) return;
    _closeCode = code;
    if (!_frames.isClosed) await _frames.close();
    _closed.add(null);
    await _closed.close();
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
        'ts': '2026-10-17T10:00:00.000Z',
      },
    };

class _Harness {
  _Harness(this.rest, this.ws, this.sockets, this.facade);

  final FakeCloudRest rest;
  final WsMultiplexer ws;
  final List<FakeCloudSocket> sockets;
  final CloudAgentFacade facade;

  Future<FakeCloudSocket> socket() async {
    await pumpEventQueue();
    expect(sockets, isNotEmpty, reason: 'the facade must subscribe on demand');
    return sockets.last;
  }
}

Future<_Harness> _build({FakeCloudRest? rest}) async {
  final fakeRest = rest ?? FakeCloudRest();
  final sockets = <FakeCloudSocket>[];
  final ws = WsMultiplexer(
    mintTicket: () async => 'ticket',
    socketFactory: (Uri url) async {
      final socket = FakeCloudSocket();
      sockets.add(socket);
      return socket;
    },
    prefs: await SharedPreferences.getInstance(),
    heartbeatInterval: const Duration(hours: 1),
    pongTimeout: const Duration(hours: 1),
    jitterMs: () => 0,
  );
  final facade = CloudAgentFacade(rest: fakeRest, ws: ws, store: null);
  return _Harness(fakeRest, ws, sockets, facade);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  group('runTask', () {
    test('issues sendMessage with a 32-hex clientMsgId and appends the '
        'optimistic user message under the server userMessageId', () async {
      final h = await _build();
      await h.facade.runTask('hello cloud', sessionId: 's1');

      expect(h.rest.sent, hasLength(1));
      final call = h.rest.sent.single;
      expect(call.sessionId, 's1');
      expect(call.content, 'hello cloud');
      expect(call.attachmentIds, isEmpty);
      expect(call.clientMsgId, isNotNull);
      expect(call.clientMsgId, matches(RegExp(r'^[0-9a-f]{32}$')));

      final projection = h.facade.projectionForTest('s1')!;
      final userRows = projection.messages.where((m) => m.role == 'user');
      expect(userRows, hasLength(1));
      expect(userRows.single.content, 'hello cloud');
      expect(userRows.single.privateSyncId, 'msg-user-1');

      final run = h.facade.runStateFor('s1');
      expect(run.runId, 'run-1');
      expect(run.busy, isTrue);
      expect(run.lastErrorCode, isNull);

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('uploads staged attachments before sending and clears the staging '
        'list on success', () async {
      final h = await _build();
      final dir = await Directory.systemTemp.createTemp('facade-attach');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/notes.txt');
      await file.writeAsString('attachment bytes');

      final error =
          await h.facade.attachFile(file.path, 'notes.txt', sessionId: 's1');
      expect(error, isNull);
      expect(h.facade.pendingAttachmentsForTest('s1'), hasLength(1));

      await h.facade.runTask('with a file', sessionId: 's1');

      expect(h.rest.created, hasLength(1));
      expect(h.rest.created.single.name, 'notes.txt');
      expect(h.rest.created.single.size, file.lengthSync());
      expect(h.rest.uploaded.single, utf8.encode('attachment bytes'));
      expect(h.rest.sent.single.attachmentIds, ['att-1']);
      expect(h.facade.pendingAttachmentsForTest('s1'), isEmpty);

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('a 402 daily_limit_reached lands in run state and leaves no '
        'dangling optimistic message', () async {
      final h = await _build();
      h.rest.sendError = CloudApiException(
        status: 402,
        code: 'daily_limit_reached',
        message: 'Daily limit reached. Resets soon.',
      );

      await h.facade.runTask('too much', sessionId: 's1');

      final run = h.facade.runStateFor('s1');
      expect(run.lastErrorCode, 'daily_limit_reached');
      expect(run.lastErrorMessage, 'Daily limit reached. Resets soon.');
      expect(run.runId, isNull);
      expect(run.busy, isFalse);
      expect(
        h.facade.projectionForTest('s1')!.messages.where((m) => m.role == 'user'),
        isEmpty,
        reason: 'the optimistic row may only be appended after a 202',
      );

      await h.ws.disconnect();
      h.facade.dispose();
    });
  });

  group('projection', () {
    test('busyFor flips on run_started and clears on run_completed', () async {
      final h = await _build();
      await h.facade.runTask('hello', sessionId: 's1');
      final socket = await h.socket();

      expect(h.facade.busyFor('s1'), isFalse,
          reason: 'queued is not running — only run_started is');

      socket.server(_eventFrame('s1', '1-0', 'run_started', {'runId': 'run-1'}));
      await pumpEventQueue();
      expect(h.facade.busyFor('s1'), isTrue);
      expect(h.facade.statusFor('s1'), isNull);

      socket.server(_eventFrame(
          's1', '2-0', 'message_delta', {'runId': 'run-1', 'text': 'hi'}));
      await pumpEventQueue();
      expect(h.facade.liveBubbleTicksFor('s1').value, 1);

      socket.server(_eventFrame('s1', '3-0', 'run_completed', {'runId': 'run-1'}));
      await pumpEventQueue();
      expect(h.facade.busyFor('s1'), isFalse);
      expect(h.facade.runStateFor('s1').busy, isFalse);

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('notifyListeners fires on every projection change', () async {
      final h = await _build();
      await h.facade.runTask('hello', sessionId: 's1');
      final socket = await h.socket();
      var notifications = 0;
      h.facade.addListener(() => notifications++);

      socket.server(_eventFrame('s1', '1-0', 'run_started', {'runId': 'run-1'}));
      await pumpEventQueue();
      expect(notifications, greaterThan(0));

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('run_failed surfaces its code and clears busy + stopRequested', () async {
      final h = await _build();
      await h.facade.runTask('hello', sessionId: 's1');
      final socket = await h.socket();
      socket.server(_eventFrame('s1', '1-0', 'run_started', {'runId': 'run-1'}));
      await pumpEventQueue();
      expect(h.facade.busyFor('s1'), isTrue);

      expect(h.facade.stopRequested(sessionId: 's1'), isTrue);
      await h.facade.hardStopSettledForTest;
      expect(h.facade.runStateFor('s1').stopRequested, isTrue);

      socket.server(_eventFrame('s1', '2-0', 'run_failed', {
        'code': 'cancelled',
        'message': 'Stopped by user.',
      }));
      await pumpEventQueue();

      expect(h.facade.busyFor('s1'), isFalse);
      final run = h.facade.runStateFor('s1');
      expect(run.stopRequested, isFalse,
          reason: 'a terminal event settles the stop request');
      expect(run.lastErrorCode, 'cancelled');
      expect(run.lastErrorMessage, 'Stopped by user.');

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('a later run_started clears the previous run error', () async {
      final h = await _build();
      await h.facade.runTask('first', sessionId: 's1');
      final socket = await h.socket();
      socket.server(_eventFrame('s1', '1-0', 'run_started', {'runId': 'run-1'}));
      await pumpEventQueue();
      socket.server(_eventFrame('s1', '2-0', 'run_failed', {
        'code': 'provider_error',
        'message': 'boom',
      }));
      await pumpEventQueue();
      expect(h.facade.runStateFor('s1').lastErrorCode, 'provider_error');

      await h.facade.runTask('second', sessionId: 's1');
      socket.server(_eventFrame('s1', '3-0', 'run_started', {'runId': 'run-2'}));
      await pumpEventQueue();
      expect(h.facade.runStateFor('s1').lastErrorCode, isNull);

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('same-session FIFO: run-1 completing does not clear run-2 (I-2)', () async {
      final h = await _build();
      await h.facade.runTask('one', sessionId: 's1');
      final socket = await h.socket();
      socket.server(_eventFrame('s1', '1-0', 'run_started', {'runId': 'run-1'}));
      await pumpEventQueue();
      expect(h.facade.busyFor('s1'), isTrue);

      // The server accepts a second send while run-1 runs.
      await h.facade.runTask('two', sessionId: 's1');
      expect(h.facade.runStateFor('s1').runId, 'run-2');
      expect(h.rest.sent, hasLength(2));

      socket.server(_eventFrame('s1', '2-0', 'run_completed', {'runId': 'run-1'}));
      await pumpEventQueue();

      expect(h.facade.busyFor('s1'), isTrue,
          reason: 'run-1 terminalizing must not make run-2 look idle');
      expect(h.facade.stopRequested(sessionId: 's1'), isTrue);
      await pumpEventQueue();
      expect(h.rest.cancelled, ['run-2'],
          reason: 'run-2 stays cancellable across run-1\'s terminal');

      // run-2's own terminal settles.
      socket.server(_eventFrame('s1', '3-0', 'run_started', {'runId': 'run-2'}));
      await pumpEventQueue();
      socket.server(_eventFrame('s1', '4-0', 'run_completed', {'runId': 'run-2'}));
      await pumpEventQueue();
      expect(h.facade.busyFor('s1'), isFalse);

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('a 409 settle is not re-armed by a later projection change (I-2)',
        () async {
      final h = await _build();
      await h.facade.runTask('hello', sessionId: 's1');
      final socket = await h.socket();
      socket.server(_eventFrame('s1', '1-0', 'run_started', {'runId': 'run-1'}));
      await pumpEventQueue();

      h.rest.cancelError = CloudApiException(
        status: 409,
        code: 'run_not_cancellable',
        message: 'Run is already terminal.',
      );
      h.facade.hardStopAll();
      await h.facade.hardStopSettledForTest;
      expect(h.facade.busyFor('s1'), isFalse);

      // The terminal event was missed, so the projection still says busy.
      // Any later structural fold must not resurrect the dead run.
      socket.server(_eventFrame('s1', '2-0', 'system_note', {'text': 'note'}));
      await pumpEventQueue();
      expect(h.facade.busyFor('s1'), isFalse);
      expect(h.facade.runStateFor('s1').runId, isNull,
          reason: 'a terminal run must not leave a live-looking runId');

      await h.ws.disconnect();
      h.facade.dispose();
    });
  });

  group('hardStopAll / stopRequested', () {
    test('posts cancelRun for a live run and reports stopRequested', () async {
      final h = await _build();
      await h.facade.runTask('hello', sessionId: 's1');
      expect(h.facade.runStateFor('s1').busy, isTrue);

      h.facade.hardStopAll();
      expect(h.rest.cancelled, ['run-1']);
      expect(h.facade.runStateFor('s1').stopRequested, isTrue);

      await h.facade.hardStopSettledForTest;
      expect(h.rest.cancelled, ['run-1']);

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('a 409 run_not_cancellable means the run just finished: settle to '
        'not busy', () async {
      final h = await _build();
      await h.facade.runTask('hello', sessionId: 's1');
      final socket = await h.socket();
      socket.server(_eventFrame('s1', '1-0', 'run_started', {'runId': 'run-1'}));
      await pumpEventQueue();
      expect(h.facade.busyFor('s1'), isTrue);

      h.rest.cancelError = CloudApiException(
        status: 409,
        code: 'run_not_cancellable',
        message: 'Run is already terminal.',
      );
      h.facade.hardStopAll();
      await h.facade.hardStopSettledForTest;

      expect(h.facade.busyFor('s1'), isFalse);
      final run = h.facade.runStateFor('s1');
      expect(run.busy, isFalse);
      expect(run.stopRequested, isFalse,
          reason: 'a terminal run has nothing left to stop');
      expect(run.lastErrorCode, isNull,
          reason: '409 run_not_cancellable is an expected cancel race, not '
              'a surfaced error');

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('stopRequested(sessionId:) cancels only that session and returns '
        'whether a run was live', () async {
      final h = await _build();
      await h.facade.runTask('one', sessionId: 's1');
      await h.facade.runTask('two', sessionId: 's2');
      await pumpEventQueue();

      expect(h.facade.stopRequested(sessionId: 's1'), isTrue);
      expect(h.rest.cancelled, ['run-1']);
      expect(h.facade.runStateFor('s1').stopRequested, isTrue);
      expect(h.facade.runStateFor('s2').stopRequested, isFalse);
      expect(h.facade.stopRequested(sessionId: 'nobody'), isFalse);

      await h.facade.hardStopSettledForTest;
      await h.ws.disconnect();
      h.facade.dispose();
    });
  });

  group('setMode', () {
    test('optimistically sets the mode and PATCHes it', () async {
      final h = await _build();
      h.facade.setMode(AgentMode.studio, sessionId: 's1');
      expect(h.rest.patches.single.mode, 'studio');
      expect(h.rest.patches.single.sessionId, 's1');
      expect(h.facade.modeForTest('s1'), AgentMode.studio);

      await h.facade.modePatchSettledForTest('s1');
      expect(h.facade.modeForTest('s1'), AgentMode.studio);

      h.facade.dispose();
    });

    test('reverts the optimistic mode when the PATCH fails', () async {
      final h = await _build();
      h.facade.setMode(AgentMode.studio, sessionId: 's1');
      await h.facade.modePatchSettledForTest('s1');

      h.rest.patchError = CloudApiException(
        status: 500,
        code: 'internal',
        message: 'Could not update the session.',
      );
      h.facade.setMode(AgentMode.drive, sessionId: 's1');
      expect(h.facade.modeForTest('s1'), AgentMode.drive,
          reason: 'optimistic until the failure settles');

      await h.facade.modePatchSettledForTest('s1');
      expect(h.facade.modeForTest('s1'), AgentMode.studio,
          reason: 'the failed pick must not stick');
      expect(h.facade.runStateFor('s1').lastErrorCode, 'internal');

      h.facade.dispose();
    });

    test('reverts to the persisted pre-pick mode, not auto (I-3)', () async {
      final h = await _build();
      final session =
          ChatSession(id: 's1', title: 'S', model: 'm', mode: 'studio');
      AppState.I.sessions.add(session);
      AppState.I.activeSessionId = 's1';
      addTearDown(() {
        AppState.I.sessions.remove(session);
        AppState.I.activeSessionId = null;
      });

      // No prior explicit pick: the effective mode is the persisted studio.
      expect(h.facade.modeForTest('s1'), AgentMode.studio);

      h.rest.patchError = CloudApiException(
        status: 500,
        code: 'internal',
        message: 'Could not update the session.',
      );
      h.facade.setMode(AgentMode.drive, sessionId: 's1');
      expect(h.facade.modeForTest('s1'), AgentMode.drive,
          reason: 'optimistic until the failure settles');

      await h.facade.modePatchSettledForTest('s1');
      expect(h.facade.modeForTest('s1'), AgentMode.studio,
          reason: 'the failed pick must fall back to the persisted mode, '
              'not shadow it with auto');

      h.facade.dispose();
    });
  });

  group('composer queue', () {
    test('queues while busy, then sends the head when the run terminalizes',
        () async {
      final h = await _build();
      await h.facade.runTask('first', sessionId: 's1');
      final socket = await h.socket();
      socket.server(_eventFrame('s1', '1-0', 'run_started', {'runId': 'run-1'}));
      await pumpEventQueue();

      h.facade.enqueueMessage('queued while busy', sessionId: 's1');
      expect(h.facade.queuedMessagesFor('s1'), ['queued while busy']);
      expect(h.facade.queuedMessageIdsFor('s1'), hasLength(1));
      expect(h.rest.sent, hasLength(1), reason: 'not sent while busy');

      socket.server(_eventFrame('s1', '2-0', 'run_completed', {'runId': 'run-1'}));
      await pumpEventQueue();

      expect(h.rest.sent, hasLength(2));
      expect(h.rest.sent.last.content, 'queued while busy');
      expect(h.rest.sent.last.clientMsgId, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(h.facade.queuedMessagesFor('s1'), isEmpty);

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('edit / remove / steer / take / restore operate on stable ids',
        () async {
      final h = await _build();
      // The dock's per-row actions resolve the foreground session, exactly
      // like AgentService's active-bucket semantics.
      AppState.I.activeSessionId = 's1';
      addTearDown(() => AppState.I.activeSessionId = null);
      await h.facade.runTask('first', sessionId: 's1');
      final socket = await h.socket();
      socket.server(_eventFrame('s1', '1-0', 'run_started', {'runId': 'run-1'}));
      await pumpEventQueue();

      h.facade.enqueueMessage('a', sessionId: 's1');
      h.facade.enqueueMessage('b', sessionId: 's1');
      h.facade.enqueueMessage('c', sessionId: 's1');
      final ids = h.facade.queuedMessageIdsFor('s1');
      expect(h.facade.queuedMessagesFor('s1'), ['a', 'b', 'c']);

      h.facade.editQueuedMessageById(ids[1], 'b-edited');
      expect(h.facade.queuedMessagesFor('s1'), ['a', 'b-edited', 'c']);

      h.facade.steerQueuedMessage(2);
      expect(h.facade.queuedMessagesFor('s1'), ['c', 'a', 'b-edited']);

      h.facade.removeQueuedMessageById(ids[0]);
      expect(h.facade.queuedMessagesFor('s1'), ['c', 'b-edited']);

      h.facade.removeQueuedMessage(0);
      expect(h.facade.queuedMessagesFor('s1'), ['b-edited']);

      final taken = h.facade.takeQueuedMessages('s1');
      expect(taken, hasLength(1));
      expect(taken.single.text, 'b-edited');
      expect(h.facade.queuedMessagesFor('s1'), isEmpty);
      expect(h.facade.restoreQueuedMessages('s1', taken), 1);
      expect(h.facade.queuedMessagesFor('s1'), ['b-edited']);

      await h.ws.disconnect();
      h.facade.dispose();
    });
  });

  group('attachments', () {
    test('rejects files over the 25 MB cloud limit without staging', () async {
      final h = await _build();
      final dir = await Directory.systemTemp.createTemp('facade-big');
      addTearDown(() => dir.delete(recursive: true));
      final big = File('${dir.path}/big.bin');
      final raf = await big.open(mode: FileMode.write);
      await raf.truncate(25 * 1024 * 1024 + 1);
      await raf.close();

      final error =
          await h.facade.attachFile(big.path, 'big.bin', sessionId: 's1');

      expect(error, 'File is larger than the 25 MB cloud attachment limit.');
      expect(h.facade.pendingAttachmentsForTest('s1'), isEmpty);

      h.facade.dispose();
    });

    test('stages files at exactly the 25 MB limit', () async {
      final h = await _build();
      final dir = await Directory.systemTemp.createTemp('facade-limit');
      addTearDown(() => dir.delete(recursive: true));
      final atLimit = File('${dir.path}/limit.bin');
      final raf = await atLimit.open(mode: FileMode.write);
      await raf.truncate(25 * 1024 * 1024);
      await raf.close();

      final error =
          await h.facade.attachFile(atLimit.path, 'limit.bin', sessionId: 's1');

      expect(error, isNull);
      expect(h.facade.pendingAttachmentsForTest('s1'), hasLength(1));

      h.facade.dispose();
    });
  });
}
