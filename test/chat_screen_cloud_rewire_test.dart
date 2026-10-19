// P8 Task 10 — chat rewire: `chat_screen.dart` on the facade.
//
// The app is the thin client on every build since Task 20 removed the
// dual-path flag. Everything here binds a facade + store to fakes, proving:
//   * typing + Send reaches the FACADE's REST client (never a local run);
//   * a run_started / message_delta / message_completed sequence through the
//     fake socket renders a live bubble and then the finalized row;
//   * the FIRST message_delta flips that bubble out of the "Thinking…" card
//     so the answer streams through the answer path (pre-delta content, if
//     any, is kept as the "Thought for" block above the answer);
//   * queued outbox entries render the composer queue chip;
//   * Review Focus #4 — a 402 `daily_limit_reached` with `x-ovid-resets-at`
//     shows the server message VERBATIM plus a resets countdown, and the
//     composed draft survives dismissing the error.
//
// The thin arm is covered here; the facade is the only agent implementation
// since Task 19 deleted the local service.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/connection_service.dart';
import 'package:ovid_ai/core/diag.dart';
import 'package:ovid_ai/core/session_history_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class FakeChatRest extends CloudRestClient {
  FakeChatRest() : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  final List<
      ({
        String sessionId,
        String content,
        List<String> attachmentIds,
        String? clientMsgId,
      })> sent = [];

  /// 402/409/503 answers keyed by the prompt content being sent.
  final Map<String, CloudApiException> sendErrors = <String, CloudApiException>{};

  /// Holds every sendMessage RESPONSE until completed: the POST is recorded
  /// (it left the device) but the facade stays inside the POST's in-flight
  /// window — the double-tap window under test.
  Completer<void>? sendGate;

  /// Title PATCHes (the rename sync), in call order.
  final List<({String sessionId, String? title, String? mode})> patched = [];
  CloudApiException? patchError;

  /// Server-side message history keyed by session id, OLDEST-first (the
  /// model's order); the wire answers newest-first, so page slices come
  /// back reversed — mirroring `GET /sessions/:id/messages`.
  final Map<String, List<MessageDto>> historyBySession =
      <String, List<MessageDto>>{};

  /// Every pageMessages call, in order — the pager tests read the `before`
  /// cursors out of these.
  final List<({String sessionId, String? before, int limit})> paged = [];

  /// Thrown only for older-page fetches (`before != null`): the boot's
  /// newest-page load stays clean, so a failure lands in the pager alone.
  CloudApiException? olderPageError;

  /// Thrown for every newest-page fetch while set (CH-035: a failed first
  /// history load).
  CloudApiException? newestPageError;

  int _seq = 0;

  @override
  Future<SessionDto> patchSession(String id,
      {String? title, String? mode}) async {
    patched.add((sessionId: id, title: title, mode: mode));
    if (patchError != null) throw patchError!;
    return SessionDto(
      id: id,
      title: title,
      mode: mode ?? 'auto',
      createdAt: DateTime.utc(2026, 10, 17),
      updatedAt: DateTime.utc(2026, 10, 17),
    );
  }

  @override
  Future<SessionDto> createSession({String? title}) async => SessionDto(
        id: 'srv-created',
        title: title,
        mode: 'auto',
        createdAt: DateTime.utc(2026, 10, 17),
        updatedAt: DateTime.utc(2026, 10, 17),
      );

  @override
  Future<CloudPage<SessionDto>> listSessions(
      {int limit = 50, String? cursor}) async {
    return const CloudPage<SessionDto>(items: [], nextCursor: null);
  }

  @override
  Future<CloudPage<MessageDto>> pageMessages(
    String sessionId, {
    int limit = 50,
    String? before,
    bool withEvents = false,
  }) async {
    paged.add((sessionId: sessionId, before: before, limit: limit));
    if (before != null && olderPageError != null) throw olderPageError!;
    final newestError = newestPageError;
    if (before == null && newestError != null) throw newestError;
    final history = historyBySession[sessionId] ?? const <MessageDto>[];
    // Server semantics: the page before `before` holds the `limit` rows
    // strictly OLDER than that message, newest first. `before` = the
    // oldest message (or an unknown id) is the empty final page.
    var end = history.length;
    if (before != null) {
      final i = history.indexWhere((m) => m.id == before);
      if (i <= 0) {
        return const CloudPage<MessageDto>(items: [], nextCursor: null);
      }
      end = i;
    }
    final start = end - limit < 0 ? 0 : end - limit;
    return CloudPage<MessageDto>(
      items: history.sublist(start, end).reversed.toList(),
      nextCursor: null,
    );
  }

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
    final error = sendErrors[content];
    if (error != null) throw error;
    sent.add((
      sessionId: sessionId,
      content: content,
      attachmentIds: attachmentIds,
      clientMsgId: clientMsgId,
    ));
    if (sendGate != null) await sendGate!.future;
    final n = ++_seq;
    return SendMessageResponse(
      runId: 'run-$n',
      userMessageId: 'msg-user-$n',
      status: 'queued',
    );
  }
}

