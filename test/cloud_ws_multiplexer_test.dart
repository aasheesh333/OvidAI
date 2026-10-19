// P8 Task 6 — WsMultiplexer. Every wire shape asserted here was reconciled
// against the BUILT server code (the contract, not the plan sketches):
//   - client ops subscribe/unsubscribe/ping     — cloud/packages/shared/src/ws.ts
//   - server ops subscribed/event/pong/error    — cloud/packages/shared/src/ws.ts
//   - SessionEvent {sessionId, seq, type, payload, ts} — shared/src/events.ts
//   - close 4401 = WS_CLOSE_UNAUTHENTICATED     — cloud/apps/gateway/src/ws.ts
//   - replay-degradation signals = the additive {"op":"subscribed",
//     "sessionId":…,"trimmed":true} flag (the DURABLE gap signal — the
//     server-side sub stays live) AND the legacy {"op":"error","code":
//     "internal","message":"Replay failed.","sessionId":…} family (older
//     servers; the server deletes the subscription on it).
//   - compareSeq numeric-on-both-parts semantics — gateway ws.ts compareSeq.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, HttpOverrides, SecurityContext;
import 'dart:typed_data';

// fake_async comes transitively through flutter_test; promoting it to a
// direct dev_dependency needs a pubspec edit that is outside this task's
// pathspec lane (parallel-wave disjointness) — flagged in the task report
// for the next lockfile-allowed wave.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart' show fakeAsync;
import 'package:flutter/foundation.dart'
    show FlutterError, FlutterErrorDetails;
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

  /// Server → client BINARY frame (the P6 browser screencast). `dart:io`
  /// delivers these as Uint8List, so the fake does too.
  void serverBinary(List<int> bytes) => _frames.add(Uint8List.fromList(bytes));

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

  test('(b2) sessionEvents mirrors every ACCEPTED event of every session to '
      'read-only observers (Studio workspace refresh, ST-006)', () async {
    final spy = SocketFactorySpy();
    final ws = await _build(spy);
    final observed = <String>[];
    final tap = ws.sessionEvents.listen((e) => observed.add('${e.sessionId}:${e.seq}'));
    final (events, _) = await _subscribeAndListen(ws, 's1');
    ws.subscribe('s2').listen((_) {});
    await pumpEventQueue();
    final socket = spy.sockets.single;
    socket.server(_eventFrame('s1', '5-0'));
    socket.server(_eventFrame('s1', '5-0')); // duplicate: dropped for both
    socket.server(_eventFrame('s2', '1-0'));
    await pumpEventQueue();
    expect(events.map((e) => e.seq), ['5-0'],
        reason: 'the owner still receives its own stream');
    expect(observed, ['s1:5-0', 's2:1-0']);
    await tap.cancel();
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

  test('(j3) subscribed{trimmed:true} — the durable gap signal — triggers '
      'the SAME mirror catch-up, then live continues (trimmed-ack heal)',
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

    // The durable signal (@ovid/shared): the ack itself carries the trimmed
    // flag — unlike the error-frame path, the server-side sub stays live.
    socket.server(const {
      'op': 'subscribed',
      'sessionId': 's1',
      'trimmed': true,
    });
    await pumpEventQueue();

    expect(mirrorCalls, [('s1', '5-0')],
        reason: 'the mirror reads strictly after the sub cursor');
    expect(events.map((e) => e.seq), ['6-0', '7-0'],
        reason: 'mirror events flow through the session stream once');
    expect(errors, isEmpty, reason: 'the trimmed gap heals, no stream error');
    expect(store.getString('$_lastEventKey' 's1'), '7-0',
        reason: 'the cursor re-seeds from the mirror last event');

    // Live continues: the catch-up's re-subscribe goes out with the
    // re-seeded cursor (ws.ts re-subscribe replaces the still-live sub in
    // place), and overlap with the mirror range dedupes.
    expect(
      socket.sentJson().last,
      {'op': 'subscribe', 'sessionId': 's1', 'lastEventId': '7-0'},
    );
    socket.server(_eventFrame('s1', '6-0'));
    socket.server(_eventFrame('s1', '8-0'));
    await pumpEventQueue();
    expect(events.map((e) => e.seq), ['6-0', '7-0', '8-0']);
    await ws.disconnect();
  });

  test('(j4) a plain subscribed ack never touches the mirror; a trimmed ack '
      'for a session we no longer hold is ignored', () async {
    final mirrorCalls = <(String, String?)>[];
    final spy = SocketFactorySpy();
    final ws = await _build(
      spy,
      mirror: (sessionId, lastSeq) async {
        mirrorCalls.add((sessionId, lastSeq));
        return const <CloudSessionEvent>[];
      },
    );
    final (events, errors) = await _subscribeAndListen(ws, 's1');
    final socket = spy.sockets.single;

    // The normal ack (no flag)…
    socket.server(const {'op': 'subscribed', 'sessionId': 's1'});
    // …an explicit false…
    socket.server(const {
      'op': 'subscribed',
      'sessionId': 's1',
      'trimmed': false,
    });
    // …and a trimmed ack for an unknown session: none of these heal, none
    // may fire the fallback.
    socket.server(const {
      'op': 'subscribed',
      'sessionId': 'sX',
      'trimmed': true,
    });
    await pumpEventQueue();

    expect(mirrorCalls, isEmpty,
        reason: 'only trimmed:true for a held session sub triggers the '
            'catch-up');
    expect(events, isEmpty);
    expect(errors, isEmpty);
    await ws.disconnect();
  });

  test('(j5) readMirrorPages pages with after=<last seq of the previous '
      'page> until a SHORT page, then stops; off-contract responses end '
      'leniently', () async {
    final afters = <String?>[];
    final events = await WsMultiplexer.readMirrorPages((after) async {
      afters.add(after);
      if (after == '5-0') {
        // Page 1: a FULL 200-event page (the route's DEFAULT_EVENT_LIMIT),
        // resumed strictly after the seeded cursor.
        return <String, dynamic>{
          'events': [
            for (var i = 0; i < 200; i++)
              _sessionEventJson('s1', '${1000 + i}-0'),
          ],
        };
      }
      // Page 2: a short page → the mirror is exhausted.
      return <String, dynamic>{
        'events': [
          _sessionEventJson('s1', '1200-0'),
          _sessionEventJson('s1', '1200-1'),
        ],
      };
    }, '5-0');
    expect(afters, ['5-0', '1199-0'],
        reason: 'resume after the cursor, then after the page-1 last seq');
    expect(events, hasLength(202));
    expect(events.first.seq, '1000-0');
    expect(events.last.seq, '1200-1');

    // Off-contract response (no `events` list): stop, keep what was read.
    final offContract = await WsMultiplexer.readMirrorPages((after) async {
      return <String, dynamic>{'unexpected': true};
    }, null);
    expect(offContract, isEmpty);
  });

  test('(j6) readMirrorPages stops at the 25-page cap (5000 events) and '
      'gives up gracefully', () async {
    var calls = 0;
    final events = await WsMultiplexer.readMirrorPages((after) async {
      calls++;
      // Every page FULL and advancing — only the cap can stop the loop.
      return <String, dynamic>{
        'events': [
          for (var i = 0; i < 200; i++)
            _sessionEventJson('s1', '${calls * 200 + i}-0'),
        ],
      };
    }, null);
    expect(calls, 25, reason: 'the loop is bounded, never spins');
    expect(events, hasLength(5000));
    expect(events.first.seq, '200-0');
    expect(events.last.seq, '5199-0');
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

  test('(l2) binary server frames reach binaryServerFrames, not the text '
      'pipeline (P6 browser screencast)', () async {
    final spy = SocketFactorySpy();
    final ws = await _build(spy);
    ws.subscribe('s1');
    await pumpEventQueue();

    final binary = <Uint8List>[];
    final raw = <Map<String, dynamic>>[];
    final events = <CloudSessionEvent>[];
    ws.binaryServerFrames.listen(binary.add);
    ws.rawServerFrames.listen(raw.add);
    ws.subscribe('s1').listen(events.add);

    spy.sockets.single.serverBinary(const [0x52, 0x49, 0x46, 0x46]);
    await pumpEventQueue();

    expect(binary, hasLength(1));
    expect(binary.single, <int>[0x52, 0x49, 0x46, 0x46]);
    expect(raw, isEmpty, reason: 'binary frames are not JSON ops');
    expect(events, isEmpty, reason: 'binary frames are not session events');
    await ws.disconnect();
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

  test('(p) disconnect during an in-flight connect: the late socket never '
      'attaches and nothing ever reconnects (fix I-1)', () async {
    final prefs = await SharedPreferences.getInstance();
    fakeAsync((async) {
      final gate = Completer<void>();
      final sockets = <FakeCloudSocket>[];
      var mints = 0;
      final ws = WsMultiplexer(
        mintTicket: () async => 't${++mints}',
        socketFactory: (Uri url) async {
          final socket = FakeCloudSocket(url);
          sockets.add(socket);
          await gate.future; // hold the connect in flight
          return socket;
        },
        prefs: prefs,
        heartbeatInterval: const Duration(minutes: 10),
      );
      ws.subscribe('s1').listen((_) {});
      async.elapse(const Duration(milliseconds: 10));
      expect(ws.linkState, WsLinkState.connecting);
      expect(mints, 1);

      // User teardown while the connect is in flight.
      ws.disconnect();
      expect(ws.linkState, WsLinkState.disconnected);

      // The factory now resolves with the late socket — it must be closed,
      // never attached (no frames may leave on it).
      gate.complete();
      async.elapse(const Duration(milliseconds: 50));
      expect(sockets, hasLength(1));
      expect(sockets.single.isClosed, isTrue,
          reason: 'the stray socket must be closed, never attached');
      expect(sockets.single.sent, isEmpty,
          reason: 'no subscribe/ping frames after teardown');

      // Nothing reconnects — advance past the entire backoff cap.
      async.elapse(const Duration(seconds: 65));
      expect(mints, 1, reason: 'no re-mint after teardown');
      expect(sockets, hasLength(1));
      expect(ws.linkState, WsLinkState.disconnected);
    });
  });

  test('(q) a reconnect armed before disconnect never fires after it '
      '(fix I-1 defense-in-depth)', () async {
    final prefs = await SharedPreferences.getInstance();
    fakeAsync((async) {
      final spy = SocketFactorySpy();
      var mints = 0;
      final ws = WsMultiplexer(
        mintTicket: () async => 't${++mints}',
        socketFactory: spy.fn,
        prefs: prefs,
        heartbeatInterval: const Duration(minutes: 10),
        jitterMs: () => 0,
      );
      ws.subscribe('s1').listen((_) {});
      async.elapse(const Duration(milliseconds: 10));
      expect(spy.sockets, hasLength(1));

      // Server close → a reconnect is armed at +1s…
      spy.sockets.last.close(1000);
      async.elapse(const Duration(milliseconds: 20));
      expect(ws.linkState, WsLinkState.disconnected);

      // …then the user tears down: the armed timer must never fire.
      ws.disconnect();
      async.elapse(const Duration(seconds: 65));
      expect(spy.sockets, hasLength(1), reason: 'no reconnect after teardown');
      expect(mints, 1);
      expect(ws.linkState, WsLinkState.disconnected);
    });
  });

  test('(r) only the built replay-family literals trigger the mirror '
      'fallback; other internal+sessionId frames are session errors '
      '(fix I-2)', () async {
    Future<(List<(String, String?)> calls, List<Object> errors)> run(
      Map<String, Object?> frame,
    ) async {
      final mirrorCalls = <(String, String?)>[];
      final spy = SocketFactorySpy();
      final ws = await _build(spy, mirror: (sessionId, lastSeq) async {
        mirrorCalls.add((sessionId, lastSeq));
        return const <CloudSessionEvent>[];
      });
      final errors = <Object>[];
      ws.subscribe('s1').listen((_) {}, onError: errors.add);
      await pumpEventQueue();
      spy.sockets.single.server(frame);
      await pumpEventQueue();
      await ws.disconnect();
      return (mirrorCalls, errors);
    }

    // "Replay failed." (built ws.ts readSince catch) → mirror fallback.
    final replay = await run({
      'op': 'error',
      'code': 'internal',
      'message': 'Replay failed.',
      'sessionId': 's1',
    });
    expect(replay.$1, [('s1', null)]);

    // "Live subscription failed." (built ws.ts subscribe catch) → fallback,
    // healed (no stream error).
    final live = await run({
      'op': 'error',
      'code': 'internal',
      'message': 'Live subscription failed.',
      'sessionId': 's1',
    });
    expect(live.$1, [('s1', null)]);
    expect(live.$2, isEmpty, reason: 'the fallback heals, no stream error');

    // Another internal frame with a sessionId (the built ws.ts
    // browser-attach failure shape) must NOT trigger the fallback —
    // it is a session error.
    final other = await run({
      'op': 'error',
      'code': 'internal',
      'message': 'Browser attach failed.',
      'sessionId': 's1',
    });
    expect(other.$1, isEmpty,
        reason: 'non-replay internal frames are not replay degradation');
    expect(other.$2, hasLength(1));
    expect(other.$2.single,
        isA<CloudWsError>().having((e) => e.code, 'code', 'internal'));
  });

  test('(s) ptyId-scoped error frames reach rawServerFrames (T15 seam, '
      'fix I-3)', () async {
    final spy = SocketFactorySpy();
    final ws = await _build(spy);
    final (events, errors) = await _subscribeAndListen(ws, 's1');
    final raw = <Map<String, dynamic>>[];
    ws.rawServerFrames.listen(raw.add);
    spy.sockets.single.server(const {
      'op': 'error',
      'code': 'sandbox_busy',
      'message': 'Sandbox admission timed out.',
      'ptyId': 'p1',
    });
    await pumpEventQueue();
    expect(raw, hasLength(1));
    expect(raw.single['op'], 'error');
    expect(raw.single['code'], 'sandbox_busy');
    expect(raw.single['ptyId'], 'p1');
    expect(errors, isEmpty, reason: 'pty-scoped errors are not session errors');
    expect(events, isEmpty);
    await ws.disconnect();
  });

  test('(s2) a registered browser attach also sees session-scoped errors on '
      'the raw lane (T16 fix)', () async {
    final spy = SocketFactorySpy();
    final ws = await _build(spy);
    final (events, errors) = await _subscribeAndListen(ws, 's1');
    final raw = <Map<String, dynamic>>[];
    ws.rawServerFrames.listen(raw.add);

    ws.watchSessionErrors('s1');
    spy.sockets.single.server(const {
      'op': 'error',
      'code': 'forbidden',
      'message': 'Session not found.',
      'sessionId': 's1',
    });
    await pumpEventQueue();

    expect(raw, hasLength(1));
    expect(raw.single['op'], 'error');
    expect(raw.single['code'], 'forbidden');
    expect(raw.single['sessionId'], 's1');
    expect(errors, hasLength(1),
        reason: 'session-stream routing is unchanged (no duplicate event)');
    expect(events, isEmpty);

    // Once the viewer detaches, the raw lane stops receiving them.
    ws.unwatchSessionErrors('s1');
    spy.sockets.single.server(const {
      'op': 'error',
      'code': 'forbidden',
      'message': 'Session not found.',
      'sessionId': 's1',
    });
    await pumpEventQueue();
    expect(raw, hasLength(1));
    expect(errors, hasLength(2));
    await ws.disconnect();
  });

  test('(t) sync teardown inside the connecting transition: a later '
      'connect starts a FRESH chain, not the dead future (fix round 2)',
      () async {
    final spy = SocketFactorySpy();
    var mints = 0;
    final ws = WsMultiplexer(
      mintTicket: () async => 't${++mints}',
      socketFactory: spy.fn,
      prefs: await SharedPreferences.getInstance(),
    );
    // A linkState listener tears the link down SYNCHRONOUSLY inside the
    // connecting-transition notifyListeners — the wedge window between the
    // generation bump and the _connectFuture slot assignment in _connect().
    late final void Function() wedgeListener;
    wedgeListener = () {
      if (ws.linkState == WsLinkState.connecting) ws.disconnect();
    };
    ws.addListener(wedgeListener);
    ws.subscribe('s1').listen((_) {});
    await pumpEventQueue();
    expect(mints, 1, reason: 'the doomed chain minted once, then aborted');
    expect(spy.sockets, isEmpty, reason: 'never attached');
    expect(ws.linkState, WsLinkState.disconnected);

    // Disarm the wedge; a subsequent connect must start a fresh chain. With
    // the dead future left in the slot it would be a silent no-op (silent
    // link death).
    ws.removeListener(wedgeListener);
    await ws.connectIfNeeded();
    await pumpEventQueue();
    expect(mints, 2, reason: 'fresh chain minted a new ticket');
    expect(spy.sockets, hasLength(1));
    expect(ws.linkState, WsLinkState.online);
    expect(
      spy.sockets.single.sentJson().where((f) => f['op'] == 'subscribe'),
      hasLength(1),
      reason: 'the fresh chain re-subscribed the session on open',
    );
    await ws.disconnect();
  });

  test('(u) sync DISPOSE inside the connecting transition: the framework '
      'reports the ChangeNotifier contract violation LOUDLY and the '
      'multiplexer never silently wedges (fix round 2)', () async {
    final spy = SocketFactorySpy();
    var mints = 0;
    final ws = WsMultiplexer(
      mintTicket: () async => 't${++mints}',
      socketFactory: spy.fn,
      prefs: await SharedPreferences.getInstance(),
    );
    late final void Function() disposeListener;
    disposeListener = () {
      if (ws.linkState == WsLinkState.connecting) ws.dispose();
    };
    ws.addListener(disposeListener);
    final reported = <FlutterErrorDetails>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = reported.add;
    try {
      ws.subscribe('s1').listen((_) {});
      await pumpEventQueue();
    } finally {
      FlutterError.onError = previousOnError;
    }
    // dispose() DURING a notification is a ChangeNotifier contract
    // violation — the framework's own assertion fires (loudly), so the
    // failure mode is never silence. (The legal sync teardown inside the
    // transition is disconnect(), whose wedge and fresh-chain self-heal
    // are pinned by test (t).)
    expect(
      reported.any((details) =>
          '${details.exception}'.contains(
              'was called during the call to "notifyListeners()"')),
      isTrue,
      reason: 'the framework must report the dispose-during-notify misuse',
    );
    // The multiplexer's own teardown ran and nothing wedges: no socket
    // attached, no reconnect churn, link state honestly down — and the
    // connect slot self-healed via the identity guard.
    expect(mints, 1);
    expect(spy.sockets, isEmpty);
    expect(ws.linkState, WsLinkState.disconnected);
    await pumpEventQueue();
    expect(mints, 1, reason: 'no reconnect after teardown');
    expect(spy.sockets, isEmpty);
  });

  group('Wave 1b cursor discipline', () {
    test('CH-021: a token stream writes the cursor at most once per interval; '
        'a terminal writes through at once', () async {
      final spy = SocketFactorySpy();
      final store = await SharedPreferences.getInstance();
      final ws = await _build(spy, prefs: store);
      await _subscribeAndListen(ws, 's1');
      final socket = spy.sockets.single;
      socket.server(_eventFrame('s1', '5-0'));
      await pumpEventQueue();
      expect(store.getString('${_lastEventKey}s1'), '5-0',
          reason: 'the first event writes through');
      for (var i = 1; i <= 20; i++) {
        socket.server(_eventFrame('s1', '5-$i'));
      }
      await pumpEventQueue();
      expect(store.getString('${_lastEventKey}s1'), '5-0',
          reason: 'per-token writes are deferred');
      socket.server(<String, dynamic>{
        'op': 'event',
        'event': <String, dynamic>{
          'sessionId': 's1',
          'seq': '6-0',
          'type': 'run_completed',
          'payload': <String, dynamic>{'runId': 'r'},
          'ts': '2026-10-16T10:00:00.000Z',
        },
      });
      await pumpEventQueue();
      expect(store.getString('${_lastEventKey}s1'), '6-0');
      await ws.disconnect();
    });

    test('CH-021: deferred cursors flush on disconnect', () async {
      final spy = SocketFactorySpy();
      final store = await SharedPreferences.getInstance();
      final ws = await _build(spy, prefs: store);
      await _subscribeAndListen(ws, 's1');
      final socket = spy.sockets.single;
      socket.server(_eventFrame('s1', '5-0'));
      socket.server(_eventFrame('s1', '5-1'));
      await pumpEventQueue();
      await ws.disconnect();
      await pumpEventQueue();
      expect(store.getString('${_lastEventKey}s1'), '5-1');
    });

    test('CH-015: a cache seed never moves the cursor backwards', () async {
      final spy = SocketFactorySpy();
      final ws = await _build(spy);
      await _subscribeAndListen(ws, 's1');
      spy.sockets.single.server(_eventFrame('s1', '9-0'));
      await pumpEventQueue();
      ws.seedCursor('s1', '3-0');
      expect(await ws.cursorFor('s1'), '9-0');
      ws.seedCursor('s1', '10-0');
      expect(await ws.cursorFor('s1'), '10-0');
      await ws.disconnect();
    });

    test('CH-003: rebaseCursor re-subscribes from the snapshot watermark', () async {
      final spy = SocketFactorySpy();
      final ws = await _build(spy);
      final (events, _) = await _subscribeAndListen(ws, 's1');
      final socket = spy.sockets.single;
      socket.server(_eventFrame('s1', '9-0'));
      await pumpEventQueue();
      ws.rebaseCursor('s1', '7-0');
      expect(socket.lastSentJson(),
          {'op': 'subscribe', 'sessionId': 's1', 'lastEventId': '7-0'});
      // The replay after the watermark is accepted again (the rebuilt fold
      // needs it), duplicates past it still drop.
      socket.server(_eventFrame('s1', '8-0'));
      socket.server(_eventFrame('s1', '9-0'));
      socket.server(_eventFrame('s1', '9-0'));
      await pumpEventQueue();
      expect(events.map((e) => e.seq), ['9-0', '8-0', '9-0']);
      await ws.disconnect();
    });
  });

  test('(v) account switch (SH-008): reset closes the link, drops every '
      'subscription and cursor; the next connect mints a fresh ticket and '
      'subscribes nothing of the previous account', () async {
    final spy = SocketFactorySpy();
    final store = await SharedPreferences.getInstance();
    final ws = await _build(spy, prefs: store);
    var done = false;
    ws.subscribe('a-session').listen((_) {}, onDone: () => done = true);
    await pumpEventQueue();
    spy.sockets.single.server(_eventFrame('a-session', '5-0'));
    await pumpEventQueue();
    expect(store.getString('${_lastEventKey}a-session'), '5-0');

    await ws.resetForAccountChange();
    await pumpEventQueue();

    expect(ws.linkState, WsLinkState.disconnected);
    expect(spy.sockets.single.isClosed, isTrue);
    expect(ws.subscriptionCountForTest, 0);
    expect(done, isTrue, reason: "A's stream completes");
    expect(store.getString('${_lastEventKey}a-session'), isNull);

    await ws.connectIfNeeded();
    await pumpEventQueue();
    expect(spy.sockets, hasLength(2));
    expect(spy.uris.last.queryParameters['ticket'], 'ticket-2');
    expect(spy.sockets.last.sent, isEmpty,
        reason: "no subscribe for the previous account's session");
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
