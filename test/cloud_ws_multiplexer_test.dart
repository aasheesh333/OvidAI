// P8 Task 6 — WsMultiplexer. Every wire shape asserted here was reconciled
// against the BUILT server code (the contract, not the plan sketches):
//   - client ops subscribe/unsubscribe/ping     — cloud/packages/shared/src/ws.ts
//   - server ops subscribed/event/pong/error    — cloud/packages/shared/src/ws.ts
//   - SessionEvent {sessionId, seq, type, payload, ts} — shared/src/events.ts
//   - close 4401 = WS_CLOSE_UNAUTHENTICATED     — cloud/apps/gateway/src/ws.ts
//   - replay-degradation signal = {"op":"error","code":"internal",
//     "message":"Replay failed.","sessionId":…} (the built server has NO
//     dedicated trimmed-frame op; the internal error family is the only
//     signal, and the server deletes the subscription on it).
//   - compareSeq numeric-on-both-parts semantics — gateway ws.ts compareSeq.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, HttpOverrides, SecurityContext;

// fake_async comes transitively through flutter_test; promoting it to a
// direct dev_dependency needs a pubspec edit that is outside this task's
// pathspec lane (parallel-wave disjointness) — flagged in the task report
// for the next lockfile-allowed wave.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart' show fakeAsync;
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/connection_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// FakeCloudSocket — StreamController-backed CloudSocket
// ---------------------------------------------------------------------------

class FakeCloudSocket implements CloudSocket {
  FakeCloudSocket(this.uri);

  final Uri uri;

  /// Text frames the multiplexer sent, in order.
  final List<String> sent = <String>[];

  final StreamController<Object> _frames = StreamController<Object>();
  final StreamController<void> _closed = StreamController<void>();

  int? _closeCode;
  bool isClosed = false;

  @override
  Stream<Object> get frames => _frames.stream;

  @override
  Stream<void> get closed => _closed.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  void sendText(String frame) => sent.add(frame);

  /// Server → client frame. Maps are JSON-encoded on the wire, like the
  /// real socket delivers them; Strings pass through as-is.
  void server(Object frame) =>
      _frames.add(frame is String ? frame : jsonEncode(frame));

  /// The client (or a test simulating the server) closing the socket.
  @override
  Future<void> close([int? code, String? reason]) async {
    if (isClosed) return;
    isClosed = true;
    _closeCode = code;
    await _frames.close();
    if (!_closed.isClosed) {
      _closed.add(null);
      await _closed.close();
    }
  }

  /// Last sent frame, decoded.
  Map<String, dynamic> lastSentJson() =>
      jsonDecode(sent.last) as Map<String, dynamic>;

  List<Map<String, dynamic>> sentJson() => [
        for (final frame in sent) jsonDecode(frame) as Map<String, dynamic>,
      ];
}

class SocketFactorySpy {
  final sockets = <FakeCloudSocket>[];
  final uris = <Uri>[];

  CloudSocketFactory get fn => (Uri url) async {
        uris.add(url);
        final socket = FakeCloudSocket(url);
        sockets.add(socket);
        return socket;
      };
}

// ---------------------------------------------------------------------------
// Event helpers — the BUILT SessionEvent wire shape
// ---------------------------------------------------------------------------

Map<String, dynamic> _sessionEventJson(String sessionId, String seq) => {
      'sessionId': sessionId,
      'seq': seq,
      'type': 'message_delta',
      'payload': <String, dynamic>{'text': 'x'},
      'ts': '2026-10-16T10:00:00.000Z',
    };

Map<String, dynamic> _eventFrame(String sessionId, String seq) => {
      'op': 'event',
      'event': _sessionEventJson(sessionId, seq),
    };

CloudSessionEvent _event(String sessionId, String seq) =>
    CloudSessionEvent.fromJson(_sessionEventJson(sessionId, seq));

const String _lastEventKey = 'ovid_cloud_last_event_';