class FakeChatSocket implements CloudSocket {
  final StreamController<Object> _frames = StreamController<Object>.broadcast();
  final StreamController<void> _closed = StreamController<void>.broadcast();

  /// Every client frame that reached the wire, decoded, in order — the
  /// subscribe frames, pings, and the approval ops alike.
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  @override
  Stream<Object> get frames => _frames.stream;

  @override
  Stream<void> get closed => _closed.stream;

  @override
  int? get closeCode => null;

  @override
  void sendText(String frame) {
    try {
      final decoded = jsonDecode(frame);
      if (decoded is Map<String, dynamic>) sent.add(decoded);
    } catch (_) {
      // Not a JSON object frame — nothing the harness needs to assert on.
    }
  }

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
        'ts': '2026-10-17T10:00:00.000Z',
      },
    };

class _Harness {
  _Harness(this.rest, this.ws, this.store, this.facade, this.sockets);

  final FakeChatRest rest;
  final WsMultiplexer ws;
  final CloudSessionStore store;
  final CloudAgentFacade facade;
  final List<FakeChatSocket> sockets;

  /// Tears the link down INSIDE the test body: `addTearDown` runs after
  /// flutter_test's pending-timer invariant check, so the heartbeat periodic
  /// timer must be cancelled before the body returns.
  Future<void> close() async {
    await ws.disconnect();
    facade.dispose();
  }

  FakeChatSocket socket() {
    // NOTE: no `pumpEventQueue()` here — inside `testWidgets` the fake clock
    // never advances a `Future.delayed(Duration.zero)`, so it deadlocks. The
    // send path was already pumped by `_send`, which is what lets the facade
    // subscribe (and the socket factory run).
    expect(sockets, isNotEmpty, reason: 'the facade must subscribe on demand');
    return sockets.last;
  }
}

Future<_Harness> _bind() async {
  // NOTE: this runs inside `testWidgets` — no `pumpEventQueue()` (the fake
  // clock never fires a zero-delay timer). Every await below resolves on
  // microtasks, which the test binding drains between awaits.
  final prefs = await SharedPreferences.getInstance();
  // 'srv-1' IS a server id (the session row a reconciliation would key by
  // it): seed the store's known-server set so a first send passes through
  // instead of creating a duplicate server session.
  await prefs.setString(CloudSessionStore.knownServerIdsKey,
      jsonEncode(<String>['srv-1']));
  final sockets = <FakeChatSocket>[];
  final ws = WsMultiplexer(
    mintTicket: () async => 'ticket',
    socketFactory: (Uri url) async {
      final socket = FakeChatSocket();
      sockets.add(socket);
      return socket;
    },
    prefs: prefs,
    heartbeatInterval: const Duration(hours: 1),
    pongTimeout: const Duration(hours: 1),
    jitterMs: () => 0,
  );
  await ws.connectIfNeeded();

  final rest = FakeChatRest();
  final store = CloudSessionStore(
    rest: rest,
    cache: SessionHistoryRepository.I,
    prefs: prefs,
    connection: ConnectionService.forTest(),
    ws: ws,
    autoRetry: false,
  );
  final facade = CloudAgentFacade(rest: rest, ws: ws, store: store);
  CloudSessionStore.installForTest(store);
  CloudAgentFacade.installForTest(facade);
  await store.ready;
  return _Harness(rest, ws, store, facade, sockets);
}

ChatSession _addSession(String id) {
  final session = ChatSession(id: id, title: 'Cloud chat', model: 'm');
  AppState.I.sessions.add(session);
  AppState.I.activeSessionId = id;
  return session;
}

/// Seeds [rest] with [count] single-row messages (`msg-0` oldest).
void _seedHistory(FakeChatRest rest, String sessionId, int count) {
  rest.historyBySession[sessionId] = <MessageDto>[
    for (var i = 0; i < count; i++)
      MessageDto(
        id: 'msg-$i',
        sessionId: sessionId,
        role: 'user',
        content: 'm$i',
        createdAt: DateTime.utc(2026, 10, 17),
      ),
  ];
}

