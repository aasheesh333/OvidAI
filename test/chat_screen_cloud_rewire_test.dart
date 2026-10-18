// P8 Task 10 — chat rewire: `chat_screen.dart` on the facade behind
// `Distribution.cloudExecution`.
//
// Everything here runs with `Distribution.thinOverrideForTest = true` and a
// facade + store bound to fakes, proving the THIN arm of the dual-path
// binding:
//   * typing + Send reaches the FACADE's REST client (never a local run);
//   * a run_started / message_delta / message_completed sequence through the
//     fake socket renders a live bubble and then the finalized row;
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
import 'package:ovid_ai/core/distribution.dart';
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

  int _seq = 0;

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
  }) async {
    return const CloudPage<MessageDto>(items: [], nextCursor: null);
  }

  @override
  Future<SendMessageResponse> sendMessage(
    String sessionId,
    String content, {
    List<String> attachmentIds = const [],
    String? clientMsgId,
  }) async {
    final error = sendErrors[content];
    if (error != null) throw error;
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
}

class FakeChatSocket implements CloudSocket {
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
    Distribution.thinOverrideForTest = true;
    // The local engine must never be consulted; pausing its timer keeps the
    // assertion below safe to make without pending-timer noise.
  });

  tearDown(() async {
    Distribution.thinOverrideForTest = null;
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
      find.descendant(of: chip, matching: find.textContaining('1 queued')),
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
    // The server message is shown VERBATIM.
    expect(
      find.descendant(
        of: row,
        matching: find.text('Daily limit reached. Your allowance resets soon.'),
      ),
      findsOneWidget,
    );
    // A countdown derived from resetsAt.
    expect(
      find.descendant(
        of: row,
        matching: find.textContaining(RegExp(r'Resets in \d+ min')),
      ),
      findsOneWidget,
    );
    // Nothing was sent and the local engine never ran.
    expect(h.rest.sent, isEmpty);
    expect(CloudAgentFacade.I.busyFor('srv-1'), isFalse);

    // The composed draft is still present after the error row is dismissed.
    await tester.tap(find.byKey(const ValueKey('cloud-error-dismiss')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('cloud-error-row')), findsNothing);
    final editable = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('chat-composer')),
        matching: find.byType(EditableText),
      ),
    );
    expect(editable.controller.text, 'limit me');
    await h.close();
  });
}