// ---------------------------------------------------------------------------
// Test harness
// ---------------------------------------------------------------------------

Future<WsMultiplexer> _build(
  SocketFactorySpy spy, {
  CloudMirrorReader? mirror,
  ConnectionService? connection,
  SharedPreferences? prefs,
  Duration heartbeatInterval = const Duration(seconds: 25),
  Duration pongTimeout = const Duration(seconds: 10),
  int Function()? jitter,
}) async {
  var mint = 0;
  return WsMultiplexer(
    mintTicket: () async => 'ticket-${++mint}',
    socketFactory: spy.fn,
    prefs: prefs ?? await SharedPreferences.getInstance(),
    connection: connection ?? ConnectionService.forTest(),
    heartbeatInterval: heartbeatInterval,
    pongTimeout: pongTimeout,
    mirrorReader: mirror,
    jitterMs: jitter,
  );
}

/// Subscribes, drains the connect pipeline, returns the seen events/errors.
Future<(List<CloudSessionEvent> events, List<Object> errors)>
    _subscribeAndListen(
  WsMultiplexer ws,
  String sessionId,
) async {
  final events = <CloudSessionEvent>[];
  final errors = <Object>[];
  ws.subscribe(sessionId).listen(events.add, onError: (Object e) {
    errors.add(e);
  });
  await pumpEventQueue();
  return (events, errors);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  test('(a) first subscribe mints a ticket, connects, and sends subscribe '
      'with lastEventId null; linkState reaches online', () async {
    final spy = SocketFactorySpy();
    final ws = await _build(spy);
    expect(ws.linkState, WsLinkState.disconnected);
    await _subscribeAndListen(ws, 's1');
    expect(spy.sockets, hasLength(1));
    expect(spy.uris.single.queryParameters['ticket'], 'ticket-1',
        reason: 'every (re)connect must mint a fresh single-use ticket');
    expect(
      spy.sockets.single.sentJson().single,
      {'op': 'subscribe', 'sessionId': 's1', 'lastEventId': null},
    );
    expect(ws.linkState, WsLinkState.online);
    await ws.disconnect();
  });

  test("(b) events below the last accepted seq are dropped ('5-0' then "
      "'4-9' emits only '5-0')", () async {
    final spy = SocketFactorySpy();
    final ws = await _build(spy);
    final (events, errors) = await _subscribeAndListen(ws, 's1');
    final socket = spy.sockets.single;
    socket.server(_eventFrame('s1', '5-0'));
    socket.server(_eventFrame('s1', '4-9'));
    await pumpEventQueue();
    expect(events.map((e) => e.seq), ['5-0']);
    expect(errors, isEmpty);
    await ws.disconnect();
  });

  test('(c) the same seq delivered twice is emitted exactly once '
      '(Review Focus #2) and persisted', () async {
    final spy = SocketFactorySpy();
    final store = await SharedPreferences.getInstance();
    final ws = await _build(spy, prefs: store);
    final (events, _) = await _subscribeAndListen(ws, 's1');
    final socket = spy.sockets.single;
    socket.server(_eventFrame('s1', '5-0'));
    socket.server(_eventFrame('s1', '5-0'));
    await pumpEventQueue();
    expect(events.map((e) => e.seq), ['5-0']);
    expect(store.getString('$_lastEventKey' 's1'), '5-0');
    await ws.disconnect();
  });

  test("(d) lastEventId persists: a fresh multiplexer resubscribes with the "
      "stored cursor ('5-0')", () async {
    final store = await SharedPreferences.getInstance();
    final spy1 = SocketFactorySpy();
    final ws1 = await _build(spy1, prefs: store);
    final (events, _) = await _subscribeAndListen(ws1, 's1');
    spy1.sockets.single.server(_eventFrame('s1', '5-0'));
    await pumpEventQueue();
    expect(events.map((e) => e.seq), ['5-0']);
    await ws1.disconnect();

    final spy2 = SocketFactorySpy();
    final ws2 = await _build(spy2, prefs: store);
    await _subscribeAndListen(ws2, 's1');
    expect(
      spy2.sockets.single.sentJson().single,
      {'op': 'subscribe', 'sessionId': 's1', 'lastEventId': '5-0'},
    );
    await ws2.disconnect();
  });

  test('(e) close 4401 → re-mint, new socket, resubscribe with the persisted '
      'id, no error surfaced (Review Focus #1)', () async {
    final spy = SocketFactorySpy();
    final store = await SharedPreferences.getInstance();
    final ws = await _build(spy, prefs: store);
    final (events, errors) = await _subscribeAndListen(ws, 's1');
    spy.sockets.single.server(_eventFrame('s1', '5-0'));
    await pumpEventQueue();
    expect(events.map((e) => e.seq), ['5-0']);
    final ticketsBefore = spy.uris.length;
    expect(ticketsBefore, 1);

    // Server closes with the app-private 4401 (stale/reused ticket).
    await spy.sockets.single.close(4401, 'unauthenticated');
    await pumpEventQueue();

    expect(spy.uris.length, 2,
        reason: '4401 must re-mint a fresh single-use ticket');
    expect(spy.uris.last.queryParameters['ticket'], 'ticket-2');
    expect(spy.sockets, hasLength(2));
    expect(
      spy.sockets.last.sentJson().single,
      {'op': 'subscribe', 'sessionId': 's1', 'lastEventId': '5-0'},
    );
    expect(errors, isEmpty, reason: 'a 4401 close must never surface');
    expect(ws.linkState, WsLinkState.online);
    await ws.disconnect();
  });

  test('(f) close without 4401 → backoff 1s, 2s, 4s … capped at 60s '
      '(fake async, jitter 0)', () async {
    final store = await SharedPreferences.getInstance();
    fakeAsync((async) {
      final spy = SocketFactorySpy();
      final ws = WsMultiplexer(
        mintTicket: () async => 't',
        socketFactory: spy.fn,
        prefs: store,
        // Keep heartbeats out of the backoff measurement.
        heartbeatInterval: const Duration(minutes: 10),
        jitterMs: () => 0,
      );
      ws.subscribe('s1').listen((_) {});
      async.elapse(const Duration(milliseconds: 10));
      expect(spy.sockets, hasLength(1));

      // Attempt 1: reconnect after exactly 1s (1s * 2^0), not before.
      spy.sockets.last.close(1000);
      async.elapse(const Duration(milliseconds: 999));
      expect(spy.sockets, hasLength(1));
      async.elapse(const Duration(milliseconds: 2));
      expect(spy.sockets, hasLength(2));

      // Attempt 2: 2s.
      spy.sockets.last.close(1000);
      async.elapse(const Duration(milliseconds: 1999));
      expect(spy.sockets, hasLength(2));
      async.elapse(const Duration(milliseconds: 2));
      expect(spy.sockets, hasLength(3));

      // Attempt 3: 4s.
      spy.sockets.last.close(1000);
      async.elapse(const Duration(milliseconds: 3999));
      expect(spy.sockets, hasLength(3));
      async.elapse(const Duration(milliseconds: 2));
      expect(spy.sockets, hasLength(4));

      // Attempts 4..6: 8s, 16s, 32s.
      spy.sockets.last.close(1000);
      async.elapse(const Duration(seconds: 7, milliseconds: 999));
      expect(spy.sockets, hasLength(4));
      async.elapse(const Duration(milliseconds: 2));
      expect(spy.sockets, hasLength(5));

      spy.sockets.last.close(1000);
      async.elapse(const Duration(seconds: 15, milliseconds: 999));
      expect(spy.sockets, hasLength(5));
      async.elapse(const Duration(milliseconds: 2));
      expect(spy.sockets, hasLength(6));

      spy.sockets.last.close(1000);
      async.elapse(const Duration(seconds: 31, milliseconds: 999));
      expect(spy.sockets, hasLength(6));
      async.elapse(const Duration(milliseconds: 2));
      expect(spy.sockets, hasLength(7));

      // Attempt 8: would be 64s uncapped → the 60s cap fires at 60s.
      spy.sockets.last.close(1000);
      async.elapse(const Duration(seconds: 59, milliseconds: 999));
      expect(spy.sockets, hasLength(7));
      async.elapse(const Duration(milliseconds: 2));
      expect(spy.sockets, hasLength(8));

      ws.disconnect();
    });
  });

  test('(f2) jitter shifts the backoff by 0–250 ms', () async {
    final store = await SharedPreferences.getInstance();
    fakeAsync((async) {
      final spy = SocketFactorySpy();
      final ws = WsMultiplexer(
        mintTicket: () async => 't',
        socketFactory: spy.fn,
        prefs: store,
        heartbeatInterval: const Duration(minutes: 10),
        jitterMs: () => 250,
      );
      ws.subscribe('s1').listen((_) {});
      async.elapse(const Duration(milliseconds: 10));
      spy.sockets.last.close(1000);
      async.elapse(const Duration(milliseconds: 1249));
      expect(spy.sockets, hasLength(1), reason: '1s base + 250ms jitter');
      async.elapse(const Duration(milliseconds: 2));
      expect(spy.sockets, hasLength(2));
      ws.disconnect();
    });
  });

  test('(g) offline ConnectionService → no connect/reconnect until it flips '
      'online', () async {
    var reachable = false;
    final connection = ConnectionService.forTest(
      status: ConnectionStatus.offline,
      reach: () async => reachable,
    );
    final spy = SocketFactorySpy();
    final ws = await _build(spy, connection: connection);

    // Subscribing while offline registers the session but must NOT connect.
    final (events, errors) = await _subscribeAndListen(ws, 's1');
    expect(spy.sockets, isEmpty);
    expect(errors, isEmpty);
    expect(events, isEmpty);
    expect(ws.linkState, WsLinkState.disconnected);

    // Flip to online → the deferred connect happens.
    reachable = true;
    await connection.probe();
    await pumpEventQueue();
    expect(spy.sockets, hasLength(1));
    expect(
      spy.sockets.single.sentJson().single,
      {'op': 'subscribe', 'sessionId': 's1', 'lastEventId': null},
    );

    // Back offline → a socket close schedules nothing…
    reachable = false;
    await connection.probe();
    await spy.sockets.single.close(1000);
    await pumpEventQueue();
    expect(spy.sockets, hasLength(1));
    // …and flipping online again reconnects.
    reachable = true;
    await connection.probe();
    await pumpEventQueue();
    expect(spy.sockets, hasLength(2));
    await ws.disconnect();
  });

  test('(h1) pong within the timeout keeps the link alive across heartbeat '
      'cycles (no reconnect)', () async {
    final store = await SharedPreferences.getInstance();
    fakeAsync((async) {
      final spy = SocketFactorySpy();
      final ws = WsMultiplexer(
        mintTicket: () async => 't',
        socketFactory: spy.fn,
        prefs: store,
        heartbeatInterval: const Duration(seconds: 25),
        pongTimeout: const Duration(seconds: 10),
        jitterMs: () => 0,
      );
      ws.subscribe('s1').listen((_) {});
      async.elapse(const Duration(milliseconds: 10));
      spy.sockets.last.server(const {'op': 'subscribed', 'sessionId': 's1'});

      // Cycle 1: ping fires at ~25s; pong delivered well within the 10s
      // deadline (elapse stays short of ping+10s).
      async.elapse(const Duration(seconds: 26));
      expect(spy.sockets.last.lastSentJson()['op'], 'ping');
      spy.sockets.last.server(const {'op': 'pong'});

      // Cycle 2: second ping fires at ~50s; pong again in time.
      async.elapse(const Duration(seconds: 30));
      expect(spy.sockets.last.lastSentJson()['op'], 'ping');
      spy.sockets.last.server(const {'op': 'pong'});
      expect(spy.sockets.last.isClosed, isFalse);

      // Still inside the third ping's grace window — link never closed.
      async.elapse(const Duration(seconds: 9));
      expect(spy.sockets.last.isClosed, isFalse,
          reason: 'a timely pong must never close the link');

      // A pong also resets the attempt counter: the next
      // (server-initiated) close reconnects after the FIRST backoff step.
      spy.sockets.last.close(1000);
      async.elapse(const Duration(milliseconds: 999));
      expect(spy.sockets, hasLength(1));
      async.elapse(const Duration(milliseconds: 2));
      expect(spy.sockets, hasLength(2));
      ws.disconnect();
    });
  });

  test('(h2) missing pong → close + reconnect; subscribed ack resets the '
      'backoff attempt counter', () async {
    final store = await SharedPreferences.getInstance();
    fakeAsync((async) {
      final spy = SocketFactorySpy();
      final ws = WsMultiplexer(
        mintTicket: () async => 't',
        socketFactory: spy.fn,
        prefs: store,
        heartbeatInterval: const Duration(seconds: 25),
        pongTimeout: const Duration(seconds: 10),
        jitterMs: () => 0,
      );
      ws.subscribe('s1').listen((_) {});
      async.elapse(const Duration(milliseconds: 10));
      spy.sockets.last.server(const {'op': 'subscribed', 'sessionId': 's1'});

      // Ping goes out; no pong comes back → close at the pong deadline.
      async.elapse(const Duration(seconds: 25));
      expect(spy.sockets.last.lastSentJson()['op'], 'ping');
      async.elapse(const Duration(seconds: 10));
      expect(spy.sockets.last.isClosed, isTrue);
      expect(spy.sockets.last.closeCode, 4000, reason: 'pong-timeout close');

      // Reconnect after the 1s first backoff step, with a live resubscribe.
      // (The pong-deadline close fires mid-elapse at a fuzzy sub-boundary
      // offset, so the margins here are deliberately coarse.)
      async.elapse(const Duration(milliseconds: 800));
      expect(spy.sockets, hasLength(1));
      async.elapse(const Duration(milliseconds: 400));
      expect(spy.sockets, hasLength(2));
      expect(
        spy.sockets.last.sentJson().single,
        {'op': 'subscribe', 'sessionId': 's1', 'lastEventId': null},
      );

      // subscribed resets the attempt counter: the next close reconnects
      // after 1s again (not after the grown 2s step).
      spy.sockets.last.server(const {'op': 'subscribed', 'sessionId': 's1'});
      spy.sockets.last.close(1000);
      async.elapse(const Duration(milliseconds: 999));
      expect(spy.sockets, hasLength(2));
      async.elapse(const Duration(milliseconds: 2));
      expect(spy.sockets, hasLength(3));
      ws.disconnect();
    });
  });

  test('(i) compareSeq compares both parts numerically', () {
    expect(WsMultiplexer.compareSeq('10-0', '9-99'), greaterThan(0));
    expect(WsMultiplexer.compareSeq('100-0', '99-99'), greaterThan(0),
        reason: 'digit-width change must not fall back to lexicographic');
    expect(WsMultiplexer.compareSeq('5-1', '5-0'), greaterThan(0));
    expect(WsMultiplexer.compareSeq('4-9', '5-0'), lessThan(0));
    expect(WsMultiplexer.compareSeq('7-1', '7-1'), 0);
  });

  test('(j) internal replay error → DB-mirror catch-up through the same '
      'seq-dedupe, then live continues; cursor re-seeds from the mirror',
      () async {
    final store = await SharedPreferences.getInstance();
    await store.setString('$_lastEventKey' 's1', '5-0');
    final mirrorCalls = <(String, String?)>[];
    final spy = SocketFactorySpy();
    final ws = await _build(
      spy,
      prefs: store,
      mirror: (sessionId, lastSeq) async {
        mirrorCalls.add((sessionId, lastSeq));
        return [_event('s1', '6-0'), _event('s1', '7-0')];
      },
    );
    final (events, errors) = await _subscribeAndListen(ws, 's1');
    final socket = spy.sockets.single;
    expect(socket.sentJson().single['lastEventId'], '5-0');

    // The built server's ONLY replay-degradation signal (ws.ts): an internal
    // error frame naming the session — it deletes the server-side sub.
    socket.server({
      'op': 'error',
      'code': 'internal',
      'message': 'Replay failed.',
      'sessionId': 's1',
    });
    await pumpEventQueue();

    expect(mirrorCalls, [('s1', '5-0')]);
    expect(events.map((e) => e.seq), ['6-0', '7-0'],
        reason: 'mirror events flow through the session stream once');
    expect(errors, isEmpty, reason: 'the fallback heals the degradation');
    expect(store.getString('$_lastEventKey' 's1'), '7-0',
        reason: 'the cursor re-seeds from the mirror last event');

    // Live continues: a fresh subscribe goes out with the re-seeded cursor.
    expect(
      socket.sentJson().last,
      {'op': 'subscribe', 'sessionId': 's1', 'lastEventId': '7-0'},
    );

    // Overlap dedupe across mirror→live: replayed/duplicate seqs drop, new
    // live events flow.
    socket.server(_eventFrame('s1', '6-0'));
    socket.server(_eventFrame('s1', '8-0'));
    await pumpEventQueue();
    expect(events.map((e) => e.seq), ['6-0', '7-0', '8-0']);
    await ws.disconnect();
  });

  test('(j2) mirror catch-up failure surfaces an error on the session '
      'stream (the degradation is not silently swallowed)', () async {
    final spy = SocketFactorySpy();
    final ws = await _build(
      spy,
      mirror: (sessionId, lastSeq) async {
        throw Exception('mirror unreachable');
      },
    );
    final (events, errors) = await _subscribeAndListen(ws, 's1');
    spy.sockets.single.server({
      'op': 'error',
      'code': 'internal',
      'message': 'Replay failed.',
      'sessionId': 's1',
    });
    await pumpEventQueue();
    expect(events, isEmpty);
    expect(errors, hasLength(1));
    expect(errors.single,
        isA<CloudWsError>().having((e) => e.code, 'code', 'internal'));
    await ws.disconnect();
  });

  test('(k) non-recoverable error frames forward on the session stream; '
      'frames without a sessionId never reach it', () async {
    final spy = SocketFactorySpy();
    final ws = await _build(spy);
    final (events, errors) = await _subscribeAndListen(ws, 's1');
    final socket = spy.sockets.single;

    socket.server({
      'op': 'error',
      'code': 'forbidden',
      'message': 'Session not found.',
      'sessionId': 's1',
    });
    await pumpEventQueue();
    expect(errors, hasLength(1));
    expect(
      errors.single,
      isA<CloudWsError>()
          .having((e) => e.code, 'code', 'forbidden')
          .having((e) => e.message, 'message', 'Session not found.'),
    );

    // Connection-level error (no sessionId): logged, never forwarded/rethrown.
    socket.server({
      'op': 'error',
      'code': 'bad_message',
      'message': 'Frame is not a valid client message.',
    });
    await pumpEventQueue();
    expect(errors, hasLength(1), reason: 'no session to forward to');
    expect(events, isEmpty);
    await ws.disconnect();
  });

  test('(l) subscribe is idempotent (same stream, one wire frame); '
      'pty/browser frames flow through rawServerFrames and sendRaw works '
      'from disconnected', () async {
    final spy = SocketFactorySpy();
    final ws = await _build(spy);
    final a = ws.subscribe('s1');
    final b = ws.subscribe('s1');
    expect(b, same(a));
    await pumpEventQueue();
    expect(
      spy.sockets.single.sentJson().where((f) => f['op'] == 'subscribe'),
      hasLength(1),
    );

    // Unconsumed ops (pty_*, browser_state — Tasks 15/16 lane) go to the
    // raw stream, decoded.
    final raw = <Map<String, dynamic>>[];
    ws.rawServerFrames.listen(raw.add);
    spy.sockets.single.server(const {
      'op': 'pty_output',
      'ptyId': 'p1',
      'data': 'aGk=',
      'offset': 4,
    });
    await pumpEventQueue();
    expect(raw, hasLength(1));
    expect(raw.single['op'], 'pty_output');
    expect(spy.sockets.single.sentJson().where((f) => f['op'] == 'event'),
        isEmpty,
        reason: 'raw ops must not leak into the session-event pipeline');

    await ws.sendRaw(const {'op': 'pty_input', 'ptyId': 'p1', 'data': 'aGk='});
    expect(
      spy.sockets.single.sentJson().where((f) => f['op'] == 'pty_input'),
      hasLength(1),
    );

    // From a disconnected multiplexer, sendRaw connects first.
    await ws.disconnect();
    final fresh = SocketFactorySpy();
    final ws2 = await _build(fresh);
    await ws2.sendRaw(const {'op': 'ping'});
    expect(fresh.sockets, hasLength(1));
    expect(fresh.sockets.single.sentJson().single['op'], 'ping');
    await ws2.disconnect();
  });

  test('(m) the production socket factory goes through HttpOverrides — '
      'cert pinning applies to the WS handshake', () async {
    final previous = HttpOverrides.current;
    HttpOverrides.global = _PinningProbeOverrides();
    try {
      await expectLater(
        defaultCloudSocketFactory(Uri.parse('wss://api.ovidsi.com/cloud/ws')),
        throwsA(isA<_PinningProbeException>()),
        reason: 'WebSocket.connect must consult HttpOverrides.global '
            '(OvidPinningHttpOverrides is the pinning seam)',
      );
    } finally {
      HttpOverrides.global = previous;
    }
  });

  test('(n) CloudSessionEvent.fromJson mirrors shared/src/events.ts', () {
    final event = CloudSessionEvent.fromJson({
      'sessionId': 's1',
      'seq': '1700000000000-3',
      'type': 'message_delta',
      'payload': <String, dynamic>{
        'messageId': 'm1',
        'delta': <String>['x'],
      },
      'ts': '2026-10-16T10:00:00.000Z',
    });
    expect(event.sessionId, 's1');
    expect(event.seq, '1700000000000-3');
    expect(event.type, 'message_delta');
    expect(event.payload['messageId'], 'm1');
    expect(event.ts, DateTime.parse('2026-10-16T10:00:00.000Z'));
  });

  test('(o) unsubscribe sends the op and completes the stream; the cursor '
      'stays persisted for a later resubscribe', () async {
    final spy = SocketFactorySpy();
    final store = await SharedPreferences.getInstance();
    final ws = await _build(spy, prefs: store);
    final (events, _) = await _subscribeAndListen(ws, 's1');
    spy.sockets.single.server(_eventFrame('s1', '5-0'));
    await pumpEventQueue();
    expect(events.map((e) => e.seq), ['5-0']);

    ws.unsubscribe('s1');
    await pumpEventQueue();
    expect(
      spy.sockets.single.sentJson().where((f) => f['op'] == 'unsubscribe'),
      hasLength(1),
    );

    // Resubscribe replays from the persisted cursor, exactly once per event.
    final (events2, _) = await _subscribeAndListen(ws, 's1');
    final frames =
        spy.sockets.single.sentJson().where((f) => f['op'] == 'subscribe');
    expect(frames.last['lastEventId'], '5-0');
    spy.sockets.single.server(_eventFrame('s1', '5-0'));
    spy.sockets.single.server(_eventFrame('s1', '6-0'));
    await pumpEventQueue();
    expect(events2.map((e) => e.seq), ['6-0']);
    await ws.disconnect();
  });
}

class _PinningProbeException implements Exception {}

class _PinningProbeOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    throw _PinningProbeException();
  }
}