Future<void> _pumpChat(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('chat-composer')), text);
  await tester.pump();
  await tester.tap(find.byTooltip('Send'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    AppState.resetTestInstance();
    AppState.createForTest();
    Diag.resetForTest();
    // The local engine must never be consulted; pausing its timer keeps the
    // assertion below safe to make without pending-timer noise.
  });

  tearDown(() async {
    CloudAgentFacade.resetForTest();
    CloudSessionStore.resetForTest();
    AppState.resetTestInstance();
  });

  testWidgets('typing + Send calls runTask on the FACADE, never the local service',
      timeout: const Timeout(Duration(seconds: 60)), (tester) async {
    final h = await _bind();
    addTearDown(() async {
      await h.ws.disconnect();
      h.facade.dispose();
    });
    _addSession('srv-1');
    await _pumpChat(tester);

    await _send(tester, 'hello cloud');

    expect(h.rest.sent, hasLength(1));
    expect(h.rest.sent.single.sessionId, 'srv-1');
    expect(h.rest.sent.single.content, 'hello cloud');
    expect(h.rest.sent.single.clientMsgId, matches(RegExp(r'^[0-9a-f]{32}$')));
    // The local engine never ran.
    expect(CloudAgentFacade.I.busyFor('srv-1'), isFalse);
    // The optimistic user row renders from the facade projection.
    expect(find.textContaining('hello cloud'), findsWidgets);
    await h.close();
  });

  testWidgets(
      'a double-tap Send while the POST is in flight queues the second '
      'message — ONE server POST (chat P1)',
      timeout: const Timeout(Duration(seconds: 60)), (tester) async {
    final h = await _bind();
    addTearDown(() async {
      await h.ws.disconnect();
      h.facade.dispose();
    });
    _addSession('srv-1');
    await _pumpChat(tester);

    final gate = Completer<void>();
    h.rest.sendGate = gate;

    await tester.enterText(
        find.byKey(const ValueKey('chat-composer')), 'hello cloud');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    // busyFor covers the POST's in-flight window: a second send would queue.
    expect(h.facade.busyFor('srv-1'), isTrue);

    // CH-011: the prompt left the composer the moment it was safe in the
    // outbox and shows as a pending row — there is nothing left for a second
    // tap to send, so a double tap can never double-run.
    final editable = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('chat-composer')),
        matching: find.byType(EditableText),
      ),
    );
    expect(editable.controller.text, isEmpty);
    expect(find.text('Sending…'), findsOneWidget);
    expect(h.rest.sent, hasLength(1), reason: 'one POST, one run');
    expect(h.rest.sent.single.content, 'hello cloud');

    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(h.rest.sent, hasLength(1));
    // Confirmed: the pending status is gone, the row stays.
    expect(find.text('Sending…'), findsNothing);
    expect(find.textContaining('hello cloud'), findsWidgets);
    await h.close();
  });

  testWidgets(
      'run_started / message_delta / message_completed renders a live bubble '
      'then finalizes', timeout: const Timeout(Duration(seconds: 60)),
      (tester) async {
    final h = await _bind();
    addTearDown(() async {
      await h.ws.disconnect();
      h.facade.dispose();
    });
    _addSession('srv-1');
    await _pumpChat(tester);

    await _send(tester, 'hello cloud');
    final socket = h.socket();

    socket.server(_eventFrame('srv-1', '1-0', 'run_started', {'runId': 'run-1'}));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(h.facade.busyFor('srv-1'), isTrue);

    socket.server(_eventFrame('srv-1', '2-0', 'message_delta',
        {'runId': 'run-1', 'text': 'Cloud '}));
    socket.server(_eventFrame('srv-1', '3-0', 'message_delta',
        {'runId': 'run-1', 'text': 'says hi'}));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // The live streaming bubble shows the folded deltas.
    expect(find.textContaining('Cloud says hi'), findsWidgets);

    socket.server(_eventFrame('srv-1', '4-0', 'message_completed', {
      'messageId': 'msg-assistant-1',
      'content': 'Cloud says hi. Final answer.',
    }));
    // The built wire always lands `run_completed` after `message_completed`;
    // `message_completed` finalizes the bubble, `run_completed` settles busy
    // (event_projection.dart fold table).
    socket.server(
        _eventFrame('srv-1', '5-0', 'run_completed', {'runId': 'run-1'}));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(h.facade.busyFor('srv-1'), isFalse);
    expect(find.textContaining('Final answer.'), findsWidgets);
    await h.close();
  });

  testWidgets(
    'the FIRST message_delta flips the live bubble out of the Thinking… '
    'card — the answer streams through the answer path',
    timeout: const Timeout(Duration(seconds: 60)), (tester) async {
      final h = await _bind();
      addTearDown(() async {
        await h.ws.disconnect();
        h.facade.dispose();
      });
      _addSession('srv-1');
      await _pumpChat(tester);

      await _send(tester, 'hello cloud');
      final socket = h.socket();

      socket.server(_eventFrame('srv-1', '1-0', 'run_started', {'runId': 'run-1'}));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // CH-037: one phase status, not a second empty reasoning card.
      expect(find.textContaining('Thinking'), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-run-status')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-reasoning-summary')), findsNothing);

      socket.server(_eventFrame('srv-1', '2-0', 'message_delta',
          {'runId': 'run-1', 'text': 'Cloud '}));
      socket.server(_eventFrame('srv-1', '3-0', 'message_delta',
          {'runId': 'run-1', 'text': 'says hi'}));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Flipped on the first delta: the shimmer label is gone and the
      // streamed text renders as the answer body with the caret at its
      // growing edge — never buried inside the expanded reasoning card
      // until the run finishes.
      expect(find.textContaining('Cloud says hi'), findsWidgets);
      expect(find.textContaining('Thinking'), findsNothing);
      expect(find.byKey(const ValueKey('chat-run-status')), findsNothing);
      expect(
          find.byKey(const ValueKey('chat-streaming-caret')), findsOneWidget);

      // Settle the run so no live animation outlives the test body.
      socket.server(_eventFrame('srv-1', '4-0', 'message_completed', {
        'messageId': 'msg-assistant-1',
        'content': 'Cloud says hi. Final answer.',
      }));
      socket.server(
          _eventFrame('srv-1', '5-0', 'run_completed', {'runId': 'run-1'}));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('chat-streaming-caret')), findsNothing);
      await h.close();
    });

  testWidgets(
    'pre-delta bubble content is kept as the "Thought for" block above the '
    'answer, never prefixed to the answer body',
    timeout: const Timeout(Duration(seconds: 60)), (tester) async {
      final h = await _bind();
      addTearDown(() async {
        await h.ws.disconnect();
        h.facade.dispose();
      });
      _addSession('srv-1');
      await _pumpChat(tester);

      await _send(tester, 'hello cloud');
      final socket = h.socket();

      socket.server(_eventFrame('srv-1', '1-0', 'run_started', {'runId': 'run-1'}));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // No built emitter puts content in the bubble before the first answer
      // delta (the worker streams answer text only); write pre-answer noise
      // straight into the armed bubble to pin the fold for a future
      // reasoning-phase emitter. No frame is pumped while the noise sits on
      // the thinking bubble on purpose: the projector owns the thinking →
      // answer transition, and the fold's reasoning row — not the UI-side
      // think-clock snapshot — is the durable carrier of the thought text.
      (CloudAgentFacade.I.transcriptFor('srv-1')!).last.content =
          'PRE_ANSWER_NOISE';

      socket.server(_eventFrame('srv-1', '2-0', 'message_delta',
          {'runId': 'run-1', 'text': 'Cloud says hi'}));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The answer body starts with the delta text — the noise never leaks
      // in — and the snapshot survives as the collapsed "Thought for" block
      // above it (collapsed by default: the body is not rendered yet).
      expect(find.textContaining('Cloud says hi'), findsWidgets);
      expect(find.textContaining('Thought for'), findsOneWidget);
      expect(find.textContaining('PRE_ANSWER_NOISE'), findsNothing);

      // Expanding the block shows the recorded snapshot.
      await tester.tap(find.byKey(const ValueKey('chat-reasoning-summary')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('PRE_ANSWER_NOISE'), findsWidgets);

      // The block survives the server-authoritative finalize.
      socket.server(_eventFrame('srv-1', '3-0', 'message_completed', {
        'messageId': 'msg-assistant-1',
        'content': 'Cloud says hi. Final answer.',
      }));
      socket.server(
          _eventFrame('srv-1', '4-0', 'run_completed', {'runId': 'run-1'}));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Thought for'), findsOneWidget);
      expect(find.textContaining('PRE_ANSWER_NOISE'), findsWidgets);
      expect(find.textContaining('Final answer.'), findsWidgets);
      await h.close();
    });

  testWidgets('queued outbox entries render the composer queue chip',
      (tester) async {
    final h = await _bind();
    addTearDown(() async {
      await h.ws.disconnect();
      h.facade.dispose();
    });
    _addSession('srv-1');
    await _pumpChat(tester);

    expect(find.byKey(const ValueKey('cloud-outbox-chip')), findsNothing);
    await h.store.enqueue('srv-1', 'queued while offline');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final chip = find.byKey(const ValueKey('cloud-outbox-chip'));
    expect(chip, findsOneWidget);
    expect(
      find.descendant(of: chip, matching: find.textContaining('1 message')),
      findsOneWidget,
    );
    await h.close();
  });

  testWidgets(
      'Review Focus #4 — 402 daily_limit_reached shows the verbatim server '
      'message, a resets countdown, and keeps the draft after dismiss',
      (tester) async {
    final h = await _bind();
    addTearDown(() async {
      await h.ws.disconnect();
      h.facade.dispose();
    });
    _addSession('srv-1');
    await _pumpChat(tester);

    h.rest.sendErrors['limit me'] = CloudApiException(
      status: 402,
      code: 'daily_limit_reached',
      message: 'Daily limit reached. Your allowance resets soon.',
      resetsAt: DateTime.now().add(const Duration(minutes: 30)),
    );

    await _send(tester, 'limit me');

    final row = find.byKey(const ValueKey('cloud-error-row'));
    expect(row, findsOneWidget);
    // CH-031: plain language with the reset time and an Upgrade path —
    // never a raw code or "Resets in 842 min".
    expect(
      find.descendant(
        of: row,
        matching: find.textContaining(
            RegExp(r'plan allowance\. It resets at \d\d:\d\d \(in \d+ min\)')),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('cloud-error-plans')), findsOneWidget);
    // Nothing was accepted and the local engine never ran.
    expect(h.rest.sent, isEmpty);
    expect(CloudAgentFacade.I.busyFor('srv-1'), isFalse);

    // CH-009: the prompt is KEPT — a "Not sent" row with Retry / Discard,
    // durable in the outbox (it survives process death).
    expect(find.text('Not sent'), findsOneWidget);
    expect(h.store.outboxFor('srv-1').single.content, 'limit me');
    expect(h.store.outboxFor('srv-1').single.failedCode, 'daily_limit_reached');

    // Retry re-delivers with the SAME clientMsgId (CH-010).
    final key = h.store.outboxFor('srv-1').single.clientMsgId;
    h.rest.sendErrors.remove('limit me');
    await tester.tap(find.byKey(const ValueKey('cloud-error-retry')).hitTestable().evaluate().isEmpty
        ? find.byKey(ValueKey('pending-retry-$key'))
        : find.byKey(const ValueKey('cloud-error-retry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(h.rest.sent.single.clientMsgId, key);
    expect(h.store.outboxFor('srv-1'), isEmpty);
    expect(find.byKey(const ValueKey('cloud-error-row')), findsNothing);
    expect(find.text('Not sent'), findsNothing);
    await h.close();
  });

  testWidgets(
    'a rename PATCHes the server title for a cloud session, never for a '
    'purely local one',
    timeout: const Timeout(Duration(seconds: 60)),
    (tester) async {
      final h = await _bind();
      addTearDown(() async {
        await h.ws.disconnect();
        h.facade.dispose();
      });
      final s = _addSession('srv-1'); // 'srv-1' is a known server id
      AppState.I.sessions
          .add(ChatSession(id: 'local-9', title: 'Local', model: 'm'));

      AppState.I.renameSession('srv-1', 'Renamed cloud chat');
      await h.facade.titlePatchSettledForTest('srv-1');
      expect(h.rest.patched.single,
          (sessionId: 'srv-1', title: 'Renamed cloud chat', mode: null));
      // The optimistic local title stands either way.
      expect(s.title, 'Renamed cloud chat');

      // No server id yet: the rename stays local until the first send.
      AppState.I.renameSession('local-9', 'Renamed local chat');
      await h.facade.titlePatchSettledForTest('local-9');
      expect(h.rest.patched, hasLength(1),
          reason: 'a purely local chat has nothing to sync');
      expect(AppState.I.sessionById('local-9')!.title, 'Renamed local chat');

      // A failed PATCH keeps the local rename and only lands in Diag.
      h.rest.patchError = CloudApiException(
        status: 503,
        code: 'unavailable',
        message: 'Gateway is restarting.',
      );
      AppState.I.renameSession('srv-1', 'Offline rename');
      await h.facade.titlePatchSettledForTest('srv-1');
      expect(s.title, 'Offline rename',
          reason: 'the optimistic title must survive a failed sync');
      expect(
        Diag.recent().any((e) => e.context == 'cloud.renameSession'),
        isTrue,
      );
      await h.close();
    },
  );

  testWidgets(
    'a rename of a local id mapped to a server id PATCHes under the server id',
    timeout: const Timeout(Duration(seconds: 60)),
    (tester) async {
      // Seed the map BEFORE _bind so the store loads it with the outbox.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(CloudSessionStore.idMapKey,
          jsonEncode(<String, String>{'local-mapped': 'srv-2'}));
      final h = await _bind();
      addTearDown(() async {
        await h.ws.disconnect();
        h.facade.dispose();
      });
      AppState.I.sessions
          .add(ChatSession(id: 'local-mapped', title: 'Mapped', model: 'm'));

      AppState.I.renameSession('local-mapped', 'Mapped rename');
      await h.facade.titlePatchSettledForTest('local-mapped');
      expect(h.rest.patched.single,
          (sessionId: 'srv-2', title: 'Mapped rename', mode: null));
      expect(
          AppState.I.sessionById('local-mapped')!.title, 'Mapped rename');
      await h.close();
    },
  );

  testWidgets(
    'a server approval_requested renders the approval card; Allow answers the '
    'bridge with the approval_response op and dismisses the card',
    timeout: const Timeout(Duration(seconds: 60)),
    (tester) async {
      final h = await _bind();
      addTearDown(() async {
        await h.ws.disconnect();
        h.facade.dispose();
      });
      _addSession('srv-1');
      await _pumpChat(tester);

      await _send(tester, 'hello cloud');
      final socket = h.socket();

      socket.server(
          _eventFrame('srv-1', '1-0', 'run_started', {'runId': 'run-1'}));
      socket.server(_eventFrame('srv-1', '2-0', 'approval_requested',
          <String, dynamic>{
        'approvalId': 'ap-1',
        'tool': 'bash',
        'kind': 'tool',
        'summary': 'Run rm -rf /tmp/build',
        'detail': 'rm -rf /tmp/build',
        'allowAlways': true,
      }));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The card shows the tool's ask and the exact preview, and the
      // composer is locked while it stands (approval takeover parity).
      expect(find.byKey(const ValueKey('approval-allow')), findsOneWidget);
      expect(find.byKey(const ValueKey('approval-deny')), findsOneWidget);
      expect(find.byKey(const ValueKey('approval-always')), findsOneWidget);
      expect(find.text('Run rm -rf /tmp/build'), findsOneWidget);
      expect(find.text('rm -rf /tmp/build'), findsOneWidget);

      // The dock's arm delay (300 ms) has elapsed; the tap is delivered.
      await tester.tap(find.byKey(const ValueKey('approval-allow')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // CH-017: the card stays up in its "Sending…" state until the server
      // confirms the decision…
      expect(find.byKey(const ValueKey('approval-sending')), findsOneWidget);
      socket.server(<String, dynamic>{
        'op': 'approval_ack',
        'approvalId': 'ap-1',
        'decision': 'allow',
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('approval-allow')), findsNothing);
      expect(find.byKey(const ValueKey('approval-deny')), findsNothing);
      // …and the answer went out on the multiplexed wire.
      final frames = <Map<String, dynamic>>[
        for (final frame in socket.sent)
          if (frame['op'] == 'approval_response') frame,
      ];
      expect(frames, hasLength(1));
      expect(frames.single, <String, dynamic>{
        'op': 'approval_response',
        'sessionId': 'srv-1',
        'approvalId': 'ap-1',
        'decision': 'allow',
      });
      await h.close();
    },
  );

  testWidgets(
    'approval_resolved (the timeout-deny spelling) dismisses the card with '
    'nothing sent from the client',
    timeout: const Timeout(Duration(seconds: 60)),
    (tester) async {
      final h = await _bind();
      addTearDown(() async {
        await h.ws.disconnect();
        h.facade.dispose();
      });
      _addSession('srv-1');
      await _pumpChat(tester);

      await _send(tester, 'hello cloud');
      final socket = h.socket();

      socket.server(
          _eventFrame('srv-1', '1-0', 'run_started', {'runId': 'run-1'}));
      socket.server(_eventFrame('srv-1', '2-0', 'approval_requested',
          <String, dynamic>{
        'approvalId': 'ap-1',
        'tool': 'bash',
        'kind': 'tool',
        'summary': 'Run rm -rf /tmp/build',
        'detail': 'rm -rf /tmp/build',
        'allowAlways': false,
      }));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('approval-allow')), findsOneWidget);

      socket.server(_eventFrame('srv-1', '3-0', 'approval_resolved',
          <String, dynamic>{
        'approvalId': 'ap-1',
        'decision': 'deny',
        'reason': 'timeout',
      }));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const ValueKey('approval-allow')), findsNothing);
      expect(
        socket.sent.where((f) => f['op'] == 'approval_response'),
        isEmpty,
        reason: 'the bridge settled by timeout — the client never answered',
      );
      await h.close();
    },
  );

  testWidgets(
    '⋮ menu offers Share and New chat once the projection has content',
    timeout: const Timeout(Duration(seconds: 60)),
    (tester) async {
      final h = await _bind();
      addTearDown(() async {
        await h.ws.disconnect();
        h.facade.dispose();
      });
      _addSession('srv-1'); // a cloud chat: the local rows stay empty
      await _pumpChat(tester);

      // No projection yet: transcriptFor is null and the empty rows hide
      // Share / New chat (the pre-fix behaviour for EVERY cloud chat).
      await tester.tap(find.byKey(const ValueKey('chat-header-more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-menu-share')), findsNothing);
      expect(find.byKey(const ValueKey('chat-menu-newChat')), findsNothing);
      // Dismiss the menu before the second open.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // The live projection is the transcript — the gate must see it.
      h.facade.seedTranscript('srv-1', [
        Message(role: 'user', content: 'hello cloud'),
        Message(role: 'assistant', kind: MsgKind.text, content: 'Cloud says hi'),
      ], null);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('chat-header-more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-menu-share')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-menu-newChat')), findsOneWidget);
      await h.close();
    },
  );

  // -------------------------------------------------------------------------
  // Older-server-page paging (chat P1: history past the first page)
  // -------------------------------------------------------------------------

  testWidgets(
    'scrolling to the top pages OLDER server pages through `before` — '
    'history past the first 50 is reachable',
    timeout: const Timeout(Duration(seconds: 60)),
    (tester) async {
      final h = await _bind();
      addTearDown(() async {
        await h.ws.disconnect();
        h.facade.dispose();
      });
      _addSession('srv-1');
      _seedHistory(h.rest, 'srv-1', 120);
      await _pumpChat(tester);

      // Boot loaded the newest 50 (msg-70..msg-119); the tail renders.
      expect(h.rest.paged, hasLength(1));
      expect(h.rest.paged.single.before, isNull);
      // The projection holds the full boot page; the viewport sits at the
      // bottom (the follow-tip jump), so newest rows are built. The exact
      // LAST row can sit a few pixels below the lazy builder's fold (the
      // 24px at-bottom dead zone), so assert on the projection plus a row
      // that is guaranteed built.
      final seeded = CloudAgentFacade.I.transcriptFor('srv-1')!;
      expect(seeded.length, 50);
      expect(seeded.first.content, 'm70');
      expect(seeded.last.content, 'm119');
      expect(find.textContaining('m11'), findsWidgets);

      final list = find.byKey(const ValueKey('chat-transcript-list'));
      // Drag to the top: the pager widens the in-memory window, and — one
      // widen from exhausting it — fetches the next server page from the
      // oldest loaded row. Single-flight keeps the scroll-event burst to
      // ONE older-page call.
      await tester.drag(list, const Offset(0, 5000));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.rest.paged.where((c) => c.before != null), hasLength(1));
      expect(h.rest.paged.last.before, 'msg-70');
      // The 50 older rows were prepended into the projection.
      expect(CloudAgentFacade.I.transcriptFor('srv-1'), hasLength(100));
      expect(
        CloudAgentFacade.I.transcriptFor('srv-1')!.first.privateSyncId,
        'msg-20',
      );

      // The prepend pushed the anchored view back down. A real user drags
      // back to the top; in the harness, gesture physics clamp at the
      // extent unpredictably after the anchor restore, so drive the scroll
      // position directly to the top edge (the production trigger is
      // `pixels < 120`) — deterministic for the second page fetch.
      final scrollState =
          tester.state<ScrollableState>(find.byType(Scrollable).first);
      scrollState.position.jumpTo(0);
      scrollState.position.notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.rest.paged.last.before, 'msg-20');
      expect(CloudAgentFacade.I.transcriptFor('srv-1'), hasLength(120));
      expect(
        CloudAgentFacade.I.transcriptFor('srv-1')!.first.privateSyncId,
        'msg-0',
      );

      // The in-memory window is now exhausted (hidden == 0): the pager's
      // server branch fires, and the empty page completes the transcript.
      scrollState.position.jumpTo(0);
      scrollState.position.notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.rest.paged.last.before, 'msg-0');
      expect(CloudAgentFacade.I.transcriptFor('srv-1'), hasLength(120));

      // A completed transcript never hits the wire again: leave the top
      // edge so the next approach produces scroll events.
      scrollState.position.jumpTo(400);
      scrollState.position.notifyListeners();
      await tester.pump();
      scrollState.position.jumpTo(0);
      scrollState.position.notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.rest.paged, hasLength(4));
      await h.close();
    },
  );

  testWidgets(
    'a failed older-page fetch is swallowed and the chat stays usable',
    timeout: const Timeout(Duration(seconds: 60)),
    (tester) async {
      final h = await _bind();
      addTearDown(() async {
        await h.ws.disconnect();
        h.facade.dispose();
      });
      _addSession('srv-1');
      _seedHistory(h.rest, 'srv-1', 120);
      // Only the older-page fetch fails; the boot's newest page loads clean.
      h.rest.olderPageError = CloudApiException(
        status: 503,
        code: 'unavailable',
        message: 'Gateway is restarting.',
      );
      await _pumpChat(tester);
      final seeded2 = CloudAgentFacade.I.transcriptFor('srv-1')!;
      expect(seeded2.length, 50);
      expect(find.textContaining('m11'), findsWidgets);

      final list = find.byKey(const ValueKey('chat-transcript-list'));
      await tester.drag(list, const Offset(0, 5000));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      // The fetch fired, failed, and was swallowed into Diag — one call
      // per top-approach, no retry storm.
      expect(h.rest.paged, hasLength(2));
      expect(h.rest.paged.last.before, 'msg-70');
      expect(
        Diag.recent()
            .any((e) => e.context == 'chat_screen.loadEarlierServerPage'),
        isTrue,
      );
      // The loaded window is untouched and fully readable from the top.
      // (Row visibility depends on the lazy builder's viewport fold; the
      // projection length is the data-level guarantee.)
      expect(CloudAgentFacade.I.transcriptFor('srv-1'), hasLength(50));
      // The "Loading earlier…" affordance did not stick at the top.
      expect(find.textContaining('Loading earlier'), findsNothing);

      // The chat keeps working: a send still reaches the facade's REST.
      await _send(tester, 'still works');
      expect(h.rest.sent.single.content, 'still works');
      expect(find.textContaining('still works'), findsWidgets);
      expect(h.rest.paged, hasLength(2));
      await h.close();
    },
  );

  testWidgets(
    'CH-035: a failed first history load shows Retry, never an empty chat',
    timeout: const Timeout(Duration(seconds: 60)),
    (tester) async {
      final h = await _bind();
      addTearDown(h.close);
      _seedHistory(h.rest, 'srv-1', 3);
      h.rest.newestPageError = CloudApiException(
        status: 503,
        code: 'unavailable',
        message: 'Gateway is restarting.',
      );
      _addSession('srv-1');
      await _pumpChat(tester);

      expect(find.byKey(const ValueKey('chat-history-load-failed')),
          findsOneWidget);
      expect(find.text('How can I help?'), findsNothing);

      h.rest.newestPageError = null;
      await tester.tap(find.byKey(const ValueKey('chat-history-retry')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('chat-history-load-failed')),
          findsNothing);
      expect(CloudAgentFacade.I.transcriptFor('srv-1'), hasLength(3));
      await h.close();
    },
  );

  testWidgets(
    'R1: an @[chat] tag sends that chat\'s server id with this message only',
    timeout: const Timeout(Duration(seconds: 60)),
    (tester) async {
      final h = await _bind();
      addTearDown(h.close);
      final other =
          ChatSession(id: 'trip-local', title: 'Trip plan', model: 'm');
      AppState.I.sessions.add(other);
      // The tagged chat is synced: it has a server id.
      await h.store.ensureServerSession('trip-local');
      _addSession('srv-1');
      await _pumpChat(tester);

      await _send(tester, 'compare with @[Trip plan] please');
      expect(h.rest.lastTurn.sessionRefs, ['srv-created']);

      await _send(tester, 'and now without a tag');
      expect(h.rest.lastTurn.sessionRefs, isEmpty);
      await h.close();
    },
  );
}
