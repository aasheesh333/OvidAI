// P8 Task 8 — CloudAgentFacade.
//
// The facade composes the landed pieces (Task 5 REST, Task 6 multiplexer,
// Task 7 projector) behind the AgentSurface seam. Every
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
// fake_async comes transitively through flutter_test; promoting it to a
// direct dev_dependency needs a pubspec edit that is outside this task's
// pathspec lane (parallel-wave disjointness) — flagged in the task report
// for the next lockfile-allowed wave. Same waiver as
// cloud_ws_multiplexer_test.dart.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart' show fakeAsync, FakeAsync;
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
      String? clientMsgId, int? maxOutputTokens})> sent = [];
  final List<String> cancelled = [];
  final List<({String sessionId, String? mode})> patches = [];
  final List<({String sessionId, String name, int size})> created = [];
  final List<List<int>> uploaded = [];

  CloudApiException? sendError;
  CloudApiException? cancelError;
  CloudApiException? patchError;

  /// Holds every sendMessage RESPONSE until completed: the call is recorded
  /// (the POST left the device) but the facade stays inside the POST's
  /// in-flight window — the double-tap window under test.
  Completer<void>? sendGate;

  int _seq = 0;

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
    if (sendError != null) throw sendError!;
    sent.add((
      sessionId: sessionId,
      content: content,
      attachmentIds: attachmentIds,
      clientMsgId: clientMsgId,
      maxOutputTokens: maxOutputTokens,
    ));
    if (sendGate != null) await sendGate!.future;
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
      {String? title, String? mode, bool? pinned}) async {
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
      AttachmentUpload upload, List<int> bytes,
      {Duration? timeout}) async {
    uploaded.add(bytes);
  }

  // Wave 1b history edits.
  final List<({String sessionId, String messageId})> truncated = [];
  final List<({String sessionId, String messageId})> regenerated = [];
  final List<({String sessionId, String messageId})> branched = [];
  CloudApiException? historyError;
  String regeneratePromptId = '';

  @override
  Future<int> deleteMessagesFrom(String sessionId, String messageId) async {
    if (historyError != null) throw historyError!;
    truncated.add((sessionId: sessionId, messageId: messageId));
    return 2;
  }

  @override
  Future<RegenerateResponse> regenerateMessage(
    String sessionId,
    String messageId, {
    int? maxOutputTokens,
  }) async {
    if (historyError != null) throw historyError!;
    regenerated.add((sessionId: sessionId, messageId: messageId));
    return RegenerateResponse(
      runId: 'run-regen',
      promptMessageId: regeneratePromptId,
    );
  }

  @override
  Future<SessionDto> branchSession(
    String sessionId,
    String messageId, {
    String? title,
  }) async {
    branched.add((sessionId: sessionId, messageId: messageId));
    return SessionDto(
      id: '0199aaaa-0000-7000-8000-00000000b001',
      title: 'Branch',
      mode: 'auto',
      createdAt: DateTime.utc(2026, 10, 19),
      updatedAt: DateTime.utc(2026, 10, 19),
    );
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

/// The socket's `approval_response` frames, decoded, in wire order.
List<Map<String, dynamic>> _approvalFrames(FakeCloudSocket socket) => [
      for (final raw in socket.sent)
        if ((jsonDecode(raw) as Map<String, dynamic>)['op'] ==
            'approval_response')
          jsonDecode(raw) as Map<String, dynamic>,
    ];

/// One gate-shaped `approval_requested` payload (agent-core approvals.ts:
/// no runId on the wire — the prompt belongs to the session's active run).
Map<String, dynamic> _approvalPayload(String approvalId, {String tool = 'bash'}) =>
    <String, dynamic>{
      'approvalId': approvalId,
      'tool': tool,
      'kind': 'tool',
      'summary': 'Run rm -rf /tmp/build',
      'detail': 'rm -rf /tmp/build',
      'allowAlways': true,
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

Future<_Harness> _build({
  FakeCloudRest? rest,
  Duration Function()? stallWindowFor,
}) async {
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
  final facade = CloudAgentFacade(
    rest: fakeRest,
    ws: ws,
    store: null,
    stallWindowFor: stallWindowFor,
  );
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

    test('Wave1a pending:<clientMsgId> survives rich reseeding and is '
        'confirmed under the actual server id without a duplicate', () async {
      final h = await _build();
      h.rest.sendGate = Completer<void>();
      final send = h.facade.runTask('still sending', sessionId: 's1');
      await pumpEventQueue();
      final clientId = h.rest.sent.single.clientMsgId!;
      expect(h.facade.projectionForTest('s1')!.messages.single.privateSyncId,
          CloudAgentFacade.pendingRowId(clientId));
      h.facade.seedRichTranscript('s1', rows: const [], events: const [],
          watermark: '10-0', activeRunId: null);
      expect(h.facade.projectionForTest('s1')!.messages.single.privateSyncId,
          'pending:$clientId');
      // A snapshot may even see the accepted row before the 202 reaches us.
      h.facade.seedRichTranscript('s1', rows: [
        Message(role: 'user', content: 'still sending', privateSyncId: 'msg-user-1'),
      ], events: const [], watermark: '11-0', activeRunId: null);
      h.rest.sendGate!.complete();
      await send;
      final rows = h.facade.projectionForTest('s1')!.messages
          .where((m) => m.role == 'user').toList();
      expect(rows, hasLength(1));
      expect(rows.single.privateSyncId, 'msg-user-1');
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

    test('the Settings max output cap rides the send (0/auto sends no key; '
        'values above the wire cap degrade to it)', () async {
      final h = await _build();
      addTearDown(() => AppState.I.setMaxOutputTokens(0));

      // Auto: no key on the wire.
      await h.facade.runTask('auto pick', sessionId: 's1');
      expect(h.rest.sent.single.maxOutputTokens, isNull);

      // A cap within the wire limit passes through verbatim.
      await AppState.I.setMaxOutputTokens(4096);
      await h.facade.runTask('four oh nine six', sessionId: 's1');
      expect(h.rest.sent.last.maxOutputTokens, 4096);

      // The 16K/32K Settings presets exceed the shared wire cap: the facade
      // degrades them instead of letting every send 400.
      await AppState.I.setMaxOutputTokens(16384);
      await h.facade.runTask('sixteen k', sessionId: 's1');
      expect(h.rest.sent.last.maxOutputTokens, 8192);
      expect(h.rest.sent.last.content, 'sixteen k');

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('a second send while the first POST is in flight queues instead of '
        'double-spending (chat P1)', () async {
      final h = await _build();
      final gate = Completer<void>();
      h.rest.sendGate = gate;

      final first = h.facade.runTask('one', sessionId: 's1');
      // busyFor already reads busy: the guard is claimed before runTask's
      // first await, not when the POST response lands.
      expect(h.facade.busyFor('s1'), isTrue);

      final second = h.facade.runTask('two', sessionId: 's1');
      await pumpEventQueue();

      // ONE POST. The second call's row waits in the queue.
      expect(h.rest.sent, hasLength(1));
      expect(h.rest.sent.single.content, 'one');
      expect(h.facade.queuedMessagesFor('s1'), ['two']);

      gate.complete();
      await Future.wait([first, second]);
      // The POST landed: busy falls back to run tracking (no run_started
      // yet — 'queued is not running' is unchanged).
      expect(h.facade.busyFor('s1'), isFalse);
      expect(h.rest.sent, hasLength(1));

      // The re-entrant row leaves in order when the first run terminalizes.
      final socket = await h.socket();
      socket.server(
          _eventFrame('s1', '1-0', 'run_started', {'runId': 'run-1'}));
      await pumpEventQueue();
      socket.server(
          _eventFrame('s1', '2-0', 'run_completed', {'runId': 'run-1'}));
      await pumpEventQueue();
      expect(h.rest.sent, hasLength(2));
      expect(h.rest.sent.last.content, 'two');
      expect(h.facade.queuedMessagesFor('s1'), isEmpty);

      await h.ws.disconnect();
      h.facade.dispose();
    });
  });

  // -------------------------------------------------------------------------
  // Response-timeout watchdog (the Settings "Response wait limit"): a
  // user-visible surface only — long silent stretches are legitimate, so
  // nothing is cancelled. The window is injected (5s) so fake time can cross
  // it; production clamps the user's responseTimeoutSec to [30s, 600s].
  // -------------------------------------------------------------------------

  group('response-timeout watchdog', () {
    // Built INSIDE fakeAsync (unlike _build, which pre-connects): the
    // watchdog's periodic timer must be created in the fake zone, and it is
    // created by the run_started listener — which runs in the socket's
    // zone, which is the multiplexer's, which must therefore be fake too.
    _Harness buildInZone(FakeAsync async, SharedPreferences prefs) {
      final fakeRest = FakeCloudRest();
      final zoneSockets = <FakeCloudSocket>[];
      final ws = WsMultiplexer(
        mintTicket: () async => 'ticket',
        socketFactory: (Uri url) async {
          final socket = FakeCloudSocket();
          zoneSockets.add(socket);
          return socket;
        },
        prefs: prefs,
        heartbeatInterval: const Duration(hours: 1),
        pongTimeout: const Duration(hours: 1),
        jitterMs: () => 0,
      );
      final facade = CloudAgentFacade(
        rest: fakeRest,
        ws: ws,
        store: null,
        stallWindowFor: () => const Duration(seconds: 5),
      );
      facade.subscribeForTest('s1');
      async.elapse(const Duration(milliseconds: 50));
      return _Harness(fakeRest, ws, zoneSockets, facade);
    }

    test('silence past the window surfaces stalledFor; a delta re-arms '
        'against a longer silence; run_completed clears it (fake async)',
        () async {
      final prefs = await SharedPreferences.getInstance();
      fakeAsync((async) {
        final h = buildInZone(async, prefs);
        final socket = h.sockets.last;

        socket.server(
            _eventFrame('s1', '1-0', 'run_started', {'runId': 'run-1'}));
        async.elapse(const Duration(milliseconds: 50));
        expect(h.facade.busyFor('s1'), isTrue);
        expect(h.facade.stalledFor('s1'), isFalse);

        // Just under the window: still a normal live run.
        async.elapse(const Duration(seconds: 4, milliseconds: 900));
        expect(h.facade.stalledFor('s1'), isFalse);

        // One tick past the window with NO event of any kind: stalled.
        async.elapse(const Duration(milliseconds: 200));
        expect(h.facade.stalledFor('s1'), isTrue);

        // A delta re-arms: the flag clears the moment traffic resumes…
        socket.server(_eventFrame('s1', '2-0', 'message_delta',
            {'runId': 'run-1', 'text': 'chunk'}));
        async.elapse(const Duration(milliseconds: 50));
        expect(h.facade.stalledFor('s1'), isFalse);

        // …and a LONGER silence than the first window trips it again.
        async.elapse(const Duration(seconds: 5, milliseconds: 200));
        expect(h.facade.stalledFor('s1'), isTrue);

        // The terminal clears it synchronously and stands the watchdog down.
        socket.server(
            _eventFrame('s1', '3-0', 'run_completed', {'runId': 'run-1'}));
        async.elapse(const Duration(milliseconds: 50));
        expect(h.facade.busyFor('s1'), isFalse);
        expect(h.facade.stalledFor('s1'), isFalse);

        // No zombie timer: quiet time after the terminal never re-stalls.
        async.elapse(const Duration(seconds: 30));
        expect(h.facade.stalledFor('s1'), isFalse);

        h.facade.dispose();
        h.ws.disconnect();
      });
    });

    test('run_failed clears the stalled state too', () async {
      final prefs = await SharedPreferences.getInstance();
      fakeAsync((async) {
        final h = buildInZone(async, prefs);
        final socket = h.sockets.last;

        socket.server(
            _eventFrame('s1', '1-0', 'run_started', {'runId': 'run-1'}));
        async.elapse(const Duration(seconds: 5, milliseconds: 100));
        expect(h.facade.stalledFor('s1'), isTrue);

        socket.server(_eventFrame('s1', '2-0', 'run_failed',
            {'runId': 'run-1', 'code': 'model_error'}));
        async.elapse(const Duration(milliseconds: 50));
        expect(h.facade.busyFor('s1'), isFalse);
        expect(h.facade.stalledFor('s1'), isFalse);

        h.facade.dispose();
        h.ws.disconnect();
      });
    });

    test('a run already live when the transcript is seeded arms the watchdog '
        '(reopened mid-run chat: no second run_started)', () async {
      final prefs = await SharedPreferences.getInstance();
      fakeAsync((async) {
        final h = buildInZone(async, prefs);

        // The history page carries the run_started that this socket never
        // saw: the fold is busy, but the stream listener never fires.
        h.facade.seedRichTranscript(
          's1',
          rows: const [],
          events: [
            CloudSessionEvent(
              sessionId: 's1',
              seq: '1-0',
              type: 'run_started',
              payload: const {'runId': 'run-1'},
              ts: DateTime.utc(2026, 10, 17, 10),
            ),
          ],
          watermark: '1-0',
          activeRunId: 'run-1',
        );
        async.elapse(const Duration(milliseconds: 50));
        expect(h.facade.busyFor('s1'), isTrue);
        expect(h.facade.stalledFor('s1'), isFalse);

        // The Settings window still runs out on a seeded live run.
        async.elapse(const Duration(seconds: 5, milliseconds: 200));
        expect(h.facade.stalledFor('s1'), isTrue);

        h.facade.dispose();
        h.ws.disconnect();
      });
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
      // CH-020: the queued-cancel spelling run_failed{cancelled} is a
      // user-initiated stop, never a red error row.
      expect(run.lastErrorCode, isNull);

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('run_cancelled settles busy, clears stopRequested, records no error',
        () async {
      final h = await _build();
      await h.facade.runTask('hello', sessionId: 's1');
      final socket = await h.socket();
      socket.server(_eventFrame('s1', '1-0', 'run_started', {'runId': 'run-1'}));
      await pumpEventQueue();
      expect(h.facade.busyFor('s1'), isTrue);

      expect(h.facade.stopRequested(sessionId: 's1'), isTrue);
      await h.facade.hardStopSettledForTest;
      expect(h.facade.runStateFor('s1').stopRequested, isTrue);

      // The full processor's cancel terminal (loop.ts cancelled()):
      // {runId, reason?} — no code/message.
      socket.server(_eventFrame('s1', '2-0', 'run_cancelled', {'runId': 'run-1'}));
      await pumpEventQueue();

      expect(h.facade.busyFor('s1'), isFalse);
      final run = h.facade.runStateFor('s1');
      expect(run.runId, isNull);
      expect(run.stopRequested, isFalse,
          reason: 'a terminal event settles the stop request');
      expect(run.lastErrorCode, isNull,
          reason: 'a user-initiated cancel is not a surfaced error');

      // The projection fold owns the row the user sees.
      final projection = h.facade.projectionForTest('s1')!;
      expect(projection.busy, isFalse);
      expect(projection.activeRunId, isNull);
      expect(projection.messages.last.kind, MsgKind.turnTail);
      expect(projection.messages.last.content, 'Stopped by user.');

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('a queued row dispatches on run_cancelled (terminal queue drain)',
        () async {
      final h = await _build();
      await h.facade.runTask('first', sessionId: 's1');
      final socket = await h.socket();
      socket.server(_eventFrame('s1', '1-0', 'run_started', {'runId': 'run-1'}));
      await pumpEventQueue();

      h.facade.enqueueMessage('queued while busy', sessionId: 's1');
      expect(h.rest.sent, hasLength(1), reason: 'not sent while busy');

      socket.server(_eventFrame('s1', '2-0', 'run_cancelled', {'runId': 'run-1'}));
      await pumpEventQueue();

      expect(h.rest.sent, hasLength(2));
      expect(h.rest.sent.last.content, 'queued while busy');
      expect(h.facade.queuedMessagesFor('s1'), isEmpty);

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('run_cancelled followed by the compat run_failed{cancelled} '
        'spelling is a full no-op (no duplicate)', () async {
      final h = await _build();
      await h.facade.runTask('hello', sessionId: 's1');
      final socket = await h.socket();
      socket.server(_eventFrame('s1', '1-0', 'run_started', {'runId': 'run-1'}));
      await pumpEventQueue();
      expect(h.facade.busyFor('s1'), isTrue);

      socket.server(_eventFrame('s1', '2-0', 'run_cancelled', {'runId': 'run-1'}));
      await pumpEventQueue();
      expect(h.facade.busyFor('s1'), isFalse);

      // The server may emit BOTH spellings of one cancel; the compat
      // run_failed{cancelled} (no runId) arriving after run_cancelled must
      // be dropped wholesale: no second settle, no recorded error, no
      // second turn-tail row, no queue re-drain.
      socket.server(_eventFrame('s1', '3-0', 'run_failed', {
        'code': 'cancelled',
        'message': 'Stopped by user.',
      }));
      await pumpEventQueue();

      expect(h.facade.busyFor('s1'), isFalse);
      final run = h.facade.runStateFor('s1');
      expect(run.runId, isNull);
      expect(run.lastErrorCode, isNull,
          reason: 'the duplicate compat spelling must not surface an error');
      expect(h.rest.sent, hasLength(1), reason: 'no second drain');
      expect(h.rest.cancelled, isEmpty);
      final projection = h.facade.projectionForTest('s1')!;
      final tails =
          projection.messages.where((m) => m.kind == MsgKind.turnTail).toList();
      expect(tails, hasLength(1), reason: 'the duplicate appended no row');
      expect(tails.single.content, 'Stopped by user.');

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('CH-019: a run failure has ONE surface — the inline failure row, '
        'never the banner too', () async {
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
      expect(h.facade.runStateFor('s1').lastErrorCode, isNull,
          reason: 'no banner for a run-level failure');
      final tail = h.facade.transcriptFor('s1')!.last;
      expect(tail.kind, MsgKind.turnTail);
      expect(tail.toolName, 'run_failed');
      expect(tail.toolSummary, 'provider_error');

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

    test('a queued row keeps its staged files; a file staged later does not '
        'ride with it (chat P1)', () async {
      final h = await _build();
      final dir = await Directory.systemTemp.createTemp('facade-queue-att');
      addTearDown(() => dir.delete(recursive: true));
      final first = File('${dir.path}/first.txt');
      await first.writeAsString('first file bytes');
      final later = File('${dir.path}/later.txt');
      await later.writeAsString('later file bytes');

      await h.facade.runTask('start', sessionId: 's1');
      final socket = await h.socket();
      socket.server(
          _eventFrame('s1', '1-0', 'run_started', {'runId': 'run-1'}));
      await pumpEventQueue();
      expect(h.facade.busyFor('s1'), isTrue);

      // Stage a file, then queue a row: ownership moves onto the row.
      expect(
          await h.facade.attachFile(first.path, 'first.txt', sessionId: 's1'),
          isNull);
      h.facade.enqueueMessage('queued', sessionId: 's1');
      expect(h.facade.pendingAttachmentsForTest('s1'), isEmpty,
          reason: 'the staged file left the composer with the row');
      expect(h.facade.queuedMessagesFor('s1'), ['queued']);

      // A file staged AFTER queueing belongs to the next message.
      expect(
          await h.facade.attachFile(later.path, 'later.txt', sessionId: 's1'),
          isNull);

      socket.server(
          _eventFrame('s1', '2-0', 'run_completed', {'runId': 'run-1'}));
      await pumpEventQueue();

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await pumpEventQueue();
      // The row dispatched with ITS file — and only its file.
      expect(h.rest.created, hasLength(1));
      expect(h.rest.created.single.name, 'first.txt');
      expect(h.rest.sent.last.content, 'queued');
      expect(h.rest.sent.last.attachmentIds, ['att-1']);
      // The later-staged file survives for the NEXT message.
      expect(h.facade.pendingAttachmentsForTest('s1').single.name, 'later.txt');

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('edit / remove / steer / take / restore operate on stable ids',
        () async {
      final h = await _build();
      // The dock's per-row actions resolve the foreground session, exactly
      // like the retired local service's active-bucket semantics.
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

    test('editing a queued row replaces its project refs before dispatch',
        () async {
      final h = await _build();
      AppState.I.activeSessionId = 's1';
      addTearDown(() => AppState.I.activeSessionId = null);
      await h.facade.runTask('first', sessionId: 's1');
      final socket = await h.socket();
      socket.server(_eventFrame('s1', '1-0', 'run_started', {'runId': 'run-1'}));
      await pumpEventQueue();

      h.facade.enqueueMessage(
        'use @project:old',
        sessionId: 's1',
        projectRefs: const ['0192f0a0-0000-7000-8000-000000000001'],
      );
      final id = h.facade.queuedMessageIdsFor('s1').single;
      // The edit removes the tag and replaces the refs.
      h.facade.editQueuedMessageById(id, 'plain now', projectRefs: const []);

      socket.server(
          _eventFrame('s1', '2-0', 'run_completed', {'runId': 'run-1'}));
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await pumpEventQueue();

      expect(h.rest.sent.last.content, 'plain now');
      expect(h.rest.lastTurn.projectRefs, isEmpty);

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
      // CH-022: the SERVER's limit is 25,000,000 bytes (not 25 MiB).
      await raf.truncate(CloudAgentFacade.maxAttachmentBytes + 1);
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
      await raf.truncate(CloudAgentFacade.maxAttachmentBytes);
      await raf.close();

      final error =
          await h.facade.attachFile(atLimit.path, 'limit.bin', sessionId: 's1');

      expect(error, isNull);
      expect(h.facade.pendingAttachmentsForTest('s1'), hasLength(1));

      h.facade.dispose();
    });

    test('CH-022: the limit is the server\'s 25,000,000 bytes and an empty '
        'file is refused at staging time', () async {
      expect(CloudAgentFacade.maxAttachmentBytes, 25000000);
      final h = await _build();
      final dir = await Directory.systemTemp.createTemp('facade-empty');
      addTearDown(() => dir.delete(recursive: true));
      final empty = File('${dir.path}/empty.txt')..writeAsBytesSync(const []);
      final error =
          await h.facade.attachFile(empty.path, 'empty.txt', sessionId: 's1');
      expect(error, 'empty.txt is empty, so there is nothing to send.');
      expect(h.facade.pendingAttachmentsForTest('s1'), isEmpty);
      h.facade.dispose();
    });
  });

  // -------------------------------------------------------------------------
  // Approvals (P3 Task 12): the gate emits approval_requested/approval_resolved
  // as session events; the facade surfaces the prompt behind
  // AgentSurface.pendingApproval and answers the worker's bridge with the
  // approval_response WS op (shared ws.ts WsClientMsg — the gateway validates
  // ownership + the decision enum and acks with approval_ack).
  // -------------------------------------------------------------------------

  group('approvals', () {
    setUp(() {
      // pendingApproval/pendingApprovalsElsewhere resolve through the
      // ACTIVE session — the same wiring chat_screen reads.
      AppState.resetTestInstance();
      final app = AppState.createForTest();
      app.sessions
        ..clear()
        ..add(ChatSession(id: 's1', title: 'Active', model: 'm'))
        ..add(ChatSession(id: 's2', title: 'Background', model: 'm'));
      app.activeSessionId = 's1';
    });

    tearDown(() {
      AppState.resetTestInstance();
    });

    test('approval_requested surfaces pendingApproval; approveRequest answers '
        'the bridge with the approval_response op', () async {
      final h = await _build();
      h.facade.subscribeForTest('s1');
      final socket = await h.socket();

      socket.server(_eventFrame('s1', '1-0', 'run_started', {'runId': 'run-1'}));
      socket.server(_eventFrame(
          's1', '2-0', 'approval_requested', _approvalPayload('ap-1')));
      await pumpEventQueue();

      final req = h.facade.pendingApproval;
      expect(req, isNotNull);
      expect(req!.tool, 'bash');
      expect(req.summary, 'Run rm -rf /tmp/build');
      expect(req.detail, 'rm -rf /tmp/build');
      expect(req.allowAlways, isTrue);
      expect(req.approvalId, 'ap-1');
      // The foreground session's own prompt is not "elsewhere".
      expect(h.facade.pendingApprovalsElsewhere, isEmpty);

      expect(h.facade.approveRequest(req, true), isTrue);
      expect(_approvalFrames(socket), <Map<String, dynamic>>[
        <String, dynamic>{
          'op': 'approval_response',
          'sessionId': 's1',
          'approvalId': 'ap-1',
          'decision': 'allow',
        },
      ]);
      // CH-017: the card stays up ("Sending…") until the server confirms.
      expect(h.facade.pendingApproval, same(req));
      expect(req.sending, isTrue);

      // A second tap while the first is in flight answers nothing.
      expect(h.facade.approveRequest(req, true), isFalse);
      expect(_approvalFrames(socket), hasLength(1));

      // The gateway's approval_ack confirms: the card goes away for good.
      socket.server(<String, dynamic>{
        'op': 'approval_ack',
        'approvalId': 'ap-1',
        'decision': 'allow',
      });
      await pumpEventQueue();
      expect(h.facade.pendingApproval, isNull);
      expect(h.facade.approveRequest(req, true), isFalse);

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('deny and always spellings of the decision enum', () async {
      final h = await _build();
      h.facade.subscribeForTest('s1');
      final socket = await h.socket();

      socket.server(_eventFrame(
          's1', '1-0', 'approval_requested', _approvalPayload('ap-1')));
      await pumpEventQueue();
      expect(h.facade.approveRequest(h.facade.pendingApproval!, false),
          isTrue);
      expect(_approvalFrames(socket).single['decision'], 'deny');

      socket.server(_eventFrame(
          's1', '2-0', 'approval_requested', _approvalPayload('ap-2')));
      await pumpEventQueue();
      expect(h.facade.approveAlwaysRequest(h.facade.pendingApproval!), isTrue);
      expect(_approvalFrames(socket).last['decision'], 'always');

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('approval_resolved clears the prompt; a late tap answers nothing '
        '(the timeout-deny spelling included)', () async {
      final h = await _build();
      h.facade.subscribeForTest('s1');
      final socket = await h.socket();

      socket.server(_eventFrame(
          's1', '1-0', 'approval_requested', _approvalPayload('ap-1')));
      await pumpEventQueue();
      final req = h.facade.pendingApproval!;
      expect(req, isNotNull);

      socket.server(_eventFrame('s1', '2-0', 'approval_resolved',
          {'approvalId': 'ap-1', 'decision': 'deny', 'reason': 'timeout'}));
      await pumpEventQueue();
      expect(h.facade.pendingApproval, isNull);

      expect(h.facade.approveRequest(req, true), isFalse);
      expect(_approvalFrames(socket), isEmpty);

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('a terminal event auto-dismisses a standing prompt', () async {
      final h = await _build();
      h.facade.subscribeForTest('s1');
      final socket = await h.socket();

      socket.server(_eventFrame('s1', '1-0', 'run_started', {'runId': 'run-1'}));
      socket.server(_eventFrame(
          's1', '2-0', 'approval_requested', _approvalPayload('ap-1')));
      await pumpEventQueue();
      expect(h.facade.pendingApproval, isNotNull);

      socket.server(_eventFrame('s1', '3-0', 'run_failed',
          {'code': 'internal', 'message': 'boom'}));
      await pumpEventQueue();
      expect(h.facade.pendingApproval, isNull);

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('a background session prompt surfaces through '
        'pendingApprovalsElsewhere and answers under ITS session id', () async {
      final h = await _build();
      h.facade.subscribeForTest('s1');
      h.facade.subscribeForTest('s2');
      final socket = await h.socket();

      socket.server(_eventFrame(
          's2', '1-0', 'approval_requested', _approvalPayload('ap-bg')));
      await pumpEventQueue();

      // The foreground session (s1) has no prompt of its own.
      expect(h.facade.pendingApproval, isNull);
      final elsewhere = h.facade.pendingApprovalsElsewhere;
      expect(elsewhere, hasLength(1));
      expect(elsewhere.single.sessionId, 's2');
      expect(elsewhere.single.title, 'Background');
      expect(elsewhere.single.request.approvalId, 'ap-bg');

      expect(h.facade.approveRequest(elsewhere.single.request, true), isTrue);
      expect(_approvalFrames(socket).single, <String, dynamic>{
        'op': 'approval_response',
        'sessionId': 's2',
        'approvalId': 'ap-bg',
        'decision': 'allow',
      });

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('CH-017: an unconfirmed answer brings the card back (timeout and '
        'a session error frame)', () async {
      final saved = CloudAgentFacade.approvalConfirmTimeout;
      CloudAgentFacade.approvalConfirmTimeout =
          const Duration(milliseconds: 30);
      addTearDown(() => CloudAgentFacade.approvalConfirmTimeout = saved);
      final h = await _build();
      h.facade.subscribeForTest('s1');
      final socket = await h.socket();
      socket.server(_eventFrame(
          's1', '1-0', 'approval_requested', _approvalPayload('ap-1')));
      await pumpEventQueue();
      final req = h.facade.pendingApproval!;
      expect(h.facade.approveRequest(req, true), isTrue);
      expect(req.sending, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(req.sending, isFalse, reason: 'no ack arrived: answer again');
      expect(h.facade.pendingApproval, same(req));

      expect(h.facade.approveRequest(req, false), isTrue);
      socket.server(<String, dynamic>{
        'op': 'error',
        'code': 'unavailable',
        'message': 'Approvals are unavailable.',
        'sessionId': 's1',
      });
      await pumpEventQueue();
      expect(req.sending, isFalse);
      expect(_approvalFrames(socket), hasLength(2));

      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('CH-017: a plan prompt keeps its kind, plan body and expiry', () async {
      final h = await _build();
      h.facade.subscribeForTest('s1');
      final socket = await h.socket();
      socket.server(_eventFrame('s1', '1-0', 'approval_requested', <String, dynamic>{
        'approvalId': 'ap-plan',
        'tool': 'exit_plan_mode',
        'kind': 'plan',
        'summary': 'Ready to build?',
        'detail': 'Review this plan:\n\n1. Add the route\n2. Test it',
        'allowAlways': false,
        'expiresAt': '2026-10-19T12:00:00.000Z',
      }));
      await pumpEventQueue();
      final req = h.facade.pendingApproval!;
      expect(req.kind, 'plan');
      expect(req.planBody, '1. Add the route\n2. Test it');
      expect(req.expiresAt, DateTime.utc(2026, 10, 19, 12));
      expect(req.allowAlways, isFalse);
      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('the test seam still shadows the live prompt', () async {
      final h = await _build();
      h.facade.subscribeForTest('s1');
      final socket = await h.socket();
      socket.server(_eventFrame(
          's1', '1-0', 'approval_requested', _approvalPayload('ap-1')));
      await pumpEventQueue();

      final seeded = ApprovalRequest(
          tool: 'shell', summary: 's', detail: 'd');
      h.facade.pendingApprovalForTest = seeded;
      expect(identical(h.facade.pendingApproval, seeded), isTrue);

      h.facade.pendingApprovalForTest = null;
      expect(h.facade.pendingApproval?.approvalId, 'ap-1');

      await h.ws.disconnect();
      h.facade.dispose();
    });
  });

  group('Wave 1b', () {
    const u1 = '0199aaaa-0000-7000-8000-000000000001';
    const a1 = '0199aaaa-0000-7000-8000-000000000002';
    const u2 = '0199aaaa-0000-7000-8000-000000000003';
    const a2 = '0199aaaa-0000-7000-8000-000000000004';

    setUp(() {
      AppState.resetTestInstance();
      final app = AppState.createForTest();
      app.sessions
        ..clear()
        ..add(ChatSession(id: 's1', title: 'Active', model: 'm'));
      app.activeSessionId = 's1';
    });

    tearDown(AppState.resetTestInstance);

    Future<(_Harness, FakeCloudSocket)> seeded() async {
      final h = await _build();
      h.facade.seedTranscript('s1', <Message>[
        Message(role: 'user', content: 'q1', privateSyncId: u1),
        Message(role: 'assistant', content: 'a1', privateSyncId: a1),
        Message(role: 'user', content: 'q2', privateSyncId: u2),
        Message(role: 'assistant', content: 'a2', privateSyncId: a2),
      ], null);
      final socket = await h.socket();
      return (h, socket);
    }

    test('CH-016: run_merged settles the merged run instead of leaving the '
        'composer busy', () async {
      final h = await _build();
      h.facade.subscribeForTest('s1');
      final socket = await h.socket();
      socket.server(_eventFrame('s1', '1-0', 'run_started', {'runId': 'run-A'}));
      await pumpEventQueue();
      // A second send while run-A is active: the client tracks its run.
      await h.facade.runTask('follow-up', sessionId: 's1');
      await pumpEventQueue();
      final tracked = h.facade.runStateFor('s1').runId;
      socket.server(_eventFrame('s1', '2-0', 'system_note', {
        'code': 'run_merged',
        'mergedRunId': tracked,
        'runId': 'run-A',
      }));
      await pumpEventQueue();
      expect(h.facade.runStateFor('s1').runId, 'run-A',
          reason: 'the tracked run is now the one that absorbed it');
      socket.server(_eventFrame('s1', '3-0', 'run_completed', {'runId': 'run-A'}));
      await pumpEventQueue();
      expect(h.facade.busyFor('s1'), isFalse);
      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('CH-028: subagents, the Jobs list and the context ring come from '
        'real events', () async {
      final h = await _build();
      h.facade.subscribeForTest('s1');
      final socket = await h.socket();
      for (final f in <Map<String, Object?>>[
        _eventFrame('s1', '1-0', 'run_started', {'runId': 'r1'}),
        _eventFrame('s1', '1-1', 'tool_started', {
          'runId': 'r1',
          'callId': 'd1',
          'name': 'dispatch_agent',
          'args': {'prompt': 'edit files', 'agentType': 'CodeSubagent'},
        }),
        _eventFrame('s1', '1-2', 'subagent_started', {
          'runId': 'r1',
          'childSessionId': 'child-1',
          'childRunId': 'cr-1',
          'agentType': 'CodeSubagent',
          'prompt': 'edit files',
        }),
      ]) {
        socket.server(f);
      }
      await pumpEventQueue();
      final subs = h.facade.subagentsOf('s1');
      expect(subs.single.sessionId, 'child-1');
      expect(subs.single.label, 'CodeSubagent');
      expect(subs.single.finished, isFalse);
      // The child session is watched: its tool activity feeds the card.
      socket.server(_eventFrame('child-1', '1-0', 'run_started', {'runId': 'cr-1'}));
      socket.server(_eventFrame('child-1', '1-1', 'tool_started', {
        'runId': 'cr-1',
        'callId': 'x',
        'name': 'fs_edit',
        'args': {'path': 'lib/a.dart'},
      }));
      await pumpEventQueue();
      final jobs = h.facade.jobsFor('s1');
      expect(jobs.single.name, 'CodeSubagent: Editing lib/a.dart');
      h.facade.killJobFor('s1', jobs.single.id);
      await pumpEventQueue();
      expect(h.rest.cancelled, contains('cr-1'));

      socket.server(_eventFrame('s1', '2-0', 'subagent_completed',
          {'childRunId': 'cr-1', 'status': 'completed'}));
      socket.server(_eventFrame('s1', '2-1', 'message_completed',
          {'messageId': 'm1', 'content': 'done'}));
      socket.server(_eventFrame('s1', '2-2', 'run_completed', {
        'runId': 'r1',
        'usage': {'inputTokens': 900, 'outputTokens': 100, 'contextTokens': 1000},
      }));
      await pumpEventQueue();
      expect(h.facade.jobsFor('s1'), isEmpty);
      expect(h.facade.measuredContextTokens(AppState.I.sessionById('s1')!), 1000);
      expect(h.facade.sessionMessageTokens, 1000);
      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('todo/goal/plan events reach the ChatSession the docks render', () async {
      final h = await _build();
      h.facade.subscribeForTest('s1');
      final socket = await h.socket();
      socket.server(_eventFrame('s1', '1-0', 'todo_updated', {
        'todos': [
          {'content': 'a', 'status': 'in_progress'},
        ],
      }));
      socket.server(_eventFrame('s1', '1-1', 'goal_updated', {
        'goal': {'objective': 'Ship', 'notes': ''},
      }));
      socket.server(_eventFrame('s1', '1-2', 'plan_mode_changed', {'planMode': true}));
      await pumpEventQueue();
      final s = AppState.I.sessionById('s1')!;
      expect(s.todos, [
        {'content': 'a', 'status': 'in_progress'},
      ]);
      expect(s.goal?['objective'], 'Ship');
      expect(s.planMode, isTrue);
      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('deleteFrom truncates on the server and locally', () async {
      final (h, _) = await seeded();
      final rows = h.facade.transcriptFor('s1')!;
      await h.facade.deleteFrom('s1', rows[2]);
      expect(h.rest.truncated.single, (sessionId: 's1', messageId: u2));
      expect(h.facade.transcriptFor('s1')!.map((m) => m.content), ['q1', 'a1']);
      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('regenerate re-runs on the server, trims after the prompt and shows '
        'Stop for the new run', () async {
      final (h, _) = await seeded();
      h.rest.regeneratePromptId = u2;
      final rows = h.facade.transcriptFor('s1')!;
      await h.facade.regenerate('s1', rows[3]);
      expect(h.rest.regenerated.single.messageId, a2);
      expect(h.facade.transcriptFor('s1')!.map((m) => m.content),
          ['q1', 'a1', 'q2']);
      expect(h.facade.busyFor('s1'), isTrue);
      expect(h.facade.runStateFor('s1').runId, 'run-regen');
      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('retryFailedRun re-runs the last prompt in place (no duplicate row)', () async {
      final (h, _) = await seeded();
      h.rest.regeneratePromptId = u2;
      await h.facade.retryFailedRun('s1');
      expect(h.rest.regenerated.single.messageId, u2);
      expect(h.rest.sent, isEmpty);
      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('a busy session refuses edits with the server error; rows that the '
        'server does not store are refused locally', () async {
      final (h, _) = await seeded();
      h.rest.historyError = CloudApiException(
          status: 409, code: 'session_busy', message: 'busy');
      final rows = h.facade.transcriptFor('s1')!;
      await expectLater(h.facade.deleteFrom('s1', rows[0]),
          throwsA(isA<CloudApiException>()));
      expect(h.facade.transcriptFor('s1'), hasLength(4));
      h.rest.historyError = null;
      final tool = Message(
          role: 'assistant', kind: MsgKind.tool, privateSyncId: 'tool:c1');
      expect(CloudAgentFacade.isServerMessage(tool), isFalse);
      await expectLater(h.facade.regenerate('s1', tool),
          throwsA(isA<CloudApiException>()));
      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('branchFrom returns the new server chat id', () async {
      final (h, _) = await seeded();
      final rows = h.facade.transcriptFor('s1')!;
      final id = await h.facade.branchFrom('s1', rows[1]);
      expect(id, '0199aaaa-0000-7000-8000-00000000b001');
      expect(h.rest.branched.single, (sessionId: 's1', messageId: a1));
      await h.ws.disconnect();
      h.facade.dispose();
    });

    test('oldestServerMessageId skips rich rows (paging cursor)', () async {
      final h = await _build();
      h.facade.seedTranscript('s1', <Message>[
        Message(role: 'assistant', kind: MsgKind.tool, privateSyncId: 'tool:c'),
        Message(role: 'user', content: 'q', privateSyncId: u1),
      ], null);
      expect(h.facade.oldestServerMessageId('s1'), u1);
      h.facade.dispose();
    });
  });
}
